# Closure conversion — shared code templates with per-instance environments.
#
# These are the regression tests for docs/closure-conversion.md.  Each one
# pins down a way the old runtime-identity walker could (or the new one still
# could) silently miscompile.
[
  {
    description = "two closures of one template keep separate environments";
    func =
      let
        makeAdder = x: (y: x + y);
        add1 = makeAdder 1;
        add2 = makeAdder 2;
      in
      params: [
        (add1 params.n)
        (add2 params.n)
      ];
    params = {
      n = 10;
    };
    expected.toBe = [
      11
      12
    ];
  }

  {
    # A template-key-based cycle guard would tie the knot here and emit
    # `x: k (k x)` instead of `x: h (h x)`, silently returning 2 instead of 4.
    description = "composition does not collapse distinct instances of one template";
    func =
      let
        compose = f: g: (x: f (g x));
        inc = x: x + 1;
        h = compose inc inc;
        k = compose h h;
      in
      params: k params.n;
    params = {
      n = 0;
    };
    expected.toBe = 4;
  }

  {
    description = "self-recursive closure ties its own knot";
    func =
      let
        countDown = n: if n == 0 then 0 else 1 + countDown (n - 1);
      in
      params: countDown params.n;
    params = {
      n = 5;
    };
    expected.toBe = 5;
  }

  {
    description = "mutually recursive closures";
    func =
      let
        isEven = n: if n == 0 then true else isOdd (n - 1);
        isOdd = n: if n == 0 then false else isEven (n - 1);
      in
      params: isEven params.n;
    params = {
      n = 10;
    };
    expected.toBe = true;
  }

  {
    # The original reproduction: a partially applied recursive helper used to
    # generate new hoisted functions forever.
    description = "partially applied recursive helper terminates";
    func =
      let
        walkLicense =
          suffix: license:
          if builtins.isList license then builtins.map (walkLicense suffix) license else license + suffix;
      in
      params:
      walkLicense params.suffix [
        "a"
        [
          "b"
          [ "c" ]
        ]
      ];
    params = {
      suffix = "!";
    };
    expected.toBe = [
      "a!"
      [
        "b!"
        [ "c!" ]
      ]
    ];
  }

  {
    # Without path narrowing the whole `helpers` set is captured and `unused`
    # is forced, which throws at translation time.
    description = "path narrowing captures only the selected attribute";
    func =
      let
        helpers = {
          twice = x: x * 2;
          unused = throw "wechselbalg: this attribute must never be captured";
        };
        f = n: helpers.twice n;
      in
      params: f params.n;
    params = {
      n = 21;
    };
    expected.toBe = 42;
  }

  {
    description = "closed lambda needs no environment";
    func =
      let
        double = x: x * 2;
      in
      params: builtins.map double params.xs;
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
    description = "nested closures capture through several levels";
    func =
      let
        outer = a: (b: (c: a + b + c));
      in
      params: outer params.a params.b params.c;
    params = {
      a = 1;
      b = 20;
      c = 300;
    };
    expected.toBe = 321;
  }

  {
    description = "formals metadata survives closure instantiation";
    func =
      let
        mk =
          prefix:
          {
            a,
            b ? 2,
          }:
          prefix + toString (a + b);
      in
      params: (mk params.prefix) { a = 1; };
    params = {
      prefix = "n=";
    };
    expected.toBe = "n=3";
  }

  {
    description = "functionArgs works through a closure";
    func =
      let
        mk =
          _prefix:
          {
            a,
            b ? 2,
          }:
          a + b;
      in
      params: builtins.functionArgs (mk params.prefix);
    params = {
      prefix = "x";
    };
    expected.toBe = {
      a = false;
      b = true;
    };
  }

  {
    # Every level is reachable through two environment entries.  Without a
    # global memo of walked closure instances the graph is traversed as a
    # tree, so walking this takes 2^24 steps instead of 24.  Only one branch
    # ever runs, so the generated code stays cheap.
    description = "a shared closure graph is walked once per node, not once per path";
    func =
      let
        mk =
          n:
          if n == 0 then
            { f = x: x + 1; }
          else
            let
              prev = mk (n - 1);
              l = a: prev.f a;
              r = b: prev.f b;
            in
            {
              f = c: if c == 0 then l c else r c;
            };
      in
      params: (mk 24).f params.n;
    params = {
      n = 0;
    };
    expected.toBe = 1;
  }
]
