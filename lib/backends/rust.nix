let
  join = sep: list: builtins.concatStringsSep sep list;

  hasPrefix = prefix: str: builtins.substring 0 (builtins.stringLength prefix) str == prefix;

  hasInfix = needle: haystack: needle == "" || builtins.length (builtins.split needle haystack) > 1;

  isCheapExpr =
    str:
    hasPrefix "Value::from_int(" str
    || hasPrefix "Value::from_float(" str
    || hasPrefix "Value::from_bool(" str
    || hasPrefix "Value::from_str(" str
    || str == "Value::null_()"
    || hasPrefix "(__wb_primop_" str
    || hasPrefix "(__wb_unknown_primop(" str;

  isPureExpr =
    str: isCheapExpr str || hasPrefix "Value::from_set(" str || hasPrefix "Value::from_list(" str;

  cleanIdent = name: builtins.replaceStrings [ "'" "-" "." ] [ "_q" "_h" "_dot_" ] name;

  sanitize =
    name:
    let
      reserved = [
        "as"
        "break"
        "const"
        "continue"
        "crate"
        "else"
        "enum"
        "extern"
        "false"
        "fn"
        "for"
        "if"
        "impl"
        "in"
        "let"
        "loop"
        "match"
        "mod"
        "move"
        "mut"
        "pub"
        "ref"
        "return"
        "self"
        "Self"
        "static"
        "struct"
        "super"
        "trait"
        "true"
        "type"
        "unsafe"
        "use"
        "where"
        "while"
        "async"
        "await"
        "dyn"
      ];
      cleaned = builtins.replaceStrings [ "'" "-" "." ] [ "_q" "_h" "_dot_" ] name;
    in
    if builtins.elem cleaned reserved then "r#${cleaned}" else cleaned;

  # Unique token delimiter
  varToken = name: "__wb_v_${builtins.replaceStrings [ "'" "-" "." ] [ "_q" "_h" "_dot_" ] name}__";

  # Extracts all variable tokens referenced anywhere inside an expression
  extractVars =
    expr:
    let
      parts = builtins.split "(__wb_v_[a-zA-Z0-9_]+__)" expr;
      matches = builtins.filter builtins.isList parts;
      tokens = builtins.map builtins.head matches;
      unique = list: builtins.foldl' (acc: x: if builtins.elem x acc then acc else acc ++ [ x ]) [ ] list;
    in
    unique tokens;

  # A variable token is declared internally if "let ${token} = ::std::rc::Rc::new" exists in the code
  isBoundIn = token: expr: hasInfix "let ${token} = ::std::rc::Rc::new" expr;

  # Filters for true free variables: used in expr, but NOT declared inside expr
  findFreeVars = expr: builtins.filter (v: !isBoundIn v expr) (extractVars expr);

  rustPrimopDefs = import ../primops/rust.nix;

  backend = {
    name = "rust";
    extension = "rs";

    renderUnknownPrimop = name: "(__wb_unknown_primop(${builtins.toJSON name}))";

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "Value::from_int(${toString value})";
    renderFloat = value: "Value::from_float(${builtins.toJSON value})";
    renderString = value: "Value::from_str(${builtins.toJSON value})";
    renderBool = value: "Value::from_bool(${if value then "true" else "false"})";
    renderNull = "Value::null_()";

    renderList = elements: "Value::from_list(vec![${join ", " elements}])";
    renderAttrs =
      entries:
      let
        names = builtins.attrNames entries;
        pairs = builtins.map (
          name:
          let
            expr = entries.${name};
          in
          if isCheapExpr expr then
            "(${builtins.toJSON name}.to_string(), ${expr})"
          else
            let
              freeVars = findFreeVars expr;
              clones = join "\n" (builtins.map (t: "let ${t} = ::std::rc::Rc::clone(&${t});") freeVars);
            in
            if freeVars == [ ] then
              "(${builtins.toJSON name}.to_string(), Value::thunk(move || { ${expr} }))"
            else
              "(${builtins.toJSON name}.to_string(), { ${clones} Value::thunk(move || { ${expr} }) })"
        ) names;
      in
      "Value::from_set(vec![${join ", " pairs}])";

    # ── Let Bindings ────────────────────────────────────────────
    renderLet =
      bindings: body: localDefs: localDefNames:
      let
        names = builtins.attrNames bindings;
        allInScope = names ++ localDefNames;

        fwdDecls = builtins.map (
          name: "let ${varToken name} = ::std::rc::Rc::new(::std::cell::RefCell::new(Value::Null));"
        ) allInScope;

        defsBlock = if localDefs == [ ] then [ ] else localDefs;

        assigns = builtins.map (
          name:
          let
            expr = bindings.${name};
            freeVars = findFreeVars expr;
            clones = join "\n" (builtins.map (t: "let ${t} = ::std::rc::Rc::clone(&${t});") freeVars);
          in
          if isCheapExpr expr then
            "*${varToken name}.borrow_mut() = ${expr};"
          else
            ''
              {
                let __wb_target = ::std::rc::Rc::clone(&${varToken name});
                ${clones}
                *__wb_target.borrow_mut() = Value::thunk(move || {
                  ${expr}
                });
              }
            ''
        ) names;

        lines = fwdDecls ++ defsBlock ++ assigns;
      in
      ''
        {
          ${join "\n  " lines}
          ${body}
        }
      '';

    # ── Variable Access ─────────────────────────────────────────
    renderRef = name: "Value::get(&${varToken name})";
    renderVar = name: "Value::get(&${varToken name})";

    # ── Function Application ────────────────────────────────────
    renderApply =
      fn: arg:
      if isCheapExpr arg then
        "(${fn}).call(${arg})"
      else
        let
          freeVars = findFreeVars arg;
          clones = join "\n" (builtins.map (t: "let ${t} = ::std::rc::Rc::clone(&${t});") freeVars);
        in
        if freeVars == [ ] then
          "(${fn}).call(Value::thunk(move || { ${arg} }))"
        else
          "(${fn}).call({ ${clones} Value::thunk(move || { ${arg} }) })";

    # ── Control Flow & Operators ────────────────────────────────
    renderIf =
      cond: then_: else_:
      "if (${cond}).as_bool() { ${then_} } else { ${else_} }";
    renderEq = a: b: "Value::from_bool((${a}).deep_eq(&(${b})))";
    renderLessThan = a: b: "Value::from_bool((${a}).lt(&(${b})))";
    renderAdd = a: b: "(${a}).add(&(${b}))";
    renderUpdate = base: ext: "(${base}).update(&(${ext}))";
    renderConcatLists = a: b: "(${a}).concat_lists(&(${b}))";

    renderSelect =
      expr: path: default:
      let
        access = join "" (builtins.map (p: ".select_attr(${p}.as_str().as_str())") path);
      in
      if default == null then
        "(${expr})${access}"
      else
        ''
          ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| {
            (${expr})${access}
          })).unwrap_or_else(|_| ${default})
        '';

    renderParams = params: params;

    # ── Function Definitions ────────────────────────────────────
    renderFuncDef =
      name: params: bodyStr: localDefs: localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        identifierBinding =
          if identifier != null then
            "let ${varToken identifier} = ::std::rc::Rc::new(::std::cell::RefCell::new(${paramName}.clone()));"
          else
            "";

        formalsFwdDecls =
          if formals != null then
            join "\n    " (
              builtins.map (
                f: "let ${varToken f.name} = ::std::rc::Rc::new(::std::cell::RefCell::new(Value::Null));"
              ) formals
            )
          else
            "";

        formalsBindings =
          if formals != null then
            join "\n    " (
              builtins.map (
                f:
                if f.hasDefault then
                  let
                    freeVars = findFreeVars f.default;
                    clones = join "\n    " (builtins.map (t: "let ${t} = ::std::rc::Rc::clone(&${t});") freeVars);
                  in
                  ''
                    {
                      let __wb_target = ::std::rc::Rc::clone(&${varToken f.name});
                      let ${paramName} = ${paramName}.clone();
                      ${clones}
                      *__wb_target.borrow_mut() = Value::thunk(move || {
                        if ${paramName}.has_attr(${builtins.toJSON f.name}) {
                          ${paramName}.select_attr(${builtins.toJSON f.name})
                        } else {
                          ${f.default}
                        }
                      });
                    }
                  ''
                else
                  ''
                    {
                      let __wb_target = ::std::rc::Rc::clone(&${varToken f.name});
                      let ${paramName} = ${paramName}.clone();
                      *__wb_target.borrow_mut() = Value::thunk(move || {
                        ${paramName}.select_attr(${builtins.toJSON f.name})
                      });
                    }
                  ''
              ) formals
            )
          else
            "";

        ellipsisCheck =
          if formals != null && !ellipsis then
            let
              checks = builtins.map (f: "k != ${builtins.toJSON f.name}") formals;
              cond = if checks == [ ] then "true" else join " && " checks;
            in
            ''
              if ${paramName}.is_set() {
                for (k, _) in ${paramName}.as_set().iter() {
                  if ${cond} {
                    panic!("wechselbalg: unexpected argument '{}'", k);
                  }
                }
              }
            ''
          else
            "";

        localDefFwdDecls =
          if localDefNames != [ ] then
            join "\n    " (
              builtins.map (
                n: "let ${varToken n} = ::std::rc::Rc::new(::std::cell::RefCell::new(Value::Null));"
              ) localDefNames
            )
          else
            "";

        localDefsBlock = if localDefs == [ ] then "" else join "\n    " localDefs;

        bindings = join "\n    " (
          builtins.filter (s: s != "") [
            identifierBinding
            formalsFwdDecls
            localDefFwdDecls
            formalsBindings
            ellipsisCheck
            localDefsBlock
          ]
        );

        astJson = params.ast or null;
        envVal = if (params.env or null) == null then "Value::null_()" else params.env;

        fullBody = bindings + "\n" + bodyStr + (if astJson != null then "\n" + envVal else "");
        freeVars = findFreeVars fullBody;

        capturePreamble = join "\n    " (
          builtins.map (v: "let ${v} = ::std::rc::Rc::clone(&${v});") freeVars
        );

        formalsMetadata =
          if formals != null then
            let
              entries = builtins.map (
                f: "(${builtins.toJSON f.name}.to_string(), ${if f.hasDefault then "true" else "false"})"
              ) formals;
            in
            "Some(vec![${join ", " entries}])"
          else
            "None";
      in
      ''
        {
          let __wb_env = ${if astJson != null then "Some(${envVal})" else "None"};
          let __wb_target = ::std::rc::Rc::clone(&${varToken name});
          ${capturePreamble}
          *__wb_target.borrow_mut() = Value::lambda_with_meta(
            move |${paramName}| {
              ${bindings}
              ${bodyStr}
            },
            ${formalsMetadata},
            ${if astJson != null then "Some(${builtins.toJSON astJson})" else "None"},
            __wb_env
          );
        }
      '';

    # ── Program Assembly ────────────────────────────────────────
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
        usedKnown = builtins.filter (name: builtins.hasAttr name rustPrimopDefs) (
          builtins.attrNames usedPrimops
        );
        usedUnknown = builtins.filter (name: !(builtins.hasAttr name rustPrimopDefs)) (
          builtins.attrNames usedPrimops
        );

        # Functions rather than local variables so closures never capture or move them
        primopDecls = builtins.map (
          name:
          "fn __wb_primop_${cleanIdent name}() -> Value { Value::primop(${builtins.toJSON name}, ${rustPrimopDefs.${name}}) }"
        ) usedKnown;

        unknownFactory =
          if usedUnknown != [ ] then
            ''
              fn __wb_unknown_primop(name: &'static str) -> Value {
                Value::primop(name, Value::lambda(move |_| {
                  panic!("wechselbalg: primop '{}' is not implemented in Rust", name);
                }))
              }
            ''
          else
            "";

        stringDecls = builtins.map (
          name: "let ${varToken name} = ::std::rc::Rc::new(::std::cell::RefCell::new(${stringDefs.${name}}));"
        ) stringDefNames;

        fwdDecls = builtins.map (
          n: "let ${varToken n} = ::std::rc::Rc::new(::std::cell::RefCell::new(Value::Null));"
        ) defNames;
      in
      ''
        {
          ${unknownFactory}
          ${join "\n  " primopDecls}
          ${join "\n  " stringDecls}
          ${join "\n  " fwdDecls}
          ${join "\n  " defs}
          ${expr}
        }
      '';

    primopDefs = rustPrimopDefs;
    primops = builtins.mapAttrs (name: _: "(__wb_primop_${cleanIdent name}())") rustPrimopDefs;
  };
in
backend
