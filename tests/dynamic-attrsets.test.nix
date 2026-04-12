# Dynamic attribute sets (computed attr names via ${expr})
[
  {
    description = "simple dynamic attr name";
    func = params:
      let
        key = "hello";
        s = { ${key} = params.x; };
      in s.hello;
    params = { x = 42; };
    expected.toBe = 42;
  }
  {
    description = "dynamic attr name from parameter";
    func = params:
      let s = { ${params.key} = params.val; };
      in s.greeting;
    params = { key = "greeting"; val = 99; };
    expected.toBe = 99;
  }
  {
    description = "dynamic attrset as full result";
    func = params:
      { ${params.key} = params.val; };
    params = { key = "a"; val = 1; };
    expected.toBe = { a = 1; };
  }
  {
    description = "mixed static and dynamic attrs";
    func = params:
      let s = { x = 1; ${params.key} = 2; };
      in s.x + s.y;
    params = { key = "y"; };
    expected.toBe = 3;
  }
  {
    description = "multiple dynamic attrs";
    func = params:
      { ${params.k1} = params.v1; ${params.k2} = params.v2; };
    params = { k1 = "a"; v1 = 10; k2 = "b"; v2 = 20; };
    expected.toBe = { a = 10; b = 20; };
  }
  {
    description = "dynamic attr with string interpolation key";
    func = params:
      let s = { ${"key_${params.suffix}"} = params.x; };
      in s.key_foo;
    params = { suffix = "foo"; x = 7; };
    expected.toBe = 7;
  }
  {
    description = "dynamic attr alongside static in rec set";
    func = params:
      let s = rec { a = 5; ${params.key} = a + 1; };
      in s.b;
    params = { key = "b"; };
    expected.toBe = 6;
  }
  {
    description = "select dynamic attr by computed name";
    func = params:
      let
        s = { ${params.key} = params.val; };
      in s.${params.key};
    params = { key = "z"; val = 100; };
    expected.toBe = 100;
  }
  {
    description = "dynamic attr with null name is dropped";
    func = params:
      { ${params} = 1; a = 2; };
    params = null;
    expected.toBe = { a = 2; };
  }
  {
    description = "all-null dynamic attrs yield empty set";
    func = params:
      { ${params} = 1; };
    params = null;
    expected.toBe = {};
  }
  {
    description = "only non-null dynamic attrs survive";
    func = params:
      { ${params.k1} = 1; ${params.k2} = 2; };
    params = { k1 = null; k2 = "b"; };
    expected.toBe = { b = 2; };
  }
]
