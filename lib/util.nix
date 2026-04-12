# Name generation utilities.
#
# Produces unique names for hoisted function definitions.
# Operates on the `known` attrset passed through the walker.

let
  findNew =
    prefix: i: known:
    let
      name = "${prefix}${toString i}";
    in
    if builtins.hasAttr name known then findNew prefix (i + 1) known else name;
in
{
  # Generate a fresh function name not yet in `known`.
  freshFuncName = findNew "__wb_func_" 0;

  # Generate a fresh variable name not yet in `known`.
  freshVarName = findNew "__wb_var_" 0;
}
