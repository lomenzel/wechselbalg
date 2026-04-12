# Edge cases — sanitization collisions, reserved words, select-or, hasAttr guards
[
  # The sanitize function in both backends renames JS/C++ reserved words
  # by prepending "_" (e.g. int → _int). But if both "int" and "_int"
  # exist as let-bindings in the same scope, they collide to the same
  # target name, producing invalid code (duplicate declaration).
  {
    description = "let bindings with reserved word and its sanitized form";
    func =
      params:
      let
        int = params.a;
        _int = params.b;
      in
      int + _int;
    params = {
      a = 3;
      b = 4;
    };
    expected.toBe = 7;
  }

  # ── select-or on missing paths ──────────────────────────────
  {
    description = "select-or returns default on missing key";
    func = params: params.x or 42;
    params = {
      y = 1;
    };
    expected.toBe = 42;
  }
  {
    description = "select-or returns value when key exists";
    func = params: params.x or 42;
    params = {
      x = 7;
    };
    expected.toBe = 7;
  }
  {
    description = "select-or nested: missing intermediate";
    func = params: params.a.b.c or 99;
    params = {
      a = {
        z = 1;
      };
    };
    expected.toBe = 99;
  }
  {
    description = "select-or nested: non-set intermediate";
    func = params: params.a.b or 55;
    params = {
      a = 42;
    };
    expected.toBe = 55;
  }

  # ── hasAttr on non-set value ────────────────────────────────
  # In Nix, `42 ? x` returns false (not an error).
  # The Nix backend wraps builtins.hasAttr with isAttrs guard.
  {
    description = "hasAttr on non-set returns false";
    func =
      params:
      let
        check = params ? x;
      in
      check;
    params = 42;
    expected.toBe = false;
  }
  {
    description = "hasAttr multi-path on non-set intermediate";
    func = params: params.a ? b;
    params = {
      a = 42;
    };
    expected.toBe = false;
  }

  # ── Deeply nested let with hoisted defs ─────────────────────
  # Tests that hoistable defs from inner scopes propagate correctly.
  {
    description = "nested let with shared helper function";
    func =
      params:
      let
        double = x: x * 2;
        result =
          let
            a = double params;
            b = double (params + 1);
          in
          a + b;
      in
      result;
    params = 5;
    expected.toBe = 22;
  }

  {
    description = "self-referential attrset: non-cyclic access works";
    func =
      params:
      let
        self = {
          x = 1;
          ref = self;
          y = params; # needed to prevent eval from optimizing self away
        };
      in
      self.ref.ref.x + params;
    params = 5;
    expected.toBe = 6;
  }

  # ── Lazy function arguments ────────────────────────────────────
  # In Nix, function arguments are call-by-need — they're only evaluated
  # when the function body actually uses them.  These tests verify that
  # translated code correctly thunks call arguments.

  {
    description = "lazy arg: unused argument with string + null is not forced";
    func =
      params:
      let
        # identity is warnIf-like: ignores msg when cond is false
        warnIf = cond: msg: x: if cond then builtins.trace msg x else x;
      in
      warnIf false "test ${null}" params;
    params = 42;
    expected.toBe = 42;
  }
  {
    description = "lazy arg: unused argument with throw is not forced";
    func =
      params:
      let
        f = x: y: x;
      in
      f params (throw "this should never be evaluated");
    params = 7;
    expected.toBe = 7;
  }
  {
    description = "lazy arg: used argument is correctly forced";
    func =
      params:
      let
        f = x: y: x + y;
      in
      f params 10;
    params = 5;
    expected.toBe = 15;
  }
]
