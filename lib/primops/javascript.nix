# JavaScript implementations of Nix primops.
#
# Each entry is a JS expression evaluating to a Value.lambda (curried).
# All inputs and outputs are Value instances.

{
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

  seq = "Value.lambda(a => Value.lambda(b => b))";
  deepSeq = "Value.lambda(a => Value.lambda(b => { a.toJSON_(); return b; }))";

  substring = ''
    Value.lambda(start => Value.lambda(len => Value.lambda(str =>
      Value.fromString(str.asString().substring(Number(start.asInt()), Number(start.asInt()) + Number(len.asInt())))
    )))
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
        parts.push(Value.fromList([Value.fromString(match[0])]));
        lastIndex = re.lastIndex;
      }
      parts.push(Value.fromString(s.slice(lastIndex)));
      return Value.fromList(parts);
    }))
  '';
  match = ''
    Value.lambda(regex => Value.lambda(str => {
      const m = str.asString().match(new RegExp(regex.asString()));
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
        return Value.fromSet({
          success: Value.fromBool(true),
          value: e
        });
      } catch(_) {
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
      const combined = {};
      for (const s of list.asList()) {
        for (const k of Object.keys(s.asSet())) {
          if (!(k in combined)) combined[k] = [];
          combined[k].push(s.asSet()[k]);
        }
      }
      const r = {};
      for (const k of Object.keys(combined))
        r[k] = f.call(Value.fromString(k)).call(Value.fromList(combined[k]));
      return Value.fromSet(r);
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

  null = "Value.null_()";
  true = "Value.fromBool(true)";
  false = "Value.fromBool(false)";
}
