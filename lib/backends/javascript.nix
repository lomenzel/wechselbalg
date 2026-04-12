# JavaScript backend for Wechselbalg.
#
# All values are wrapped in the Value class (provided by runtime/js/value.js).
# Generated code is a bare expression — no runtime included.
# Users must load the Value class themselves (available via lib.jsRuntime).
# API mirrors the C++ backend for consistency.

let
  join = sep: list: builtins.concatStringsSep sep list;

  sanitize =
    name:
    let
      reserved = [
        "break"
        "case"
        "catch"
        "continue"
        "debugger"
        "default"
        "delete"
        "do"
        "else"
        "finally"
        "for"
        "function"
        "if"
        "in"
        "instanceof"
        "new"
        "return"
        "switch"
        "this"
        "throw"
        "try"
        "typeof"
        "var"
        "void"
        "while"
        "with"
        "class"
        "const"
        "enum"
        "export"
        "extends"
        "import"
        "super"
        "implements"
        "interface"
        "let"
        "package"
        "private"
        "protected"
        "public"
        "static"
        "yield"
        "int"
        "float"
        "value"
        "Value"
      ];
      # Replace characters valid in Nix identifiers but not in JS
      cleaned = builtins.replaceStrings [ "'" "-" ] [ "_q" "_h" ] name;
    in
    if builtins.elem cleaned reserved then "__wb_rsv_${cleaned}" else cleaned;

  backend = {
    name = "javascript";
    extension = "js";

    # Unknown primops become runtime errors so translation proceeds.
    renderUnknownPrimop =
      name:
      "Value.lambda((...__args) => { throw new Error(\"wechselbalg: primop '${name}' is not implemented in JavaScript\"); })";

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "Value.fromInt(${toString value}n)";
    renderFloat = value: "Value.fromFloat(${builtins.toJSON value})";
    renderString = value: "Value.fromString(${builtins.toJSON value})";
    renderBool = value: "Value.fromBool(${if value then "true" else "false"})";
    renderNull = "Value.null_()";

    # ── Collections ─────────────────────────────────────────────
    renderList = elements: "Value.fromList([${join ", " elements}])";

    renderAttrs =
      entries:
      let

        names = builtins.attrNames entries;
        pairs = builtins.map (name: "${builtins.toJSON name}: () => ${entries.${name}}") names;
      in
      "Value.lazySet({${join ", " pairs}})";

    # ── Let bindings (thunked for recursive scoping) ────────────
    # localDefs: rendered function definitions scoped to this let block
    renderLet =
      bindings: body: localDefs: _localDefNames:
      let
        names = builtins.attrNames bindings;
        decl = "let ${join ", " (builtins.map sanitize names)};";
        defsBlock = if localDefs == [ ] then "" else join "\n  " localDefs;
        assigns = builtins.map (name: "${sanitize name} = Value.thunk(() => ${bindings.${name}});") names;
        lines = builtins.filter (s: s != "") [
          decl
          defsBlock
          (join "\n  " assigns)
        ];
      in
      ''
        (() => {
          ${join "\n  " lines}
          return ${body};
        })()'';

    # ── References ──────────────────────────────────────────────
    renderRef = name: sanitize name;
    renderVar = name: sanitize name;

    # ── Application ─────────────────────────────────────────────
    # Arguments are thunked to emulate Nix's call-by-need semantics.
    renderApply = fn: arg: "${fn}.call(Value.thunk(() => ${arg}))";

    # ── Control flow ────────────────────────────────────────────
    renderIf =
      cond: then_: else_:
      "(${cond}.asBool() ? ${then_} : ${else_})";

    # ── Comparison ──────────────────────────────────────────────────
    renderEq = a: b: "${a}.eq(${b})";
    renderLessThan = a: b: "${a}.lessThan(${b})";

    # ── Arithmetic ──────────────────────────────────────────────
    renderAdd = a: b: "${a}.add(${b})";

    # Collection ops
    renderUpdate = base: ext: "${base}.update(${ext})";
    renderConcatLists = a: b: "${a}.concat(${b})";

    renderSelect =
      expr: path: default:
      let
        access = builtins.foldl' (acc: p: "${acc}.get(${p})") expr path;
      in
      if default == null then
        access
      else
        ''
          (() => {
            try { return ${access}; }
            catch(_) { return ${default}; }
          })()'';

    # ── Function definitions ────────────────────────────────────
    renderParams = params: params;

    renderFuncDef =
      name: params: bodyStr: localDefs: _localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        identifierBinding =
          if identifier != null then "const ${sanitize identifier} = ${paramName};" else "";

        formalsBindings =
          if formals != null then
            join "\n  " (
              builtins.map (
                f:
                if f.hasDefault then
                  "const ${sanitize f.name} = Value.thunk(() => ${paramName}.getOr(${builtins.toJSON f.name}, ${f.default}));"
                else
                  "const ${sanitize f.name} = Value.thunk(() => ${paramName}.get(${builtins.toJSON f.name}));"
              ) formals
            )
          else
            "";

        ellipsisCheck =
          if formals != null && !ellipsis then
            let
              allowed = join ", " (builtins.map (f: builtins.toJSON f.name) formals);
            in
            ''
              for (const __k of Object.keys(${paramName}.asSet())) {
                  if (![${allowed}].includes(__k))
                    throw new Error("wechselbalg: unexpected argument '" + __k + "'");
                }''
          else
            "";

        localDefsBlock = if localDefs == [ ] then "" else join "\n  " localDefs;

        bindings = builtins.concatStringsSep "\n  " (
          builtins.filter (s: s != "") [
            identifierBinding
            formalsBindings
            ellipsisCheck
            localDefsBlock
          ]
        );
      in
      ''
        const ${sanitize name} = Value.lambda(function _${sanitize name}(${paramName}) {
          ${bindings}
          return ${bodyStr};
        });'';

    # ── Program assembly ────────────────────────────────────────
    # Bare expression. No runtime included — user provides Value class.
    # If defs exist, wrap in IIFE.
    renderProgram =
      {
        defs,
        defNames ? [ ],
        expr,
      }:
      if defs == [ ] then
        expr
      else
        let
          defBlock = join "\n" defs;
        in
        ''
          (() => {
          ${defBlock}
          return ${expr};
          })()'';

    # ── Primops ─────────────────────────────────────────────────
    primops = import ../primops/javascript.nix;
  };

in
backend
