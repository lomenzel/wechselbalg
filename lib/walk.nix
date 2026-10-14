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

let
  ir = import ./ir.nix;
  evaluateAST = import ./eval.nix;
  purity = import ./purity.nix;
  util = import ./util.nix;
  validate = import ./validate.nix;
  analyze = import ./analyze.nix;

  # Name of the environment parameter of a code template.  Deliberately not
  # `__wb_env`: the Python backend uses that identifier for its let-scope dict.
  envParam = "__wb_cenv";

  emptySeen = {
    sets = { };
    funcs = [ ];
    depth = 0;
  };

  # Strict fold for accumulator walks. `builtins.foldl'` only forces the
  # accumulator to WHNF (the outer attribute set), never its inner fields, so
  # `update acc.defs ...` and `acc.known` build deep thunk chains that cascade-
  # force on unwind and blow the C++ call stack. This forces the fields we
  # actually thread through so each step is fully evaluated before the next.
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
    ) init list;

  # ── Merge helper ────────────────────────────────────────────────
  # TODO maybe lower this at ir level to simplify backends
  update = a: b: a // b;

  # ── Split defs by hoistability ──────────────────────────────────
  # Separates defs into { hoistable; local; }.
  # Hoistable defs (from walkValue — fully self-contained, closure vars
  # resolved) can safely propagate out of let/lambda scopes.
  # Local defs (from walkAST — may reference scope-bound variables by
  # name) must stay in their enclosing scope.
  # ── Split defs by hoistability ──────────────────────────────────
  splitDefs =
    defs:
    let
      names = builtins.attrNames defs;

      # Separate names into hoistable and local
      hoistableNames = builtins.filter (name: defs.${name}._hoistable or false) names;
      localNames = builtins.filter (name: !(defs.${name}._hoistable or false)) names;

      # Build the attrsets flatly to avoid deep '//' Proxy chains in JS
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
  # `ast` is the stripped AST of the lambda; `envIR` evaluates, at the point
  # the definition is emitted, to the attrset from which the free variables
  # marked in that AST can be read.  Template captures come from the template
  # environment, everything else from the enclosing generated scope.
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
  # Formal defaults are ASTs, so walking them can discover nested lambdas.
  # Their defs/pending/known must be threaded out, not dropped.
  walkParams =
    arguments: known:
    let
      identifier = arguments.identifier or null;
      ellipsis = if builtins.hasAttr "ellipsis" arguments then arguments.ellipsis else true;
    in
    if !(builtins.hasAttr "formals" arguments) then
      {
        params = {
          inherit identifier ellipsis;
          formals = null;
        };
        defs = { };
        pending = [ ];
        inherit known;
      }
    else
      let
        result =
          foldWalk
            (
              acc: f:
              if builtins.hasAttr "defaultExpr" f then
                let
                  r = walkAST f.defaultExpr acc.known;
                in
                {
                  formals = acc.formals ++ [
                    {
                      inherit (f) name;
                      hasDefault = true;
                      default = r.ir;
                    }
                  ];
                  defs = update acc.defs r.defs;
                  pending = acc.pending ++ r.pending;
                  known = r.known;
                }
              else
                {
                  formals = acc.formals ++ [
                    {
                      inherit (f) name;
                      hasDefault = false;
                      default = null;
                    }
                  ];
                  inherit (acc) defs pending known;
                }
            )
            {
              formals = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            arguments.formals;
      in
      {
        params = {
          inherit identifier ellipsis;
          inherit (result) formals;
        };
        inherit (result) defs pending known;
      };

  # ── Name allocation ─────────────────────────────────────────────
  # A single monotonic counter in `known` is the only allocator, so names are
  # unique by construction and allocation is O(1).
  alloc = prefix: known: {
    name = "${prefix}${toString known.counter}";
    known = known // {
      counter = known.counter + 1;
    };
  };

  # Mark a top-level binding as actually referenced.  A binding that is never
  # marked is inlined at its single use site instead of being emitted.
  markUsed =
    name: known:
    known
    // {
      used = known.used // {
        ${name} = true;
      };
    };

  # ── Cycle detection over the current walk path ──────────────────
  # `sameFunction` is scanned only against the in-flight ancestor chain, never
  # against a global table, so this is O(depth) rather than O(all closures).
  findInFlight =
    fn: funcs:
    builtins.foldl' (
      acc: e:
      if acc != null then
        acc
      else if builtins.sameFunction fn e.fn then
        e.binding
      else
        null
    ) null funcs;

  # ── Instance memo ───────────────────────────────────────────────
  # Without this, a closure reachable through two different environment
  # entries is walked once per path, so a shared value *graph* is traversed as
  # a *tree* — exponential in its depth.
  #
  # The memo is bucketed by template key, which is exact syntactic identity,
  # so a bucket only ever holds instances of one source lambda and the scan is
  # short.  The cap bounds templates that are instantiated once per data item
  # (thousands of them, essentially never revisited) and would otherwise make
  # the scan quadratic; those still terminate via `findInFlight`.
  instanceCap = 64;

  findInstance =
    fn: instances:
    builtins.foldl' (
      acc: e:
      if acc != null then
        acc
      else if builtins.sameFunction fn e.fn then
        e.binding
      else
        null
    ) null instances;

  # Confirm a fingerprint match between two attrsets by comparing the first
  # function-valued attribute with `sameFunction`.
  # Returns true / false / null (inconclusive — no comparable attribute).
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
  # `entry.env` is the reified `closureEnvValue` thunk of the root variable;
  # `entry.path` is the statically narrowed selection below it.
  # Never lets an unevaluatable capture abort the whole translation.
  resolveCapture =
    entry:
    let
      r = builtins.tryEval (builtins.foldl' (acc: p: acc.${p}) entry.env entry.path);
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

  # ── Walk a Nix value (already evaluated) ────────────────────────
  # seen = {
  #   sets  : { <fingerprint> = { binding; value; }; }  ancestor attrsets
  #   funcs : [ { fn; binding; } ]                      ancestor closures
  #   depth : int                                       safety net
  # }
  walkValue =
    value: known: seen:
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
        inherit known;
      }

    else if (type == "set" || type == "list") && util.JSONOptimizable value then
      # skip walking of pure JSON-optimizable sets/lists — just emit IR converting it to String literal and parsing at runtime
      {
        ir = ir.primopApp "fromJSON" [ (ir.string (builtins.toJSON value)) ];
        defs = { };
        pending = [ ];
        inherit known;
      }
    else if type == "int" then
      {
        ir = ir.int value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "float" then
      {
        ir = ir.float value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "string" then
      {
        ir = ir.string value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "bool" then
      {
        ir = ir.bool value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "null" then
      {
        ir = ir.null_;
        defs = { };
        pending = [ ];
        inherit known;
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
                r = walkValue elem acc.known seen';
              in
              {
                elements = acc.elements ++ [ r.ir ];
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              elements = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            value;
      in
      {
        ir = ir.list result.elements;
        inherit (result) defs known pending;
      }

    else if type == "set" then
      let
        names = builtins.attrNames value;
        # Build a fingerprint that includes distinguishing string values
        # (not just key names) to avoid false-positive cycle detection
        # for structurally similar attrsets (e.g. nixpkgs type objects
        # all have the same keys but different "name" values).
        distinguishers = builtins.concatStringsSep "|" (
          builtins.filter (s: s != "") (
            builtins.map
              (
                n:
                let
                  try = builtins.tryEval (if builtins.isString value.${n} then "${n}=${value.${n}}" else "");
                in
                if try.success then try.value else ""
              )
              (
                builtins.filter (
                  n:
                  builtins.elem n [
                    "name"
                    "_type"
                    "description"
                  ]
                ) names
              )
          )
        );
        rawFingerprint =
          builtins.concatStringsSep "," names + (if distinguishers != "" then "#${distinguishers}" else "");

        # Hash fingerprints for wide sets (like licenses) to avoid 10KB attribute keys
        fingerprint =
          if builtins.length names > 10 then builtins.hashString "sha256" rawFingerprint else rawFingerprint;

        ancestor = seen.sets.${fingerprint} or null;
        # A fingerprint collision is only evidence; confirm it by comparing a
        # function-valued attribute.  `null` means we could not tell.
        confirmed = if ancestor == null then false else confirmSameSet value ancestor.value;
      in
      if ancestor != null && confirmed == true then
        # Genuine cycle confirmed by sameFunction: refer to the shared binding.
        {
          ir = ir.ref ancestor.binding;
          defs = { };
          pending = [ ];
          known = markUsed ancestor.binding known;
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
                    # O(1) prepend to list instead of O(N) attrset copying with `//`
                    entries = [
                      {
                        inherit name;
                        value = ir.primopApp "throw" [
                          (ir.string "wechselbalg: attribute '${name}' could not be evaluated")
                        ];
                      }
                    ]
                    ++ acc.entries;
                    inherit (acc) defs known pending;
                  }
                else
                  let
                    r = walkValue tryAttr.value acc.known seen';
                  in
                  {
                    # O(1) prepend to list instead of O(N) attrset copying with `//`
                    entries = [
                      {
                        inherit name;
                        value = r.ir;
                      }
                    ]
                    ++ acc.entries;
                    defs = update acc.defs r.defs;
                    pending = acc.pending ++ r.pending;
                    known = r.known;
                  }
              )
              {
                entries = [ ]; # Start with empty list
                defs = { };
                pending = [ ];
                known = bindingAlloc.known;
              }
              names;
          # Single O(N) C++ conversion to attribute set at the end
          attrsIR = ir.attrs (builtins.listToAttrs result.entries);
        in
        if result.known.used ? ${binding} then
          # Something inside referred back to us — materialise the shared binding.
          {
            ir = ir.ref binding;
            inherit (result) defs pending;
            known = result.known // {
              bindings = result.known.bindings // {
                ${binding} = attrsIR;
              };
            };
          }
        else
          {
            ir = attrsIR;
            inherit (result) defs known pending;
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
          inherit known;
        }
      else if ast._expr == "primopApp" then
        let
          argsResult =
            foldWalk
              (
                acc: arg:
                let
                  r = walkValue arg acc.known (seen // { depth = seen.depth + 1; });
                in
                {
                  args = acc.args ++ [ r.ir ];
                  defs = update acc.defs r.defs;
                  pending = acc.pending ++ r.pending;
                  known = r.known;
                }
              )
              {
                args = [ ];
                defs = { };
                pending = [ ];
                inherit known;
              }
              ast.value.appliedArgs;
        in
        {
          ir = ir.primopApp ast.value.primop argsResult.args;
          inherit (argsResult) defs known pending;
        }
      else
        let
          inFlight = findInFlight value seen.funcs;
        in
        if inFlight != null then
          # This exact closure instance is an ancestor of itself: tie the knot.
          {
            ir = ir.ref inFlight;
            defs = { };
            pending = [ ];
            known = markUsed inFlight known;
          }
        else
          let
            info = analyze.analyze ast;
            memo = if info.closed then null else findInstance value (known.instances.${info.key} or [ ]);
          in
          if memo != null then
            # Already walked this exact closure instance elsewhere in the graph.
            {
              ir = ir.ref memo;
              defs = { };
              pending = [ ];
              inherit known;
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
                    }
                  ];
            in
            if info.closed then
              # No captures: the template *is* the value. Zero allocation.
              {
                ir = ir.ref tplName;
                defs = { };
                pending = newPending;
                known = known1;
              }
            else
              let
                cloAlloc = alloc "__wb_clo_" known1;
                binding = cloAlloc.name;
                bucket = known1.instances.${info.key} or [ ];

                # Registered before the environment is walked, so a reference
                # back to this closure from inside its own environment resolves
                # to the binding instead of recursing.
                known2 = cloAlloc.known // {
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
                      in
                      if !resolved.ok then
                        {
                          entries = acc.entries // {
                            ${key} = ir.primopApp "throw" [
                              (ir.string "wechselbalg: captured variable '${key}' could not be translated")
                            ];
                          };
                          inherit (acc) defs pending known;
                        }
                      else
                        let
                          r = walkValue resolved.value acc.known seen';
                        in
                        {
                          entries = acc.entries // {
                            ${key} = r.ir;
                          };
                          defs = update acc.defs r.defs;
                          pending = acc.pending ++ r.pending;
                          known = r.known;
                        }
                    )
                    {
                      entries = { };
                      defs = { };
                      pending = newPending;
                      known = known2;
                    }
                    info.envKeys;

                closureIR = ir.closure tplName envResult.entries;
              in
              # Always materialised: the memo hands out `ir.ref binding`, and a
              # stable binding is also what makes runtime `sameFunction` agree
              # with Nix for a closure reached twice.
              {
                ir = ir.ref binding;
                inherit (envResult) defs pending;
                known = envResult.known // {
                  bindings = envResult.known.bindings // {
                    ${binding} = closureIR;
                  };
                };
              }

    else if type == "path" then
      # Paths are not supported on non-Nix targets — emit a runtime error.
      # This allows closures containing paths to still be translated as long
      # as the path itself is not accessed at runtime.
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${toString value}' cannot be translated (paths are not supported in target runtime)")
        ];
        defs = { };
        pending = [ ];
        inherit known;
      }

    else
      throw "wechselbalg: unsupported Nix type '${type}'";

  # ── Walk a reified AST node ─────────────────────────────────────
  # This handles the output of builtins.reify — the structural AST
  # of lambda bodies.  Tries compile-time eval first; falls back to
  # structural translation.
  #
  # `known._env` holds the capture plan of the template currently being
  # compiled: { param; capture; }.  Free variables are read from it; they are
  # never resolved through `closureEnvValue`, because the compiled body is
  # shared by every closure instance of the template.
  walkAST =
    ast: known:
    let
      evalResult = evaluateAST ast;
    in
    # If the AST can be fully evaluated at Nix eval time, just walk the
    # resulting value (turns it into IR literals / refs).
    if evalResult.success && builtins.typeOf evalResult.value != "lambda" then
      walkValue evalResult.value known emptySeen

    else if ast._expr == "lambda" then
      # Nested lambda inside a lambda body.  It may reference parameters of the
      # enclosing lambda, so it is never registered as a shareable template —
      # it stays a scope-local definition (invariant I6).
      let
        nameAlloc = alloc "__wb_func_" known;
        name = nameAlloc.name;
        bodyResult = walkAST ast.value.body nameAlloc.known;
        paramsResult = walkParams ast.value.arguments bodyResult.known;
        splitBody = splitDefs (update bodyResult.defs paramsResult.defs);
      in
      {
        ir = ir.ref name;
        defs = {
          ${name} = ir.funcDef (paramsResult.params // reifyMeta ast known) bodyResult.ir splitBody.local;
        }
        // splitBody.hoistable;
        known = paramsResult.known;
        pending = (bodyResult.pending or [ ]) ++ paramsResult.pending;
      }

    else if ast._expr == "var" then
      if ast.value.name == "__wasm" then
        {
          ir = ir.primop "wasm";
          defs = { };
          pending = [ ];
          inherit known;
        }
      else if builtins.hasAttr "closureEnvValue" ast.value then
        if (known._env or null) == null then
          # Fallback: if walked outside a template, emit direct variable reference
          {
            ir = ir.var ast.value.name;
            defs = { };
            pending = [ ];
            inherit known;
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
              inherit known;
            }
      else
        {
          ir = ir.var ast.value.name;
          defs = { };
          pending = [ ];
          inherit known;
        }

    else if ast._expr == "concatString/addition" then
      let
        result =
          foldWalk
            (
              acc: operand:
              let
                r = walkAST operand acc.known;
              in
              {
                parts = acc.parts ++ [ r.ir ];
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              parts = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            ast.value;
      in
      {
        ir = ir.concatStrings result.parts;
        inherit (result) defs known pending;
      }
    else if ast._expr == "call" && evalResult ? importedFn then
      let
        fnR = walkValue evalResult.importedFn known emptySeen;
        argsResult =
          foldWalk
            (
              acc: arg:
              let
                r = walkAST arg acc.known;
              in
              {
                args = acc.args ++ [ r.ir ];
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = fnR.defs;
              pending = fnR.pending;
              known = fnR.known;
            }
            evalResult.restArgs;
      in
      {
        ir = builtins.foldl' (f: a: ir.apply f a) fnR.ir argsResult.args;
        inherit (argsResult) defs known pending;
      }
    else if ast._expr == "call" then
      let
        funcResult = walkAST ast.value.function known;
        argsResult =
          foldWalk
            (
              acc: arg:
              let
                r = walkAST arg acc.known;
              in
              {
                args = acc.args ++ [ r.ir ];
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = funcResult.defs;
              pending = funcResult.pending;
              known = funcResult.known;
            }
            ast.value.args;
        # Build nested apply: f(a)(b)(c)
        appliedIR = builtins.foldl' (fn: arg: ir.apply fn arg) funcResult.ir argsResult.args;
      in
      {
        ir = appliedIR;
        inherit (argsResult) defs known pending;
      }

    else if ast._expr == "if" then
      let
        condR = walkAST ast.value.condition known;
        thenR = walkAST ast.value.${"then"} condR.known;
        elseR = walkAST ast.value.${"else"} thenR.known;
      in
      {
        ir = ir.if_ condR.ir thenR.ir elseR.ir;
        defs = update (update condR.defs thenR.defs) elseR.defs;
        pending = condR.pending ++ thenR.pending ++ elseR.pending;
        known = elseR.known;
      }

    else if ast._expr == "not" then
      let
        r = walkAST ast.value known;
      in
      {
        ir = ir.not_ r.ir;
        inherit (r) defs known pending;
      }

    else if ast._expr == "and" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.and_ aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "or" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.or_ aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "implies" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.implies aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "hasAttr" then
      # Nix `e ? a.b.c` — check whether the full attribute path exists.
      # Desugared to: hasAttr "a" e && hasAttr "b" e.a && hasAttr "c" e.a.b
      # using the existing hasAttr primop (no new IR node needed).
      let
        exprR = walkAST ast.value.expression known;
        pathR =
          foldWalk
            (
              acc: p:
              let
                r = walkAST p acc.known;
              in
              {
                path = acc.path ++ [ r.ir ];
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              path = [ ];
              defs = exprR.defs;
              pending = exprR.pending;
              known = exprR.known;
            }
            ast.value.path;

        # Build chained check: hasAttr(p0, e) && hasAttr(p1, e.p0) && ...
        checks = builtins.genList (
          i:
          let
            elem = builtins.elemAt pathR.path i;
            prefix = builtins.genList (j: builtins.elemAt pathR.path j) i;
            base = if prefix == [ ] then exprR.ir else ir.select exprR.ir prefix;
          in
          ir.primopApp "hasAttr" [
            elem
            base
          ]
        ) (builtins.length pathR.path);

        finalIR = builtins.foldl' (
          acc: check: if acc == null then check else ir.and_ acc check
        ) null checks;
      in
      {
        ir = finalIR;
        inherit (pathR) defs known pending;
      }

    else if ast._expr == "equals" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.eq aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "notEquals" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.neq aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "update" then
      let
        baseR = walkAST ast.value.e1 known;
        extR = walkAST ast.value.e2 baseR.known;
      in
      {
        ir = ir.update baseR.ir extR.ir;
        defs = update baseR.defs extR.defs;
        pending = baseR.pending ++ extR.pending;
        known = extR.known;
      }

    else if ast._expr == "concatLists" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.concatLists aR.ir bR.ir;
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "path" then
      # Paths are not supported on non-Nix targets — emit a runtime error.
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${toString ast.value}' cannot be translated (paths are not supported in target runtime)")
        ];
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if ast._expr == "list" then
      let
        result =
          foldWalk
            (
              acc: elem:
              let
                r = walkAST elem acc.known;
              in
              {
                elements = acc.elements ++ [ r.ir ];
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              elements = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            ast.value;
      in
      {
        ir = ir.list result.elements;
        inherit (result) defs known pending;
      }

    else if ast._expr == "attrSet" then
      let
        # ── Walk static attrs ──────────────────────────────────────
        names = builtins.attrNames ast.value.attrs;
        staticResult =
          foldWalk
            (
              acc: name:
              let
                r = walkAST ast.value.attrs.${name} acc.known;
              in
              {
                entries = update acc.entries {
                  ${name} = r.ir;
                };
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              entries = { };
              defs = { };
              pending = [ ];
              inherit known;
            }
            names;

        # ── Walk dynamic attrs ─────────────────────────────────────
        # Each dynamic attr has { name = <ast>; value = <ast>; }.
        # Nix silently drops entries whose name evaluates to null
        # (e.g. `{ ${null} = 1; }` yields `{}`), so each entry is
        # wrapped in `if name != null then listToAttrs [...] else {}`.
        hasDynamic = ast.value.dynamicAttrs != [ ];
        hasStatic = names != [ ];
        dynamicResult =
          foldWalk
            (
              acc: dyn:
              let
                nameR = walkAST dyn.name acc.known;
                valueR = walkAST dyn.value nameR.known;
                pair = ir.primopApp "listToAttrs" [
                  (ir.list [
                    (ir.attrs {
                      name = nameR.ir;
                      value = valueR.ir;
                    })
                  ])
                ];
                # Nix drops dynamic attrs whose name is null — guard each entry
                guarded = ir.if_ (ir.eq nameR.ir ir.null_) (ir.attrs { }) pair;
              in
              {
                parts = acc.parts ++ [ guarded ];
                defs = update (update acc.defs nameR.defs) valueR.defs;
                pending = acc.pending ++ nameR.pending ++ valueR.pending;
                known = valueR.known;
              }
            )
            {
              parts = [ ];
              defs = staticResult.defs;
              pending = staticResult.pending;
              known = staticResult.known;
            }
            ast.value.dynamicAttrs;

        # Merge all guarded dynamic entries via //
        dynamicIR = builtins.foldl' ir.update (builtins.head dynamicResult.parts) (
          builtins.tail dynamicResult.parts
        );
      in
      if ast.value.recursive then
        # Recursive attrsets: entries can reference each other by name.
        # Desugar to: let a = expr_a; b = expr_b; in lazyAttrs { a; b; }
        # The let_ bindings are thunked by the backend, so mutual references
        # resolve lazily.  The body is a lazy attrset of variable refs.
        # All defs stay local (they may reference entry-bound variables).
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
          split = splitDefs allDefs;
        in
        {
          ir = ir.let_ staticResult.entries body split.local;
          defs = split.hoistable;
          pending = allPending;
          known = finalKnown;
        }
      else
        # Non-recursive attrset inside a lambda body.
        # Use lazyAttrs so that entries referencing thunked outer variables
        # (e.g. from a let-binding or fixed-point) aren't forced prematurely.
        let
          staticIR = ir.attrs staticResult.entries;
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
        in
        {
          ir = finalIR;
          defs = allDefs;
          pending = allPending;
          known = finalKnown;
        }

    else if ast._expr == "select" then
      let
        # Path narrowing.  Mirrors analyze.nix exactly: if the capture plan
        # decided this root is reached only through static paths, read the
        # narrowed value straight out of the environment instead of capturing
        # the whole container.
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
            inherit known;
          }
      else
        let
          exprR = walkAST ast.value.expression known;
          pathR =
            foldWalk
              (
                acc: p:
                let
                  r = walkAST p acc.known;
                in
                {
                  path = acc.path ++ [ r.ir ];
                  defs = update acc.defs r.defs;
                  pending = acc.pending ++ r.pending;
                  known = r.known;
                }
              )
              {
                path = [ ];
                defs = exprR.defs;
                pending = exprR.pending;
                known = exprR.known;
              }
              ast.value.path;

          hasDefault = builtins.hasAttr "default" ast.value;
          defaultR =
            if hasDefault then
              walkAST ast.value.default pathR.known
            else
              {
                ir = null;
                defs = { };
                pending = [ ];
                known = pathR.known;
              };

          allDefs = update pathR.defs defaultR.defs;
          allPending = pathR.pending ++ defaultR.pending;
        in
        {
          ir =
            if hasDefault then ir.selectOr exprR.ir pathR.path defaultR.ir else ir.select exprR.ir pathR.path;
          defs = allDefs;
          pending = allPending;
          known = defaultR.known;
        }

    else if ast._expr == "primop" then
      {
        ir = ir.primop ast.value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if ast._expr == "primopApp" then
      let
        argsResult =
          foldWalk
            (
              acc: arg:
              let
                r = walkValue arg acc.known emptySeen;
              in
              {
                args = acc.args ++ [ r.ir ];
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            ast.value.appliedArgs;
      in
      {
        ir = ir.primopApp ast.value.primop argsResult.args;
        inherit (argsResult) defs known pending;
      }

    else if ast._expr == "path" then
      # Path expressions can't be translated — emit a runtime error
      # so the rest of the translation proceeds (the path may never
      # be accessed at runtime).
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${builtins.toJSON (ast.value or "unknown")}' cannot be translated")
        ];
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if ast._expr == "let" then
      # Nix `let` is always a recursive scope — bindings can reference
      # each other.  We emit ir.let_ so the backend thunks all bindings.
      # Scope-dependent defs (from walkAST lambdas — may reference let-bound
      # variables) stay local.  Hoistable defs (from walkValue — fully
      # self-contained) propagate out so they're visible from all references.
      let
        attrs = ast.value.attrs.value.attrs;
        names = builtins.attrNames attrs;
        bindingsResult =
          foldWalk
            (
              acc: name:
              let
                r = walkAST attrs.${name} acc.known;
              in
              {
                bindings = update acc.bindings {
                  ${name} = r.ir;
                };
                defs = update acc.defs r.defs;
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              bindings = { };
              defs = { };
              pending = [ ];
              inherit known;
            }
            names;
        bodyResult = walkAST ast.value.body bindingsResult.known;
        allDefs = update bindingsResult.defs bodyResult.defs;
        allPending = bindingsResult.pending ++ bodyResult.pending;
        split = splitDefs allDefs;
      in
      {
        ir = ir.let_ bindingsResult.bindings bodyResult.ir split.local;
        defs = split.hoistable; # Self-contained defs propagate out
        pending = allPending;
        known = bodyResult.known;
      }

    else if ast._expr == "with" then
      # 'with' is hard to translate statically — emit a runtime error.
      # In many cases the enclosing code path is never reached at runtime.
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: 'with' expressions are not supported") ];
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if ast._expr == "assert" then
      # assert condition; body → if condition then body else throw "assertion failed"
      let
        condR = walkAST ast.value.condition known;
        bodyR = walkAST ast.value.body condR.known;
      in
      {
        ir = ir.if_ condR.ir bodyR.ir (
          ir.primopApp "throw" [ (ir.string "wechselbalg: assertion failed") ]
        );
        defs = update condR.defs bodyR.defs;
        pending = condR.pending ++ bodyR.pending;
        known = bodyR.known;
      }

    else
      # Unknown AST node — emit runtime error instead of compile-time throw
      # so the rest of the translation proceeds.
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: unsupported AST node '${ast._expr}'") ];
        defs = { };
        pending = [ ];
        inherit known;
      };

  # ── Compile one code template ───────────────────────────────────
  # Templates are keyed by the stripped AST, so this runs exactly once per
  # distinct source lambda no matter how many closure instances exist.
  #
  # A template with captures is emitted as a curried definition
  #   <name> = __wb_cenv: <inner>
  # where `<inner>` is an ordinary local definition holding the real
  # parameters and body.  That reuses the existing localDefs machinery, keeps
  # `functionArgs` metadata on the inner lambda, and needs no backend support.
  # ── Compile one code template ───────────────────────────────────
  walkFunctionBody =
    {
      name,
      value,
      key,
      known,
    }:
    let
      ast = builtins.reify value;
      template = known.templates.${key};

      known' =
        if template.closed then
          known // { _env = null; }
        else
          known
          // {
            _env = {
              param = envParam;
              inherit (template) capture;
            };
          };

      # Snapshot state that must not leak out of this function's scope
      priorBindings = known'.bindings;
      priorInstances = known'.instances;
      priorUsed = known'.used;

      bodyResult = walkAST ast.value.body known';
      paramsResult = walkParams ast.value.arguments bodyResult.known;
      splitBody = splitDefs (update bodyResult.defs paramsResult.defs);

      # Isolate bindings created strictly inside this function body
      newBindingNames = builtins.filter (n: !(priorBindings ? ${n})) (
        builtins.attrNames paramsResult.known.bindings
      );
      localBodyBindings = builtins.listToAttrs (
        builtins.map (n: {
          name = n;
          value = paramsResult.known.bindings.${n};
        }) newBindingNames
      );

      # If the body created local closures/bindings, wrap the body IR in a let_
      scopedBodyIR =
        if localBodyBindings == { } then bodyResult.ir else ir.let_ localBodyBindings bodyResult.ir { };

      innerDef = ir.funcDef (paramsResult.params // reifyMeta ast known') scopedBodyIR splitBody.local;

      # The definition the rest of the program refers to by `name`.
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

      # Restore caches so local closures do not leak as unbound refs to other templates
      cleanedKnown = paramsResult.known // {
        bindings = priorBindings;
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
      pending = (bodyResult.pending or [ ]) ++ paramsResult.pending;
    };
  # ── Top-level entry point ───────────────────────────────────────
  walk =
    value:
    let
      initial = walkValue value {
        counter = 0;
        templates = { };
        instances = { };
        bindings = { };
        used = { };
        _env = null;
      } emptySeen;

      initialState = {
        inherit (initial) ir defs known;
        queue = initial.pending or [ ];
      };

      # Generates a pool of steps. Creating 50,000 ints in Nix takes ~1ms.
      fuel = builtins.genList (x: x) 50000;

      # Driven purely by C++'s for-loop: stack depth is ALWAYS 1.
      finalState = builtins.foldl' (
        state: _i:
        if state.queue == [ ] then
          state # Queue is empty: fast no-op for remaining fuel
        else
          let
            item = builtins.head state.queue;
            restQueue = builtins.tail state.queue;

            compiled = walkFunctionBody {
              inherit (item) name value key;
              inherit (state) known;
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
                  queue = [ ];
                }
              else
                {
                  inherit (state) ir;
                  defs = newDefs;
                  known = compiled.known;
                  queue = newQueue;
                }
            )
          )
      ) initialState fuel;

      bindings = finalState.known.bindings;

      # Shared captures and knotted closures become a recursive `let` around
      # the root expression.  Every backend already forward-declares and thunks
      # let bindings, so reference cycles resolve without new machinery.
      rootIR = if bindings == { } then finalState.ir else ir.let_ bindings finalState.ir { };

      result = {
        inherit (finalState) defs;
        ir = rootIR;
      };

      report =
        let
          numTemplates = toString (builtins.length (builtins.attrNames finalState.known.templates));
          numDefs = toString (builtins.length (builtins.attrNames finalState.defs));
          numShared = toString (builtins.length (builtins.attrNames bindings));
          numAllocated = toString finalState.known.counter;
        in
        if finalState.known.counter < 100 then
          "[Telemetry] templates: ${numTemplates}, defs: ${numDefs}, shared: ${numShared}, names: ${numAllocated}"
        else
          ''

            ═════════════ Wechselbalg Template Telemetry ═════════════
            Code templates   : ${numTemplates}
            Hoisted defs     : ${numDefs}
            Shared bindings  : ${numShared}
            Names allocated  : ${numAllocated}
            ══════════════════════════════════════════════════════════
          '';

      # Invariant I4: every ref/var resolves. Catches dangling hoisted
      # definitions, which otherwise only surface as runtime errors in the
      # generated target code.
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
      # builtins.trace report
      result;

in
walk
