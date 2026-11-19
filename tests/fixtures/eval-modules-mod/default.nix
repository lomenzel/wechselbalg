# Module fixture for eval-modules.test.nix: consumed through a real
# lib.evalModules call as `imports = [ ./eval-modules-mod ]`. Must not match
# the *test.nix harness glob (see fixture-path-import note).
{ lib, ... }:
{
  options.greeting = lib.mkOption {
    type = lib.types.str;
    default = "hello from module path import";
  };
  options.doubledFromParam = lib.mkOption {
    type = lib.types.int;
    default = 0;
  };
}
