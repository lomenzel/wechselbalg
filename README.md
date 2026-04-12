# Wechselbalg

Wechselbalg translates Nix values (including functions and lambdas) into
portable code for multiple targets: JavaScript, C++, Python, and Nix.

The project performs a single-pass traversal over Nix values to produce an
intermediate representation (IR), which is then rendered by target-specific
backends. Wechselbalg attempts to preserve essential Nix semantics, so the
generated code behaves similarly to the original value whenever possible.

## Warning

This project is an early work in progress. The codebase began as an
AI-generated rewrite of parts from [gestalt](https://rad.menzel.lol/nodes/rad-node.menzel.lol/rad:zC4kuEr7XGt6qAcTt5JtJ7pCxZE8).
Although much has been modified since that initial generation, large parts
may still be rough, incomplete, or contain issues. Use at your own risk.

## Usage

Note: Wechselbalg depends on a fork of Nix that exposes the builtins
`reify` and `sameFunction`. See the fork at https://github.com/lomenzel/nix.

An overlay (`overlays.default`) adds helper functions to `lib`. The primary
translators are:

- `toNix` — serialize Nix values to Nix source code (no runtime required)
- `toCpp` — translate Nix values to C++ (requires C++ runtime)
- `toJS` — translate Nix values to JavaScript (requires JS runtime)
- `toPython` — translate Nix values to Python (requires Python runtime)

All non-Nix targets require a small runtime `Value` class (which handles
laziness and helper functions). Runtime snippets are available as:

- `lib.cppRuntime`
- `lib.jsRuntime`
- `lib.pythonRuntime`

Example (embedding the JavaScript runtime from Nix):

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

Python and C++ work similarly using `lib.pythonRuntime` and `lib.cppRuntime`.

Generating Nix is simpler and does not require a runtime:

```nix
# Serializing a function to a Nix string
builtins.trace (lib.toNix (x: x + 1)) "trace"
```

## Current status

Basic language features are supported (see the test cases in `./tests`), but
the implementation is incomplete: many primitive operations are
unimplemented, and support for Nix paths and derivations is not available
(and is not planned).

Performance is currently poor: code generation and generated code can be
slow. For example, the C++ translation of `lib.evalModules` may take hours
to compile and can require increasing the stack size to evaluate.

## Development

- direnv provides the nix fork
- Run tests and checks with Nix: `nix flake check`.
- See `./tests` for current coverage.

Contributions are welcome.

## License

This project is licensed under the GNU Affero General Public License version 3
(AGPL-3.0). See the [LICENSE](LICENSE) file for the full license text and
terms.
