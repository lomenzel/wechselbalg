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
  validate = import ./validate.nix;
  analyze = import ./analyze.nix;

  # Name of the environment parameter of a code template.  Deliberately not
  # `__wb_env`: the Python backend uses that identifier for its let-scope dict.
  envParam = "__wb_cenv";

  emptySeen = {
    sets = { };
    funcs = [ ];
    depth = 0;
  };

  reverseList =
    list:
    let
      len = builtins.length list;
    in
    builtins.genList (i: builtins.elemAt list (len - 1 - i)) len;

  # Strict fold for accumulator walks. Forces hot fields to prevent thunk cascades.
  foldWalk =
    f: init: list:
    builtins.foldl' (
      acc: x:
      let
        res = f acc x;
      in
      builtins.seq res.defs (
        builtins.seq res.pending (
          builtins.seq res.known.counter (
            if res ? elements then
              builtins.seq res.elements res
            else if res ? entries then
              builtins.seq res.entries res
            else if res ? args then
              builtins.seq res.args res
            else if res ? parts then
              builtins.seq res.parts res
            else if res ? path then
              builtins.seq res.path res
            else if res ? bindings then
              builtins.seq res.bindings res
            else if res ? formals then
              builtins.seq res.formals res
            else
              res
          )
        )
      )
    ) init list;

  # ── Merge helper ────────────────────────────────────────────────
  update =
    a: b:
    if a == { } then
      b
    else if b == { } then
      a
    else
      a // b;

  # ── Split defs by hoistability ──────────────────────────────────
  splitDefs =
    defs:
    let
      names = builtins.attrNames defs;
      hoistableNames = builtins.filter (name: defs.${name}._hoistable or false) names;
      localNames = builtins.filter (name: !(defs.${name}._hoistable or false)) names;

      hoistable = builtins.listToAttrs (
        builtins.map (name: {
          inherit name;
          value = defs.${name};
        }) hoistableNames
      );
      local = builtins.listToAttrs (
        builtins.map (name: {
          inherit name;
          value = defs.${name};
        }) localNames
      );
    in
    {
      inherit hoistable local;
    };

  # ── Runtime reify metadata for one hoisted definition ───────────
  reifyMeta =
    ast: known:
    let
      info = analyze.reifyInfo ast;
      hasEnv = (known._env or null) != null;
      captured = if hasEnv then known._env.capture.mode else { };
      localNames = builtins.filter (n: !(captured ? ${n})) info.free;
      localEnv = ir.attrs (
        builtins.listToAttrs (
          builtins.map (n: {
            name = n;
            value = ir.var n;
          }) localNames
        )
      );
    in
    {
      ast = builtins.toJSON info.stripped;
      envIR =
        if hasEnv && localNames != [ ] then
          ir.update (ir.var known._env.param) localEnv
        else if hasEnv then
          ir.var known._env.param
        else if localNames != [ ] then
          localEnv
        else
          null;
    };

  # ── Walk a reified lambda's parameter list ──────────────────────
  walkParams =
    arguments: known:
    let
      identifier = arguments.identifier or null;
      ellipsis = if builtins.hasAttr "ellipsis" arguments then arguments.ellipsis else true;
    in
    if !(builtins.hasAttr "formals" arguments) then
      {
        params = {
          inherit identifier ellipsis;
          formals = null;
        };
        defs = { };
        pending = [ ];
        inherit known;
      }
    else
      let
        result =
          foldWalk
            (
              acc: f:
              if builtins.hasAttr "defaultExpr" f then
                let
                  r = walkAST f.defaultExpr acc.known;
                in
                {
                  formals = [
                    {
                      inherit (f) name;
                      hasDefault = true;
                      default = r.ir;
                    }
                  ]
                  ++ acc.formals;
                  defs = update acc.defs r.defs;
                  pending = r.pending ++ acc.pending;
                  known = r.known;
                }
              else
                {
                  formals = [
                    {
                      inherit (f) name;
                      hasDefault = false;
                      default = null;
                    }
                  ]
                  ++ acc.formals;
                  inherit (acc) defs pending known;
                }
            )
            {
              formals = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            arguments.formals;
      in
      {
        params = {
          inherit identifier ellipsis;
          formals = reverseList result.formals;
        };
        inherit (result) defs pending known;
      };

  # ── Name allocation ─────────────────────────────────────────────
  alloc = prefix: known: {
    name = "${prefix}${toString known.counter}";
    known = known // {
      counter = known.counter + 1;
    };
  };

  markUsed =
    name: known:
    known
    // {
      used = known.used // {
        ${name} = true;
      };
    };

  findInFlight =
    fn: funcs:
    let
      len = builtins.length funcs;
      go =
        i:
        if i >= len then
          null
        else
          let
            e = builtins.elemAt funcs i;
          in
          if builtins.sameFunction fn e.fn then e.binding else go (i + 1);
    in
    if funcs == [ ] then null else go 0;

  findInstance =
    fn: instances:
    let
      len = builtins.length instances;
      go =
        i:
        if i >= len then
          null
        else
          let
            e = builtins.elemAt instances i;
          in
          if builtins.sameFunction fn e.fn then e.binding else go (i + 1);
    in
    if instances == [ ] then null else go 0;

  # ── Instance memo ───────────────────────────────────────────────
  instanceCap = 64;

  confirmSameSet =
    a: b:
    builtins.foldl' (
      acc: n:
      if acc != null then
        acc
      else
        let
          t = builtins.tryEval (
            if builtins.isFunction a.${n} && builtins.isFunction b.${n} then
              builtins.sameFunction a.${n} b.${n}
            else
              null
          );
        in
        if t.success && t.value != null then t.value else null
    ) null (builtins.attrNames a);

  # ── Resolve one captured environment entry ──────────────────────
  resolveCapture =
    entry:
    let
      r = builtins.tryEval (builtins.foldl' (acc: p: acc.${p}) entry.env entry.path);
    in
    if !r.success then
      { ok = false; }
    else
      let
        t = builtins.tryEval (builtins.typeOf r.value);
        p = builtins.tryEval (purity.isPure r.value);
      in
      if !t.success then
        { ok = false; }
      else if t.value == "path" then
        {
          ok = true;
          inherit (r) value;
        }
      else if !p.success || !p.value.pure then
        { ok = false; }
      else
        {
          ok = true;
          inherit (r) value;
        };

  # Fast string extractor for fingerprinting without iterating all names
  extractDistString =
    v: k:
    if v ? ${k} then
      let
        try = builtins.tryEval (if builtins.isString v.${k} then "${k}=${v.${k}}" else "");
      in
      if try.success then try.value else ""
    else
      "";

  # ── Walk a Nix value (already evaluated) ────────────────────────
  walkValue =
    value: known: seen:
    let
      type = builtins.typeOf value;
    in

    if seen.depth > 500 then
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: value nesting too deep (possible cycle)")
        ];
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if (type == "set" || type == "list") && util.JSONOptimizable value then
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
        seen' = seen // {
          depth = seen.depth + 1;
        };
        result =
          foldWalk
            (
              acc: elem:
              let
                r = walkValue elem acc.known seen';
              in
              {
                elements = [ r.ir ] ++ acc.elements;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
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
        ir = ir.list (reverseList result.elements);
        inherit (result) defs known pending;
      }

    else if type == "set" then
      if value ? drvPath || (value ? type && value.type == "derivation") then
        {
          ir = ir.primopApp "throw" [
            (ir.string "wechselbalg: derivations cannot be translated into target code")
          ];
          defs = { };
          pending = [ ];
          inherit known;
        }
      else
        let
          names = builtins.attrNames value;
          # Fast direct lookup instead of filtering over all names
          dName = extractDistString value "name";
          dType = extractDistString value "_type";
          dDesc = extractDistString value "description";
          distinguishers = builtins.concatStringsSep "|" (
            builtins.filter (s: s != "") [
              dName
              dType
              dDesc
            ]
          );

          rawFingerprint =
            builtins.concatStringsSep "," names + (if distinguishers != "" then "#${distinguishers}" else "");

          fingerprint =
            if builtins.length names > 10 then builtins.hashString "sha256" rawFingerprint else rawFingerprint;

          ancestor = seen.sets.${fingerprint} or null;
          confirmed = if ancestor == null then false else confirmSameSet value ancestor.value;
        in
        if ancestor != null && confirmed == true then
          {
            ir = ir.ref ancestor.binding;
            defs = { };
            pending = [ ];
            known = markUsed ancestor.binding known;
          }
        else
          let
            bindingAlloc = alloc "__wb_cap_" known;
            binding = bindingAlloc.name;
            seen' = seen // {
              depth = seen.depth + 1;
              sets = seen.sets // {
                ${fingerprint} = {
                  inherit binding value;
                };
              };
            };
            result =
              foldWalk
                (
                  acc: name:
                  let
                    tryAttr = builtins.tryEval (builtins.seq value.${name} value.${name});
                  in
                  if !tryAttr.success then
                    {
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
                      r = walkValue tryAttr.value acc.known seen';
                    in
                    {
                      entries = [
                        {
                          inherit name;
                          value = r.ir;
                        }
                      ]
                      ++ acc.entries;
                      defs = update acc.defs r.defs;
                      pending = r.pending ++ acc.pending;
                      known = r.known;
                    }
                )
                {
                  entries = [ ];
                  defs = { };
                  pending = [ ];
                  known = bindingAlloc.known;
                }
                names;
            attrsIR = ir.attrs (builtins.listToAttrs result.entries);
          in
          if result.known.used ? ${binding} then
            {
              ir = ir.ref binding;
              inherit (result) defs pending;
              known = result.known // {
                bindings = result.known.bindings // {
                  ${binding} = attrsIR;
                };
              };
            }
          else
            {
              ir = attrsIR;
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
            foldWalk
              (
                acc: arg:
                let
                  r = walkValue arg acc.known (seen // { depth = seen.depth + 1; });
                in
                {
                  args = [ r.ir ] ++ acc.args;
                  defs = update acc.defs r.defs;
                  pending = r.pending ++ acc.pending;
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
          ir = ir.primopApp ast.value.primop (reverseList argsResult.args);
          inherit (argsResult) defs known pending;
        }
      else
        let
          inFlight = findInFlight value seen.funcs;
        in
        if inFlight != null then
          {
            ir = ir.ref inFlight;
            defs = { };
            pending = [ ];
            known = markUsed inFlight known;
          }
        else
          let
            info = analyze.analyze ast;
            memo = if info.closed then null else findInstance value (known.instances.${info.key} or [ ]);
          in
          if memo != null then
            {
              ir = ir.ref memo;
              defs = { };
              pending = [ ];
              inherit known;
            }
          else
            let
              registered = known.templates.${info.key} or null;

              tplAlloc = if registered != null then null else alloc "__wb_tpl_" known;
              tplName = if registered != null then registered.name else tplAlloc.name;

              known1 =
                if registered != null then
                  known
                else
                  tplAlloc.known
                  // {
                    templates = tplAlloc.known.templates // {
                      ${info.key} = {
                        name = tplName;
                        inherit (info)
                          capture
                          envKeys
                          closed
                          stripped
                          ;
                      };
                    };
                  };

              newPending =
                if registered != null then
                  [ ]
                else
                  [
                    {
                      name = tplName;
                      inherit value;
                      inherit (info) key;
                    }
                  ];
            in
            if info.closed then
              {
                ir = ir.ref tplName;
                defs = { };
                pending = newPending;
                known = known1;
              }
            else
              let
                cloAlloc = alloc "__wb_clo_" known1;
                binding = cloAlloc.name;
                bucket = known1.instances.${info.key} or [ ];

                known2 = cloAlloc.known // {
                  instances = cloAlloc.known.instances // {
                    ${info.key} =
                      if builtins.length bucket >= instanceCap then
                        bucket
                      else
                        bucket
                        ++ [
                          {
                            fn = value;
                            inherit binding;
                          }
                        ];
                  };
                };

                seen' = seen // {
                  depth = seen.depth + 1;
                  funcs = [
                    {
                      fn = value;
                      inherit binding;
                    }
                  ]
                  ++ seen.funcs;
                };

                envResult =
                  foldWalk
                    (
                      acc: key:
                      let
                        resolved = resolveCapture info.capture.entries.${key};
                      in
                      if !resolved.ok then
                        {
                          entries = [
                            {
                              name = key;
                              value = ir.primopApp "throw" [
                                (ir.string "wechselbalg: captured variable '${key}' could not be translated")
                              ];
                            }
                          ]
                          ++ acc.entries;
                          inherit (acc) defs pending known;
                        }
                      else
                        let
                          r = walkValue resolved.value acc.known seen';
                        in
                        {
                          entries = [
                            {
                              name = key;
                              value = r.ir;
                            }
                          ]
                          ++ acc.entries;
                          defs = update acc.defs r.defs;
                          pending = r.pending ++ acc.pending;
                          known = r.known;
                        }
                    )
                    {
                      entries = [ ];
                      defs = { };
                      pending = newPending;
                      known = known2;
                    }
                    info.envKeys;

                closureIR = ir.closure tplName (builtins.listToAttrs envResult.entries);
              in
              {
                ir = ir.ref binding;
                inherit (envResult) defs pending;
                known = envResult.known // {
                  bindings = envResult.known.bindings // {
                    ${binding} = closureIR;
                  };
                };
              }

    else if type == "path" then
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
  walkAST =
    ast: known:
    let
      evalResult = evaluateAST ast;
    in
    if evalResult.success && builtins.typeOf evalResult.value != "lambda" then
      walkValue evalResult.value known emptySeen

    else if ast._expr == "lambda" then
      let
        nameAlloc = alloc "__wb_func_" known;
        name = nameAlloc.name;
        bodyResult = walkAST ast.value.body nameAlloc.known;
        paramsResult = walkParams ast.value.arguments bodyResult.known;
        splitBody = splitDefs (update bodyResult.defs paramsResult.defs);
      in
      {
        ir = ir.ref name;
        defs = {
          ${name} = ir.funcDef (paramsResult.params // reifyMeta ast known) bodyResult.ir splitBody.local;
        }
        // splitBody.hoistable;
        known = paramsResult.known;
        pending = (bodyResult.pending or [ ]) ++ paramsResult.pending;
      }

    else if ast._expr == "var" then
      if ast.value.name == "__wasm" then
        {
          ir = ir.primop "wasm";
          defs = { };
          pending = [ ];
          inherit known;
        }
      else if builtins.hasAttr "closureEnvValue" ast.value then
        if (known._env or null) == null then
          {
            ir = ir.var ast.value.name;
            defs = { };
            pending = [ ];
            inherit known;
          }
        else
          let
            env = known._env;
            mode =
              env.capture.mode.${ast.value.name}
                or (throw "wechselbalg: internal: free variable '${ast.value.name}' is missing from the capture plan; envKeys=${builtins.toString (builtins.attrNames env.capture.mode)}");
          in
          if mode != "whole" then
            throw "wechselbalg: internal: free variable '${ast.value.name}' is captured as '${mode}' but read whole"
          else
            {
              ir = ir.select (ir.var env.param) [ (ir.string ast.value.name) ];
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
          foldWalk
            (
              acc: operand:
              let
                r = walkAST operand acc.known;
              in
              {
                parts = [ r.ir ] ++ acc.parts;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
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
        ir = ir.concatStrings (reverseList result.parts);
        inherit (result) defs known pending;
      }
    else if ast._expr == "call" && evalResult ? importedFn then
      let
        fnR = walkValue evalResult.importedFn known emptySeen;
        argsResult =
          foldWalk
            (
              acc: arg:
              let
                r = walkAST arg acc.known;
              in
              {
                args = [ r.ir ] ++ acc.args;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
              }
            )
            {
              args = [ ];
              defs = fnR.defs;
              pending = fnR.pending;
              known = fnR.known;
            }
            evalResult.restArgs;
      in
      {
        ir = builtins.foldl' (f: a: ir.apply f a) fnR.ir (reverseList argsResult.args);
        inherit (argsResult) defs known pending;
      }
    else if ast._expr == "call" then
      let
        funcResult = walkAST ast.value.function known;
        argsResult =
          foldWalk
            (
              acc: arg:
              let
                r = walkAST arg acc.known;
              in
              {
                args = [ r.ir ] ++ acc.args;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
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
        appliedIR = builtins.foldl' (fn: arg: ir.apply fn arg) funcResult.ir (reverseList argsResult.args);
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
        defs = update (update condR.defs thenR.defs) elseR.defs;
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
        defs = update aR.defs bR.defs;
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
        defs = update aR.defs bR.defs;
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
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "hasAttr" then
      let
        exprR = walkAST ast.value.expression known;
        pathR =
          foldWalk
            (
              acc: p:
              let
                r = walkAST p acc.known;
              in
              {
                path = [ r.ir ] ++ acc.path;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
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

        actualPath = reverseList pathR.path;
        pathLen = builtins.length actualPath;
        checks = builtins.genList (
          i:
          let
            elem = builtins.elemAt actualPath i;
            prefix = builtins.genList (j: builtins.elemAt actualPath j) i;
            base = if prefix == [ ] then exprR.ir else ir.select exprR.ir prefix;
          in
          ir.primopApp "hasAttr" [
            elem
            base
          ]
        ) pathLen;

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
        defs = update aR.defs bR.defs;
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
        defs = update aR.defs bR.defs;
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
        defs = update baseR.defs extR.defs;
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
        defs = update aR.defs bR.defs;
        pending = aR.pending ++ bR.pending;
        known = bR.known;
      }

    else if ast._expr == "path" then
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
          foldWalk
            (
              acc: elem:
              let
                r = walkAST elem acc.known;
              in
              {
                elements = [ r.ir ] ++ acc.elements;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
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
        ir = ir.list (reverseList result.elements);
        inherit (result) defs known pending;
      }

    else if ast._expr == "attrSet" then
      let
        names = builtins.attrNames ast.value.attrs;
        staticResult =
          foldWalk
            (
              acc: name:
              let
                r = walkAST ast.value.attrs.${name} acc.known;
              in
              {
                entries = [
                  {
                    inherit name;
                    value = r.ir;
                  }
                ]
                ++ acc.entries;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
              }
            )
            {
              entries = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            names;

        staticEntriesAttrSet = builtins.listToAttrs staticResult.entries;

        hasDynamic = ast.value.dynamicAttrs != [ ];
        hasStatic = names != [ ];
        dynamicResult =
          foldWalk
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
                guarded = ir.if_ (ir.eq nameR.ir ir.null_) (ir.attrs { }) pair;
              in
              {
                parts = [ guarded ] ++ acc.parts;
                defs = update (update acc.defs nameR.defs) valueR.defs;
                pending = nameR.pending ++ valueR.pending ++ acc.pending;
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

        dynParts = reverseList dynamicResult.parts;
        dynamicIR =
          if dynParts == [ ] then
            null
          else
            builtins.foldl' ir.update (builtins.head dynParts) (builtins.tail dynParts);
      in
      if ast.value.recursive then
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
          ir = ir.let_ staticEntriesAttrSet body split.local;
          defs = split.hoistable;
          pending = allPending;
          known = finalKnown;
        }
      else
        let
          staticIR = ir.attrs staticEntriesAttrSet;
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
        sp = analyze.staticPath ast.value.path;
        narrowed =
          if
            !(builtins.hasAttr "default" ast.value)
            && sp != null
            && sp != [ ]
            && analyze.isFreeVar ast.value.expression
            && (known._env or null) != null
            && (known._env.capture.mode.${ast.value.expression.value.name} or null) == "narrow"
          then
            analyze.joinKey ast.value.expression.value.name sp
          else
            null;
      in
      if narrowed != null then
        if !(known._env.capture.entries ? ${narrowed}) then
          throw "wechselbalg: internal: narrowed capture '${narrowed}' is missing from the capture plan"
        else
          {
            ir = ir.select (ir.var known._env.param) [ (ir.string narrowed) ];
            defs = { };
            pending = [ ];
            inherit known;
          }
      else
        let
          exprR = walkAST ast.value.expression known;
          pathR =
            foldWalk
              (
                acc: p:
                let
                  r = walkAST p acc.known;
                in
                {
                  path = [ r.ir ] ++ acc.path;
                  defs = update acc.defs r.defs;
                  pending = r.pending ++ acc.pending;
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

          allDefs = update pathR.defs defaultR.defs;
          allPending = pathR.pending ++ defaultR.pending;
        in
        {
          ir =
            if hasDefault then
              ir.selectOr exprR.ir (reverseList pathR.path) defaultR.ir
            else
              ir.select exprR.ir (reverseList pathR.path);
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
          foldWalk
            (
              acc: arg:
              let
                r = walkValue arg acc.known emptySeen;
              in
              {
                args = [ r.ir ] ++ acc.args;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
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
        ir = ir.primopApp ast.value.primop (reverseList argsResult.args);
        inherit (argsResult) defs known pending;
      }

    else if ast._expr == "path" then
      {
        ir = ir.primopApp "throw" [
          (ir.string "wechselbalg: path '${builtins.toJSON (ast.value or "unknown")}' cannot be translated")
        ];
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if ast._expr == "let" then
      let
        attrs = ast.value.attrs.value.attrs;
        names = builtins.attrNames attrs;
        bindingsResult =
          foldWalk
            (
              acc: name:
              let
                r = walkAST attrs.${name} acc.known;
              in
              {
                bindings = [
                  {
                    inherit name;
                    value = r.ir;
                  }
                ]
                ++ acc.bindings;
                defs = update acc.defs r.defs;
                pending = r.pending ++ acc.pending;
                known = r.known;
              }
            )
            {
              bindings = [ ];
              defs = { };
              pending = [ ];
              inherit known;
            }
            names;

        bindingsAttrSet = builtins.listToAttrs bindingsResult.bindings;
        bodyResult = walkAST ast.value.body bindingsResult.known;
        allDefs = update bindingsResult.defs bodyResult.defs;
        allPending = bindingsResult.pending ++ bodyResult.pending;
        split = splitDefs allDefs;
      in
      {
        ir = ir.let_ bindingsAttrSet bodyResult.ir split.local;
        defs = split.hoistable;
        pending = allPending;
        known = bodyResult.known;
      }

    else if ast._expr == "with" then
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: 'with' expressions are not supported") ];
        defs = { };
        pending = [ ];
        inherit known;
      }

    else if ast._expr == "assert" then
      let
        condR = walkAST ast.value.condition known;
        bodyR = walkAST ast.value.body condR.known;
      in
      {
        ir = ir.if_ condR.ir bodyR.ir (
          ir.primopApp "throw" [ (ir.string "wechselbalg: assertion failed") ]
        );
        defs = update condR.defs bodyR.defs;
        pending = condR.pending ++ bodyR.pending;
        known = bodyR.known;
      }

    else
      {
        ir = ir.primopApp "throw" [ (ir.string "wechselbalg: unsupported AST node '${ast._expr}'") ];
        defs = { };
        pending = [ ];
        inherit known;
      };

  # ── Compile one code template ───────────────────────────────────
  walkFunctionBody =
    {
      name,
      value,
      key,
      known,
    }:
    let
      ast = builtins.reify value;
      template = known.templates.${key};

      known' =
        if template.closed then
          known // { _env = null; }
        else
          known
          // {
            _env = {
              param = envParam;
              inherit (template) capture;
            };
          };

      startCounter = known'.counter;
      priorBindings = known'.bindings;
      priorInstances = known'.instances;
      priorUsed = known'.used;

      bodyResult = walkAST ast.value.body known';
      paramsResult = walkParams ast.value.arguments bodyResult.known;
      splitBody = splitDefs (update bodyResult.defs paramsResult.defs);

      hasNewBindings = paramsResult.known.counter != startCounter;

      newBindingNames =
        if !hasNewBindings then
          [ ]
        else
          let
            diff = paramsResult.known.counter - startCounter;
            candidateIndices = builtins.genList (i: startCounter + i) diff;
            checkIdx =
              i:
              let
                cap = "__wb_cap_${toString i}";
                clo = "__wb_clo_${toString i}";
              in
              if paramsResult.known.bindings ? ${cap} then
                [ cap ]
              else if paramsResult.known.bindings ? ${clo} then
                [ clo ]
              else
                [ ];
          in
          builtins.concatMap checkIdx candidateIndices;

      localBodyBindings =
        if newBindingNames == [ ] then
          { }
        else
          builtins.listToAttrs (
            builtins.map (n: {
              name = n;
              value = paramsResult.known.bindings.${n};
            }) newBindingNames
          );

      scopedBodyIR =
        if localBodyBindings == { } then bodyResult.ir else ir.let_ localBodyBindings bodyResult.ir { };

      innerDef = ir.funcDef (paramsResult.params // reifyMeta ast known') scopedBodyIR splitBody.local;

      hoisted =
        if template.closed then
          innerDef // { _hoistable = true; }
        else
          ir.funcDef
            {
              identifier = envParam;
              formals = null;
              ellipsis = true;
            }
            (ir.ref "${name}__fn")
            {
              "${name}__fn" = innerDef;
            }
          // {
            _hoistable = true;
          };

      cleanedKnown =
        if !hasNewBindings then
          paramsResult.known
        else
          paramsResult.known
          // {
            bindings = priorBindings;
            instances = priorInstances;
            used = priorUsed;
          };
    in
    {
      def = {
        ${name} = hoisted;
      }
      // splitBody.hoistable;
      known = cleanedKnown;
      pending = (bodyResult.pending or [ ]) ++ paramsResult.pending;
    };

  # ── Top-level entry point ───────────────────────────────────────
  walk =
    value:
    let
      initial = walkValue value {
        counter = 0;
        templates = { };
        instances = { };
        bindings = { };
        used = { };
        _env = null;
      } emptySeen;

      initialState = {
        inherit (initial) ir defs known;
        queue = initial.pending or [ ];
      };

      fuel = builtins.genList (x: x) 50000;

      finalState = builtins.foldl' (
        state: _i:
        if state.queue == [ ] then
          state
        else
          let
            item = builtins.head state.queue;
            restQueue = builtins.tail state.queue;

            compiled = walkFunctionBody {
              inherit (item) name value key;
              inherit (state) known;
            };

            newDefs = update state.defs compiled.def;
            newQueue = restQueue ++ (compiled.pending or [ ]);
          in
          builtins.seq newDefs (
            builtins.seq compiled.known.counter (
              if newQueue == [ ] then
                builtins.seq newQueue state
                // {
                  defs = newDefs;
                  known = compiled.known;
                  queue = [ ];
                }
              else
                {
                  inherit (state) ir;
                  defs = newDefs;
                  known = compiled.known;
                  queue = newQueue;
                }
            )
          )
      ) initialState fuel;

      bindings = finalState.known.bindings;
      rootIR = if bindings == { } then finalState.ir else ir.let_ bindings finalState.ir { };

      result = {
        inherit (finalState) defs;
        ir = rootIR;
      };

      errors = validate.check result;
      shown = builtins.genList (i: builtins.elemAt errors i) (
        if builtins.length errors > 20 then 20 else builtins.length errors
      );

    in
    if finalState.queue != [ ] then
      throw "wechselbalg: exceeded fuel limit while compiling functions"
    else if errors != [ ] then
      throw ''
        wechselbalg: internal IR validation failed (${toString (builtins.length errors)} error(s)):
          ${builtins.concatStringsSep "\n  " shown}''
    else
      result;

in
walk
