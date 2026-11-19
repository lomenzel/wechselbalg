{
  pkgs,
  plainLib,
  ...
}:
let
  lib = pkgs.lib;

  # Target package set for ARMv7 with hard-float (Galaxy S4 Mini / postmarketOS)
  armPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
  qemuArm = pkgs.buildPackages.qemu;

  testFiles =
    lib.filesystem.listFilesRecursive ./.
    |> lib.filter (path: lib.hasSuffix "test.nix" (builtins.toString path));

  allTests = lib.concatMap (
    path:
    let
      tests = import path;
      testList =
        if builtins.typeOf tests == "list" then
          tests
        else if builtins.typeOf tests == "lambda" then
          tests { inherit pkgs lib plainLib; }
        else
          [ tests ];
      fileName = builtins.baseNameOf (builtins.toString path);
    in
    builtins.map (t: t // { _file = fileName; }) testList
  ) testFiles;

  # Clean string for Nix store path names: letters, numbers, -, _, .
  sanitizeDerivName =
    str:
    let
      # Replace spaces, colons, slashes, parens with dashes
      cleaned =
        builtins.replaceStrings
          [
            " "
            "/"
            "\\"
            ":"
            "("
            ")"
            "["
            "]"
            "{"
            "}"
            "\""
            "'"
            ","
            "<"
            ">"
            "."
            "+"
            "|"
            "="
            "&"
            "@"
          ]
          [
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
            "-"
          ]
          str;
      # Truncate long descriptions so the store path doesn't exceed Linux filename limits
      truncated = builtins.substring 0 35 cleaned;
    in
    truncated;

  # Generates: <fileName>_<sanitizedDesc>_<shortHash>
  # e.g.: modules.test.nix_evalModules-pulls-in-all-of-lib_f5e4e5eeb7ec
  mkTestId =
    test:
    let
      cleanFile = lib.removeSuffix ".test.nix" test._file;
      cleanDesc = sanitizeDerivName test.description;
      hash = builtins.substring 0 8 (builtins.hashString "sha256" "${test._file}:${test.description}");
    in
    "${cleanFile}_${cleanDesc}_${hash}";
  # ── Eval-time Translation Helper ────────────────────────────
  tryTranslate =
    translate: test:
    let
      tf = builtins.tryEval (translate test.func);
      tp = builtins.tryEval (translate test.params);
      te = builtins.tryEval (translate test.expected.toBe);
    in
    if tf.success && tp.success && te.success then
      {
        success = true;
        func = tf.value;
        params = tp.value;
        expected = te.value;
      }
    else
      {
        success = false;
        reason =
          if !tf.success then
            "function translation failed"
          else if !tp.success then
            "params translation failed"
          else
            "expected value translation failed";
      };

  # ── Generic Isolated Test Derivation ────────────────────────
  mkIsolatedTestDrv =
    {
      backendName,
      testId,
      test,
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      runScript,
    }:
    pkgs.stdenv.mkDerivation {
      name = "wechselbalg-test-${backendName}-${testId}";
      dontUnpack = true;
      inherit nativeBuildInputs buildInputs;
      dontFixup = true;
      buildPhase = ''
        mkdir -p $out
        echo ${lib.escapeShellArg test.description} > $out/desc

        set +e
        (
          ${runScript}
        ) > run.log 2>&1
        exit_code=$?
        set -e

        if [ $exit_code -eq 0 ]; then
          echo "PASS" > $out/status
          cat run.log > $out/log
        else
          echo "FAIL" > $out/status
          {
            echo "FAIL: " ${lib.escapeShellArg test.description}
            cat run.log
          } > $out/log
        fi
      '';
      installPhase = "true";
    };

  # ── Shared Test Aggregator ──────────────────────────────────
  mkAggregator =
    { name, testDrvs }:
    let
      aggregatorScript = pkgs.writeShellScript "aggregate-${name}-tests.sh" ''
        passed=0
        failed=0
        total=0

        for dir in "$@"; do
          total=$((total + 1))
          status=$(cat "$dir/status" 2>/dev/null || echo "FAIL")
          log=$(cat "$dir/log" 2>/dev/null || echo "No log output")

          if [ "$status" = "PASS" ]; then
            echo "$log"
            passed=$((passed + 1))
          else
            echo "$log" >&2
            failed=$((failed + 1))
          fi
        done

        echo ""
        echo "$passed passed, $failed failed, $total total"

        if [ "$failed" -gt 0 ]; then
          exit 1
        fi
      '';
    in
    pkgs.stdenv.mkDerivation {
      name = "wechselbalg-tests-${name}";
      dontUnpack = true;
      dontFixup = true;
      buildPhase = ''
        echo "=== Aggregating ${toString (builtins.length testDrvs)} ${name} tests ==="
        ${aggregatorScript} ${lib.concatStringsSep " " (builtins.map (d: "${d}") testDrvs)}
      '';
      installPhase = ''
        echo "All ${name} tests passed." > $out
      '';
    };

  # Multi-library C++ linking smoke test for native host
  smokeTestDrv =
    let
      smokeLib1 =
        (lib.mkCppLibrary {
          value = {
            increment = x: x + 1;
          };
          namespace = "testFN";
        }).mkDerivation
          pkgs;

      smokeLib2 =
        (lib.mkCppLibrary {
          value = {
            a = 41;
            b = -1;
          };
          namespace = "base";
        }).mkDerivation
          pkgs;

      smokeSrc = pkgs.writeText "smoke.cpp" ''
        #include <testFN.hpp>
        #include <base.hpp>
        #include <iostream>

        int main() {
          auto r1 = testFN::increment(base::a).asInt();
          auto r2 = testFN::increment(base::b).asInt();
          if (r1 != 42 || r2 != 0) {
            std::cerr << "  increment(41)=" << r1 << ", increment(-1)=" << r2 << std::endl;
            return 1;
          }
          std::cout << "PASS: multi-library linking check" << std::endl;
          return 0;
        }
      '';
    in
    mkIsolatedTestDrv {
      backendName = "cpp-library";
      testId = "smoke";
      test = {
        description = "multi-library linking check";
      };
      nativeBuildInputs = [ pkgs.gcc ];
      buildInputs = [
        smokeLib1
        smokeLib2
      ];
      runScript = ''
        g++ -std=c++23 -O2 ${smokeSrc} -ltestFN -lbase -o test_bin
        ./test_bin
      '';
    };

  # Multi-library C++ linking smoke test for ARMv7 via QEMU
  smokeTestArmv7Drv =
    let
      smokeLib1 =
        (lib.mkCppLibrary {
          value = {
            increment = x: x + 1;
          };
          namespace = "testFN";
        }).mkDerivation
          armPkgs;

      smokeLib2 =
        (lib.mkCppLibrary {
          value = {
            a = 41;
            b = -1;
          };
          namespace = "base";
        }).mkDerivation
          armPkgs;

      smokeSrc = pkgs.writeText "smoke-arm.cpp" ''
        #include <testFN.hpp>
        #include <base.hpp>
        #include <iostream>

        int main() {
          auto r1 = testFN::increment(base::a).asInt();
          auto r2 = testFN::increment(base::b).asInt();
          if (r1 != 42 || r2 != 0) {
            std::cerr << "  increment(41)=" << r1 << ", increment(-1)=" << r2 << std::endl;
            return 1;
          }
          std::cout << "PASS: [armv7l] multi-library linking check (qemu-arm)" << std::endl;
          return 0;
        }
      '';
    in
    mkIsolatedTestDrv {
      backendName = "cpp-library-armv7l";
      testId = "smoke";
      test = {
        description = "[armv7l] multi-library linking check (qemu-arm)";
      };
      nativeBuildInputs = [
        armPkgs.stdenv.cc
        qemuArm
      ];
      buildInputs = [
        smokeLib1
        smokeLib2
      ];
      runScript = ''
        # 1. Cross-compile with explicit include & library paths
        ${armPkgs.stdenv.cc.targetPrefix}g++ -std=c++23 -O2 ${smokeSrc} \
          -I${smokeLib1}/include \
          -I${smokeLib2}/include \
          -L${smokeLib1}/lib \
          -L${smokeLib2}/lib \
          -ltestFN -lbase \
          -o test_bin

        # 2. Set dynamic library path for ARM libstdc++ and generated libs
        export QEMU_LD_PREFIX="${armPkgs.stdenv.cc.libc}"
        export QEMU_SET_ENV="LD_LIBRARY_PATH=${armPkgs.stdenv.cc.cc.lib}/armv7l-unknown-linux-gnueabihf/lib:${smokeLib1}/lib:${smokeLib2}/lib"

        # 3. Execute via QEMU user emulation
        qemu-arm ./test_bin
      '';
    };

  # ── Target Language Backends ────────────────────────────────
  testBackends = {
    # ── JavaScript
    javascript = {
      name = "javascript";
      mkTestDrv =
        { testId, test }:
        let
          t = tryTranslate lib.toJS test;
          testFile =
            if !t.success then
              null
            else
              pkgs.writeText "test-${testId}.js" ''
                ${lib.jsRuntime}
                const func = ${t.func};
                const params = ${t.params};
                const expected = ${t.expected};
                const result = func.call(params);
                if (!Value._deepEq(result, expected)) {
                  const r = JSON.stringify(result, (k, v) => typeof v === "bigint" ? v.toString() + "n" : v);
                  const e = JSON.stringify(expected, (k, v) => typeof v === "bigint" ? v.toString() + "n" : v);
                  console.error("  Expected: " + e + "\n  Got:      " + r);
                  process.exit(1);
                }
                console.log("PASS: " + ${builtins.toJSON test.description});
              '';
        in
        mkIsolatedTestDrv {
          backendName = "javascript";
          inherit testId test;
          nativeBuildInputs = [ pkgs.nodejs ];
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else
              "node ${testFile}";
        };
    };

    # ── TypeScript
    typescript = {
      name = "typescript";
      mkTestDrv =
        { testId, test }:
        let
          t = tryTranslate lib.toTS test;
          testFile =
            if !t.success then
              null
            else
              pkgs.writeText "test-${testId}.ts" ''
                declare var process: { exit(code: number): never };
                ${lib.tsRuntime}
                const func = ${t.func};
                const params = ${t.params};
                const expected = ${t.expected};
                const result = func.call(params);
                if (!Value._deepEq(result, expected)) {
                  const r = JSON.stringify(result, (k, v) => typeof v === "bigint" ? v.toString() + "n" : v);
                  const e = JSON.stringify(expected, (k, v) => typeof v === "bigint" ? v.toString() + "n" : v);
                  console.error("  Expected: " + e + "\n  Got:      " + r);
                  process.exit(1);
                }
                console.log("PASS: " + ${builtins.toJSON test.description});
              '';
        in
        mkIsolatedTestDrv {
          backendName = "typescript";
          inherit testId test;
          nativeBuildInputs = [
            pkgs.typescript
            pkgs.nodejs
          ];
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else
              ''
                cp ${testFile} test.ts
                tsc --target ES2020 --moduleResolution node test.ts
                node test.js
              '';
        };
    };

    # ── Python
    python = {
      name = "python";
      mkTestDrv =
        { testId, test }:
        let
          t = tryTranslate lib.toPython test;
          testFile =
            if !t.success then
              null
            else
              pkgs.writeText "test-${testId}.py" ''
                import sys
                sys.setrecursionlimit(10000)
                ${lib.pythonRuntime}
                func = ${t.func}
                params = ${t.params}
                expected = ${t.expected}
                result = func.call(params)
                if not Value._deep_eq(result, expected):
                    print(f"  Expected: {expected.to_json_().as_string()}\n  Got:      {result.to_json_().as_string()}", file=sys.stderr)
                    sys.exit(1)
                print("PASS: " + ${builtins.toJSON test.description})
              '';
        in
        mkIsolatedTestDrv {
          backendName = "python";
          inherit testId test;
          nativeBuildInputs = [ pkgs.python3 ];
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else
              "python3 ${testFile}";
        };
    };

    # ── Kotlin
    kotlin = {
      name = "kotlin";
      mkTestDrv =
        { testId, test }:
        let
          t = tryTranslate lib.toKotlin test;
          testFile =
            if !t.success then
              null
            else
              pkgs.writeText "Test-${testId}.kt" ''
                ${lib.kotlinRuntime}
                fun main() {
                  val func = ${t.func}
                  val params = ${t.params}
                  val expected = ${t.expected}
                  val result = func.call(params)
                  if (!Value._deepEq(result, expected)) {
                    val r = result.toJSON_().asString()
                    val e = expected.toJSON_().asString()
                    System.err.println("  Expected: " + e + "\n  Got:      " + r)
                    kotlin.system.exitProcess(1)
                  }
                  println("PASS: " + ${builtins.toJSON test.description})
                }
              '';
        in
        mkIsolatedTestDrv {
          backendName = "kotlin";
          inherit testId test;
          nativeBuildInputs = [
            pkgs.kotlin
            pkgs.openjdk
          ];
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else
              ''
                cp ${testFile} Test.kt
                kotlinc -include-runtime -d test.jar Test.kt
                java -jar test.jar
              '';
        };
    };

    # ── Nix
    nix = {
      name = "nix";
      mkTestDrv =
        { testId, test }:
        let
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

          t = tryTranslate lib.toNix test;
          evalResult =
            if !t.success then
              {
                pass = false;
                reason = t.reason;
              }
            else
              let
                codeFile = builtins.toFile "test-${testId}.nix" t.func;
                tryRes = builtins.tryEval (
                  let
                    func = import codeFile;
                    result = func test.params;
                  in
                  {
                    isEq = deepEq result test.expected.toBe;
                    got = builtins.toJSON result;
                    exp = builtins.toJSON test.expected.toBe;
                  }
                );
              in
              if !tryRes.success then
                {
                  pass = false;
                  reason = "evaluation threw an error";
                }
              else if tryRes.value.isEq then
                { pass = true; }
              else
                {
                  pass = false;
                  reason = "  Expected: ${tryRes.value.exp}\n  Got:      ${tryRes.value.got}";
                };
        in
        mkIsolatedTestDrv {
          backendName = "nix";
          inherit testId test;
          runScript =
            if evalResult.pass then
              "echo 'PASS: '${lib.escapeShellArg test.description}"
            else
              ''
                echo ${lib.escapeShellArg evalResult.reason} >&2
                exit 1
              '';
        };
    };

    # ── Direct C++ (Native Host)
    cpp = {
      name = "cpp";
      mkTestDrv =
        { testId, test }:
        let
          t = tryTranslate lib.toCpp test;
          cppSrc =
            if !t.success then
              null
            else
              pkgs.writeText "test-${testId}.cpp" ''
                #include <iostream>
                #include <exception>

                ${lib.cppRuntime}

                int main() {
                  try {
                    auto func = ${t.func};
                    auto params = ${t.params};
                    auto expected = ${t.expected};
                    auto result = (func)(params);
                    if (!(result == expected)) {
                      std::cerr << "  Expected: " << expected.toJSON()
                                << "\n  Got:      " << result.toJSON() << std::endl;
                      return 1;
                    }
                    std::cout << "PASS: " << ${builtins.toJSON test.description} << std::endl;
                    return 0;
                  } catch(const std::exception& e) {
                    std::cerr << "  Exception: " << e.what() << std::endl;
                    return 1;
                  } catch(...) {
                    std::cerr << "  Unknown exception" << std::endl;
                    return 1;
                  }
                }
              '';
        in
        mkIsolatedTestDrv {
          backendName = "cpp";
          inherit testId test;
          nativeBuildInputs = [ pkgs.gcc ];
          buildInputs = [ pkgs.wasmtime ];
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else
              ''
                g++ -std=c++23 -O2 ${cppSrc} -lwasmtime -o test_bin
                ./test_bin
              '';
        };
    };

    # ── C++ Library Mode (Native Host)
    cpp-library = {
      name = "cpp-library";
      extraTestDrvs = [ smokeTestDrv ];
      mkTestDrv =
        { testId, test }:
        let
          fnName = testId;
          t = tryTranslate lib.toCpp test;

          tryLibSpec =
            if t.success then
              builtins.tryEval (
                lib.mkCppLibrary {
                  value = {
                    "testFunction" = test.func;
                  };
                  namespace = "testLib";
                  # compileBatchSize = 50;
                  # chunkSize = 12;
                }
              )
            else
              { success = false; };

          rawLib =
            if tryLibSpec.success then
              builtins.tryEval (tryLibSpec.value.mkDerivation pkgs)
            else
              { success = false; };

          generatedLib = if rawLib.success then rawLib.value else null;

          runnerSrc =
            if !t.success || generatedLib == null then
              null
            else
              pkgs.writeText "runner-${testId}.cpp" ''
                #include <testLib.hpp>
                #include <iostream>
                #include <exception>

                int main() {
                  try {
                    auto params = ${t.params};
                    auto expected = ${t.expected};
                    auto result = (testLib::testFunction)(params);
                    if (!(result == expected)) {
                      std::cerr << "  Expected: " << expected.toJSON()
                                << "\n  Got:      " << result.toJSON() << std::endl;
                      return 1;
                    }
                    std::cout << "PASS: " << ${builtins.toJSON test.description} << std::endl;
                    return 0;
                  } catch(const std::exception& e) {
                    std::cerr << "  Exception: " << e.what() << std::endl;
                    return 1;
                  } catch(...) {
                    std::cerr << "  Unknown exception" << std::endl;
                    return 1;
                  }
                }
              '';
        in
        mkIsolatedTestDrv {
          backendName = "cpp-library";
          inherit testId test;
          nativeBuildInputs = [ pkgs.gcc ];
          buildInputs = lib.optional (generatedLib != null) generatedLib;
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else if generatedLib == null then
              ''
                echo "  Reason: mkCppLibrary generation failed" >&2
                exit 1
              ''
            else
              ''
                g++ -std=c++23 -O2 ${runnerSrc} -lwasmtime -o test_bin
                ./test_bin
              '';
        };
    };

    # ── C++ Library Mode for ARMv7 (postmarketOS Galaxy S4 Mini) via QEMU
    cpp-library-armv7l = {
      name = "cpp-library-armv7l";
      extraTestDrvs = [ smokeTestArmv7Drv ];
      mkTestDrv =
        { testId, test }:
        let
          fnName = testId;
          t = tryTranslate lib.toCpp test;

          tryLibSpec =
            if t.success then
              builtins.tryEval (
                lib.mkCppLibrary {
                  value = {
                    "testFunction" = test.func;
                  };
                  namespace = "testLib";
                }
              )
            else
              { success = false; };

          # Cross-compile the library for armv7l
          rawLib =
            if tryLibSpec.success then
              builtins.tryEval (tryLibSpec.value.mkDerivation armPkgs)
            else
              { success = false; };

          generatedLib = if rawLib.success then rawLib.value else null;

          runnerSrc =
            if !t.success || generatedLib == null then
              null
            else
              pkgs.writeText "runner-armv7l-${testId}.cpp" ''
                #include <testLib.hpp>
                #include <iostream>
                #include <exception>

                int main() {
                  try {
                    auto params = ${t.params};
                    auto expected = ${t.expected};
                    auto result = (testLib::testFunction)(params);
                    if (!(result == expected)) {
                      std::cerr << "  Expected: " << expected.toJSON()
                                << "\n  Got:      " << result.toJSON() << std::endl;
                      return 1;
                    }
                    std::cout << "PASS: [armv7l] " << ${builtins.toJSON test.description} << std::endl;
                    return 0;
                  } catch(const std::exception& e) {
                    std::cerr << "  Exception: " << e.what() << std::endl;
                    return 1;
                  } catch(...) {
                    std::cerr << "  Unknown exception" << std::endl;
                    return 1;
                  }
                }
              '';
        in
        mkIsolatedTestDrv {
          backendName = "cpp-library-armv7l";
          inherit testId test;
          nativeBuildInputs = [
            armPkgs.stdenv.cc
            qemuArm
          ];
          buildInputs = lib.optional (generatedLib != null) generatedLib;
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else if generatedLib == null then
              ''
                echo "  Reason: mkCppLibrary generation failed" >&2
                exit 1
              ''
            else
              ''
                # 1. Cross-compile runner on x86_64 host targeting ARMv7
                ${armPkgs.stdenv.cc.targetPrefix}g++ -std=c++23 -O2 ${runnerSrc} \
                  -I${generatedLib}/include \
                  -L${generatedLib}/lib \
                  -ltestLib \
                  -o test_bin

                # 2. Run with ARM dynamic linker and standard C++ library paths
                export QEMU_LD_PREFIX="${armPkgs.stdenv.cc.libc}"
                export QEMU_SET_ENV="LD_LIBRARY_PATH=${armPkgs.stdenv.cc.cc.lib}/armv7l-unknown-linux-gnueabihf/lib:${generatedLib}/lib"

                qemu-arm ./test_bin
              '';
        };
    };

    # ── Rust Backend
    rust = {
      name = "rust";
      mkTestDrv =
        { testId, test }:
        let
          t = tryTranslate lib.toRust test;
          testFile =
            if !t.success then
              null
            else
              pkgs.writeText "test-${testId}.rs" ''
                #![allow(dead_code, unused_variables, unused_mut, unused_parens, non_snake_case)]

                mod value {
                  ${lib.rustRuntime}
                }
                use value::Value;

                fn main() {
                  let func = ${t.func};
                  let params = ${t.params};
                  let expected = ${t.expected};
                  let result = (func).call(params);
                  if !result.deep_eq(&expected) {
                    eprintln!("  Expected: {}\n  Got:      {}", expected.to_json(), result.to_json());
                    std::process::exit(1);
                  }
                  println!("PASS: {}", ${builtins.toJSON test.description});
                }
              '';
        in
        mkIsolatedTestDrv {
          backendName = "rust";
          inherit testId test;
          nativeBuildInputs = [ pkgs.rustc ];
          runScript =
            if !t.success then
              ''
                echo "  Reason: ${t.reason}" >&2
                exit 1
              ''
            else
              ''
                rustc --edition 2021 -O ${testFile} -o test_bin && ./test_bin
              '';
        };
    };
  };

  # ── Construct Backend Aggregator Derivations ────────────────
  mkBackendDrv =
    name: backend:
    let
      backendTests = builtins.filter (
        t:
        !(builtins.elem name (t.skipBackends or [ ]))
        && (!(t ? onlyBackends) || builtins.elem name t.onlyBackends)
      ) allTests;
      testDrvs =
        builtins.map (
          test:
          backend.mkTestDrv {
            testId = mkTestId test;
            inherit test;
          }
        ) backendTests
        ++ (backend.extraTestDrvs or [ ]);
    in
    mkAggregator {
      inherit name testDrvs;
    };
in
lib.mapAttrs mkBackendDrv testBackends
