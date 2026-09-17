# The core walker: Nix values → Wechselbalg IR.
#
# Performs a single pass over a Nix value (including reified lambda ASTs)
# and produces:
#
#   { ir = <ir-node>;  defs = { name = { params; body; }; ... };  known = { ... }; }
#
# - `ir`:    the IR representation of the input (call sites get `ref` nodes)
# - `defs`:  all function definitions discovered during the walk (hoisted)
# - `known`: the accumulated function identity map (name → nixValue)
#
# Every lambda is defined exactly once in `defs` and referenced by name
# everywhere it appears.  Recursion (self, mutual) is handled by
# registering the name BEFORE walking the body.

let
  ir = import ./ir.nix;
  evaluateAST = import ./eval.nix;
  purity = import ./purity.nix;
  util = import ./util.nix;

  # ── Merge helper ────────────────────────────────────────────────
  # Merges two walk results, combining defs and keeping the later known.
  mergeDefs = a: b: a // b;

  # ── Split defs by hoistability ──────────────────────────────────
  # Separates defs into { hoistable; local; }.
  # Hoistable defs (from walkValue — fully self-contained, closure vars
  # resolved) can safely propagate out of let/lambda scopes.
  # Local defs (from walkAST — may reference scope-bound variables by
  # name) must stay in their enclosing scope.
  splitDefs =
    defs:
    let
      names = builtins.attrNames defs;
    in
    builtins.foldl'
      (
        acc: name:
        if (defs.${name}._hoistable or false) then
          {
            hoistable = acc.hoistable // {
              ${name} = defs.${name};
            };
            inherit (acc) local;
          }
        else
          {
            inherit (acc) hoistable;
            local = acc.local // {
              ${name} = defs.${name};
            };
          }
      )
      {
        hoistable = { };
        local = { };
      }
      names;

  # ── Find a lambda we've already seen ────────────────────────────
  # Returns the name if `fn` was already registered in `known`, else null.
  findSameFunction =
    fn: known:
    let
      names = builtins.attrNames known;
      match = builtins.foldl' (
        acc: name:
        if acc != null then
          acc
        else if builtins.typeOf known.${name} != "lambda" then
          null
        else if builtins.sameFunction fn known.${name} then
          name
        else
          null
      ) null names;
    in
    match;

  # ── Walk a Nix value (already evaluated) ────────────────────────
  # seenSets: attrset of fingerprints of ancestor attrsets being walked.
  # Used to detect circular attrset references (e.g. functor.type in nixpkgs).
  walkValue =
    value: known: seenSets:
    let
      type = builtins.typeOf value;
      _ = if type == "path" then true else purity.assertPure value;
    in

    if (type == "set" || type == "list") && util.JSONOptimizable value then
      # skip walking of pure JSON-optimizable sets/lists — just emit IR converting it to String literal and parsing at runtime
      {
        ir = ir.primopApp "fromJSON" [ (ir.string (builtins.toJSON value)) ];
        defs = { };
        inherit known;
      }
    else if type == "int" then
      {
        ir = ir.int value;
        defs = { };
        inherit known;
      }

    else if type == "float" then
      {
        ir = ir.float value;
        defs = { };
        inherit known;
      }

    else if type == "string" then
      {
        ir = ir.string value;
        defs = { };
        inherit known;
      }

    else if type == "bool" then
      {
        ir = ir.bool value;
        defs = { };
        inherit known;
      }

    else if type == "null" then
      {
        ir = ir.null_;
        defs = { };
        inherit known;
      }

    else if type == "list" then
      let
        result =
          builtins.foldl'
            (
              acc: elem:
              let
                r = walkValue elem acc.known seenSets;
              in
              {
                elements = acc.elements ++ [ r.ir ];
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              elements = [ ];
              defs = { };
              inherit known;
            }
            value;
      in
      {
        ir = ir.list result.elements;
        inherit (result) defs known;
      }

    else if type == "set" then
      let
        names = builtins.attrNames value;
        # Build a fingerprint that includes distinguishing string values
        # (not just key names) to avoid false-positive cycle detection
        # for structurally similar attrsets (e.g. nixpkgs type objects
        # all have the same keys but different "name" values).
        distinguishers = builtins.concatStringsSep "|" (
          builtins.filter (s: s != "") (
            builtins.map
              (
                n:
                let
                  try = builtins.tryEval (if builtins.isString value.${n} then "${n}=${value.${n}}" else "");
                in
                if try.success then try.value else ""
              )
              (
                builtins.filter (
                  n:
                  builtins.elem n [
                    "name"
                    "_type"
                    "description"
                  ]
                ) names
              )
          )
        );
        fingerprint =
          builtins.concatStringsSep "," names + (if distinguishers != "" then "#${distinguishers}" else "");
      in
      if builtins.hasAttr fingerprint seenSets then
        # Circular attrset reference detected — emit a let-bound throw so
        # the error message string is defined once, shared across all entries.
        {
          ir =
            ir.let_
              {
                __wb_circ_err = ir.primopApp "throw" [
                  (ir.string "wechselbalg: circular attrset (keys: ${fingerprint})")
                ];
              }
              (ir.attrs (
                builtins.listToAttrs (
                  builtins.map (name: {
                    inherit name;
                    value = ir.var "__wb_circ_err";
                  }) names
                )
              ))
              { };
          defs = { };
          inherit known;
        }
      else
        let
          seenSets' = seenSets // {
            ${fingerprint} = true;
          };
          result =
            builtins.foldl'
              (
                acc: name:
                let
                  tryAttr = builtins.tryEval (builtins.seq value.${name} value.${name});
                in
                if !tryAttr.success then
                  {
                    entries = acc.entries // {
                      ${name} = ir.primopApp "throw" [
                        (ir.string "wechselbalg: attribute '${name}' could not be evaluated")
                      ];
                    };
                    inherit (acc) defs known;
                  }
                else
                  let
                    r = walkValue tryAttr.value acc.known seenSets';
                  in
                  {
                    entries = acc.entries // {
                      ${name} = r.ir;
                    };
                    defs = mergeDefs acc.defs r.defs;
                    known = r.known;
                  }
              )
              {
                entries = { };
                defs = { };
                inherit known;
              }
              names;
        in
        {
          ir = ir.attrs result.entries;
          inherit (result) defs known;
        }

    else if type == "lambda" then
      let
        existing = findSameFunction value known;
      in
      if existing != null then
        {
          ir = ir.ref existing;
          defs = { };
          inherit known;
        }
      else
        let
          ast = builtins.reify value;
        in
        # Primops reify as { _expr = "primop"; value = "name"; }
        if ast._expr == "primop" then
          {
            ir = ir.primop ast.value;
            defs = { };
            inherit known;
          }

        # Partially-applied primops (e.g. `builtins.lessThan 1`)
        else if ast._expr == "primopApp" then
          let
            argsResult =
              builtins.foldl'
                (
                  acc: arg:
                  let
                    r = walkValue arg acc.known seenSets;
                  in
                  {
                    args = acc.args ++ [ r.ir ];
                    defs = mergeDefs acc.defs r.defs;
                    known = r.known;
                  }
                )
                {
                  args = [ ];
                  defs = { };
                  inherit known;
                }
                ast.value.appliedArgs;
          in
          {
            ir = ir.primopApp ast.value.primop argsResult.args;
            inherit (argsResult) defs known;
          }

        else
          let
            name = util.freshFuncName known;
            # Register BEFORE walking body — breaks cycles
            known' = known // {
              ${name} = value;
            };
            bodyResult = walkAST ast.value.body known';
            splitBody = splitDefs bodyResult.defs;

            params = {
              identifier = ast.value.arguments.identifier or null;
              formals =
                if builtins.hasAttr "formals" ast.value.arguments then
                  builtins.map (f: {
                    inherit (f) name;
                    hasDefault = builtins.hasAttr "defaultExpr" f;
                    default =
                      if builtins.hasAttr "defaultExpr" f then (walkAST f.defaultExpr bodyResult.known).ir else null;
                  }) ast.value.arguments.formals
                else
                  null;
              ellipsis =
                if builtins.hasAttr "ellipsis" ast.value.arguments then ast.value.arguments.ellipsis else true; # default: allow extra args
            };
          in
          {
            ir = ir.ref name;
            defs = {
              ${name} = ir.funcDef params bodyResult.ir splitBody.local // {
                _hoistable = true;
              };
            }
            // splitBody.hoistable;
            known = bodyResult.known;
          }

    else if type == "path" then
      # Paths are not supported on non-Nix targets — emit a runtime error.
      # This allows closures containing paths to still be translated as long
      # as the path itself is not accessed at runtime.
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${toString value}' cannot be translated (paths are not supported in target runtime)")
        ];
        defs = { };
        inherit known;
      }

    else
      throw "wechselbalg: unsupported Nix type '${type}'";

  # ── Walk a reified AST node ─────────────────────────────────────
  # This handles the output of builtins.reify — the structural AST
  # of lambda bodies.  Tries compile-time eval first; falls back to
  # structural translation.
  walkAST =
    ast: known:
    let
      evalResult = evaluateAST ast;
    in
    # If the AST can be fully evaluated at Nix eval time, just walk the
    # resulting value (turns it into IR literals / refs).
    if evalResult.success then
      walkValue evalResult.value known { }

    else if ast._expr == "lambda" then
      # Nested lambda inside a lambda body — same hoisting logic
      let
        name = if builtins.hasAttr "name" ast then ast.name else util.freshFuncName known;
        # We don't have the actual Nix function value here (it's an AST),
        # so we can't use sameFunction.  Just register the name to claim it.
        known' = known // {
          ${name} = {
            __astPlaceholder = true;
          };
        };
        bodyResult = walkAST ast.value.body known';
        splitBody = splitDefs bodyResult.defs;

        params = {
          identifier = ast.value.arguments.identifier or null;
          formals =
            if builtins.hasAttr "formals" ast.value.arguments then
              builtins.map (f: {
                inherit (f) name;
                hasDefault = builtins.hasAttr "defaultExpr" f;
                default =
                  if builtins.hasAttr "defaultExpr" f then (walkAST f.defaultExpr bodyResult.known).ir else null;
              }) ast.value.arguments.formals
            else
              null;
          ellipsis =
            if builtins.hasAttr "ellipsis" ast.value.arguments then ast.value.arguments.ellipsis else true;
        };
      in
      {
        ir = ir.ref name;
        defs = {
          ${name} = ir.funcDef params bodyResult.ir splitBody.local;
        }
        // splitBody.hoistable;
        known = bodyResult.known;
      }

    else if ast._expr == "var" then
      # Variable reference.  If it has a closureEnvValue that's a function,
      # we need to walk it (it'll get hoisted).  Otherwise just emit var.
      if builtins.hasAttr "closureEnvValue" ast.value then
        let
          envVal = ast.value.closureEnvValue;
          # Check if the value can be safely inspected.
          # Some nixpkgs values (filesets, etc.) throw on inspection.
          canWalk = builtins.tryEval (builtins.seq envVal (builtins.typeOf envVal));
        in
        if canWalk.success then
          walkValue envVal known { }
        else
          {
            ir = ir.primopApp "throw" [
              (ir.string "wechselbalg: closure variable '${ast.value.name}' could not be translated")
            ];
            defs = { };
            inherit known;
          }
      else
        {
          ir = ir.var ast.value.name;
          defs = { };
          inherit known;
        }

    else if ast._expr == "concatString/addition" then
      let
        result =
          builtins.foldl'
            (
              acc: operand:
              let
                r = walkAST operand acc.known;
              in
              {
                parts = acc.parts ++ [ r.ir ];
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              parts = [ ];
              defs = { };
              inherit known;
            }
            ast.value;
      in
      {
        ir = ir.concatStrings result.parts;
        inherit (result) defs known;
      }

    else if ast._expr == "call" then
      let
        funcResult = walkAST ast.value.function known;
        argsResult =
          builtins.foldl'
            (
              acc: arg:
              let
                r = walkAST arg acc.known;
              in
              {
                args = acc.args ++ [ r.ir ];
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = funcResult.defs;
              known = funcResult.known;
            }
            ast.value.args;
        # Build nested apply: f(a)(b)(c)
        appliedIR = builtins.foldl' (fn: arg: ir.apply fn arg) funcResult.ir argsResult.args;
      in
      {
        ir = appliedIR;
        inherit (argsResult) defs known;
      }

    else if ast._expr == "if" then
      let
        condR = walkAST ast.value.condition known;
        thenR = walkAST ast.value.${"then"} condR.known;
        elseR = walkAST ast.value.${"else"} thenR.known;
      in
      {
        ir = ir.if_ condR.ir thenR.ir elseR.ir;
        defs = mergeDefs (mergeDefs condR.defs thenR.defs) elseR.defs;
        known = elseR.known;
      }

    else if ast._expr == "not" then
      let
        r = walkAST ast.value known;
      in
      {
        ir = ir.not_ r.ir;
        inherit (r) defs known;
      }

    else if ast._expr == "and" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.and_ aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        known = bR.known;
      }

    else if ast._expr == "or" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.or_ aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        known = bR.known;
      }

    else if ast._expr == "implies" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.implies aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        known = bR.known;
      }

    else if ast._expr == "hasAttr" then
      # Nix `e ? a.b.c` — check whether the full attribute path exists.
      # Desugared to: hasAttr "a" e && hasAttr "b" e.a && hasAttr "c" e.a.b
      # using the existing hasAttr primop (no new IR node needed).
      let
        exprR = walkAST ast.value.expression known;
        pathR =
          builtins.foldl'
            (
              acc: p:
              let
                r = walkAST p acc.known;
              in
              {
                path = acc.path ++ [ r.ir ];
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              path = [ ];
              defs = exprR.defs;
              known = exprR.known;
            }
            ast.value.path;

        # Build chained check: hasAttr(p0, e) && hasAttr(p1, e.p0) && ...
        checks = builtins.genList (
          i:
          let
            elem = builtins.elemAt pathR.path i;
            prefix = builtins.genList (j: builtins.elemAt pathR.path j) i;
            base = if prefix == [ ] then exprR.ir else ir.select exprR.ir prefix;
          in
          ir.primopApp "hasAttr" [
            elem
            base
          ]
        ) (builtins.length pathR.path);

        finalIR = builtins.foldl' (
          acc: check: if acc == null then check else ir.and_ acc check
        ) null checks;
      in
      {
        ir = finalIR;
        defs = pathR.defs;
        known = pathR.known;
      }

    else if ast._expr == "equals" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.eq aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        known = bR.known;
      }

    else if ast._expr == "notEquals" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.neq aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        known = bR.known;
      }

    else if ast._expr == "update" then
      let
        baseR = walkAST ast.value.e1 known;
        extR = walkAST ast.value.e2 baseR.known;
      in
      {
        ir = ir.update baseR.ir extR.ir;
        defs = mergeDefs baseR.defs extR.defs;
        known = extR.known;
      }

    else if ast._expr == "concatLists" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.concatLists aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        known = bR.known;
      }

    else if ast._expr == "path" then
      # Paths are not supported on non-Nix targets — emit a runtime error.
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${toString ast.value}' cannot be translated (paths are not supported in target runtime)")
        ];
        defs = { };
        inherit known;
      }

    else if ast._expr == "list" then
      let
        result =
          builtins.foldl'
            (
              acc: elem:
              let
                r = walkAST elem acc.known;
              in
              {
                elements = acc.elements ++ [ r.ir ];
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              elements = [ ];
              defs = { };
              inherit known;
            }
            ast.value;
      in
      {
        ir = ir.list result.elements;
        inherit (result) defs known;
      }

    else if ast._expr == "attrSet" then
      let
        # ── Walk static attrs ──────────────────────────────────────
        names = builtins.attrNames ast.value.attrs;
        staticResult =
          builtins.foldl'
            (
              acc: name:
              let
                r = walkAST ast.value.attrs.${name} acc.known;
              in
              {
                entries = acc.entries // {
                  ${name} = r.ir;
                };
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              entries = { };
              defs = { };
              inherit known;
            }
            names;

        # ── Walk dynamic attrs ─────────────────────────────────────
        # Each dynamic attr has { name = <ast>; value = <ast>; }.
        # Nix silently drops entries whose name evaluates to null
        # (e.g. `{ ${null} = 1; }` yields `{}`), so each entry is
        # wrapped in `if name != null then listToAttrs [...] else {}`.
        hasDynamic = ast.value.dynamicAttrs != [ ];
        dynamicResult =
          builtins.foldl'
            (
              acc: dyn:
              let
                nameR = walkAST dyn.name acc.known;
                valueR = walkAST dyn.value nameR.known;
                pair = ir.primopApp "listToAttrs" [
                  (ir.list [
                    (ir.attrs {
                      name = nameR.ir;
                      value = valueR.ir;
                    })
                  ])
                ];
                # Nix drops dynamic attrs whose name is null — guard each entry
                guarded = ir.if_ (ir.eq nameR.ir ir.null_) (ir.attrs { }) pair;
              in
              {
                parts = acc.parts ++ [ guarded ];
                defs = mergeDefs (mergeDefs acc.defs nameR.defs) valueR.defs;
                known = valueR.known;
              }
            )
            {
              parts = [ ];
              defs = staticResult.defs;
              known = staticResult.known;
            }
            ast.value.dynamicAttrs;

        # Merge all guarded dynamic entries via //
        dynamicIR = builtins.foldl' ir.update (builtins.head dynamicResult.parts) (
          builtins.tail dynamicResult.parts
        );
        hasStatic = names != [ ];
      in
      if ast.value.recursive then
        # Recursive attrsets: entries can reference each other by name.
        # Desugar to: let a = expr_a; b = expr_b; in lazyAttrs { a; b; }
        # The let_ bindings are thunked by the backend, so mutual references
        # resolve lazily.  The body is a lazy attrset of variable refs.
        # All defs stay local (they may reference entry-bound variables).
        let
          refs = builtins.listToAttrs (
            builtins.map (name: {
              inherit name;
              value = ir.var name;
            }) names
          );
          staticBody = ir.attrs refs;
          body = if hasDynamic then ir.update staticBody dynamicIR else staticBody;
          allDefs = if hasDynamic then dynamicResult.defs else staticResult.defs;
          finalKnown = if hasDynamic then dynamicResult.known else staticResult.known;
          split = splitDefs allDefs;
        in
        {
          ir = ir.let_ staticResult.entries body split.local;
          defs = split.hoistable;
          known = finalKnown;
        }
      else
        # Non-recursive attrset inside a lambda body.
        # Use lazyAttrs so that entries referencing thunked outer variables
        # (e.g. from a let-binding or fixed-point) aren't forced prematurely.
        let
          staticIR = ir.attrs staticResult.entries;
          finalIR =
            if hasDynamic && hasStatic then
              ir.update staticIR dynamicIR
            else if hasDynamic then
              dynamicIR
            else
              staticIR;
          allDefs = if hasDynamic then dynamicResult.defs else staticResult.defs;
          finalKnown = if hasDynamic then dynamicResult.known else staticResult.known;
        in
        {
          ir = finalIR;
          defs = allDefs;
          known = finalKnown;
        }

    else if ast._expr == "select" then
      let
        exprR = walkAST ast.value.expression known;
        pathR =
          builtins.foldl'
            (
              acc: p:
              let
                r = walkAST p acc.known;
              in
              {
                path = acc.path ++ [ r.ir ];
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              path = [ ];
              defs = exprR.defs;
              known = exprR.known;
            }
            ast.value.path;

        hasDefault = builtins.hasAttr "default" ast.value;
        defaultR =
          if hasDefault then
            walkAST ast.value.default pathR.known
          else
            {
              ir = null;
              defs = { };
              known = pathR.known;
            };

        allDefs = mergeDefs pathR.defs defaultR.defs;
      in
      {
        ir =
          if hasDefault then ir.selectOr exprR.ir pathR.path defaultR.ir else ir.select exprR.ir pathR.path;
        defs = allDefs;
        known = defaultR.known;
      }

    else if ast._expr == "primop" then
      {
        ir = ir.primop ast.value;
        defs = { };
        inherit known;
      }

    else if ast._expr == "primopApp" then
      let
        argsResult =
          builtins.foldl'
            (
              acc: arg:
              let
                r = walkValue arg acc.known { };
              in
              {
                args = acc.args ++ [ r.ir ];
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = { };
              inherit known;
            }
            ast.value.appliedArgs;
      in
      {
        ir = ir.primopApp ast.value.primop argsResult.args;
        inherit (argsResult) defs known;
      }

    else if ast._expr == "path" then
      # Path expressions can't be translated — emit a runtime error
      # so the rest of the translation proceeds (the path may never
      # be accessed at runtime).
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${builtins.toJSON (ast.value or "unknown")}' cannot be translated")
        ];
        defs = { };
        inherit known;
      }

    else if ast._expr == "let" then
      # Nix `let` is always a recursive scope — bindings can reference
      # each other.  We emit ir.let_ so the backend thunks all bindings.
      # Scope-dependent defs (from walkAST lambdas — may reference let-bound
      # variables) stay local.  Hoistable defs (from walkValue — fully
      # self-contained) propagate out so they're visible from all references.
      let
        attrs = ast.value.attrs.value.attrs;
        names = builtins.attrNames attrs;
        bindingsResult =
          builtins.foldl'
            (
              acc: name:
              let
                r = walkAST attrs.${name} acc.known;
              in
              {
                bindings = acc.bindings // {
                  ${name} = r.ir;
                };
                defs = mergeDefs acc.defs r.defs;
                known = r.known;
              }
            )
            {
              bindings = { };
              defs = { };
              inherit known;
            }
            names;
        bodyResult = walkAST ast.value.body bindingsResult.known;
        allDefs = mergeDefs bindingsResult.defs bodyResult.defs;
        split = splitDefs allDefs;
      in
      {
        ir = ir.let_ bindingsResult.bindings bodyResult.ir split.local;
        defs = split.hoistable; # Self-contained defs propagate out
        known = bodyResult.known;
      }

    else if ast._expr == "with" then
      # 'with' is hard to translate statically — emit a runtime error.
      # In many cases the enclosing code path is never reached at runtime.
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: 'with' expressions are not supported") ];
        defs = { };
        inherit known;
      }

    else if ast._expr == "assert" then
      # assert condition; body → if condition then body else throw "assertion failed"
      let
        condR = walkAST ast.value.condition known;
        bodyR = walkAST ast.value.body condR.known;
      in
      {
        ir = ir.if_ condR.ir bodyR.ir (
          ir.primopApp "throw" [ (ir.string "wechselbalg: assertion failed") ]
        );
        defs = mergeDefs condR.defs bodyR.defs;
        known = bodyR.known;
      }

    else
      # Unknown AST node — emit runtime error instead of compile-time throw
      # so the rest of the translation proceeds.
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: unsupported AST node '${ast._expr}'") ];
        defs = { };
        inherit known;
      };

  # ── Top-level entry point ───────────────────────────────────────
  walk =
    value:
    let
      result = walkValue value { } { };
    in
    {
      inherit (result) ir defs;
    };

in
walk
