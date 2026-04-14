# TypeScript implementations of Nix primops.
#
# Imports the JavaScript primops and overrides only those that need
# TypeScript-specific type annotations (e.g. generic Set constructors).

let
  jsPrimops = import ./javascript.nix;
in
jsPrimops
// {
  zipAttrsWith = ''
    Value.lambda(f => Value.lambda(list => {
      const sets = list.asList().map(s => s.asSet());
      const allKeys = new Set<string>();
      for (const s of sets)
        for (const k of Object.keys(s))
          allKeys.add(k);
      const factories: Record<string, () => Value> = {};
      for (const k of allKeys) {
        const key = k;
        factories[key] = () => {
          const vals: Value[] = [];
          for (const s of sets)
            if (key in s) vals.push(s[key]);
          return f.call(Value.fromString(key)).call(Value.fromList(vals));
        };
      }
      return Value.lazySet(factories);
    }))
  '';

  genericClosure = ''
    Value.lambda(args => {
      const startSet = args.get("startSet").asList();
      const op = args.get("operator");
      const result: Value[] = [];
      const seen = new Set<string>();
      const work = [...startSet];
      while (work.length > 0) {
        const item = work.shift()!;
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
}
