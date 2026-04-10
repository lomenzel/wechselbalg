# Nix backend for Wechselbalg.
#
# Translates IR nodes back to Nix code strings.
# The ultimate meta move: Nix compiling to Nix.
# Generated code is a bare Nix expression — no runtime needed.
# Values are plain Nix values (ints, strings, lists, attrsets, lambdas).

let
  join = sep: list: builtins.concatStringsSep sep list;

  sanitize = name:
    let
      reserved = [
        "assert" "else" "if" "in" "inherit" "let" "or" "rec" "then"
        "with" "import"
      ];
    in
    if builtins.elem name reserved
    then "_${name}"
    else name;

  backend = {
    name = "nix";
    extension = "nix";

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: toString value;
    renderFloat = value: builtins.toJSON value;
    renderString = value: builtins.toJSON value;
    renderBool = value: if value then "true" else "false";
    renderNull = "null";

    # ── Collections ─────────────────────────────────────────────
    renderList = elements: "[ ${join " " elements} ]";

    renderAttrs = entries:
      let
        pairs = builtins.map
          (name: "${builtins.toJSON name} = ${entries.${name}};")
          (builtins.attrNames entries);
      in
      "{ ${join " " pairs} }";
    # ── Lazy attrset (entries evaluated on first access) ────────
    # Nix attrsets are already lazy, so this is just a regular attrset.
    renderLazyAttrs = entries:
      let
        pairs = builtins.map
          (name: "${builtins.toJSON name} = ${entries.${name}};")
          (builtins.attrNames entries);
      in
      "{ ${join " " pairs} }";

    # ── Let bindings ────────────────────────────────────────────
    # Nix `let` is already recursive, no need to thunk.
    renderLet = bindings: body: localDefs: _localDefNames:
      let
        names = builtins.attrNames bindings;
        bindingLines = builtins.map
          (name: "${sanitize name} = ${bindings.${name}};")
          names;
        # localDefs are function definitions scoped to this let
        allLines = localDefs ++ bindingLines;
      in
      "(let ${join " " allLines} in ${body})";

    # ── References ──────────────────────────────────────────────
    renderRef = name: sanitize name;
    renderVar = name: sanitize name;

    # ── Application ─────────────────────────────────────────────
    renderApply = fn: arg: "(${fn} ${arg})";

    # ── Control flow ────────────────────────────────────────────
    renderIf = cond: then_: else_: "(if ${cond} then ${then_} else ${else_})";

    # ── Comparison ──────────────────────────────────────────────────
    renderEq = a: b: "(${a} == ${b})";
    renderLessThan = a: b: "(${a} < ${b})";

    # ── Arithmetic ──────────────────────────────────────────────
    renderAdd = a: b: "(${a} + ${b})";

    # Collection ops
    renderUpdate = base: ext: "(${base} // ${ext})";
    renderConcatLists = a: b: "(${a} ++ ${b})";

    renderSelect = expr: path: default:
      let
        # Path elements are rendered IR nodes (strings in Nix code).
        # For attr selection in Nix, we need a.b.c syntax, but the
        # path elements are arbitrary expressions — use lib-style access.
        access = builtins.foldl'
          (acc: p: "(builtins.getAttr ${p} ${acc})")
          expr
          path;
      in
      if default == null then
        access
      else
        "(let __v = builtins.tryEval ${access}; in if __v.success then __v.value else ${default})";

    # ── Function definitions ────────────────────────────────────
    renderParams = params: params;

    renderFuncDef = name: params: bodyStr: localDefs: _localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        # Build the formal parameter pattern
        formalsPart =
          if formals != null
          then
            let
              formalItems = builtins.map (f:
                if f.hasDefault
                then "${sanitize f.name} ? ${f.default}"
                else sanitize f.name
              ) formals;
              formalsStr = join ", " formalItems;
              ellipsisStr = if ellipsis then ", ..." else "";
            in
            "{ ${formalsStr}${ellipsisStr} }"
          else null;

        paramPattern =
          if identifier != null && formalsPart != null
          then "${sanitize identifier}@${formalsPart}"
          else if formalsPart != null
          then formalsPart
          else if identifier != null
          then sanitize identifier
          else paramName;

        localDefsBlock =
          if localDefs == [] then ""
          else join " " localDefs;

        bodyWithLocalDefs =
          if localDefs == []
          then bodyStr
          else "(let ${localDefsBlock} in ${bodyStr})";
      in
      "${sanitize name} = ${paramPattern}: ${bodyWithLocalDefs};";

    # ── Program assembly ────────────────────────────────────────
    renderProgram = { defs, defNames ? [], expr }:
      if defs == [] then
        expr
      else
        let
          defBlock = join "\n" defs;
        in
        "let\n${defBlock}\nin ${expr}";

    # ── Primops ─────────────────────────────────────────────────
    primops = import ../primops/nix.nix;
  };

in
  backend
