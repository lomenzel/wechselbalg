# if/then/else control flow
[
  {
    description = "if true branch";
    func = params: if params.cond then params.a else params.b;
    params = {
      cond = true;
      a = 1;
      b = 2;
    };
    expected.toBe = 1;
  }
  {
    description = "if false branch";
    func = params: if params.cond then params.a else params.b;
    params = {
      cond = false;
      a = 1;
      b = 2;
    };
    expected.toBe = 2;
  }
  {
    description = "nested if";
    func =
      params:
      if params.x == 1 then
        "one"
      else if params.x == 2 then
        "two"
      else
        "other";
    params = {
      x = 2;
    };
    expected.toBe = "two";
  }

  # ── assert expressions ─────────────────────────────────────
  {
    description = "assert true passes through";
    func =
      params:
      assert params > 0;
      params + 1;
    params = 5;
    expected.toBe = 6;
  }
  {
    description = "assert with computed condition";
    func =
      params:
      let
        x = params * 2;
      in
      assert x > 0;
      x;
    params = 3;
    expected.toBe = 6;
  }
]
