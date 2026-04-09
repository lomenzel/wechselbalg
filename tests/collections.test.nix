# Collections — lists and attrsets
[
  {
    description = "list passthrough";
    func = params: params.xs;
    params = { xs = [ 1 2 3 ]; };
    expected.toBe = [ 1 2 3 ];
  }
  {
    description = "list concatenation";
    func = params: params.a ++ params.b;
    params = { a = [ 1 2 ]; b = [ 3 4 ]; };
    expected.toBe = [ 1 2 3 4 ];
  }
  {
    description = "attrset passthrough";
    func = params: params.set;
    params = { set = { a = 1; b = 2; }; };
    expected.toBe = { a = 1; b = 2; };
  }
  {
    description = "attrset update (//)";
    func = params: params.base // params.ext;
    params = { base = { a = 1; b = 2; }; ext = { b = 99; c = 3; }; };
    expected.toBe = { a = 1; b = 99; c = 3; };
  }
  {
    description = "attribute selection";
    func = params: params.set.x;
    params = { set = { x = 42; y = 99; }; };
    expected.toBe = 42;
  }
  {
    description = "nested attrset access";
    func = params: params.a.b.c;
    params = { a = { b = { c = "deep"; }; }; };
    expected.toBe = "deep";
  }
]
