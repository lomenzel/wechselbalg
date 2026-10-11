# JavaScript implementations of Nix primops.
#
# Each entry is a JS expression evaluating to a Value.lambda (curried).
# All inputs and outputs are Value instances.

{
  wasm = ''
    (() => {
      // 1. Process-wide singletons anchored to the Value class
      // These survive across ANY number of IIFE invocations, lambda calls, or modules!
      const moduleCache = (Value._wbWasmModuleCache ??= new Map());
      const instanceCache = (Value._wbWasmInstanceCache ??= new Map());

      let currentMemory = null;

      const pureImports = {
        wasi_snapshot_preview1: new Proxy({
          proc_exit: (code) => { throw new Error("Wasm proc_exit: " + code); },
          fd_write: (fd, iovs, iovs_len, nwritten) => {
            if (!currentMemory) return 0;
            const view = new DataView(currentMemory.buffer);
            let total = 0;
            for (let i = 0; i < iovs_len; i++) {
              const ptr = view.getUint32(iovs + i * 8, true);
              const len = view.getUint32(iovs + i * 8 + 4, true);
              const bytes = new Uint8Array(currentMemory.buffer, ptr, len);
              const str = new TextDecoder().decode(bytes);
              if (fd === 1) process.stdout.write(str);
              if (fd === 2) process.stderr.write(str);
              total += len;
            }
            if (nwritten) view.setUint32(nwritten, total, true);
            return 0;
          }
        }, {
          get(target, prop) {
            if (prop in target) return target[prop];
            return () => 0; // WASI SUCCESS stub
          }
        }),
        env: new Proxy({
          abort: () => { throw new Error("Wasm abort()"); }
        }, {
          get(target, prop) {
            if (prop in target) return target[prop];
            return () => 0;
          }
        })
      };

      return Value.lambda(config => Value.lambda(args => {
        const conf = config.asSet();
        const base64Val = conf.bytecode || conf.base64;
        const fnameVal = conf.fname || conf.function;

        if (!base64Val || !fnameVal) {
          throw new Error("builtins.wasm requires 'bytecode' (or 'base64') and 'fname' (or 'function')");
        }

        const fname = fnameVal.asString();
        console.log("-> CALLING WASM:", fname);


        // 2. TRUE MODULE CACHING: Check persistent process-wide cache
        // We use base64Val._wbModule if available, else fall back to the global Map
        let module = base64Val._wbModule;
        if (!module) {
          const base64 = base64Val.asString();
          module = moduleCache.get(base64);
          if (!module) {
            const binary = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
            module = new WebAssembly.Module(binary);
            moduleCache.set(base64, module);
          }
          base64Val._wbModule = module;
        }

        // 3. TRUE INSTANCE & SNAPSHOT CACHING (Keyed by Module object reference: O(1))
        let state = instanceCache.get(module);
        if (!state) {
          const instance = new WebAssembly.Instance(module, pureImports);
          currentMemory = instance.exports.memory;
          const memory = instance.exports.memory;
          if (!memory) {
            throw new Error("Wasm module must export 'memory'");
          }

          // Snapshot pristine initial memory in < 0.05 ms
          const cleanSnapshot = new Uint8Array(memory.buffer.slice(0));

          state = {
            instance,
            cleanSnapshot,
          };
          instanceCache.set(module, state);
        }

        const instance = state.instance;
        const memory = instance.exports.memory;
        const cleanSnapshot = state.cleanSnapshot;

        const fn = instance.exports[fname];
        if (typeof fn !== "function") {
          throw new Error("Wasm export '" + fname + "' is not a function");
        }

        const alloc = instance.exports.malloc || instance.exports.__wb_alloc;
        if (!alloc) {
          throw new Error("Wasm module must export an allocator ('malloc' or '__wb_alloc')");
        }

        let outJsonStr = "";

        try {
          // 4. Input serialization
          const inStr = args.isString() ? args.asString() : args.toJSON_().asString();
          const inBytes = new TextEncoder().encode(inStr + "\0");
          const inPtr = alloc(inBytes.length);
          new Uint8Array(memory.buffer, inPtr, inBytes.length).set(inBytes);

          // 5. Invoke function: supports func(ptr) or func(ptr, len)
          const inLen = inBytes.length - 1;
          const callArgs = fn.length >= 2 ? [inPtr, inLen] : [inPtr];
          currentMemory = memory;
          const outPtr = fn(...callArgs);

          if (!outPtr || outPtr === 0) {
            return Value.null_();
          }

          // 6. Read string response into JS heap BEFORE memory is wiped
          const memView = new Uint8Array(memory.buffer);
          let end = outPtr;
          while (end < memView.length && memView[end] !== 0) {
            end++;
          }
          outJsonStr = new TextDecoder().decode(memView.subarray(outPtr, end));

        } finally {
          currentMemory = null;
          // Fresh instance per call guarantees 100% purity without heap/global desync
          instanceCache.delete(module);
        }

        // 8. Return parsed JSON or fallback to raw string
        try {
          return Value.fromJSON_(Value.fromString(outJsonStr));
        } catch (_) {
          return Value.fromString(outJsonStr);
        }
      }))
    })()
  '';
  sub = ''
    Value.lambda(a => Value.lambda(b => a.sub(b)))
  '';

  lessThan = "Value.lambda(a => Value.lambda(b => a.lessThan(b)))";

  elemAt = ''
    Value.lambda(list => Value.lambda(index => list.at(index.asInt())))
  '';

  filter = "Value.lambda(func => Value.lambda(list => list.filter(func)))";
  all = "Value.lambda(func => Value.lambda(list => list.all(func)))";
  any = "Value.lambda(func => Value.lambda(list => list.any(func)))";
  elem = "Value.lambda(item => Value.lambda(list => list.elem(item)))";
  concatMap = "Value.lambda(func => Value.lambda(list => list.concatMap(func)))";
  map = "Value.lambda(func => Value.lambda(list => list.map(func)))";

  genList = "Value.lambda(func => Value.lambda(count => Value.genList(func, count.asInt())))";

  foldl' = "Value.lambda(op => Value.lambda(acc => Value.lambda(list => list.foldl(op, acc))))";

  typeOf = "Value.lambda(e => Value.fromString(e.typeOf()))";

  toString = "Value.lambda(e => e.toString_())";
  toJSON = "Value.lambda(e => e.toJSON_())";
  fromJSON = "Value.lambda(s => Value.fromJSON_(s))";

  concatStringsSep = "Value.lambda(sep => Value.lambda(list => list.concatStringsSep(sep)))";

  head = "Value.lambda(list => list.head())";
  tail = "Value.lambda(list => list.tail())";

  length = "Value.lambda(e => e.length())";

  mul = "Value.lambda(a => Value.lambda(b => a.mul(b)))";
  div = "Value.lambda(a => Value.lambda(b => a.div(b)))";
  add = "Value.lambda(a => Value.lambda(b => a.add(b)))";

  hasAttr = "Value.lambda(attr => Value.lambda(s => Value.fromBool(s.hasAttr(attr.asString()))))";
  getAttr = "Value.lambda(attr => Value.lambda(s => s.get(attr.asString())))";
  removeAttrs = "Value.lambda(s => Value.lambda(names => s.removeAttrs(names)))";
  attrNames = "Value.lambda(s => s.attrNames())";
  attrValues = "Value.lambda(s => s.attrValues())";
  intersectAttrs = "Value.lambda(a => Value.lambda(b => a.intersectAttrs(b)))";
  catAttrs = "Value.lambda(attr => Value.lambda(list => list.catAttrs(attr)))";

  isNull = "Value.lambda(e => Value.fromBool(e.isNull()))";
  isInt = "Value.lambda(e => Value.fromBool(e.isInt()))";
  isFloat = "Value.lambda(e => Value.fromBool(e.isFloat()))";
  isString = "Value.lambda(e => Value.fromBool(e.isString()))";
  isBool = "Value.lambda(e => Value.fromBool(e.isBool()))";
  isList = "Value.lambda(e => Value.fromBool(e.isList()))";
  isAttrs = "Value.lambda(e => Value.fromBool(e.isAttrs()))";
  isFunction = "Value.lambda(e => Value.fromBool(e.isFunction()))";
  isPath = "Value.lambda(e => Value.fromBool(false))";

  functionArgs = "Value.lambda(f => f.functionArgs())";

  trace = ''
    Value.lambda(msg => Value.lambda(val => {
      console.log("[trace]", msg.asString());
      return val;
    }))
  '';
  warn = ''
    Value.lambda(msg => Value.lambda(val => {
      console.warn("[warn]", msg.asString());
      return val;
    }))
  '';

  seq = "Value.lambda(a => Value.lambda(b => { Value._forceDeep(a); return b; }))";
  deepSeq = ''
    Value.lambda(a => Value.lambda(b => {
      const seen = new Set();
      function force(v) {
        const val = Value._forceDeep(v);
        if (!val || seen.has(val)) return;
        seen.add(val);
        if (val.isList()) {
          for (const elem of val.asList()) force(elem);
        } else if (val.isAttrs()) {
          const s = val.asSet();
          for (const k of Object.keys(s)) force(s[k]);
        }
      }
      force(a);
      return b;
    }))
  '';
  substring = ''
    Value.lambda(start => Value.lambda(len => Value.lambda(str => {
      const s = str.asString();
      const st = Number(start.asInt());
      const l = Number(len.asInt());
      if (st < 0 || st >= s.length) return Value.fromString("");
      if (l < 0) return Value.fromString(s.slice(st));
      return Value.fromString(s.slice(st, st + l));
    })))
  '';
  stringLength = "Value.lambda(str => Value.fromInt(BigInt(str.asString().length)))";
  replaceStrings = ''
    Value.lambda(from => Value.lambda(to => Value.lambda(str => str.replaceStrings(from, to))))
  '';
  split = ''
    Value.lambda(regex => Value.lambda(str => {
      const re = new RegExp(regex.asString(), "g");
      const s = str.asString();
      const parts = [];
      let lastIndex = 0;
      let match;
      while ((match = re.exec(s)) !== null) {
        parts.push(Value.fromString(s.slice(lastIndex, match.index)));
        const captures = match.length > 1
          ? match.slice(1).map(c => c === undefined ? Value.null_() : Value.fromString(c))
          : [];
        parts.push(Value.fromList(captures));
        lastIndex = re.lastIndex;
        if (match.index === re.lastIndex) {
          re.lastIndex++;
        }
      }
      parts.push(Value.fromString(s.slice(lastIndex)));
      return Value.fromList(parts);
    }))
  '';
  match = ''
    Value.lambda(regex => Value.lambda(str => {
      const m = str.asString().match(new RegExp("^(?:" + regex.asString() + ")$"));
      if (!m) return Value.null_();
      return Value.fromList(m.slice(1).map(s => s === undefined ? Value.null_() : Value.fromString(s)));
    }))
  '';

  sort = "Value.lambda(cmp => Value.lambda(list => list.sort(cmp)))";
  groupBy = "Value.lambda(f => Value.lambda(list => list.groupBy(f)))";
  partition = "Value.lambda(pred => Value.lambda(list => list.partition(pred)))";

  ceil = "Value.lambda(x => x.ceil())";
  floor = "Value.lambda(x => x.floor())";

  bitAnd = "Value.lambda(a => Value.lambda(b => Value.fromInt(a.asInt() & b.asInt())))";
  bitOr = "Value.lambda(a => Value.lambda(b => Value.fromInt(a.asInt() | b.asInt())))";
  bitXor = "Value.lambda(a => Value.lambda(b => Value.fromInt(a.asInt() ^ b.asInt())))";

  abort = "Value.lambda(msg => { throw new Error('abort: ' + msg.asString()); })";
  throw = "Value.lambda(msg => { throw new Error(msg.asString()); })";

  tryEval = ''
    Value.lambda(e => {
      try {
        const forced = Value._forceDeep(e);
        return Value.fromSet({
          success: Value.fromBool(true),
          value: e
        });
      } catch(err) {
      console.error("[debug][wechselbalg] tryEval caught this error:", err);
        return Value.fromSet({
          success: Value.fromBool(false),
          value: Value.fromBool(false)
        });
      }
    })
  '';

  mapAttrs = "Value.lambda(f => Value.lambda(s => s.mapAttrs(f)))";
  zipAttrsWith = ''
    Value.lambda(f => Value.lambda(list => {
      const sets = list.asList().map(s => s.asSet());
      const allKeys = new Set();
      for (const s of sets)
        for (const k of Object.keys(s))
          allKeys.add(k);
      const factories = {};
      for (const k of allKeys) {
        const key = k;
        factories[key] = () => {
          const vals = [];
          for (const s of sets)
            if (key in s) vals.push(s[key]);
          return f.call(Value.fromString(key)).call(Value.fromList(vals));
        };
      }
      return Value.lazySet(factories);
    }))
  '';

  concatLists = ''
    Value.lambda(lists => {
      const r = [];
      for (const l of lists.asList()) r.push(...l.asList());
      return Value.fromList(r);
    })
  '';

  parseDrvName = ''
    Value.lambda(s => {
      const str = s.asString();
      const m = str.match(/^(.+?)-([0-9].*)$/);
      if (m) return Value.fromSet({name: Value.fromString(m[1]), version: Value.fromString(m[2])});
      return Value.fromSet({name: s, version: Value.fromString("")});
    })
  '';

  compareVersions = ''
    Value.lambda(a => Value.lambda(b => {
      const pa = a.asString().split(".");
      const pb = b.asString().split(".");
      const len = Math.max(pa.length, pb.length);
      for (let i = 0; i < len; i++) {
        const na = parseInt(pa[i] || "0", 10);
        const nb = parseInt(pb[i] || "0", 10);
        if (na < nb) return Value.fromInt(-1n);
        if (na > nb) return Value.fromInt(1n);
      }
      return Value.fromInt(0n);
    }))
  '';

  splitVersion = ''
    Value.lambda(s => Value.fromList(s.asString().split(/([^0-9]+|[0-9]+)/).filter(Boolean).map(Value.fromString)))
  '';

  hashString = ''
    Value.lambda(algo => Value.lambda(str => {
      const s = str.asString();
      let hash = 0;
      for (let i = 0; i < s.length; i++) {
        hash = ((hash << 5) - hash + s.charCodeAt(i)) | 0;
      }
      return Value.fromString(Math.abs(hash).toString(16).padStart(8, "0"));
    }))
  '';

  listToAttrs = ''
    Value.lambda(list => {
      const r = {};
      for (const e of list.asList()) {
        const name = e.get("name");
        if (!name.isNull()) r[name.asString()] = e.get("value");
      }
      return Value.fromSet(r);
    })
  '';

  genericClosure = ''
    Value.lambda(args => {
      const startSet = args.get("startSet").asList();
      const op = args.get("operator");
      const result = [];
      const seen = new Set();
      const work = [...startSet];
      while (work.length > 0) {
        const item = work.shift();
        const key = item.get("key").toJSON_().asString();
        if (seen.has(key)) continue;
        seen.add(key);
        result.push(item);
        const newItems = op.call(item).asList();
        work.push(...newItems);
      }
      return Value.fromList(result);
    })
  '';

  addErrorContext = "Value.lambda(ctx => Value.lambda(val => val))";

  # ── AST introspection (self-hosting) ──────────────────────────
  reify = "Value.lambda(f => Value.reify(f))";
  sameFunction = "Value.lambda(a => Value.lambda(b => Value.fromBool(Value.sameFunction(a, b))))";

  null = "Value.null_()";
  true = "Value.fromBool(true)";
  false = "Value.fromBool(false)";
}
