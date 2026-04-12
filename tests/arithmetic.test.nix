# Arithmetic operations
[
  {
    description = "integer addition";
    func = params: params.a + params.b;
    params = {
      a = 3;
      b = 4;
    };
    expected.toBe = 7;
  }
  {
    description = "integer subtraction";
    func = params: params.a - params.b;
    params = {
      a = 10;
      b = 3;
    };
    expected.toBe = 7;
  }
  {
    description = "integer multiplication";
    func = params: params.a * params.b;
    params = {
      a = 6;
      b = 7;
    };
    expected.toBe = 42;
  }
  {
    description = "integer division (truncating)";
    func = params: params.a / params.b;
    params = {
      a = 7;
      b = 2;
    };
    expected.toBe = 3;
  }
  {
    description = "float addition";
    func = params: params.a + params.b;
    params = {
      a = 1.5;
      b = 2.5;
    };
    expected.toBe = 4.0;
  }
  {
    description = "mixed int/float promotes to float";
    func = params: params.a + params.b;
    params = {
      a = 1;
      b = 0.5;
    };
    expected.toBe = 1.5;
  }
  {
    description = "nested arithmetic";
    func = params: (params.a + params.b) * params.c;
    params = {
      a = 2;
      b = 3;
      c = 4;
    };
    expected.toBe = 20;
  }
  {
    description = "chained addition (3 operands)";
    func = params: params.a + params.b + params.c;
    params = {
      a = 1;
      b = 2;
      c = 3;
    };
    expected.toBe = 6;
  }
  {
    description = "addition and subtraction mixed";
    func = params: params.a + params.b - params.c;
    params = {
      a = 10;
      b = 5;
      c = 3;
    };
    expected.toBe = 12;
  }
]
