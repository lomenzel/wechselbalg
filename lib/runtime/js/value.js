// Wechselbalg JS Value type.
//
// This file provides the Value class used by toJS-generated code.
// Include it in your project before using any wechselbalg output.
//
// API mirrors the C++ Value type for consistency across backends.

class Value {
  constructor(type, value) {
    this.type = type;
    this.value = value;
  }

  // ── Construction ──────────────────────────────────────────────

  static null_() {
    return new Value("null", null);
  }
  static fromBool(v) {
    return new Value("bool", v);
  }
  static fromInt(v) {
    return new Value("int", typeof v === "bigint" ? v : BigInt(v));
  }
  static fromFloat(v) {
    return new Value("float", v);
  }
  static fromString(v) {
    return new Value("string", v);
  }
  static fromList(v) {
    return new Value("list", v);
  }
  static fromSet(v) {
    return new Value("set", v);
  }
  static lambda(v) {
    return new Value("lambda", v);
  }
  static lambdaWithFormals(v, formals) {
    const val = new Value("lambda", v);
    val._formals = formals;
    return val;
  }

  // Lazy thunk — transparent Proxy that forces on first access and caches.
  // Allows recursive let-bindings and fixed-point patterns (lib.fix).
  static thunk(fn) {
    const UNFORCED = Symbol("unforced");
    const FORCING = Symbol("forcing");
    let _cached = UNFORCED;
    const _force = () => {
      if (_cached === FORCING) {
        console.log("looping thunk:", fn.toString());
        throw new Error("wechselbalg: infinite recursion in thunk");
      }
      if (_cached !== UNFORCED) return _cached;
      _cached = FORCING;
      try {
        _cached = fn();
      } catch (err) {
        _cached = UNFORCED; // <-- RESET STATE SO IT DOESN'T LOOK LIKE A LOOP!
        throw err; // <-- RE-THROW THE REAL ERROR
      }
      if (!(_cached instanceof Value))
        console.log(
          "TRACE FORCE-NON-VALUE:",
          require("util").inspect(_cached, { depth: 1 }),
          "\n",
          new Error().stack.split("\n").slice(2, 10).join("\n"),
        );
      return _cached;
    };
    return new Proxy(new Value("thunk", null), {
      get(_target, prop) {
        if (prop === "__wb_force") return _force;
        if (prop === "__wb_isThunk") return true;
        const real = _force();
        const val = real[prop];
        return typeof val === "function" ? val.bind(real) : val;
      },
    });
  }

  // Lazy attrset — entries are thunks evaluated on first access and cached.
  // Required for attrsets inside lambda bodies so that fixed-point and
  // rec patterns don't force values prematurely.
  static lazySet(factories) {
    const cache = Object.create(null);
    const obj = new Proxy(Object.create(null), {
      get(_target, prop) {
        if (!Object.prototype.hasOwnProperty.call(factories, prop))
          return undefined;
        if (!(prop in cache)) cache[prop] = factories[prop]();
        return cache[prop];
      },
      has(_target, prop) {
        return Object.prototype.hasOwnProperty.call(factories, prop);
      },
      ownKeys(_target) {
        return Reflect.ownKeys(factories);
      },
      getOwnPropertyDescriptor(_target, prop) {
        if (Object.prototype.hasOwnProperty.call(factories, prop))
          // <-- CHANGED
          return {
            configurable: true,
            enumerable: true,
            writable: false,
            value: undefined,
          };
        return undefined;
      },
    });
    return Value.fromSet(obj);
  }

  // ── Type checks ───────────────────────────────────────────────

  functionArgs() {
    if (this.type === "set") return Value.fromSet({});
    if (this.type !== "lambda")
      throw new Error("wechselbalg: functionArgs requires a function");
    if (!this._formals) return Value.fromSet({});
    const r = {};
    for (const [k, v] of Object.entries(this._formals))
      r[k] = Value.fromBool(v);
    return Value.fromSet(r);
  }

  isNull() {
    return this.type === "null";
  }
  isInt() {
    return this.type === "int";
  }
  isFloat() {
    return this.type === "float";
  }
  isBool() {
    return this.type === "bool";
  }
  isString() {
    return this.type === "string";
  }
  isNumber() {
    return this.type === "int" || this.type === "float";
  }
  isList() {
    return this.type === "list";
  }
  isSet() {
    return this.type === "set";
  }
  isAttrs() {
    return this.type === "set";
  }
  isFunction() {
    return this.type === "lambda";
  }
  typeOf() {
    return this.type;
  }

