# C++ implementations of Nix primops.
#
# Each is a string of C++ code evaluating to a Value::lambda (curried).

{
wasm = ''
    Value::lambda([](const Value& config) {
      return Value::lambda([config](const Value& args) -> Value {
        // ScopeGuard helper for RAII cleanup
        struct ScopeGuard {
          std::function<void()> cleanup;
          ~ScopeGuard() { if (cleanup) cleanup(); }
        };

        auto formatError = [](wasmtime_error_t* err, wasm_trap_t* trap, const std::string& fallback) -> std::string {
          if (err) {
            wasm_byte_vec_t msg;
            wasmtime_error_message(err, &msg);
            std::string s(msg.data, msg.size);
            wasm_byte_vec_delete(&msg);
            wasmtime_error_delete(err);
            return s;
          }
          if (trap) {
            wasm_byte_vec_t msg;
            wasm_trap_message(trap, &msg);
            std::string s(msg.data, msg.size);
            wasm_byte_vec_delete(&msg);
            wasm_trap_delete(trap);
            return s;
          }
          return fallback;
        };

        // 1. Thread-safe Engine & Module Cache
        static wasm_engine_t* engine = wasm_engine_new();
        static std::mutex cache_mutex;
        static std::unordered_map<std::string, wasmtime_module_t*> module_cache;

        auto conf = config.asSet();
        std::string base64Str = conf.count("bytecode") ? conf.at("bytecode").asString()
                                : conf.count("base64")   ? conf.at("base64").asString()
                                : "";
        std::string fname = conf.count("fname")        ? conf.at("fname").asString()
                            : conf.count("function")   ? conf.at("function").asString()
                            : "";

        if (base64Str.empty() || fname.empty()) {
          throw std::runtime_error("builtins.wasm requires 'bytecode'/'base64' and 'fname'/'function'");
        }

        // 2. Fetch or compile module
        wasmtime_module_t* module = nullptr;
        {
          std::lock_guard<std::mutex> lock(cache_mutex);
          auto it = module_cache.find(base64Str);
          if (it != module_cache.end()) {
            module = it->second;
          } else {
            std::vector<uint8_t> wasmBytes = __wb_base64_decode(base64Str);
            wasmtime_error_t* err = wasmtime_module_new(engine, wasmBytes.data(), wasmBytes.size(), &module);
            if (err) {
              throw std::runtime_error("Failed to compile WebAssembly module: " + formatError(err, nullptr, ""));
            }
            module_cache[base64Str] = module;
          }
        }

        // 3. Isolated Store & Context per call (RAII managed)
        wasmtime_store_t* store = wasmtime_store_new(engine, nullptr, nullptr);
        ScopeGuard storeGuard{[&]() { wasmtime_store_delete(store); }};
        wasmtime_context_t* context = wasmtime_store_context(store);

        wasi_config_t* wasi_config = wasi_config_new();
        wasi_config_inherit_stdout(wasi_config);
        wasi_config_inherit_stderr(wasi_config);
        wasmtime_error_t* wasi_err = wasmtime_context_set_wasi(context, wasi_config);
        if (wasi_err) {
          throw std::runtime_error("WASI context setup failed: " + formatError(wasi_err, nullptr, ""));
        }

        wasmtime_linker_t* linker = wasmtime_linker_new(engine);
        ScopeGuard linkerGuard{[&]() { wasmtime_linker_delete(linker); }};

        wasmtime_error_t* link_err = wasmtime_linker_define_wasi(linker);
        if (link_err) {
          throw std::runtime_error("WASI linker setup failed: " + formatError(link_err, nullptr, ""));
        }

        wasmtime_instance_t instance;
        wasm_trap_t* trap = nullptr;
        wasmtime_error_t* error = wasmtime_linker_instantiate(linker, context, module, &instance, &trap);
        if (error || trap) {
          throw std::runtime_error("Failed to instantiate WebAssembly module: " + formatError(error, trap, ""));
        }

        // 4. Exports lookup
        wasmtime_extern_t mem_ext, malloc_ext, fn_ext;
        if (!wasmtime_instance_export_get(context, &instance, "memory", 6, &mem_ext) ||
            mem_ext.kind != WASMTIME_EXTERN_MEMORY) {
          throw std::runtime_error("Wasm module must export 'memory'");
        }
        wasmtime_memory_t memory = mem_ext.of.memory;

        bool has_alloc = wasmtime_instance_export_get(context, &instance, "malloc", 6, &malloc_ext);
        if (!has_alloc) {
          has_alloc = wasmtime_instance_export_get(context, &instance, "__wb_alloc", 10, &malloc_ext);
        }
        if (!has_alloc || malloc_ext.kind != WASMTIME_EXTERN_FUNC) {
          throw std::runtime_error("Wasm module must export an allocator ('malloc' or '__wb_alloc')");
        }
        wasmtime_func_t malloc_fn = malloc_ext.of.func;

        if (!wasmtime_instance_export_get(context, &instance, fname.c_str(), fname.size(), &fn_ext) ||
            fn_ext.kind != WASMTIME_EXTERN_FUNC) {
          throw std::runtime_error("Wasm export '" + fname + "' is not a function");
        }
        wasmtime_func_t target_fn = fn_ext.of.func;

        // 5. Serialize input & bounds-checked allocation
        std::string inStr = args.isString() ? args.asString() : args.toJSON();
        inStr.push_back('\0');

        wasmtime_val_t malloc_arg { .kind = WASMTIME_I32, .of = { .i32 = static_cast<int32_t>(inStr.size()) } };
        wasmtime_val_t malloc_ret;
        error = wasmtime_func_call(context, &malloc_fn, &malloc_arg, 1, &malloc_ret, 1, &trap);
        if (error || trap) {
          throw std::runtime_error("Wasm malloc failed: " + formatError(error, trap, ""));
        }
        int32_t inPtr = malloc_ret.of.i32;

        uint8_t* memData = wasmtime_memory_data(context, &memory);
        size_t memSize = wasmtime_memory_data_size(context, &memory);

        // Bounds check (Fix 1.3)
        if (inPtr <= 0 || static_cast<size_t>(inPtr) + inStr.size() > memSize) {
          throw std::runtime_error("Wasm malloc returned invalid or out-of-bounds pointer: " + std::to_string(inPtr));
        }
        std::copy_n(inStr.data(), inStr.size(), memData + inPtr);

        // 6. Inspect function signature (Fix 1.2 & 2.1)
        wasm_functype_t* fnType = wasmtime_func_type(context, &target_fn);
        ScopeGuard fnTypeGuard{[&]() { wasm_functype_delete(fnType); }};
        size_t paramCount = wasm_functype_params(fnType)->size;

        if (paramCount > 2) {
          throw std::runtime_error("Wasm function '" + fname + "' takes " + std::to_string(paramCount) +
                                   " parameters, but Wechselbalg ABI expects 1 (ptr) or 2 (ptr, len)");
        }

        wasmtime_val_t callArgs[2];
        if (paramCount >= 1) {
          callArgs[0] = { .kind = WASMTIME_I32, .of = { .i32 = inPtr } };
        }
        if (paramCount == 2) {
          callArgs[1] = { .kind = WASMTIME_I32, .of = { .i32 = static_cast<int32_t>(inStr.size() - 1) } };
        }

        wasmtime_val_t retVal;
        error = wasmtime_func_call(context, &target_fn, callArgs, paramCount, &retVal, 1, &trap);
        if (error || trap) {
          throw std::runtime_error("Execution of Wasm function '" + fname + "' failed: " + formatError(error, trap, ""));
        }
        int32_t outPtr = retVal.of.i32;

        // 7. Read output string
        std::string outJsonStr;
        if (outPtr != 0) {
          memData = wasmtime_memory_data(context, &memory);
          memSize = wasmtime_memory_data_size(context, &memory);
          if (static_cast<size_t>(outPtr) >= memSize) {
            throw std::runtime_error("Wasm function returned out-of-bounds pointer: " + std::to_string(outPtr));
          }
          for (size_t p = outPtr; p < memSize && memData[p] != 0; ++p) {
            outJsonStr.push_back(static_cast<char>(memData[p]));
          }
        }

        if (outPtr == 0) return Value::null_();

        try {
          return Value::fromJSON(outJsonStr);
        } catch (...) {
          return Value::fromString(outJsonStr);
        }
      });
    })
  '';
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

  # ── AST introspection (self-hosting) ──────────────────────────
  reify = ''
    Value::lambda([](const Value& f) { return Value::reify(f); })
  '';

  sameFunction = ''
    Value::lambda([](const Value& a) {
      return Value::lambda([a](const Value& b) {
        return Value::fromBool(Value::sameFunction(a, b));
      });
    })
  '';
}
