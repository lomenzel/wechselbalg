# Closure Conversion & Syntactic Template Hoisting

Working plan. If an implementation attempt goes wrong, throw away the code and
restart from this document — it contains everything we learned during analysis.

Status legend: `[ ]` todo · `[~]` in progress · `[x]` done

---

## 0. Goal

Replace runtime closure-pointer deduplication (`builtins.sameFunction` +
bucket linear scans) with **syntactic template hoisting + closure conversion**.

Secondary goal (same design, enabled by it): make every backend **self-hosting**
by implementing `builtins.reify` and `builtins.sameFunction` as target-language
primops.

### Why the current design fails

`walker.nix` hoists every _runtime closure instance_ into a standalone top-level
definition and inlines captured variables into the body by calling `walkValue`
on `closureEnvValue`. Consequences:

1. Type constructors in nixpkgs (`submoduleWith`, `attrsWith`) instantiate
   closures with fresh `Env` pointers on every call → `sameFunction` is `false`
   → a new `__wb_func_N` per instance → 18 000+ copies of `prefix:` → OOM.
2. Capturing `lib` inlines all of nixpkgs `lib` into the function body.
3. `builtins.reify` can never be implemented in a target runtime, because the
   environment has been smeared into the code and is unrecoverable.

---

## 1. Architecture

Split "function" into two concepts:

**Code template** (syntactic, lives in `defs`)
: compiled once per unique _stripped AST_. Captured variables are read from an
environment parameter `__wb_env`. A template with no free variables takes no
env parameter.

**Closure value** (runtime, `ir.closure`)
: `{ template = <name>; env = { <key> = <irNode>; }; }`, built at the
instantiation site from `closureEnvValue`s.

### Representation decisions (and why)

