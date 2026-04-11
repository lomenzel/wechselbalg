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
  {
    description = "triple string concatenation";
    func = params: params.a + params.b + params.c;
    params = { a = "one"; b = "two"; c = "three"; };
    expected.toBe = "onetwothree";
  }
  {
    description = "mixed interpolation and concat";
    func = params: "${params.a}-${params.b}" + params.c;
    params = { a = "x"; b = "y"; c = "z"; };
    expected.toBe = "x-yz";
  }

  # ── Dollar-brace escaping (Nix backend) ─────────────────────
  {
    description = "string containing dollar-brace literal";
    func = params: params + "$" + "{x}";
    params = "prefix";
    expected.toBe = "prefix\${x}";
  }
]