  // ── Accessors ─────────────────────────────────────────────────

  asInt() {
    if (this.type === "int") return this.value;
    throw new Error("wechselbalg: expected int, got " + this.type);
  }

  asFloat() {
    if (this.type === "float") return this.value;
    if (this.type === "int") return Number(this.value);
    throw new Error("wechselbalg: expected float, got " + this.type);
  }

  asBool() {
    if (this.type === "bool") return this.value;
    throw new Error("wechselbalg: expected bool, got " + this.type);
  }

  asString() {
    if (this.type === "string") return this.value;
    throw new Error("wechselbalg: expected string, got " + this.type);
  }

  asList() {
    if (this.type === "list") return this.value;
    throw new Error("wechselbalg: expected list, got " + this.type);
  }

  asSet() {
    if (this.type === "set") return this.value;
    throw new Error("wechselbalg: expected set, got " + this.type);
  }

  asFunction() {
    if (this.type === "lambda") return this.value;
    throw new Error("wechselbalg: expected lambda, got " + this.type);
  }

  // ── AST introspection (builtins.reify / builtins.sameFunction) ─
  //
  // Mirrors the Nix fork: a function's identity is (code, environment).
  // `withMeta` records the stripped AST of a code template and the captured
  // environment of this particular instance; `primop` records a primop name,
  // because Nix compares primops by name rather than by identity.

  static withMeta(v, astJson, env) {
    v._wbAst = astJson;
    v._wbEnv = env === undefined ? null : env;
    return v;
  }

  static primop(name, v) {
    v._wbPrimop = name;
    return v;
  }

  static sameFunction(a, b) {
    const fa = Value._forceDeep(a);
    const fb = Value._forceDeep(b);
    if (!fa.isFunction() || !fb.isFunction())
      throw new Error("wechselbalg: sameFunction expects two functions");
    const pa = fa._wbPrimop,
      pb = fb._wbPrimop;
    if (pa !== undefined || pb !== undefined) return pa === pb;
    // Every lambda value is created once per (code, environment) pair, so
    // identity of the Value is identity of (fun, env) in Nix.
    return fa === fb;
  }

  static _forceDeep(v) {
    let r = v;
    while (r && r.__wb_isThunk) r = r.__wb_force();
    return r;
  }

  static reify(f) {
    const fn = Value._forceDeep(f);
    if (!fn.isFunction())
      throw new Error("wechselbalg: reify expects a function");

    // 1. Fully or partially applied primop:
    if (fn._wbPrimop !== undefined) {
      if (fn._wbAppliedArgs && fn._wbAppliedArgs.length > 0) {
        return Value.fromSet({
          _expr: Value.fromString("primopApp"),
          value: Value.fromSet({
            primop: Value.fromString(fn._wbPrimop),
            appliedArgs: Value.fromList(fn._wbAppliedArgs),
          }),
        });
      }
      return Value.fromSet({
        _expr: Value.fromString("primop"),
        value: Value.fromString(fn._wbPrimop),
      });
    }

    // 2. Standard user lambda with attached AST
    if (fn._wbAst === undefined)
      throw new Error(
        "wechselbalg: reify: this function carries no AST (not generated by wechselbalg)",
      );

    return Value._reifyNode(
      Value.fromJSON_(Value.fromString(fn._wbAst)),
      fn._wbEnv,
    );
  }
  // Re-attach `closureEnvValue` to the variables the template captured.
  // Re-attach `closureEnvValue` to captured variables,
  // and unpack `__pairs` back into canonical C++ Nix AST structures.
  static _reifyNode(node, env) {
    const n = Value._forceDeep(node);
    if (n.isList()) {
      return Value.fromList(n.asList().map((e) => Value._reifyNode(e, env)));
    }
    if (!n.isAttrs()) return n;

    const src = n.asSet();

    // 1. If this object is a `__pairs` list, unpack it back into an attribute set!
    if ("__pairs" in src) {
      const pairs = Value._forceDeep(src["__pairs"]).asList();
      const map = Object.create(null);
      for (const p of pairs) {
        const pairObj = Value._forceDeep(p).asSet();
        const k = pairObj["name"].asString();
        map[k] = Value._reifyNode(pairObj["value"], env);
      }
      return Value.fromSet(map);
    }

    // 2. Canonical AST restoration for `let`:
    // C++ Nix's builtins.reify wraps let bindings in:
    //   ast.value.attrs = { _expr: "attrSet", value: { attrs: { ... } } }
    // analyze.nix stripped this to `attrs: { __pairs: [...] }`.
    // Here we restore the canonical wrapper so `ast.value.attrs.value.attrs` resolves!
    if (
      src._expr &&
      src._expr.isString() &&
      src._expr.asString() === "let" &&
      src.value &&
      src.value.isAttrs()
    ) {
      const valSet = src.value.asSet();
      const unpackedBindings = Value._reifyNode(valSet.attrs, env);

      const canonicalAttrsNode = Value.fromSet({
        _expr: Value.fromString("attrSet"),
        value: Value.fromSet({
          attrs: unpackedBindings,
          dynamicAttrs: Value.fromList([]),
          recursive: Value.fromBool(false),
        }),
      });

      return Value.fromSet({
        _expr: Value.fromString("let"),
        value: Value.fromSet({
          attrs: canonicalAttrsNode,
          body: Value._reifyNode(valSet.body, env),
        }),
      });
    }

    // 3. Normal attribute set: reify children and re-attach free variable lookups
    const out = Object.create(null);
    for (const k of Object.keys(src)) {
      if (k === "__free") continue;
      out[k] = Value._reifyNode(src[k], env);
    }

    if ("__free" in src) {
      const name = src["name"].asString();
      out["closureEnvValue"] = Value.thunk(() => Value._envLookup(env, name));
    }

    return Value.fromSet(out);
  }

