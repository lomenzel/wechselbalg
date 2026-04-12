# hasAttr operator (?) tests — covers the ? AST node, not the builtins.hasAttr primop
[
  {
    description = "hasAttr operator (present)";
    func = params: params.set ? a;
    params = {
      set = {
        a = 1;
        b = 2;
      };
    };
    expected.toBe = true;
  }
  {
    description = "hasAttr operator (missing)";
    func = params: params.set ? z;
    params = {
      set = {
        a = 1;
        b = 2;
      };
    };
    expected.toBe = false;
  }
  {
    description = "hasAttr multi-path (present)";
    func = params: params.set ? a.x;
    params = {
      set = {
        a = {
          x = 1;
        };
      };
    };
    expected.toBe = true;
  }
  {
    description = "hasAttr multi-path (missing inner)";
    func = params: params.set ? a.z;
    params = {
      set = {
        a = {
          x = 1;
        };
      };
    };
    expected.toBe = false;
  }
  {
    description = "hasAttr multi-path (missing outer)";
    func = params: params.set ? z.x;
    params = {
      set = {
        a = 1;
      };
    };
    expected.toBe = false;
  }
  {
    description = "hasAttr with or-default pattern";
    func = params: if params.set ? val then params.set.val else 0;
    params = {
      set = {
        val = 42;
      };
    };
    expected.toBe = 42;
  }
  {
    description = "hasAttr with or-default pattern (missing)";
    func = params: if params.set ? val then params.set.val else 0;
    params = {
      set = { };
    };
    expected.toBe = 0;
  }
]
