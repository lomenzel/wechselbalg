lib: [
  {
    description = "Test that evalmoules works";
    func =
      params:
      (lib.evalModules {
        modules = [
          (
            { lib }:
            {
              config = { a = params; };
              options.a = lib.mkOption {
                type = lib.types.int;
                default = 0;
              };
              options.b = lib.mkOption {
                type = lib.types.int;
                default = 0;
              };
            }
          )
        ];
      }).config;
    params = 1;
    expected.toBe = {
      a = 1;
      b = 0;
    };
  }
]
