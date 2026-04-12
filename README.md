# Wechselbalg

Wechselbalg translates Nix values (including lambdas)
into portable code for multiple targets: JavaScript, C++, Python and Nix.

The library performs a single-pass walk over Nix values to produce an
intermediate representation (IR) and then renders that IR with backend
renderers. It tries to preserve important Nix semantics so the generated code
behaves like the original Nix value where possible.

## WARNING

This is a COMPLETELY AI GENERATED rewrite of parts from [Gestalt](https://git.menzel.lol/leonard/gestalt)
