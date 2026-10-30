# Stable, bounded compilation batches. Split a binary hash trie only where a
# bucket exceeds batchSize, so adding a unit cannot shift unrelated batches.
# Chunks of large SCCs bypass batching and get one derivation each.
{
  units,
  batchSize,
}:
let
  hexBits = {
    "0" = "0000";
    "1" = "0001";
    "2" = "0010";
    "3" = "0011";
    "4" = "0100";
    "5" = "0101";
    "6" = "0110";
    "7" = "0111";
    "8" = "1000";
    "9" = "1001";
    a = "1010";
    b = "1011";
    c = "1100";
    d = "1101";
    e = "1110";
    f = "1111";
  };

  sortedUnits = builtins.sort (a: b: a.fileName < b.fileName) units;
  chunkedUnits = builtins.filter (unit: unit.isChunked or false) sortedUnits;
  unchunkedUnits = builtins.filter (unit: !(unit.isChunked or false)) sortedUnits;

  entries = builtins.map (unit: {
    inherit unit;
    hash = builtins.hashString "sha256" unit.fileName;
  }) unchunkedUnits;

  standaloneChunks = builtins.map (unit: {
    id = "chunk-${builtins.substring 0 16 (builtins.hashString "sha256" unit.fileName)}";
    units = [ unit ];
  }) chunkedUnits;

  leaf = prefix: items: {
    id = if prefix == "" then "root" else builtins.substring 0 16 (builtins.hashString "sha256" prefix);
    units = builtins.map (entry: entry.unit) items;
  };

  split =
    prefix: items:
    let
      count = builtins.length items;
      depth = builtins.stringLength prefix;
      buckets = builtins.groupBy (
        entry:
        let
          digit = builtins.substring (builtins.div depth 4) 1 entry.hash;
        in
        builtins.substring (builtins.bitAnd depth 3) 1 hexBits.${digit}
      ) items;
    in
    if count == 0 then
      [ ]
    else if count <= batchSize then
      [ (leaf prefix items) ]
    else if depth == 256 then
      # Bound batches even in the event of identical keys / hash collisions.
      builtins.genList (
        index:
        let
          remaining = count - index * batchSize;
        in
        leaf "${prefix}-${toString index}" (
          builtins.genList (offset: builtins.elemAt items (index * batchSize + offset)) (
            if remaining < batchSize then remaining else batchSize
          )
        )
      ) (builtins.div (count + batchSize - 1) batchSize)
    else
      builtins.concatMap (bit: split (prefix + bit) buckets.${bit}) (builtins.attrNames buckets);
in
if !builtins.isInt batchSize || batchSize < 1 then
  throw "wechselbalg: compileBatchSize must be a positive integer"
else
  split "" entries ++ standaloneChunks
