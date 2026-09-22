{
  pkgs,
  wechselbalg,
}:
let
  lib = pkgs.lib;

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

  testBackends = {
    javascript = rec {
      name = "javascript";
      translate = wechselbalg.toJS;

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
            params = translate test.params;
            expected = translate test.expected.toBe;
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

    # ── TypeScript backend ──────────────────────────────────────
    typescript = rec {
      name = "typescript";
      translate = wechselbalg.toTS;

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
            params = translate test.params;
            expected = translate test.expected.toBe;
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
          runtime = wechselbalg.tsRuntime;
        in
        ''
          declare var process: { exit(code: number): never };

          ${runtime}

          let _passed = 0;
          let _failed = 0;

          ${lib.concatStringsSep "\n" (
            builtins.map (r: ''
              try {
                ${r.block}
                _passed++;
              } catch(e: any) {

                console.error(e.message || e);
                _failed++;
              }
            '') results
          )}

          console.log("\n" + _passed + " passed, " + _failed + " failed, " + (_passed + _failed) + " total");
          if (_failed > 0) process.exit(1);
        '';

      buildInputs = [
        pkgs.typescript
        pkgs.nodejs
      ];

      mkDrv =
        tests:
        let
          results = builtins.map mkTestBlock tests;
          testFile = pkgs.writeText "wechselbalg-tests.ts" (harness results);
        in
        {
          buildPhase = ''
            echo "=== Running ${toString (builtins.length results)} wechselbalg tests (${name}) ==="
            cp ${testFile} test.ts
            tsc --target ES2020 --moduleResolution node test.ts
            node test.js
          '';
          inherit buildInputs;
        };
    };

    # ── C++ backend ─────────────────────────────────────────────
    cpp = rec {
      name = "cpp";
      translate = wechselbalg.toCpp;

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
            params = translate test.params;
            expected = translate test.expected.toBe;
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
            g++ -o test test.cpp
            ./test
          '';
          inherit buildInputs;
        };
    };

    # ── Python backend ──────────────────────────────────────────
    python = rec {
      name = "python";
      translate = wechselbalg.toPython;

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
            params = translate test.params;
            expected = translate test.expected.toBe;
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

    # ── Kotlin backend ──────────────────────────────────────────
    kotlin = rec {
      name = "kotlin";
      translate = wechselbalg.toKotlin;

      mkTestBlock =
        test:
        let
          tryCode = builtins.tryEval (translate test.func);
        in
        if !tryCode.success then
          {
            block = ''
              // Test: ${test.description}
              run {
                System.err.println("FAIL: " + ${builtins.toJSON test.description} + "\n  Reason: translation failed")
                _failed++
              }
            '';
          }
        else
          let
            code = tryCode.value;
            params = translate test.params;
            expected = translate test.expected.toBe;
          in
          {
            block = ''
              // Test: ${test.description}
              run {
                val func = ${code}
                val params = ${params}
                val expected = ${expected}
                val result = func.call(params)
                if (!Value._deepEq(result, expected)) {
                  val r = result.toJSON_().asString()
                  val e = expected.toJSON_().asString()
                  System.err.println("FAIL: " + ${builtins.toJSON test.description} + "\n  Expected: " + e + "\n  Got:      " + r)
                  _failed++
                } else {
                  println("PASS: " + ${builtins.toJSON test.description})
                  _passed++
                }
              }
            '';
          };

      harness =
        results:
        let
          runtime = wechselbalg.kotlinRuntime;
        in
        ''
          ${runtime}

          fun main() {
            var _passed = 0
            var _failed = 0

            ${lib.concatStringsSep "\n" (
              builtins.map (r: ''
                try {
                  ${r.block}
                } catch(e: Throwable) {
                  System.err.println("ERROR: " + (e.message ?: e.toString()))
                  _failed++
                }
              '') results
            )}

            println("\n" + _passed + " passed, " + _failed + " failed, " + (_passed + _failed) + " total")
            if (_failed > 0) kotlin.system.exitProcess(1)
          }
        '';

      buildInputs = [
        pkgs.kotlin
        pkgs.openjdk
      ];

      mkDrv =
        tests:
        let
          results = builtins.map mkTestBlock tests;
          testFile = pkgs.writeText "wechselbalg-tests.kt" (harness results);
        in
        {
          buildPhase = ''
            echo "=== Running ${toString (builtins.length results)} wechselbalg tests (${name}) ==="
            cp ${testFile} Test.kt
            kotlinc -include-runtime -d test.jar Test.kt
            java -jar test.jar
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
            got = {
              success = true;
              value = "translation failed";
            };
            expected = {
              success = true;
              value = "successful translation";
            };
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
              got = {
                success = true;
                value = "eval failed";
              };
              expected = {
                success = true;
                value = "successful eval";
              };
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
          script = pkgs.writeText "wechselbalg-tests-nix.sh" (
            ''
              echo "=== Running wechselbalg tests (${name}) ==="
            ''
            + lib.concatStringsSep "\n" passLines
            + lib.concatStringsSep "\n" failLines
            + ''

              echo "${summary}"
            ''
            + (if (builtins.length failed) > 0 then "exit 1" else "")
          );
        in
        {
          buildPhase = ''
            bash ${script}
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
// {
  # ── C++ library mode integration test ───────────────────────
  # Builds a generated wechselbalg value as a standalone static
  # library, then links a small consumer against it and runs it.
  cpp-library =
    let
      # The value being exported: a curried adder
      a = x: x + 1;
      increment = x: a x;
      libSpec = wechselbalg.mkCppLibrary {
        value = { inherit increment; };
        namespace = "testFN";
      };
      generatedLib = libSpec.mkDerivation pkgs;

      libSpec2 = wechselbalg.mkCppLibrary {
        value = {
          a = 41;
          b = -1;
        };
        namespace = "base";
      };
      generatedLib2 = libSpec2.mkDerivation pkgs;
    in
    pkgs.stdenv.mkDerivation {
      name = "wechselbalg-cpp-library-test";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.gcc ];
      buildInputs = [
        generatedLib
        generatedLib2
      ];
      buildPhase = ''
        cat > main.cpp <<'EOF'
        #include <testFN.hpp>
        #include <base.hpp>
        #include <cstdio>
        int main() {
          auto r1 = testFN::increment(base::a).asInt();
          auto r2 = testFN::increment(base::b).asInt();
          if (r1 != ${wechselbalg.toCpp 42}.asInt()) { std::fprintf(stderr, "FAIL: increment(41) = %lld\n", r1); return 1; }
          if (r2 != 0)  { std::fprintf(stderr, "FAIL: increment(-1) = %lld\n", r2); return 1; }
          std::printf("PASS: cpp library mode (increment 41 = %lld, -1 = %lld)\n", r1, r2);
          return 0;
        }
        EOF
        g++ -std=c++23 -O2  main.cpp \
          -ltestFN -lbase \
          -o test_bin
        ./test_bin
      '';
      installPhase = ''
        echo "cpp library test passed." > $out
      '';
    };
}
