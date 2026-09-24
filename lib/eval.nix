# Compile-time partial evaluation of reified AST nodes.
#
# Given an AST node from builtins.reify, attempts to evaluate it at Nix
# evaluation time.  Returns { success = bool; value = <nix-value>|null; }.
#
# If success == true, the node was fully resolved and `value` is a plain
# Nix value that can be lowered to an IR literal.
# If success == false, the node must be translated structurally by the walker.
#

let
  hasPrefix = prefix: str: builtins.substring 0 (builtins.stringLength prefix) str == prefix;

  mapAttrsToList = f: attrs: builtins.map (name: f name attrs.${name}) (builtins.attrNames attrs);

  listToAttrs = list: builtins.listToAttrs list;

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
      {
        success = true;
        inherit value;
      }

    else if _expr == "var" then
      # Never resolve a free variable through its `closureEnvValue`.
      # Compiled bodies are shared between every closure instance of the same
      # template, so folding one instance's captured value into the body would
      # silently miscompile all the others.
      {
        success = false;
        value = null;
      }

    else if _expr == "concatString/addition" then
      # Safe to evaluate when all operands are the same type (no mix → no uncatchable errors).
      let
        partsEval = builtins.map eval value;
        allSuccess = builtins.all (e: e.success) partsEval;
        values = builtins.map (e: e.value) partsEval;
        allStrings = allSuccess && builtins.all builtins.isString values;
        allNumbers = allSuccess && builtins.all (v: builtins.isInt v || builtins.isFloat v) values;
      in
      if allStrings then
        {
          success = true;
          value = builtins.concatStringsSep "" values;
        }
      else if allNumbers then
        {
          success = true;
          value = builtins.foldl' (a: b: a + b) 0 values;
        }
      else
        {
          success = false;
          value = null;
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
      {
        success = false;
        value = null;
      }

    else if _expr == "attrSet" then
      let
        attrsEval = mapAttrsToList (name: attr: {
          inherit name;
          value = eval attr;
        }) value.attrs;
        success = builtins.all (a: a.value.success) attrsEval;
      in
      if value.dynamicAttrs != [ ] then
        {
          success = false;
          value = null;
        }
      else if value.recursive then
        {
          success = false;
          value = null;
        }
      else
        {
          inherit success;
          value =
            if success then
              listToAttrs (
                builtins.map (a: {
                  inherit (a) name;
                  inherit (a.value) value;
                }) attrsEval
              )
            else
              null;
        }

    else if _expr == "select" then
      let
        pathEval = builtins.map (p: eval p) value.path;
        exprEval = eval value.expression;
        hasDefault = builtins.hasAttr "default" value;
        defaultEval =
          if hasDefault then
            eval value.default
          else
            {
              success = true;
              value = null;
            };

        success =
          builtins.all (p: p.success) pathEval
          && exprEval.success
          && builtins.isAttrs exprEval.value
          && (hasDefault -> defaultEval.success);
      in
      let
        foldResult =
          if success then
            builtins.foldl'
              (
                acc: curr:
                if !acc.continue || !acc.found then
                  acc
                else if builtins.isAttrs acc.value && builtins.hasAttr curr.value acc.value then
                  {
                    continue = true;
                    value = acc.value.${curr.value};
                    found = true;
                  }
                else if hasDefault then
                  {
                    continue = false;
                    value = defaultEval.value;
                    found = true;
                  }
                else
                  {
                    continue = false;
                    value = null;
                    found = false;
                  }
              )
              {
                continue = true;
                value = exprEval.value;
                found = true;
              }
              pathEval
          else
            {
              value = null;
              found = false;
            };
      in
      {
        success = success && foldResult.found;
        value = if success && foldResult.found then foldResult.value else null;
      }

    else if _expr == "if" then
      let
        condEval = eval value.condition;
        thenEval = eval value.${"then"};
        elseEval = eval value.${"else"};
        success =
          condEval.success && (condEval.value -> thenEval.success) && (!condEval.value -> elseEval.success);
      in
      {
        inherit success;
        value = if success then (if condEval.value then thenEval.value else elseEval.value) else null;
      }

    else if _expr == "let" then
      # Try evaluating just the body — if all variable references resolve
      # (via closureEnvValues from Nix's evaluator), the let collapses.
      # Individual bindings are still structurally walked if this fails.
      eval value.body

    else if _expr == "with" then
      {
        success = false;
        value = null;
      }

    else if _expr == "call" then
      let
        fnNode = value.function;
        args = value.args or [ ];

        # Safely extract variable names: { _expr = "var"; value = { name = "..."; }; }
        varName =
          node:
          if node ? value && builtins.isAttrs node.value && node.value ? name then
            node.value.name
          else if node ? value && builtins.isString node.value then
            node.value
          else
            "";

        isImportFn =
          # 1. Bare `import` or `scopedImport`
          (fnNode._expr or null == "var" && (varName fnNode == "import" || varName fnNode == "scopedImport"))
          # 2. `builtins.import`
          || (
            fnNode._expr or null == "select"
            && (fnNode.value.expression._expr or null) == "var"
            && varName fnNode.value.expression == "builtins"
            && builtins.length fnNode.value.path == 1
            && (
              let
                p = eval (builtins.elemAt fnNode.value.path 0);
              in
              p.success && p.value == "import"
            )
          );
      in
      # Only handle single-argument calls to import
      if isImportFn && builtins.length args == 1 then
        let
          argEval = eval (builtins.head args);
        in
        if argEval.success && (builtins.isPath argEval.value || builtins.isString argEval.value) then
          let
            imported = builtins.tryEval (import argEval.value);
          in
          if imported.success then
            {
              success = true;
              value = imported.value;
            }
          else
            throw "wechselbalg eval: failed to import '${toString argEval.value}'"
        else
          {
            success = false;
            value = null;
          }
      else
        {
          success = false;
          value = null;
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
      in
      if fstEval.success && !fstEval.value then
        {
          success = true;
          value = false;
        }
      else
        let
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
      in
      if fstEval.success && fstEval.value then
        {
          success = true;
          value = true;
        }
      else
        let
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
      in
      if fstEval.success && !fstEval.value then
        {
          success = true;
          value = true;
        }
      else
        let
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
      {
        success = true;
        inherit value;
      }

    else if _expr == "hasAttr" then
      let
        exprEval = eval value.expression;
        pathEval = builtins.map (p: eval p) value.path;
        success = exprEval.success && builtins.all (p: p.success) pathEval;
      in
      {
        inherit success;
        value =
          if success then
            (builtins.foldl'
              (
                acc: pe:
                if !acc.continue then
                  acc
                else if builtins.isAttrs acc.cur && builtins.hasAttr pe.value acc.cur then
                  {
                    continue = true;
                    cur = acc.cur.${pe.value};
                  }
                else
                  {
                    continue = false;
                    cur = null;
                  }
              )
              {
                continue = true;
                cur = exprEval.value;
              }
              pathEval
            ).continue
          else
            null;
      }

    else if _expr == "primop" || _expr == "primopApp" then
      {
        success = false;
        value = null;
      }

    else if _expr == "assert" then
      # Assertions can't be reliably evaluated at compile time
      {
        success = false;
        value = null;
      }

    else
      throw "wechselbalg eval: unknown AST node type '${_expr}'";

in
eval
