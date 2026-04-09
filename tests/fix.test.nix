# Fixed-point pattern — the core of lib.fix / evalModules
[
  {
    description = "fixed point: simple self-referencing attrset";
    func = params:
      let
        fix = f: let x = f x; in x;
        result = fix (self: {
          a = params.x;
          b = self.a + 1;
        });
      in result.b;
    params = { x = 10; };
    expected.toBe = 11;
  }
  {
    description = "fixed point: multiple self-references";
    func = params:
      let
        fix = f: let x = f x; in x;
        result = fix (self: {
          width = params.w;
          height = params.h;
          area = self.width * self.height;
        });
      in result.area;
    params = { w = 3; h = 4; };
    expected.toBe = 12;
  }
  {
    description = "fixed point: override pattern";
    func = params:
      let
        fix = f: let x = f x; in x;
        base = self: {
          x = params.a;
          y = self.x + 1;
        };
        override = self: (base self) // { x = params.b; };
        result = fix override;
      in result.y;
    params = { a = 10; b = 20; };
    expected.toBe = 21;
  }
]