  // Environment keys are either a bare variable name or a narrowed path
  // ("lib.strings.toUpper").  Narrowed keys are un-flattened so the caller
  // still sees an attrset rooted at the variable.
  static _envLookup(env, name) {
    if (env === null || env === undefined)
      throw new Error(
        "wechselbalg: reify: '" + name + "' has no captured environment",
      );
    if (env.hasAttr(name)) return env.get(name);
    const prefix = name + ".";
    const keys = Object.keys(env.asSet()).filter((k) => k.startsWith(prefix));
    if (keys.length === 0)
      throw new Error(
        "wechselbalg: reify: captured variable '" + name + "' is unavailable",
      );
    const tree = {};
    for (const k of keys) {
      const parts = k.slice(prefix.length).split(".");
      let cur = tree;
      for (let i = 0; i < parts.length - 1; i++) {
        if (!(parts[i] in cur)) cur[parts[i]] = {};
        cur = cur[parts[i]];
      }
      cur[parts[parts.length - 1]] = k;
    }
    return Value._envNest(tree, env);
  }

  static _envNest(tree, env) {
    const factories = {};
    for (const k of Object.keys(tree)) {
      const v = tree[k];
      factories[k] =
        typeof v === "string" ? () => env.get(v) : () => Value._envNest(v, env);
    }
    return Value.lazySet(factories);
  }

  // ── Call ───────────────────────────────────────────────────────

  call(arg) {
    if (this.type === "set" && "__functor" in this.value)
      return this.value["__functor"].call(this).call(arg);
    if (this.type !== "lambda")
      throw new Error("wechselbalg: tried to call a " + this.type);

    const res = this.value(arg);

    // CRITICAL: Only tag freshly constructed closures, NEVER mutate pass-through arguments!
    // (e.g. seq(a, fn) returning fn must NOT mutate fn into a primop!)
    if (
      this._wbPrimop !== undefined &&
      res instanceof Value &&
      res.isFunction() &&
      res !== arg &&
      res._wbAst === undefined // Only tag if it doesn't already have its own AST!
    ) {
      res._wbPrimop = this._wbPrimop;
      res._wbAppliedArgs = [...(this._wbAppliedArgs || []), arg];
    }

    return res;
  }

  // ── Attribute access ──────────────────────────────────────────

  get(key) {
    if (this.type !== "set")
      throw new Error("wechselbalg: attribute access on " + this.type);
    const k = typeof key === "string" ? key : key.asString();
    if (!Object.prototype.hasOwnProperty.call(this.value, k)) {
      //console.error(">>> ATTRIBUTE NOT FOUND:", k, "AVAILABLE KEYS ARE:", Object.keys(this.value), "OBJECT:", this.value);
      throw new Error("wechselbalg: attribute '" + k + "' not found");
    }
    return this.value[k];
  }

