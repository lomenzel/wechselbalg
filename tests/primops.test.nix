# Builtin primops
[
  {
    description = "builtins.length";
    func = params: builtins.length params.xs;
    params = {
      xs = [
        1
        2
        3
        4
        5
      ];
    };
    expected.toBe = 5;
  }
  {
    description = "builtins.head";
    func = params: builtins.head params.xs;
    params = {
      xs = [
        42
        1
        2
      ];
    };
    expected.toBe = 42;
  }
  {
    description = "builtins.tail";
    func = params: builtins.tail params.xs;
    params = {
      xs = [
        1
        2
        3
      ];
    };
    expected.toBe = [
      2
      3
    ];
  }
  {
    description = "builtins.elemAt";
    func = params: builtins.elemAt params.xs params.i;
    params = {
      xs = [
        10
        20
        30
      ];
      i = 1;
    };
    expected.toBe = 20;
  }
  {
    description = "builtins.map";
    func = params: builtins.map (x: x * 2) params.xs;
    params = {
      xs = [
        1
        2
        3
      ];
    };
    expected.toBe = [
      2
      4
      6
    ];
  }
  {
    description = "builtins.filter";
    func = params: builtins.filter (x: x > 2) params.xs;
    params = {
      xs = [
        1
        2
        3
        4
        5
      ];
    };
    expected.toBe = [
      3
      4
      5
    ];
  }
  {
    description = "builtins.foldl' (sum)";
    func = params: builtins.foldl' (acc: x: acc + x) 0 params.xs;
    params = {
      xs = [
        1
        2
        3
        4
      ];
    };
    expected.toBe = 10;
  }
  {
    description = "builtins.attrNames";
    func = params: builtins.attrNames params.set;
    params = {
      set = {
        c = 3;
        a = 1;
        b = 2;
      };
    };
    expected.toBe = [
      "a"
      "b"
      "c"
    ];
  }
  {
    description = "builtins.attrValues";
    func = params: builtins.attrValues params.set;
    params = {
      set = {
        a = 1;
        b = 2;
        c = 3;
      };
    };
    expected.toBe = [
      1
      2
      3
    ];
  }
  {
    description = "builtins.hasAttr";
    func = params: builtins.hasAttr "a" params.set;
    params = {
      set = {
        a = 1;
      };
    };
    expected.toBe = true;
  }
  {
    description = "builtins.hasAttr (missing)";
    func = params: builtins.hasAttr "z" params.set;
    params = {
      set = {
        a = 1;
      };
    };
    expected.toBe = false;
  }
  {
    description = "builtins.genList";
    func = params: builtins.genList (i: i * i) params.n;
    params = {
      n = 4;
    };
    expected.toBe = [
      0
      1
      4
      9
    ];
  }
  {
    description = "builtins.concatLists";
    func = params: builtins.concatLists params.xss;
    params = {
      xss = [
        [
          1
          2
        ]
        [ 3 ]
        [
          4
          5
        ]
      ];
    };
    expected.toBe = [
      1
      2
      3
      4
      5
    ];
  }
  {
    description = "builtins.elem";
    func = params: builtins.elem params.x params.xs;
    params = {
      x = 3;
      xs = [
        1
        2
        3
        4
      ];
    };
    expected.toBe = true;
  }
  {
    description = "builtins.elem (missing)";
    func = params: builtins.elem params.x params.xs;
    params = {
      x = 9;
      xs = [
        1
        2
        3
        4
      ];
    };
    expected.toBe = false;
  }
  {
    description = "builtins.stringLength";
    func = params: builtins.stringLength params.s;
    params = {
      s = "hello";
    };
    expected.toBe = 5;
  }
  {
    description = "builtins.substring";
    func = params: builtins.substring params.start params.len params.s;
    params = {
      start = 1;
      len = 3;
      s = "hello";
    };
    expected.toBe = "ell";
  }
  {
    description = "builtins.replaceStrings";
    func = params: builtins.replaceStrings params.from params.to params.s;
    params = {
      from = [
        "o"
        "l"
      ];
      to = [
        "0"
        "1"
      ];
      s = "hello world";
    };
    expected.toBe = "he110 w0r1d";
  }
  {
    description = "builtins.typeOf (int)";
    func = params: builtins.typeOf params.x;
    params = {
      x = 42;
    };
    expected.toBe = "int";
  }
  {
    description = "builtins.typeOf (string)";
    func = params: builtins.typeOf params.x;
    params = {
      x = "hi";
    };
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
    func = builtins.lessThan 1;
    params = 0;
    expected.toBe = false;
  }

  # ── mapAttrs ─────────────────────────────────────────────────
  {
    description = "builtins.mapAttrs";
    func = params: builtins.mapAttrs (name: value: value + params.offset) params.set;
    params = {
      set = {
        a = 1;
        b = 2;
      };
      offset = 10;
    };
    expected.toBe = {
      a = 11;
      b = 12;
    };
  }
  {
    description = "builtins.mapAttrs uses key";
    func = params: builtins.mapAttrs (name: value: name + "=" + builtins.toString value) params.set;
    params = {
      set = {
        x = 1;
        y = 2;
      };
    };
    expected.toBe = {
      x = "x=1";
      y = "y=2";
    };
  }

  # ── listToAttrs / intersectAttrs ─────────────────────────────
  {
    description = "builtins.listToAttrs";
    func = params: builtins.listToAttrs params.entries;
    params = {
      entries = [
        {
          name = "a";
          value = 1;
        }
        {
          name = "b";
          value = 2;
        }
      ];
    };
    expected.toBe = {
      a = 1;
      b = 2;
    };
  }
  {
    description = "builtins.intersectAttrs";
    func = params: builtins.intersectAttrs params.a params.b;
    params = {
      a = {
        x = 1;
        y = 2;
      };
      b = {
        y = 99;
        z = 3;
      };
    };
    expected.toBe = {
      y = 99;
    };
  }

  # ── removeAttrs ──────────────────────────────────────────────
  {
    description = "builtins.removeAttrs";
    func = params: builtins.removeAttrs params.set params.names;
    params = {
      set = {
        a = 1;
        b = 2;
        c = 3;
      };
      names = [ "b" ];
    };
    expected.toBe = {
      a = 1;
      c = 3;
    };
  }

  # ── all / any ────────────────────────────────────────────────
  {
    description = "builtins.all (true)";
    func = params: builtins.all (x: x > 0) params.xs;
    params = {
      xs = [
        1
        2
        3
      ];
    };
    expected.toBe = true;
  }
  {
    description = "builtins.any (true)";
    func = params: builtins.any (x: x > 2) params.xs;
    params = {
      xs = [
        1
        2
        3
      ];
    };
    expected.toBe = true;
  }
  {
    description = "builtins.any (false)";
    func = params: builtins.any (x: x > 10) params.xs;
    params = {
      xs = [
        1
        2
        3
      ];
    };
    expected.toBe = false;
  }
  {
    description = "genericClosure (Collatz conjecture)";
    func =
      param:
      builtins.genericClosure {
        startSet = [ { key = param; } ];
        operator = item: [
          {
            key = if (item.key / 2) * 2 == item.key then item.key / 2 else 3 * item.key + 1;
          }
        ];
      };
    params = 5;
    expected.toBe = [
      { key = 5; }
      { key = 16; }
      { key = 8; }
      { key = 4; }
      { key = 2; }
      { key = 1; }
    ];
  }
  {
    description = "genericClosure (BFS order with multi-element operator)";
    func =
      param:
      builtins.genericClosure {
        startSet = [ { key = param; } ];
        operator = item:
          if item.key == 1 then [ { key = 2; } { key = 3; } ]
          else if item.key == 2 then [ { key = 4; } { key = 5; } ]
          else if item.key == 3 then [ { key = 6; } { key = 7; } ]
          else [];
      };
    params = 1;
    expected.toBe = [
      { key = 1; }
      { key = 2; }
      { key = 3; }
      { key = 4; }
      { key = 5; }
      { key = 6; }
      { key = 7; }
    ];
  }
  {
    description = "genericClosure (deduplication)";
    func =
      param:
      builtins.genericClosure {
        startSet = [ { key = param; } ];
        operator = item:
          if item.key == 1 then [ { key = 2; } { key = 3; } ]
          else if item.key == 2 then [ { key = 3; } { key = 4; } ]
          else [];
      };
    params = 1;
    expected.toBe = [
      { key = 1; }
      { key = 2; }
      { key = 3; }
      { key = 4; }
    ];
  }
]
