# Backend interface.
#
# A backend is an attrset conforming to this shape. The `render` function
# in this module takes a backend + walk result and produces the final string.
#
# Backend contract:
# {
#   name         : string          — e.g. "javascript"
#   extension    : string          — e.g. "js"
#   renderNode   : ir-node → string
#   renderFuncDef: name → params → bodyString → string
#   renderProgram: { defs : [string]; expr : string; } → string
#   primops      : { name = string; ... }
# }

let
  ir = import ./ir.nix;

  # Render a single IR node using the backend.
  renderNode = backend: node:
    if node._t == "int" then
      backend.renderInt node.value

    else if node._t == "float" then
      backend.renderFloat node.value

    else if node._t == "string" then
      backend.renderString node.value

    else if node._t == "bool" then
      backend.renderBool node.value

    else if node._t == "null" then
      backend.renderNull

    else if node._t == "list" then
      backend.renderList (builtins.map (renderNode backend) node.elements)

    else if node._t == "attrs" then
      backend.renderAttrs (builtins.mapAttrs (_: renderNode backend) node.entries)

    else if node._t == "rec-attrs" then
      backend.renderRecAttrs (builtins.mapAttrs (_: renderNode backend) node.entries)

    else if node._t == "lazy-attrs" then
      backend.renderLazyAttrs (builtins.mapAttrs (_: renderNode backend) node.entries)

    else if node._t == "let" then
      let
        renderedBindings = builtins.mapAttrs (_: renderNode backend) node.bindings;
        renderedBody = renderNode backend node.body;
        localDefNames = builtins.attrNames node.localDefs;
        renderedLocalDefs = builtins.map
          (name: renderDef backend name node.localDefs.${name})
          localDefNames;
      in
      backend.renderLet renderedBindings renderedBody renderedLocalDefs localDefNames

    else if node._t == "thunk" then
      backend.renderThunk (renderNode backend node.body)

    else if node._t == "ref" then
      backend.renderRef node.name

    else if node._t == "apply" then
      backend.renderApply (renderNode backend node.fn) (renderNode backend node.arg)

    else if node._t == "var" then
      backend.renderVar node.name

    else if node._t == "if" then
      backend.renderIf
        (renderNode backend node.cond)
        (renderNode backend node.then_)
        (renderNode backend node.else_)

    else if node._t == "not" then
      backend.renderNot (renderNode backend node.value)

    else if node._t == "and" then
      backend.renderAnd (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "or" then
      backend.renderOr (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "implies" then
      backend.renderImplies (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "eq" then
      backend.renderEq (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "neq" then
      backend.renderNeq (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "lessThan" then
      backend.renderLessThan (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "add" then
      backend.renderAdd (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "sub" then
      backend.renderSub (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "mul" then
      backend.renderMul (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "div" then
      backend.renderDiv (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "concatStrings" then
      backend.renderConcatStrings (builtins.map (renderNode backend) node.parts)

    else if node._t == "update" then
      backend.renderUpdate (renderNode backend node.base) (renderNode backend node.ext)

    else if node._t == "concatLists" then
      backend.renderConcatLists (renderNode backend node.a) (renderNode backend node.b)

    else if node._t == "select" then
      backend.renderSelect
        (renderNode backend node.expr)
        (builtins.map (renderNode backend) node.path)
        (if node.default != null then renderNode backend node.default else null)

    else if node._t == "primop" then
      if builtins.hasAttr node.name backend.primops
      then backend.primops.${node.name}
      else throw "wechselbalg: backend '${backend.name}' does not implement primop '${node.name}'"

    else if node._t == "primopApp" then
      let
        primopCode =
          if builtins.hasAttr node.name backend.primops
          then backend.primops.${node.name}
          else throw "wechselbalg: backend '${backend.name}' does not implement primop '${node.name}'";
        renderedArgs = builtins.map (renderNode backend) node.args;
      in
      backend.renderPrimopApp primopCode renderedArgs

    else
      throw "wechselbalg render: unknown IR node type '${node._t}'";


  # Render function parameters for a definition
  renderParams = backend: params:
    backend.renderParams params;

  # Render a complete function definition.
  # Pre-renders default values in formals so the backend gets strings.
  # Also renders any localDefs (nested lambdas scoped to this function).
  renderDef = backend: name: def:
    let
      params = def.params // {
        formals =
          if def.params.formals != null
          then builtins.map (f: f // {
            default =
              if f.hasDefault
              then renderNode backend f.default
              else null;
          }) def.params.formals
          else null;
      };
      localDefNames = builtins.attrNames (def.localDefs or {});
      renderedLocalDefs = builtins.map
        (n: renderDef backend n def.localDefs.${n})
        localDefNames;
    in
    backend.renderFuncDef name params (renderNode backend def.body) renderedLocalDefs localDefNames;

  # ── Main entry point ────────────────────────────────────────────
  # Takes a backend and a walk result { ir; defs; } and produces
  # the final code string.
  render = backend: walkResult:
    let
      defNames = builtins.attrNames walkResult.defs;
      renderedDefs = builtins.map
        (name: renderDef backend name walkResult.defs.${name})
        defNames;
      renderedExpr = renderNode backend walkResult.ir;
    in
    backend.renderProgram {
      defs = renderedDefs;
      defNames = defNames;
      expr = renderedExpr;
    };

in
{
  inherit render renderNode;
}
