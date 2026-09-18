// Wechselbalg TS Value type.
//
// This file provides the Value class used by toTS-generated code.
// Include it in your project before using any wechselbalg output.
//
// API mirrors the JS/C++ Value types for consistency across backends.

type ValueType =
  | "null"
  | "bool"
  | "int"
  | "float"
  | "string"
  | "list"
  | "set"
  | "lambda"
  | "thunk";

type ValueSet = Record<string, Value>;

type LambdaFn = (arg: Value) => Value;

type Formals = Record<string, boolean>;

class Value {
  type: ValueType;
  value: unknown;
  _formals?: Formals;
  _wbAst?: string;
  _wbEnv?: Value | null;
  _wbPrimop?: string;

  constructor(type: ValueType, value: unknown) {
    this.type = type;
    this.value = value;
  }

  // ── Construction ──────────────────────────────────────────────

  static null_(): Value {
    return new Value("null", null);
  }
  static fromBool(v: boolean): Value {
    return new Value("bool", v);
  }
  static fromInt(v: bigint | number): Value {
    return new Value("int", typeof v === "bigint" ? v : BigInt(v));
  }
  static fromFloat(v: number): Value {
    return new Value("float", v);
  }
  static fromString(v: string): Value {
    return new Value("string", v);
  }
  static fromList(v: Value[]): Value {
    return new Value("list", v);
  }
  static fromSet(v: ValueSet): Value {
    return new Value("set", v);
  }
  static lambda(v: LambdaFn): Value {
    return new Value("lambda", v);
  }
  static lambdaWithFormals(v: LambdaFn, formals: Formals): Value {
    const val = new Value("lambda", v);
    val._formals = formals;
    return val;
  }

  // Lazy thunk — transparent Proxy that forces on first access and caches.
  // Allows recursive let-bindings and fixed-point patterns (lib.fix).
  static thunk(fn: () => Value): Value {
    const UNFORCED = Symbol("unforced");
    const FORCING = Symbol("forcing");
    let _cached: Value | symbol = UNFORCED;
    const _force = (): Value => {
      if (_cached === FORCING)
        throw new Error("wechselbalg: infinite recursion in thunk");
      if (_cached !== UNFORCED) return _cached as Value;
      _cached = FORCING;
      _cached = fn();
      return _cached as Value;
    };
    return new Proxy(new Value("thunk", null), {
      get(_target: Value, prop: string | symbol): unknown {
        if (prop === "__wb_force") return _force;
        if (prop === "__wb_isThunk") return true;
        const real = _force();
        const val = (real as any)[prop];
        return typeof val === "function" ? val.bind(real) : val;
      },
    });
  }

