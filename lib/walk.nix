# The core walker: Nix values → Wechselbalg IR.
#
# Performs a single pass over a Nix value (including reified lambda ASTs)
# and produces:
#
#   { ir = <ir-node>;  defs = { name = { params; body; }; ... };  known = { ... }; }
#
# - `ir`:    the IR representation of the input (call sites get `ref` nodes)
# - `defs`:  all function definitions discovered during the walk (hoisted)
# - `known`: the accumulated function identity map (name → nixValue)
#
# Every lambda is defined exactly once in `defs` and referenced by name
# everywhere it appears.  Recursion (self, mutual) is handled by
# registering the name BEFORE walking the body.
#
# The walker takes an option attribute set (all fields optional):
#
#   { maxPathRecords ? , maxDirEntries ? , maxImportValueNodes ?
#   , maxFileChars ? }
#
# See the comment at the budget definitions below for their meaning.
#
# `walk` additionally takes the target *backend* attrset (see lib/backends/*).
# A path reached through a *value* position (parameter, attr select, list
# element) lowers to a real runtime path value (string + fs record) when the
# backend has one (`renderPathValue`, i.e. js/cpp); backends without a path
# runtime receive the plain path string — the same shape a JSON-folded
# container always produced. The fs record binding is hoisted either way, so
# inline `import p` lowering keeps working everywhere.
{
  maxPathRecordsArg ? null,
  maxDirEntriesArg ? null,
  maxImportValueNodesArg ? null,
  maxFileCharsArg ? null,
}:
let
  ir = import ./ir.nix;
  evaluateAST = import ./eval.nix;
  purity = import ./purity.nix;
  util = import ./util.nix;
  validate = import ./validate.nix;
  analyze = import ./analyze.nix;
  paths = import ./paths.nix { inherit maxFileChars; };

  # Name of the environment parameter of a code template.  Deliberately not
  # `__wb_env`: the Python backend uses that identifier for its let-scope dict.
  envParam = "__wb_cenv";

  emptySeen = {
    sets = { };
    pathRoots = [ ];
    pathActive = { };
    funcs = [ ];
    depth = 0;
  };

  reverseList =
    list:
    let
      len = builtins.length list;
    in
    builtins.genList (i: builtins.elemAt list (len - 1 - i)) len;

  attrChunkSize = 100;

  chunkList =
    size: list:
    let
      len = builtins.length list;
      numChunks = builtins.div (len + size - 1) size;
    in
    if len <= size then
      [ list ]
    else
      builtins.genList (
        c:
        let
          start = c * size;
          rem = len - start;
          n = if rem < size then rem else size;
        in
        builtins.genList (i: builtins.elemAt list (start + i)) n
      ) numChunks;

  mergeAttrsBalanced =
    nodes:
    let
      len = builtins.length nodes;
    in
    if len == 1 then
      builtins.head nodes
    else
      let
        mid = builtins.div len 2;
        left = builtins.genList (i: builtins.elemAt nodes i) mid;
        right = builtins.genList (i: builtins.elemAt nodes (mid + i)) (len - mid);
      in
      ir.update (mergeAttrsBalanced left) (mergeAttrsBalanced right);

  # Strict fold for accumulator walks. Forces hot fields to prevent thunk cascades.
  foldWalk =
    f: init: list:
    builtins.foldl' (
      acc: x:
      let
        res = f acc x;
      in
      builtins.seq res.defs (
        builtins.seq res.pending (
          builtins.seq res.known.counter (
            # The import-window counter (see the `walkValue` wrapper) must run
            # during the walk, not after it: forcing `emitted` here makes a
            # walk over the node cap abort AT the cap, bounding translation
            # time and output size instead of finishing first.
            builtins.seq res.known.emitted (
              # `seen` is threaded through every walk step: force it so the
              # strict fold never drops it from the accumulator.
              builtins.seq res.seen (
                if res ? elements then
                  builtins.seq res.elements res
                else if res ? entries then
                  builtins.seq res.entries res
                else if res ? args then
                  builtins.seq res.args res
                else if res ? parts then
                  builtins.seq res.parts res
                else if res ? path then
                  builtins.seq res.path res
                else if res ? bindings then
                  builtins.seq res.bindings res
                else if res ? formals then
                  builtins.seq res.formals res
                else
                  res
              )
            )
          )
        )
      )
    ) init list;

  # ── Merge helper ────────────────────────────────────────────────
  update =
    a: b:
    if a == { } then
      b
    else if b == { } then
      a
    else
      a // b;

  # ── AST path-node scan ──────────────────────────────────────────
  # True if a reified AST subtree contains a `path` node anywhere below the
  # *direct* children of the given list/attrSet node. Such containers must
  # not be folded to a `fromJSON` literal: reify stores path nodes as plain
  # strings, so folding would silently replace each path with its string and
  # skip the translation-time fs-record registration (`walkPath`). The
  # direct children themselves are not inspected — a top-level path node is
  # handled by the caller's own path case.
  astListHasPath = nodes: builtins.any (n: astSubtreeHasPath n) nodes;

  # For a *value* reified with builtins.reify: containers appear as list /
  # attrSet AST nodes; scan their direct children for path nodes. Any other
  # node shape has nothing to fold, so answer false.
  astNodeHasPathChildren =
    ast:
    let
      e = ast._expr or null;
    in
    if e == "list" then
      astListHasPath (ast.value or [ ])
    else if e == "attrSet" then
      astAttrsHasPath (ast.value.attrs or { }) (builtins.attrNames (ast.value.attrs or { }))
    else
      false;

  astAttrsHasPath = attrs: names: builtins.any (n: astSubtreeHasPath attrs.${n}) names;

  astSubtreeHasPath =
    ast:
    let
      e = ast._expr or null;
    in
    if e == "path" then
      true
    else if e == "list" then
      astListHasPath (ast.value or [ ])
    else if e == "attrSet" then
      astAttrsHasPath (ast.value.attrs or { }) (builtins.attrNames (ast.value.attrs or { }))
      || builtins.any (d: astSubtreeHasPath d.name || astSubtreeHasPath d.value) (
        ast.value.dynamicAttrs or [ ]
      )
    else if e == "lambda" then
      # Parameter defaults are evaluated eagerly when the lambda value is
      # built, so a path there must be lowered like any other embedded value.
      astParamsHavePath ast.value.arguments or { } || astSubtreeHasPath ast.value.body or { }
    else if e == "let" then
      let
        attrs = ast.value.attrs or { };
        names = builtins.attrNames attrs;
      in
      astAttrsHasPath attrs names || astSubtreeHasPath ast.value.body or { }
    else if e == "with" then
      astSubtreeHasPath ast.value.namespace or { } || astSubtreeHasPath ast.value.body or { }
    else if e == "if" then
      astSubtreeHasPath ast.value.condition or { }
      || astSubtreeHasPath ast.value.${"then"} or { }
      || astSubtreeHasPath ast.value.${"else"} or { }
    else if e == "assert" then
      astSubtreeHasPath ast.value.condition or { } || astSubtreeHasPath ast.value.body or { }
    else if e == "call" then
      astSubtreeHasPath ast.value.function or { } || astListHasPath (ast.value.args or [ ])
    else if e == "select" then
      astSubtreeHasPath ast.value.expression or { } || astListHasPath (ast.value.path or [ ])
    else if e == "update" || e == "addition" || e == "concatString" || e == "implicitAssert" then
      astSubtreeHasPath ast.value.e1 or { } || astSubtreeHasPath ast.value.e2 or { }
    else if e == "hasAttribute" then
      astSubtreeHasPath ast.value.e1 or { } || astSubtreeHasPath ast.value.e2 or { }
    else if e == "opNot" || e == "head" || e == "tail" || e == "length" then
      astSubtreeHasPath ast.value or { }
    else if e == "opAnd" || e == "opOr" || e == "equal" || e == "lessThan" || e == "greaterThan" then
      astSubtreeHasPath ast.value.e1 or { } || astSubtreeHasPath ast.value.e2 or { }
    else if e == "attrName" || e == "var" || e == "literal" || e == "primop" || e == "comment" then
      false
    else
      # Unknown node shape: be conservative, keep the structural walk.
      true;

  astParamsHavePath =
    arguments:
    builtins.any (f: f ? defaultExpr && astSubtreeHasPath f.defaultExpr) (arguments.formals or [ ]);

  # Same scan including the node itself.
  isPathBearing =
    ast:
    let
      e = ast._expr or null;
    in
    if e == "path" then true else astSubtreeHasPath ast;

  # ── Split defs by hoistability ──────────────────────────────────
  splitDefs =
    defs:
    let
      names = builtins.attrNames defs;
      hoistableNames = builtins.filter (name: defs.${name}._hoistable or false) names;
      localNames = builtins.filter (name: !(defs.${name}._hoistable or false)) names;

      hoistable = builtins.listToAttrs (
        builtins.map (name: {
          inherit name;
          value = defs.${name};
        }) hoistableNames
      );
      local = builtins.listToAttrs (
        builtins.map (name: {
          inherit name;
          value = defs.${name};
        }) localNames
      );
    in
    {
      inherit hoistable local;
    };

  # ── Runtime reify metadata for one hoisted definition ───────────
  reifyMeta =
    ast: known:
    let
      info = analyze.reifyInfo ast;
      hasEnv = (known._env or null) != null;
      captured = if hasEnv then known._env.capture.mode else { };
      localNames = builtins.filter (n: !(captured ? ${n})) info.free;
      localEnv = ir.attrs (
        builtins.listToAttrs (
          builtins.map (n: {
            name = n;
            value = ir.var n;
          }) localNames
        )
      );
    in
    {
      ast = builtins.toJSON info.stripped;
      envIR =
        if hasEnv && localNames != [ ] then
          ir.update (ir.var known._env.param) localEnv
        else if hasEnv then
          ir.var known._env.param
        else if localNames != [ ] then
          localEnv
        else
          null;
    };

  # ── Walk a reified lambda's parameter list ──────────────────────
  walkParams =
    arguments: backend: known: seen:
    let
      identifier = arguments.identifier or null;
      ellipsis = if builtins.hasAttr "ellipsis" arguments then arguments.ellipsis else true;
      # Canonical order (see analyze.canonicalFormals): `reify` reports the
      # formals in source order, which would otherwise leak into every
      # backend's parameter bindings and its `!ellipsis` guard code.
      formals = analyze.canonicalFormals (arguments.formals or [ ]);
    in
    if !(builtins.hasAttr "formals" arguments) then
      {
        params = {
          inherit identifier ellipsis;
          formals = null;
        };
        defs = { };
        pending = [ ];
        inherit known seen;
      }
    else
      let
        result =
          foldWalk
            (
              acc: f:
              if builtins.hasAttr "defaultExpr" f then
                let
                  r = walkAST f.defaultExpr backend acc.known seen;
                in
                {
                  formals = [
                    {
                      inherit (f) name;
                      hasDefault = true;
                      default = r.ir;
                    }
                  ]
                  ++ acc.formals;
                  defs = update acc.defs r.defs;
                  pending = r.pending ++ acc.pending;
                  known = r.known;
                  seen = r.seen;
                }
              else
                {
                  formals = [
                    {
                      inherit (f) name;
                      hasDefault = false;
                      default = null;
                    }
                  ]
                  ++ acc.formals;
                  inherit (acc)
                    defs
                    pending
                    known
                    seen
                    ;
                }
            )
            {
              formals = [ ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
            formals;
      in
      {
        params = {
          inherit identifier ellipsis;
          formals = reverseList result.formals;
        };
        inherit (result)
          defs
          pending
          known
          seen
          ;
      };

  # ── Name allocation ─────────────────────────────────────────────
  alloc = prefix: known: {
    name = "${prefix}${toString known.counter}";
    known = known // {
      counter = known.counter + 1;
    };
  };

  markUsed =
    name: known:
    known
    // {
      used = known.used // {
        ${name} = true;
      };
    };

  findInFlight =
    fn: funcs:
    let
      len = builtins.length funcs;
      go =
        i:
        if i >= len then
          null
        else
          let
            e = builtins.elemAt funcs i;
          in
          if builtins.sameFunction fn e.fn then e.binding else go (i + 1);
    in
    if funcs == [ ] then null else go 0;

  findInstance =
    fn: instances:
    let
      len = builtins.length instances;
      go =
        i:
        if i >= len then
          null
        else
          let
            e = builtins.elemAt instances i;
          in
          if builtins.sameFunction fn e.fn then e.binding else go (i + 1);
    in
    if instances == [ ] then null else go 0;

  # ── Instance memo ───────────────────────────────────────────────
  instanceCap = 64;

  confirmSameSet =
    a: b:
    builtins.foldl' (
      acc: n:
      if acc != null then
        acc
      else
        let
          t = builtins.tryEval (
            if builtins.isFunction a.${n} && builtins.isFunction b.${n} then
              builtins.sameFunction a.${n} b.${n}
            else
              null
          );
        in
        if t.success && t.value != null then t.value else null
    ) null (builtins.attrNames a);

  # ── Resolve one captured environment entry ──────────────────────
  resolveCapture =
    entry:
    let
      # `entry.env` is the reified `closureEnvValue` — for a narrowed
      # capture (e.g. `wasm` read out of the big `lib` attrset) it is the
      # *root* value, and the fold walks the selection path into it. A failed
      # fold means the capture cannot be resolved statically; decline it with an
      # explicit runtime throw instead of failing translation.
      #
      # Missing-attribute errors are NOT catchable by `tryEval` (only
      # throw/assert failures are), e.g. `builtins.currentSystem` under pure
      # evaluation. Guard every selection step with `hasAttr` and turn an
      # absent attribute into a catchable throw so the capture is declined.
      r = builtins.tryEval (
        let
          selectAll =
            env: path:
            if path == [ ] then
              env
            else if !builtins.isAttrs env || !builtins.hasAttr (builtins.head path) env then
              throw "wechselbalg: captured attribute path is not available"
            else
              selectAll env.${builtins.head path} (builtins.tail path);
        in
        selectAll entry.env entry.path
      );
    in
    if !r.success then
      { ok = false; }
    else
      let
        t = builtins.tryEval (builtins.typeOf r.value);
        p = builtins.tryEval (purity.isPure r.value);
      in
      if !t.success then
        { ok = false; }
      else if t.value == "path" then
        # Paths are translatable: the walker records the translation-time fs state.
        {
          ok = true;
          inherit (r) value;
        }
      else if !p.success || !p.value.pure then
        { ok = false; }
      else
        {
          ok = true;
          inherit (r) value;
        };

  # Fast string extractor for fingerprinting without iterating all names
  extractDistString =
    v: k:
    if v ? ${k} then
      let
        try = builtins.tryEval (if builtins.isString v.${k} then "${k}=${v.${k}}" else "");
      in
      if try.success then try.value else ""
    else
      "";

  # ── Lower a path value to an IR `path` node ─────────────────────
  #
  # The target runtime cannot see the filesystem that existed while
  # translating, so `paths.probe` records everything `pathExists`,
  # `readFileType`, `readFile`, `readDir` and `import` would have answered,
  # and that record is embedded as a lazy attrset attached to the path value.
  # Cycles (a .nix file whose import reaches back to the same path node) are
  # tied with the same knot-tying scheme as captured sets: the first lowering
  # registers the path in `known.pathReg`, imports it, and — if the walk came
  # back here — emits a `ref` to the allocated meta binding instead of a
  # second copy.

  # The fs metadata attrset (no imported value) as IR entries.
  fsMetaEntries =
    s: fs:
    let
      strOrThrow = v: msg: if v == null then ir.primopApp "throw" [ (ir.string msg) ] else ir.string v;

      # `builtins.readFile` on a non-file raises a SysError in Nix; the
      # probe recorded that failure as content == null.
      contentMsg =
        if fs.fileType == "directory" then
          "wechselbalg: cannot read contents of directory '${s}': not a regular file"
        else
          "wechselbalg: cannot read '${s}': does not exist in the translated filesystem";

      fileTypeNode =
        if fs.fileType == "unknown" then
          ir.primopApp "throw" [ (ir.string "wechselbalg: cannot determine file type of '${s}'") ]
        else
          ir.string fs.fileType;

      dirNode =
        if fs.dir == null then
          ir.primopApp "throw" [
            (ir.string "wechselbalg: '${s}' is not a directory in the translated filesystem")
          ]
        # maxDirEntries: a listing larger than the cap is never emitted —
        # readDir on it throws naming the limit. exists/fileType/content
        # remain valid, and the directory still costs exactly one record.
        else if builtins.length (builtins.attrNames fs.dir) > maxDirEntries then
          ir.primopApp "throw" [
            (ir.string "wechselbalg: directory listing of '${s}' has more than ${toString maxDirEntries} entries; readDir is not available for it in the translated program")
          ]
        else
          ir.attrs (
            builtins.mapAttrs (_: kind: strOrThrow kind "wechselbalg: unknown file type in '${s}'") fs.dir
          );
    in
    {
      exists = ir.bool fs.exists;
      fileType = fileTypeNode;
      content = strOrThrow fs.content contentMsg;
      dir = dirNode;
    };

  # Entry set for a path that exceeded the per-root record budget:
  # *every* field — including the imported `value` — is a runtime throw
  # naming the path and the limit. Used by walkPath when a path is refused.
  limitedMetaEntries =
    s: reason:
    let
      mk =
        field:
        ir.primopApp "throw" [
          (ir.string "wechselbalg: '${s}' was not recorded during translation: ${reason}. The path itself remains usable (toString, ==, isPath).")
        ];
    in
    {
      exists = mk "exists";
      fileType = mk "fileType";
      content = mk "content";
      dir = mk "dir";
      value = mk "value";
    };

  # The runtime throw used when `import` of this path is attempted but the
  # translated value is not available: `unimportable` (not a .nix file),
  # `failed` (the file itself threw while evaluating), or `nodes` (the import
  # expansion exceeded its IR-node window — see walkPathImport; note a
  # genuine translator error *inside* an imported value aborts the same way
  # and reports `nodes` as well).
  pathImportError =
    s: probeResult: reason:
    if !probeResult.importable then
      "wechselbalg: '${s}' cannot be imported: not a .nix file or directory with default.nix"
    else if reason == "nodes" then
      "wechselbalg: importing '${s}' exceeds the translation limit of ${toString maxImportValueNodes} IR nodes per import: its value is not embedded in the translated program"
    else
      "wechselbalg: importing '${s}' failed at translation time";

  # ── Path budgets (per *root* path reference) ────────────────────
  # A root path reference (a path appearing in translated code) starts a
  # bounded neighbourhood expansion, charged against its OWN counters —
  # expanding root A's neighbourhood never charges root B:
  #   * `maxPathRecords` — how many distinct filesystem records (exists,
  #     fileType, content, listing for one path) the root may emit. Reaching
  #     a path a second time within the same root is free (visited set); a
  #     path beyond the cap still emits a working path *value* (toString/==/
  #     isPath work) but every fs field is a runtime throw naming the limit.
  #   * `maxDirEntries` — a directory listing larger than this is never
  #     emitted; readDir on it throws. The directory still costs one record.
  #   * `maxImportValueNodes` — IR-node window for import value expansion
  #     (see `importWindow` / `emitted` below and walkPathImport): the walker
  #     ticks a counter for every value it expands inside an import, and when
  #     the window's count exceeds this cap the import aborts and resolves to
  #     a runtime throw.
  # A path that is merely referenced but never read keeps only its basic
  # record (exists/fileType/dir listing). There is no descent into directory
  # children: a directory record contains its own listing and nothing else.
  maxPathRecords = if maxPathRecordsArg != null then maxPathRecordsArg else 100; # distinct fs records per root
  maxDirEntries = if maxDirEntriesArg != null then maxDirEntriesArg else 200; # entries per directory listing
  maxImportValueNodes = if maxImportValueNodesArg != null then maxImportValueNodesArg else 20000; # IR nodes per import window

  # Maximum size of a *file content* embedded into the translated program.
  # A larger file still gets its metadata record (exists/fileType/dir listing —
  # those never depend on this cap), but `content`/`import` of it is a runtime
  # throw naming the limit. This also keeps binary or huge data files out of
  # the output without ever forcing their bytes.
  maxFileChars = if maxFileCharsArg != null then maxFileCharsArg else 10000;

  # Rough cost (in "IR nodes") charged when the walker *visits* a value
  # (enforced by the `walkValue` wrapper against the import window — see
  # `importWindow`). It is computed before descending, so over-cap values are
  # refused without ever building their IR — the bound on translation time.
  # Not exact, by design:
  #   - strings cost 1 + length/256: one node, but it renders as its full
  #     text, so a multi-kilobyte blob must not register as a single node
  #   - lists/attrsets cost their structural total: containers are expanded
  #     completely, including the `fromJSON` fast path, so a 100k-element
  #     list is ~100k nodes even when lowered as a single literal
  #   - lambda *bodies* are not counted (templates compile outside any
  #     window; they are deduplicated by template key and bounded by source
  #     size — see the spec's Bound section)
  #   - unforceable members cost 1 (they become runtime throws anyway)
  # `budget` bounds this computation itself: contributions beyond what the
  # window has left are irrelevant — the caller refuses either way — so
  # computing a weight never costs more than the walk it guards. The depth
  # cap keeps shared/cyclic structures finite; every visited descent re-ticks
  # its own subtree, so the threaded counter still dominates.
  # ── Import node windows (`maxImportValueNodes`) ────────────────
  # The walker threads a counter (`known.emitted`) that every visited value
  # ticks; `walkPathImport` opens a window (start = current count) around an
  # import — nested imports *share* the outer window — and the walk aborts
  # with a throw once the count exceeds the cap, so a translated program
  # contains at most `maxImportValueNodes` IR nodes per *import chain*.
  # Two cost models, each for its place:
  #
  #   valueCost     — the per-visit tick in `walkValue`. Constant per value
  #                   except for strings, which are a single node that renders
  #                   as their full text (1 + length/256 registers a
  #                   multi-kilobyte blob as several nodes). Containers cost
  #                   1 because the walk ticks each descent separately.
  #
  #   structuralCost— the *entry* check in `walkPathImport`, run once per
  #                   import before walking anything: it sums the full
  #                   (bounded) IR cost of the imported value, so an
  #                   oversized value is refused without ever expanding it —
  #                   this bounds translation time and output size directly,
  #                   not just the post-hoc node count (`fromJSON` folds a
  #                   100k-element list into one literal, which per-value
  #                   ticks would count as a single node).
  #
  # Both models skip lambda *bodies* on purpose: function templates compile
  # later from the queue, outside any window; they are deduplicated by
  # template key and bounded by source size (see the spec's Bound section).
  # `structuralCost` is capped at the window's remainging budget: contributions
  # beyond that never change the outcome, so measuring one import costs O(the
  # cap). The depth bound makes shared/cyclic values terminate; the walk's own
  # counter still bounds what actually reaches the output.
  valueCost =
    value:
    let
      type = builtins.typeOf value;
    in
    if type == "string" then 1 + builtins.div (builtins.stringLength value) 256 else 1;

  structuralCost =
    budget: value:
    let
      step =
        acc: depth: guarded:
        if acc > budget then
          acc
        else if depth > 64 || !guarded.success then
          # Unevaluable members become runtime throws anyway.
          acc + 1
        else
          let
            item = guarded.value;
            type = builtins.typeOf item;
            listCost = builtins.foldl' (a: g: step a (depth + 1) g) (acc + 1);
            attrCost = builtins.foldl' (a: n: step a (depth + 1) (builtins.tryEval (item.${n} or null))) (
              acc + 1
            );
          in
          if type == "list" then
            listCost (map builtins.tryEval item)
          else if type == "set" then
            attrCost (builtins.attrNames item)
          else if type == "string" then
            acc + 1 + builtins.div (builtins.stringLength item) 256
          else
            acc + 1;
    in
    step 0 0 (builtins.tryEval value);

  # The value-walking entry point used everywhere: tick the visit against the
  # active import window and refuse (throw) instead of expanding past the cap.
  # With no window (`importWindow == null` — the top-level value and template
  # compilation) nothing is counted or enforced. Every branch of `walkValue'`
  # threads `known` through, so ticks propagate through the whole subtree;
  # `foldWalk` forces `emitted` so the abort happens *during* the walk.
  walkValue =
    value: backend: known0: seen:
    let
      w = known0.importWindow;
      e = if w == null then known0.emitted else known0.emitted + valueCost value;
    in
    if w != null && e - w.start > w.limit then
      throw "wechselbalg: import of '${w.path}' exceeds the import limit of ${toString maxImportValueNodes} IR nodes"
    else
      walkValue' value backend (if w == null then known0 else known0 // { emitted = e; }) seen;

  # Import a path at translation time and lower the result. Only `.nix` files
  # and dirs with a default.nix are attempted — anything else raises an
  # uncatchable ParseError. A failing import (a throw while evaluating the
  # file) is caught by tryEval and becomes a runtime throw in target code.
  # The per-root record cap (maxPathRecords) is enforced by walkPath *before*
  # calling this — by the time we get here the path has been charged to its
  # root. Cycle detection lives there too: a path whose own import is already
  # in progress (seen.pathActive) never reaches this function.
  # The expansion runs inside an IR-node window (`maxImportValueNodes`): see
  # the window code below and the `walkValue` wrapper above.
  # Whether the target backend can represent a Nix path as a runtime value
  # (js/cpp build a Value carrying the fs record; others only have strings).
  hasRuntimePath = backend: backend != null && builtins.hasAttr "renderPathValue" backend;

  walkPathImport =
    s: probeResult: backend: known: seen:
    let
      bindingAlloc = alloc "__wb_pmeta_" known;
      binding = bindingAlloc.name;

      importTry =
        if !probeResult.importable then
          {
            success = false;
            value = null;
          }
        else
          builtins.tryEval (import (builtins.toPath s));

      reason =
        if !probeResult.importable then
          "unimportable"
        else if !importTry.success then
          "failed"
        else
          null;
    in
    if reason != null then
      {
        ir = ir.primopApp "throw" [ (ir.string (pathImportError s probeResult reason)) ];
        defs = { };
        pending = [ ];
        known = bindingAlloc.known;
        inherit seen;
        refused = true;
        inherit binding;
      }
    else
      let
        # The registry is only an fs-probe cache: the record cap and visited
        # sets live in `known.roots` (per root), so pathReg entries carry just
        # { importable, fs } and re-references never re-probe the filesystem.
        known1 =
          if known.pathReg ? ${s} then
            bindingAlloc.known
          else
            bindingAlloc.known
            // {
              pathReg = bindingAlloc.known.pathReg // {
                ${s} = {
                  importable = probeResult.importable;
                  fs = probeResult.fs;
                };
              };
            };
        # The node window: inside an import chain we share the chain's window;
        # otherwise this import opens one (closed again when it returns).
        # The window carries its originating path for the error message.
        window =
          if known.importWindow != null then
            known.importWindow
          else
            {
              inherit s;
              start = known.emitted;
              limit = maxImportValueNodes;
            };
        # Entry check *before* anything is expanded: an oversized imported
        # value is refused outright, so its IR is never built — this bounds
        # translation time and output size, not merely the post-hoc count.
        remaining = window.limit - (if known.importWindow != null then known.emitted - window.start else 0);
        overEntry = structuralCost remaining importTry.value > remaining;
        r = walkValue importTry.value backend (known1 // { inherit window; }) seen;
        # Forcing the full result turns the window's throw into a *refusal*
        # of the whole expansion: a failed import leaves no half-built values,
        # records or visited marks — `known1` / the caller's `seen` are
        # returned instead, and the meta record's `value` is the node-limit
        # throw. tryEval cannot tell the limit throw from a genuine translator
        # error inside the imported value; both are reported as "nodes" (the
        # mitigation for debugging is a raised maxImportValueNodes).
        forced = builtins.tryEval (builtins.seq r.known.emitted (builtins.seq r.ir r));
      in
      if overEntry || !forced.success then
        {
          ir = ir.primopApp "throw" [ (ir.string (pathImportError s probeResult "nodes")) ];
          defs = { };
          pending = [ ];
          known = known1;
          inherit seen;
          refused = true;
          inherit binding;
        }
      else
        {
          inherit (r)
            ir
            defs
            pending
            ;
          # The window closes at the import boundary — only nested expansions
          # shared it; the outer counter (`emitted`) stays incremented.
          known = r.known // {
            importWindow = known.importWindow;
          };
          inherit seen;
          refused = false;
          inherit binding;
        };

  # `newRoot` marks a path reached outside any import expansion (a value
  # position in the translated program, or an inline literal): that reference
  # starts its own record-budgeted neighbourhood. Paths reached *within* an
  # import are charged to the root currently being expanded — tracked on
  # `seen.pathRoots`, a stack of root ids whose top is the expansion we are
  # inside of. Per-root state lives in `known.roots.${rootId}`:
  #   { count = distinct records emitted; visited = set of path strings }.
  walkPath =
    pathStr: backend: known0: seen0: newRoot: origin:
    let
      s = builtins.toString pathStr;
      rootAlloc = if newRoot then alloc "__wb_root_" known0 else null;
      # A fresh root gets its own id (from the name allocator) and a fresh
      # counter/visited set; inside an import we keep charging the top root.
      rootId =
        if newRoot then
          rootAlloc.name
        else if seen0.pathRoots != [ ] then
          builtins.head seen0.pathRoots
        else
          # Defensive: a path reached outside any import but without newRoot
          # (should not happen) — treat it as its own root.
          rootAlloc.name;
      known1 =
        if newRoot then
          rootAlloc.known
          // {
            roots = rootAlloc.known.roots // {
              ${rootId} = {
                count = 0;
                visited = { };
              };
            };
          }
        else
          known0;
      rs = known1.roots.${rootId};
      # Re-reaching a path within the same root is free — no record charged.
      revisit = rs.visited ? ${s};
      # Beyond the per-root cap: still emit a working path *value*
      # (toString/==/isPath work) but every fs field throws naming the limit.
      # A refused path is neither counted nor marked visited.
      recordRefused = !revisit && rs.count >= maxPathRecords;

      existing = known1.pathReg.${s} or null;
      # Probe once per distinct path (the filesystem walk); reuse its record
      # for subsequent references — they differ only in placement, not fs facts.
      probeResult =
        if existing != null then
          {
            importable = existing.importable;
            fs = existing.fs;
          }
        else
          paths.probe s;

      # A cyclic import: this exact path's own import is still in progress on
      # the call stack (ancestry-scoped seen.pathActive). Its value resolves
      # to a runtime throw naming the cycle; no second copy of the expansion.
      cyclic = seen0.pathActive ? ${s};

      # Charge the root: mark visited and count the record — even when the
      # import then fails, the fs record itself was emitted and costs one.
      # A *refused* path emits no record, so it is neither counted nor marked
      # visited: `roots.${rootId}.count` always equals the number of records
      # actually emitted (at most `maxPathRecords`), which is what
      # `pathStats` reports and the count tests assert.
      knownCharged =
        if recordRefused then
          known1
        else
          known1
          // {
            roots = known1.roots // {
              ${rootId} = rs // {
                count = if revisit then rs.count else rs.count + 1;
                visited = rs.visited // {
                  ${s} = true;
                };
              };
            };
          };

      # Extend the import ancestry for the nested walk: this path becomes the
      # active node (cycle detection) and, at a fresh root, the top of the
      # root stack. Both are restored when the import returns.
      seenImport =
        if newRoot then
          seen0
          // {
            pathRoots = [ rootId ];
            pathActive = {
              ${s} = true;
            };
          }
        else
          seen0
          // {
            pathActive = seen0.pathActive // {
              ${s} = true;
            };
          };

      imp =
        if recordRefused || cyclic then
          null
        else
          walkPathImport s probeResult backend knownCharged seenImport;

      # The import expansion must not leak the caller's root stack or active
      # set — both are restored exactly.
      afterSeen =
        if imp == null then
          seen0
        else
          imp.seen
          // {
            pathRoots = seen0.pathRoots;
            pathActive = seen0.pathActive;
          };
      afterKnown = if imp == null then knownCharged else imp.known;

      valueSel = b: ir.select (ir.ref b) [ (ir.string "value") ];
      bindingName = if imp == null then (alloc "__wb_pmeta_" afterKnown).name else imp.binding;
      rootMeta =
        if recordRefused then
          limitedMetaEntries s "it exceeds ${toString maxPathRecords} path records for its root reference"
        else
          fsMetaEntries s probeResult.fs;
      metaEntries =
        if imp == null then
          if cyclic then
            rootMeta
            // {
              value = ir.primopApp "throw" [
                (ir.string "wechselbalg: importing '${s}' would be cyclic: the file's value includes this same path")
              ];
            }
          else
            # recordRefused already throws in every field, incl. value.
            rootMeta
        else
          rootMeta // { value = imp.ir; };
    in
    {
      ir = if !hasRuntimePath backend then ir.string s else ir.pathValue s bindingName;
      importIR =
        if imp == null then
          valueSel bindingName # refused/cyclic: the meta attrset's `value` throws
        else if imp.refused then
          imp.ir
        else
          valueSel imp.binding;
      defs = if imp == null then { } else imp.defs;
      pending = if imp == null then [ ] else imp.pending;
      known = afterKnown // {
        bindings = afterKnown.bindings // {
          ${bindingName} = ir.attrs metaEntries;
        };
      };
      seen = afterSeen;
    };

  # ── Walk a Nix value (already evaluated) ────────────────────────
  # Wrapped by `walkValue` (the import-node window) above.
  walkValue' =
    value: backend: known: seen:
    let
      type = builtins.typeOf value;
    in
    if seen.depth > 500 then
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: value nesting too deep (possible cycle)")
        ];
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if
      (type == "set" || type == "list")
      && util.JSONOptimizable value
      # A container whose reified AST contains path nodes must NOT be folded
      # to a fromJSON literal: the JSON encoding stores paths as plain
      # strings, and at runtime `import`/readFile on such a string fails with
      # "no translation-time filesystem record". Lower it structurally so each
      # path element goes through walkPath (fs record + pathValue). Only the
      # children are scanned — a top-level path value has no AST here anyway.
      # (`builtins.reify` in this Nix only accepts functions; a non-function
      # value reifies to its own value, whose type can never be `path` — that
      # case is caught by walkValue's type == "path" branch instead.)
      && !(builtins.isFunction value && astNodeHasPathChildren (builtins.reify value))
    then
      {
        ir = ir.primopApp "fromJSON" [ (ir.string (builtins.toJSON value)) ];
        defs = { };
        pending = [ ];
        inherit known seen;
      }
    else if type == "int" then
      {
        ir = ir.int value;
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if type == "float" then
      {
        ir = ir.float value;
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if type == "string" then
      {
        ir = ir.string value;
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if type == "bool" then
      {
        ir = ir.bool value;
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if type == "null" then
      {
        ir = ir.null_;
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if type == "list" then
      let
        seen' = seen // {
          depth = seen.depth + 1;
        };
        result =
          foldWalk
            (
              acc: elem:
              let
                r = walkValue elem backend acc.known seen';
              in
              {
                elements = [ r.ir ] ++ acc.elements;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              elements = [ ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
            value;
      in
      {
        ir = ir.list (reverseList result.elements);
        inherit (result)
          defs
          known
          pending
          seen
          ;
      }

    else if type == "set" then
      if value ? drvPath || (value ? type && value.type == "derivation") then
        {
          ir = ir.primopApp "throw" [
            (ir.string "wechselbalg: derivations cannot be translated into target code")
          ];
          defs = { };
          pending = [ ];
          inherit known seen;
        }
      else
        let
          names = builtins.attrNames value;
          # Fast direct lookup instead of filtering over all names
          dName = extractDistString value "name";
          dType = extractDistString value "_type";
          dDesc = extractDistString value "description";
          distinguishers = builtins.concatStringsSep "|" (
            builtins.filter (s: s != "") [
              dName
              dType
              dDesc
            ]
          );

          rawFingerprint =
            builtins.concatStringsSep "," names + (if distinguishers != "" then "#${distinguishers}" else "");

          fingerprint =
            if builtins.length names > 10 then builtins.hashString "sha256" rawFingerprint else rawFingerprint;

          ancestor = seen.sets.${fingerprint} or null;
          confirmed = if ancestor == null then false else confirmSameSet value ancestor.value;
        in
        if ancestor != null && confirmed == true then
          {
            ir = ir.ref ancestor.binding;
            defs = { };
            pending = [ ];
            known = markUsed ancestor.binding known;
            inherit seen;
          }
        else
          let
            bindingAlloc = alloc "__wb_cap_" known;
            binding = bindingAlloc.name;
            seen' = seen // {
              depth = seen.depth + 1;
              sets = seen.sets // {
                ${fingerprint} = {
                  inherit binding value;
                };
              };
            };
            result =
              foldWalk
                (
                  acc: name:
                  let
                    tryAttr = builtins.tryEval (builtins.seq value.${name} value.${name});
                  in
                  if !tryAttr.success then
                    {
                      entries = [
                        {
                          inherit name;
                          value = ir.primopApp "throw" [
                            (ir.string "wechselbalg: attribute '${name}' could not be evaluated")
                          ];
                        }
                      ]
                      ++ acc.entries;
                      inherit (acc)
                        defs
                        known
                        pending
                        seen
                        ;
                    }
                  else
                    let
                      r = walkValue tryAttr.value backend acc.known seen';
                    in
                    {
                      entries = [
                        {
                          inherit name;
                          value = r.ir;
                        }
                      ]
                      ++ acc.entries;
                      defs = update acc.defs r.defs;
                      pending = r.pending ++ acc.pending;
                      known = r.known;
                      seen = r.seen;
                    }
                )
                {
                  entries = [ ];
                  defs = { };
                  pending = [ ];
                  known = bindingAlloc.known;
                  inherit seen;
                }
                names;
            orderedEntries = reverseList result.entries;
          in
          if builtins.length orderedEntries <= attrChunkSize then
            let
              attrsIR = ir.attrs (builtins.listToAttrs orderedEntries);
            in
            if result.known.used ? ${binding} then
              {
                ir = ir.ref binding;
                inherit (result) defs pending seen;
                known = result.known // {
                  bindings = result.known.bindings // {
                    ${binding} = attrsIR;
                  };
                };
              }
            else
              {
                ir = attrsIR;
                inherit (result)
                  defs
                  known
                  pending
                  seen
                  ;
              }
          else
            let
              chunks = chunkList attrChunkSize orderedEntries;
              chunked =
                builtins.foldl'
                  (
                    acc: chunkEntries:
                    let
                      a = alloc "__wb_set_" acc.known;
                    in
                    {
                      known = a.known // {
                        bindings = a.known.bindings // {
                          ${a.name} = ir.attrs (builtins.listToAttrs chunkEntries);
                        };
                      };
                      refs = [ (ir.ref a.name) ] ++ acc.refs;
                    }
                  )
                  {
                    known = result.known;
                    refs = [ ];
                  }
                  chunks;
              combinedIR = mergeAttrsBalanced (reverseList chunked.refs);
            in
            if chunked.known.used ? ${binding} then
              {
                ir = ir.ref binding;
                inherit (result) defs pending seen;
                known = chunked.known // {
                  bindings = chunked.known.bindings // {
                    ${binding} = combinedIR;
                  };
                };
              }
            else
              {
                ir = combinedIR;
                inherit (result) defs pending seen;
                known = chunked.known;
              }

    else if type == "lambda" then
      let
        ast = builtins.reify value;
      in
      if ast._expr == "primop" then
        {
          ir = ir.primop ast.value;
          defs = { };
          pending = [ ];
          inherit known seen;
        }
      else if ast._expr == "primopApp" then
        let
          argsResult =
            foldWalk
              (
                acc: arg:
                let
                  r = walkValue arg backend acc.known (seen // { depth = seen.depth + 1; });
                in
                {
                  args = [ r.ir ] ++ acc.args;
                  defs = update acc.defs r.defs;
                  pending = r.pending ++ acc.pending;
                  known = r.known;
                  seen = r.seen;
                }
              )
              {
                args = [ ];
                defs = { };
                pending = [ ];
                inherit known seen;
              }
              ast.value.appliedArgs;
        in
        {
          ir = ir.primopApp ast.value.primop (reverseList argsResult.args);
          inherit (argsResult)
            defs
            known
            pending
            seen
            ;
        }
      else
        let
          inFlight = findInFlight value seen.funcs;
        in
        if inFlight != null then
          {
            ir = ir.ref inFlight;
            defs = { };
            pending = [ ];
            known = markUsed inFlight known;
            inherit seen;
          }
        else
          let
            info = analyze.analyze ast;
            memo = if info.closed then null else findInstance value (known.instances.${info.key} or [ ]);
          in
          if memo != null then
            {
              ir = ir.ref memo;
              defs = { };
              pending = [ ];
              inherit known seen;
            }
          else
            let
              registered = known.templates.${info.key} or null;

              tplAlloc = if registered != null then null else alloc "__wb_tpl_" known;
              tplName = if registered != null then registered.name else tplAlloc.name;
              known1 =
                if registered != null then
                  known
                else
                  tplAlloc.known
                  // {
                    templates = tplAlloc.known.templates // {
                      ${info.key} = {
                        name = tplName;
                        inherit (info)
                          capture
                          envKeys
                          closed
                          stripped
                          ;
                      };
                    };
                  };

              newPending =
                if registered != null then
                  [ ]
                else
                  [
                    {
                      name = tplName;
                      inherit value;
                      inherit (info) key;
                      pathRoots = seen.pathRoots;
                    }
                  ];
            in
            if info.closed then
              {
                ir = ir.ref tplName;
                defs = { };
                pending = newPending;
                known = known1;
                inherit seen;
              }
            else
              let
                cloAlloc = alloc "__wb_clo_" known1;
                binding = cloAlloc.name;
                bucket = known1.instances.${info.key} or [ ];

                # Knot: register the (not-yet-filled) closure binding right away.
                # A nested walk that reaches this lambda through a cycle sees the
                # `ref` already resolvable, and if an outer walk aborts partway
                # (reified-AST eval failure), every binding allocated up to that
                # point still exists in the result — dangling refs become
                # unreferenced dead code instead of validation errors.
                known2 =
                  (
                    cloAlloc.known
                    // {
                      bindings = cloAlloc.known.bindings // {
                        ${binding} = ir.attrs { };
                      };
                    }
                  )
                  // {
                    instances = cloAlloc.known.instances // {
                      ${info.key} =
                        if builtins.length bucket >= instanceCap then
                          bucket
                        else
                          bucket
                          ++ [
                            {
                              fn = value;
                              inherit binding;
                            }
                          ];
                    };
                  };

                seen' = seen // {
                  depth = seen.depth + 1;
                  funcs = [
                    {
                      fn = value;
                      inherit binding;
                    }
                  ]
                  ++ seen.funcs;
                };

                envResult =
                  foldWalk
                    (
                      acc: key:
                      let
                        resolved = resolveCapture info.capture.entries.${key};
                        # A captured free-variable reference to `import` (the
                        # test harness passes it through the environment):
                        # reify has no AST for primops, so resolveCapture
                        # lowered it to a plain variable that is unbound at
                        # runtime. Replace it with the real primop — applying
                        # it to a runtime path value (pathValue) performs
                        # `importPath_()`.
                        importFallback = key == "import" && info.capture.mode.${key} or null == "whole";
                      in
                      if !resolved.ok then
                        {
                          entries = [
                            {
                              name = key;
                              value = ir.primopApp "throw" [
                                (ir.string "wechselbalg: captured variable '${key}' could not be translated")
                              ];
                            }
                          ]
                          ++ acc.entries;
                          inherit (acc)
                            defs
                            pending
                            known
                            seen
                            ;
                        }
                      else
                        let
                          r =
                            if !importFallback then
                              walkValue resolved.value backend acc.known seen'
                            else
                              {
                                ir = ir.primop "import";
                                defs = { };
                                pending = [ ];
                                known = acc.known;
                                seen = seen';
                              };
                        in
                        {
                          entries = [
                            {
                              name = key;
                              value = r.ir;
                            }
                          ]
                          ++ acc.entries;
                          defs = update acc.defs r.defs;
                          pending = r.pending ++ acc.pending;
                          known = r.known;
                          seen = r.seen;
                        }
                    )
                    {
                      entries = [ ];
                      defs = { };
                      pending = newPending;
                      known = known2;
                      inherit seen;
                    }
                    info.envKeys;

                closureIR = ir.closure tplName (builtins.listToAttrs envResult.entries);
              in
              {
                ir = ir.ref binding;
                inherit (envResult) defs pending seen;
                known = envResult.known // {
                  bindings = envResult.known.bindings // {
                    ${binding} = closureIR;
                  };
                };
              }

    else if type == "path" then
      # A path reached through a *value* position: it starts its own budgeted
      # neighbourhood only when we are not inside an import expansion. Paths
      # carried in an imported value (e.g. a `sourcePath` attribute) belong to
      # the root whose value we are currently importing — they must charge its
      # budget, never start a new root.
      walkPath value backend known seen (seen.pathRoots == [ ]) "walkValue"

    else
      throw "wechselbalg: unsupported Nix type '${type}'";

  # ── Walk a reified AST node ─────────────────────────────────────
  walkAST =
    ast: backend: known: seen:
    let
      evalResult = evaluateAST ast;
    in
    if ast._expr == "path" then
      # Paths need a dedicated lowering (fs metadata is recorded at
      # translation time), and `evaluateAST` would only yield the path as a
      # plain string — so this case must be matched before the eval fast-path.
      # An inline path literal in program source is a root reference; one that
      # appears inside a value currently being imported charges that root.
      walkPath ast.value backend known seen (seen.pathRoots == [ ]) "ast-path-early"
    else if ast._expr == "call" && evalResult ? pathImport then
      # `import <known-path>`: register the path (fs record + translated value)
      # and emit a runtime path value; applying it is exactly `importPath_()`.
      # evalAST keeps the argument as an evaluated attrset (`{ _type = "path"; … }`).
      # The path belongs to whichever root expansion we are inside of (or
      # starts its own when reached outside any import). Extra arguments apply
      # to the imported value at runtime.
      let
        pv = evalResult.pathValue;
        p = walkPath (if pv ? value then pv.value else pv) backend known seen (
          seen.pathRoots == [ ]
        ) "ast-import";
        rest = evalResult.restArgs or [ ];
      in
      if rest == [ ] then
        {
          ir = ir.primopApp "import" [ p.ir ];
          inherit (p)
            defs
            pending
            known
            seen
            ;
        }
      else
        let
          argsResult =
            foldWalk
              (
                acc: arg:
                let
                  r = walkAST arg backend acc.known seen;
                in
                {
                  args = [ r.ir ] ++ acc.args;
                  defs = update acc.defs r.defs;
                  pending = r.pending ++ acc.pending;
                  known = r.known;
                  seen = r.seen;
                }
              )
              {
                args = [ ];
                inherit (p)
                  defs
                  pending
                  known
                  seen
                  ;
              }
              rest;
        in
        {
          ir = builtins.foldl' (f: a: ir.apply f a) p.importIR (reverseList argsResult.args);
          inherit (argsResult)
            defs
            known
            pending
            seen
            ;
        }
    else if
      evalResult.success
      && builtins.typeOf evalResult.value != "lambda"
      # A container whose AST contains path nodes must not go through the
      # value fast-path: its evaluated form folds back to a fromJSON literal
      # (paths degrade to plain strings, losing the fs-record registration).
      # Lower it element-by-element instead — each path child reaches walkPath.
      && !(ast._expr == "list" && astListHasPath ast.value)
      && !(ast._expr == "attrSet" && astAttrsHasPath ast.value.attrs (builtins.attrNames ast.value.attrs))
    then
      # Deep-eval fast path: the evaluated value re-walks from this node, so
      # cycle detection (sets/funcs) and the value-nesting depth must start
      # fresh here — otherwise unrelated sub-values inflate `depth` toward the
      # 500 guard or produce false cycle knots. The current path-root stack is
      # *not* per-sub-value: carry it along (a nested import's expansion
      # continues across eval boundaries). The path registry now lives in
      # `known`, which threads through unchanged.
      # (A list/attrset containing paths has type "set" here; walkValue's
      # path branch handles its elements through walkPath.)
      walkValue evalResult.value backend known (
        emptySeen
        // {
          pathRoots = seen.pathRoots;
          pathActive = seen.pathActive;
        }
      )

    else if ast._expr == "lambda" then
      let
        nameAlloc = alloc "__wb_func_" known;
        name = nameAlloc.name;
        bodyResult = walkAST ast.value.body backend nameAlloc.known seen;
        paramsResult = walkParams ast.value.arguments backend bodyResult.known seen;
        splitBody = splitDefs (update bodyResult.defs paramsResult.defs);
      in
      {
        ir = ir.ref name;
        defs = {
          ${name} = ir.funcDef (paramsResult.params // reifyMeta ast known) bodyResult.ir splitBody.local;
        }
        // splitBody.hoistable;
        known = paramsResult.known;
        seen = paramsResult.seen;
        pending = (bodyResult.pending or [ ]) ++ paramsResult.pending;
      }

    else if ast._expr == "var" then
      if ast.value.name == "__wasm" then
        {
          ir = ir.primop "wasm";
          defs = { };
          pending = [ ];
          inherit known seen;
        }
      else if builtins.hasAttr "closureEnvValue" ast.value then
        if (known._env or null) == null then
          {
            ir = ir.var ast.value.name;
            defs = { };
            pending = [ ];
            inherit known seen;
          }
        else
          let
            env = known._env;
            mode =
              env.capture.mode.${ast.value.name}
                or (throw "wechselbalg: internal: free variable '${ast.value.name}' is missing from the capture plan; envKeys=${builtins.toString (builtins.attrNames env.capture.mode)}");
          in
          if mode != "whole" then
            throw "wechselbalg: internal: free variable '${ast.value.name}' is captured as '${mode}' but read whole"
          else
            {
              ir = ir.select (ir.var env.param) [ (ir.string ast.value.name) ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
      else
        {
          ir = ir.var ast.value.name;
          defs = { };
          pending = [ ];
          inherit known seen;
        }

    else if ast._expr == "concatString/addition" then
      let
        result =
          foldWalk
            (
              acc: operand:
              let
                r = walkAST operand backend acc.known seen;
              in
              {
                parts = [ r.ir ] ++ acc.parts;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              parts = [ ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
            ast.value;
      in
      {
        ir = ir.concatStrings (reverseList result.parts);
        inherit (result)
          defs
          known
          pending
          seen
          ;
      }
    else if ast._expr == "call" then
      let
        funcResult = walkAST ast.value.function backend known seen;
        argsResult =
          foldWalk
            (
              acc: arg:
              let
                r = walkAST arg backend acc.known seen;
              in
              {
                args = [ r.ir ] ++ acc.args;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              args = [ ];
              defs = funcResult.defs;
              pending = funcResult.pending;
              known = funcResult.known;
              seen = funcResult.seen;
            }
            ast.value.args;
        appliedIR = builtins.foldl' (fn: arg: ir.apply fn arg) funcResult.ir (reverseList argsResult.args);
      in
      {
        ir = appliedIR;
        inherit (argsResult)
          defs
          known
          pending
          seen
          ;
      }

    else if ast._expr == "if" then
      let
        condR = walkAST ast.value.condition backend known seen;
        thenR = walkAST ast.value.${"then"} backend condR.known seen;
        elseR = walkAST ast.value.${"else"} backend thenR.known seen;
      in
      {
        ir = ir.if_ condR.ir thenR.ir elseR.ir;
        defs = update (update condR.defs thenR.defs) elseR.defs;
        pending = condR.pending ++ thenR.pending ++ elseR.pending;
        known = elseR.known;
        seen = elseR.seen;
      }

    else if ast._expr == "not" then
      let
        r = walkAST ast.value backend known seen;
      in
      {
        ir = ir.not_ r.ir;
        inherit (r)
          defs
          known
          pending
          seen
          ;
      }

    else if ast._expr == "and" then
      let
        aR = walkAST ast.value.e1 backend known seen;
        bR = walkAST ast.value.e2 backend aR.known seen;
      in
      {
        ir = ir.and_ aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
        seen = bR.seen;
      }

    else if ast._expr == "or" then
      let
        aR = walkAST ast.value.e1 backend known seen;
        bR = walkAST ast.value.e2 backend aR.known seen;
      in
      {
        ir = ir.or_ aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
        seen = bR.seen;
      }

    else if ast._expr == "implies" then
      let
        aR = walkAST ast.value.e1 backend known seen;
        bR = walkAST ast.value.e2 backend aR.known seen;
      in
      {
        ir = ir.implies aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
        seen = bR.seen;
      }

    else if ast._expr == "hasAttr" then
      let
        exprR = walkAST ast.value.expression backend known seen;
        pathR =
          foldWalk
            (
              acc: p:
              let
                r = walkAST p backend acc.known seen;
              in
              {
                path = [ r.ir ] ++ acc.path;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              path = [ ];
              defs = exprR.defs;
              pending = exprR.pending;
              known = exprR.known;
              seen = exprR.seen;
            }
            ast.value.path;

        actualPath = reverseList pathR.path;
        pathLen = builtins.length actualPath;
        checks = builtins.genList (
          i:
          let
            elem = builtins.elemAt actualPath i;
            prefix = builtins.genList (j: builtins.elemAt actualPath j) i;
            base = if prefix == [ ] then exprR.ir else ir.select exprR.ir prefix;
          in
          ir.primopApp "hasAttr" [
            elem
            base
          ]
        ) pathLen;

        finalIR = builtins.foldl' (
          acc: check: if acc == null then check else ir.and_ acc check
        ) null checks;
      in
      {
        ir = finalIR;
        inherit (pathR)
          defs
          known
          pending
          seen
          ;
      }

    else if ast._expr == "equals" then
      let
        aR = walkAST ast.value.e1 backend known seen;
        bR = walkAST ast.value.e2 backend aR.known seen;
      in
      {
        ir = ir.eq aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
        seen = bR.seen;
      }

    else if ast._expr == "notEquals" then
      let
        aR = walkAST ast.value.e1 backend known seen;
        bR = walkAST ast.value.e2 backend aR.known seen;
      in
      {
        ir = ir.neq aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
        seen = bR.seen;
      }

    else if ast._expr == "update" then
      let
        baseR = walkAST ast.value.e1 backend known seen;
        extR = walkAST ast.value.e2 backend baseR.known seen;
      in
      {
        ir = ir.update baseR.ir extR.ir;
        defs = update baseR.defs extR.defs;
        pending = baseR.pending ++ extR.pending;
        known = extR.known;
        seen = extR.seen;
      }

    else if ast._expr == "concatLists" then
      let
        aR = walkAST ast.value.e1 backend known seen;
        bR = walkAST ast.value.e2 backend aR.known seen;
      in
      {
        ir = ir.concatLists aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
        seen = bR.seen;
      }

    else if ast._expr == "path" then
      walkPath ast.value backend known seen (seen.pathRoots == [ ]) "ast-path-list"

    else if ast._expr == "list" then
      let
        result =
          foldWalk
            (
              acc: elem:
              let
                r = walkAST elem backend acc.known seen;
              in
              {
                elements = [ r.ir ] ++ acc.elements;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              elements = [ ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
            ast.value;
      in
      {
        ir = ir.list (reverseList result.elements);
        inherit (result)
          defs
          known
          pending
          seen
          ;
      }

    else if ast._expr == "attrSet" then
      let
        names = builtins.attrNames ast.value.attrs;
        staticResult =
          foldWalk
            (
              acc: name:
              let
                r = walkAST ast.value.attrs.${name} backend acc.known seen;
              in
              {
                entries = [
                  {
                    inherit name;
                    value = r.ir;
                  }
                ]
                ++ acc.entries;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              entries = [ ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
            names;

        staticEntriesAttrSet = builtins.listToAttrs staticResult.entries;

        hasDynamic = ast.value.dynamicAttrs != [ ];
        hasStatic = names != [ ];
        dynamicResult =
          foldWalk
            (
              acc: dyn:
              let
                nameR = walkAST dyn.name backend acc.known seen;
                valueR = walkAST dyn.value backend nameR.known seen;
                pair = ir.primopApp "listToAttrs" [
                  (ir.list [
                    (ir.attrs {
                      name = nameR.ir;
                      value = valueR.ir;
                    })
                  ])
                ];
                guarded = ir.if_ (ir.eq nameR.ir ir.null_) (ir.attrs { }) pair;
              in
              {
                parts = [ guarded ] ++ acc.parts;
                defs = update (update acc.defs nameR.defs) valueR.defs;
                pending = nameR.pending ++ valueR.pending ++ acc.pending;
                known = valueR.known;
                seen = valueR.seen;
              }
            )
            {
              parts = [ ];
              defs = staticResult.defs;
              pending = staticResult.pending;
              known = staticResult.known;
              seen = staticResult.seen;
            }
            ast.value.dynamicAttrs;

        dynParts = reverseList dynamicResult.parts;
        dynamicIR =
          if dynParts == [ ] then
            null
          else
            builtins.foldl' ir.update (builtins.head dynParts) (builtins.tail dynParts);
      in
      if ast.value.recursive then
        let
          refs = builtins.listToAttrs (
            builtins.map (name: {
              inherit name;
              value = ir.var name;
            }) names
          );
          staticBody = ir.attrs refs;
          body = if hasDynamic then ir.update staticBody dynamicIR else staticBody;
          allDefs = if hasDynamic then dynamicResult.defs else staticResult.defs;
          allPending = if hasDynamic then dynamicResult.pending else staticResult.pending;
          finalKnown = if hasDynamic then dynamicResult.known else staticResult.known;
          finalSeen = if hasDynamic then dynamicResult.seen else staticResult.seen;
          split = splitDefs allDefs;
        in
        {
          ir = ir.let_ staticEntriesAttrSet body split.local;
          defs = split.hoistable;
          pending = allPending;
          known = finalKnown;
          seen = finalSeen;
        }
      else
        let
          staticIR = ir.attrs staticEntriesAttrSet;
          finalIR =
            if hasDynamic && hasStatic then
              ir.update staticIR dynamicIR
            else if hasDynamic then
              dynamicIR
            else
              staticIR;
          allDefs = if hasDynamic then dynamicResult.defs else staticResult.defs;
          allPending = if hasDynamic then dynamicResult.pending else staticResult.pending;
          finalKnown = if hasDynamic then dynamicResult.known else staticResult.known;
          finalSeen = if hasDynamic then dynamicResult.seen else staticResult.seen;
        in
        {
          ir = finalIR;
          defs = allDefs;
          pending = allPending;
          known = finalKnown;
          seen = finalSeen;
        }

    else if ast._expr == "select" then
      let
        sp = analyze.staticPath ast.value.path;
        narrowed =
          if
            !(builtins.hasAttr "default" ast.value)
            && sp != null
            && sp != [ ]
            && analyze.isFreeVar ast.value.expression
            && (known._env or null) != null
            && (known._env.capture.mode.${ast.value.expression.value.name} or null) == "narrow"
          then
            analyze.joinKey ast.value.expression.value.name sp
          else
            null;
      in
      if narrowed != null then
        if !(known._env.capture.entries ? ${narrowed}) then
          throw "wechselbalg: internal: narrowed capture '${narrowed}' is missing from the capture plan"
        else
          {
            ir = ir.select (ir.var known._env.param) [ (ir.string narrowed) ];
            defs = { };
            pending = [ ];
            inherit known seen;
          }
      else
        let
          exprR = walkAST ast.value.expression backend known seen;
          pathR =
            foldWalk
              (
                acc: p:
                let
                  r = walkAST p backend acc.known seen;
                in
                {
                  path = [ r.ir ] ++ acc.path;
                  defs = update acc.defs r.defs;
                  pending = r.pending ++ acc.pending;
                  known = r.known;
                  seen = r.seen;
                }
              )
              {
                path = [ ];
                defs = exprR.defs;
                pending = exprR.pending;
                known = exprR.known;
                seen = exprR.seen;
              }
              ast.value.path;

          hasDefault = builtins.hasAttr "default" ast.value;
          defaultR =
            if hasDefault then
              walkAST ast.value.default backend pathR.known seen
            else
              {
                ir = null;
                defs = { };
                pending = [ ];
                known = pathR.known;
                seen = pathR.seen;
              };

          allDefs = update pathR.defs defaultR.defs;
          allPending = pathR.pending ++ defaultR.pending;
        in
        {
          ir =
            if hasDefault then
              ir.selectOr exprR.ir (reverseList pathR.path) defaultR.ir
            else
              ir.select exprR.ir (reverseList pathR.path);
          defs = allDefs;
          pending = allPending;
          known = defaultR.known;
          seen = defaultR.seen;
        }

    else if ast._expr == "primop" then
      {
        ir = ir.primop ast.value;
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if ast._expr == "primopApp" then
      let
        argsResult =
          foldWalk
            (
              acc: arg:
              let
                r = walkValue arg backend acc.known seen;
              in
              {
                args = [ r.ir ] ++ acc.args;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              args = [ ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
            ast.value.appliedArgs;
      in
      {
        ir = ir.primopApp ast.value.primop (reverseList argsResult.args);
        inherit (argsResult)
          defs
          known
          pending
          seen
          ;
      }

    else if ast._expr == "path" then
      walkPath ast.value backend known seen (seen.pathRoots == [ ]) "ast-path-let"

    else if ast._expr == "let" then
      let
        attrs = ast.value.attrs.value.attrs;
        names = builtins.attrNames attrs;
        bindingsResult =
          foldWalk
            (
              acc: name:
              let
                r = walkAST attrs.${name} backend acc.known seen;
              in
              {
                bindings = [
                  {
                    inherit name;
                    value = r.ir;
                  }
                ]
                ++ acc.bindings;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
                seen = r.seen;
              }
            )
            {
              bindings = [ ];
              defs = { };
              pending = [ ];
              inherit known seen;
            }
            names;

        bindingsAttrSet = builtins.listToAttrs bindingsResult.bindings;
        bodyResult = walkAST ast.value.body backend bindingsResult.known seen;
        allDefs = update bindingsResult.defs bodyResult.defs;
        allPending = bindingsResult.pending ++ bodyResult.pending;
        split = splitDefs allDefs;
      in
      {
        ir = ir.let_ bindingsAttrSet bodyResult.ir split.local;
        defs = split.hoistable;
        pending = allPending;
        known = bodyResult.known;
        seen = bodyResult.seen;
      }

    else if ast._expr == "with" then
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: 'with' expressions are not supported") ];
        defs = { };
        pending = [ ];
        inherit known seen;
      }

    else if ast._expr == "assert" then
      let
        condR = walkAST ast.value.condition backend known seen;
        bodyR = walkAST ast.value.body backend condR.known seen;
      in
      {
        ir = ir.if_ condR.ir bodyR.ir (
          ir.primopApp "throw" [ (ir.string "wechselbalg: assertion failed") ]
        );
        defs = update condR.defs bodyR.defs;
        pending = condR.pending ++ bodyR.pending;
        known = bodyR.known;
        seen = bodyR.seen;
      }

    else
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: unsupported AST node '${ast._expr}'") ];
        defs = { };
        pending = [ ];
        inherit known seen;
      };

  # ── Compile one code template ───────────────────────────────────
  walkFunctionBody =
    {
      name,
      value,
      key,
      backend,
      known,
      seen,
    }:
    let
      ast = builtins.reify value;
      template = known.templates.${key};

      known' =
        (
          if template.closed then
            known // { _env = null; }
          else
            known
            // {
              _env = {
                param = envParam;
                inherit (template) capture;
              };
            }
        )
        // {
          # Clear instances so this template only memos closures created inside its own body:
          instances = { };
        };

      startCounter = known'.counter;
      priorInstances = known'.instances;
      priorUsed = known'.used;

      # Template bodies are compiled independently of the value walk, so each
      # starts with a fresh cycle-detection state — but the path-registration
      # budget is shared translation-wide: `seen` carries the accumulated
      # `paths` entries (their count/chars fields) from earlier walks.
      bodyResult = walkAST ast.value.body backend known' seen;
      paramsResult = walkParams ast.value.arguments backend bodyResult.known seen;
      # Split per phase: body-walk defs may reference bindings that only exist
      # in the function's internal `let` (path metadata, closures), so they are
      # placed inside it; parameter-default defs stay at function scope.
      splitBodyOnly = splitDefs bodyResult.defs;
      splitParamsOnly = splitDefs paramsResult.defs;
      splitBody = {
        hoistable = splitBodyOnly.hoistable // splitParamsOnly.hoistable;
        local = splitBodyOnly.local // splitParamsOnly.local;
      };

      # Bindings allocated while walking the *body* form a mutually
      # referencing set: a path record's `value` embeds captured sets and
      # closures from the same walk, and path records reached through captured
      # data (a path *value* carried in an imported file, e.g. a `patches`
      # entry) are referenced by the *shared* function definitions this walk
      # emits — refs to a *global* scope. Because the set cannot be split
      # (hoisting a closure away orphans the path record's `value`; keeping a
      # path record outer while hoisting its companion closure orphans the
      # other side), the whole set stays in outer scope (`known.bindings`),
      # where both the defs and the walk's root `let` resolve the refs.
      # Unreferenced outer bindings are pruned later by dead-code elimination.
      #
      # This is *stricter than hoisting would suggest*: an uncapped path walk
      # (see the limit comments) routinely lowers path values that live inside
      # lambda bodies, which is exactly where the knot crosses a scope
      # boundary. The old walk-time import caps kept those records rare
      # enough to ignore; with the per-root model they are common, so the
      # whole knot must move as one piece.
      hasNewBindings = false;

      newBindingNames =
        if !hasNewBindings then
          [ ]
        else
          let
            diff = paramsResult.known.counter - startCounter;
            candidateIndices = builtins.genList (i: startCounter + i) diff;
            checkIdx =
              i:
              let
                cap = "__wb_cap_${toString i}";
                clo = "__wb_clo_${toString i}";
                pmeta = "__wb_pmeta_${toString i}";
              in
              if bodyResult.known.bindings ? ${cap} then
                [ cap ]
              else if bodyResult.known.bindings ? ${clo} then
                [ clo ]
              else if bodyResult.known.bindings ? ${pmeta} then
                [ pmeta ]
              else
                [ ];
          in
          builtins.concatMap checkIdx candidateIndices;

      localBodyBindings =
        if newBindingNames == [ ] then
          { }
        else
          builtins.listToAttrs (
            builtins.map (n: {
              name = n;
              value = bodyResult.known.bindings.${n};
            }) newBindingNames
          );

      # Body-local lambdas may reference the body-scoped bindings (path
      # metadata, closures allocated during the body walk), so their defs live
      # inside the same `let`. Defs from parameter defaults stay at function
      # scope — they cannot see body-internal names.
      scopedBodyIR =
        if localBodyBindings == { } then
          bodyResult.ir
        else
          ir.let_ localBodyBindings bodyResult.ir splitBodyOnly.local;

      functionLocalDefs = if localBodyBindings == { } then splitBody.local else splitParamsOnly.local;

      innerDef = ir.funcDef (paramsResult.params // reifyMeta ast known') scopedBodyIR functionLocalDefs;

      hoisted =
        if template.closed then
          innerDef // { _hoistable = true; }
        else
          ir.funcDef
            {
              identifier = envParam;
              formals = null;
              ellipsis = true;
            }
            (ir.ref "${name}__fn")
            {
              "${name}__fn" = innerDef;
            }
          // {
            _hoistable = true;
          };

      cleanedKnown =
        # Bindings hoisted into the template's own `let` are function-local and
        # must not also exist in the outer scope. Anything else the walk
        # allocated — e.g. path metadata reached through a parameter default or
        # a reified-AST fast-path, or bindings from an aborted body walk whose
        # IR was never spliced into the function — stays in the outer scope,
        # where its `ref`s resolve. Unreferenced outer bindings are pruned
        # later by dead-code elimination.
        # Bindings allocated during one body walk form a mutually-referencing
        # set (path metadata, closures, captured sets); they move into the
        # template's local `let` *together*. Keeping some (e.g. `__wb_pmeta_*`)
        # at outer scope while moving their companions splits that set and
        # strands the `ref`s between them in the root scope.
        paramsResult.known // {
          bindings = builtins.removeAttrs paramsResult.known.bindings newBindingNames;
          instances = priorInstances;
          used = priorUsed;
        };
    in
    {
      def = {
        ${name} = hoisted;
      }
      // splitBody.hoistable;
      known = cleanedKnown;
      # Path registrations from this function's walks (budget entries) go back
      # to the queue fold so later templates share them.
      seen = paramsResult.seen;
      # Bindings allocated by the body walk: they live in the function's `let`
      # (see scopedBodyIR), so callers must NOT re-emit them at the root.
      localBindings = localBodyBindings;
      pending = (bodyResult.pending or [ ]) ++ paramsResult.pending;
    };

  # ── Top-level entry point ───────────────────────────────────────
  walk =
    backend: value:
    let
      initial = walkValue value backend {
        counter = 0;
        templates = { };
        instances = { };
        bindings = { };
        used = { };
        _env = null;
        pathReg = { };
        # Per-root record accounting: rootId -> { count, visited } (see walkPath).
        roots = { };
        # Stage 2 placeholders — set here, not yet enforced by the walker.
        emitted = 0;
        importWindow = null;
      } emptySeen;

      initialState = {
        inherit (initial) ir defs known;
        # Path registrations made by the initial value walk live in
        # `known.pathReg` / `known.roots`, which carry into template
        # compilation through the threaded `known`.
        seen = initial.seen;
        queue = initial.pending or [ ];
      };

      fuel = builtins.genList (x: x) 50000;

      finalState = builtins.foldl' (
        state: _i:
        if state.queue == [ ] then
          state
        else
          let
            item = builtins.head state.queue;
            restQueue = builtins.tail state.queue;

            compiled = walkFunctionBody {
              inherit (item) name value key;
              inherit backend;
              # Thread the full `known` (templates, pathReg, roots included):
              # template registration memoization depends on `known.templates`
              # surviving between queue steps — dropping it would re-queue the
              # same template forever.
              inherit (state) known;
              seen = state.seen // {
                pathRoots = item.pathRoots or [ ];
                # A queued template is compiled after the import that queued
                # it has returned, so no path import is active on this stack.
                pathActive = { };
              };
            };

            newDefs = update state.defs compiled.def;
            newQueue = restQueue ++ (compiled.pending or [ ]);
          in
          builtins.seq newDefs (
            builtins.seq compiled.known.counter (
              if newQueue == [ ] then
                builtins.seq newQueue state
                // {
                  defs = newDefs;
                  known = compiled.known;
                  seen = state.seen;
                  queue = [ ];
                }
              else
                {
                  inherit (state) ir;
                  defs = newDefs;
                  known = compiled.known;
                  seen = state.seen;
                  queue = newQueue;
                }
            )
          )
      ) initialState fuel;

      # Root bindings: what the initial value walk accumulated, plus anything a
      # compiled template left in the outer scope (parameter-default path
      # metadata, bindings from aborted body walks). Bindings hoisted into a
      # function's own `let` are reported via `localBindings` and excluded.
      bindings = initial.known.bindings // finalState.known.bindings;
      rootIR = if bindings == { } then finalState.ir else ir.let_ bindings finalState.ir { };

      result = {
        inherit (finalState) defs;
        ir = rootIR;
        inherit bindings;
        # Per-root path accounting: rootId -> { count = records emitted;
        # visited = set of path strings }. The renderers ignore this key;
        # tests use it to assert the record cap. See `walkPath`.
        pathStats = finalState.known.roots;
      };

      errors = validate.check result;
      shown = builtins.genList (i: builtins.elemAt errors i) (
        if builtins.length errors > 20 then 20 else builtins.length errors
      );

    in
    if finalState.queue != [ ] then
      throw "wechselbalg: exceeded fuel limit while compiling functions"
    else if errors != [ ] then
      throw ''
        wechselbalg: internal IR validation failed (${toString (builtins.length errors)} error(s)):
          ${builtins.concatStringsSep "\n  " shown}''
    else
      result;

in
walk
