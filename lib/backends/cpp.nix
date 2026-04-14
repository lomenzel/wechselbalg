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

  hasPrefix = prefix: str: builtins.substring 0 (builtins.stringLength prefix) str == prefix;

  # Detect rendered expressions that are cheap/pure and can't fail.
  # These don't need thunk wrapping for lazy evaluation.
  # Used by renderLet (let-bindings) and renderAttrs (attrset entries).
  # Must NOT include compound values (fromSet/fromList) because
  # let-bindings may have forward references that require lazy init.
  isCheapExpr =
    str:
    hasPrefix "Value::fromInt(" str
    || hasPrefix "Value::fromFloat(" str
    || hasPrefix "Value::fromBool(" str
    || hasPrefix "Value::fromString(" str
    || str == "Value::null_()"
    || hasPrefix "(*" str
    || hasPrefix "__wb_primop_" str
    || hasPrefix "__wb_unknown_primop(" str;

  # Like isCheapExpr but also includes pure compound constructors.
  # Safe for renderApply where evaluation order doesn't matter.
  isPureExpr =
    str: isCheapExpr str || hasPrefix "Value::fromSet(" str || hasPrefix "Value::fromList(" str;

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

  cppPrimopDefs = import ../primops/cpp.nix;

  backend = {
    name = "cpp";
    extension = "cpp";

    # Unknown primops become runtime errors so translation proceeds.
    # Uses a factory function defined once in the program preamble.
    renderUnknownPrimop = name: "__wb_unknown_primop(${builtins.toJSON name})";

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "Value::fromInt(${toString value})";
    renderFloat = value: "Value::fromFloat(${builtins.toJSON value})";
    renderString = value: "Value::fromString(${builtins.toJSON value})";
    renderBool = value: "Value::fromBool(${if value then "true" else "false"})";
    renderNull = "Value::null_()";

    # ── Collections ─────────────────────────────────────────────
    renderList =
      elements:
      if builtins.length elements > 4 then
        "Value::fromList({\n${join ",\n" elements}\n})"
      else
        "Value::fromList({${join ", " elements}})";

    renderAttrs =
      entries:
      let
        names = builtins.attrNames entries;
        pairs = builtins.map (
          name:
          let
            val = entries.${name};
          in
          if isCheapExpr val then
            "{${builtins.toJSON name}, ${val}}"
          else
            "{${builtins.toJSON name}, Value::thunk([=]() -> Value {\n  return ${val};\n})}"
        ) names;
      in
      "Value::fromSet({\n${join ",\n" pairs}\n})";

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
          name:
          if isCheapExpr bindings.${name} then
            "*${sanitize name} = ${bindings.${name}};"
          else
            "*${sanitize name} = Value::thunk([=]() -> Value {\n  return ${bindings.${name}};\n});"
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
    # Arguments are thunked to emulate Nix's call-by-need semantics,
    # unless the argument is a pure expression that can't fail.
    renderApply =
      fn: arg:
      if isPureExpr arg then
        "(${fn})(${arg})"
      else
        "(${fn})(Value::thunk([=]() -> Value {\n  return ${arg};\n}))";

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
        # Formal parameters need forward declarations because defaults
        # can reference other formals in any order (Nix formals are lazy).
        identifierBinding =
          if identifier != null then
            "auto ${sanitize identifier} = std::make_shared<Value>(${paramName});"
          else
            "";

        # Check if any default expression references another formal name.
        # If so, we need the two-pass (forward-declare + assign) pattern.
        needsFwdDecl =
          formals != null
          && builtins.any (
            f:
            f.hasDefault
            && builtins.any (
              other:
              other.name != f.name && builtins.match ".*\\(\\*${sanitize other.name}\\).*" f.default != null
            ) formals
          ) formals;

        formalsFwdDecls =
          if formals != null && needsFwdDecl then
            join "\n    " (builtins.map (f: "auto ${sanitize f.name} = std::make_shared<Value>();") formals)
          else
            "";

        formalsBindings =
          if formals != null && needsFwdDecl then
            join "\n    " (
              builtins.map (
                f:
                if f.hasDefault then
                  ''
                    *${sanitize f.name} = Value::thunk([=]() -> Value {
                      try { return ${paramName}[${builtins.toJSON f.name}]; }
                      catch(...) { return ${f.default}; }
                    });
                  ''
                else
                  "*${sanitize f.name} = Value::thunk([=]() -> Value { return ${paramName}[${builtins.toJSON f.name}]; });"
              ) formals
            )
          else if formals != null then
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
            formalsFwdDecls
            formalsBindings
            ellipsisCheck
            localDefsBlock
          ]
        );

        # Build formals metadata for functionArgs support
        formalsMetadata =
          if formals != null then
            let
              entries = builtins.map (
                f: "{${builtins.toJSON f.name}, ${if f.hasDefault then "true" else "false"}}"
              ) formals;
            in
            "{${join ", " entries}}"
          else
            null;

        lambdaCtor = if formalsMetadata != null then "Value::lambdaWithFormals" else "Value::lambda";

        formalsArg = if formalsMetadata != null then ", ${formalsMetadata}" else "";

      in
      ''
        *${sanitize name} = ${lambdaCtor}([=](const Value& ${paramName}) -> Value {
          ${bindings}
          return ${bodyStr};
        }${formalsArg});
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
        usedPrimops ? { },
        stringDefs ? { },
        stringDefNames ? [ ],
      }:
      let
        # Only emit definitions for primops that are actually used
        usedKnown = builtins.filter (name: builtins.hasAttr name cppPrimopDefs) (
          builtins.attrNames usedPrimops
        );
        usedUnknown = builtins.filter (name: !(builtins.hasAttr name cppPrimopDefs)) (
          builtins.attrNames usedPrimops
        );
        primopDecls = builtins.map (
          name: "auto __wb_primop_${sanitize name} = ${cppPrimopDefs.${name}};"
        ) usedKnown;
        # Factory for unknown primops — defined once, called with name string.
        unknownFactory =
          if usedUnknown != [ ] then
            [
              ''
                auto __wb_unknown_primop = [](const std::string& name) -> Value {
                  return Value::lambda([name](const Value&) -> Value {
                    throw std::runtime_error("wechselbalg: primop '" + name + "' is not implemented in C++");
                  });
                };''
            ]
          else
            [ ];
        primopBlock = join "\n" (unknownFactory ++ primopDecls);
        # Deduplicated string constants
        stringDecls = builtins.map (
          name: "auto ${name} = std::make_shared<Value>(${stringDefs.${name}});"
        ) stringDefNames;
        hasContent = defs != [ ] || primopBlock != "" || stringDecls != [ ];
      in
      if !hasContent then
        expr
      else
        let
          fwdDecls = builtins.map (n: "auto ${sanitize n} = std::make_shared<Value>();") defNames;
          defBlock = join "\n" (stringDecls ++ fwdDecls ++ defs);
        in
        ''
          ([]() -> Value {
            ${primopBlock}
            ${defBlock}
            return ${expr};
          }())'';

    # ── Primops ─────────────────────────────────────────────────
    # Primop definitions are the full C++ lambda code.
    # Primop references (used during rendering) are just variable names.
    # renderProgram emits all primop definitions once in the preamble.
    primopDefs = cppPrimopDefs;
    primops = builtins.mapAttrs (name: _: "__wb_primop_${sanitize name}") cppPrimopDefs;
  };

in
backend
