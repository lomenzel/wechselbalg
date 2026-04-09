# String operations
[
  {
    description = "string concatenation with +";
    func = params: params.a + params.b;
    params = { a = "foo"; b = "bar"; };
    expected.toBe = "foobar";
  }
  {
    description = "string interpolation";
    func = params: "${params.greeting} ${params.name}!";
    params = { greeting = "Hello"; name = "World"; };
    expected.toBe = "Hello World!";
  }
  {
    description = "string interpolation with integer coercion";
    func = params: "count: ${builtins.toString params.n}";
    params = { n = 42; };
    expected.toBe = "count: 42";
  }
]
