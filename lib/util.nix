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

  JSONOptimizable =
    depth: value:
    let
      type = builtins.typeOf value;
      canEvaluate = builtins.tryEval value;
    in
    if !canEvaluate.success then
      #builtins.trace "optimize-json: value cannot be evaluated at build time"
      false
    else if depth > 100 then
      #builtins.trace "optimize-json: depth too high, maybe cyclic data structure"
      false
    else if
      type == "null" || type == "string" || type == "int" || type == "bool" || type == "float"
    then
      true
    else if type == "list" then
      builtins.all (JSONOptimizable (depth + 1)) value
    else if type == "set" then
      builtins.all (JSONOptimizable (depth + 1)) (builtins.attrValues value)
    else if type == "path" || type == "lambda" then
      false
    else
      throw "unknown type ${type} in JSONOptimizable";
in
{
  # Generate a fresh function name not yet in `known`.
  freshFuncName =
    known:
    let
      # Fast jump: start searching from the number of keys already in known
      startIdx = builtins.length (builtins.attrNames known);
    in
    findNew "__wb_func_" startIdx known;

  # Generate a fresh variable name not yet in `known`.
  freshVarName =
    known:
    let
      startIdx = builtins.length (builtins.attrNames known);
    in
    findNew "__wb_var_" startIdx known;
  JSONOptimizable = JSONOptimizable 0;

}
