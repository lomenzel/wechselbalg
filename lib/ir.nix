# Wechselbalg IR — Intermediate Representation
#
# Every Nix value is lowered to this IR before any backend touches it.
# Backends only need to pattern-match on { _t = "..."; ... } nodes.
#
# Constructors are plain functions returning attrsets.
# No dependencies — this file is entirely self-contained.

rec {
  # ── Literals ──────────────────────────────────────────────────────
  int = value: { _t = "int"; inherit value; };
  float = value: { _t = "float"; inherit value; };
  string = value: { _t = "string"; inherit value; };
  bool = value: { _t = "bool"; inherit value; };
  null_ = { _t = "null"; };

  # ── Collections ───────────────────────────────────────────────────
  list = elements: { _t = "list"; inherit elements; };
  attrs = entries: { _t = "attrs"; inherit entries; };

  # ── Functions ─────────────────────────────────────────────────────

  # Reference to a hoisted function definition.
  # All lambdas are given a unique name and hoisted into `definitions`.
  # Call sites get a ref, not the body.
  ref = name: { _t = "ref"; inherit name; };

  # Function application
  apply = fn: arg: { _t = "apply"; inherit fn arg; };

  # ── Variables ─────────────────────────────────────────────────────
  # A reference to a locally-bound variable (lambda param, let binding)
  var = name: { _t = "var"; inherit name; };

  # ── Control flow ──────────────────────────────────────────────────
  if_ = cond: then_: else_: { _t = "if"; inherit cond then_ else_; };

  # ── Operators ─────────────────────────────────────────────────────
  add = a: b: { _t = "add"; inherit a b; };

  eq = a: b: { _t = "eq"; inherit a b; };
  neq = a: b: not_ (eq a b);
  lessThan = a: b: { _t = "lessThan"; inherit a b; };

  # Composed — lowered to if_ at IR construction time.
  # Backends only need to implement renderIf.
  not_ = value: if_ value (bool false) (bool true);
  and_ = a: b: if_ a b (bool false);
  or_ = a: b: if_ a (bool true) b;
  implies = a: b: if_ a b (bool true);

  # Composed — Nix `+` is overloaded (string concat + numeric add).
  # Lowered to chained `add` at IR construction time.
  concatStrings = parts:
    if parts == [] then string ""
    else builtins.foldl' (acc: p: add acc p) (builtins.head parts) (builtins.tail parts);

  # Attrset update (//)
  update = base: ext: { _t = "update"; inherit base ext; };

  # List concatenation (++)
  concatLists = a: b: { _t = "concatLists"; inherit a b; };

  # Attribute selection (expr.path or expr.path or default)
  select = expr: path: { _t = "select"; inherit expr path; default = null; };
  selectOr = expr: path: default: { _t = "select"; inherit expr path default; };

  # ── Primops ───────────────────────────────────────────────────────
  # Abstract reference to a builtin operation.
  # Backends provide the implementation.
  primop = name: { _t = "primop"; inherit name; };

  # Composed — lowered to chained apply at IR construction time.
  # Backends only need to implement renderApply + primops.
  primopApp = name: args: builtins.foldl' (fn: arg: apply fn arg) (primop name) args;

  # ── Let bindings ──────────────────────────────────────────────────
  # Nix `let` introduces a (potentially recursive) scope.
  # In strict target languages, each binding is thunked so that
  # mutual / self-references resolve lazily.
  # bindings: { name = ir-node; ... }, body: ir-node
  # localDefs: { name = funcDef; ... } — hoisted lambdas scoped to this let
  let_ = bindings: body: localDefs: { _t = "let"; inherit bindings body localDefs; };

  # ── Lazy attrsets ─────────────────────────────────────────────────
  # An attrset whose entries are evaluated lazily (on first access).
  # Needed for attrsets inside lambda bodies so that the fixed-point
  # pattern (`lib.fix`) and similar recursive constructions work.
  # entries: { name = ir-node; ... }
  lazyAttrs = entries: { _t = "lazy-attrs"; inherit entries; };

  # ── Function definitions (used in the top-level `definitions` map) ──
  # Not an IR node per se — this is the shape of entries in `definitions`.
  # params: { identifier; formals; ellipsis; }
  # localDefs: { name = funcDef; ... } — nested lambdas scoped to this function
  funcDef = params: body: localDefs: { inherit params body localDefs; };
}
