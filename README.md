# Wechselbalg

Wechselbalg translates Nix values (including lambdas) into
portable code for multiple targets: JavaScript, TypeScript, C++, Python, Kotlin, Rust and Nix.

The project performs a single-pass traversal over Nix values to produce an
intermediate representation (IR), which is then rendered by target-specific
backends. Wechselbalg attempts to preserve essential Nix semantics, so the
generated code behaves similarly to the original value whenever possible.

## Usage

Note: Wechselbalg depends on a fork of Nix that exposes the builtins
`reify` and `sameFunction`. See the fork at https://github.com/lomenzel/nix.
The fork only exposes them with the experimental feature `ast-introspection`
enabled, e.g.:

```sh
nix run github:lomenzel/nix -- --extra-experimental-features ast-introspection build .#my-cool-project-that-uses-wechselbalg
```

An overlay (`overlays.default`) adds helper functions to `lib`. The primary
translators are:

- `toNix`
- `toCpp`
- `toRust`
- `toJS`
- `toTS`
- `toPython`
- `toKotlin`

All non-Nix targets require a `Value` class (which handles
laziness and helper functions). Runtime snippets are available as:

- `lib.cppRuntime`
- `lib.jsRuntime`
- `lib.tsRuntime`
- `lib.pythonRuntime`
- `lib.kotlinRuntime`

Example:

```nix
pkgs.writeText "fun.js" ''
    ${lib.jsRuntime}

    let increment = ${lib.toJS (x: x + 1)};

    // Generated functions expect `Value` objects. Wrap plain values using
    // `Value.fromInt`, or pass wrapped values produced by `lib.toJS`.
    console.log(increment(${lib.toJS (2 + 4)}));         // using lib.toJS
    console.log(increment(Value.fromInt(6)));           // wrapping a literal

    // To extract plain JS values from a `Value`, use the asX accessors:
    console.log(${lib.toJS (1 == 2)}.asBool());
''
```

Other languages work similarly using `lib.pythonRuntime` and `lib.cppRuntime` etc..

### C++ library mode

For large values, the single-TU output of `lib.toCpp value` may be too
large for the C++ compiler to handle efficiently. To solve this there is `lib.mkCppLibrary`

```nix
let
  cppApp = lib.mkCppLibrary {
      namespace = "myapp"; # can be linked with -lmyapp
                           # produces a myapp.hpp
                           # all attrs of value are accessible through that namespace
      value = {
        name = "VeryGoodApp";
        version = "1.0.0";
        otherCode = largeValue;
      };
  };
  lib-drv = cppApp.mkDerivation pkgs;
in
pkgs.stdenv.mkDerivation {
  name = "my-consumer";
  nativeBuildInputs = [ lib-drv ];
  # …
  buildPhase = ''
    g++ -std=c++23 main.cpp -o main
  '';
}
```

The consumer includes the exported value like this:

```cpp
#include <myapp.hpp>
int main() {
  auto r = myapp::name.asString();
  auto s = myapp::otherCode(myapp::version);
  // ...
}
```

Large SCCs are split into C++ translation units of at most 15 definitions.
Each chunk of a split SCC gets its own compilation derivation and is never
batched with other chunks or unsplit SCCs.

Only unsplit SCCs are grouped into derivations of at most 10 units by default.
A binary hierarchy over hashes of their names splits oversized groups;
inserting or changing an unsplit SCC only invalidates its affected batches,
rather than shifting every subsequent group. Adding, removing, or changing
split-SCC chunks does not affect the batching of unsplit SCCs.
Each batch compiles its units independently and in parallel using `NIX_BUILD_CORES`.
The runtime precompiled header, primops, root expression, and final thin archive
remain separate derivations.

Set `compileBatchSize` in the arguments to `lib.mkCppLibrary` to trade cache
granularity for fewer derivations for unsplit SCCs. It must be a positive integer; `1` restores
one compilation derivation per translation unit. The same setting is accepted
inside `library` when using `lib.toCpp value { library = { ... }; }`.
The resulting derivation exposes `compileBatches` and `compileBatchSize` as
passthru attributes for inspecting the compilation graph. A change recompiles
all units in the affected batch, not just the changed unit.

The default is defined only by `mkCppLibrary`; the `toCpp` wrapper forwards
optional overrides, and the internal builder and batch planner require the
resolved size explicitly. The library specification also exposes `compileBatchSize`.

Cache stability also depends on closure captures: capturing the entire `builtins`
set includes volatile values such as `currentTime`. Compute capability checks
outside translated closures and capture their boolean results instead. Intentional
captures of `builtins.currentTime` still change the generated code.

Generating Nix is simpler and does not require a runtime:

```nix
# Serializing a function to a Nix string
string = lib.toNix (x: x + 1);
```

## Limitations

- Infinite attribute sets: i have not yet found a way to detect infinitly recursive attr sets. They are translated to a depth of 500. Any runtime access deeper than that will throw. Generating them at runtime should work tho.
- Performance: as allready mentioned compiling large values with gcc causes problems. but translation and runtime are not perfect by any means. running complex things with compiled code quickly creates stack overflows or needs a long time to finish.
- Paths: Paths are completely unsupported. they can be translated but accessing them at runtime throws
- Partial Primop implementation: Not every primop is implemented in every language. especially the ones operating on paths. Unknown primops translate to a runtime throw.
- translated tryEval catches every error. even stack overflows. this is intentional but a difference to the real nix
- if translating the lib.wasm function with the nix backend, it generates an expression with your host system hardcoded. use --impure when running the generated expression to use the system its running on instead of the system the expression was translated on

## Development

- direnv provides the nix fork
- Run tests and checks with Nix: `nix flake check`.
- See `./tests` for current coverage.

Contributions are welcome.

## License

This project is licensed under the GNU Affero General Public License version 3
(AGPL-3.0). See the [LICENSE](LICENSE) file for the full license text and
terms.
