{
  description = "Wechselbalg — translate Nix values to JavaScript, C++, Nix, and more";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    treefmt.url = "github:numtide/treefmt-nix";
    nixFork.url = "github:lomenzel/nix";
  };
  outputs =
    {
      self,
      nixpkgs,
      treefmt,
      nixFork,
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
              overlays = [ self.overlay ];
            };
          }
        );
    in
    {
      lib = import ./lib;

      overlay =
        final: prev:

        {
          lib = prev.lib // self.lib;
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
                ulimit -s unlimited && ${
                  nixFork.packages.${system}.nix
                }/bin/nix --option max-call-depth 10000000 "$@"
              '')
            ];
          };
        }
      );
    };
}
