# Wechselbalg test runner.
#
# Auto-discovers all *.test.nix files in this directory (recursively).
# Each test file returns a list of test cases:
#
#   [{
#     func = params: <some computation>;
#     params = { ... };
#     description = "what this tests";
#     expected.toBe = <expected result>;
#   }]
#
# The runner translates each test's `func` through every backend,
# generates a harness that calls it with `params` and asserts the
# result equals `expected.toBe`, then compiles+runs to verify.
#
# To add a new backend, add an entry to `testBackends` below.
# Each backend needs: translate, nixToLiteral, mkTestBlock, harness, run.
#
# Usage:
#   nix flake check          (runs all tests)
#   nix build .#checks.x86_64-linux.tests

{ pkgs, wechselbalg }:

let
  lib = pkgs.lib;

  # ── Test discovery ──────────────────────────────────────────
  testFiles =
    lib.filesystem.listFilesRecursive ./.
    |> lib.filter (path: lib.hasSuffix ".test.nix" (builtins.toString path));

  allTests = lib.concatMap (
    path:
    let
      tests = import path;
      testList =
        if builtins.typeOf tests == "list" then
          tests
        else if builtins.typeOf tests == "lambda" then
          tests lib
        else
          [ tests ];
      fileName = builtins.baseNameOf (builtins.toString path);
    in
    builtins.map (t: t // { _file = fileName; }) testList
  ) testFiles;

  # ── Nix value → target literal converters ───────────────────

  nixToJS =
    v:
    let
      type = builtins.typeOf v;
    in
    if type == "int" then
      "Value.fromInt(${toString v}n)"
    else if type == "float" then
      "Value.fromFloat(${builtins.toJSON v})"
    else if type == "string" then
      "Value.fromString(${builtins.toJSON v})"
    else if type == "bool" then
      "Value.fromBool(${if v then "true" else "false"})"
    else if type == "null" then
      "Value.null_()"
    else if type == "list" then
      "Value.fromList([${lib.concatMapStringsSep ", " nixToJS v}])"
    else if type == "set" then
      let
        pairs = lib.mapAttrsToList (k: val: "${builtins.toJSON k}: ${nixToJS val}") v;
      in
      "Value.fromSet({${lib.concatStringsSep ", " pairs}})"
    else
      throw "wechselbalg test: cannot convert Nix type '${type}' to JS literal";

  nixToCpp =
    v:
    let
      type = builtins.typeOf v;
    in
    if type == "int" then
      "Value::fromInt(${toString v})"
    else if type == "float" then
      "Value::fromFloat(${builtins.toJSON v})"
    else if type == "string" then
      "Value::fromString(${builtins.toJSON v})"
    else if type == "bool" then
      "Value::fromBool(${if v then "true" else "false"})"
    else if type == "null" then
      "Value::null_()"
    else if type == "list" then
      "Value::fromList({${lib.concatMapStringsSep ", " nixToCpp v}})"
    else if type == "set" then
      let
        pairs = lib.mapAttrsToList (k: val: "{${builtins.toJSON k}, ${nixToCpp val}}") v;
      in
      "Value::fromSet({${lib.concatStringsSep ", " pairs}})"
    else
      throw "wechselbalg test: cannot convert Nix type '${type}' to C++ literal";

  nixToPython =
    v:
    let
      type = builtins.typeOf v;
    in
    if type == "int" then
      "Value.from_int(${toString v})"
    else if type == "float" then
      "Value.from_float(${builtins.toJSON v})"
    else if type == "string" then
      "Value.from_string(${builtins.toJSON v})"
    else if type == "bool" then
      "Value.from_bool(${if v then "True" else "False"})"
    else if type == "null" then
      "Value.null_()"
    else if type == "list" then
      "Value.from_list([${lib.concatMapStringsSep ", " nixToPython v}])"
    else if type == "set" then
      let
        pairs = lib.mapAttrsToList (k: val: "${builtins.toJSON k}: ${nixToPython val}") v;
      in
      "Value.from_set({${lib.concatStringsSep ", " pairs}})"
    else
      throw "wechselbalg test: cannot convert Nix type '${type}' to Python literal";

  nixToNix =
    v:
    let
      type = builtins.typeOf v;
    in
    if type == "int" then
      toString v
    else if type == "float" then
      builtins.toJSON v
    else if type == "string" then
      builtins.toJSON v
    else if type == "bool" then
      (if v then "true" else "false")
    else if type == "null" then
      "null"
    else if type == "list" then
      "[ ${lib.concatMapStringsSep " " nixToNix v} ]"
    else if type == "set" then
      let
        pairs = lib.mapAttrsToList (k: val: "${builtins.toJSON k} = ${nixToNix val};") v;
      in
      "{ ${lib.concatStringsSep " " pairs} }"
    else
      throw "wechselbalg test: cannot convert Nix type '${type}' to Nix literal";

  # ── Backend definitions ─────────────────────────────────────
  # Each backend provides everything needed to build and run tests.
  # To add a new backend, add an entry here with:
  #   translate:    Nix value → target code string
  #   nixToLiteral: Nix value → target literal string
  #   mkTestBlock:  test → code block string for a single test
  #   harness:      [test-blocks] → full source file string
  #   buildInputs:  packages needed to compile/run
  #   mkDrv:        tests → { buildPhase; buildInputs; }
  #
  # Tests that fail to translate (e.g. missing primops) are reported
  # as failures.

  testBackends = {

    # ── JavaScript backend ──────────────────────────────────────
    javascript = rec {
      name = "javascript";
      translate = wechselbalg.toJS;
      nixToLiteral = nixToJS;

      mkTestBlock =
        test:
        let
          tryCode = builtins.tryEval (translate test.func);
        in
        if !tryCode.success then
          {
            block = ''
              // Test: ${test.description}
              {
                throw new Error("FAIL: " + ${builtins.toJSON test.description} + "\n  Reason: translation failed");
              }
            '';
          }
        else
          let
            code = tryCode.value;
            params = nixToLiteral test.params;
            expected = nixToLiteral test.expected.toBe;
          in
          {
            block = ''
              // Test: ${test.description}
              {
                const func = ${code};
                const params = ${params};
                const expected = ${expected};
                const result = func.call(params);
                if (!Value._deepEq(result, expected)) {
                  const r = JSON.stringify(result, (k, v) => typeof v === "bigint" ? v.toString() + "n" : v);
                  const e = JSON.stringify(expected, (k, v) => typeof v === "bigint" ? v.toString() + "n" : v);
                  throw new Error("FAIL: " + ${builtins.toJSON test.description} + "\n  Expected: " + e + "\n  Got:      " + r);
                }
                console.log("PASS: " + ${builtins.toJSON test.description});
              }
            '';
          };

      harness =
        results:
        let
          runtime = wechselbalg.jsRuntime;
        in
        ''
          ${runtime}

          let _passed = 0;
          let _failed = 0;

          ${lib.concatStringsSep "\n" (
            builtins.map (r: ''
              try {
                ${r.block}
                _passed++;
              } catch(e) {
                console.error(e.message || e);
                _failed++;
              }
            '') results
          )}

          console.log("\n" + _passed + " passed, " + _failed + " failed, " + (_passed + _failed) + " total");
          if (_failed > 0) process.exit(1);
        '';

      buildInputs = [ pkgs.nodejs ];

      mkDrv =
        tests:
        let
          results = builtins.map mkTestBlock tests;
          testFile = pkgs.writeText "wechselbalg-tests.js" (harness results);
        in
        {
          buildPhase = ''
            echo "=== Running ${toString (builtins.length results)} wechselbalg tests (${name}) ==="
            node ${testFile}
          '';
          inherit buildInputs;
        };
    };

    # ── C++ backend ─────────────────────────────────────────────
    cpp = rec {
      name = "cpp";
      translate = wechselbalg.toCpp;
      nixToLiteral = nixToCpp;

      mkTestBlock =
        test:
        let
          tryCode = builtins.tryEval (translate test.func);
        in
        if !tryCode.success then
          {
            block = ''
              // Test: ${test.description}
              {
                std::cerr << "FAIL: " << ${builtins.toJSON test.description}
                          << "\n  Reason: translation failed" << std::endl;
                _failed++;
              }
            '';
          }
        else
          let
            code = tryCode.value;
            params = nixToLiteral test.params;
            expected = nixToLiteral test.expected.toBe;
          in
          {
            block = ''
              // Test: ${test.description}
              {
                auto func = ${code};
                auto params = ${params};
                auto expected = ${expected};
                auto result = (func)(params);
                if (!(result == expected)) {
                  std::cerr << "FAIL: " << ${builtins.toJSON test.description}
                            << "\n  Expected: " << expected.toJSON()
                            << "\n  Got:      " << result.toJSON() << std::endl;
                  _failed++;
                } else {
                  std::cout << "PASS: " << ${builtins.toJSON test.description} << std::endl;
                  _passed++;
                }
              }
            '';
          };

      harness =
        results:
        let
          runtime = wechselbalg.cppRuntime;
        in
        ''
          ${runtime}

          int main() {
            int _passed = 0;
            int _failed = 0;

            ${lib.concatStringsSep "\n" (
              builtins.map (r: ''
                try {
                  ${r.block}
                } catch(const std::exception& e) {
                  std::cerr << e.what() << std::endl;
                  _failed++;
                }
              '') results
            )}

            std::cout << "\n" << _passed << " passed, " << _failed << " failed, " << (_passed + _failed) << " total" << std::endl;
            return _failed > 0 ? 1 : 0;
          }
        '';

      buildInputs = [ pkgs.gcc ];

      mkDrv =
        tests:
        let
          results = builtins.map mkTestBlock tests;
          testFile = pkgs.writeText "wechselbalg-tests.cpp" (harness results);
        in
        {
          buildPhase = ''
            echo "=== Running ${toString (builtins.length results)} wechselbalg tests (${name}) ==="
            cp ${testFile} test.cpp
            g++ -std=c++17 -O2 -o test test.cpp
            ./test
          '';
          inherit buildInputs;
        };
    };

    # ── Python backend ──────────────────────────────────────────
    python = rec {
      name = "python";
      translate = wechselbalg.toPython;
      nixToLiteral = nixToPython;

      mkTestBlock =
        test:
        let
          tryCode = builtins.tryEval (translate test.func);
        in
        if !tryCode.success then
          {
            block = ''
              # Test: ${test.description}
              print(f"FAIL: ${test.description}\n  Reason: translation failed", file=sys.stderr)
              _failed += 1
            '';
          }
        else
          let
            code = tryCode.value;
            params = nixToLiteral test.params;
            expected = nixToLiteral test.expected.toBe;
          in
          {
            block = ''
              # Test: ${test.description}
              try:
                  func = ${code}
                  params = ${params}
                  expected = ${expected}
                  result = func.call(params)
                  if not Value._deep_eq(result, expected):
                      print(f"FAIL: ${test.description}\n  Expected: {expected.to_json_().as_string()}\n  Got:      {result.to_json_().as_string()}", file=sys.stderr)
                      _failed += 1
                  else:
                      print(f"PASS: ${test.description}")
                      _passed += 1
              except Exception as e:
                  print(f"ERROR: ${test.description}: {e}", file=sys.stderr)
                  _failed += 1
            '';
          };

      harness =
        results:
        let
          runtime = wechselbalg.pythonRuntime;
        in
        ''
          import sys
          sys.setrecursionlimit(10000)

          ${runtime}

          _passed = 0
          _failed = 0

          ${lib.concatStringsSep "\n" (builtins.map (r: r.block) results)}

          print(f"\n{_passed} passed, {_failed} failed, {_passed + _failed} total")
          if _failed > 0:
              sys.exit(1)
        '';

      buildInputs = [ pkgs.python3 ];

      mkDrv =
        tests:
        let
          results = builtins.map mkTestBlock tests;
          testFile = pkgs.writeText "wechselbalg-tests.py" (harness results);
        in
        {
          buildPhase = ''
            echo "=== Running ${toString (builtins.length results)} wechselbalg tests (${name}) ==="
            python3 ${testFile}
          '';
          inherit buildInputs;
        };
    };

    # ── Nix backend ───────────────────────────────────────────────
    # Since we're compiling Nix → Nix, we can evaluate the generated
    # code at Nix eval time using builtins.import on a toFile.
    # The build phase just prints the pre-computed results.
    nix = rec {
      name = "nix";
      translate = wechselbalg.toNix;
      nixToLiteral = nixToNix;

      deepEq =
        a: b:
        let
          ta = builtins.typeOf a;
          tb = builtins.typeOf b;
        in
        if ta != tb then
          false
        else if ta == "set" then
          let
            aNames = builtins.attrNames a;
            bNames = builtins.attrNames b;
          in
          aNames == bNames && builtins.all (n: deepEq a.${n} b.${n}) aNames
        else if ta == "list" then
          builtins.length a == builtins.length b
          && builtins.all (i: deepEq (builtins.elemAt a i) (builtins.elemAt b i)) (
            builtins.genList (i: i) (builtins.length a)
          )
        else
          a == b;

      mkTestBlock =
        test:
        let
          tryCode = builtins.tryEval (translate test.func);
        in
        if !tryCode.success then
          {
            pass = false;
            desc = test.description;
            got = { success = true; value = "translation failed"; };
            expected = { success = true; value = "successful translation"; };
          }
        else
          let
            code = tryCode.value;
            # Evaluate the generated Nix code at Nix eval time
            codeFile = builtins.toFile "wechselbalg-test.nix" code;
            tryResult = builtins.tryEval (
              let
                func = import codeFile;
                result = func test.params;
              in
              deepEq result test.expected.toBe
            );
          in
          if !tryResult.success then
            {
              pass = false;
              desc = test.description;
              got = { success = true; value = "eval failed"; };
              expected = { success = true; value = "successful eval"; };
            }
          else if tryResult.value then
            {
              pass = true;
              desc = test.description;
            }
          else
            # Re-evaluate to get the actual result for the error message
            let
              func = import codeFile;
              result = func test.params;
            in
            {
              pass = false;
              desc = test.description;
              got = builtins.tryEval (builtins.toJSON result);
              expected = builtins.tryEval (builtins.toJSON test.expected.toBe);
            };

      # Not needed for Nix — tests run at eval time
      harness = _: "";

      buildInputs = [ ];

      mkDrv =
        tests:
        let
          results = builtins.map mkTestBlock tests;
          passed = builtins.filter (r: r.pass or false) results;
          failed = builtins.filter (r: !(r.pass or false)) results;

          escapeForBash =
            s:
            lib.replaceStrings
              [
                "'"
                "("
                ")"
                "&"
                "|"
                ";"
                "<"
                ">"
                "$"
                "`"
                "\\"
                "\""
                "\n"
              ]
              [
                "'\"'\"'"
                "\\("
                "\\)"
                "\\&"
                "\\|"
                "\\;"
                "\\<"
                "\\>"
                "\\$"
                "\\`"
                "\\\\"
                "\\\""
                " "
              ]
              s;
          passLines = builtins.map (r: "echo 'PASS: ${escapeForBash r.desc}'") passed;
          failLines = builtins.map (
            r:
            let
              gotStr =
                if (r.got or { success = false; }).success or false then
                  escapeForBash r.got.value
                else
                  "<eval error>";
              expStr =
                if (r.expected or { success = false; }).success or false then
                  escapeForBash r.expected.value
                else
                  "<eval error>";
            in
            "echo 'FAIL: ${escapeForBash r.desc}'; echo '  Expected: ${expStr}'; echo '  Got:      ${gotStr}'"
          ) failed;
          summary = "${toString (builtins.length passed)} passed, ${toString (builtins.length failed)} failed, ${toString (builtins.length results)} total";
        in
        {
          buildPhase = ''
            echo "=== Running wechselbalg tests (${name}) ==="
            ${lib.concatStringsSep "\n" passLines}
            ${lib.concatStringsSep "\n" failLines}
            echo ""
            echo "${summary}"
            ${if (builtins.length failed) > 0 then "exit 1" else ""}
          '';
          inherit buildInputs;
        };
    };

  };

  # ── Build one derivation per backend ────────────────────────
  mkBackendDrv =
    _name: backend:
    let
      drv = backend.mkDrv allTests;
    in
    pkgs.stdenv.mkDerivation {
      name = "wechselbalg-tests-${backend.name}";
      dontUnpack = true;
      nativeBuildInputs = drv.buildInputs;
      buildPhase = drv.buildPhase;
      installPhase = ''
        echo "All ${backend.name} tests passed." > $out
      '';
    };

in
lib.mapAttrs mkBackendDrv testBackends
