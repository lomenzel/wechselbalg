# Tests for paths: paths are unsupported in target languages and should produce runtime errors
# Unused paths (e.g. captured in attrsets/closures) must translate cleanly without compile errors.
[
  {
    description = "set containing path does not fail at runtime unless path attribute is accessed";
    func =
      params:
      let
        s = {
          a = params;
          p = /.;
        };
      in
      s.a;
    params = 42;
    expected.toBe = 42;
  }
  {
    description = "closure capturing path does not fail at runtime unless path is accessed";
    func =
      params:
      let
        myPath = /.;
        f = x: x + 1;
      in
      f params;
    params = 10;
    expected.toBe = 11;
  }
  {
    description = "import of a directory with default.nix via attr path (evalModules style)";
    func =
      params:
      let
        # Mirrors lib.evalModules' module loading: `imports = [ ./dir ]` where
        # the dir holds a default.nix. The import is resolved at translation
        # time and inlined into the target program.
        imports = [ ./fixtures/path-import-mod ];
        mergeImports =
          acc: p:
          let
            mod = import p;
          in
          {
            value = acc.value + mod.value;
            count = acc.count + 1;
          };
      in
      builtins.foldl' mergeImports {
        value = params.base;
        count = 0;
      } imports;
    params = {
      base = 0;
    };
    expected.toBe = {
      value = 42;
      count = 1;
    };
  }
  # ── Minimal repros of the directory-import meta bug (no evalModules) ──
  # A path passed as a function *parameter* carries no translation-time fs
  # record in the translated program, so `import` fails at runtime with
  # "path ... has no translation-time filesystem record".
  {
    description = "import of a directory with default.nix passed via params";
    func = params: import params.dir;
    params = {
      dir = ./fixtures/import-mod;
    };
    expected.toBe = 42;
  }
  # Contrast: the exact same import written as a literal path inline is
  # resolved and inlined at translation time, so it works everywhere.
  {
    description = "inline import of a directory with default.nix (literal path)";
    func = params: (import ./fixtures/import-mod) + params;
    params = 1;
    expected.toBe = 43;
  }
  # ── Composed paths (spec §5.5: "Composed paths are not supported") ──
  # `dir + "/x"` with a runtime path value keeps the *correct joined string*,
  # but a runtime concatenation cannot carry the translation-time filesystem
  # record: the result is a plain string tagged composed-from-a-path. String
  # behaviour stays exact; every fs lookup throws an explicit error, observed
  # here through the target runtime's own tryEval.
  # NOTE: `expected` here describes the *translated runtime* (e.g. Node), not
  # Nix itself — in Nix `readFile (p + "/nested.txt")` succeeds, so the
  # self-hosting nix backend is expected to fail these; the js/cpp backends
  # pass. The joined path is never compared against a literal string: expected
  # values live inside derivations, and a string carrying a store-path context
  # there is rejected by Nix ("not allowed to refer to a store path") — and
  # under a flake the fixture lives inside the copied source tree, so any
  # claim about its shape is wrong anyway. The checks below compare the joined
  # string against the *other operand's own* string form, split at exact
  # stringLength offsets: exact, and free of any context.
  {
    description = "composed path: joined string correct, fs lookups throw";
    func =
      p:
      let
        composed = p + "/nested.txt";
        pStr = builtins.toString p;
        pLen = builtins.stringLength pStr;
        rf = builtins.tryEval (builtins.readFile composed);
        pe = builtins.tryEval (builtins.pathExists composed);
        im = builtins.tryEval (import composed);
      in
      {
        joinedOk =
          (builtins.substring 0 pLen composed) == pStr
          && (builtins.substring pLen (-1) composed) == "/nested.txt";
        allThrew = !rf.success && !pe.success && !im.success;
      };
    params = ./fixtures/import-mod;
    expected.toBe = {
      joinedOk = true;
      allThrew = true;
    };
    onlyBackends = [
      "javascript"
      "cpp"
      "cpp-library"
      "cpp-library-armv7l"
    ];
  }
  {
    description = "composed path: further concatenation stays a usable string";
    func =
      p:
      let
        c1 = p + "/a";
        c2 = c1 + "/b";
        len1 = builtins.stringLength c1;
      in
      (builtins.substring 0 len1 c2) == c1 && (builtins.substring len1 (-1) c2) == "/b";
    params = ./fixtures/import-mod;
    expected.toBe = true;
    onlyBackends = [
      "javascript"
      "cpp"
      "cpp-library"
      "cpp-library-armv7l"
    ];
  }
  {
    description = "interpolating a path value yields an ordinary string";
    func =
      p:
      let
        s = "x ${p} y";
        pStr = builtins.toString p;
        pLen = builtins.stringLength pStr;
        len = builtins.stringLength s;
      in
      (builtins.substring 0 2 s) == "x "
      && (builtins.substring 2 pLen s) == pStr
      && (builtins.substring (len - 2) (-1) s) == " y";
    params = ./fixtures/import-mod;
    expected.toBe = true;
    onlyBackends = [
      "javascript"
      "cpp"
      "cpp-library"
      "cpp-library-armv7l"
    ];
  }
  {
    description = "pathExists on a plain string is false, not an error";
    func = _: builtins.pathExists "/definitely-not-in-the-nix-store/nothing.txt";
    params = 0;
    expected.toBe = false;
  }
]
