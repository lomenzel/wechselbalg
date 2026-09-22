# Kotlin implementations of Nix primops.
#
# Each entry is a Kotlin expression evaluating to a Value.lambda (curried).
# All inputs and outputs are Value instances.
# Complex implementations use Primops.* helpers defined in Value.kt.

{
  sub = "Value.lambda { a -> Value.lambda { b -> a.sub(b) } }";

  lessThan = "Value.lambda { a -> Value.lambda { b -> a.lessThan(b) } }";

  elemAt = "Value.lambda { list -> Value.lambda { index -> list.at(index.asInt()) } }";

  filter = "Value.lambda { func -> Value.lambda { list -> list.filter(func) } }";
  all = "Value.lambda { func -> Value.lambda { list -> list.all(func) } }";
  any = "Value.lambda { func -> Value.lambda { list -> list.any(func) } }";
  elem = "Value.lambda { item -> Value.lambda { list -> list.elem(item) } }";
  concatMap = "Value.lambda { func -> Value.lambda { list -> list.concatMap(func) } }";
  map = "Value.lambda { func -> Value.lambda { list -> list.map(func) } }";

  genList = "Value.lambda { func -> Value.lambda { count -> Value.genList(func, count.asInt()) } }";

  foldl' = "Value.lambda { op -> Value.lambda { acc -> Value.lambda { list -> list.foldl(op, acc) } } }";

  typeOf = "Value.lambda { e -> Value.fromString(e.typeOf()) }";

  toString = "Value.lambda { e -> e.toString_() }";
  toJSON = "Value.lambda { e -> e.toJSON_() }";
  fromJSON = "Value.lambda { s -> Value.fromJSON_(s) }";

  concatStringsSep = "Value.lambda { sep -> Value.lambda { list -> list.concatStringsSep(sep) } }";

  head = "Value.lambda { list -> list.head() }";
  tail = "Value.lambda { list -> list.tail() }";

  length = "Value.lambda { e -> e.length() }";

  mul = "Value.lambda { a -> Value.lambda { b -> a.mul(b) } }";
  div = "Value.lambda { a -> Value.lambda { b -> a.div(b) } }";
  add = "Value.lambda { a -> Value.lambda { b -> a.add(b) } }";

  hasAttr = "Value.lambda { attr -> Value.lambda { s -> Value.fromBool(s.hasAttr(attr.asString())) } }";
  getAttr = "Value.lambda { attr -> Value.lambda { s -> s.get(attr.asString()) } }";
  removeAttrs = "Value.lambda { s -> Value.lambda { names -> s.removeAttrs(names) } }";
  attrNames = "Value.lambda { s -> s.attrNames() }";
  attrValues = "Value.lambda { s -> s.attrValues() }";
  intersectAttrs = "Value.lambda { a -> Value.lambda { b -> a.intersectAttrs(b) } }";
  catAttrs = "Value.lambda { attr -> Value.lambda { list -> list.catAttrs(attr) } }";

  isNull = "Value.lambda { e -> Value.fromBool(e.isNull()) }";
  isInt = "Value.lambda { e -> Value.fromBool(e.isInt()) }";
  isFloat = "Value.lambda { e -> Value.fromBool(e.isFloat()) }";
  isString = "Value.lambda { e -> Value.fromBool(e.isString()) }";
  isBool = "Value.lambda { e -> Value.fromBool(e.isBool()) }";
  isList = "Value.lambda { e -> Value.fromBool(e.isList()) }";
  isAttrs = "Value.lambda { e -> Value.fromBool(e.isAttrs()) }";
  isFunction = "Value.lambda { e -> Value.fromBool(e.isFunction()) }";
  isPath = "Value.lambda { _ -> Value.fromBool(false) }";

  functionArgs = "Value.lambda { f -> f.functionArgs() }";

  trace = ''
    Value.lambda { msg -> Value.lambda { v ->
      System.err.println("[trace] " + msg.asString())
      v
    } }
  '';
  warn = ''
    Value.lambda { msg -> Value.lambda { v ->
      System.err.println("[warn] " + msg.asString())
      v
    } }
  '';

  seq = "Value.lambda { a -> Value.lambda { b -> a.force(); b } }";
  deepSeq = "Value.lambda { a -> Value.lambda { b -> a.toJSON_(); b } }";

  substring = "Value.lambda { start -> Value.lambda { len -> Value.lambda { str -> Primops.substring(start, len, str) } } }";
  stringLength = "Value.lambda { str -> Primops.stringLength(str) }";
  replaceStrings = "Value.lambda { from -> Value.lambda { to -> Value.lambda { str -> str.replaceStrings(from, to) } } }";
  split = "Value.lambda { regex -> Value.lambda { str -> Primops.split(regex, str) } }";
  match = "Value.lambda { regex -> Value.lambda { str -> Primops.match(regex, str) } }";

  sort = "Value.lambda { cmp -> Value.lambda { list -> list.sort(cmp) } }";
  groupBy = "Value.lambda { f -> Value.lambda { list -> list.groupBy(f) } }";
  partition = "Value.lambda { pred -> Value.lambda { list -> list.partition(pred) } }";

  ceil = "Value.lambda { x -> x.ceil() }";
  floor = "Value.lambda { x -> x.floor() }";

  bitAnd = "Value.lambda { a -> Value.lambda { b -> Value.fromInt(a.asInt() and b.asInt()) } }";
  bitOr = "Value.lambda { a -> Value.lambda { b -> Value.fromInt(a.asInt() or b.asInt()) } }";
  bitXor = "Value.lambda { a -> Value.lambda { b -> Value.fromInt(a.asInt() xor b.asInt()) } }";

  abort = "Value.lambda { msg -> throw RuntimeException(\"abort: \" + msg.asString()) }";
  throw = "Value.lambda { msg -> throw RuntimeException(msg.asString()) }";

  tryEval = "Value.lambda { e -> Primops.tryEval(e) }";

  mapAttrs = "Value.lambda { f -> Value.lambda { s -> s.mapAttrs(f) } }";
  zipAttrsWith = "Value.lambda { f -> Value.lambda { list -> Primops.zipAttrsWith(f, list) } }";

  concatLists = ''
    Value.lambda { lists ->
      val r = ArrayList<Value>()
      for (l in lists.asList()) r.addAll(l.asList())
      Value.fromList(r)
    }
  '';

  parseDrvName = "Value.lambda { s -> Primops.parseDrvName(s) }";

  compareVersions = "Value.lambda { a -> Value.lambda { b -> Primops.compareVersions(a, b) } }";

  splitVersion = "Value.lambda { s -> Primops.splitVersion(s) }";

  hashString = "Value.lambda { algo -> Value.lambda { str -> Primops.hashString(algo, str) } }";

  listToAttrs = "Value.lambda { list -> list.listToAttrs() }";

  genericClosure = "Value.lambda { args -> Primops.genericClosure(args) }";

  addErrorContext = "Value.lambda { _ -> Value.lambda { val_ -> val_ } }";

  # ── AST introspection (self-hosting) ────────────────────────
  reify = "Value.lambda { f -> Value.reify(f) }";
  sameFunction = "Value.lambda { a -> Value.lambda { b -> Value.fromBool(Value.sameFunction(a, b)) } }";

  null = "Value.null_()";
  true = "Value.fromBool(true)";
  false = "Value.fromBool(false)";
}
