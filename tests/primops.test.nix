# Builtin primops
[
  {
    description = "builtins.length";
    func = params: builtins.length params.xs;
    params = { xs = [ 1 2 3 4 5 ]; };
    expected.toBe = 5;
  }
  {
    description = "builtins.head";
    func = params: builtins.head params.xs;
    params = { xs = [ 42 1 2 ]; };
    expected.toBe = 42;
  }
  {
    description = "builtins.tail";
    func = params: builtins.tail params.xs;
    params = { xs = [ 1 2 3 ]; };
    expected.toBe = [ 2 3 ];
  }
  {
    description = "builtins.elemAt";
    func = params: builtins.elemAt params.xs params.i;
    params = { xs = [ 10 20 30 ]; i = 1; };
    expected.toBe = 20;
  }
  {
    description = "builtins.map";
    func = params: builtins.map (x: x * 2) params.xs;
    params = { xs = [ 1 2 3 ]; };
    expected.toBe = [ 2 4 6 ];
  }
  {
    description = "builtins.filter";
    func = params: builtins.filter (x: x > 2) params.xs;
    params = { xs = [ 1 2 3 4 5 ]; };
    expected.toBe = [ 3 4 5 ];
  }
  {
    description = "builtins.foldl' (sum)";
    func = params: builtins.foldl' (acc: x: acc + x) 0 params.xs;
    params = { xs = [ 1 2 3 4 ]; };
    expected.toBe = 10;
  }
  {
    description = "builtins.attrNames";
    func = params: builtins.attrNames params.set;
    params = { set = { c = 3; a = 1; b = 2; }; };
    expected.toBe = [ "a" "b" "c" ];
  }
  {
    description = "builtins.attrValues";
    func = params: builtins.attrValues params.set;
    params = { set = { a = 1; b = 2; c = 3; }; };
    expected.toBe = [ 1 2 3 ];
  }
  {
    description = "builtins.hasAttr";
    func = params: builtins.hasAttr "a" params.set;
    params = { set = { a = 1; }; };
    expected.toBe = true;
  }
  {
    description = "builtins.hasAttr (missing)";
    func = params: builtins.hasAttr "z" params.set;
    params = { set = { a = 1; }; };
    expected.toBe = false;
  }
  {
    description = "builtins.genList";
    func = params: builtins.genList (i: i * i) params.n;
    params = { n = 4; };
    expected.toBe = [ 0 1 4 9 ];
  }
  {
    description = "builtins.concatLists";
    func = params: builtins.concatLists params.xss;
    params = { xss = [ [ 1 2 ] [ 3 ] [ 4 5 ] ]; };
    expected.toBe = [ 1 2 3 4 5 ];
  }
  {
    description = "builtins.elem";
    func = params: builtins.elem params.x params.xs;
    params = { x = 3; xs = [ 1 2 3 4 ]; };
    expected.toBe = true;
  }
  {
    description = "builtins.elem (missing)";
    func = params: builtins.elem params.x params.xs;
    params = { x = 9; xs = [ 1 2 3 4 ]; };
    expected.toBe = false;
  }
  {
    description = "builtins.stringLength";
    func = params: builtins.stringLength params.s;
    params = { s = "hello"; };
    expected.toBe = 5;
  }
  {
    description = "builtins.substring";
    func = params: builtins.substring params.start params.len params.s;
    params = { start = 1; len = 3; s = "hello"; };
    expected.toBe = "ell";
  }
  {
    description = "builtins.replaceStrings";
    func = params: builtins.replaceStrings params.from params.to params.s;
    params = { from = [ "o" "l" ]; to = [ "0" "1" ]; s = "hello world"; };
    expected.toBe = "he110 w0r1d";
  }
  {
    description = "builtins.typeOf (int)";
    func = params: builtins.typeOf params.x;
    params = { x = 42; };
    expected.toBe = "int";
  }
  {
    description = "builtins.typeOf (string)";
    func = params: builtins.typeOf params.x;
    params = { x = "hi"; };
    expected.toBe = "string";
  }
  {
    description = "partially applied primop (builtins.lessThan 1)";
    func = builtins.lessThan 1;
    params = 5;
    expected.toBe = true;
  }
  {
    description = "partially applied primop (builtins.lessThan 1, false)";
    func = builtins.lessThan 1 ;
    params = 0;
    expected.toBe = false;
  }
]
