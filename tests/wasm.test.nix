lib:
let
  pkgs = import <nixpkgs> { };

  # Compile WAT to base64 on evaluation
  wasmBytecode = builtins.readFile (
    pkgs.runCommand "make-wasm-b64" { nativeBuildInputs = [ pkgs.wabt ]; } ''
      wat2wasm ${pkgs.writeText "module.wat" ''
          (module
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 1024))
          (func (export "malloc") (param $size i32) (result i32)
            (local $ptr i32)
            (local.set $ptr (global.get $heap))
            (global.set $heap (i32.add (local.get $ptr) (local.get $size)))
            (local.get $ptr)
          )
          (data (i32.const 16) "{\"result\":\"wasm_ok\",\"num\":42}\00")
          (func (export "run") (param $inPtr i32) (result i32)
            (i32.const 16)
          )
        )
      ''} -o module.wasm
      base64 -w0 module.wasm > $out
    ''
  );
in
[
  {
    description = "wasm: basic execution returning JSON";
    func = params: lib.wasm params.args params.input;
    params = {
      args = {
        bytecode = wasmBytecode;
        fname = "run";
      };
      input = {
        hello = "world";
      };
    };
    expected.toBe = {
      num = 42;
      result = "wasm_ok";
    };
  }
]
