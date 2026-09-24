{
  add = "Value::lambda(|a| Value::lambda(move |b| a.add(&b)))";
  sub = "Value::lambda(|a| Value::lambda(move |b| a.sub(&b)))";
  mul = "Value::lambda(|a| Value::lambda(move |b| a.mul(&b)))";
  div = "Value::lambda(|a| Value::lambda(move |b| a.div(&b)))";
  lessThan = "Value::lambda(|a| Value::lambda(move |b| Value::from_bool(a.lt(&b))))";

  # ── Collections ───────────────────────────────────────────────
  map = ''
    Value::lambda(|func| {
      Value::lambda(move |list| {
        let f = func.clone();
        let res: Vec<Value> = list.as_list().iter().map(|item| f.call(item.clone())).collect();
        Value::from_list(res)
      })
    })
  '';

  filter = ''
    Value::lambda(|func| {
      Value::lambda(move |list| {
        let f = func.clone();
        let res: Vec<Value> = list
          .as_list()
          .iter()
          .filter(|item| f.call((*item).clone()).as_bool())
          .cloned()
          .collect();
        Value::from_list(res)
      })
    })
  '';

  "foldl'" = ''
    Value::lambda(|op| {
      Value::lambda(move |acc| {
        let op = op.clone();
        Value::lambda(move |list| {
          let mut cur = acc.clone();
          for item in list.as_list().iter() {
            cur = op.call(cur).call(item.clone());
          }
          cur
        })
      })
    })
  '';

  head = "Value::lambda(|list| list.as_list()[0].clone())";
  tail = "Value::lambda(|list| Value::from_list(list.as_list()[1..].to_vec()))";
  length = "Value::lambda(|list| Value::from_int(list.as_list().len() as i64))";
  elemAt = "Value::lambda(|list| Value::lambda(move |idx| list.as_list()[idx.as_int() as usize].clone()))";

  concatLists = ''
    Value::lambda(|lists| {
      let mut out = Vec::new();
      for sub in lists.as_list().iter() {
        out.extend(sub.as_list().iter().cloned());
      }
      Value::from_list(out)
    })
  '';

  concatMap = ''
    Value::lambda(|func| {
      Value::lambda(move |list| {
        let mut out = Vec::new();
        for item in list.as_list().iter() {
          let mapped = func.call(item.clone());
          out.extend(mapped.as_list().iter().cloned());
        }
        Value::from_list(out)
      })
    })
  '';

  all = ''
    Value::lambda(|func| {
      Value::lambda(move |list| {
        let res = list.as_list().iter().all(|item| func.call(item.clone()).as_bool());
        Value::from_bool(res)
      })
    })
  '';

  any = ''
    Value::lambda(|func| {
      Value::lambda(move |list| {
        let res = list.as_list().iter().any(|item| func.call(item.clone()).as_bool());
        Value::from_bool(res)
      })
    })
  '';

  elem = ''
    Value::lambda(|item| {
      Value::lambda(move |list| {
        let res = list.as_list().iter().any(|x| x.deep_eq(&item));
        Value::from_bool(res)
      })
    })
  '';

  genList = ''
    Value::lambda(|func| {
      Value::lambda(move |count| {
        let n = count.as_int();
        let mut items = Vec::with_capacity(n as usize);
        for i in 0..n {
          items.push(func.call(Value::from_int(i)));
        }
        Value::from_list(items)
      })
    })
  '';

  sort = ''
    Value::lambda(|cmp| {
      Value::lambda(move |list| {
        let mut items = (*list.as_list()).clone();
        items.sort_by(|a, b| {
          if cmp.call(a.clone()).call(b.clone()).as_bool() {
            std::cmp::Ordering::Less
          } else if cmp.call(b.clone()).call(a.clone()).as_bool() {
            std::cmp::Ordering::Greater
          } else {
            std::cmp::Ordering::Equal
          }
        });
        Value::from_list(items)
      })
    })
  '';

  partition = ''
    Value::lambda(|pred| {
      Value::lambda(move |list| {
        let mut right = Vec::new();
        let mut wrong = Vec::new();
        for item in list.as_list().iter() {
          if pred.call(item.clone()).as_bool() {
            right.push(item.clone());
          } else {
            wrong.push(item.clone());
          }
        }
        Value::from_set(vec![
          ("right".to_string(), Value::from_list(right)),
          ("wrong".to_string(), Value::from_list(wrong)),
        ])
      })
    })
  '';

  groupBy = ''
    Value::lambda(|f| {
      Value::lambda(move |list| {
        let mut map: std::collections::BTreeMap<String, Vec<Value>> = std::collections::BTreeMap::new();
        for item in list.as_list().iter() {
          let k = f.call(item.clone()).as_str().to_string();
          map.entry(k).or_default().push(item.clone());
        }
        let entries = map.into_iter().map(|(k, v)| (k, Value::from_list(v))).collect();
        Value::from_set(entries)
      })
    })
  '';

  # ── Attrsets ──────────────────────────────────────────────────
  hasAttr = "Value::lambda(|attr| Value::lambda(move |s| Value::from_bool(s.has_attr(attr.as_str().as_str()))))";
  getAttr = "Value::lambda(|attr| Value::lambda(move |s| s.select_attr(attr.as_str().as_str())))";

  attrNames = ''
    Value::lambda(|s| {
      let map = s.as_set();
      let mut keys: Vec<String> = map.keys().cloned().collect();
      keys.sort();
      let vals = keys.into_iter().map(|k| Value::from_str(&k)).collect();
      Value::from_list(vals)
    })
  '';

  attrValues = ''
    Value::lambda(|s| {
      let map = s.as_set();
      let mut keys: Vec<String> = map.keys().cloned().collect();
      keys.sort();
      let vals = keys.into_iter().map(|k| map.get(&k).unwrap().clone()).collect();
      Value::from_list(vals)
    })
  '';

  listToAttrs = ''
    Value::lambda(|list| {
      let mut entries = Vec::new();
      for e in list.as_list().iter() {
        let name = e.select_attr("name");
        let val = e.select_attr("value");
        entries.push((name.as_str().to_string(), val));
      }
      Value::from_set(entries)
    })
  '';

  removeAttrs = ''
    Value::lambda(|s| {
      Value::lambda(move |names| {
        let to_remove: std::collections::HashSet<String> =
          names.as_list().iter().map(|n| n.as_str().to_string()).collect();
        let map = s.as_set();
        let filtered: Vec<(String, Value)> = map
          .iter()
          .filter(|(k, _)| !to_remove.contains(*k))
          .map(|(k, v)| (k.clone(), v.clone()))
          .collect();
        Value::from_set(filtered)
      })
    })
  '';

  mapAttrs = ''
    Value::lambda(|f| {
      Value::lambda(move |s| {
        let map = s.as_set();
        let mut entries = Vec::new();
        for (k, v) in map.iter() {
          let f_clone = f.clone();
          let k_clone = k.clone();
          let v_clone = v.clone();
          entries.push((
            k.clone(),
            Value::thunk(move || {
              f_clone.call(Value::from_str(&k_clone)).call(v_clone)
            })
          ));
        }
        Value::from_set(entries)
      })
    })
  '';

  zipAttrsWith = ''
    Value::lambda(|f| {
      Value::lambda(move |list| {
        let sets = list.as_list();
        let mut all_keys = std::collections::BTreeSet::new();
        for s in sets.iter() {
          if let Value::Set(map) = s.force() {
            for k in map.keys() {
              all_keys.insert(k.clone());
            }
          }
        }
        let mut r = Vec::new();
        for key in all_keys {
          let f_clone = f.clone();
          let sets_clone = sets.clone();
          let k_clone = key.clone();
          r.push((
            key.clone(),
            Value::thunk(move || {
              let mut vals = Vec::new();
              for s in sets_clone.iter() {
                if let Value::Set(map) = s.force() {
                  if let Some(v) = map.get(&k_clone) {
                    vals.push(v.clone());
                  }
                }
              }
              f_clone.call(Value::from_str(&k_clone)).call(Value::from_list(vals))
            })
          ));
        }
        Value::from_set(r)
      })
    })
  '';

  intersectAttrs = ''
    Value::lambda(|a| {
      Value::lambda(move |b| {
        let ma = a.as_set();
        let mb = b.as_set();
        let mut entries = Vec::new();
        for (k, _) in ma.iter() {
          if let Some(v) = mb.get(k) {
            entries.push((k.clone(), v.clone()));
          }
        }
        Value::from_set(entries)
      })
    })
  '';

  catAttrs = ''
    Value::lambda(|attr| {
      Value::lambda(move |list| {
        let mut out = Vec::new();
        let k = attr.as_str();
        for item in list.as_list().iter() {
          if item.has_attr(k.as_str()) {
            out.push(item.select_attr(k.as_str()));
          }
        }
        Value::from_list(out)
      })
    })
  '';

  # ── Strings ───────────────────────────────────────────────────
  toString = "Value::lambda(|e| Value::from_str(&e.force().to_json()))";
  toJSON = "Value::lambda(|e| Value::from_str(&e.force().to_json()))";
  fromJSON = "Value::lambda(|s| Value::from_json(s.as_str().as_str()))";
  stringLength = "Value::lambda(|s| Value::from_int(s.as_str().len() as i64))";

  concatStringsSep = ''
    Value::lambda(|sep| {
      Value::lambda(move |list| {
        let s = sep.as_str();
        let strings: Vec<String> = list.as_list().iter().map(|v| v.as_str().to_string()).collect();
        Value::from_str(&strings.join(s.as_str()))
      })
    })
  '';

  substring = ''
    Value::lambda(|start| {
      let start = start.clone();
      Value::lambda(move |len| {
        let start = start.clone();
        let len = len.clone();
        Value::lambda(move |str_val| {
          let st = start.as_int();
          let l = len.as_int();
          let s = str_val.as_str();
          if st < 0 || (st as usize) >= s.len() {
            Value::from_str("")
          } else {
            let st = st as usize;
            if l < 0 || st + (l as usize) > s.len() {
              Value::from_str(&s[st..])
            } else {
              Value::from_str(&s[st..st + (l as usize)])
            }
          }
        })
      })
    })
  '';

  replaceStrings = ''
    Value::lambda(|from| {
      Value::lambda(move |to| {
        let from_list = from.as_list();
        let to_list = to.as_list();
        Value::lambda(move |str_val| {
          let mut s = str_val.as_str().to_string();
          for (f, t) in from_list.iter().zip(to_list.iter()) {
            s = s.replace(f.as_str().as_str(), t.as_str().as_str());
          }
          Value::from_str(&s)
        })
      })
    })
  '';

  # ── Math & Bitwise ────────────────────────────────────────────
  ceil = "Value::lambda(|x| Value::from_int(x.as_float().ceil() as i64))";
  floor = "Value::lambda(|x| Value::from_int(x.as_float().floor() as i64))";
  bitAnd = "Value::lambda(|a| Value::lambda(move |b| Value::from_int(a.as_int() & b.as_int())))";
  bitOr = "Value::lambda(|a| Value::lambda(move |b| Value::from_int(a.as_int() | b.as_int())))";
  bitXor = "Value::lambda(|a| Value::lambda(move |b| Value::from_int(a.as_int() ^ b.as_int())))";

  # ── Types & Evaluation ────────────────────────────────────────
  typeOf = "Value::lambda(|e| Value::from_str(e.type_of()))";
  isNull = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::Null)))";
  isInt = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::Int(_))))";
  isFloat = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::Float(_))))";
  isString = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::String(_))))";
  isBool = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::Bool(_))))";
  isList = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::List(_))))";
  isAttrs = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::Set(_))))";
  isFunction = "Value::lambda(|e| Value::from_bool(matches!(e.force(), Value::Lambda(_))))";

  seq = "Value::lambda(|a| Value::lambda(move |b| { a.force(); b }))";
  deepSeq = ''
    Value::lambda(|a| {
      Value::lambda(move |b| {
        fn deep_force(val: &Value) {
          let forced = val.force();
          if let Value::List(l) = forced {
            for item in l.iter() { deep_force(item); }
          } else if let Value::Set(s) = forced {
            for v in s.values() { deep_force(v); }
          }
        }
        deep_force(&a);
        b
      })
    })
  '';

  tryEval = ''
    Value::lambda(|e| {
      let res = ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| {
        e.force()
      }));
      match res {
        Ok(v) => Value::from_set(vec![
          ("success".to_string(), Value::from_bool(true)),
          ("value".to_string(), v),
        ]),
        Err(_) => Value::from_set(vec![
          ("success".to_string(), Value::from_bool(false)),
          ("value".to_string(), Value::from_bool(false)),
        ]),
      }
    })
  '';

  abort = "Value::lambda(|msg| panic!(\"abort: {}\", msg.as_str()))";
  throw = "Value::lambda(|msg| panic!(\"{}\", msg.as_str()))";

  null = "Value::null_()";
  true = "Value::from_bool(true)";
  false = "Value::from_bool(false)";

  isPath = "Value::lambda(|_| Value::from_bool(false))";

  match = ''
    Value::lambda(|regex| {
      Value::lambda(move |str_val| {
        let re = Value::regex_compile(regex.as_str().as_str());
        re.match_str(str_val.as_str().as_str())
      })
    })
  '';

  split = ''
    Value::lambda(|regex| {
      Value::lambda(move |str_val| {
        let re = Value::regex_compile(regex.as_str().as_str());
        re.split_str(str_val.as_str().as_str())
      })
    })
  '';

  genericClosure = ''
    Value::lambda(|args| {
      let start_set = args.select_attr("startSet");
      let op = args.select_attr("operator");
      let mut result = Vec::new();
      let mut seen = std::collections::HashSet::new();
      let mut work = std::collections::VecDeque::new();
      for item in start_set.as_list().iter() {
        work.push_back(item.clone());
      }
      while let Some(item) = work.pop_front() {
        let key = item.select_attr("key").to_json();
        if seen.contains(&key) {
          continue;
        }
        seen.insert(key);
        result.push(item.clone());
        let expanded = op.call(item);
        for new_item in expanded.as_list().iter() {
          work.push_back(new_item.clone());
        }
      }
      Value::from_list(result)
    })
  '';

  hashString = ''
    Value::lambda(|_| {
      Value::lambda(move |str_val| {
        let s = str_val.as_str();
        let mut hash: u64 = 5381;
        for c in s.bytes() {
          hash = ((hash << 5).wrapping_add(hash)).wrapping_add(c as u64);
        }
        Value::from_str(&format!("{:016x}", hash))
      })
    })
  '';

  addErrorContext = "Value::lambda(|_| Value::lambda(|val| val))";

  trace = ''
    Value::lambda(|msg| {
      Value::lambda(move |val| {
        eprintln!("[trace] {}", msg.as_str());
        val
      })
    })
  '';

  warn = ''
    Value::lambda(|msg| {
      Value::lambda(move |val| {
        eprintln!("[warn] {}", msg.as_str());
        val
      })
    })
  '';

  functionArgs = "Value::lambda(|f| f.function_args())";

  reify = "Value::lambda(|f| f.reify())";

  sameFunction = ''
    Value::lambda(|a| {
      Value::lambda(move |b| {
        Value::from_bool(Value::same_function(&a, &b))
      })
    })
  '';
}
