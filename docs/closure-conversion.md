# Closure Conversion & Syntactic Template Hoisting

Design doc for how `walk.nix`/`analyze.nix` lower Nix values to IR. This was
the rationale behind the closure-conversion rewrite (commits "closure
rewrite"). The old design deduplicated functions by runtime closure identity
(`sameFunction` + global bucket scans), which exploded on nixpkgs-scale values
(fresh `Env` pointer per instantiation → thousands of template copies,
captured `lib` inlined everywhere). The rewrite replaced that with syntactic
template hoisting + closure conversion. The failure modes below are the
findings that are easy to regress; the acceptance tests live in
`tests/closures.test.nix` and `tests/self-hosting.test.nix`.

## The model

"Function" is split into two concepts:

**Code template** (syntactic, lives in `defs`)
: compiled once per unique _stripped AST_. Captured variables are read from an
environment parameter `__wb_cenv`. A template with no free variables takes no
env parameter.

**Closure value** (runtime, `ir.closure`)
: `{ template = <name>; env = { <key> = <irNode>; }; }`, built at the
instantiation site from `closureEnvValue`s.

Representation decisions:

- `ir.closure` is a real IR node, **not** `ir.apply (ir.ref tpl) env` —
  `renderApply` thunks its argument, so each application site would wrap the
  env in a fresh thunk and runtime `sameFunction` (tpl identity && env
  identity) would be wrong.
- `render.nix` supplies a default lowering
  `renderClosure = tpl: env: backend.renderApply tpl env`; backends that want
  runtime `reify`/`sameFunction` override it.
- A template with env is emitted as a curried two-level function
  `env -> params -> body`, so `functionArgs` keeps working (the _inner_ lambda
  carries the formals metadata).
- Every closure with free vars becomes a named top-level binding `__wb_clo_N`;
  the name is pushed before walking the env so self-references resolve to
  `ir.ref __wb_clo_N` (cycles expressible).

## The invariants

Referenced as I1/I5 in `lib/analyze.nix`, I2/I6 in `lib/walk.nix`, I4 in
`lib/validate.nix`.

| #   | Invariant                                                                                                        | Enforced by                              |
| --- | ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| I1  | `analyze` is deterministic: re-analysis yields identical `key` _and_ `envKeys`                                   | assertion on template reuse              |
| I2  | `walkAST` never emits an env access for a key outside `envKeys`                                                  | hard `throw` in `walkAST`                |
| I3  | `walkValue` on a lambda returns exactly `ir.ref <template>` or `ir.ref <closure binding>` — never an inline body | code shape                               |
| I4  | every `ref`/`var` resolves to `defs` ∪ bindings ∪ `localDefs` ∪ params ∪ enclosing `let`s                        | `lib/validate.nix`, run in tests         |
| I5  | no two `defs` entries share a `templateKey`                                                                      | registry (`known.templates`) keyed by it |
| I6  | nested `walkAST` lambdas are never registered in `known.templates`                                               | code shape (`splitDefs`/`_hoistable`)    |

## Non-obvious failure modes

1. **`eval.nix` must not fold through captured values.** `walkAST` constant-folds
   _before_ structural dispatch, and `eval.nix` could resolve `var` nodes
   through `closureEnvValue` — that bakes one instance's captured value into a
   shared template (`f = x: (_: x)` folded for `f 1` breaks `f 2`). The `var`
   case (and the folding `let` case, which folds through the body's free
   variables) must return `success = false`.

2. **Stripping must preserve the free/bound distinction.** `x: (y: x + y)` and
   `y: x + y` strip to byte-identical ASTs unless the free/bound marker is
   _replaced_ (`closureEnvValue` → `__free = true`), never deleted — otherwise
   one template serves both but one wants `__wb_cenv.x` and the other a local.
   The strip is a generic deep map: free vars also live in
   `arguments.formals[*].defaultExpr`, `dynamicAttrs[*].{name,value}`,
   `select.path[*]`, `select.default`.

3. **`sameFunction` stays, and instance memoisation stays.** A
   `templateKey`-based cycle guard is not a valid substitute for the
   `sameFunction` in-flight-stack scan (`seen.funcs`):

   ```nix
   compose = f: g: (x: f (g x));
   h = compose inc inc;   # template T
   k = compose h h;       # template T again, env = { f = h; g = h; }
   ```

   A key-based guard ties the knot to `k` and emits `x: k (k x)` instead of
   `x: h (h x)` — silent wrong code. Conversely, an ancestor-only scan alone
   (correct but without instance memoisation) walks a shared value **graph** as
   a **tree** — exponential in depth (`evalString` OOM-killed; measured on
   synthetic diamonds). Hence `known.instances`, memo buckets keyed by template
   key, capped at `instanceCap = 64` (over-cap still terminates via the
   in-flight check). Regression test: "a shared closure graph is walked once
   per node, not once per path" in `tests/closures.test.nix`.

4. **The captured-environment graph is cyclic; IR is a tree.** `lib.foo`
   captures `lib`, which contains `lib.foo`; circular attrsets are hoisted into
   named top-level bindings (`seenSets` carrying binding names) and referenced
   by `ir.ref`. The attrset fingerprint is a heuristic (key names +
   `name`/`_type`/`description`); a false positive is a _silently wrong shared
   reference_, so on fingerprint match the match is confirmed with
   `sameFunction` on the first shared lambda-valued attribute.

5. **Free-var collection and body compilation must not diverge.** `walkValue`
   returns a `ref`/`closure` and the body is compiled later, so the env key set
   is _predicted_ at instantiation time by `analyze.nix` (single source of
   truth for `key` + `capture`). A missed var → `__wb_cenv.foo` is `undefined`
   at runtime; an extra var → forces a value the body never needed (OOM /
   spurious throw / re-entering a cycle). `walkAST` throws at compile time on
   an env var outside `envKeys` (I2), converting silent divergence into a loud
   failure.

6. **Path narrowing is all-or-nothing per root variable:** if root `v` ever
   appears bare, under a dynamic path element, or under a `select` with an `or`
   default → capture `v` whole; otherwise capture each static path as
   `__wb_cenv."v.a.b"`. No per-site judgement, so the two sides cannot drift.

## Self-hosting (`reify` / `sameFunction` as target primops)

Runtime side (mirrored in all five runtimes): `Value.template` memoises on env
identity and tags the produced lambda with `_wb_tpl` / `_wb_env`;
`sameFunction(a,b)` is `a._wb_tpl === b._wb_tpl && a._wb_env === b._wb_env`
(faithful mirror of the fork's `fun == fun && env == env`); `reify(f)` returns
the template AST with `closureEnvValue = env[name]` re-attached lazily at every
`__free` var; the AST ships as data through the existing JSON path
(`ir.primopApp "fromJSON"`); primops carry their own name so `reify` on a
primop yields `{ _expr = "primop"; value = <name>; }`.

Known limitation: nested lambdas stay real target-language closures, so
runtime `reify` cannot report _their_ captured locals. Full fidelity requires
closure-converting nested lambdas too — not done.

North star: `toJS` applied to the walker itself (`tests/self-hosting.test.nix`
is the seed for that).
