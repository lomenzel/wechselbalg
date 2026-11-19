# End-to-end translation test: a real lib.evalModules call whose module list
# uses `imports = [ ./dir ]` (default.nix directory), exercising path-import
# resolution through the full evalModules machinery — not just a hand-rolled fold.
{ lib, ... }:
[
  {
    description = "evalModules with imports = [ ./dir-with-default.nix ]";
    func =
      params:
      let
        result = lib.evalModules {
          modules = [
            ({ config, ... }: {
              imports = [ params.path-mod ];
              options.fromParams = lib.mkOption {
                type = lib.types.int;
                default = 0;
              };
              config.fromParams = params.p1;
              # Reference `config` as the standard module-system function value,
              # not a plain (unbound) local variable.
              config.doubledFromParam = config.fromParams * 2;
            })
          ];
        };
      in
      {
        greeting = result.config.greeting;
        doubled = result.config.doubledFromParam;
      };
    params = {
      p1 = 21;
      path-mod = ./fixtures/eval-modules-mod;
    };
    expected.toBe = {
      greeting = "hello from module path import";
      doubled = 42;
    };
  }
]
