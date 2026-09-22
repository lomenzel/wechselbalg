# tests/tostring-primop.test.nix
lib: [
  {
    description = "simple let binding";
    func =
      params:
      let
        x = params.a + 1;
      in
      x * 2;
    params = {
      a = 5;
    };
    expected.toBe = 12;
  }

  {
    description = "reserved JS identifier 'arguments' as lambda parameter";
    func = arguments: ((y: arguments.a + y) 7);
    params = {
      a = 5;
    };
    expected.toBe = 12;
  }

  {
    description = "circular translation :)";
    func =
      let
        parsec = import (
          builtins.fetchurl "https://raw.githubusercontent.com/kanwren/nix-parsec/refs/heads/master/parsec.nix"
        );
        lexer = import (
          builtins.fetchurl "https://raw.githubusercontent.com/kanwren/nix-parsec/refs/heads/master/lexer.nix"
        );
        nix-nix = import /home/leonard/Projekte/Gestalt/nix-nix/src/default.nix {
          nix-parsec.lib = {
            parsec = parsec;
            lexer = lexer { inherit parsec; };
          };
        };
        evalString = nix-nix.evalString;
      in
      params: (evalString { inherit lib; } params); # .success # should fail, but in the logs, the error message and value should be visible
    params = "lib.toJS (x: x)";
    expected.toBe =
      let
        parsec = import (
          builtins.fetchurl "https://raw.githubusercontent.com/kanwren/nix-parsec/refs/heads/master/parsec.nix"
        );
        lexer = import (
          builtins.fetchurl "https://raw.githubusercontent.com/kanwren/nix-parsec/refs/heads/master/lexer.nix"
        );
        nix-nix = import /home/leonard/Projekte/Gestalt/nix-nix/src/default.nix {
          nix-parsec.lib = {
            parsec = parsec;
            lexer = lexer { inherit parsec; };
          };
        };
        evalString = nix-nix.evalString;
      in
      (evalString { inherit lib; } "lib.toJS (x: x)");
  }
]
