# Wechselbalg — Top-level API
#
# Usage (from flake):
#   let wb = wechselbalg.lib; in
#   wb.toJS (x: x + 1)
#   wb.toCpp { a = 1; b = "hello"; }
#   wb.translate { lang = "javascript"; value = someFunc; }
#
# This file is the single entry-point. It wires together the walker,
# renderer, and backends.

let
  walk = import ./walk.nix;
  renderer = import ./render.nix;

  backends = {
    javascript = import ./backends/javascript.nix;
    cpp = import ./backends/cpp.nix;
    python = import ./backends/python.nix;
    nix = import ./backends/nix.nix;
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

  # Convenience wrappers
  toJS =
    value:
    translate {
      lang = "javascript";
      inherit value;
    };
  toCpp =
    value:
    translate {
      lang = "cpp";
      inherit value;
    };
  toPython =
    value:
    translate {
      lang = "python";
      inherit value;
    };
  toNix =
    value:
    translate {
      lang = "nix";
      inherit value;
    };

in
{
  inherit
    translate
    toJS
    toCpp
    toPython
    toNix
    ;

  # The C++ Value type header — users include this in their project.
  # Usage: builtins.toFile "wechselbalg.hpp" lib.cppRuntime
  cppRuntime = builtins.readFile ./runtime/cpp/value.hpp;

  # The JS Value class — users include this before using toJS output.
  # Usage: write to file, <script src="value.js"> before generated code.
  jsRuntime = builtins.readFile ./runtime/js/value.js;

  # The Python Value class — users import this before using toPython output.
  # Usage: write to file, exec(open("value.py").read()) before generated code.
  pythonRuntime = builtins.readFile ./runtime/python/value.py;

  # Escape hatches for advanced users
  inherit walk;
  inherit backends;
  ir = import ./ir.nix;
}
