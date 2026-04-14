{
  description = "Wechselbalg — translate Nix values to JavaScript, TypeScript, C++, Nix, and more";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    treefmt.url = "github:numtide/treefmt-nix";
    nixFork.url = "github:lomenzel/nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt,
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

      overlays.default =
        final: prev:

        {
          lib = prev.lib // {
            inherit (self.lib)
              toJS
              toTS
              toCpp
              toPython
              toNix
              cppRuntime
              jsRuntime
              tsRuntime
              pythonRuntime
              ;
          };
        };

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
            ];
          };
        }
      );
      formatter = eachSystem ({ system, ... }: treefmtEval.${system}.config.build.wrapper);

    };

}
