(builtins.mapAttrs (name: _: "builtins.${name}") builtins)
// {
  # special case because i map ? to hasAttr which behaves slightly differently
  hasAttr = "(name: value: (builtins.isAttrs value) && (builtins.hasAttr name value))";
}
