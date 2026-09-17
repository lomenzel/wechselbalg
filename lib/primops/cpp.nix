# C++ implementations of Nix primops.
#
# Each is a string of C++ code evaluating to a Value::lambda (curried).

{
  sub = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return __wb_sub(a, b);
      });
    })
  '';

  lessThan = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return Value::fromBool(a < b);
      });
    })
  '';

  elemAt = ''
    Value::lambda([](const Value& list) {
      return Value::lambda([list](const Value& index) {
        return list.at(index.asInt());
      });
    })
  '';

  filter = ''
    Value::lambda([](const Value& func) {
      return Value::lambda([func](const Value& list) {
        return list.filter(func);
      });
    })
  '';

  map = ''
    Value::lambda([](const Value& func) {
      return Value::lambda([func](const Value& list) {
        return list.map(func);
      });
    })
  '';

  foldl' = ''
    Value::lambda([](const Value& op) {
      return Value::lambda([op](const Value& acc) {
        return Value::lambda([op, acc](const Value& list) {
          return list.foldl(op, acc);
        });
      });
    })
  '';

  head = ''
    Value::lambda([](const Value& list) {
      return list.head();
    })
  '';

  tail = ''
    Value::lambda([](const Value& list) {
      return list.tail();
    })
  '';

  length = ''
    Value::lambda([](const Value& list) {
      return Value::fromInt(list.length());
    })
  '';

  typeOf = ''
    Value::lambda([](const Value& e) {
      return Value::fromString(e.typeOf());
    })
  '';

  toString = ''
    Value::lambda([](const Value& e) {
      return Value::fromString(e.toString());
    })
  '';

  toJSON = ''
    Value::lambda([](const Value& e) {
      return Value::fromString(e.toJSON());
    })
  '';

  fromJSON = ''
    Value::lambda([](const Value& s) {
      return Value::fromJSON(s.asString());
    })
  '';

  concatStringsSep = ''
    Value::lambda([](const Value& sep) {
      return Value::lambda([sep](const Value& list) {
        return list.concatStringsSep(sep.asString());
      });
    })
  '';

  hasAttr = ''
    Value::lambda([](const Value& attr) {
      return Value::lambda([attr](const Value& s) {
        return Value::fromBool(s.hasAttr(attr.asString()));
      });
    })
  '';

  getAttr = ''
    Value::lambda([](const Value& attr) {
      return Value::lambda([attr](const Value& s) {
        return s[attr.asString()];
      });
    })
  '';

  attrNames = ''
    Value::lambda([](const Value& s) {
      return s.attrNames();
    })
  '';

  attrValues = ''
    Value::lambda([](const Value& s) {
      return s.attrValues();
    })
  '';

  isNull = "Value::lambda([](const Value& e) { return Value::fromBool(e.isNull()); })";
  isInt = "Value::lambda([](const Value& e) { return Value::fromBool(e.isInt()); })";
  isFloat = "Value::lambda([](const Value& e) { return Value::fromBool(e.isFloat()); })";
  isString = "Value::lambda([](const Value& e) { return Value::fromBool(e.isString()); })";
  isBool = "Value::lambda([](const Value& e) { return Value::fromBool(e.isBool()); })";
  isList = "Value::lambda([](const Value& e) { return Value::fromBool(e.isList()); })";
  isAttrs = "Value::lambda([](const Value& e) { return Value::fromBool(e.isAttrs()); })";
  isFunction = "Value::lambda([](const Value& e) { return Value::fromBool(e.isFunction()); })";
  isPath = "Value::lambda([](const Value&) { return Value::fromBool(false); })";

  functionArgs = "Value::lambda([](const Value& f) -> Value { return f.functionArgs(); })";

  genList = ''
    Value::lambda([](const Value& func) {
      return Value::lambda([func](const Value& count) {
        return Value::genList(func, count.asInt());
      });
    })
  '';

  all = ''
    Value::lambda([](const Value& func) {
      return Value::lambda([func](const Value& list) {
        return Value::fromBool(list.all(func));
      });
    })
  '';

  any = ''
    Value::lambda([](const Value& func) {
      return Value::lambda([func](const Value& list) {
        return Value::fromBool(list.any(func));
      });
    })
  '';

  concatMap = ''
    Value::lambda([](const Value& func) {
      return Value::lambda([func](const Value& list) {
        return list.concatMap(func);
      });
    })
  '';

  elem = ''
    Value::lambda([](const Value& item) {
      return Value::lambda([item](const Value& list) {
        return Value::fromBool(list.elem(item));
      });
    })
  '';

  removeAttrs = ''
    Value::lambda([](const Value& s) {
      return Value::lambda([s](const Value& names) {
        return s.removeAttrs(names);
      });
    })
  '';

  listToAttrs = ''
    Value::lambda([](const Value& list) {
      Value::Set r;
      for (const auto& e : list.asList()) {
        auto name = e["name"];
        if (!name.isNull()) r[name.asString()] = e["value"];
      }
      return Value::fromSet(std::move(r));
    })
  '';

  trace = ''
    Value::lambda([](const Value& msg) {
      return Value::lambda([msg](const Value& val) {
        std::cerr << "[trace] " << msg.asString() << std::endl;
        return val;
      });
    })
  '';

  seq = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        a.force();
        return b;
      });
    })
  '';

  abort = ''
    Value::lambda([](const Value& msg) -> Value {
      throw std::runtime_error("abort: " + msg.asString());
    })
  '';

  throw = ''
    Value::lambda([](const Value& msg) -> Value {
      throw std::runtime_error(msg.asString());
    })
  '';

  mul = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return __wb_mul(a, b);
      });
    })
  '';

  div = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return __wb_div(a, b);
      });
    })
  '';

  add = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return __wb_add(a, b);
      });
    })
  '';

  sort = ''
    Value::lambda([](const Value& cmp) {
      return Value::lambda([cmp](const Value& list) {
        return list.sort(cmp);
      });
    })
  '';

  substring = ''
    Value::lambda([](const Value& start) {
      return Value::lambda([start](const Value& len) {
        return Value::lambda([start, len](const Value& str) {
          int64_t st = start.asInt();
          int64_t l = len.asInt();
          const std::string& s = str.asString();
          if (st < 0 || st >= (int64_t)s.size()) return Value::fromString("");
          if (l < 0) return Value::fromString(s.substr(st));
          return Value::fromString(s.substr(st, l));
        });
      });
    })
  '';

  stringLength = ''
    Value::lambda([](const Value& str) {
      return Value::fromInt(str.asString().length());
    })
  '';

  replaceStrings = ''
    Value::lambda([](const Value& from) {
      return Value::lambda([from](const Value& to) {
        return Value::lambda([from, to](const Value& str) {
          return str.replaceStrings(from, to);
        });
      });
    })
  '';

  match = ''
    Value::lambda([](const Value& regex) {
      return Value::lambda([regex](const Value& str) {
        std::regex re("^(?:" + regex.asString() + ")$");
        std::smatch m;
        std::string s = str.asString();
        if (!std::regex_match(s, m, re)) return Value::null_();
        Value::List list;
        for (size_t i = 1; i < m.size(); ++i) {
          if (!m[i].matched) list.push_back(Value::null_());
          else list.push_back(Value::fromString(m[i].str()));
        }
        return Value::fromList(list);
      });
    })
  '';

  split = ''
    Value::lambda([](const Value& regex) {
      return Value::lambda([regex](const Value& str) {
        std::regex re(regex.asString());
        std::string s = str.asString();
        Value::List parts;
        auto begin = std::sregex_iterator(s.begin(), s.end(), re);
        auto end = std::sregex_iterator();
        size_t lastIndex = 0;
        for (auto it = begin; it != end; ++it) {
          const auto& match = *it;
          parts.push_back(Value::fromString(s.substr(lastIndex, match.position() - lastIndex)));
          Value::List captures;
          for (size_t i = 1; i < match.size(); ++i) {
            if (!match[i].matched) captures.push_back(Value::null_());
            else captures.push_back(Value::fromString(match[i].str()));
          }
          parts.push_back(Value::fromList(captures));
          lastIndex = match.position() + match.length();
        }
        parts.push_back(Value::fromString(s.substr(lastIndex)));
        return Value::fromList(parts);
      });
    })
  '';

  mapAttrs = ''
    Value::lambda([](const Value& f) {
      return Value::lambda([f](const Value& s) {
        return s.mapAttrs(f);
      });
    })
  '';

  zipAttrsWith = ''
    Value::lambda([](const Value& f) {
      return Value::lambda([f](const Value& list) {
        auto sets = list.asList();
        std::set<std::string> allKeys;
        for (const auto& s : sets)
          for (const auto& kv : s.asSet())
            allKeys.insert(kv.first);
        Value::Set r;
        for (const auto& k : allKeys) {
          auto key = k;
          auto func = f;
          auto setsRef = sets;
          r[key] = Value::thunk([func, key, setsRef]() {
            Value::List vals;
            for (const auto& s : setsRef) {
              const auto& m = s.asSet();
              auto it = m.find(key);
              if (it != m.end()) vals.push_back(it->second);
            }
            return func(Value::fromString(key))(Value::fromList(std::move(vals)));
          });
        }
        return Value::fromSet(std::move(r));
      });
    })
  '';

  ceil = "Value::lambda([](const Value& x) { return Value::fromInt(x.ceil()); })";
  floor = "Value::lambda([](const Value& x) { return Value::fromInt(x.floor()); })";

  bitAnd = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return Value::fromInt(a.asInt() & b.asInt());
      });
    })
  '';

  bitOr = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return Value::fromInt(a.asInt() | b.asInt());
      });
    })
  '';

  bitXor = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return Value::fromInt(a.asInt() ^ b.asInt());
      });
    })
  '';

  intersectAttrs = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return a.intersectAttrs(b);
      });
    })
  '';

  catAttrs = ''
    Value::lambda([](const Value& attr) {
      return Value::lambda([attr](const Value& list) {
        return list.catAttrs(attr.asString());
      });
    })
  '';

  groupBy = ''
    Value::lambda([](const Value& f) {
      return Value::lambda([f](const Value& list) {
        return list.groupBy(f);
      });
    })
  '';

  partition = ''
    Value::lambda([](const Value& pred) {
      return Value::lambda([pred](const Value& list) {
        return list.partition(pred);
      });
    })
  '';

  tryEval = ''
    Value::lambda([](const Value& e) {
      try {
        e.force();
        return Value::fromSet({{"success", Value::fromBool(true)}, {"value", e}});
      } catch(...) {
        return Value::fromSet({{"success", Value::fromBool(false)}, {"value", Value::fromBool(false)}});
      }
    })
  '';

  warn = ''
    Value::lambda([](const Value& msg) {
      return Value::lambda([msg](const Value& val) {
        std::cerr << "[warn] " << msg.asString() << std::endl;
        return val;
      });
    })
  '';

  concatLists = ''
    Value::lambda([](const Value& lists) {
      Value::List r;
      for (const auto& l : lists.asList()) {
        const auto& sub = l.asList();
        r.insert(r.end(), sub.begin(), sub.end());
      }
      return Value::fromList(std::move(r));
    })
  '';

  deepSeq = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        // Recursive helper to deeply evaluate the value
        std::function<void(const Value&)> deepForce;
        deepForce = [&deepForce](const Value& val) {
          val.force(); // Evaluate to WHNF
          
          // If it's a collection, recursively force its contents
          if (val.isList()) {
            for (const auto& item : val.asList()) {
              deepForce(item);
            }
          } else if (val.isSet()) {
            for (const auto& kv : val.asSet()) {
              deepForce(kv.second);
            }
          }
          // Int, Float, String, Bool, Null, and Lambdas require no further action
        };

        deepForce(a);
        return b;
      });
    })
  '';

  null = "Value::null_()";
  true = "Value::fromBool(true)";
  false = "Value::fromBool(false)";

  hashString = ''
    Value::lambda([](const Value&) {
      return Value::lambda([](const Value& str) {
        auto s = str.asString();
        unsigned long hash = 5381;
        for (char c : s) hash = ((hash << 5) + hash) + c;
        char buf[17]; snprintf(buf, sizeof(buf), "%016lx", hash);
        return Value::fromString(std::string(buf));
      });
    })
  '';

  genericClosure = ''
    Value::lambda([](const Value& args) {
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
    Value::lambda([](const Value&) {
      return Value::lambda([](const Value& val) {
        return val;
      });
    })
  '';
}
