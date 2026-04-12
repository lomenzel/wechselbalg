# Purity enforcement.
#
# Wechselbalg only translates pure Nix values.  This module provides a
# single check that rejects paths, derivations, store-path references,
# and anything else that cannot be meaningfully represented in a target
# language without access to the Nix store.

let
  check =
    value:
    let
      type = builtins.typeOf value;
    in
    if type == "path" then
      throw "wechselbalg: paths cannot be translated (they reference the filesystem)"
    else if type == "set" && value ? drvPath then
      throw "wechselbalg: derivations cannot be translated (value has drvPath)"
    else if type == "set" && value ? outPath then
      throw "wechselbalg: store-path sets cannot be translated (value has outPath)"
    else
      true;
in
{
  # Assert that a value is translatable. Returns true or throws.
  assertPure = check;

  # Check without throwing. Returns { pure = bool; reason = string|null; }.
  isPure =
    value:
    let
      type = builtins.typeOf value;
    in
    if type == "path" then
      {
        pure = false;
        reason = "path values reference the filesystem";
      }
    else if type == "set" && value ? drvPath then
      {
        pure = false;
        reason = "derivations cannot be translated";
      }
    else if type == "set" && value ? outPath then
      {
        pure = false;
        reason = "store-path sets cannot be translated";
      }
    else
      {
        pure = true;
        reason = null;
      };
}
