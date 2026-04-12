# Minimal reproduction of the config fixpoint bug.
#
# The NixOS module system pattern: a fixpoint where configs are merged via
# zipAttrsWith, and config values can reference other config values through
# the fixpoint.  In Nix, zipAttrsWith is lazy per-key -- accessing one key
# does NOT force other keys' values.  The JS backend's zipAttrsWith eagerly
# forces all values, triggering infinite recursion.
[
  {
    description = "zipAttrsWith in fixpoint: value references sibling through fixpoint";
    func = params:
      let
        fix = f: let x = f x; in x;

        result = fix (self: let
          # Each "config" attrset simulates a module's config output.
          # `doubled` references `self.config.base`, creating a lazy
          # cross-reference through the fixpoint.
          configs = [
            { base = params; doubled = self.config.base * 2; }
          ];

          # zipAttrsWith groups values by key.
          # In Nix this is lazy: forcing key "base" does NOT force "doubled".
          rawDefs = builtins.zipAttrsWith (name: vs: vs) configs;

          # Per-key merge: just take the first (only) definition.
          options = builtins.mapAttrs (name: defs: {
            value = builtins.head defs;
          }) rawDefs;

          # config extracts .value from each option.
          config = builtins.mapAttrs (name: opt: opt.value) options;
        in {
          inherit config;
        });
      in
        result.config.doubled;
    params = 7;
    expected.toBe = 14;
  }
]
