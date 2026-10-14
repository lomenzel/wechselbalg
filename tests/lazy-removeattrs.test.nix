# Bug: removeAttrs eagerly forces all values (JS/Python spread operator)
# but Nix's native builtins.removeAttrs is lazy.
#
# This breaks fixpoint patterns like NixOS module system shorthand syntax,
# where unifyModuleSyntax calls removeAttrs on a module's return value
# containing values that reference the not-yet-resolved config fixpoint.
#
# In Nix: removeAttrs creates a new set without forcing values → lazy access works.
# In JS/Python: { ...set } forces all values via get trap → infinite recursion.
{ lib, ... }: [
  {
    description = "removeAttrs must be lazy through fixpoint";
    func =
      params:
      let
        cleaned = builtins.removeAttrs raw [ "x" ];
        raw = {
          a = params.p1;
          b = cleaned.a * 2;
        };
      in
      cleaned;
    params = {
      p1 = 7;
    };
    expected.toBe = {
      a = 7;
      b = 14;
    };
  }
]
