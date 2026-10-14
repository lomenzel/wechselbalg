# Wechselbalg — Top-level API
#
# Usage (from flake):
#   let wb = wechselbalg.lib; in
#   wb.toJS (x: x + 1)
#   wb.toCpp { a = 1; b = "hello"; }
#   wb.toRust (x: x + 1)
#   wb.translate { lang = "rust"; value = someFunc; }
#
# This file is the single entry-point. It wires together the walker,
# renderer, and backends.
pkgs:
let
  walk = import ./walk.nix;
  renderer = import ./render.nix;

  backends = rec {
    javascript = import ./backends/javascript.nix;
    typescript = import ./backends/typescript.nix;
    cpp = import ./backends/cpp.nix;
    python = import ./backends/python.nix;
    kotlin = import ./backends/kotlin.nix;
    nix = import ./backends/nix.nix {
      inherit (pkgs) lib;
      inherit pkgs;
    };
    rust = import ./backends/rust.nix;
    rs = rust; # convenience alias
  };

  # Core translate: walk the value, then render with the chosen backend.
  translate =
    {
      lang,
      value,
    }:
    let
      backend =
        if !builtins.hasAttr "reify" builtins then
          throw "wechselbalg: builtins.reify is required. Please use the Nix Fork from github:lomenzel/nix."
        else if builtins.hasAttr lang backends then
          backends.${lang}
        else
          throw "wechselbalg: unknown backend '${lang}'. Available: ${builtins.concatStringsSep ", " (builtins.attrNames backends)}";
      walkResult = walk value;
    in
    renderer.render backend walkResult;

  # ── C++ library build ──────────────────────────────────────────
  # Translate `value` to a set of C++ source files suitable for building
  # a static library.  See backends/cpp.nix `renderLibrary` for the
  # shape of `files`.
  #
  # Returns:
  #   {
  #     namespace;            # as requested
  #     name;                 # as requested
  #     files;                # attrset { relpath = contents; ... }
  #     mkDerivation = pkgs: <stdenv.mkDerivation>;
  #   }
  #
  # The derivation produces:
  #   $out/include/wechselbalg/value.hpp
  #   $out/include/<namespace>/<name>.hpp
  #   $out/lib/lib<namespace>_<name>.a
  mkCppLibrary =
    {
      value,
      namespace,
    }:
    let
      walkResult = walk value;
      files = renderer.renderLibrary value backends.cpp walkResult {
        inherit namespace value;
      };

      cppFiles = builtins.filter (
        p:
        let
          ext = builtins.substring ((builtins.stringLength p) - 4) 4 p;
        in
        ext == ".cpp"
      ) (builtins.attrNames files);

      libBase = "${namespace}";
    in
    {
      inherit namespace files;

      mkDerivation =
        pkgs:
        let
          # Materialise each generated file as its own store path.
          # We then `install -D` them into the build dir so we have real
          # (writable) files with the correct hierarchy.
          pathToDrv = pkgs.lib.mapAttrs (
            path: content:
            pkgs.writeText ("wb-src-" + builtins.replaceStrings [ "/" "." ] [ "_" "_" ] path) content
          ) files;

          installLines = builtins.concatStringsSep "\n" (
            pkgs.lib.mapAttrsToList (path: drv: ''
              mkdir -p "build/$(dirname ${path})"
              cp "${drv}" "build/${path}"
              chmod u+w "build/${path}"
            '') pathToDrv
          );

          objFiles = builtins.map (
            p:
            let
              noSlash = builtins.replaceStrings [ "/" ] [ "_" ] p;
              len = builtins.stringLength noSlash;
              # strip trailing ".cpp" (4 chars) and append ".o"
            in
            builtins.substring 0 (len - 4) noSlash + ".o"
          ) cppFiles;

          # Generate a build.ninja file for parallel compilation.
          ninjaFile = builtins.concatStringsSep "\n" (
            [
              "cxxflags = -std=c++23 -O2 -fPIC -Iinclude -Isrc"
              ""
              "rule cxx"
              "  command = g++ $cxxflags -c $in -o $out"
              "  description = Compiling $in"
              ""
              "rule ar"
              "  command = ar rcs $out $in"
              "  description = Archiving $out"
              ""
            ]
            ++ (pkgs.lib.zipListsWith (src: obj: "build ${obj}: cxx ${src}") cppFiles objFiles)
            ++ [
              ""
              "build lib${libBase}.a: ar ${builtins.concatStringsSep " " objFiles}"
              ""
              "default lib${libBase}.a"
            ]
          );
          ninjaFileDrv = pkgs.writeText "build.ninja" (ninjaFile + "\n");
        in
        pkgs.stdenv.mkDerivation {
          pname = "wb-cpp-${libBase}";
          version = "0.0.0";
          dontUnpack = true;
          dontStrip = true;
          dontPatchELF = true;
          nativeBuildInputs = [
            pkgs.gcc
            pkgs.ninja
          ];
          buildInputs = [
            pkgs.wasmtime
          ];
          propagatedBuildInputs = [
            pkgs.wasmtime
          ];
          setupHook = pkgs.writeText "wb-cpp-setup-hook.sh" ''
            export NIX_LDFLAGS="$NIX_LDFLAGS -l${libBase} -lwasmtime"
          '';
          buildPhase = ''
            runHook preBuild
            ${pkgs.writeShellScript "build.sh" ''
              (
              set -eu
              ${installLines}
              cp "${ninjaFileDrv}" build/build.ninja
              cd build
              export 
              NINJA_STATUS='[%f/%t %p %w %W] ' ninja -v
              )''}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/include" "$out/lib"
            cp -r build/include/. "$out/include/"
            cp "build/lib${libBase}.a" "$out/lib/"
            runHook postInstall
          '';
          passthru = {
            inherit files;
            source = pkgs.runCommand "source" { } ''
              mkdir -p "$out"
              ${
                # Symlink the generated files into the output for easy access.
                # This is not strictly necessary since the headers are installed
                # into $out/include, but it can be convenient for users to have
                # them directly available.
                builtins.concatStringsSep "\n" (
                  pkgs.lib.mapAttrsToList (path: drv: ''
                    ln -s "${drv}" "$out/$(basename ${path})"
                  '') pathToDrv
                )
              }
            '';
          };
        };
    };

  # Functor version of toCpp:
  #   lib.toCpp value               → attrset coercible to the code string
  #                                   (existing behaviour via __toString)
  #   lib.toCpp value { library = { namespace; name; }; }
  #                                 → C++ library spec (see mkCppLibrary)
  toCppFunctor = {
    __functor =
      _self: value:
      let
        code = renderer.render backends.cpp (walk value);
      in
      {
        __toString = _self: code;
        __functor =
          _self:
          {
            library ? null,
          }:
          if library == null then
            code
          else
            mkCppLibrary {
              inherit value;
              inherit (library) namespace;
            };
      };
  };

  # Convenience wrappers
  toJS =
    value:
    translate {
      lang = "javascript";
      inherit value;
    };
  toCpp = toCppFunctor;
  toPython =
    value:
    translate {
      lang = "python";
      inherit value;
    };
  toTS =
    value:
    translate {
      lang = "typescript";
      inherit value;
    };
  toKotlin =
    value:
    translate {
      lang = "kotlin";
      inherit value;
    };
  toNix =
    value:
    translate {
      lang = "nix";
      inherit value;
    };
  toRust =
    value:
    translate {
      lang = "rust";
      inherit value;
    };
  toRS = toRust;
  cppRuntime = builtins.readFile ./runtime/cpp/value.hpp;

  rustRuntime = builtins.readFile ./runtime/rust/value.rs;
  jsRuntime = builtins.readFile ./runtime/js/value.js;
  tsRuntime = builtins.readFile ./runtime/ts/value.ts;
  pythonRuntime = builtins.readFile ./runtime/python/value.py;
  kotlinRuntime = builtins.readFile ./runtime/kotlin/Value.kt;

  wasm =
    let
      __wasm =
        a: b:
        builtins.fromJSON (
          builtins.readFile (
            pkgs.runCommand "wasm-thing" { } ''
              ${pkgs.nodejs}/bin/node ${pkgs.writeText "index.js" ''
                ${jsRuntime}
                const res = ${toJS wasm}.call(${toJS a}).call(${toJS b})
                const fs = require('fs');
                fs.writeFileSync(process.env.out, res.toJSON_().asString());
              ''}
            ''
          )
        );
    in
    args: input: __wasm args input;

in
{
  inherit
    cppRuntime
    rustRuntime
    jsRuntime
    tsRuntime
    pythonRuntime
    kotlinRuntime

    translate
    toJS
    toTS
    toCpp
    toPython
    toKotlin
    toNix
    toRust
    toRS
    mkCppLibrary

    walk
    backends
    wasm
    ;

  ir = import ./ir.nix;
}
