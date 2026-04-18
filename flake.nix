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
      lib = import ./lib;

      overlays.default = final: prev: {
        lib = prev.lib // {
          inherit (self.lib)
            toJS
            toTS
            toCpp
            toPython
            toNix
            mkCppLibrary
            cppRuntime
            jsRuntime
            tsRuntime
            pythonRuntime
            ;
        };
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
            wechselbalg = self.lib;
          };
        in
        testsByBackend
        // {
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
                ulimit -s unlimited && ${nixFork.packages.${system}.nix}/bin/nix --option max-call-depth 10000000 "$@"
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
