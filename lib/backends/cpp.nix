# C++ backend for Wechselbalg.
#
# Translates IR nodes to C++ code strings.
# All values are wrapped in a `Value` type (provided by the runtime header).
#
# Memory model: all variable bindings (let-bindings, function parameters,
# function definitions) use std::shared_ptr<Value> so that closures
# (which capture by value via [=]) keep referenced Values alive even
# after the defining scope has returned.  References and variables are
# dereferenced with (*name).

let
  join = sep: list: builtins.concatStringsSep sep list;

  sanitize =
    name:
    let
      reserved = [
        "int"
        "float"
        "double"
        "char"
        "void"
        "bool"
        "class"
        "struct"
        "enum"
        "union"
        "const"
        "static"
        "extern"
        "register"
        "volatile"
        "return"
        "if"
        "else"
        "for"
        "while"
        "do"
        "switch"
        "case"
        "break"
        "continue"
        "default"
        "goto"
        "sizeof"
        "typedef"
        "namespace"
        "using"
        "template"
        "typename"
        "public"
        "private"
        "protected"
        "virtual"
        "override"
        "final"
        "new"
        "delete"
        "throw"
        "try"
        "catch"
        "operator"
        "friend"
        "inline"
        "auto"
        "nullptr"
        "true"
        "false"
        "this"
        "and"
        "or"
        "not"
      ];
      # Replace characters valid in Nix identifiers but not in C++
      cleaned = builtins.replaceStrings [ "'" "-" ] [ "_q" "_h" ] name;
    in
    if builtins.elem cleaned reserved then "__wb_rsv_${cleaned}" else cleaned;

  backend = {
    name = "cpp";
    extension = "cpp";

    # Unknown primops become runtime errors so translation proceeds.
    renderUnknownPrimop =
      name: ''
        Value::lambda([](Value) -> Value 
        { 
          throw std::runtime_error(\"wechselbalg: primop '${name}' is not implemented in C++\"); 
        })
      '';

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "Value::fromInt(${toString value})";
    renderFloat = value: "Value::fromFloat(${builtins.toJSON value})";
    renderString = value: "Value::fromString(${builtins.toJSON value})";
    renderBool = value: "Value::fromBool(${if value then "true" else "false"})";
    renderNull = "Value::null_()";

    # ── Collections ─────────────────────────────────────────────
    renderList = elements: "Value::fromList({${join ", " elements}})";

    renderAttrs =
      entries:
      let

        names = builtins.attrNames entries;
        pairs = builtins.map (
          name: "{${builtins.toJSON name}, Value::thunk([=]() -> Value { return ${entries.${name}}; })}"
        ) names;
      in
      "Value::fromSet({${join ", " pairs}})";

    # ── Let bindings (thunked for recursive scoping) ────────────
    renderLet =
      bindings: body: localDefs: localDefNames:
      let
        names = builtins.attrNames bindings;
        # All bindings and local defs are shared_ptr<Value> so closures
        # that escape this scope keep them alive.
        fwdDecls = builtins.map (name: "auto ${sanitize name} = std::make_shared<Value>();") (
          names ++ localDefNames
        );
        defsBlock = if localDefs == [ ] then [ ] else localDefs;
        assigns = builtins.map (
          name: "*${sanitize name} = Value::thunk([=]() -> Value { return ${bindings.${name}}; });"
        ) names;
        lines = fwdDecls ++ defsBlock ++ assigns;
      in
      ''
        ([=]() -> Value {
          ${join "\n  " lines}
          return ${body};
        }())'';

    # ── References ──────────────────────────────────────────────
    # All named values are shared_ptr<Value>, so dereference on use.
    renderRef = name: "(*${sanitize name})";
    renderVar = name: "(*${sanitize name})";

    # ── Application ─────────────────────────────────────────────
    renderApply = fn: arg: "(${fn})(${arg})";

    # ── Control flow ────────────────────────────────────────────
    renderIf =
      cond: then_: else_:
      "(${cond}.asBool() ? ${then_} : ${else_})";

    # ── Comparison ──────────────────────────────────────────────────
    renderEq = a: b: "Value::fromBool(${a} == ${b})";
    renderLessThan = a: b: "Value::fromBool(${a} < ${b})";

    # ── Arithmetic ──────────────────────────────────────────────
    renderAdd = a: b: "__wb_add(${a}, ${b})";

    # Collection ops
    renderUpdate = base: ext: "${base}.update(${ext})";
    renderConcatLists = a: b: "${a}.concat(${b})";

    renderSelect =
      expr: path: default:
      let
        access = join "" (builtins.map (p: "[${p}]") path);
      in
      if default == null then
        "${expr}${access}"
      else
        ''
          ([=]() -> Value {
            try { return ${expr}${access}; }
            catch(...) { return ${default}; }
          }())'';

    # ── Function definitions ────────────────────────────────────
    renderParams = params: params;

    renderFuncDef =
      name: params: bodyStr: localDefs: localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        # Parameters are shared_ptr<Value> so nested lambdas can
        # safely capture them after this call frame returns.
        identifierBinding =
          if identifier != null then
            "auto ${sanitize identifier} = std::make_shared<Value>(${paramName});"
          else
            "";

        formalsBindings =
          if formals != null then
            join "\n    " (
              builtins.map (
                f:
                if f.hasDefault then
                  ''
                    auto ${sanitize f.name} = std::make_shared<Value>(Value::thunk([=]() -> Value {
                      try { return ${paramName}[${builtins.toJSON f.name}]; }
                      catch(...) { return ${f.default}; }
                    }));
                  ''
                else
                  "auto ${sanitize f.name} = std::make_shared<Value>(Value::thunk([=]() -> Value { return ${paramName}[${builtins.toJSON f.name}]; }));"
              ) formals
            )
          else
            "";

        ellipsisCheck =
          if formals != null && !ellipsis then
            let
              checks = builtins.map (f: "_kv.first != ${builtins.toJSON f.name}") formals;
              cond = if checks == [ ] then "true" else join " && " checks;
            in
            ''
              if (${paramName}.isSet()) {
                for (const auto& _kv : ${paramName}.asSet()) {
                  if (${cond}) {
                    throw std::runtime_error("wechselbalg: unexpected argument '" + _kv.first + "'");
                  }
                }
              }
            ''
          else
            "";

        # Forward-declare local defs as shared_ptr so mutual references work
        localDefFwdDecls = builtins.map (
          n: "auto ${sanitize n} = std::make_shared<Value>();"
        ) localDefNames;
        localDefsBlock = if localDefs == [ ] then "" else join "\n    " (localDefFwdDecls ++ localDefs);

        bindings = builtins.concatStringsSep "\n    " (
          builtins.filter (s: s != "") [
            identifierBinding
            formalsBindings
            ellipsisCheck
            localDefsBlock
          ]
        );
      in
      ''
        *${sanitize name} = Value::lambda([=](Value ${paramName}) -> Value {
          ${bindings}
          return ${bodyStr};
        });
      '';

    # ── Program assembly ────────────────────────────────────────
    # Emits a bare C++ expression/block. Does NOT include headers.
    # Users must #include the wechselbalg Value header themselves.
    # Access the header via lib.cppRuntime.
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
          fwdDecls = builtins.map (n: "auto ${sanitize n} = std::make_shared<Value>();") defNames;
          defBlock = join "\n" (fwdDecls ++ defs);
        in
        ''
          ([=]() -> Value {
            ${defBlock}
            return ${expr};
          }())'';

    # ── Primops ─────────────────────────────────────────────────
    primops = import ../primops/cpp.nix;
  };

in
backend