  getOr(key, def) {
    if (this.type !== "set") return def;
    const k = typeof key === "string" ? key : key.asString();
    return k in this.value ? this.value[k] : def;
  }

  hasAttr(key) {
    if (!(this instanceof Value))
      console.log(
        "TRACE hasAttr on:",
        require("util").inspect(this, { depth: 3 }),
        new Error().stack.split("\n").slice(3, 12).join("\n"),
      );
    if (this.type !== "set") return false;
    const k = typeof key === "string" ? key : key.asString();
    return Object.prototype.hasOwnProperty.call(this.value, k);
  }

  // ── Comparison ────────────────────────────────────────────────

  eq(other) {
    return Value.fromBool(Value._deepEq(this, other));
  }

  static _deepEq(a, b) {
    if (a.type !== b.type) {
      if (a.isNumber() && b.isNumber()) return a.asFloat() === b.asFloat();
      return false;
    }
    switch (a.type) {
      case "null":
        return true;
      case "bool":
        return a.value === b.value;
      case "int":
        return a.value === b.value;
      case "float":
        return a.value === b.value;
      case "string":
        return a.value === b.value;
      case "list": {
        const al = a.value,
          bl = b.value;
        if (al.length !== bl.length) return false;
        for (let i = 0; i < al.length; i++)
          if (!Value._deepEq(al[i], bl[i])) return false;
        return true;
      }
      case "set": {
        const ak = Object.keys(a.value).sort();
        const bk = Object.keys(b.value).sort();
        if (ak.length !== bk.length) return false;
        for (let i = 0; i < ak.length; i++) {
          if (ak[i] !== bk[i]) return false;
          if (!Value._deepEq(a.value[ak[i]], b.value[bk[i]])) return false;
        }
        return true;
      }
      case "lambda":
        return false;
    }
    return false;
  }

  lessThan(other) {
    if (this.isInt() && other.isInt())
      return Value.fromBool(this.value < other.value);
    if (this.isNumber() && other.isNumber())
      return Value.fromBool(this.asFloat() < other.asFloat());
    if (this.isString() && other.isString())
      return Value.fromBool(this.value < other.value);
    throw new Error(
      "wechselbalg: cannot compare " + this.type + " < " + other.type,
    );
  }

  // ── Arithmetic ────────────────────────────────────────────────

  add(other) {
    if (this.isInt() && other.isInt())
      return Value.fromInt(this.value + other.value);
    if (this.isNumber() && other.isNumber())
      return Value.fromFloat(this.asFloat() + other.asFloat());
    if (this.isString() && other.isString())
      return Value.fromString(this.value + other.value);
    throw new Error(
      "wechselbalg: cannot add " + this.type + " and " + other.type,
    );
  }

  sub(other) {
    if (this.isInt() && other.isInt())
      return Value.fromInt(this.value - other.value);
    if (this.isNumber() && other.isNumber())
      return Value.fromFloat(this.asFloat() - other.asFloat());
    throw new Error(
      "wechselbalg: cannot subtract " + this.type + " and " + other.type,
    );
  }

  mul(other) {
    if (this.isInt() && other.isInt())
      return Value.fromInt(this.value * other.value);
    if (this.isNumber() && other.isNumber())
      return Value.fromFloat(this.asFloat() * other.asFloat());
    throw new Error(
      "wechselbalg: cannot multiply " + this.type + " and " + other.type,
    );
  }

  div(other) {
    if (this.isInt() && other.isInt()) {
      if (other.value === 0n) throw new Error("wechselbalg: division by zero");
      return Value.fromInt(this.value / other.value);
    }
    if (this.isNumber() && other.isNumber()) {
      if (other.asFloat() === 0)
        throw new Error("wechselbalg: division by zero");
      return Value.fromFloat(this.asFloat() / other.asFloat());
    }
    throw new Error(
      "wechselbalg: cannot divide " + this.type + " and " + other.type,
    );
  }

  negate() {
    return Value.fromBool(!this.asBool());
  }

