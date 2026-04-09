# Compile-time partial evaluation of reified AST nodes.
#
# Given an AST node from builtins.reify, attempts to evaluate it at Nix
# evaluation time.  Returns { success = bool; value = <nix-value>|null; }.
#
# If success == true, the node was fully resolved and `value` is a plain
# Nix value that can be lowered to an IR literal.
# If success == false, the node must be translated structurally by the walker.
#
# Adapted from gestalt's eval.nix — made standalone (no module system).

let
  hasPrefix = prefix: str:
    builtins.substring 0 (builtins.stringLength prefix) str == prefix;

  mapAttrsToList = f: attrs:
    builtins.map (name: f name attrs.${name}) (builtins.attrNames attrs);

  listToAttrs = list:
    builtins.listToAttrs list;

  eval =
    {
      _expr ? null,
      value ? throw "wechselbalg eval: missing 'value' in AST node",
      name ? "",
      ...
    }@input:
    if _expr == null then
      throw "wechselbalg eval: AST node has no _expr field"

    else if _expr == "literal" || _expr == "attrName" then
      { success = true; inherit value; }

    else if _expr == "var" then
      {
        success = builtins.hasAttr "closureEnvValue" value;
        value =
          if builtins.hasAttr "closureEnvValue" value
          then value.closureEnvValue
          else null;
      }

    else if _expr == "concatString/addition" then
      let
        operandsEval = builtins.map (o: eval o) value;
        success = builtins.all (o: o.success) operandsEval;
      in
      {
        inherit success;
        value =
          if success
          then builtins.foldl'
            (acc: curr: acc + curr.value)
            (builtins.head operandsEval).value
            (builtins.tail operandsEval)
          else null;
      }

    else if _expr == "list" then
      let
        elementsEval = builtins.map (e: eval e) value;
        success = builtins.all (e: e.success) elementsEval;
      in
      {
        inherit success;
        value = if success then builtins.map (e: e.value) elementsEval else null;
      }

    else if _expr == "lambda" then
      { success = false; value = null; }

    else if _expr == "attrSet" then
      let
        attrsEval = mapAttrsToList (name: attr: {
          inherit name;
          value = eval attr;
        }) value.attrs;
        success = builtins.all (a: a.value.success) attrsEval;
      in
      if value.dynamicAttrs != [ ] then
        { success = false; value = null; }
      else if value.recursive then
        { success = false; value = null; }
      else
        {
          inherit success;
          value =
            if success
            then listToAttrs (builtins.map (a: {
              inherit (a) name;
              inherit (a.value) value;
            }) attrsEval)
            else null;
        }

    else if _expr == "select" then
      let
        pathEval = builtins.map (p: eval p) value.path;
        exprEval = eval value.expression;
        hasDefault = builtins.hasAttr "default" value;
        defaultEval = if hasDefault then eval value.default else { success = true; value = null; };

        success =
          builtins.all (p: p.success) pathEval
          && exprEval.success
          && (hasDefault -> defaultEval.success);
      in
      {
        inherit success;
        value =
          if success then
            (builtins.foldl'
              (acc: curr:
                if !acc.continue then acc
                else if builtins.hasAttr curr.value acc.value then
                  { continue = true; value = acc.value.${curr.value}; }
                else if hasDefault then
                  { continue = false; value = defaultEval.value; }
                else
                  throw "wechselbalg eval: attribute '${curr.value}' not found"
              )
              { continue = true; value = exprEval.value; }
              pathEval
            ).value
          else null;
      }

    else if _expr == "if" then
      let
        condEval = eval value.condition;
        thenEval = eval value.${"then"};
        elseEval = eval value.${"else"};
        success =
          condEval.success
          && (condEval.value -> thenEval.success)
          && (!condEval.value -> elseEval.success);
      in
      {
        inherit success;
        value =
          if success
          then (if condEval.value then thenEval.value else elseEval.value)
          else null;
      }

    else if _expr == "let" then
      { success = false; value = null; }

    else if _expr == "with" then
      { success = false; value = null; }

    else if _expr == "call" then
      let
        funcEval = eval value.function;
        argsEval = builtins.map (e: eval e) value.args;
        success = funcEval.success && builtins.all (a: a.success) argsEval;
      in
      {
        inherit success;
        value =
          if success
          then builtins.foldl' (acc: curr: acc curr.value) funcEval.value argsEval
          else null;
      }

    else if _expr == "update" then
      let
        baseEval = eval value.e1;
        updateEval = eval value.e2;
        success = baseEval.success && updateEval.success;
      in
      {
        inherit success;
        value = if success then baseEval.value // updateEval.value else null;
      }

    else if _expr == "concatLists" then
      let
        fstEval = eval value.e1;
        sndEval = eval value.e2;
        success = fstEval.success && sndEval.success;
      in
      {
        inherit success;
        value = if success then fstEval.value ++ sndEval.value else null;
      }

    else if _expr == "not" then
      let
        exprEval = eval value;
      in
      {
        inherit (exprEval) success;
        value = if exprEval.success then !exprEval.value else null;
      }

    else if _expr == "equals" then
      let
        fstEval = eval value.e1;
        sndEval = eval value.e2;
        success = fstEval.success && sndEval.success;
      in
      {
        inherit success;
        value = if success then fstEval.value == sndEval.value else null;
      }

    else if _expr == "and" then
      let
        fstEval = eval value.e1;
        sndEval = eval value.e2;
        success = fstEval.success && sndEval.success;
      in
      {
        inherit success;
        value = if success then fstEval.value && sndEval.value else null;
      }

    else if _expr == "or" then
      let
        fstEval = eval value.e1;
        sndEval = eval value.e2;
        success = fstEval.success && sndEval.success;
      in
      {
        inherit success;
        value = if success then fstEval.value || sndEval.value else null;
      }

    else if _expr == "implies" then
      let
        fstEval = eval value.e1;
        sndEval = eval value.e2;
        success = fstEval.success && sndEval.success;
      in
      {
        inherit success;
        value = if success then fstEval.value -> sndEval.value else null;
      }

    else if _expr == "notEquals" then
      let
        fstEval = eval value.e1;
        sndEval = eval value.e2;
        success = fstEval.success && sndEval.success;
      in
      {
        inherit success;
        value = if success then fstEval.value != sndEval.value else null;
      }

    else if _expr == "path" then
      # Paths are impure — we cannot evaluate them at compile time in wechselbalg
      { success = false; value = null; }

    else if _expr == "primop" || _expr == "primopApp" then
      { success = false; value = null; }

    else
      throw "wechselbalg eval: unknown AST node type '${_expr}'";

in
  eval
