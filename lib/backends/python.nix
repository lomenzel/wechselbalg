# Python backend for Wechselbalg.
#
# All values are wrapped in the Value class (provided by runtime/python/value.py).
# Generated code is a bare expression — no runtime included.
# Users must load the Value class themselves (available via lib.pythonRuntime).
# API mirrors the JS/C++ backends for consistency.
#
# Code generation strategy: Python lacks multi-statement IIFEs, so we use
# walrus operator (:=) inside tuple expressions to create local variables.
# Let-bindings use a dict (__wb_env) for thunked recursive scoping, then
# expose names as locals via walrus so renderRef can emit bare names.
# Requires Python 3.8+.

let
  join = sep: list: builtins.concatStringsSep sep list;

  sanitize = name:
    let
      reserved = [
        "False" "None" "True" "and" "as" "assert" "async" "await"
        "break" "class" "continue" "def" "del" "elif" "else" "except"
        "finally" "for" "from" "global" "if" "import" "in" "is"
        "lambda" "nonlocal" "not" "or" "pass" "raise" "return" "try"
        "while" "with" "yield"
        "int" "float" "str" "bool" "list" "dict" "set" "type"
        "value" "Value"
      ];
    in
    if builtins.elem name reserved
    then "__wb_r_${name}"
    else name;

  backend = {
    name = "python";
    extension = "py";

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "Value.from_int(${toString value})";
    renderFloat = value: "Value.from_float(${builtins.toJSON value})";
    renderString = value: "Value.from_string(${builtins.toJSON value})";
    renderBool = value: "Value.from_bool(${if value then "True" else "False"})";
    renderNull = "Value.null_()";

    # ── Collections ─────────────────────────────────────────────
    renderList = elements: "Value.from_list([${join ", " elements}])";

    renderAttrs = entries:
      let
        pairs = builtins.map
          (name: "${builtins.toJSON name}: ${entries.${name}}")
          (builtins.attrNames entries);
      in
      "Value.from_set({${join ", " pairs}})";

    renderRecAttrs = entries:
      let
        names = builtins.attrNames entries;
        assignments = builtins.map
          (name: "__rec.__setitem__(${builtins.toJSON name}, ${entries.${name}})")
          names;
      in
      "(lambda __rec={}: (${join ", " (assignments ++ [ "Value.from_set(__rec)" ])})[-1])()";

    # ── Laziness ────────────────────────────────────────────────
    renderThunk = body: "Value.thunk(lambda: ${body})";

    # ── Lazy attrset (entries evaluated on first access) ────────
    renderLazyAttrs = entries:
      let
        names = builtins.attrNames entries;
        pairs = builtins.map
          (name: "${builtins.toJSON name}: lambda: ${entries.${name}}")
          names;
      in
      "Value.lazy_set({${join ", " pairs}})";

    # ── Let bindings (thunked for recursive scoping) ────────────
    # Uses a dict (__wb_env) to hold thunked bindings so closures can
    # capture them before all bindings exist. Then walrus operator
    # exposes each name as a plain local for renderRef to find.
    renderLet = bindings: body: localDefs: _localDefNames:
      let
        names = builtins.attrNames bindings;
        envInit = "(__wb_env := {})";
        envAssigns = builtins.map
          (name: "__wb_env.__setitem__(${builtins.toJSON (sanitize name)}, Value.thunk(lambda: ${bindings.${name}}))")
          names;
        localBinds = builtins.map
          (name: "(${sanitize name} := __wb_env[${builtins.toJSON (sanitize name)}])")
          names;
        allParts = [ envInit ] ++ envAssigns ++ localDefs ++ localBinds ++ [ body ];
      in
      "(lambda: (${join ", " allParts})[-1])()";

    # ── References ──────────────────────────────────────────────
    renderRef = name: sanitize name;
    renderVar = name: sanitize name;

    # ── Application ─────────────────────────────────────────────
    renderApply = fn: arg: "${fn}.call(${arg})";

    # ── Control flow ────────────────────────────────────────────
    renderIf = cond: then_: else_: "(${then_} if ${cond}.as_bool() else ${else_})";

    # ── Boolean ops ─────────────────────────────────────────────
    renderNot = value: "${value}.negate()";
    renderAnd = a: b: "Value.from_bool(${a}.as_bool() and ${b}.as_bool())";
    renderOr = a: b: "Value.from_bool(${a}.as_bool() or ${b}.as_bool())";
    renderImplies = a: b: "Value.from_bool(not ${a}.as_bool() or ${b}.as_bool())";

    # ── Comparison ──────────────────────────────────────────────
    renderEq = a: b: "${a}.eq(${b})";
    renderNeq = a: b: "Value.from_bool(not Value._deep_eq(${a}, ${b}))";
    renderLessThan = a: b: "${a}.less_than(${b})";

    # ── Arithmetic ──────────────────────────────────────────────
    renderAdd = a: b: "${a}.add(${b})";
    renderSub = a: b: "${a}.sub(${b})";
    renderMul = a: b: "${a}.mul(${b})";
    renderDiv = a: b: "${a}.div(${b})";

    # ── String / collection ops ─────────────────────────────────
    renderConcatStrings = parts:
      if builtins.length parts == 0 then ''Value.from_string("")''
      else builtins.foldl'
        (acc: p: "${acc}.add(${p})")
        (builtins.head parts)
        (builtins.tail parts);

    renderUpdate = base: ext: "${base}.update(${ext})";
    renderConcatLists = a: b: "${a}.concat(${b})";

    renderSelect = expr: path: default:
      let
        access = builtins.foldl'
          (acc: p: "${acc}.get(${p})")
          expr
          path;
      in
      if default == null then
        access
      else
        "__wb_select_or(lambda: ${access}, ${default})";

    # ── Primop application ──────────────────────────────────────
    renderPrimopApp = primopCode: args:
      builtins.foldl'
        (acc: arg: "(${acc}).call(${arg})")
        "(${primopCode})"
        args;

    # ── Function definitions ────────────────────────────────────
    renderParams = params: params;

    renderFuncDef = name: params: bodyStr: localDefs: _localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        identifierBinding =
          if identifier != null
          then [ "(${sanitize identifier} := ${paramName})" ]
          else [];

        formalsBindings =
          if formals != null
          then builtins.map (f:
            if f.hasDefault
            then "(${sanitize f.name} := ${paramName}.get_or(${builtins.toJSON f.name}, ${f.default}))"
            else "(${sanitize f.name} := ${paramName}.get(${builtins.toJSON f.name}))"
          ) formals
          else [];

        ellipsisCheck =
          if formals != null && !ellipsis
          then
            let
              allowed = join ", " (builtins.map (f: builtins.toJSON f.name) formals);
            in
            [ ''[(__wb_throw(Value.from_string("wechselbalg: unexpected argument '" + __k + "'")) if True else None) for __k in ${paramName}.as_set().keys() if __k not in [${allowed}]]'' ]
          else [];

        localDefsElements = localDefs;

        allElements = identifierBinding ++ formalsBindings ++ ellipsisCheck ++ localDefsElements;
      in
      if allElements == [] then
        "(${sanitize name} := Value.lambda_(lambda ${paramName}: ${bodyStr}))"
      else
        "(${sanitize name} := Value.lambda_(lambda ${paramName}: (${join ", " (allElements ++ [ bodyStr ])})[-1]))";

    # ── Program assembly ────────────────────────────────────────
    # Bare expression. No runtime included — user provides Value class.
    # If defs exist, wrap in a self-calling lambda with walrus assignments.
    renderProgram = { defs, defNames ? [], expr }:
      if defs == [] then
        expr
      else
        "(lambda: (${join ", " (defs ++ [ expr ])})[-1])()";

    # ── Primops ─────────────────────────────────────────────────
    primops = import ../primops/python.nix;
  };

in
  backend
