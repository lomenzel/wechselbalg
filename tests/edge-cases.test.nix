# Edge cases — sanitization collisions, reserved words, select-or
[
  # The sanitize function in both backends renames JS/C++ reserved words
  # by prepending "_" (e.g. int → _int). But if both "int" and "_int"
  # exist as let-bindings in the same scope, they collide to the same
  # target name, producing invalid code (duplicate declaration).
  {
    description = "let bindings with reserved word and its sanitized form";
    func = params:
      let
        int = params.a;
        _int = params.b;
      in int + _int;
    params = { a = 3; b = 4; };
    expected.toBe = 7;
  }
]
