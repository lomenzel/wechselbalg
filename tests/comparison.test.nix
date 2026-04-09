# Comparison and boolean operations
[
  {
    description = "equality on integers (true)";
    func = params: params.a == params.b;
    params = { a = 5; b = 5; };
    expected.toBe = true;
  }
  {
    description = "equality on integers (false)";
    func = params: params.a == params.b;
    params = { a = 5; b = 6; };
    expected.toBe = false;
  }
  {
    description = "inequality";
    func = params: params.a != params.b;
    params = { a = 1; b = 2; };
    expected.toBe = true;
  }
  {
    description = "less than (true)";
    func = params: builtins.lessThan params.a params.b;
    params = { a = 3; b = 5; };
    expected.toBe = true;
  }
  {
    description = "less than (false)";
    func = params: builtins.lessThan params.a params.b;
    params = { a = 5; b = 3; };
    expected.toBe = false;
  }
  {
    description = "boolean and";
    func = params: params.a && params.b;
    params = { a = true; b = false; };
    expected.toBe = false;
  }
  {
    description = "boolean or";
    func = params: params.a || params.b;
    params = { a = false; b = true; };
    expected.toBe = true;
  }
  {
    description = "boolean not";
    func = params: ! params.x;
    params = { x = true; };
    expected.toBe = false;
  }
  {
    description = "implication (false -> anything = true)";
    func = params: params.a -> params.b;
    params = { a = false; b = false; };
    expected.toBe = true;
  }
  {
    description = "implication (true -> false = false)";
    func = params: params.a -> params.b;
    params = { a = true; b = false; };
    expected.toBe = false;
  }
]
