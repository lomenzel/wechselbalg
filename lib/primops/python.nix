# Python implementations of Nix primops.
#
# Each entry is a Python expression evaluating to a Value.lambda_ (curried).
# All inputs and outputs are Value instances.
# Complex implementations use __wb_* helpers defined in value.py.

{
  sub = "Value.lambda_(lambda a: Value.lambda_(lambda b: a.sub(b)))";

  lessThan = "Value.lambda_(lambda a: Value.lambda_(lambda b: a.less_than(b)))";

  elemAt = "Value.lambda_(lambda lst: Value.lambda_(lambda index: lst.at(index.as_int())))";

  filter = "Value.lambda_(lambda func: Value.lambda_(lambda lst: lst.filter(func)))";
  all = "Value.lambda_(lambda func: Value.lambda_(lambda lst: lst.all(func)))";
  any = "Value.lambda_(lambda func: Value.lambda_(lambda lst: lst.any(func)))";
  elem = "Value.lambda_(lambda item: Value.lambda_(lambda lst: lst.elem(item)))";
  concatMap = "Value.lambda_(lambda func: Value.lambda_(lambda lst: lst.concat_map(func)))";
  map = "Value.lambda_(lambda func: Value.lambda_(lambda lst: lst.map(func)))";

  genList = "Value.lambda_(lambda func: Value.lambda_(lambda count: Value.gen_list(func, count.as_int())))";

  foldl' = "Value.lambda_(lambda op: Value.lambda_(lambda acc: Value.lambda_(lambda lst: lst.foldl(op, acc))))";

  typeOf = "Value.lambda_(lambda e: Value.from_string(e.type_of()))";

  toString = "Value.lambda_(lambda e: e.to_string_())";
  toJSON = "Value.lambda_(lambda e: e.to_json_())";
  fromJSON = "Value.lambda_(lambda s: Value.from_json_(s))";

  concatStringsSep = "Value.lambda_(lambda sep: Value.lambda_(lambda lst: lst.concat_strings_sep(sep)))";

  head = "Value.lambda_(lambda lst: lst.head())";
  tail = "Value.lambda_(lambda lst: lst.tail())";

  length = "Value.lambda_(lambda e: e.length())";

  mul = "Value.lambda_(lambda a: Value.lambda_(lambda b: a.mul(b)))";
  div = "Value.lambda_(lambda a: Value.lambda_(lambda b: a.div(b)))";
  add = "Value.lambda_(lambda a: Value.lambda_(lambda b: a.add(b)))";

  hasAttr = "Value.lambda_(lambda attr: Value.lambda_(lambda s: Value.from_bool(s.has_attr(attr.as_string()))))";
  getAttr = "Value.lambda_(lambda attr: Value.lambda_(lambda s: s.get(attr.as_string())))";
  removeAttrs = "Value.lambda_(lambda s: Value.lambda_(lambda names: s.remove_attrs(names)))";
  attrNames = "Value.lambda_(lambda s: s.attr_names())";
  attrValues = "Value.lambda_(lambda s: s.attr_values())";
  intersectAttrs = "Value.lambda_(lambda a: Value.lambda_(lambda b: a.intersect_attrs(b)))";
  catAttrs = "Value.lambda_(lambda attr: Value.lambda_(lambda lst: lst.cat_attrs(attr)))";
  listToAttrs = "Value.lambda_(lambda lst: __wb_list_to_attrs(lst))";

  isNull = "Value.lambda_(lambda e: Value.from_bool(e.is_null()))";
  isInt = "Value.lambda_(lambda e: Value.from_bool(e.is_int()))";
  isFloat = "Value.lambda_(lambda e: Value.from_bool(e.is_float()))";
  isString = "Value.lambda_(lambda e: Value.from_bool(e.is_string()))";
  isBool = "Value.lambda_(lambda e: Value.from_bool(e.is_bool()))";
  isList = "Value.lambda_(lambda e: Value.from_bool(e.is_list()))";
  isAttrs = "Value.lambda_(lambda e: Value.from_bool(e.is_set()))";
  isFunction = "Value.lambda_(lambda e: Value.from_bool(e.is_function()))";
  isPath = "Value.lambda_(lambda e: Value.from_bool(False))";

  functionArgs = "Value.lambda_(lambda f: f.function_args())";

  trace = "Value.lambda_(lambda msg: Value.lambda_(lambda val: __wb_trace(msg, val)))";
  warn = "Value.lambda_(lambda msg: Value.lambda_(lambda val: __wb_warn(msg, val)))";

  seq = "Value.lambda_(lambda a: Value.lambda_(lambda b: (Value._force_deep(a), b)[1]))";
  deepSeq = "Value.lambda_(lambda a: Value.lambda_(lambda b: (a.to_json_(), b)[1]))";

  substring = "Value.lambda_(lambda start: Value.lambda_(lambda length: Value.lambda_(lambda s: Value.from_string(s.as_string()[start.as_int():] if length.as_int() < 0 else s.as_string()[start.as_int():start.as_int() + length.as_int()]))))";
  stringLength = "Value.lambda_(lambda s: Value.from_int(len(s.as_string())))";
  replaceStrings = "Value.lambda_(lambda from_: Value.lambda_(lambda to: Value.lambda_(lambda s: s.replace_strings(from_, to))))";
  split = "Value.lambda_(lambda regex: Value.lambda_(lambda s: __wb_split(regex, s)))";
  match = "Value.lambda_(lambda regex: Value.lambda_(lambda s: __wb_match(regex, s)))";

  sort = "Value.lambda_(lambda cmp: Value.lambda_(lambda lst: lst.sort(cmp)))";
  groupBy = "Value.lambda_(lambda f: Value.lambda_(lambda lst: lst.group_by(f)))";
  partition = "Value.lambda_(lambda pred: Value.lambda_(lambda lst: lst.partition(pred)))";

  ceil = "Value.lambda_(lambda x: x.ceil())";
  floor = "Value.lambda_(lambda x: x.floor())";

  bitAnd = "Value.lambda_(lambda a: Value.lambda_(lambda b: Value.from_int(a.as_int() & b.as_int())))";
  bitOr = "Value.lambda_(lambda a: Value.lambda_(lambda b: Value.from_int(a.as_int() | b.as_int())))";
  bitXor = "Value.lambda_(lambda a: Value.lambda_(lambda b: Value.from_int(a.as_int() ^ b.as_int())))";

  abort = "Value.lambda_(lambda msg: __wb_abort(msg))";
  throw = "Value.lambda_(lambda msg: __wb_throw(msg))";

  tryEval = "Value.lambda_(lambda e: __wb_try_eval(e))";

  mapAttrs = "Value.lambda_(lambda f: Value.lambda_(lambda s: s.map_attrs(f)))";
  zipAttrsWith = "Value.lambda_(lambda f: Value.lambda_(lambda lst: __wb_zip_attrs_with(f, lst)))";

  concatLists = "Value.lambda_(lambda lists: Value.from_list([e for l in lists.as_list() for e in l.as_list()]))";

  parseDrvName = "Value.lambda_(lambda s: __wb_parse_drv_name(s))";

  compareVersions = "Value.lambda_(lambda a: Value.lambda_(lambda b: __wb_compare_versions(a, b)))";

  splitVersion = "Value.lambda_(lambda s: __wb_split_version(s))";

  hashString = "Value.lambda_(lambda algo: Value.lambda_(lambda s: __wb_hash_string(algo, s)))";

  genericClosure = "Value.lambda_(lambda args: __wb_generic_closure(args))";

  addErrorContext = "Value.lambda_(lambda ctx: Value.lambda_(lambda val: val))";

  # ── AST introspection (self-hosting) ────────────────────────
  reify = "Value.lambda_(lambda f: Value.reify(f))";
  sameFunction = "Value.lambda_(lambda a: Value.lambda_(lambda b: Value.from_bool(Value.same_function(a, b))))";

  null = "Value.null_()";
}
