# C++ implementations of Nix primops.
#
# Each is a string of C++ code evaluating to a Value::lambda (curried).

{
  sub = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return __wb_sub(a, b);
      });
    })
  '';

  lessThan = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return Value::fromBool(a < b);
      });
    })
  '';

  elemAt = ''
    Value::lambda([](Value list) {
      return Value::lambda([list](Value index) {
        return list.at(index.asInt());
      });
    })
  '';

  filter = ''
    Value::lambda([](Value func) {
      return Value::lambda([func](Value list) {
        return list.filter(func);
      });
    })
  '';

  map = ''
    Value::lambda([](Value func) {
      return Value::lambda([func](Value list) {
        return list.map(func);
      });
    })
  '';

  foldl' = ''
    Value::lambda([](Value op) {
      return Value::lambda([op](Value acc) {
        return Value::lambda([op, acc](Value list) {
          return list.foldl(op, acc);
        });
      });
    })
  '';

  head = ''
    Value::lambda([](Value list) {
      return list.head();
    })
  '';

  tail = ''
    Value::lambda([](Value list) {
      return list.tail();
    })
  '';

  length = ''
    Value::lambda([](Value list) {
      return Value::fromInt(list.length());
    })
  '';

  typeOf = ''
    Value::lambda([](Value e) {
      return Value::fromString(e.typeOf());
    })
  '';

  toString = ''
    Value::lambda([](Value e) {
      return Value::fromString(e.toString());
    })
  '';

  toJSON = ''
    Value::lambda([](Value e) {
      return Value::fromString(e.toJSON());
    })
  '';

  fromJSON = ''
    Value::lambda([](Value s) {
      return Value::fromJSON(s.asString());
    })
  '';

  concatStringsSep = ''
    Value::lambda([](Value sep) {
      return Value::lambda([sep](Value list) {
        return list.concatStringsSep(sep.asString());
      });
    })
  '';

  hasAttr = ''
    Value::lambda([](Value attr) {
      return Value::lambda([attr](Value s) {
        return Value::fromBool(s.hasAttr(attr.asString()));
      });
    })
  '';

  getAttr = ''
    Value::lambda([](Value attr) {
      return Value::lambda([attr](Value s) {
        return s[attr.asString()];
      });
    })
  '';

  attrNames = ''
    Value::lambda([](Value s) {
      return s.attrNames();
    })
  '';

  attrValues = ''
    Value::lambda([](Value s) {
      return s.attrValues();
    })
  '';

  isNull = "Value::lambda([](Value e) { return Value::fromBool(e.isNull()); })";
  isInt = "Value::lambda([](Value e) { return Value::fromBool(e.isInt()); })";
  isFloat = "Value::lambda([](Value e) { return Value::fromBool(e.isFloat()); })";
  isString = "Value::lambda([](Value e) { return Value::fromBool(e.isString()); })";
  isBool = "Value::lambda([](Value e) { return Value::fromBool(e.isBool()); })";
  isList = "Value::lambda([](Value e) { return Value::fromBool(e.isList()); })";
  isAttrs = "Value::lambda([](Value e) { return Value::fromBool(e.isAttrs()); })";
  isFunction = "Value::lambda([](Value e) { return Value::fromBool(e.isFunction()); })";
  isPath = "Value::lambda([](Value) { return Value::fromBool(false); })";

  functionArgs = "Value::lambda([](Value f) -> Value { return f.functionArgs(); })";

  genList = ''
    Value::lambda([](Value func) {
      return Value::lambda([func](Value count) {
        return Value::genList(func, count.asInt());
      });
    })
  '';

  all = ''
    Value::lambda([](Value func) {
      return Value::lambda([func](Value list) {
        return Value::fromBool(list.all(func));
      });
    })
  '';

  any = ''
    Value::lambda([](Value func) {
      return Value::lambda([func](Value list) {
        return Value::fromBool(list.any(func));
      });
    })
  '';

  concatMap = ''
    Value::lambda([](Value func) {
      return Value::lambda([func](Value list) {
        return list.concatMap(func);
      });
    })
  '';

  elem = ''
    Value::lambda([](Value item) {
      return Value::lambda([item](Value list) {
        return Value::fromBool(list.elem(item));
      });
    })
  '';

  removeAttrs = ''
    Value::lambda([](Value s) {
      return Value::lambda([s](Value names) {
        return s.removeAttrs(names);
      });
    })
  '';

  listToAttrs = ''
    Value::lambda([](Value list) {
      Value::Set r;
      for (const auto& e : list.asList()) {
        auto name = e["name"];
        if (!name.isNull()) r[name.asString()] = e["value"];
      }
      return Value::fromSet(std::move(r));
    })
  '';

  trace = ''
    Value::lambda([](Value msg) {
      return Value::lambda([msg](Value val) {
        std::cerr << "[trace] " << msg.asString() << std::endl;
        return val;
      });
    })
  '';

  seq = ''
    Value::lambda([](Value a) {
      return Value::lambda([](Value b) {
        return b;
      });
    })
  '';

  abort = ''
    Value::lambda([](Value msg) -> Value {
      throw std::runtime_error("abort: " + msg.asString());
    })
  '';

  throw = ''
    Value::lambda([](Value msg) -> Value {
      throw std::runtime_error(msg.asString());
    })
  '';

  mul = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return __wb_mul(a, b);
      });
    })
  '';

  div = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return __wb_div(a, b);
      });
    })
  '';

  add = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return __wb_add(a, b);
      });
    })
  '';

  sort = ''
    Value::lambda([](Value cmp) {
      return Value::lambda([cmp](Value list) {
        return list.sort(cmp);
      });
    })
  '';

  substring = ''
    Value::lambda([](Value start) {
      return Value::lambda([start](Value len) {
        return Value::lambda([start, len](Value str) {
          return Value::fromString(str.asString().substr(start.asInt(), len.asInt()));
        });
      });
    })
  '';

  stringLength = ''
    Value::lambda([](Value str) {
      return Value::fromInt(str.asString().length());
    })
  '';

  replaceStrings = ''
    Value::lambda([](Value from) {
      return Value::lambda([from](Value to) {
        return Value::lambda([from, to](Value str) {
          return str.replaceStrings(from, to);
        });
      });
    })
  '';

  mapAttrs = ''
    Value::lambda([](Value f) {
      return Value::lambda([f](Value s) {
        return s.mapAttrs(f);
      });
    })
  '';

  ceil = "Value::lambda([](Value x) { return Value::fromInt(x.ceil()); })";
  floor = "Value::lambda([](Value x) { return Value::fromInt(x.floor()); })";

  bitAnd = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return Value::fromInt(a.asInt() & b.asInt());
      });
    })
  '';

  bitOr = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return Value::fromInt(a.asInt() | b.asInt());
      });
    })
  '';

  bitXor = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return Value::fromInt(a.asInt() ^ b.asInt());
      });
    })
  '';

  intersectAttrs = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        return a.intersectAttrs(b);
      });
    })
  '';

  catAttrs = ''
    Value::lambda([](Value attr) {
      return Value::lambda([attr](Value list) {
        return list.catAttrs(attr.asString());
      });
    })
  '';

  groupBy = ''
    Value::lambda([](Value f) {
      return Value::lambda([f](Value list) {
        return list.groupBy(f);
      });
    })
  '';

  partition = ''
    Value::lambda([](Value pred) {
      return Value::lambda([pred](Value list) {
        return list.partition(pred);
      });
    })
  '';

  tryEval = ''
    Value::lambda([](Value e) {
      try {
        auto v = e;
        return Value::fromSet({{"success", Value::fromBool(true)}, {"value", v}});
      } catch(...) {
        return Value::fromSet({{"success", Value::fromBool(false)}, {"value", Value::fromBool(false)}});
      }
    })
  '';

  warn = ''
    Value::lambda([](Value msg) {
      return Value::lambda([msg](Value val) {
        std::cerr << "[warn] " << msg.asString() << std::endl;
        return val;
      });
    })
  '';

  concatLists = ''
    Value::lambda([](Value lists) {
      Value::List r;
      for (const auto& l : lists.asList()) {
        const auto& sub = l.asList();
        r.insert(r.end(), sub.begin(), sub.end());
      }
      return Value::fromList(std::move(r));
    })
  '';

  deepSeq = ''
    Value::lambda([](Value a) {
      return Value::lambda([a](Value b) {
        a.toJSON();
        return b;
      });
    })
  '';

  null = "Value::null_()";
  true = "Value::fromBool(true)";
  false = "Value::fromBool(false)";


  hashString = ''
    Value::lambda([](Value) {
      return Value::lambda([](Value str) {
        auto s = str.asString();
        unsigned long hash = 5381;
        for (char c : s) hash = ((hash << 5) + hash) + c;
        char buf[17]; snprintf(buf, sizeof(buf), "%016lx", hash);
        return Value::fromString(std::string(buf));
      });
    })
  '';

  genericClosure = ''
    Value::lambda([](Value args) {
      auto startSet = args["startSet"].asList();
      auto op = args["operator"];
      Value::List result;
      std::set<std::string> seen;
      std::deque<Value> work(startSet.begin(), startSet.end());
      while (!work.empty()) {
        auto item = work.front();
        work.pop_front();
        auto key = item["key"].toJSON();
        if (seen.count(key)) continue;
        seen.insert(key);
        result.push_back(item);
        auto expanded = (op)(item);
        const auto& newItems = expanded.asList();
        work.insert(work.end(), newItems.begin(), newItems.end());
      }
      return Value::fromList(std::move(result));
    })
  '';

  addErrorContext = ''
    Value::lambda([](Value) {
      return Value::lambda([](Value val) {
        return val;
      });
    })
  '';
}
