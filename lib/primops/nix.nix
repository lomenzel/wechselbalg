# Nix implementations of Nix primops.
#
# Since we're compiling back to Nix, primops are simply references
# to the corresponding builtins. Each entry is a Nix expression string.

{
  sub = "builtins.sub";
  lessThan = "builtins.lessThan";
  elemAt = "builtins.elemAt";
  filter = "builtins.filter";
  all = "builtins.all";
  any = "builtins.any";
  elem = "builtins.elem";
  concatMap = "builtins.concatMap";
  map = "builtins.map";
  genList = "builtins.genList";
  foldl' = "builtins.foldl'";
  typeOf = "builtins.typeOf";
  toString = "builtins.toString";
  toJSON = "builtins.toJSON";
  fromJSON = "builtins.fromJSON";
  concatStringsSep = "builtins.concatStringsSep";
  head = "builtins.head";
  tail = "builtins.tail";
  length = "builtins.length";
  mul = "builtins.mul";
  div = "builtins.div";
  add = "builtins.add";
  hasAttr = "builtins.hasAttr";
  getAttr = "builtins.getAttr";
  removeAttrs = "builtins.removeAttrs";
  attrNames = "builtins.attrNames";
  attrValues = "builtins.attrValues";
  intersectAttrs = "builtins.intersectAttrs";
  catAttrs = "builtins.catAttrs";
  listToAttrs = "builtins.listToAttrs";
  functionArgs = "builtins.functionArgs";
  isNull = "builtins.isNull";
  isInt = "builtins.isInt";
  isFloat = "builtins.isFloat";
  isString = "builtins.isString";
  isBool = "builtins.isBool";
  isList = "builtins.isList";
  isAttrs = "builtins.isAttrs";
  isFunction = "builtins.isFunction";
  trace = "builtins.trace";
  warn = "(msg: val: builtins.trace \"[warn] $${msg}\" val)";
  seq = "builtins.seq";
  deepSeq = "builtins.deepSeq";
  substring = "builtins.substring";
  stringLength = "builtins.stringLength";
  replaceStrings = "builtins.replaceStrings";
  split = "builtins.split";
  match = "builtins.match";
  sort = "builtins.sort";
  groupBy = "builtins.groupBy";
  partition = "builtins.partition";
  ceil = "builtins.ceil";
  floor = "builtins.floor";
  bitAnd = "builtins.bitAnd";
  bitOr = "builtins.bitOr";
  bitXor = "builtins.bitXor";
  abort = "builtins.abort";
  throw = "builtins.throw";
  tryEval = "builtins.tryEval";
  mapAttrs = "builtins.mapAttrs";
  zipAttrsWith = "builtins.zipAttrsWith";
  concatLists = "builtins.concatLists";
  parseDrvName = "builtins.parseDrvName";
  compareVersions = "builtins.compareVersions";
  splitVersion = "builtins.splitVersion";
  null = "null";
  true = "true";
  false = "false";
}
