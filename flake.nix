{
  description = "Wechselbalg — translate Nix values to JavaScript, C++, Nix, and more";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    treefmt.url = "github:numtide/treefmt-nix";
    nixFork.url = "git+file:///home/leonard/Projekte/nix";
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
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = f: nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          inherit system;
          pkgs = import nixpkgs {
            inherit system;
          };
        }
      );
    in
    {
      lib = import ./lib;

      overlays.default = final: prev: {
        wechselbalg = self.lib;
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
              nixFork.packages.${system}.nix
            ];
          };
        }
      );
    };
}
