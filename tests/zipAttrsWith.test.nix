# builtins.zipAttrsWith — comprehensive tests
[
  # ── Basic functionality ──────────────────────────────────────
  {
    description = "zipAttrsWith: single set identity";
    func = params: builtins.zipAttrsWith (name: vs: builtins.head vs) [ params ];
    params = {
      a = 1;
      b = 2;
    };
    expected.toBe = {
      a = 1;
      b = 2;
    };
  }
  {
    description = "zipAttrsWith: merge two disjoint sets";
    func =
      params:
      builtins.zipAttrsWith (name: vs: builtins.head vs) [
        { a = params; }
        { b = params * 2; }
      ];
    params = 5;
    expected.toBe = {
      a = 5;
      b = 10;
    };
  }
  {
    description = "zipAttrsWith: merge overlapping keys collects all values";
    func =
      params:
      builtins.zipAttrsWith (name: vs: vs) [
        {
          a = 1;
          b = 2;
        }
        {
          a = 3;
          c = 4;
        }
        {
          a = params;
          b = 6;
        }
      ];
    params = 5;
    expected.toBe = {
      a = [
        1
        3
        5
      ];
      b = [
        2
        6
      ];
      c = [ 4 ];
    };
  }
  {
    description = "zipAttrsWith: sum overlapping values";
    func =
      params:
      builtins.zipAttrsWith (name: vs: builtins.foldl' (a: b: a + b) 0 vs) [
        {
          x = params;
          y = 1;
        }
        {
          x = 10;
          y = 2;
        }
      ];
    params = 5;
    expected.toBe = {
      x = 15;
      y = 3;
    };
  }
  {
    description = "zipAttrsWith: empty list of sets";
    func = params: builtins.zipAttrsWith (name: vs: vs + params) [ ];
    params = null;
    expected.toBe = { };
  }
  {
    description = "zipAttrsWith: name argument is the key";
    func =
      params:
      builtins.zipAttrsWith (name: vs: name) [
        {
          hello = params;
          world = params;
        }
      ];
    params = 0;
    expected.toBe = {
      hello = "hello";
      world = "world";
    };
  }
  {
    description = "zipAttrsWith: single key from multiple sets";
    func =
      params:
      let
        r = builtins.zipAttrsWith (name: vs: builtins.length vs) [
          { a = 1; }
          { a = 2; }
          { a = params; }
        ];
      in
      r.a;
    params = 3;
    expected.toBe = 3;
  }

  # ── Laziness ─────────────────────────────────────────────────
  {
    description = "zipAttrsWith: accessing one key does not force others";
    func =
      params:
      let
        # Key "bomb" would diverge if forced (infinite recursion).
        fix =
          f:
          let
            x = f x;
          in
          x;
        r = builtins.zipAttrsWith (name: vs: builtins.head vs) [
          {
            safe = params;
            bomb = fix (x: x);
          }
        ];
      in
      r.safe;
    params = 42;
    expected.toBe = 42;
  }

  # ── Interaction with other primops ───────────────────────────
  {
    description = "zipAttrsWith: result works with attrNames";
    func =
      params:
      let
        r = builtins.zipAttrsWith (name: vs: vs) [
          {
            b = 1;
            a = 2;
          }
          { c = params; }
        ];
      in
      builtins.attrNames r;
    params = 3;
    expected.toBe = [
      "a"
      "b"
      "c"
    ];
  }
  {
    description = "zipAttrsWith: result works with mapAttrs";
    func =
      params:
      let
        r = builtins.zipAttrsWith (name: vs: builtins.head vs) [
          {
            a = params;
            b = params * 3;
          }
        ];
        doubled = builtins.mapAttrs (n: v: v * 2) r;
      in
      doubled;
    params = 4;
    expected.toBe = {
      a = 8;
      b = 24;
    };
  }
]
