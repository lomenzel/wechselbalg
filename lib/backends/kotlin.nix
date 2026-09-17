# Kotlin backend for Wechselbalg.
#
# All values are wrapped in the Value class (provided by runtime/kotlin/Value.kt).
# Generated code is a bare expression — no runtime included.
# Users must load the Value class themselves (available via lib.kotlinRuntime).
# API mirrors the JS/Python/C++ backends for consistency.

let
  join = sep: list: builtins.concatStringsSep sep list;

  sanitize =
    name:
    let
      reserved = [
        "as"
        "break"
        "class"
        "continue"
        "do"
        "else"
        "false"
        "for"
        "fun"
        "if"
        "in"
        "interface"
        "is"
        "null"
        "object"
        "package"
        "return"
        "super"
        "this"
        "throw"
        "true"
        "try"
        "typealias"
        "typeof"
        "val"
        "var"
        "when"
        "while"
        "by"
        "catch"
        "constructor"
        "delegate"
        "dynamic"
        "field"
        "file"
        "finally"
        "get"
        "import"
        "init"
        "param"
        "property"
        "receiver"
        "set"
        "setparam"
        "value"
        "where"
        "actual"
        "abstract"
        "annotation"
        "companion"
        "const"
        "crossinline"
        "data"
        "enum"
        "expect"
        "external"
        "final"
        "infix"
        "inline"
        "inner"
        "internal"
        "lateinit"
        "noinline"
        "open"
        "operator"
        "out"
        "override"
        "private"
        "protected"
        "public"
        "reified"
        "sealed"
        "suspend"
        "tailrec"
        "vararg"
        "Int"
        "Long"
        "Double"
        "Float"
        "String"
        "Boolean"
        "List"
        "Map"
        "Set"
        "Value"
        "Array"
        "Any"
        "Unit"
        "Nothing"
        "Primops"
        "LazySetMap"
        "MergedSetMap"
      ];
      # Replace characters valid in Nix identifiers but not in Kotlin
      cleaned = builtins.replaceStrings [ "'" "-" ] [ "_q" "_h" ] name;
    in
    if builtins.elem cleaned reserved then "__wb_r_${cleaned}" else cleaned;

  backend = {
    name = "kotlin";
    extension = "kt";

    # Unknown primops become runtime errors so translation proceeds.
    renderUnknownPrimop =
      name:
      "Value.lambda { throw RuntimeException(\"wechselbalg: primop '${name}' is not implemented in Kotlin\") }";

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "Value.fromInt(${toString value}L)";
    renderFloat = value: "Value.fromFloat(${builtins.toJSON value})";
    renderString =
      value:
      let
        # In Kotlin string literals, $ starts string interpolation, so escape it as \$
        escaped = builtins.replaceStrings [ "$" ] [ "\\$" ] (builtins.toJSON value);
      in
      "Value.fromString(${escaped})";
    renderBool = value: "Value.fromBool(${if value then "true" else "false"})";
    renderNull = "Value.null_()";

    # ── Collections ─────────────────────────────────────────────
    renderList = elements: "Value.fromList(listOf(${join ", " elements}))";

    renderAttrs =
      entries:
      let
        names = builtins.attrNames entries;
        pairs = builtins.map (name: "${builtins.toJSON name} to { ${entries.${name}} }") names;
      in
      "Value.lazySet(mapOf(${join ", " pairs}))";

    # ── Let bindings (thunked for recursive scoping) ────────────
    renderLet =
      bindings: body: localDefs: localDefNames:
      let
        names = builtins.attrNames bindings;
        allVarNames = names ++ localDefNames;
        decls = builtins.map (name: "var ${sanitize name}: Value = Value.null_()") allVarNames;
        defsBlock = if localDefs == [ ] then "" else join "\n  " localDefs;
        assigns = builtins.map (name: "${sanitize name} = Value.thunk { ${bindings.${name}} }") names;
        lines = builtins.filter (s: s != "") [
          (join "\n  " decls)
          defsBlock
          (join "\n  " assigns)
          body
        ];
      in
      ''
        (run {
          ${join "\n  " lines}
        })'';

    # ── References ──────────────────────────────────────────────
    renderRef = name: sanitize name;
    renderVar = name: sanitize name;

    # ── Application ─────────────────────────────────────────────
    renderApply = fn: arg: "${fn}.call(Value.thunk { ${arg} })";

    # ── Control flow ────────────────────────────────────
    renderIf =
      cond: then_: else_:
      "(if ((${cond}).asBool()) (${then_}) else (${else_}))";

    # ── Comparison ──────────────────────────────────────────────
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
          (run {
            try { ${access} }
            catch (_: Throwable) { ${default} }
          })'';

    # ── Function definitions ────────────────────────────────────
    renderParams = params: params;

    renderFuncDef =
      name: params: bodyStr: localDefs: localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        localDecls =
          if localDefNames == [ ] then
            ""
          else
            join "\n  " (builtins.map (n: "var ${sanitize n}: Value = Value.null_()") localDefNames);

        identifierBinding = if identifier != null then "val ${sanitize identifier} = ${paramName}" else "";

        formalsBindings =
          if formals != null then
            join "\n  " (
              builtins.map (
                f:
                if f.hasDefault then
                  "val ${sanitize f.name} = Value.thunk { if (${paramName}.hasAttr(${builtins.toJSON f.name})) ${paramName}.get(${builtins.toJSON f.name}) else (${f.default}) }"
                else
                  "val ${sanitize f.name} = Value.thunk { ${paramName}.get(${builtins.toJSON f.name}) }"
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
              for (__k in ${paramName}.asSet().keys) {
                if (__k !in listOf(${allowed}))
                  throw RuntimeException("wechselbalg: unexpected argument '$__k'")
              }''
          else
            "";

        localDefsBlock = if localDefs == [ ] then "" else join "\n  " localDefs;

        bindings = builtins.concatStringsSep "\n  " (
          builtins.filter (s: s != "") [
            localDecls
            identifierBinding
            formalsBindings
            ellipsisCheck
            localDefsBlock
          ]
        );

        formalsMetadata =
          if formals != null then
            let
              entries = builtins.map (
                f: "${builtins.toJSON f.name} to ${if f.hasDefault then "true" else "false"}"
              ) formals;
            in
            "mapOf(${join ", " entries})"
          else
            null;

        lambdaCtor = if formalsMetadata != null then "Value.lambdaWithFormals" else "Value.lambda";
        formalsArg = if formalsMetadata != null then ", ${formalsMetadata}" else "";
      in
      ''
        ${sanitize name} = ${lambdaCtor}({ ${paramName} ->
          ${bindings}
          ${bodyStr}
        }${formalsArg})'';

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
        stringDecls = builtins.map (name: "val ${name} = ${stringDefs.${name}}") stringDefNames;
        funcDecls = builtins.map (name: "var ${sanitize name}: Value = Value.null_()") defNames;
        allDefs = stringDecls ++ funcDecls ++ defs;
      in
      if allDefs == [ ] then
        expr
      else
        let
          defBlock = join "\n" allDefs;
        in
        ''
          run {
            ${defBlock}
            ${expr}
          }'';

    # ── Primops ─────────────────────────────────────────────────
    primops = import ../primops/kotlin.nix;
  };

in
backend
