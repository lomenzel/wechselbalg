# Tests for paths: paths are unsupported in target languages and should produce runtime errors
# Unused paths (e.g. captured in attrsets/closures) must translate cleanly without compile errors.
[
  {
    description = "set containing path does not fail at runtime unless path attribute is accessed";
    func =
      params:
      let
        s = {
          a = params;
          p = ./paths.test.nix;
        };
      in
      s.a;
    params = 42;
    expected.toBe = 42;
  }
  {
    description = "closure capturing path does not fail at runtime unless path is accessed";
    func =
      params:
      let
        myPath = ./paths.test.nix;
        f = x: x + 1;
      in
      f params;
    params = 10;
    expected.toBe = 11;
  }
]