| Decision                                                                                             | Rationale                                                                                                                                                                        |
| ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ir.closure` is a real IR node, **not** `ir.apply (ir.ref tpl) env`                                  | `renderApply` thunks its argument, so each application site wraps the env in a fresh thunk object. Runtime `sameFunction` (`tpl identity && env identity`) would then be wrong.  |
| `render.nix` supplies a **default lowering** `renderClosure = tpl: env: backend.renderApply tpl env` | Backends that do not care need zero changes. Backends that want runtime `reify`/`sameFunction` override it.                                                                      |
| Template with env is emitted as a curried two-level function `env -> params -> body`                 | `functionArgs` keeps working (the _inner_ lambda carries the formals metadata). No new function-object shape in the runtimes.                                                    |
| Every closure with free vars becomes a **named top-level binding** `__wb_clo_N`                      | Makes cycles expressible: push the name before walking the env, self-references resolve to `ir.ref __wb_clo_N`. All backends already forward-declare + thunk top-level bindings. |
| Free/bound marker is **replaced**, not deleted, when stripping                                       | See §2.2.                                                                                                                                                                        |
| `builtins.sameFunction` is **kept**, but only scanned against an O(depth) in-flight stack            | See §2.3.                                                                                                                                                                        |

---

## 2. The five things that break if done naively

These are the findings that must not be lost.

### 2.1 `evaluateAST` poisons shared templates — BLOCKER

`walkAST` constant-folds _before_ structural dispatch, and `eval.nix` resolves
`var` nodes through `closureEnvValue`. That bakes **one instance's** captured
values into the body.

```nix
f = x: (_: x);   # body is a bare `var x` → folded to the literal 1 for `f 1`
```

Reuse that template for `f 2` and you silently get the wrong answer. Editing
only the `ast._expr == "var"` branch is not enough — control never reaches it.

**Fix:** `eval.nix`'s `var` case must return `success = false`. Constant folding
of literal arithmetic/strings survives; folding through captured values does not.
Also affects the `let` case (`eval value.body`), which folds through the body's
free variables.

### 2.2 Stripping `closureEnvValue` destroys the free/bound distinction — BLOCKER

```nix
x: (y: x + y)   # inner: `x` bound by outer lambda → NO closureEnvValue
y: x + y        # `x` free                        → HAS closureEnvValue
```

Both strip to byte-identical ASTs → same hash → one template serves both, but
one wants `__wb_env.x` and the other a local. **Replace** `closureEnvValue` with
`__free = true`; never remove it.

The strip must be a _generic_ deep map over attrsets and lists — free vars also
live in `arguments.formals[*].defaultExpr`, `dynamicAttrs[*].{name,value}`,
`select.path[*]`, `select.default`.

### 2.3 Deleting `sameFunction` removes the only cycle breaker — BLOCKER

```nix
let f = x: ... f ... ; in f
```

`walkValue f` → env needs `f` → `walkValue f` → **infinite Nix recursion**.
The spec's "knot tying" gotcha only addresses codegen; the walker diverges first.

A `templateKey`-based cycle guard is **not** a valid substitute:

```nix
compose = f: g: (x: f (g x));
h = compose inc inc;   # template T
k = compose h h;       # template T again, env = { f = h; g = h; }, h is also T
```

A key-based guard ties the knot to `k` and emits `x: k (k x)` instead of
`x: h (h x)`. Silent wrong code. This pattern is real (`composeExtensions`,
`fixedPoints.extends`, `flip`).

**Fix:** keep `sameFunction`, but scan it only against the _current walk path_
(`seen.funcs`, an O(depth) list), never against a global table. That deletes the
O(n²) bucket scans, `findSameFunction` and `getBucketKey` — which is the actual
goal — without losing instance identity.

### 2.4 The captured-environment graph is cyclic; `defs`/IR is a tree — BLOCKER

`lib.foo` captures `lib`, and `lib` contains `lib.foo`. Even with instance
memoisation you must be able to emit a _reference_ to an in-progress node.

**Fix:** hoist both closures and cyclic attrsets into named top-level bindings.
`seenSets` grows from `{ fingerprint = true; }` to
`{ fingerprint = { binding = "__wb_cap_N"; }; }`, and a circular attrset becomes
a shared reference instead of today's `throw`.

Hardening: the attrset fingerprint is a heuristic (key names +
`name`/`_type`/`description`). Today a false positive is a loud `throw`; after
this change it is a silently wrong shared reference. On fingerprint match,
confirm with `sameFunction` on the first lambda-valued attribute the two sets
share (`lib`-shaped sets always have one).

### 2.5 Free-var collection and body compilation must not diverge — BLOCKER

`walkValue` returns a `ref`/`closure` and queues the body; the body is compiled
much later. So the env key set must be _predicted_ at instantiation time.

Divergence is silent in both directions: a missed var → `__wb_env.foo` is
`undefined` at runtime; an extra var → a value is forced that the body never
needed (OOM / spurious throw / re-entering a cycle).

**Fix:** one analysis function is the single source of truth.

```nix
analyze = ast: { strippedAst; key; envKeys; }
```

`known.templates.${key} = { name; envKeys; }`. `walkFunctionBody` receives
`envKeys` and threads it through `walkAST`. **If `walkAST` meets a
`closureEnvValue` var whose key is not in `envKeys`, it throws at compile time.**
That assertion converts the silent-divergence class into a loud failure.

---

## 3. Secondary issues (will bite, will not force a revert)

- **Nested lambdas cannot be globally template-keyed.** The `ast._expr == "lambda"`
  branch of `walkAST` produces defs that reference _enclosing lambda params_ —
  that is what `splitDefs`/`_hoistable` is for. Two identical inner ASTs in
  different scopes hash the same but must stay separate `localDefs`. Only
  `walkValue` lambdas are registered in `known.templates`.
- **`render.nix` collectors must learn `closure`.** `collectNode` and
  `collectStringsNode` fall through to `[ ]` on unknown node types. A primop
  reachable only from a closure env would then not be in `usedPrimops`, and the
  C++ backend only declares used primops → _undeclared identifier_ in generated
  C++, far from the cause.
- **`functionArgs` must survive the closure wrapper** (the module system depends
  on it — `tests/functionArgs.test.nix`, `tests/modules.test.nix`).
- **Formal defaults drop `defs`/`pending`/`known`** (pre-existing bug):
  `default = ... (walkAST f.defaultExpr bodyResult.known).ir`. Today a lambda in
  a default yields a dangling `ref`; after templating it yields a
  `__wb_tpl_N` that is never compiled. Fix in stage 0.
- **`ir.funcDef` arity change** touches `render.renderDef` and `renderFuncDef` in
  all six backends. Keep it additive (`params.envParam`).
- **Path narrowing** must be decided once, per root variable, all-or-nothing:

  > If root `v` ever appears bare, or under a dynamic path element, or under a
  > `select` with an `or` default → capture `v` whole. Otherwise capture each
  > static path as `__wb_env."v.a.b"`.

  No per-site judgement calls, so the two sides cannot drift.

- **Hashing cost.** `toJSON` on the stripped AST forces the whole subtree, once
  per closure instance. Bounded, but it is the new hot loop. Cache on the key.
- **`_expr == "pos"`** is reified with no `value` attribute, and `eval.nix` ends
  in a bare `throw` for unknown node types, called _without_ `tryEval`.
- **`purity.assertPure` throws outside any `tryEval`**; env capture reaches more
  values than before. Wrap env-value evaluation in `tryEval` and emit a per-key
  `throw` node on failure. Note `tryEval` catches neither `abort` nor infinite
  recursion.
- **C++ `__wb_env`** must be a `shared_ptr<Value>` like every other binding, or
  `[=]` capture in nested lambdas breaks.
- **Closure bindings are eagerly evaluated** at definition time in JS/C++, unlike
  today's function defs. Forward-declare + assign; do not rely on `const` order.

---

## 4. Invariants (encode as assertions)

| #   | Invariant                                                                                                        | Enforced by                      |
| --- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| I1  | `analyze` is deterministic: re-analysis yields identical `key` _and_ `envKeys`                                   | assertion on template reuse      |
| I2  | `walkAST` never emits an env access for a key outside `envKeys`                                                  | hard `throw` in `walkAST`        |
| I3  | `walkValue` on a lambda returns exactly `ir.ref <template>` or `ir.ref <closure binding>` — never an inline body | code shape                       |
| I4  | every `ref`/`var` resolves to `defs` ∪ bindings ∪ `localDefs` ∪ params ∪ enclosing `let`s                        | `lib/validate.nix`, run in tests |
| I5  | no two `defs` entries share a `templateKey`                                                                      | registry is keyed by it          |
| I6  | nested `walkAST` lambdas are never registered in `known.templates`                                               | code shape                       |

I4 and I2 pay for themselves. I4 alone catches the formals-default bug that is
in the tree today.

---

## 5. Stages

Each stage leaves the tree green and is independently revertible.

### Stage 0 — safety net `[x]`

1. `lib/validate.nix`: post-walk pass implementing I4. Wire into the test harness.
2. Fix dropped `defs`/`pending`/`known` in formal defaults (`walk.nix`, two sites).
3. Add the three acceptance tests (§6) as expected-failures.

_Gate:_ existing suite green; validator green on every existing test.

### Stage 1 — stop instance-specific folding `[x]`

`eval.nix` `var` case returns `success = false`. One line.

_Gate:_ suite green. Output grows; latent structural paths surface here, in
isolation.

### Stage 2 — `analyze`, observation only `[x]`

New `lib/analyze.nix` (strip → key → envKeys → narrowing). `walkValue` records
`known.templates` but still emits the old inlined defs. `trace` the ratio.

_Gate:_ unique-template count small and identical across two runs; `analyze`
idempotent.

### Stage 3 — identity & cycles `[x]`

Replace buckets with the in-flight `seen.funcs` stack. Promote `seenSets` to
carry binding names. Add the top-level binding table + forward declaration in
`renderProgram`.

_Gate:_ `let f = x: … f …`, mutual recursion, `compose h h`, `rec { a = …b…; b = …a…; }`,
self-referential attrset — all terminate and validate. `compose h h` must produce
`x: h (h x)`.

### Stage 4 — closure conversion `[x]`

`params.envParam`; `ir.closure` + default `renderClosure`; `walkAST` consults
`envKeys` with the I2 assertion; `render.nix` collectors learn `closure`.

_Gate:_ all three acceptance tests, all six backends, validator green.

### Stage 5 — cleanup `[x]`

Delete `getBucketKey`; rewrite the telemetry block. IR refcount pass that inlines
single-use `__wb_clo_N`. Optional: dedup closures by
`(templateKey, structural hash of env IR)`.

### Stage 6 — `reify` / `sameFunction` in every backend `[~]`

Runtime representation (JS shown; mirror in ts/py/kt/cpp):

```js
const __wb_tpl_3 = Value.template("__wb_tpl_3", __wb_ast_3, (env) =>
  Value.lambdaWithFormals(function (__p) { … }, { … })
);
```

- `Value.template` memoises on env identity and tags the produced lambda with
  `_wb_tpl` / `_wb_env`.
- `sameFunction(a,b)` → `a._wb_tpl === b._wb_tpl && a._wb_env === b._wb_env`.
  Faithful mirror of the fork's `fun == fun && env == env`: structurally-equal
  but distinct envs are `false` in both.
- `reify(f)` returns the template AST with `closureEnvValue = env[name]` attached
  lazily at every `__free` var — the inverse of `appendBindingExpr`.
- The AST ships as data through the existing JSON path:
  `ir.primopApp "fromJSON" [ (ir.string astJson) ]`. One shared constant per
  template.
- Primops must carry their own name so `reify` on a primop returns
  `{ _expr = "primop"; value = <name>; }`.
- Opt-in via `translate { features.reify = true; }` so ordinary bundles do not
  carry ASTs.
- The Nix backend gets both for free (`builtins.reify`, `builtins.sameFunction`).

**Known limitation:** nested lambdas stay real target-language closures, so
runtime `reify` cannot report _their_ captured locals. Full fidelity requires
closure-converting nested lambdas too (capture enclosing params into env) — a
separate, later decision.

_Gate:_ `toJS (f: builtins.sameFunction f f)`; `reify` on a closure yields the
free variable's value; `reify` on a primop yields its name.

_North star:_ `toJS` applied to the walker itself.

---

## 6. Acceptance tests

1. **Reproduction** — must terminate in < 50 ms, queue must not oscillate:
   ```nix
   let reproHelper = prop: license:
         if builtins.isList license then builtins.map (reproHelper prop) license
         else license;
   in walk (reproHelper "test")
   ```
2. **`pkgs.lib` integration** — compile
   `pkgs.lib.evalString { inherit (pkgs.lib) lists licenses evalString; }` to JS:
   no fuel limit, no OOM, < 500 templates.
3. **Closure correctness** — `[ 11 12 ]`:
   ```nix
   let makeAdder = x: (y: x + y); add1 = makeAdder 1; add2 = makeAdder 2;
   in [ (add1 10) (add2 10) ]
   ```
4. **Cycle suite** (stage 3): self-recursion, mutual recursion, `compose h h`,
   `rec` attrset self-reference.
5. **Self-hosting suite** (stage 6): `sameFunction` reflexive/negative cases,
   `reify` of closed template / closure / primop.

---

## 7. Running things

The fork with `ast-introspection` is required:

```sh
nix run github:lomenzel/nix -- eval \
  --extra-experimental-features ast-introspection \
  --impure --expr '…'
```

or from the dev shell (`nix develop`), where `nix` is already the wrapped fork
with `ulimit -s unlimited` and `--option max-call-depth 10000000`.

Test suite:

```sh
nix flake check          # all backends
nix build .#checks.x86_64-linux.javascript
```
