# Literal values — the most basic translation tests.
[
  {
    description = "integer literal";
    func = params: params.x;
    params = {
      x = 42;
    };
    expected.toBe = 42;
  }
  {
    description = "negative integer";
    func = params: params.x;
    params = {
      x = -7;
    };
    expected.toBe = -7;
  }
  {
    description = "float literal";
    func = params: params.x;
    params = {
      x = 3.14;
    };
    expected.toBe = 3.14;
  }
  {
    description = "string literal";
    func = params: params.x;
    params = {
      x = "hello";
    };
    expected.toBe = "hello";
  }
  {
    description = "empty string";
    func = params: params.x;
    params = {
      x = "";
    };
    expected.toBe = "";
  }
  {
    description = "boolean true";
    func = params: params.x;
    params = {
      x = true;
    };
    expected.toBe = true;
  }
  {
    description = "boolean false";
    func = params: params.x;
    params = {
      x = false;
    };
    expected.toBe = false;
  }
  {
    description = "null value";
    func = params: params.x;
    params = {
      x = null;
    };
    expected.toBe = null;
  }
]
