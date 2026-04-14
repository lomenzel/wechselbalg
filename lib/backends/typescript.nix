# TypeScript backend for Wechselbalg.
#
# TypeScript is a superset of JavaScript, so the generated code is identical.
# This backend reuses the JavaScript backend, overriding only the name,
# file extension, and primops (a handful need type annotations).
# The TypeScript runtime (lib/runtime/ts/value.ts) provides the same
# Value class with proper type annotations.

let
  jsBackend = import ./javascript.nix;
in
jsBackend
// {
  name = "typescript";
  extension = "ts";
  primops = import ../primops/typescript.nix;
}
