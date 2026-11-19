{
  description = "Wechselbalg — translate Nix values to JavaScript, TypeScript, C++, Nix, and more";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    nixFork.url = "github:lomenzel/nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixFork,
      treefmt-nix,
      ...
    }:
    let
      supportedSystems = nixpkgs.lib.systems.flakeExposed;
      eachSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            };
          }
        );
      treefmtEval = eachSystem ({ pkgs, ... }: treefmt-nix.lib.evalModule pkgs ./treefmt.nix);
    in
    {
      #lib = import ./lib;

      overlays.default =
        final: prev:

        let

          inherit (final) runCommand nodejs writeText;

          wasm =
            let
              __wasm =
                a: b:
                builtins.fromJSON (
                  builtins.readFile (
                    runCommand "wasm-thing" { } ''
                      ${nodejs}/bin/node ${writeText "index.js" ''
                        ${final.lib.jsRuntime}
                        const res = ${final.lib.toJS wasm}.call(${final.lib.toJS a}).call(${final.lib.toJS b})
                        const fs = require('fs');
                        fs.writeFileSync(process.env.out, res.toJSON_().asString());
                      ''}
                    ''
                  )
                );
            in
            args: input: __wasm args input;

          importedLib = import ./lib {
            system = final.hostPlatform.system;
            inherit (final) lib;
            inherit wasm;
          };
        in
        {
          lib = prev.lib.extend (
            lfinal: lprev: {
              inherit (importedLib)
                toJS
                toTS
                toCpp
                toPython
                toKotlin
                toNix
                toRust
                mkCppLibrary
                cppRuntime
                jsRuntime
                tsRuntime
                pythonRuntime
                kotlinRuntime
                rustRuntime
                wasm
                ;
            }
          );
        };

      packages = eachSystem (
        {
          pkgs,
          system,
          ...
        }:
        {
          example =
            (pkgs.lib.toCpp
              (
                let
                  incBy = i: x: x + i;
                  inc = incBy 1;
                  dec = incBy (-1);
                in
                {
                  inherit dec inc;
                }
              )
              {
                library = {
                  namespace = "wechselbalgexample";
                };
              }
            ).mkDerivation
              pkgs;
        }
      );

      checks = eachSystem (
        {
          pkgs,
          system,
          ...
        }:
        let
          testsByBackend = import ./tests {
            inherit pkgs;
            plainLib =
              (import nixpkgs {
                inherit system;
              }).lib;
          };
        in
        {
          inherit (testsByBackend)
            javascript
            cpp-library
            nix
            cpp-library-armv7l
            ; # other backends currently have no priority
        }
        // {
          capture-reproducibility = import ./tests/capture-reproducibility.nix { inherit pkgs; };
          cpp-compile-batches = import ./tests/compile-batches.nix { inherit pkgs; };
          formatting = treefmtEval.${system}.config.build.check self;
        }
      );

      devShells = eachSystem (
        {
          pkgs,
          system,
          ...
        }:
        {
          default = pkgs.mkShell {
            buildInputs = [
              (pkgs.writeShellScriptBin "nix" ''
                ${nixFork.packages.${system}.nix}/bin/nix --extra-experimental-features ast-introspection "$@"
              '')
              pkgs.llvmPackages_22.clang-tools
              pkgs.gdb
            ];
          };
        }
      );
      formatter = eachSystem ({ system, ... }: treefmtEval.${system}.config.build.wrapper);
    };
}
