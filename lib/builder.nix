# Batched Incremental Derivation Pipeline for Wechselbalg C++ (Cross-Compilation Ready)

{ pkgs }:
let
  cxxFlags = "-std=c++23 -O1 -fPIC -fno-var-tracking -fno-var-tracking-assignments";

  # Prefix for cross tools: e.g. "aarch64-unknown-linux-gnu-" or "" for native
  targetPrefix = pkgs.stdenv.cc.targetPrefix;

  # Build-time tools that MUST run on the building machine (buildPlatform)
  nativeBash = "${pkgs.buildPackages.bash}/bin/bash";
  nativeCoreutils = "${pkgs.buildPackages.coreutils}/bin";

  # ── 1. Runtime Precompiled Header (PCH) Derivation ───────────────
  mkRuntime =
    runtimeHppContent:
    let
      runtimeHppFile = pkgs.writeText "value.hpp" runtimeHppContent;
    in
    pkgs.stdenv.mkDerivation {
      pname = "wb-runtime";
      version = "0.0.1";
      dontUnpack = true;
      dontFixup = true;
      hardeningDisable = [ "all" ];
      buildInputs = [ pkgs.wasmtime ];

      buildPhase = ''
        mkdir -p include/wechselbalg
        cp "${runtimeHppFile}" include/wechselbalg/value.hpp

        # Include target wasmtime headers
        cp -r ${pkgs.wasmtime.dev}/include/. include/

        # Use $CXX instead of hardcoded g++ for cross-compilation
        $CXX ${cxxFlags} -Iinclude -x c++-header include/wechselbalg/value.hpp -o include/wechselbalg/value.hpp.gch
      '';

      installPhase = ''
        mkdir -p "$out/include"
        cp -r include/. "$out/include/"
      '';
    };

  # ── 2. Build the Complete Incremental Library ────────────────────
  buildLibrary =
    {
      rendered,
      compileBatchSize,
    }:
    let
      namespace = rendered.namespace;
      wbRuntime = mkRuntime rendered."include/wechselbalg/value.hpp";
      wbInclude = "${wbRuntime}/include";

      publicHeader = pkgs.writeText "${namespace}.hpp" rendered."include/${namespace}.hpp";
      publicHeaderDir = pkgs.writeTextDir "${namespace}.hpp" rendered."include/${namespace}.hpp";

      # Keep each translation unit small, but compile many in one derivation.
      sccMakefile = pkgs.writeText "wb-compile-scc.mk" ''
        SHELL := ${nativeBash}
        .RECIPEPREFIX := >
        objects := $(patsubst %.cpp,$(out)/%.o,$(wildcard *.cpp))
        .PHONY: all
        all: $(objects)

        $(out)/%.o: %.cpp
        >${targetPrefix}g++ ${cxxFlags} -Winvalid-pch -I"$(wbInclude)" -c "$<" -o "$@"
      '';

      sccBuilder = pkgs.writeShellScript "wb-compile-scc-batch.sh" ''
        set -eu
        export PATH="${nativeCoreutils}:${pkgs.stdenv.cc}/bin:${pkgs.buildPackages.gnumake}/bin"
        export NIX_HARDENING_ENABLE=""
        mkdir -p "$out"
        source "$sourcesPath"
        jobs="''${NIX_BUILD_CORES:-1}"
        if [ "$jobs" -eq 0 ]; then jobs=$(nproc); fi
        make -f ${sccMakefile} -j"$jobs"
      '';

      # a. Batch unchunked SCCs; chunks of large SCCs compile individually.
      # Sources pass together, without one writeText derivation per TU.
      batches = import ./compile-batches.nix {
        units = rendered.sccUnits;
        batchSize = compileBatchSize;
      };
      sccBatches = builtins.map (batch: {
        inherit (batch) units;
        drv = derivation {
          name = "wb-scc-batch-${batch.id}";
          # Builder runs on buildPlatform, producing code for hostPlatform.
          system = pkgs.stdenv.buildPlatform.system;
          builder = nativeBash;
          args = [
            "-e"
            sccBuilder
          ];
          sources = builtins.concatStringsSep "\n" (
            builtins.map (
              unit:
              "printf '%s' ${pkgs.lib.escapeShellArg unit.content} > ${pkgs.lib.escapeShellArg unit.fileName}"
            ) batch.units
          );
          passAsFile = [ "sources" ];
          inherit wbInclude;

          allowSubstitutes = false;
          preferLocalBuild = true;
        };
      }) batches;

      # Preserve the renderer's original archive member order.
      objectPaths = builtins.listToAttrs (
        builtins.concatMap (
          batch:
          builtins.map (unit: {
            name = unit.fileName;
            value = "${batch.drv}/${pkgs.lib.removeSuffix ".cpp" unit.fileName}.o";
          }) batch.units
        ) sccBatches
      );
      sccObjects = builtins.map (unit: objectPaths.${unit.fileName}) rendered.sccUnits;

      # b. Primops object file derivation
      primopsSrc = rendered."src/_primops.cpp";
      primopsObj =
        pkgs.runCommandCC "wb-primops.o"
          {
            hardeningDisable = [ "all" ];
            buildInputs = [ pkgs.wasmtime ];
            content = primopsSrc;
            passAsFile = [ "content" ];
            allowSubstitutes = false;
            preferLocalBuild = true;
          }
          ''
            ln -s "$contentPath" "_primops.cpp"
            $CXX ${cxxFlags} -Winvalid-pch -I"${wbInclude}" -c "_primops.cpp" -o "$out"
          '';

      # c. Root expression & exported attribute thunks object file
      rootObj =
        pkgs.runCommandCC "wb-root.o"
          {
            hardeningDisable = [ "all" ];
            buildInputs = [ pkgs.wasmtime ];
            content = rendered."src/_root.cpp";
            passAsFile = [ "content" ];
            allowSubstitutes = false;
            preferLocalBuild = true;
          }
          ''
            ln -s "$contentPath" "_root.cpp"
            $CXX ${cxxFlags} -Winvalid-pch -I"${wbInclude}" -I"${publicHeaderDir}" -c "_root.cpp" -o "$out"
          '';

      allObjects = [
        primopsObj
        rootObj
      ]
      ++ sccObjects;

      objectsFile = pkgs.writeText "objects.txt" (builtins.concatStringsSep "\n" allObjects);

      # d. Final Archive: links everything with target $AR
      libDerivation = pkgs.stdenv.mkDerivation {
        pname = "lib${namespace}";
        version = "0.0.1";
        dontUnpack = true;
        dontStrip = true;
        dontPatchELF = true;
        hardeningDisable = [ "all" ];
        buildInputs = [ pkgs.wasmtime ];
        propagatedBuildInputs = [ pkgs.wasmtime ];

        passthru = {
          inherit compileBatchSize;
          compileBatches = builtins.map (batch: batch.drv) sccBatches;
        };

        installPhase = ''
          mkdir -p "$out/lib" "$out/include/${namespace}" "$out/include/wechselbalg"

          # Use $AR instead of hardcoded ar
          $AR qcsT "$out/lib/lib${namespace}.a" @"${objectsFile}"

          # Install headers
          cp "${publicHeader}" "$out/include/${namespace}.hpp"
          cp "${wbInclude}/wechselbalg/value.hpp" "$out/include/wechselbalg/value.hpp"
        '';

        setupHook = pkgs.writeText "wb-setup-hook.sh" ''
          export NIX_LDFLAGS="$NIX_LDFLAGS -L$out/lib -l${namespace} -lwasmtime"
        '';
      };
    in
    libDerivation;

in
{
  inherit mkRuntime buildLibrary;
}
