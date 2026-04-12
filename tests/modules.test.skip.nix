# evalModules tests — using the REAL nixpkgs lib.evalModules.
#
# Each test translates a function that calls the real lib.evalModules.
# The entire module system (evalModules + types + merge logic) is carried
# as closure values and translated alongside the test logic.
#
# This exercises the full pipeline: reify → walk → IR → backend for the
# real-world NixOS module system.
#
# Note: each test independently translates evalModules (~9M chars), so
# we keep the number of tests small to avoid very long build times.
lib:
let
  evalModules = lib.evalModules;
  inherit (lib) mkOption types;
in
[
  # ── basic: param overrides option default ──────────────────
  {
    description = "real evalModules: param overrides option default";
    func = params:
      let
        result = evalModules {
          modules = [
            ({ ... }: {
              options.value = mkOption { type = types.int; default = 0; };
              config.value = params;
            })
          ];
        };
      in result.config.value;
    params = 42;
    expected.toBe = 42;
  }

  # ── default value: no config provided ──────────────────────
  {
    description = "real evalModules: default value; using lib in module";
    func = params:
      let
        result = evalModules {
          modules = [
            ({ lib, ... }: {
              options.x = lib.mkOption { type = lib.types.int; default = 99; };
            })
          ];
        };
      in result.config.x + params;
    params = 1;
    expected.toBe = 100;
  }

  # ── config fixpoint: module reads sibling config ───────────
  {
    description = "real evalModules: config fixpoint";
    func = params:
      let
        result = evalModules {
          modules = [
            ({ ... }: {
              options.base = mkOption { type = types.int; default = 0; };
              options.doubled = mkOption { type = types.int; default = 0; };
            })
            ({ config, ... }: {
              config.base = params;
              config.doubled = config.base * 2;
            })
          ];
        };
      in result.config.doubled;
    params = 7;
    expected.toBe = 14;
  }

  # ── option merge: two modules set the same list option ─────
  {
    description = "real evalModules: list option merge from two modules";
    func = params:
      let
        result = evalModules {
          modules = [
            ({ ... }: {
              options.items = mkOption { type = types.listOf types.int; default = []; };
            })
            ({ ... }: {
              config.items = [ 1 2 ];
            })
            ({ ... }: {
              config.items = [ params ];
            })
          ];
        };
      in builtins.sort (p: q: p < q)  result.config.items;
    params = 3;
    expected.toBe = [ 1 2 3 ];
  }
]
