# Nix backend for Wechselbalg.
#
# Translates IR nodes back to Nix code strings.
# The ultimate meta move: Nix compiling to Nix.
# Generated code is a bare Nix expression — no runtime needed.
# Values are plain Nix values (ints, strings, lists, attrsets, lambdas).
{ lib, pkgs, ... }:
let
  join = sep: list: builtins.concatStringsSep sep list;

  sanitize =
    name:
    let
      reserved = [
        "assert"
        "else"
        "if"
        "in"
        "inherit"
        "let"
        "or"
        "rec"
        "then"
        "with"
        "import"
      ];
    in
    if builtins.elem name reserved then "__wb_rsv_${name}" else name;

  backend = {
    name = "nix";
    extension = "nix";
    # Unknown primops fall back to builtins.<name> so translation proceeds.
    renderUnknownPrimop = name: "builtins.${name}";
    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "(${toString value})";
    renderFloat = value: "(${builtins.toJSON value})";
    renderString =
      value:
      # builtins.toJSON produces valid JSON strings, but Nix strings also
      # treat ${ as interpolation. Escape any ${ that toJSON doesn't handle.
      builtins.replaceStrings [ "\${" ] [ "\\$\{" ] (builtins.toJSON value);
    renderBool = value: if value then "true" else "false";
    renderNull = "null";

    # ── Collections ─────────────────────────────────────────────
    renderList = elements: "[ ${join " " elements} ]";

    # Nix attrsets are already lazy, so no thunking needed.
    renderAttrs =
      entries:
      let
        pairs = builtins.map (name: "${builtins.toJSON name} = ${entries.${name}};") (
          builtins.attrNames entries
        );
      in
      "{ ${join " " pairs} }";

    # ── Let bindings ────────────────────────────────────────────
    # Nix `let` is already recursive, no need to thunk.
    renderLet =
      bindings: body: localDefs: _localDefNames:
      let
        names = builtins.attrNames bindings;
        bindingLines = builtins.map (name: "${sanitize name} = ${bindings.${name}};") names;
        # localDefs are function definitions scoped to this let
        allLines = localDefs ++ bindingLines;
      in
      "(let ${join "\n" allLines}\nin ${body})";

    # ── References ──────────────────────────────────────────────
    renderRef = name: sanitize name;
    renderVar = name: sanitize name;

    # ── Application ─────────────────────────────────────────────
    renderApply = fn: arg: "(${fn} ${arg})";

    # ── Control flow ────────────────────────────────────────────
    renderIf =
      cond: then_: else_:
      "(if ${cond} then ${then_} else ${else_})";

    # ── Comparison ──────────────────────────────────────────────────
    renderEq = a: b: "(${a} == ${b})";
    renderLessThan = a: b: "(${a} < ${b})";

    # ── Arithmetic ──────────────────────────────────────────────
    renderAdd = a: b: "(${a} + ${b})";

    # Collection ops
    renderUpdate = base: ext: "(${base} // ${ext})";
    renderConcatLists = a: b: "(${a} ++ ${b})";

    renderSelect =
      expr: path: default:
      let
        # Path elements are rendered IR nodes (strings in Nix code).
        # For attr selection in Nix, we need a.b.c syntax, but the
        # path elements are arbitrary expressions — use lib-style access.
        access = builtins.foldl' (acc: p: "(builtins.getAttr ${p} ${acc})") expr path;
      in
      if default == null then
        access
      else
        # Use hasAttr checks (tryEval doesn't catch missing-attr errors in Nix).
        # Short-circuit && ensures each hasAttr only runs if the previous succeeded.
        let
          checks = builtins.genList (
            i:
            let
              pathUpTo = builtins.genList (j: builtins.elemAt path j) i;
              base = builtins.foldl' (acc: p: "(builtins.getAttr ${p} ${acc})") expr pathUpTo;
              elem = builtins.elemAt path i;
            in
            "((builtins.isAttrs ${base}) && (builtins.hasAttr ${elem} ${base}))"
          ) (builtins.length path);
          allChecks = builtins.concatStringsSep " && " checks;
        in
        "(if ${allChecks} then ${access} else ${default})";

    # ── Function definitions ────────────────────────────────────
    renderParams = params: params;

    renderFuncDef =
      name: params: bodyStr: localDefs: _localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        theArg = if identifier != null then sanitize identifier else paramName;

        # Build the formal parameter pattern
        formalsPart =
          if formals != null then
            let
              formalItems = builtins.map (
                f: if f.hasDefault then "${sanitize f.name} ? null" else sanitize f.name
              ) formals;
              formalsStr = join ", " formalItems;
              ellipsisStr = if ellipsis then if formalItems == [ ] then "..." else ", ..." else "";
            in
            "{ ${formalsStr}${ellipsisStr} }"
          else
            null;

        paramPattern = if formalsPart != null then "${formalsPart}@${theArg}" else theArg;

        formalsBindings =
          if formals != null then
            builtins.filter (s: s != "") (
              builtins.map (
                f:
                if f.hasDefault then
                  "${sanitize f.name} = if ${theArg} ? ${builtins.toJSON f.name} then ${theArg}.${builtins.toJSON f.name} else ${f.default};"
                else
                  ""
              ) formals
            )
          else
            [ ];

        localDefsBlock = if localDefs == [ ] then [ ] else localDefs;

        allLines = localDefsBlock ++ formalsBindings;

        bodyWithLocalDefs =
          if allLines == [ ] then bodyStr else "(let\n${join "\n" allLines}\nin ${bodyStr})";
      in
      "${sanitize name} = ${paramPattern}: ${bodyWithLocalDefs};";
    # ── Program assembly ────────────────────────────────────────
    renderProgram =
      {
        defs,
        defNames ? [ ],
        expr,
        stringDefs ? { },
        stringDefNames ? [ ],
        ...
      }:
      let
        stringDecls = builtins.map (name: "${name} = ${stringDefs.${name}};") stringDefNames;
        allDefs = stringDecls ++ defs;
      in
      if allDefs == [ ] then
        expr
      else
        let
          defBlock = join "\n" allDefs;
        in
        "let\n${defBlock}\nin ${expr}";

    # ── Primops ─────────────────────────────────────────────────
    primops = import ../primops/nix.nix { inherit lib pkgs; };
  };

in
backend
