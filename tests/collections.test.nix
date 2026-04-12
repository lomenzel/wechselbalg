# Collections — lists and attrsets
[
  {
    description = "list passthrough";
    func = params: params.xs;
    params = {
      xs = [
        1
        2
        3
      ];
    };
    expected.toBe = [
      1
      2
      3
    ];
  }
  {
    description = "list concatenation";
    func = params: params.a ++ params.b;
    params = {
      a = [
        1
        2
      ];
      b = [
        3
        4
      ];
    };
    expected.toBe = [
      1
      2
      3
      4
    ];
  }
  {
    description = "attrset passthrough";
    func = params: params.set;
    params = {
      set = {
        a = 1;
        b = 2;
      };
    };
    expected.toBe = {
      a = 1;
      b = 2;
    };
  }
  {
    description = "attrset update (//)";
    func = params: params.base // params.ext;
    params = {
      base = {
        a = 1;
        b = 2;
      };
      ext = {
        b = 99;
        c = 3;
      };
    };
    expected.toBe = {
      a = 1;
      b = 99;
      c = 3;
    };
  }
  {
    description = "attribute selection";
    func = params: params.set.x;
    params = {
      set = {
        x = 42;
        y = 99;
      };
    };
    expected.toBe = 42;
  }
  {
    description = "nested attrset access";
    func = params: params.a.b.c;
    params = {
      a = {
        b = {
          c = "deep";
        };
      };
    };
    expected.toBe = "deep";
  }

  # ── mapAttrs (lazy entry evaluation) ──────────────────────
  {
    description = "mapAttrs transforms values";
    func =
      params:
      let
        s = {
          a = 1;
          b = 2;
          c = 3;
        };
        mapped = builtins.mapAttrs (name: value: value + params) s;
      in
      mapped;
    params = 10;
    expected.toBe = {
      a = 11;
      b = 12;
      c = 13;
    };
  }
  {
    description = "mapAttrs selective access (lazy)";
    func =
      params:
      let
        s = {
          a = 1;
          b = 2;
        };
        mapped = builtins.mapAttrs (name: value: value + params) s;
      in
      mapped.a;
    params = 100;
    expected.toBe = 101;
  }

  # ── Update/concat/length with rec attrsets (lazy values) ────
  {
    description = "update with rec attrset";
    func =
      params:
      let
        a = rec {
          x = params;
          y = x + 1;
        };
        b = {
          z = 99;
        };
      in
      (a // b).y;
    params = 10;
    expected.toBe = 11;
  }
  {
    description = "concat with let-bound lists";
    func =
      params:
      let
        a = [ params ];
        b = [ (params + 1) ];
      in
      a ++ b;
    params = 5;
    expected.toBe = [
      5
      6
    ];
  }
  {
    description = "length of concatenated list";
    func =
      params:
      let
        xs = [
          1
          2
          3
        ]
        ++ [ params ];
      in
      builtins.length xs;
    params = 99;
    expected.toBe = 4;
  }
]
