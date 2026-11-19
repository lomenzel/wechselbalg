# Merkle DAG Canonicalization for Wechselbalg IR.
#
# Unifies function templates (defs) and closure/capture bindings into
# content-addressed definitions:
#   __wb_fn_<hash> (functions)
#   __wb_val_<hash> (values / closures)
#
# Handles mutual recursion and cycle-knots via SCC clustering.

let
  sccUtil = import ./scc.nix;

  hasPrefix =
    prefix: str:
    let
      len = builtins.stringLength prefix;
    in
    builtins.stringLength str >= len && builtins.substring 0 len str == prefix;

  isMerkleSym = ref: hasPrefix "__wb_fn_" ref || hasPrefix "__wb_val_" ref;

  reverseList =
    list:
    let
      len = builtins.length list;
    in
    builtins.genList (i: builtins.elemAt list (len - 1 - i)) len;

  # Deduplicate list of strings efficiently
  uniqueStrings =
    list:
    builtins.attrNames (
      builtins.listToAttrs (
        builtins.map (x: {
          name = x;
          value = null;
        }) list
      )
    );

  # ── Collect all symbol references in an IR node ─────────────────
  collectRefs =
    node:
    let
      t = node._t or null;
    in
    if t == null then
      [ ]
    else if t == "ref" || t == "var" then
      [ node.name ]
    else if t == "path" then
      collectRefs node.meta
    else if t == "pathValue" then
      [ node.name ]
    else if t == "list" then
      builtins.concatMap collectRefs node.elements
    else if t == "attrs" then
      builtins.concatMap (n: collectRefs node.entries.${n}) (builtins.attrNames node.entries)
    else if t == "apply" then
      collectRefs node.fn ++ collectRefs node.arg
    else if t == "closure" then
      [ node.template ] ++ builtins.concatMap (n: collectRefs node.env.${n}) (builtins.attrNames node.env)
    else if t == "if" then
      collectRefs node.cond ++ collectRefs node.then_ ++ collectRefs node.else_
    else if t == "eq" || t == "add" || t == "lessThan" || t == "concatLists" then
      collectRefs node.a ++ collectRefs node.b
    else if t == "update" then
      collectRefs node.base ++ collectRefs node.ext
    else if t == "select" then
      collectRefs node.expr
      ++ builtins.concatMap collectRefs node.path
      ++ (if node.default != null then collectRefs node.default else [ ])
    else if t == "let" then
      builtins.concatMap (n: collectRefs node.bindings.${n}) (builtins.attrNames node.bindings)
      ++ collectRefs node.body
      ++ builtins.concatMap (n: collectDefRefs node.localDefs.${n}) (
        builtins.attrNames (node.localDefs or { })
      )
    else
      [ ];

  collectDefRefs =
    def:
    let
      fromFormals =
        if def.params.formals or null != null then
          builtins.concatMap (
            f: if f.hasDefault or false then collectRefs f.default else [ ]
          ) def.params.formals
        else
          [ ];
      fromEnv = if def.params.envIR or null != null then collectRefs def.params.envIR else [ ];
      fromLocalDefs = builtins.concatMap (n: collectDefRefs def.localDefs.${n}) (
        builtins.attrNames (def.localDefs or { })
      );
    in
    fromFormals ++ fromEnv ++ collectRefs def.body ++ fromLocalDefs;

  collectItemRefs = item: if item.isFunc then collectDefRefs item.def else collectRefs item.expr;

  # ── Reachability Pruning ─────────────────────────────────────────
  pruneItems =
    rootIR: allItems:
    let
      bfs =
        frontier: visited:
        if frontier == [ ] then
          visited
        else
          let
            validNames = builtins.filter (n: !(visited ? ${n}) && (allItems ? ${n})) frontier;
            newVisited =
              visited
              // builtins.listToAttrs (
                builtins.map (n: {
                  name = n;
                  value = true;
                }) validNames
              );
            nextFrontier = builtins.concatMap (n: collectItemRefs allItems.${n}) validNames;
          in
          if validNames == [ ] then visited else bfs nextFrontier newVisited;

      reachableSet = bfs (collectRefs rootIR) { };
    in
    builtins.intersectAttrs reachableSet allItems;

  # ── IR Symbol Renaming Substitution ──────────────────────────────
  substNode =
    renames: node:
    let
      t = node._t or null;
      sub = substNode renames;
    in
    if t == null then
      node
    else if t == "ref" || t == "var" then
      if renames ? ${node.name} then node // { name = renames.${node.name}; } else node
    else if t == "pathValue" then
      # The pmeta binding is a string literal in the Nix backend; renaming it
      # would break the literal. Everywhere else it is a real symbol.
      if builtins.substring 0 6 node.name == "__wb_p" && renames ? ${node.name} then
        node // { name = renames.${node.name}; }
      else if renames ? ${node.name} then
        node // { name = renames.${node.name}; }
      else
        node
    else if t == "path" then
      node // { meta = sub node.meta; }
    else if t == "closure" then
      let
        newTpl = if renames ? ${node.template} then renames.${node.template} else node.template;
        newEnv = builtins.mapAttrs (_: sub) node.env;
      in
      node
      // {
        template = newTpl;
        env = newEnv;
      }
    else if t == "apply" then
      node
      // {
        fn = sub node.fn;
        arg = sub node.arg;
      }
    else if t == "list" then
      node // { elements = builtins.map sub node.elements; }
    else if t == "attrs" then
      node // { entries = builtins.mapAttrs (_: sub) node.entries; }
    else if t == "if" then
      node
      // {
        cond = sub node.cond;
        then_ = sub node.then_;
        else_ = sub node.else_;
      }
    else if t == "eq" || t == "lessThan" || t == "add" || t == "concatLists" then
      node
      // {
        a = sub node.a;
        b = sub node.b;
      }
    else if t == "update" then
      node
      // {
        base = sub node.base;
        ext = sub node.ext;
      }
    else if t == "select" then
      node
      // {
        expr = sub node.expr;
        path = builtins.map sub node.path;
        default = if node.default != null then sub node.default else null;
      }
    else if t == "let" then
      node
      // {
        bindings = builtins.mapAttrs (_: sub) node.bindings;
        body = sub node.body;
        localDefs = builtins.mapAttrs (_: substFuncDef renames) (node.localDefs or { });
      }
    else
      node;

  substFuncDef =
    renames: def:
    let
      localNames = builtins.attrNames (def.localDefs or { });
      sortedLocalNames = builtins.sort (a: b: a < b) localNames;
      localRenames = builtins.listToAttrs (
        builtins.genList (i: {
          name = builtins.elemAt sortedLocalNames i;
          value = "__wb_loc_${toString i}";
        }) (builtins.length sortedLocalNames)
      );

      effectiveRenames = renames // localRenames;
      sub = substNode effectiveRenames;

      newFormals =
        if def.params.formals or null != null then
          builtins.map (
            f:
            f
            // {
              default = if f.hasDefault or false then sub f.default else null;
            }
          ) def.params.formals
        else
          null;
      newEnvIR = if def.params.envIR or null != null then sub def.params.envIR else null;

      normalizedLocalDefs =
        if def.localDefs or null != null then
          builtins.listToAttrs (
            builtins.genList (i: {
              name = "__wb_loc_${toString i}";
              value = substFuncDef effectiveRenames def.localDefs.${builtins.elemAt sortedLocalNames i};
            }) (builtins.length sortedLocalNames)
          )
        else
          { };
    in
    def
    // {
      params = def.params // {
        formals = newFormals;
        envIR = newEnvIR;
      };
      body = sub def.body;
      localDefs = normalizedLocalDefs;
    };

  substItem =
    renames: item:
    if item.isFunc then
      item // { def = substFuncDef renames item.def; }
    else
      item // { expr = substNode renames item.expr; };

  # ── Safe JSON Representation for Hashing ─────────────────────────
  safeNodeForJSON =
    node:
    let
      t = node._t or null;
    in
    if t == null then
      node
    else if t == "attrs" then
      let
        names = builtins.sort (a: b: a < b) (builtins.attrNames node.entries);
      in
      {
        _t = "attrs";
        entries = builtins.map (n: {
          name = n;
          value = safeNodeForJSON node.entries.${n};
        }) names;
      }
    else if t == "pathValue" then
      # The path string is stable and the binding name is assigned by the
      # walker; no sub-IR to canonicalise.
      {
        _t = "pathValue";
        path = node.path;
        name = node.name;
      }
    else if t == "path" then
      # Canonicalise the meta record; the path string itself is stable.
      let
        metaSafe = safeNodeForJSON node.meta;
      in
      {
        _t = "path";
        path = node.path;
        meta = metaSafe;
      }
    else if t == "closure" then
      let
        names = builtins.sort (a: b: a < b) (builtins.attrNames node.env);
      in
      {
        _t = "closure";
        inherit (node) template;
        env = builtins.map (n: {
          name = n;
          value = safeNodeForJSON node.env.${n};
        }) names;
      }
    else if t == "let" then
      let
        names = builtins.sort (a: b: a < b) (builtins.attrNames node.bindings);
        locNames = builtins.sort (a: b: a < b) (builtins.attrNames (node.localDefs or { }));
      in
      {
        _t = "let";
        bindings = builtins.map (n: {
          name = n;
          value = safeNodeForJSON node.bindings.${n};
        }) names;
        body = safeNodeForJSON node.body;
        localDefs = builtins.map (n: {
          name = n;
          value = safeDefForJSON node.localDefs.${n};
        }) locNames;
      }
    else if t == "list" then
      {
        _t = "list";
        elements = builtins.map safeNodeForJSON node.elements;
      }
    else if t == "apply" then
      {
        _t = "apply";
        fn = safeNodeForJSON node.fn;
        arg = safeNodeForJSON node.arg;
      }
    else if t == "if" then
      {
        _t = "if";
        cond = safeNodeForJSON node.cond;
        then_ = safeNodeForJSON node.then_;
        else_ = safeNodeForJSON node.else_;
      }
    else if t == "eq" || t == "lessThan" || t == "add" || t == "concatLists" then
      {
        _t = t;
        a = safeNodeForJSON node.a;
        b = safeNodeForJSON node.b;
      }
    else if t == "update" then
      {
        _t = "update";
        base = safeNodeForJSON node.base;
        ext = safeNodeForJSON node.ext;
      }
    else if t == "select" then
      {
        _t = "select";
        expr = safeNodeForJSON node.expr;
        path = builtins.map safeNodeForJSON node.path;
        default = if node.default != null then safeNodeForJSON node.default else null;
      }
    else
      node;

  safeDefForJSON =
    def:
    let
      locNames = builtins.sort (a: b: a < b) (builtins.attrNames (def.localDefs or { }));
    in
    {
      params = def.params // {
        formals =
          if def.params.formals or null != null then
            builtins.map (
              f:
              f
              // {
                default = if f.hasDefault or false then safeNodeForJSON f.default else null;
              }
            ) def.params.formals
          else
            null;
        envIR = if def.params.envIR or null != null then safeNodeForJSON def.params.envIR else null;
      };
      body = safeNodeForJSON def.body;
      localDefs = builtins.map (n: {
        name = n;
        value = safeDefForJSON def.localDefs.${n};
      }) locNames;
    };

  safeItemForJSON =
    item:
    if item.isFunc then
      {
        isFunc = true;
        def = safeDefForJSON item.def;
      }
    else
      {
        isFunc = false;
        expr = safeNodeForJSON item.expr;
      };

  # ── Main Merkle Pipeline ─────────────────────────────────────────
  process =
    walkResult:
    let
      # 1. Unpack root let if it was wrapping walk.nix's captured bindings
      hasRootBindings = walkResult.ir._t == "let" && (walkResult.ir.localDefs or { }) == { };
      rootBindings = if hasRootBindings then walkResult.ir.bindings else { };
      rawRootIR = if hasRootBindings then walkResult.ir.body else walkResult.ir;

      # 2. Package all functions and value bindings into unified items
      funcItems = builtins.mapAttrs (_: def: {
        isFunc = true;
        inherit def;
      }) walkResult.defs;
      valItems = builtins.mapAttrs (_: expr: {
        isFunc = false;
        inherit expr;
      }) rootBindings;
      allItems = funcItems // valItems;

      # 3. Prune unreachable items starting from rawRootIR
      reachableItems = pruneItems rawRootIR allItems;
      itemNames = builtins.attrNames reachableItems;

      # 4. Build dependency graph between all reachable items
      callGraph = builtins.listToAttrs (
        builtins.map (name: {
          inherit name;
          value = builtins.filter (dep: reachableItems ? ${dep}) (collectItemRefs reachableItems.${name});
        }) itemNames
      );

      # 5. Partition into SCCs in bottom-up order (leaves first)
      sccList = sccUtil.scc callGraph;

      # 6. Fold bottom-up: hash and rename each SCC
      finalAcc =
        builtins.foldl'
          (
            acc: sccGroup:
            let
              # a. Replace external dependencies with already-assigned Merkle names
              itemsWithExternalRenamed = builtins.map (name: {
                inherit name;
                item = substItem acc.renames reachableItems.${name};
              }) sccGroup;

              # b. Canonicalize intra-SCC references to break symmetry / cycle
              intraMask = builtins.listToAttrs (
                builtins.map (entry: {
                  name = entry.name;
                  value = "@scc_placeholder";
                }) itemsWithExternalRenamed
              );

              decorated = builtins.map (entry: {
                inherit (entry) name item;
                sortKey = builtins.hashString "sha256" (
                  builtins.toJSON (safeItemForJSON (substItem intraMask entry.item))
                );
              }) itemsWithExternalRenamed;

              sortedGroup = builtins.sort (a: b: a.sortKey < b.sortKey) decorated;

              # Assign canonical placeholder names (@scc_0, @scc_1, ...)
              canonMapping = builtins.listToAttrs (
                builtins.genList (i: {
                  name = (builtins.elemAt sortedGroup i).name;
                  value = "@scc_${toString i}";
                }) (builtins.length sortedGroup)
              );

              canonicalItemsList = builtins.map (entry: substItem canonMapping entry.item) sortedGroup;

              # c. Compute the Merkle hash for this entire SCC
              safeItems = builtins.map safeItemForJSON canonicalItemsList;
              rawHash = builtins.hashString "sha256" (builtins.toJSON safeItems);
              sccHash = builtins.substring 0 16 rawHash;

              # d. Determine final names (functions get __wb_fn_, values get __wb_val_)
              isSingle = builtins.length sortedGroup == 1;
              nameMappingList = builtins.genList (i: {
                oldName = (builtins.elemAt sortedGroup i).name;
                newName =
                  let
                    pfx = if (builtins.elemAt sortedGroup i).item.isFunc then "__wb_fn_" else "__wb_val_";
                  in
                  if isSingle then "${pfx}${sccHash}" else "${pfx}${sccHash}_${toString i}";
              }) (builtins.length sortedGroup);

              sccPlaceholderToFinal = builtins.listToAttrs (
                builtins.genList (i: {
                  name = "@scc_${toString i}";
                  value = (builtins.elemAt nameMappingList i).newName;
                }) (builtins.length sortedGroup)
              );

              # Final items with all references fully resolved
              finalSccItems = builtins.listToAttrs (
                builtins.genList (i: {
                  name = (builtins.elemAt nameMappingList i).newName;
                  value = substItem sccPlaceholderToFinal (builtins.elemAt canonicalItemsList i);
                }) (builtins.length sortedGroup)
              );

              oldToNew = builtins.listToAttrs (
                builtins.map (m: {
                  name = m.oldName;
                  value = m.newName;
                }) nameMappingList
              );

              # Collect external dependencies for this unit
              allRefsInScc = builtins.concatMap collectItemRefs (builtins.attrValues finalSccItems);
              externDeps = builtins.filter (ref: isMerkleSym ref && !(finalSccItems ? ${ref})) (
                uniqueStrings allRefsInScc
              );

              unit = {
                inherit sccHash externDeps;
                names = builtins.attrNames finalSccItems;
                items = finalSccItems;
              };
            in
            {
              renames = acc.renames // oldToNew;
              # O(1) prepend instead of acc.units ++ [ unit ]
              units = [ unit ] ++ acc.units;
            }
          )
          {
            renames = { };
            units = [ ];
          }
          sccList;

      # 7. Rewrite root IR using final Merkle names
      rewrittenIR = substNode finalAcc.renames rawRootIR;

      # External symbols directly referenced by root IR
      rootRefs = collectRefs rewrittenIR;
      rootDeps = builtins.filter isMerkleSym (uniqueStrings rootRefs);
    in
    {
      ir = rewrittenIR;
      sccs = reverseList finalAcc.units;
      inherit rootDeps;
    };
in
{
  inherit process;
}
