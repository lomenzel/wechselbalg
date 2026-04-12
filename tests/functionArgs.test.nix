# builtins.functionArgs tests
[
  {
    description = "functionArgs: formals without defaults";
    func = params:
      builtins.functionArgs ({ x, y }: x + y);
    params = null;
    expected.toBe = { x = false; y = false; };
  }
  {
    description = "functionArgs: formals with some defaults";
    func = params:
      builtins.functionArgs ({ x, y ? 123 }: x + y);
    params = null;
    expected.toBe = { x = false; y = true; };
  }
  {
    description = "functionArgs: all formals with defaults";
    func = params:
      builtins.functionArgs ({ x ? 1, y ? 2 }: x + y);
    params = null;
    expected.toBe = { x = true; y = true; };
  }
  {
    description = "functionArgs: plain lambda returns empty set";
    func = params:
      builtins.functionArgs (x: x);
    params = null;
    expected.toBe = {};
  }
  {
    description = "functionArgs: formals with ellipsis";
    func = params:
      builtins.functionArgs ({ x, y ? 5, ... }: params);
    params = null;
    expected.toBe = { x = false; y = true; };
  }
  {
    description = "functionArgs: single formal without default";
    func = params:
      builtins.functionArgs ({ x }: params);
    params = null;
    expected.toBe = { x = false; };
  }
  {
    description = "functionArgs: single formal with default";
    func = params:
      builtins.functionArgs ({ x ? 42 }: params);
    params = null;
    expected.toBe = { x = true; };
  }
  {
    description = "functionArgs: with @ pattern";
    func = params:
      builtins.functionArgs (args@{ x, y ? 10 }: params);
    params = null;
    expected.toBe = { x = false; y = true; };
  }
]
