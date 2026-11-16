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

  # Capture the capability result, not the entire evaluator namespace (which
  # also contains volatile currentTime), when the translator is itself compiled.
  hasReify = builtins.hasAttr "reify" builtins;

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
        if !hasReify then
          throw "wechselbalg: builtins.reify is required. Please use the Nix Fork from github:lomenzel/nix."
        else if builtins.hasAttr lang backends then
          backends.${lang}
        else
          throw "wechselbalg: unknown backend '${lang}'. Available: ${builtins.concatStringsSep ", " (builtins.attrNames backends)}";
      walkResult = walk value;
    in
    renderer.render backend walkResult;
  merkle = import ./merkle.nix;
  renderScc = import ./render-scc.nix { inherit pkgs; };
  mkCppLibrary =
    {
      value,
      namespace,
      compileBatchSize ? 10,
      chunkSize ? 15,
    }:
    let
      walkResult = walk value;
      merkleResult = merkle.process walkResult;
      rendered = renderScc.render {
        inherit
          merkleResult
          namespace
          value
          chunkSize
          ;
      };
    in
    {
      inherit namespace compileBatchSize chunkSize;
      inherit (rendered) sccUnits;

      # Function taking pkgs and returning the final derivation
      mkDerivation =
        pkgsArg:
        (import ./builder.nix { pkgs = pkgsArg; }).buildLibrary {
          inherit rendered compileBatchSize;
        };
    }; # Functor version of toCpp:
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
            mkCppLibrary (
              {
                inherit value;
                inherit (library) namespace;
              }
              // builtins.intersectAttrs {
                compileBatchSize = null;
                chunkSize = null;
              } library
            );
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

  inherit (pkgs) runCommand nodejs writeText;

  wasm =
    let
      __wasm =
        a: b:
        builtins.fromJSON (
          builtins.readFile (
            runCommand "wasm-thing" { } ''
              ${nodejs}/bin/node ${writeText "index.js" ''
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
