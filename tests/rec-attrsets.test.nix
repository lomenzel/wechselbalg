# Recursive attrsets (rec { ... })
[
  {
    description = "simple rec attrset";
    func =
      params:
      let
        r = rec {
          a = params.x;
          b = a + 1;
        };
      in
      r.b;
    params = {
      x = 10;
    };
    expected.toBe = 11;
  }
  {
    description = "rec attrset as full result";
    func = params: rec {
      a = params.x;
      b = a * 2;
    };
    params = {
      x = 5;
    };
    expected.toBe = {
      a = 5;
      b = 10;
    };
  }
  {
    description = "rec attrset with chain of refs";
    func = params: rec {
      x = params.n;
      y = x + 1;
      z = y + 1;
    };
    params = {
      n = 0;
    };
    expected.toBe = {
      x = 0;
      y = 1;
      z = 2;
    };
  }
]
