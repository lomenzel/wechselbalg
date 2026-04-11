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
  # Nix ? operator returns false for non-set values, but builtins.hasAttr throws.
  # Wrap to match ? semantics (the walker translates ? to hasAttr).
  hasAttr = "(name: value: (builtins.isAttrs value) && (builtins.hasAttr name value))";
  getAttr = "builtins.getAttr";
  removeAttrs = "builtins.removeAttrs";
  attrNames = "builtins.attrNames";
  attrValues = "builtins.attrValues";
  intersectAttrs = "builtins.intersectAttrs";
  catAttrs = "builtins.catAttrs";
  # Filter out null-named entries to match Nix dynamic attrset semantics
  # (Nix silently drops { ${null} = value; } entries).
  listToAttrs = "(entries: builtins.listToAttrs (builtins.filter (e: e.name != null) entries))";
  functionArgs = "builtins.functionArgs";
  isNull = "builtins.isNull";
  isInt = "builtins.isInt";
  isFloat = "builtins.isFloat";
  isString = "builtins.isString";
  isBool = "builtins.isBool";
  isList = "builtins.isList";
  isAttrs = "builtins.isAttrs";
  isFunction = "builtins.isFunction";
  isPath = "builtins.isPath";
  genericClosure = "builtins.genericClosure";
  dirOf = "builtins.dirOf";
  baseNameOf = "builtins.baseNameOf";
  import = "import";
  readFile = "builtins.readFile";
  pathExists = "builtins.pathExists";
  toPath = "builtins.toPath";
  storePath = "builtins.storePath";
  readDir = "builtins.readDir";
  hashString = "builtins.hashString";
  unsafeDiscardStringContext = "builtins.unsafeDiscardStringContext";
  unsafeGetAttrPos = "builtins.unsafeGetAttrPos";
  addErrorContext = "builtins.addErrorContext";
  appendContext = "builtins.appendContext";
  getContext = "builtins.getContext";
  derivationStrict = "builtins.derivationStrict";
  placeholder = "builtins.placeholder";
  fetchurl = "builtins.fetchurl";
  fetchTarball = "builtins.fetchTarball";
  fetchGit = "builtins.fetchGit";
  toFile = "builtins.toFile";
  filterSource = "builtins.filterSource";
  path = "builtins.path";
  storeDir = "builtins.storeDir";
  nixVersion = "builtins.nixVersion";
  currentSystem = "builtins.currentSystem";
  currentTime = "builtins.currentTime";
  langVersion = "builtins.langVersion";
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
