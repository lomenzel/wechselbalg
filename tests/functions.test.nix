# Function features — currying, default args, destructuring
[
  {
    description = "identity function";
    func = params: params.x;
    params = { x = 42; };
    expected.toBe = 42;
  }
  {
    description = "curried function application";
    func =
      let multiply = x: y: x * y;
      in params: multiply params.a params.b;
    params = { a = 6; b = 7; };
    expected.toBe = 42;
  }
  {
    description = "default argument value";
    func =
      let f = { a, b ? 10 }: a + b;
      in params: f params;
    params = { a = 5; };
    expected.toBe = 15;
  }
  {
    description = "default argument value overridden";
    func =
      let f = { a, b ? 10 }: a + b;
      in params: f params;
    params = { a = 5; b = 3; };
    expected.toBe = 8;
  }
  {
    description = "@ pattern captures all args";
    func =
      let f = args@{ a, ... }: a + args.b;
      in params: f params;
    params = { a = 2; b = 3; c = 99; };
    expected.toBe = 5;
  }
]
