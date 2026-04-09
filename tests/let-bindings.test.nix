# Let bindings and lazy evaluation
[
  {
    description = "simple let binding";
    func = params:
      let x = params.a + 1;
      in x * 2;
    params = { a = 5; };
    expected.toBe = 12;
  }
  {
    description = "let with forward reference (lazy thunks)";
    func = params:
      let
        a = b + 1;
        b = params.x;
      in a;
    params = { x = 10; };
    expected.toBe = 11;
  }
  {
    description = "let with multiple bindings";
    func = params:
      let
        x = params.a;
        y = params.b;
        z = x + y;
      in z;
    params = { a = 3; b = 4; };
    expected.toBe = 7;
  }
  {
    description = "let inherit from attrset";
    func = params:
      let inherit (params) a b;
      in a + b;
    params = { a = 10; b = 20; };
    expected.toBe = 30;
  }
  {
    description = "recursive let-bound function (factorial)";
    func = params:
      let fac = x: if x == 0 then 1 else x * fac (x - 1);
      in fac params.n;
    params = { n = 5; };
    expected.toBe = 120;
  }
  {
    description = "mutually referencing let bindings";
    func = params:
      let
        a = params.x;
        b = a + 1;
        c = b + a;
      in c;
    params = { x = 3; };
    expected.toBe = 7;
  }
]