  // ── Collection operations ─────────────────────────────────────
  update(other) {
    // 1. Flatten chained updates into a single flat array of layers:
    // (a // b) // c  becomes a single array [a, b, c] instead of nested Proxies!
    const aLayers = this._wbLayers || [this];
    const bLayers = other._wbLayers || [other];
    const layers = aLayers.concat(bLayers);

    // 2. A SINGLE non-recursive Proxy over all layers:
    const merged = new Proxy(Object.create(null), {
      get(_target, prop) {
        // Search layers from newest to oldest in a flat loop (Zero stack recursion!)
        for (let i = layers.length - 1; i >= 0; i--) {
          if (layers[i].hasAttr(prop)) return layers[i].get(prop);
        }
        return undefined;
      },
      has(_target, prop) {
        for (let i = layers.length - 1; i >= 0; i--) {
          if (layers[i].hasAttr(prop)) return true;
        }
        return false;
      },
      ownKeys(_target) {
        // Collect unique keys in a single pass without intermediate array copying
        const keys = new Set();
        for (let i = 0; i < layers.length; i++) {
          const s = layers[i].asSet();
          for (const k of Object.keys(s)) {
            keys.add(k);
          }
        }
        return Array.from(keys);
      },
      getOwnPropertyDescriptor(_target, prop) {
        for (let i = layers.length - 1; i >= 0; i--) {
          if (layers[i].hasAttr(prop)) {
            return {
              configurable: true,
              enumerable: true,
              writable: false,
              value: undefined,
            };
          }
        }
        return undefined;
      },
    });

    const res = Value.fromSet(merged);
    res._wbLayers = layers; // Tag so future `//` calls continue flattening!
    return res;
  }

  concat(other) {
    if (this.type !== "list" || other.type !== "list")
      throw new Error("wechselbalg: concat (++) requires two lists");
    return Value.fromList([...this.value, ...other.value]);
  }

  at(index) {
    const l = this.asList();
    const i = typeof index === "bigint" ? Number(index) : index;
    if (i < 0 || i >= l.length)
      throw new Error("wechselbalg: index out of bounds");
    return l[i];
  }

  head() {
    const l = this.asList();
    if (l.length === 0) throw new Error("wechselbalg: head of empty list");
    return l[0];
  }

  tail() {
    const l = this.asList();
    if (l.length === 0) throw new Error("wechselbalg: tail of empty list");
    return Value.fromList(l.slice(1));
  }

  length() {
    return Value.fromInt(BigInt(this.asList().length));
  }

  map(func) {
    return Value.fromList(this.asList().map((e) => func.call(e)));
  }

  filter(func) {
    return Value.fromList(this.asList().filter((e) => func.call(e).asBool()));
  }

  foldl(op, acc) {
    for (const e of this.asList()) acc = op.call(acc).call(e);
    return acc;
  }

  all(func) {
    return Value.fromBool(this.asList().every((e) => func.call(e).asBool()));
  }

  any(func) {
    return Value.fromBool(this.asList().some((e) => func.call(e).asBool()));
  }

  elem(item) {
    return Value.fromBool(this.asList().some((e) => Value._deepEq(e, item)));
  }

  concatMap(func) {
    const r = [];
    for (const e of this.asList()) r.push(...func.call(e).asList());
    return Value.fromList(r);
  }

  concatStringsSep(sep) {
    const s = typeof sep === "string" ? sep : sep.asString();
    return Value.fromString(
      this.asList()
        .map((e) => e.asString())
        .join(s),
    );
  }

  attrNames() {
    return Value.fromList(
      Object.keys(this.asSet())
        .sort()
        .map((k) => Value.fromString(k)),
    );
  }

  attrValues() {
    return Value.fromList(
      Object.keys(this.asSet())
        .sort()
        .map((k) => this.value[k]),
    );
  }

  removeAttrs(names) {
    const orig = this.asSet();
    const remove = new Set(names.asList().map((n) => n.asString()));
    const factories = {};
    for (const k of Object.keys(orig)) {
      if (!remove.has(k)) factories[k] = () => orig[k];
    }
    return Value.lazySet(factories);
  }

  listToAttrs() {
    const s = Object.create(null);
    for (const e of this.asList()) s[e.get("name").asString()] = e.get("value");
    return Value.fromSet(s);
  }

  mapAttrs(f) {
    const s = this.asSet();
    const factories = {};
    for (const k of Object.keys(s)) {
      const key = k;
      factories[key] = () => f.call(Value.fromString(key)).call(s[key]);
    }
    return Value.lazySet(factories);
  }

