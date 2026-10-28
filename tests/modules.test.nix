{ plainLib, ... }:
let
  lib = plainLib;
in
[
  {
    description = "evalModules (pulls in all of lib) (menat as stress test)";
    func =
      params:
      let
        result = lib.evalModules {
          modules = [
            (
              { lib, config, ... }:
              {
                options.ignored = lib.mkOption {
                  type = lib.types.int;
                  default = 70;
                };
                options.unset = lib.mkOption {
                  type = lib.types.int;
                  default = 99 + params.p1;
                };
                options.base = lib.mkOption {
                  type = lib.types.int;
                  default = 0;
                };
                options.doubled = lib.mkOption {
                  type = lib.types.int;
                  default = config.base * 2;
                };
                options.list = lib.mkOption {
                  type = lib.types.listOf lib.types.int;
                };
                config.list = [
                  1
                  2
                ];
              }
            )
            (
              { config, ... }:
              {
                base = params.p2;
                #doubled = config.base * 2;
                list = [ params.p3 ];
              }
            )
          ];
        };
      in
      builtins.removeAttrs result.config [ "ignored" ];
    params = {
      p1 = 1;
      p2 = 7;
      p3 = 3;
    };
    expected.toBe = {
      unset = 100;
      base = 7;
      doubled = 14;
      list = [
        3
        1
        2
      ];
    };
  }
]
