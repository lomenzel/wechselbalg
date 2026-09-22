# AGENTS.md

Wechselbalg translates Nix values (incl. lambdas, via the fork's `builtins.reify`/`sameFunction`) into JS/TS/C++/Python/Kotlin/Nix. Pure-Nix codebase, no application code — everything is Nix expressions.

## Setup

- Requires the custom Nix fork (github:lomenzel/nix). The fork only exposes `builtins.reify`/`sameFunction` with the experimental feature `ast-introspection` enabled: pass `--extra-experimental-features ast-introspection` (or `NIX_CONFIG='extra-experimental-features = ast-introspection'`); plain system `nix` will fail (`builtins.reify` missing). direnv (`use flake`) provides the fork via the dev shell; the wrapped `nix` passes the flag for you.
- The flake overlay `overlays.default` injects `toJS/toTS/toCpp/toPython/toKotlin/toNix/mkCppLibrary/*Runtime` into `pkgs.lib`.

## Verify

- `nix flake check` runs all backend test suites + formatting.
- Focused check per backend (much faster than full check): `nix build .#checks/<system>.<backend>` with backend ∈ {`javascript`, `typescript`, `cpp`, `python`, `kotlin`, `nix`, `cpp-library`}.
- Tests are `tests/*.test.nix` lists of `{ description, func, params, expected.toBe }` attrsets; each backend translates `func`/`params`/expected and deep-compares at runtime. Add test cases there, not inline in the harness (`tests/default.nix`).
- Formatting via treefmt (nixfmt, prettier, clang-format, black); the `formatting` check enforces it — format with `nix fmt` before checking in.

## Architecture

- Pipeline: `lib/walk.nix` (value + reified AST → IR) → `lib/render.nix` (contracts backend with IR) → `lib/backends/*.nix` + `lib/primops/*.nix` emit per-language code; `lib/runtime/*` holds the per-language `Value` runtime classes (laziness/thunks) exposed as `lib.<lang>Runtime`.
- `lib/ir.nix` defines the IR node shapes (`_t = "int" | "lambda" | "closure" | "ref" | ...`); backends only pattern-match on `_t`.
- `lib/analyze.nix` is the single source of truth for template `key` and `capture` (invariants I1/I5). Its traversal MUST mirror `walkAST` in walk.nix exactly — any divergence breaks closure conversion.
- **Read `docs/closure-conversion.md` before touching walk.nix/analyze.nix/eval.nix.** It is the design doc for the closure-conversion model and lists the non-obvious failure modes (e.g. eval.nix must NOT constant-fold through captured `var` nodes).
- `toCpp` is a functor: bare call coerces to a code string; `toCpp value { library = { namespace; }; }` returns a library spec whose `mkDerivation pkgs` builds a static lib (one TU per hoisted function).
- Attribute names from user values must never become Nix attrset keys in AST-handling code (special-cased by `builtins.toJSON`); use the `__pairs` list pattern from analyze.nix.

## Notes

- `result*` symlinks into /nix/store are gitignored; don't commit them.
- Project origin: AI-generated rewrite of parts of `gestalt`; rough edges expected, mirror existing code style rather than "fixing" it casually.
