# Post-walk IR validator.
#
# Implements invariant I4 from docs/closure-conversion.md: every `ref` / `var`
# node must resolve to a name that is in scope — a top-level def, a top-level
# binding, an enclosing `localDefs` entry, a function parameter, or an
# enclosing `let` binding.
#
# `ref` and `var` share one namespace because every backend renders both as a
# bare (sanitised) identifier.
#
# Returns a list of human-readable error strings; `[ ]` means valid.

let
  addNames =
    scope: names:
    scope
    // builtins.listToAttrs (
      builtins.map (n: {
        name = n;
        value = true;
      }) names
    );

  paramNames =
    params:
    (if params.envParam or null != null then [ params.envParam ] else [ ])
    ++ (if params.identifier or null != null then [ params.identifier ] else [ ])
    ++ (if params.formals or null != null then builtins.map (f: f.name) params.formals else [ ]);

  indices = list: builtins.genList (i: i) (builtins.length list);

  checkNode =
    path: scope: node:
    let
      t = node._t;
      sub = suffix: checkNode "${path}.${suffix}" scope;
    in
    if t == "ref" || t == "var" then
      if builtins.hasAttr node.name scope then [ ] else [ "${path}: unbound ${t} '${node.name}'" ]

    else if
      t == "int" || t == "float" || t == "string" || t == "bool" || t == "null" || t == "primop"
    then
      [ ]

    else if t == "list" then
      builtins.concatMap (i: checkNode "${path}[${toString i}]" scope (builtins.elemAt node.elements i)) (
        indices node.elements
      )

    else if t == "attrs" then
      builtins.concatMap (n: checkNode "${path}.${n}" scope node.entries.${n}) (
        builtins.attrNames node.entries
      )

    else if t == "apply" then
      sub "fn" node.fn ++ sub "arg" node.arg

    else if t == "closure" then
      (
        if builtins.hasAttr node.template scope then
          [ ]
        else
          [ "${path}: unbound template '${node.template}'" ]
      )
      ++ builtins.concatMap (n: checkNode "${path}.env.${n}" scope node.env.${n}) (
        builtins.attrNames node.env
      )

    else if t == "if" then
      sub "cond" node.cond ++ sub "then" node.then_ ++ sub "else" node.else_

    else if t == "eq" || t == "lessThan" || t == "add" then
      sub "a" node.a ++ sub "b" node.b

    else if t == "update" then
      sub "base" node.base ++ sub "ext" node.ext

    else if t == "concatLists" then
      sub "a" node.a ++ sub "b" node.b

    else if t == "select" then
      sub "expr" node.expr
      ++ builtins.concatMap (
        i: checkNode "${path}.path[${toString i}]" scope (builtins.elemAt node.path i)
      ) (indices node.path)
      ++ (if node.default != null then sub "default" node.default else [ ])

    else if t == "let" then
      let
        scope' = addNames scope (
          builtins.attrNames node.bindings ++ builtins.attrNames (node.localDefs or { })
        );
      in
      builtins.concatMap (n: checkNode "${path}.let.${n}" scope' node.bindings.${n}) (
        builtins.attrNames node.bindings
      )
      ++ checkDefs "${path}.let" scope' (node.localDefs or { })
      ++ checkNode "${path}.in" scope' node.body

    else
      [ "${path}: unknown IR node type '${t}'" ];

  checkDef =
    path: scope: name: def:
    let
      scope' = addNames scope (paramNames def.params ++ builtins.attrNames (def.localDefs or { }));
      formalDefaults =
        if def.params.formals or null != null then
          builtins.concatMap (
            f: if f.hasDefault then checkNode "${path}/${name}?${f.name}" scope' f.default else [ ]
          ) def.params.formals
        else
          [ ];
      # The reify environment is evaluated where the definition is emitted,
      # so it is checked against the *enclosing* scope.
      envCheck =
        if (def.params.envIR or null) == null then
          [ ]
        else
          checkNode "${path}/${name}!env" scope def.params.envIR;
    in
    envCheck
    ++ formalDefaults
    ++ checkNode "${path}/${name}" scope' def.body
    ++ checkDefs "${path}/${name}" scope' (def.localDefs or { });

  checkDefs =
    path: scope: defs:
    builtins.concatMap (n: checkDef path scope n defs.${n}) (builtins.attrNames defs);

in
{
  # walkResult: { ir; defs; bindings ? { }; }
  # Returns a list of error strings.
  check =
    walkResult:
    let
      defs = walkResult.defs or { };
      bindings = walkResult.bindings or { };
      topScope = addNames { } (builtins.attrNames defs ++ builtins.attrNames bindings);
    in
    builtins.concatMap (n: checkNode "<binding ${n}>" topScope bindings.${n}) (
      builtins.attrNames bindings
    )
    ++ checkDefs "<defs>" topScope defs
    ++ checkNode "<root>" topScope walkResult.ir;
}