  intersectAttrs(other) {
    const a = this.asSet(),
      b = other.asSet(),
      r = {};
    for (const k of Object.keys(a)) if (k in b) r[k] = b[k];
    return Value.fromSet(r);
  }

  catAttrs(attr) {
    const a = typeof attr === "string" ? attr : attr.asString();
    return Value.fromList(
      this.asList()
        .filter((e) => e.hasAttr(a))
        .map((e) => e.get(a)),
    );
  }

  groupBy(f) {
    const groups = new Map();
    for (const e of this.asList()) {
      const k = f.call(e).asString();
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(e);
    }
    const r = Object.create(null);
    for (const [k, list] of groups.entries()) {
      r[k] = Value.fromList(list);
    }
    return Value.fromSet(r);
  }

  partition(pred) {
    const right = [],
      wrong = [];
    for (const e of this.asList()) {
      if (pred.call(e).asBool()) right.push(e);
      else wrong.push(e);
    }
    return Value.fromSet({
      right: Value.fromList(right),
      wrong: Value.fromList(wrong),
    });
  }

  sort(cmp) {
    const l = [...this.asList()];
    l.sort((a, b) =>
      cmp.call(a).call(b).asBool() ? -1 : cmp.call(b).call(a).asBool() ? 1 : 0,
    );
    return Value.fromList(l);
  }

  replaceStrings(from, to) {
    let s = this.asString();
    const fl = from.asList(),
      tl = to.asList();
    for (let i = 0; i < fl.length; i++) {
      s = s.split(fl[i].asString()).join(tl[i].asString());
    }
    return Value.fromString(s);
  }

  static genList(func, count) {
    const n = typeof count === "bigint" ? Number(count) : count;
    const r = [];
    for (let i = 0; i < n; i++) r.push(func.call(Value.fromInt(BigInt(i))));
    return Value.fromList(r);
  }

  ceil() {
    if (this.isInt()) return this;
    return Value.fromInt(BigInt(Math.ceil(this.asFloat())));
  }

  floor() {
    if (this.isInt()) return this;
    return Value.fromInt(BigInt(Math.floor(this.asFloat())));
  }

  toString_() {
    switch (this.type) {
      case "null":
        return Value.fromString("");
      case "bool":
        return Value.fromString(this.value ? "1" : "");
      case "int":
        return Value.fromString(this.value.toString());
      case "float":
        return Value.fromString(this.value.toString());
      case "string":
        return this;
      default:
        throw new Error(
          "wechselbalg: cannot convert " + this.type + " to string",
        );
    }
  }

  toJSON_() {
    switch (this.type) {
      case "null":
        return Value.fromString("null");
      case "bool":
        return Value.fromString(this.value ? "true" : "false");
      case "int":
        return Value.fromString(this.value.toString());
      case "float":
        return Value.fromString(JSON.stringify(this.value));
      case "string":
        return Value.fromString(JSON.stringify(this.value));
      case "list":
        return Value.fromString(
          "[" + this.value.map((e) => e.toJSON_().asString()).join(",") + "]",
        );
      case "set": {
        const pairs = Object.keys(this.value)
          .sort()
          .map(
            (k) => JSON.stringify(k) + ":" + this.value[k].toJSON_().asString(),
          );
        return Value.fromString("{" + pairs.join(",") + "}");
      }
      case "lambda":
        throw new Error("wechselbalg: cannot serialize lambda to JSON");
    }
  }

  static fromJSON_(s) {
    const str = typeof s === "string" ? s : s.asString();
    return Value._fromJSValue(JSON.parse(str));
  }

  static _fromJSValue(v) {
    if (v === null) return Value.null_();
    if (typeof v === "boolean") return Value.fromBool(v);
    if (typeof v === "number") {
      if (Number.isInteger(v)) return Value.fromInt(BigInt(v));
      return Value.fromFloat(v);
    }
    if (typeof v === "string") return Value.fromString(v);
    if (Array.isArray(v)) return Value.fromList(v.map(Value._fromJSValue));
    if (typeof v === "object") {
      const r = Object.create(null);
      for (const k of Object.keys(v)) r[k] = Value._fromJSValue(v[k]);
      return Value.fromSet(r);
    }
    throw new Error("wechselbalg: cannot convert JS value to Value");
  }
}
