{ lib, system, ... }:
let
  escapeNixString = s: builtins.replaceStrings [ "$" ] [ "\\$" ] (builtins.toJSON s);
  jsRuntimeLit = escapeNixString (builtins.readFile ../runtime/js/value.js);
  wasmJsLit = escapeNixString (lib.toJS lib.wasm);
in
(builtins.mapAttrs (name: _: "builtins.${name}") builtins)
// {
  # special case because i map ? to hasAttr which behaves slightly differently
  hasAttr = "(name: value: (builtins.isAttrs value) && (builtins.hasAttr name value))";
  wasm = ''
    (let
         pkgs = import (builtins.fetchTarball {
            url = "https://github.com/NixOS/nixpkgs/archive/b19802cc758117c58b74cbcceca015eb829708dd.tar.gz";
            sha256 = "sha256-n1a4VOBhR9sFitvkoQnqL8YURpDmwtseo4f5hduwuzY="; 
          }) { 
            # fallback to the system the expression was built on. for impure it uses the correct current system
            system = builtins.currentSystem or "${system}";
          };
          __wb_jsRuntime = ${jsRuntimeLit};
          __wb_wasmJs = ${wasmJsLit};
          __wasm =
            a: b:
            builtins.fromJSON (
              builtins.readFile (
                pkgs.runCommand "wasm-thing" { } '''
                  ''${pkgs.nodejs}/bin/node ''${pkgs.writeText "index.js" '''
                    ''${__wb_jsRuntime}
                    const res = ''${__wb_wasmJs}.call(Value.fromJSON_(''${builtins.toJSON (builtins.toJSON a)})).call(Value.fromJSON_(''${builtins.toJSON (builtins.toJSON b)}))
                    const fs = require('fs');
                    fs.writeFileSync(process.env.out, res.toJSON_().asString());
                  '''}
                '''
              )
            );
        in
        args: input: __wasm args input)'';
}
