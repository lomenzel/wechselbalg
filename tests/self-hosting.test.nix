# Self-hosting — `builtins.reify` and `builtins.sameFunction` must work in
# every target runtime, not just in Nix.
#
# Closure conversion is what makes this possible: the environment of a
# function is a first-class value at runtime instead of being inlined into
# the compiled body.
[
  {
    description = "sameFunction: a function is the same as itself";
    func =
      params:
      let
        f = x: x + params.n;
      in
      builtins.sameFunction f f;
    params = {
      n = 1;
    };
    expected.toBe = true;
  }

  {
    description = "sameFunction: two separate instantiations differ";
    func =
      params:
      let
        mk = n: (x: x + n);
      in
      builtins.sameFunction (mk params.n) (mk params.n);
    params = {
      n = 1;
    };
    expected.toBe = false;
  }

  {
    description = "sameFunction: primops compare by name";
    func = _params: builtins.sameFunction builtins.length builtins.length;
    params = { };
    expected.toBe = true;
  }

  {
    description = "sameFunction: different primops differ";
    func = _params: builtins.sameFunction builtins.length builtins.head;
    params = { };
    expected.toBe = false;
  }

  {
    description = "sameFunction: a primop is never a lambda";
    func = _params: builtins.sameFunction builtins.length (x: x);
    params = { };
    expected.toBe = false;
  }

  {
    description = "reify: argument name of a simple lambda";
    func = _params: (builtins.reify (x: x)).value.arguments.identifier;
    params = { };
    expected.toBe = "x";
  }

  {
    description = "reify: node kind of the body";
    func = _params: (builtins.reify (x: x + 1)).value.body._expr;
    params = { };
    expected.toBe = "concatString/addition";
  }

  {
    description = "reify: a primop reports its name";
    func = _params: (builtins.reify builtins.length).value;
    params = { };
    expected.toBe = "length";
  }

  {
    description = "reify: formals are reported";
    func =
      _params:
      builtins.map (f: f.name)
        (builtins.reify (
          {
            a,
            b ? 1,
          }:
          a + b
        )).value.arguments.formals;
    params = { };
    expected.toBe = [
      "a"
      "b"
    ];
  }

  {
    description = "reify: a captured variable is reachable via closureEnvValue";
    func =
      params:
      let
        mk = n: (x: x + n);
        body = (builtins.reify (mk params.n)).value.body;
        # body is `x + n`; the second operand is the captured `n`
        captured = builtins.elemAt body.value 1;
      in
      captured.value.closureEnvValue;
    params = {
      n = 7;
    };
    expected.toBe = 7;
  }

  {
    description = "reify: a bound variable has no closureEnvValue";
    func =
      params:
      let
        mk = n: (x: x + n);
        body = (builtins.reify (mk params.n)).value.body;
        bound = builtins.head body.value;
      in
      bound.value ? closureEnvValue;
    params = {
      n = 7;
    };
    expected.toBe = false;
  }

  {
    description = "reify: root node is a lambda";
    func = _params: (builtins.reify (x: x))._expr;
    params = { };
    expected.toBe = "lambda";
  }

  {
    description = "reify: a narrowed capture still reifies";
    func =
      params:
      let
        helpers = {
          nested = {
            twice = x: x * 2;
          };
        };
        f = x: helpers.nested.twice x;
      in
      builtins.seq (builtins.reify f) (f params.n);
    params = {
      n = 4;
    };
    expected.toBe = 8;
  }
]
