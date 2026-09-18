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

  # ── Find a lambda we've already seen in its bucket ──────────────
  findSameFunction =
    fn: bucketKey: known:
    let
      bucket = known.buckets.${bucketKey} or [ ];
    in
    builtins.foldl' (
      acc: entry:
      if acc != null then
        acc
      else if builtins.sameFunction fn entry.fn then
        entry.name
      else
        null
    ) null bucket;

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
        pending = [ ];
        inherit known;
      }
    else if type == "int" then
      {
        ir = ir.int value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "float" then
      {
        ir = ir.float value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "string" then
      {
        ir = ir.string value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "bool" then
      {
        ir = ir.bool value;
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if type == "null" then
      {
        ir = ir.null_;
        defs = { };
        pending = [ ];
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              elements = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            value;
      in
      {
        ir = ir.list result.elements;
        inherit (result) defs known pending;
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
        rawFingerprint =
          builtins.concatStringsSep "," names + (if distinguishers != "" then "#${distinguishers}" else "");

        # Hash fingerprints for wide sets (like licenses) to avoid 10KB attribute keys
        fingerprint =
          if builtins.length names > 10 then builtins.hashString "sha256" rawFingerprint else rawFingerprint;
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
          pending = [ ];
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
                    # O(1) prepend to list instead of O(N) attrset copying with `//`
                    entries = [
                      {
                        inherit name;
                        value = ir.primopApp "throw" [
                          (ir.string "wechselbalg: attribute '${name}' could not be evaluated")
                        ];
                      }
                    ]
                    ++ acc.entries;
                    inherit (acc) defs known pending;
                  }
                else
                  let
                    r = walkValue tryAttr.value acc.known seenSets';
                  in
                  {
                    # O(1) prepend to list instead of O(N) attrset copying with `//`
                    entries = [
                      {
                        inherit name;
                        value = r.ir;
                      }
                    ]
                    ++ acc.entries;
                    defs = mergeDefs acc.defs r.defs;
                    pending = acc.pending ++ r.pending;
                    known = r.known;
                  }
              )
              {
                entries = [ ]; # Start with empty list
                defs = { };
                pending = [ ];
                inherit known;
              }
              names;
        in
        {
          # Single O(N) C++ conversion to attribute set at the end
          ir = ir.attrs (builtins.listToAttrs result.entries);
          inherit (result) defs known pending;
        }
    else if type == "lambda" then
      let
        ast = builtins.reify value;
      in
      if ast._expr == "primop" then
        {
          ir = ir.primop ast.value;
          defs = { };
          pending = [ ];
          inherit known;
        }
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
                  pending = acc.pending ++ r.pending;
                  known = r.known;
                }
              )
              {
                args = [ ];
                defs = { };
                pending = [ ];
                inherit known;
              }
              ast.value.appliedArgs;
        in
        {
          ir = ir.primopApp ast.value.primop argsResult.args;
          inherit (argsResult) defs known pending;
        }
      else
        let
          bucketKey = getBucketKey ast;
          existing = findSameFunction value bucketKey known;
        in
        if existing != null then
          {
            ir = ir.ref existing;
            defs = { };
            pending = [ ];
            inherit known;
          }
        else
          let
            name = util.freshFuncName known.names;

            # Register in known.names AND append to the right bucket:
            currentBucket = known.buckets.${bucketKey} or [ ];
            known' = known // {
              names = known.names // {
                ${name} = true;
              };
              buckets = known.buckets // {
                ${bucketKey} = currentBucket ++ [
                  {
                    inherit name;
                    fn = value;
                  }
                ];
              };
            };
          in
          {
            ir = ir.ref name;
            defs = { };
            pending = [ { inherit name value; } ];
            known = known';
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
        pending = [ ];
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
    if evalResult.success && builtins.typeOf evalResult.value != "lambda" then
      walkValue evalResult.value known { }

    else if ast._expr == "lambda" then
      # Nested lambda inside a lambda body — same hoisting logic
      let
        name = if builtins.hasAttr "name" ast then ast.name else util.freshFuncName known.names;
        # We don't have the actual Nix function value here (it's an AST),
        # so we can't use sameFunction.  Just register the name to claim it.
        known' = known // {
          names = known.names // {
            ${name} = true;
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
        pending = bodyResult.pending or [ ];
      }

    else if ast._expr == "var" then
      if builtins.hasAttr "closureEnvValue" ast.value then
        let
          envVal = ast.value.closureEnvValue;

          isSelf =
            known ? _currentFn
            && (builtins.typeOf envVal == "lambda")
            && builtins.sameFunction envVal known._currentFn.value;

          # Check if the value can be safely inspected.
          # Some nixpkgs values (filesets, etc.) throw on inspection.
          canWalk = builtins.tryEval (builtins.seq envVal (builtins.typeOf envVal));
        in
        if isSelf then
          {
            ir = ir.ref known._currentFn.name;
            defs = { };
            pending = [ ];
            inherit known;
          }
        else if canWalk.success then
          walkValue envVal known { }
        else
          {
            ir = ir.primopApp "throw" [
              (ir.string "wechselbalg: closure variable '${ast.value.name}' could not be translated")
            ];
            defs = { };
            pending = [ ];
            inherit known;
          }
      else
        {
          ir = ir.var ast.value.name;
          defs = { };
          pending = [ ];
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              parts = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            ast.value;
      in
      {
        ir = ir.concatStrings result.parts;
        inherit (result) defs known pending;
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = funcResult.defs;
              pending = funcResult.pending;
              known = funcResult.known;
            }
            ast.value.args;
        # Build nested apply: f(a)(b)(c)
        appliedIR = builtins.foldl' (fn: arg: ir.apply fn arg) funcResult.ir argsResult.args;
      in
      {
        ir = appliedIR;
        inherit (argsResult) defs known pending;
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
        pending = condR.pending ++ thenR.pending ++ elseR.pending;
        known = elseR.known;
      }

    else if ast._expr == "not" then
      let
        r = walkAST ast.value known;
      in
      {
        ir = ir.not_ r.ir;
        inherit (r) defs known pending;
      }

    else if ast._expr == "and" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.and_ aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
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
        pending = aR.pending ++ bR.pending;
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
        pending = aR.pending ++ bR.pending;
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              path = [ ];
              defs = exprR.defs;
              pending = exprR.pending;
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
        inherit (pathR) defs known pending;
      }

    else if ast._expr == "equals" then
      let
        aR = walkAST ast.value.e1 known;
        bR = walkAST ast.value.e2 aR.known;
      in
      {
        ir = ir.eq aR.ir bR.ir;
        defs = mergeDefs aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
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
        pending = aR.pending ++ bR.pending;
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
        pending = baseR.pending ++ extR.pending;
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
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "path" then
      # Paths are not supported on non-Nix targets — emit a runtime error.
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${toString ast.value}' cannot be translated (paths are not supported in target runtime)")
        ];
        defs = { };
        pending = [ ];
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              elements = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            ast.value;
      in
      {
        ir = ir.list result.elements;
        inherit (result) defs known pending;
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              entries = { };
              defs = { };
              pending = [ ];
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
                pending = acc.pending ++ nameR.pending ++ valueR.pending;
                known = valueR.known;
              }
            )
            {
              parts = [ ];
              defs = staticResult.defs;
              pending = staticResult.pending;
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
          allPending = if hasDynamic then dynamicResult.pending else staticResult.pending;
          finalKnown = if hasDynamic then dynamicResult.known else staticResult.known;
          split = splitDefs allDefs;
        in
        {
          ir = ir.let_ staticResult.entries body split.local;
          defs = split.hoistable;
          pending = allPending;
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
          allPending = if hasDynamic then dynamicResult.pending else staticResult.pending;
          finalKnown = if hasDynamic then dynamicResult.known else staticResult.known;
        in
        {
          ir = finalIR;
          defs = allDefs;
          pending = allPending;
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              path = [ ];
              defs = exprR.defs;
              pending = exprR.pending;
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
              pending = [ ];
              known = pathR.known;
            };

        allDefs = mergeDefs pathR.defs defaultR.defs;
        allPending = pathR.pending ++ defaultR.pending;
      in
      {
        ir =
          if hasDefault then ir.selectOr exprR.ir pathR.path defaultR.ir else ir.select exprR.ir pathR.path;
        defs = allDefs;
        pending = allPending;
        known = defaultR.known;
      }

    else if ast._expr == "primop" then
      {
        ir = ir.primop ast.value;
        defs = { };
        pending = [ ];
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            ast.value.appliedArgs;
      in
      {
        ir = ir.primopApp ast.value.primop argsResult.args;
        inherit (argsResult) defs known pending;
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
        pending = [ ];
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
                pending = acc.pending ++ r.pending;
                known = r.known;
              }
            )
            {
              bindings = { };
              defs = { };
              pending = [ ];
              inherit known;
            }
            names;
        bodyResult = walkAST ast.value.body bindingsResult.known;
        allDefs = mergeDefs bindingsResult.defs bodyResult.defs;
        allPending = bindingsResult.pending ++ bodyResult.pending;
        split = splitDefs allDefs;
      in
      {
        ir = ir.let_ bindingsResult.bindings bodyResult.ir split.local;
        defs = split.hoistable; # Self-contained defs propagate out
        pending = allPending;
        known = bodyResult.known;
      }

    else if ast._expr == "with" then
      # 'with' is hard to translate statically — emit a runtime error.
      # In many cases the enclosing code path is never reached at runtime.
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: 'with' expressions are not supported") ];
        defs = { };
        pending = [ ];
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
        pending = condR.pending ++ bodyR.pending;
        known = bodyR.known;
      }

    else
      # Unknown AST node — emit runtime error instead of compile-time throw
      # so the rest of the translation proceeds.
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: unsupported AST node '${ast._expr}'") ];
        defs = { };
        pending = [ ];
        inherit known;
      };

  # ── Walk a single lambda body ───────────────────────────────────
  # Compiles a reified lambda's body in isolation.
  walkFunctionBody =
    {
      name,
      value,
      known,
    }:
    let
      ast = builtins.reify value;

      bucketKey = getBucketKey ast;

      currentBucket = known.buckets.${bucketKey} or [ ];
      alreadyInBucket = builtins.any (e: e.name == name) currentBucket;

      known' = known // {
        names = known.names // {
          ${name} = true;
        };
        buckets = known.buckets // {
          ${bucketKey} =
            if alreadyInBucket then
              currentBucket
            else
              currentBucket
              ++ [
                {
                  inherit name;
                  fn = value;
                }
              ];
        };
        # Keep track of current compiling function for direct self-recursion checks
        _currentFn = { inherit name value; };
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
      formatArgs =
        args:
        if args ? identifier && args.identifier != null then
          args.identifier
        else if args ? formals then
          let
            names = builtins.map (f: f.name + (if f ? defaultExpr then " ? ..." else "")) args.formals;
            ellipsis = if args.ellipsis or false then [ "..." ] else [ ];
          in
          "{ " + builtins.concatStringsSep ", " (names ++ ellipsis) + " }"
        else
          "none";
    in
    builtins.trace
      ''
        → ${name} (${formatArgs ast.value.arguments})
            body._expr = ${ast.value.body._expr or "unknown"}, call target = 
              ${
                if ast.value.body._expr == "call" then
                  (
                    if ast.value.body.value.function._expr == "var" then
                      ast.value.body.value.function.value.name
                    else
                      ast.value.body.value.function._expr
                  )
                else if ast.value.body._expr == "select" then
                  builtins.concatStringsSep "." (
                    builtins.map (p: if builtins.isString (p.value or null) then p.value else "<expr>") (
                      ast.value.body.value.path or [ ]
                    )
                  )
                else
                  "other"
              }''
      ({
        def = {
          ${name} = ir.funcDef params bodyResult.ir splitBody.local // {
            _hoistable = true;
          };
        }
        // splitBody.hoistable;
        known = bodyResult.known;
        # Pass along any new lambdas discovered while compiling this body
        pending = bodyResult.pending or [ ];
      });

  # ── Extendable Bucket Key ───────────────────────────────────────
  # This key only narrows candidates for builtins.sameFunction.
  getBucketKey =
    ast:
    let
      args = ast.value.arguments;
      body = ast.value.body;

      argFeature =
        if builtins.hasAttr "identifier" args && args.identifier != null then
          "arg:${args.identifier}"
        else if builtins.hasAttr "formals" args then
          "formals:${toString (builtins.length args.formals)}"
        else
          "none";

      bodyFeature = "body:${body._expr or "unknown"}";

      detailFeature =
        if body._expr == "let" then
          let
            letAttrs = body.value.attrs.value.attrs or { };
            bindingNames = builtins.concatStringsSep "," (builtins.attrNames letAttrs);
            innerReturn = body.value.body._expr or "unknown";
          in
          "bindings:[${bindingNames}]|in:${innerReturn}"
        else if body._expr == "call" then
          let
            fnNode = body.value.function;
            fnTarget = if fnNode._expr == "var" then fnNode.value.name else fnNode._expr;
            argc = toString (builtins.length body.value.args);
          in
          "calls:${fnTarget}|argc:${argc}"
        else if body._expr == "attrSet" then
          "attrs:${toString (builtins.length (builtins.attrNames (body.value.attrs or { })))}"
        else
          "";
    in
    "${argFeature}|${bodyFeature}" + (if detailFeature != "" then "|${detailFeature}" else "");

  # ── Top-level entry point ───────────────────────────────────────
  walk =
    value:
    let
      initial = walkValue value {
        names = { };
        buckets = { };
      } { };

      initialState = {
        inherit (initial) ir defs known;
        queue = initial.pending or [ ];
      };

      # Generates a pool of steps. Creating 50,000 ints in Nix takes ~1ms.
      fuel = builtins.genList (x: x) 50000;

      # Driven purely by C++'s for-loop: stack depth is ALWAYS 1.
      finalState = builtins.foldl' (
        state: i:
        if state.queue == [ ] then
          state # Queue is empty: fast no-op for remaining fuel
        else
          let
            item = builtins.head state.queue;
            restQueue = builtins.tail state.queue;

            compiled = walkFunctionBody {
              inherit (item) name value;
              inherit (state) known;
            };
          in
          builtins.trace
            "[Wechselbalg] [Debug] walk ${toString i}; todo: ${toString (builtins.length restQueue)}"
            ({
              inherit (state) ir;
              defs = mergeDefs state.defs compiled.def;
              known = compiled.known;
              # Push newly discovered items onto the queue
              queue = restQueue ++ (compiled.pending or [ ]);
            })
      ) initialState fuel;

      # ── Telemetry & Bucket Profiling ────────────────────────────────
      buckets = finalState.known.buckets or { };
      bucketKeys = builtins.attrNames buckets;
      numBuckets = builtins.length bucketKeys;

      bucketList = builtins.map (k: {
        key = k;
        size = builtins.length buckets.${k};
      }) bucketKeys;

      # Sort buckets from largest to smallest
      sortedBuckets = builtins.sort (a: b: a.size > b.size) bucketList;

      totalLambdas = builtins.foldl' (acc: b: acc + b.size) 0 sortedBuckets;
      largest =
        if sortedBuckets != [ ] then
          builtins.head sortedBuckets
        else
          {
            key = "none";
            size = 0;
          };
      top5 = builtins.genList (i: builtins.elemAt sortedBuckets i) (
        if numBuckets < 5 then numBuckets else 5
      );

      # Pretty-print top 5 buckets
      top5Formatted = builtins.concatStringsSep "\n" (
        builtins.map (b: "  - [${toString b.size} lambdas] ${b.key}") top5
      );

      report = ''

        ═══════════════ Wechselbalg Bucket Telemetry ═══════════════
        Total Hoisted Lambdas : ${toString totalLambdas}
        Total Buckets         : ${toString numBuckets}
        Average Bucket Size   : ${if numBuckets == 0 then "0" else toString (totalLambdas / numBuckets)}
        Largest Bucket        : ${toString largest.size} lambdas ("${largest.key}")
        Top Buckets:
        ${top5Formatted}
        ════════════════════════════════════════════════════════════
      '';

    in
    builtins.trace "[Wechselbalg] [Debug] Phase 1: Walking root value..." (
      if finalState.queue != [ ] then
        throw "wechselbalg: exceeded fuel limit while compiling functions"
      else
        builtins.trace report {
          inherit (finalState) ir defs;
        }
    );

in
walk
