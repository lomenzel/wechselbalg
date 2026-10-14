# Backend interface.
#
# A backend is an attrset conforming to this shape. The `render` function
# in this module takes a backend + walk result and produces the final string.
#
# Backend contract:
# {
#   name         : string          — e.g. "javascript"
#   extension    : string          — e.g. "js"
#   renderNode   : ir-node → string
#   renderFuncDef: name → params → bodyString → string
#   renderProgram: { defs : [string]; expr : string; } → string
#   primops      : { name = string; ... }
# }
let
  ir = import ./ir.nix;
  validate = import ./validate.nix;

  # ── Collect all primop names referenced in IR trees ─────────
  # Walks an IR node recursively; returns a flat list of primop name strings.
  collectNode =
    node:
    if node._t == "primop" then
      [ node.name ]
    else if
      node._t == "int"
      || node._t == "float"
      || node._t == "string"
      || node._t == "bool"
      || node._t == "null"
      || node._t == "ref"
      || node._t == "var"
    then
      [ ]
    else if node._t == "list" then
      builtins.concatMap collectNode node.elements
    else if node._t == "attrs" then
      builtins.concatMap (n: collectNode node.entries.${n}) (builtins.attrNames node.entries)
    else if node._t == "apply" then
      collectNode node.fn ++ collectNode node.arg
    else if node._t == "closure" then
      builtins.concatMap (n: collectNode node.env.${n}) (builtins.attrNames node.env)
    else if node._t == "if" then
      collectNode node.cond ++ collectNode node.then_ ++ collectNode node.else_
    else if node._t == "eq" then
      collectNode node.a ++ collectNode node.b
    else if node._t == "lessThan" then
      collectNode node.a ++ collectNode node.b
    else if node._t == "add" then
      collectNode node.a ++ collectNode node.b
    else if node._t == "update" then
      collectNode node.base ++ collectNode node.ext
    else if node._t == "concatLists" then
      collectNode node.a ++ collectNode node.b
    else if node._t == "select" then
      collectNode node.expr
      ++ builtins.concatMap collectNode node.path
      ++ (if node.default != null then collectNode node.default else [ ])
    else if node._t == "let" then
      builtins.concatMap (n: collectNode node.bindings.${n}) (builtins.attrNames node.bindings)
      ++ collectNode node.body
      ++ collectDefs node.localDefs
    else
      [ ];

  # Walk a funcDef (params defaults + body + localDefs).
  collectFuncDef =
    def:
    let
      fromFormals =
        if def.params.formals or null != null then
          builtins.concatMap (
            f: if f.hasDefault or false then collectNode f.default else [ ]
          ) def.params.formals
        else
          [ ];
    in
    fromFormals ++ collectNode def.body ++ collectDefs (def.localDefs or { });

  # Walk a set of funcDefs.
  collectDefs = defs: builtins.concatMap (n: collectFuncDef defs.${n}) (builtins.attrNames defs);

  # Collect all unique primop names from a walk result.
  collectPrimops =
    walkResult:
    let
      allNames = collectNode walkResult.ir ++ collectDefs walkResult.defs;
    in
    builtins.listToAttrs (
      builtins.map (n: {
        name = n;
        value = true;
      }) allNames
    );

  # ── String deduplication ────────────────────────────────────────
  # Walks the IR + defs and collects all string literal values.
  collectStringsNode =
    node:
    if node._t == "string" then
      [ node.value ]
    else if
      node._t == "int"
      || node._t == "float"
      || node._t == "bool"
      || node._t == "null"
      || node._t == "ref"
      || node._t == "var"
      || node._t == "primop"
    then
      [ ]
    else if node._t == "list" then
      builtins.concatMap collectStringsNode node.elements
    else if node._t == "attrs" then
      builtins.concatMap (n: collectStringsNode node.entries.${n}) (builtins.attrNames node.entries)
    else if node._t == "apply" then
      collectStringsNode node.fn ++ collectStringsNode node.arg
    else if node._t == "closure" then
      builtins.concatMap (n: collectStringsNode node.env.${n}) (builtins.attrNames node.env)
    else if node._t == "if" then
      collectStringsNode node.cond ++ collectStringsNode node.then_ ++ collectStringsNode node.else_
    else if node._t == "eq" then
      collectStringsNode node.a ++ collectStringsNode node.b
    else if node._t == "lessThan" then
      collectStringsNode node.a ++ collectStringsNode node.b
    else if node._t == "add" then
      collectStringsNode node.a ++ collectStringsNode node.b
    else if node._t == "update" then
      collectStringsNode node.base ++ collectStringsNode node.ext
    else if node._t == "concatLists" then
      collectStringsNode node.a ++ collectStringsNode node.b
    else if node._t == "select" then
      collectStringsNode node.expr
      ++ builtins.concatMap collectStringsNode node.path
      ++ (if node.default != null then collectStringsNode node.default else [ ])
    else if node._t == "let" then
      builtins.concatMap (n: collectStringsNode node.bindings.${n}) (builtins.attrNames node.bindings)
      ++ collectStringsNode node.body
      ++ collectStringsDefs node.localDefs
    else
      [ ];

  collectStringsFuncDef =
    def:
    let
      fromFormals =
        if def.params.formals or null != null then
          builtins.concatMap (
            f: if f.hasDefault or false then collectStringsNode f.default else [ ]
          ) def.params.formals
        else
          [ ];
    in
    fromFormals ++ collectStringsNode def.body ++ collectStringsDefs (def.localDefs or { });

  collectStringsDefs =
    defs: builtins.concatMap (n: collectStringsFuncDef defs.${n}) (builtins.attrNames defs);

  # Build a dedup map: { stringValue = varName; } for strings appearing
  # more than twice and longer than 8 characters.
  buildStringDedup =
    walkResult:
    # TODO reenable string dedup, its just a test for web-nix to disable it
    ##{};
    let
      allStrings = collectStringsNode walkResult.ir ++ collectStringsDefs walkResult.defs;
      grouped = builtins.groupBy (s: s) allStrings;
      candidates = builtins.filter (s: builtins.length grouped.${s} > 1) (builtins.attrNames grouped);
      sorted = builtins.sort (a: b: a < b) candidates;
    in
    builtins.listToAttrs (
      builtins.genList (i: {
        name = builtins.elemAt sorted i;
        value = "__wb_str_${toString i}";
      }) (builtins.length sorted)
    );

  # Render a single IR node using the backend.
  renderNode =
    backend: node:
    if node._t == "int" then
      backend.renderInt node.value
    else if node._t == "float" then
      backend.renderFloat node.value
    else if node._t == "string" then
      backend.renderString node.value
    else if node._t == "bool" then
      backend.renderBool node.value
    else if node._t == "null" then
      backend.renderNull
    else if node._t == "list" then
      backend.renderList (builtins.map (renderNode backend) node.elements)
    else if node._t == "attrs" then
      backend.renderAttrs (builtins.mapAttrs (_: renderNode backend) node.entries)
    else if node._t == "let" then
      let
        renderedBindings = builtins.mapAttrs (_: renderNode backend) node.bindings;
        renderedBody = renderNode backend node.body;
        localDefNames = builtins.attrNames node.localDefs;
        renderedLocalDefs = builtins.map (
          name: renderDef backend name node.localDefs.${name}
        ) localDefNames;
      in
      backend.renderLet renderedBindings renderedBody renderedLocalDefs localDefNames
    else if node._t == "ref" then
      backend.renderRef node.name
    else if node._t == "apply" then
      backend.renderApply (renderNode backend node.fn) (renderNode backend node.arg)
    else if node._t == "closure" then
      let
        env = backend.renderAttrs (builtins.mapAttrs (_: renderNode backend) node.env);
        tpl = backend.renderRef node.template;
      in
      if builtins.hasAttr "renderClosure" backend then
        backend.renderClosure node.template tpl env
      else
        backend.renderApply tpl env
    else if node._t == "var" then
      backend.renderVar node.name
    else if node._t == "if" then
      backend.renderIf (renderNode backend node.cond) (renderNode backend node.then_) (
        renderNode backend node.else_
      )
    else if node._t == "eq" then
      backend.renderEq (renderNode backend node.a) (renderNode backend node.b)
    else if node._t == "lessThan" then
      backend.renderLessThan (renderNode backend node.a) (renderNode backend node.b)
    else if node._t == "add" then
      backend.renderAdd (renderNode backend node.a) (renderNode backend node.b)
    else if node._t == "update" then
      backend.renderUpdate (renderNode backend node.base) (renderNode backend node.ext)
    else if node._t == "concatLists" then
      backend.renderConcatLists (renderNode backend node.a) (renderNode backend node.b)
    else if node._t == "select" then
      backend.renderSelect (renderNode backend node.expr) (builtins.map (renderNode backend) node.path) (
        if node.default != null then renderNode backend node.default else null
      )
    else if node._t == "primop" then
      let
        impl =
          if builtins.hasAttr node.name backend.primops then
            backend.primops.${node.name}
          else if builtins.hasAttr "renderUnknownPrimop" backend then
            # builtins.trace "wechselbalg warning: primop '${node.name}' is not implemented in ${backend.name} — will throw at runtime"
            (backend.renderUnknownPrimop node.name)
          else
            throw "wechselbalg: backend '${backend.name}' does not implement primop '${node.name}'";
      in
      # Backends that support `builtins.sameFunction` tag primops with their
      # name, since Nix compares primops by name rather than by identity.
      if builtins.hasAttr "renderPrimop" backend then backend.renderPrimop node.name impl else impl
    else
      throw "wechselbalg render: unknown IR node type '${node._t}'";

  # Render function parameters for a definition
  renderParams = backend: params: backend.renderParams params;

  # Render a complete function definition.
  # Pre-renders default values in formals so the backend gets strings.
  # Also renders any localDefs (nested lambdas scoped to this function).
  renderDef =
    backend: name: def:
    let
      params = def.params // {
        formals =
          if def.params.formals != null then
            builtins.map (
              f:
              f
              // {
                default = if f.hasDefault then renderNode backend f.default else null;
              }
            ) def.params.formals
          else
            null;
        # Pre-rendered environment expression for runtime `builtins.reify`.
        env = if (def.params.envIR or null) == null then null else renderNode backend def.params.envIR;
      };
      localDefNames = builtins.attrNames (def.localDefs or { });
      renderedLocalDefs = builtins.map (n: renderDef backend n def.localDefs.${n}) localDefNames;
    in
    backend.renderFuncDef name params (renderNode backend def.body) renderedLocalDefs localDefNames;

  # ── Dead Code Elimination: Reachability from rootIR ──────────
  # Collect all `ref` and `var` identifiers referenced in an IR node
  collectRefs =
    node:
    if node._t == "ref" || node._t == "var" then
      [ node.name ]
    else if node._t == "list" then
      builtins.concatMap collectRefs node.elements
    else if node._t == "attrs" then
      builtins.concatMap (n: collectRefs node.entries.${n}) (builtins.attrNames node.entries)
    else if node._t == "apply" then
      collectRefs node.fn ++ collectRefs node.arg
    else if node._t == "closure" then
      [ node.template ] ++ builtins.concatMap (n: collectRefs node.env.${n}) (builtins.attrNames node.env)
    else if node._t == "if" then
      collectRefs node.cond ++ collectRefs node.then_ ++ collectRefs node.else_
    else if
      node._t == "eq" || node._t == "add" || node._t == "lessThan" || node._t == "concatLists"
    then
      collectRefs node.a ++ collectRefs node.b
    else if node._t == "update" then
      collectRefs node.base ++ collectRefs node.ext
    else if node._t == "select" then
      collectRefs node.expr
      ++ builtins.concatMap collectRefs node.path
      ++ (if node.default != null then collectRefs node.default else [ ])
    else if node._t == "let" then
      builtins.concatMap (n: collectRefs node.bindings.${n}) (builtins.attrNames node.bindings)
      ++ collectRefs node.body
      ++ builtins.concatMap (n: collectDefRefs node.localDefs.${n}) (
        builtins.attrNames (node.localDefs or { })
      )
    else
      [ ];

  # Collect all references in a function definition (including params, body, and localDefs)
  collectDefRefs =
    def:
    let
      fromFormals =
        if def.params.formals or null != null then
          builtins.concatMap (
            f: if f.hasDefault or false then collectRefs f.default else [ ]
          ) def.params.formals
        else
          [ ];
      fromEnv = if def.params.envIR or null != null then collectRefs def.params.envIR else [ ];
      fromLocalDefs = builtins.concatMap (n: collectDefRefs def.localDefs.${n}) (
        builtins.attrNames (def.localDefs or { })
      );
    in
    fromFormals ++ fromEnv ++ collectRefs def.body ++ fromLocalDefs;

  # Transitive closure of all reachable defs starting from rootIR
  pruneDefs =
    rootIR: allDefs:
    let
      bfs =
        frontier: visited:
        if frontier == [ ] then
          visited
        else
          let
            validNames = builtins.filter (n: !(visited ? ${n}) && (allDefs ? ${n})) frontier;
            newVisited =
              visited
              // builtins.listToAttrs (
                builtins.map (n: {
                  name = n;
                  value = true;
                }) validNames
              );
            nextFrontier = builtins.concatMap (n: collectDefRefs allDefs.${n}) validNames;
          in
          if validNames == [ ] then visited else bfs nextFrontier newVisited;

      reachableSet = bfs (collectRefs rootIR) { };
    in
    builtins.intersectAttrs reachableSet allDefs;

  # ── Main entry point ────────────────────────────────────────────
  # Takes a backend and a walk result { ir; defs; } and produces
  # ── Shared collection ──────────────────────────────────────────
  # Both `render` and `renderLibrary` share the same rendering of
  # bindings, defs, and expression; only the final assembly step differs.
  prepare =
    backend: walkResult':
    let
      prunedDefs = pruneDefs walkResult'.ir walkResult'.defs;
      walkResult = walkResult' // {
        defs = prunedDefs;
      };

      validationErrors = validate.check walkResult;
    in
    if validationErrors != [ ] then
      throw ''
        wechselbalg render: dead code elimination produced dangling references (${toString (builtins.length validationErrors)} error(s)):
          ${builtins.concatStringsSep "\n  " validationErrors}''
    else
      let

        usedPrimops = collectPrimops walkResult;

        stringDedup = buildStringDedup walkResult;
        dedupBackend =
          if stringDedup == { } then
            backend
          else
            backend
            // {
              renderString =
                value:
                if builtins.hasAttr value stringDedup then
                  backend.renderVar stringDedup.${value}
                else
                  backend.renderString value;
            };

        defNames = builtins.attrNames walkResult.defs;
        renderedDefs = builtins.map (name: renderDef dedupBackend name walkResult.defs.${name}) defNames;
        renderedExpr = renderNode dedupBackend walkResult.ir;

        stringDefNames = builtins.sort (a: b: a < b) (builtins.attrValues stringDedup);
        stringDefs = builtins.listToAttrs (
          builtins.map (strValue: {
            name = stringDedup.${strValue};
            value = backend.renderString strValue;
          }) (builtins.attrNames stringDedup)
        );
      in
      {
        defs = renderedDefs;
        inherit defNames;
        expr = renderedExpr;
        inherit usedPrimops stringDefs stringDefNames;
      };

  # Main entry point — returns the rendered program as a single string.
  render = backend: walkResult: backend.renderProgram (prepare backend walkResult);

  # Library entry point — delegates to backend.renderLibrary (currently
  # only implemented by the C++ backend).  Returns an attrset of file
  # contents (see backends/cpp.nix for the shape).
  renderLibrary =
    value: backend: walkResult: libraryOpts:
    if !(builtins.hasAttr "renderLibrary" backend) then
      throw "wechselbalg: backend '${backend.name}' does not support library mode"
    else
      backend.renderLibrary (
        prepare backend walkResult
        // {
          library = libraryOpts;
          inherit value;
        }
      );
in
{
  inherit render renderLibrary renderNode;
}