  // Lazy attrset — entries are thunks evaluated on first access and cached.
  // Required for attrsets inside lambda bodies so that fixed-point and
  // rec patterns don't force values prematurely.
  static lazySet(factories: Record<string, () => Value>): Value {
    const cache: Record<string, Value> = Object.create(null);
    const obj = new Proxy(Object.create(null), {
      get(_target: unknown, prop: string): Value | undefined {
        if (!(prop in factories)) return undefined;
        if (!(prop in cache)) cache[prop] = factories[prop]();
        return cache[prop];
      },
      has(_target: unknown, prop: string): boolean {
        return prop in factories;
      },
      ownKeys(_target: unknown): string[] {
        return Reflect.ownKeys(factories) as string[];
      },
      getOwnPropertyDescriptor(
        _target: unknown,
        prop: string,
      ): PropertyDescriptor | undefined {
        if (prop in factories)
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

  functionArgs(): Value {
    if (this.type === "set") return Value.fromSet({});
    if (this.type !== "lambda")
      throw new Error("wechselbalg: functionArgs requires a function");
    if (!this._formals) return Value.fromSet({});
    const r: ValueSet = {};
    for (const [k, v] of Object.entries(this._formals))
      r[k] = Value.fromBool(v);
    return Value.fromSet(r);
  }

  isNull(): boolean {
    return this.type === "null";
  }
  isInt(): boolean {
    return this.type === "int";
  }
  isFloat(): boolean {
    return this.type === "float";
  }
  isBool(): boolean {
    return this.type === "bool";
  }
  isString(): boolean {
    return this.type === "string";
  }
  isNumber(): boolean {
    return this.type === "int" || this.type === "float";
  }
  isList(): boolean {
    return this.type === "list";
  }
  isSet(): boolean {
    return this.type === "set";
  }
  isAttrs(): boolean {
    return this.type === "set";
  }
  isFunction(): boolean {
    return this.type === "lambda";
  }
  typeOf(): string {
    return this.type;
  }

  // ── Accessors ─────────────────────────────────────────────────

  asInt(): bigint {
    if (this.type === "int") return this.value as bigint;
    throw new Error("wechselbalg: expected int, got " + this.type);
  }

  asFloat(): number {
    if (this.type === "float") return this.value as number;
    if (this.type === "int") return Number(this.value as bigint);
    throw new Error("wechselbalg: expected float, got " + this.type);
  }

  asBool(): boolean {
    if (this.type === "bool") return this.value as boolean;
    throw new Error("wechselbalg: expected bool, got " + this.type);
  }

  asString(): string {
    if (this.type === "string") return this.value as string;
    throw new Error("wechselbalg: expected string, got " + this.type);
  }

  asList(): Value[] {
    if (this.type === "list") return this.value as Value[];
    throw new Error("wechselbalg: expected list, got " + this.type);
  }

  asSet(): ValueSet {
    if (this.type === "set") return this.value as ValueSet;
    throw new Error("wechselbalg: expected set, got " + this.type);
  }

  asFunction(): LambdaFn {
    if (this.type === "lambda") return this.value as LambdaFn;
    throw new Error("wechselbalg: expected lambda, got " + this.type);
  }

  // ── AST introspection (builtins.reify / builtins.sameFunction) ─
  //
  // Mirrors the Nix fork: a function's identity is (code, environment).
  // `withMeta` records the stripped AST of a code template together with the
  // environment this instance captured; `primop` records a primop name,
  // because Nix compares primops by name rather than by identity.

  static withMeta(v: Value, astJson: string, env: Value | null): Value {
    v._wbAst = astJson;
    v._wbEnv = env === undefined ? null : env;
    return v;
  }

  static primop(name: string, v: Value): Value {
    v._wbPrimop = name;
    return v;
  }

  static _forceDeep(v: Value): Value {
    let r: Value = v;
    while (r && (r as any).__wb_isThunk) r = (r as any).__wb_force();
    return r;
  }

  static sameFunction(a: Value, b: Value): boolean {
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

  static reify(f: Value): Value {
    const fn = Value._forceDeep(f);
    if (!fn.isFunction())
      throw new Error("wechselbalg: reify expects a function");
    if (fn._wbPrimop !== undefined)
      return Value.fromSet({
        _expr: Value.fromString("primop"),
        value: Value.fromString(fn._wbPrimop),
      });
    if (fn._wbAst === undefined)
      throw new Error(
        "wechselbalg: reify: this function carries no AST (not generated by wechselbalg)",
      );
    return Value._reifyNode(
      Value.fromJSON_(Value.fromString(fn._wbAst)),
      fn._wbEnv ?? null,
    );
  }

  // Re-attach `closureEnvValue` to the variables the template captured.
  static _reifyNode(node: Value, env: Value | null): Value {
    if (node.isList())
      return Value.fromList(node.asList().map((e) => Value._reifyNode(e, env)));
    if (!node.isAttrs()) return node;
    const src = node.asSet();
    const out: ValueSet = {};
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
  static _envLookup(env: Value | null, name: string): Value {
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
    const tree: Record<string, unknown> = {};
    for (const k of keys) {
      const parts = k.slice(prefix.length).split(".");
      let cur = tree;
      for (let i = 0; i < parts.length - 1; i++) {
        if (!(parts[i] in cur)) cur[parts[i]] = {};
        cur = cur[parts[i]] as Record<string, unknown>;
      }
      cur[parts[parts.length - 1]] = k;
    }
    return Value._envNest(tree, env);
  }

  static _envNest(tree: Record<string, unknown>, env: Value): Value {
    const factories: Record<string, () => Value> = {};
    for (const k of Object.keys(tree)) {
      const v = tree[k];
      factories[k] =
        typeof v === "string"
          ? () => env.get(v)
          : () => Value._envNest(v as Record<string, unknown>, env);
    }
    return Value.lazySet(factories);
  }

  // ── Call ───────────────────────────────────────────────────────

  call(arg: Value): Value {
    if (this.type === "set" && "__functor" in (this.value as ValueSet))
      return (this.value as ValueSet)["__functor"].call(this).call(arg);
    if (this.type !== "lambda")
      throw new Error("wechselbalg: tried to call a " + this.type);
    return (this.value as LambdaFn)(arg);
  }

  // ── Attribute access ──────────────────────────────────────────

  get(key: string | Value): Value {
    if (this.type !== "set")
      throw new Error("wechselbalg: attribute access on " + this.type);
    const k = typeof key === "string" ? key : (key as Value).asString();
    if (!(k in (this.value as ValueSet)))
      throw new Error("wechselbalg: attribute '" + k + "' not found");
    return (this.value as ValueSet)[k];
  }

  getOr(key: string | Value, def: Value): Value {
    if (this.type !== "set") return def;
    const k = typeof key === "string" ? key : (key as Value).asString();
    return k in (this.value as ValueSet) ? (this.value as ValueSet)[k] : def;
  }

  hasAttr(key: string): boolean {
    if (this.type !== "set") return false;
    const k =
      typeof key === "string" ? key : (key as unknown as Value).asString();
    return k in (this.value as ValueSet);
  }

  // ── Comparison ────────────────────────────────────────────────

  eq(other: Value): Value {
    return Value.fromBool(Value._deepEq(this, other));
  }

  static _deepEq(a: Value, b: Value): boolean {
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
        const al = a.value as Value[],
          bl = b.value as Value[];
        if (al.length !== bl.length) return false;
        for (let i = 0; i < al.length; i++)
          if (!Value._deepEq(al[i], bl[i])) return false;
        return true;
      }
      case "set": {
        const ak = Object.keys(a.value as ValueSet).sort();
        const bk = Object.keys(b.value as ValueSet).sort();
        if (ak.length !== bk.length) return false;
        for (let i = 0; i < ak.length; i++) {
          if (ak[i] !== bk[i]) return false;
          if (
            !Value._deepEq(
              (a.value as ValueSet)[ak[i]],
              (b.value as ValueSet)[bk[i]],
            )
          )
            return false;
        }
        return true;
      }
      case "lambda":
        return false;
    }
    return false;
  }

  lessThan(other: Value): Value {
    if (this.isInt() && other.isInt())
      return Value.fromBool((this.value as bigint) < (other.value as bigint));
    if (this.isNumber() && other.isNumber())
      return Value.fromBool(this.asFloat() < other.asFloat());
    if (this.isString() && other.isString())
      return Value.fromBool((this.value as string) < (other.value as string));
    throw new Error(
      "wechselbalg: cannot compare " + this.type + " < " + other.type,
    );
  }

  // ── Arithmetic ────────────────────────────────────────────────

  add(other: Value): Value {
    if (this.isInt() && other.isInt())
      return Value.fromInt((this.value as bigint) + (other.value as bigint));
    if (this.isNumber() && other.isNumber())
      return Value.fromFloat(this.asFloat() + other.asFloat());
    if (this.isString() && other.isString())
      return Value.fromString((this.value as string) + (other.value as string));
    throw new Error(
      "wechselbalg: cannot add " + this.type + " and " + other.type,
    );
  }

  sub(other: Value): Value {
    if (this.isInt() && other.isInt())
      return Value.fromInt((this.value as bigint) - (other.value as bigint));
    if (this.isNumber() && other.isNumber())
      return Value.fromFloat(this.asFloat() - other.asFloat());
    throw new Error(
      "wechselbalg: cannot subtract " + this.type + " and " + other.type,
    );
  }

  mul(other: Value): Value {
    if (this.isInt() && other.isInt())
      return Value.fromInt((this.value as bigint) * (other.value as bigint));
    if (this.isNumber() && other.isNumber())
      return Value.fromFloat(this.asFloat() * other.asFloat());
    throw new Error(
      "wechselbalg: cannot multiply " + this.type + " and " + other.type,
    );
  }

  div(other: Value): Value {
    if (this.isInt() && other.isInt()) {
      if ((other.value as bigint) === 0n)
        throw new Error("wechselbalg: division by zero");
      return Value.fromInt((this.value as bigint) / (other.value as bigint));
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

  negate(): Value {
    return Value.fromBool(!this.asBool());
  }

  // ── Collection operations ─────────────────────────────────────

  update(other: Value): Value {
    // Lazy merge: keys from `other` shadow keys from `this`.
    const base = this;
    const ext = other;
    const merged = new Proxy(Object.create(null), {
      get(_target: unknown, prop: string): Value {
        if (ext.hasAttr(prop)) return ext.get(prop);
        return base.get(prop);
      },
      has(_target: unknown, prop: string): boolean {
        return ext.hasAttr(prop) || base.hasAttr(prop);
      },
      ownKeys(_target: unknown): string[] {
        const baseKeys = Object.keys(base.asSet());
        const extKeys = Object.keys(ext.asSet());
        return [...new Set([...baseKeys, ...extKeys])];
      },
      getOwnPropertyDescriptor(
        _target: unknown,
        prop: string,
      ): PropertyDescriptor | undefined {
        if (ext.hasAttr(prop) || base.hasAttr(prop))
          return {
            configurable: true,
            enumerable: true,
            writable: false,
            value: undefined,
          };
        return undefined;
      },
    });
    return Value.fromSet(merged);
  }

  concat(other: Value): Value {
    if (this.type !== "list" || other.type !== "list")
      throw new Error("wechselbalg: concat (++) requires two lists");
    return Value.fromList([
      ...(this.value as Value[]),
      ...(other.value as Value[]),
    ]);
  }

  at(index: bigint | number): Value {
    const l = this.asList();
    const i = typeof index === "bigint" ? Number(index) : index;
    if (i < 0 || i >= l.length)
      throw new Error("wechselbalg: index out of bounds");
    return l[i];
  }

  head(): Value {
    const l = this.asList();
    if (l.length === 0) throw new Error("wechselbalg: head of empty list");
    return l[0];
  }

  tail(): Value {
    const l = this.asList();
    if (l.length === 0) throw new Error("wechselbalg: tail of empty list");
    return Value.fromList(l.slice(1));
  }

  length(): Value {
    return Value.fromInt(BigInt(this.asList().length));
  }

  map(func: Value): Value {
    return Value.fromList(this.asList().map((e) => func.call(e)));
  }

  filter(func: Value): Value {
    return Value.fromList(this.asList().filter((e) => func.call(e).asBool()));
  }

  foldl(op: Value, acc: Value): Value {
    let result = acc;
    for (const e of this.asList()) result = op.call(result).call(e);
    return result;
  }

  all(func: Value): Value {
    return Value.fromBool(this.asList().every((e) => func.call(e).asBool()));
  }

  any(func: Value): Value {
    return Value.fromBool(this.asList().some((e) => func.call(e).asBool()));
  }

  elem(item: Value): Value {
    return Value.fromBool(this.asList().some((e) => Value._deepEq(e, item)));
  }

  concatMap(func: Value): Value {
    const r: Value[] = [];
    for (const e of this.asList()) r.push(...func.call(e).asList());
    return Value.fromList(r);
  }

  concatStringsSep(sep: Value | string): Value {
    const s = typeof sep === "string" ? sep : sep.asString();
    return Value.fromString(
      this.asList()
        .map((e) => e.asString())
        .join(s),
    );
  }

  attrNames(): Value {
    return Value.fromList(
      Object.keys(this.asSet())
        .sort()
        .map((k) => Value.fromString(k)),
    );
  }

  attrValues(): Value {
    return Value.fromList(
      Object.keys(this.asSet())
        .sort()
        .map((k) => (this.value as ValueSet)[k]),
    );
  }

  removeAttrs(names: Value): Value {
    const orig = this.asSet();
    const remove = new Set(names.asList().map((n) => n.asString()));
    const factories: Record<string, () => Value> = {};
    for (const k of Object.keys(orig)) {
      if (!remove.has(k)) factories[k] = () => orig[k];
    }
    return Value.lazySet(factories);
  }

  listToAttrs(): Value {
    const s: ValueSet = {};
    for (const e of this.asList()) s[e.get("name").asString()] = e.get("value");
    return Value.fromSet(s);
  }

  mapAttrs(f: Value): Value {
    const s = this.asSet();
    const factories: Record<string, () => Value> = {};
    for (const k of Object.keys(s)) {
      const key = k;
      factories[key] = () => f.call(Value.fromString(key)).call(s[key]);
    }
    return Value.lazySet(factories);
  }

  intersectAttrs(other: Value): Value {
    const a = this.asSet(),
      b = other.asSet(),
      r: ValueSet = {};
    for (const k of Object.keys(a)) if (k in b) r[k] = b[k];
    return Value.fromSet(r);
  }

  catAttrs(attr: Value | string): Value {
    const a = typeof attr === "string" ? attr : attr.asString();
    return Value.fromList(
      this.asList()
        .filter((e) => e.hasAttr(a))
        .map((e) => e.get(a)),
    );
  }

  groupBy(f: Value): Value {
    const groups: Record<string, Value[]> = {};
    for (const e of this.asList()) {
      const k = f.call(e).asString();
      if (!(k in groups)) groups[k] = [];
      groups[k].push(e);
    }
    const r: ValueSet = {};
    for (const k of Object.keys(groups)) r[k] = Value.fromList(groups[k]);
    return Value.fromSet(r);
  }

  partition(pred: Value): Value {
    const right: Value[] = [],
      wrong: Value[] = [];
    for (const e of this.asList()) {
      if (pred.call(e).asBool()) right.push(e);
      else wrong.push(e);
    }
    return Value.fromSet({
      right: Value.fromList(right),
      wrong: Value.fromList(wrong),
    });
  }

  sort(cmp: Value): Value {
    const l = [...this.asList()];
    l.sort((a, b) =>
      cmp.call(a).call(b).asBool() ? -1 : cmp.call(b).call(a).asBool() ? 1 : 0,
    );
    return Value.fromList(l);
  }

  replaceStrings(from: Value, to: Value): Value {
    let s = this.asString();
    const fl = from.asList(),
      tl = to.asList();
    for (let i = 0; i < fl.length; i++) {
      s = s.split(fl[i].asString()).join(tl[i].asString());
    }
    return Value.fromString(s);
  }

  static genList(func: Value, count: bigint | number): Value {
    const n = typeof count === "bigint" ? Number(count) : count;
    const r: Value[] = [];
    for (let i = 0; i < n; i++) r.push(func.call(Value.fromInt(BigInt(i))));
    return Value.fromList(r);
  }

  ceil(): Value {
    if (this.isInt()) return this;
    return Value.fromInt(BigInt(Math.ceil(this.asFloat())));
  }

  floor(): Value {
    if (this.isInt()) return this;
    return Value.fromInt(BigInt(Math.floor(this.asFloat())));
  }

  toString_(): Value {
    switch (this.type) {
      case "null":
        return Value.fromString("");
      case "bool":
        return Value.fromString((this.value as boolean) ? "1" : "");
      case "int":
        return Value.fromString((this.value as bigint).toString());
      case "float":
        return Value.fromString((this.value as number).toString());
      case "string":
        return this;
      default:
        throw new Error(
          "wechselbalg: cannot convert " + this.type + " to string",
        );
    }
  }

  toJSON_(): Value {
    switch (this.type) {
      case "null":
        return Value.fromString("null");
      case "bool":
        return Value.fromString((this.value as boolean) ? "true" : "false");
      case "int":
        return Value.fromString((this.value as bigint).toString());
      case "float":
        return Value.fromString(JSON.stringify(this.value));
      case "string":
        return Value.fromString(JSON.stringify(this.value));
      case "list":
        return Value.fromString(
          "[" +
            (this.value as Value[])
              .map((e) => e.toJSON_().asString())
              .join(",") +
            "]",
        );
      case "set": {
        const pairs = Object.keys(this.value as ValueSet)
          .sort()
          .map(
            (k) =>
              JSON.stringify(k) +
              ":" +
              (this.value as ValueSet)[k].toJSON_().asString(),
          );
        return Value.fromString("{" + pairs.join(",") + "}");
      }
      case "lambda":
        throw new Error("wechselbalg: cannot serialize lambda to JSON");
    }
    return Value.fromString("null");
  }

  static fromJSON_(s: Value | string): Value {
    const str = typeof s === "string" ? s : (s as Value).asString();
    return Value._fromJSValue(JSON.parse(str));
  }

  static _fromJSValue(v: unknown): Value {
    if (v === null) return Value.null_();
    if (typeof v === "boolean") return Value.fromBool(v);
    if (typeof v === "number") {
      if (Number.isInteger(v)) return Value.fromInt(BigInt(v));
      return Value.fromFloat(v);
    }
    if (typeof v === "string") return Value.fromString(v);
    if (Array.isArray(v)) return Value.fromList(v.map(Value._fromJSValue));
    if (typeof v === "object") {
      const r: ValueSet = {};
      for (const k of Object.keys(v as Record<string, unknown>))
        r[k] = Value._fromJSValue((v as Record<string, unknown>)[k]);
      return Value.fromSet(r);
    }
    throw new Error("wechselbalg: cannot convert JS value to Value");
  }
}
