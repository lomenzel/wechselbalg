# Decoupled C++ Translation Unit Renderer
#
# Emits completely independent .cpp files for each Merkle SCC unit.
# Each TU forward-declares only the exact symbols it references.
# Large SCCs (>15 items) are automatically chunked into parallel compilation units.

{
  pkgs ? null,
}:
let
  cppBackend = import ./backends/cpp.nix;
  cppPrimopDefs = import ./primops/cpp.nix;
  renderer = import ./render.nix;

  join = sep: list: builtins.concatStringsSep sep list;

  # Maximum number of definitions per .cpp file before splitting
  chunkSize = 15;

  # Partition a list into chunks of at most `size` items
  chunkList =
    size: list:
    let
      len = builtins.length list;
      numChunks = (len + size - 1) / size;
    in
    if len <= size then
      [ list ]
    else
      builtins.genList (
        c:
        let
          start = c * size;
          chunkLen = if start + size > len then len - start else size;
        in
        builtins.genList (i: builtins.elemAt list (start + i)) chunkLen
      ) numChunks;

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

  hasPrefix =
    prefix: str:
    let
      len = builtins.stringLength prefix;
    in
    builtins.stringLength str >= len && builtins.substring 0 len str == prefix;

  isMerkleSym = ref: hasPrefix "__wb_fn_" ref || hasPrefix "__wb_val_" ref;

  reservedAttrs = builtins.listToAttrs (
    builtins.map
      (w: {
        name = w;
        value = true;
      })
      [
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
        "xor"
        "bitand"
        "bitor"
        "compl"
        "and_eq"
        "or_eq"
        "xor_eq"
        "not_eq"
        "export"
        "import"
        "module"
        "requires"
        "concept"
        "long"
        "short"
        "signed"
        "unsigned"
        "asm"
        "explicit"
        "mutable"
        "constexpr"
        "consteval"
        "constinit"
        "decltype"
        "noexcept"
        "typeid"
      ]
  );

  sanitize =
    name:
    let
      cleaned = builtins.replaceStrings [ "'" "-" ] [ "_q" "_h" ] name;
    in
    if reservedAttrs ? ${cleaned} then "__wb_rsv_${cleaned}" else cleaned;

  # Render a function definition (recursive for localDefs)
  renderDef =
    backend: name: def:
    let
      params = def.params // {
        formals =
          if def.params.formals != null then
            builtins.map (
              f:
              f
              // {
                default = if f.hasDefault then renderer.renderNode backend f.default else null;
              }
            ) def.params.formals
          else
            null;
        env =
          if (def.params.envIR or null) == null then null else renderer.renderNode backend def.params.envIR;
      };
      localDefNames = builtins.attrNames (def.localDefs or { });
      renderedLocalDefs = builtins.map (n: renderDef backend n def.localDefs.${n}) localDefNames;
    in
    backend.renderFuncDef name params (renderer.renderNode backend def.body) renderedLocalDefs
      localDefNames;

  collectPrimopsNode =
    node:
    let
      t = node._t or null;
    in
    if t == null then
      [ ]
    else if t == "primop" then
      [ node.name ]
    else if t == "list" then
      builtins.concatMap collectPrimopsNode node.elements
    else if t == "attrs" then
      builtins.concatMap (n: collectPrimopsNode node.entries.${n}) (builtins.attrNames node.entries)
    else if t == "apply" then
      collectPrimopsNode node.fn ++ collectPrimopsNode node.arg
    else if t == "closure" then
      [ node.template ]
      ++ builtins.concatMap (n: collectPrimopsNode node.env.${n}) (builtins.attrNames node.env)
    else if t == "if" then
      collectPrimopsNode node.cond ++ collectPrimopsNode node.then_ ++ collectPrimopsNode node.else_
    else if t == "eq" || t == "lessThan" || t == "add" || t == "concatLists" then
      collectPrimopsNode node.a ++ collectPrimopsNode node.b
    else if t == "update" then
      collectPrimopsNode node.base ++ collectPrimopsNode node.ext
    else if t == "select" then
      collectPrimopsNode node.expr
      ++ builtins.concatMap collectPrimopsNode node.path
      ++ (if node.default != null then collectPrimopsNode node.default else [ ])
    else if t == "let" then
      builtins.concatMap (n: collectPrimopsNode node.bindings.${n}) (builtins.attrNames node.bindings)
      ++ collectPrimopsNode node.body
      ++ builtins.concatMap (n: collectPrimopsDef node.localDefs.${n}) (
        builtins.attrNames (node.localDefs or { })
      )
    else
      [ ];

  collectPrimopsDef =
    def:
    let
      fromFormals =
        if def.params.formals or null != null then
          builtins.concatMap (
            f: if f.hasDefault or false then collectPrimopsNode f.default else [ ]
          ) def.params.formals
        else
          [ ];
      fromEnv = if def.params.envIR or null != null then collectPrimopsNode def.params.envIR else [ ];
      fromLocalDefs = builtins.concatMap (n: collectPrimopsDef def.localDefs.${n}) (
        builtins.attrNames (def.localDefs or { })
      );
    in
    fromFormals ++ fromEnv ++ collectPrimopsNode def.body ++ fromLocalDefs;

  collectPrimopsItem =
    item: if item.isFunc then collectPrimopsDef item.def else collectPrimopsNode item.expr;

  collectItemRefs =
    item:
    let
      cRefs = import ./merkle.nix;
    in
    # Use collectItemRefs pattern
    if item.isFunc then
      let
        def = item.def;
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
      fromFormals ++ fromEnv ++ collectRefs def.body ++ fromLocalDefs
    else
      collectRefs item.expr;

  collectRefs =
    node:
    let
      t = node._t or null;
    in
    if t == null then
      [ ]
    else if t == "ref" || t == "var" then
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

  render =
    {
      merkleResult, # Output of merkle.process
      namespace, # C++ namespace, e.g. "my_app"
      value, # Top-level attrset to export
      chunkSize,
    }:
    let
      validChunkSize =
        if !builtins.isInt chunkSize || chunkSize < 1 then
          throw "wechselbalg: chunkSize must be a positive integer"
        else
          chunkSize;
      detailNs = "${namespace}::detail";
      runtimeHpp = builtins.readFile ./runtime/cpp/value.hpp;

      # ── 1. Render SCC Units (chunked if > chunkSize symbols) ─────
      renderSccUnit =
        unit:
        let
          nameChunks = chunkList validChunkSize unit.names;
          isChunked = builtins.length nameChunks > 1;

          renderChunk =
            chunkIdx: chunkNames:
            let
              chunkNamesSet = builtins.listToAttrs (
                builtins.map (n: {
                  name = n;
                  value = true;
                }) chunkNames
              );

              # Collect all referenced symbols in this chunk
              allRefsInChunk = uniqueStrings (
                builtins.concatMap (name: collectItemRefs unit.items.${name}) chunkNames
              );

              # Forward declare any external symbols referenced by this chunk
              externDecls = builtins.map (dep: "  extern std::shared_ptr<Value> ${dep};") (
                builtins.filter (ref: isMerkleSym ref && !(chunkNamesSet ? ${ref})) allRefsInChunk
              );

              # Primops used by this chunk
              usedPrimops = uniqueStrings (
                builtins.concatMap (name: collectPrimopsItem unit.items.${name}) chunkNames
              );
              externPrimopDecls = builtins.map (p: "  extern Value __wb_primop_${sanitize p};") usedPrimops;

              # Symbols defined in this chunk
              symbolDefs = builtins.map (
                name: "  std::shared_ptr<Value> ${name} = std::make_shared<Value>();"
              ) chunkNames;

              # Initializers
              initStmts = builtins.map (
                name:
                let
                  item = unit.items.${name};
                in
                if item.isFunc then
                  renderDef cppBackend name item.def
                else
                  "*${name} = Value::thunk([=]() -> Value { return ${renderer.renderNode cppBackend item.expr}; });"
              ) chunkNames;

              externBlock =
                if (externDecls ++ externPrimopDecls) == [ ] then
                  ""
                else
                  join "\n" (externDecls ++ externPrimopDecls) + "\n";

              chunkSuffix = if isChunked then "_c${toString chunkIdx}" else "";
              sccHash = "${unit.sccHash}${chunkSuffix}";
              fileName = "scc_${sccHash}.cpp";

              content = ''
                // Auto-generated by Wechselbalg (SCC: ${unit.sccHash}${
                  if isChunked then ", chunk ${toString chunkIdx}" else ""
                })
                #include "wechselbalg/value.hpp"

                namespace ${detailNs} {
                ${externBlock}${join "\n" symbolDefs}

                namespace {
                  [[maybe_unused]] const int _wb_init_${unit.sccHash}${chunkSuffix} = []() -> int {
                    ${join "\n    " initStmts}
                    return 0;
                  }();
                }
                } // namespace ${detailNs}
              '';
            in
            {
              inherit
                sccHash
                fileName
                content
                isChunked
                ;
            };
        in
        builtins.genList (i: renderChunk i (builtins.elemAt nameChunks i)) (builtins.length nameChunks);

      # Flatten all rendered units (chunks seamlessly become parallel units)
      sccUnitsRendered = builtins.concatMap renderSccUnit merkleResult.sccs;

      # ── 2. Collect all primops across the entire project ───────────
      allUsedPrimops = uniqueStrings (
        builtins.concatMap (
          unit: builtins.concatMap (name: collectPrimopsItem unit.items.${name}) unit.names
        ) merkleResult.sccs
        ++ collectPrimopsNode merkleResult.ir
      );

      knownPrimops = builtins.filter (p: builtins.hasAttr p cppPrimopDefs) allUsedPrimops;
      unknownPrimops = builtins.filter (p: !(builtins.hasAttr p cppPrimopDefs)) allUsedPrimops;

      primopDefsCpp = builtins.map (
        n: "  Value __wb_primop_${sanitize n} = Value::primop(${builtins.toJSON n}, ${cppPrimopDefs.${n}});"
      ) knownPrimops;

      unknownDefCpp =
        if unknownPrimops != [ ] then
          [
            ''
              Value __wb_unknown_primop(const std::string& name) {
                return Value::primop(name, Value::lambda([name](const Value&) -> Value {
                  throw std::runtime_error("wechselbalg: primop '" + name + "' is not implemented in C++");
                }));
              }''
          ]
        else
          [ ];

      primopsCpp = ''
        // Auto-generated by Wechselbalg: Primop definitions
        #include "wechselbalg/value.hpp"

        namespace ${detailNs} {
        ${join "\n" (primopDefsCpp ++ unknownDefCpp)}
        }
      '';

      # ── 3. Render Root Expression & Public Interface ───────────────
      rootExternFuncs = builtins.map (
        dep: "  extern std::shared_ptr<Value> ${dep};"
      ) merkleResult.rootDeps;

      rootUsedPrimops = builtins.filter (p: builtins.hasAttr p cppPrimopDefs) (
        collectPrimopsNode merkleResult.ir
      );
      rootExternPrimops = builtins.map (p: "  extern Value __wb_primop_${sanitize p};") rootUsedPrimops;

      rootExterns = join "\n" (rootExternFuncs ++ rootExternPrimops);
      renderedRootIR = renderer.renderNode cppBackend merkleResult.ir;

      exportedAttrNames = builtins.attrNames value;
      exportedValuesCpp = builtins.map (attr: ''
        Value ${sanitize attr} = Value::thunk([]() -> Value {
          return ${detailNs}::__wb_get_root_expr()[${builtins.toJSON attr}];
        });
      '') exportedAttrNames;

      rootCpp = ''
        // Auto-generated by Wechselbalg: Root Entry Point
        #include "${namespace}.hpp"
        #include "wechselbalg/value.hpp"

        namespace ${detailNs} {
        ${rootExterns}

        Value __wb_get_root_expr() {
          static Value root = Value::thunk([]() -> Value {
            return ${renderedRootIR};
          });
          return root;
        }
        } // namespace ${detailNs}

        namespace ${namespace} {
        ${join "\n" exportedValuesCpp}
        }
      '';

      publicHpp = ''
        // Auto-generated by Wechselbalg: Public Interface
        #pragma once
        #include "wechselbalg/value.hpp"

        namespace ${namespace} {
        ${join "\n" (builtins.map (attr: "  extern Value ${sanitize attr};") exportedAttrNames)}
        }
      '';

    in
    {
      inherit namespace;
      "include/wechselbalg/value.hpp" = runtimeHpp;
      "include/${namespace}.hpp" = publicHpp;
      "src/_primops.cpp" = primopsCpp;
      "src/_root.cpp" = rootCpp;
      sccUnits = sccUnitsRendered;
    };
in
{
  inherit render;
}
