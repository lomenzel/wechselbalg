// Wechselbalg C++ Value type.
//
// This header provides the Value class used by toCpp-generated code.
// Include it in your project and #include "wechselbalg.hpp" before
// using any wechselbalg output.
//
// No external dependencies beyond the C++ standard library.

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <deque>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

struct Value;

struct ThunkState {
  std::function<Value()> fn;
  mutable bool computed = false;
  mutable bool computing = false;
  mutable std::shared_ptr<Value> result;
};

struct Value {
  using List = std::vector<Value>;
  using Set = std::unordered_map<std::string, Value>;
  using Func = std::function<Value(const Value &)>;
  using ThunkPtr = std::shared_ptr<ThunkState>;

  enum class Type { Null, Bool, Int, Float, String, List, Set, Lambda, Thunk };

  mutable Type type;
  mutable std::variant<std::monostate, bool, long long, double, std::string,
                       List, Set, Func, ThunkPtr>
      value;
  mutable std::unordered_map<std::string, bool> _formals;

  Value() : type(Type::Null), value(std::monostate{}) {}

  // ── Lazy evaluation ───────────────────────────────────────────
  // force() transparently resolves thunks. Called at the start of
  // every accessor so that thunks are indistinguishable from values.

  void force() const {
    while (type == Type::Thunk) {
      auto ts = std::get<ThunkPtr>(value);
      auto &state = *ts;
      if (state.computing)
        throw std::runtime_error("wechselbalg: infinite recursion in thunk");
      if (!state.computed) {
        state.computing = true;
        try {
          state.result = std::make_shared<Value>(state.fn());
        } catch (...) {
          state.computing = false;
          throw;
        }
        state.computed = true;
        state.computing = false;
      }
      type = state.result->type;
      value = state.result->value;
      _formals = state.result->_formals;
    }
  }

  // ── Construction ──────────────────────────────────────────────

  static Value null_() { return Value(Type::Null, std::monostate{}); }
  static Value fromBool(bool v) { return Value(Type::Bool, v); }
  static Value fromInt(long long v) { return Value(Type::Int, v); }
  static Value fromFloat(double v) { return Value(Type::Float, v); }
  static Value fromString(std::string v) {
    return Value(Type::String, std::move(v));
  }
  static Value fromList(List v) { return Value(Type::List, std::move(v)); }
  static Value fromSet(std::initializer_list<std::pair<std::string, Value>> v) {
    Set s;
    for (auto &p : v)
      s[p.first] = p.second;
    return Value(Type::Set, std::move(s));
  }
  static Value fromSet(Set v) { return Value(Type::Set, std::move(v)); }
  static Value lambda(Func v) { return Value(Type::Lambda, std::move(v)); }
  static Value
  lambdaWithFormals(Func v, std::unordered_map<std::string, bool> formals) {
    Value val(Type::Lambda, std::move(v));
    val._formals = std::move(formals);
    return val;
  }

  // Lazy thunk — transparent lazy evaluation with caching.
  static Value thunk(std::function<Value()> fn) {
    Value v;
    v.type = Type::Thunk;
    v.value = std::make_shared<ThunkState>(
        ThunkState{std::move(fn), false, false, nullptr});
    return v;
  }

  // Lazy attrset — each entry is a thunk, forced on access.
  static Value
  lazySet(std::initializer_list<std::pair<std::string, std::function<Value()>>>
              entries) {
    Set s;
    for (auto &[k, fn] : entries)
      s[k] = thunk(fn);
    return fromSet(std::move(s));
  }

  // ── Type checks ───────────────────────────────────────────────

  bool isNull() const {
    force();
    return type == Type::Null;
  }
  bool isInt() const {
    force();
    return type == Type::Int;
  }
  bool isFloat() const {
    force();
    return type == Type::Float;
  }
  bool isBool() const {
    force();
    return type == Type::Bool;
  }
  bool isString() const {
    force();
    return type == Type::String;
  }
  bool isNumber() const {
    force();
    return type == Type::Int || type == Type::Float;
  }
  bool isList() const {
    force();
    return type == Type::List;
  }
  bool isSet() const {
    force();
    return type == Type::Set;
  }
  bool isAttrs() const {
    force();
    return type == Type::Set;
  }
  bool isFunction() const {
    force();
    return type == Type::Lambda;
  }

  Value functionArgs() const {
    force();
    if (type == Type::Set)
      return fromSet({});
    if (type != Type::Lambda)
      throw std::runtime_error("wechselbalg: functionArgs requires a function");
    Set r;
    for (const auto &[k, v] : _formals)
      r[k] = fromBool(v);
    return fromSet(std::move(r));
  }

  // ── Accessors ─────────────────────────────────────────────────

  long long asInt() const {
    force();
    if (type == Type::Int)
      return std::get<long long>(value);
    throw std::runtime_error("wechselbalg: expected int, got " + typeOf());
  }

  double asFloat() const {
    force();
    if (type == Type::Float)
      return std::get<double>(value);
    if (type == Type::Int)
      return static_cast<double>(std::get<long long>(value));
    throw std::runtime_error("wechselbalg: expected float, got " + typeOf());
  }

  bool asBool() const {
    force();
    if (type == Type::Bool)
      return std::get<bool>(value);
    throw std::runtime_error("wechselbalg: expected bool, got " + typeOf());
  }

  const std::string &asString() const {
    force();
    if (type == Type::String)
      return std::get<std::string>(value);
    throw std::runtime_error("wechselbalg: expected string, got " + typeOf());
  }

  const List &asList() const {
    force();
    if (type == Type::List)
      return std::get<List>(value);
    throw std::runtime_error("wechselbalg: expected list, got " + typeOf());
  }

  const Set &asSet() const {
    force();
    if (type == Type::Set)
      return std::get<Set>(value);
    throw std::runtime_error("wechselbalg: expected set, got " + typeOf());
  }

  std::string typeOf() const {
    force();
    switch (type) {
    case Type::Null:
      return "null";
    case Type::Bool:
      return "bool";
    case Type::Int:
      return "int";
    case Type::Float:
      return "float";
    case Type::String:
      return "string";
    case Type::List:
      return "list";
    case Type::Set:
      return "set";
    case Type::Lambda:
      return "lambda";
    case Type::Thunk:
      return "thunk";
    }
    return "unknown";
  }

  // ── Call ───────────────────────────────────────────────────────

  Value operator()(const Value &arg) const {
    force();
    if (type == Type::Set) {
      auto &s = std::get<Set>(value);
      auto it = s.find("__functor");
      if (it != s.end())
        return it->second(*this)(arg);
    }
    if (type != Type::Lambda)
      throw std::runtime_error("wechselbalg: tried to call a " + typeOf());
    return std::get<Func>(value)(arg);
  }

  // ── Attribute access ──────────────────────────────────────────

  const Value &operator[](const std::string &key) const {
    force();
    if (type != Type::Set)
      throw std::runtime_error("wechselbalg: attribute access on " + typeOf());
    const auto &s = std::get<Set>(value);
    auto it = s.find(key);
    if (it == s.end())
      throw std::runtime_error("wechselbalg: attribute '" + key +
                               "' not found");
    return it->second;
  }

  const Value &operator[](const Value &key) const {
    return (*this)[key.asString()];
  }

  bool hasAttr(const std::string &key) const {
    force();
    if (type != Type::Set)
      return false;
    return std::get<Set>(value).count(key) > 0;
  }

  // ── Comparison ────────────────────────────────────────────────

  bool operator==(const Value &other) const {
    force();
    other.force();
    if (isNumber() && other.isNumber()) {
      if (type == Type::Int && other.type == Type::Int)
        return asInt() == other.asInt();
      return asFloat() == other.asFloat();
    }
    if (type != other.type)
      return false;
    switch (type) {
    case Type::Null:
      return true;
    case Type::Bool:
      return std::get<bool>(value) == std::get<bool>(other.value);
    case Type::Int:
      return std::get<long long>(value) == std::get<long long>(other.value);
    case Type::Float:
      return std::get<double>(value) == std::get<double>(other.value);
    case Type::String:
      return std::get<std::string>(value) == std::get<std::string>(other.value);
    case Type::List:
      return std::get<List>(value) == std::get<List>(other.value);
    case Type::Set:
      return std::get<Set>(value) == std::get<Set>(other.value);
    case Type::Lambda:
      return false;
    }
    return false;
  }

  bool operator<(const Value &other) const {
    force();
    other.force();
    if (isInt() && other.isInt())
      return asInt() < other.asInt();
    if (isNumber() && other.isNumber())
      return asFloat() < other.asFloat();
    if (isString() && other.isString())
      return asString() < other.asString();
    throw std::runtime_error("wechselbalg: cannot compare " + typeOf() + " < " +
                             other.typeOf());
  }

  // ── Collection operations ─────────────────────────────────────

  Value update(const Value &other) const {
    force();
    other.force();
    if (type != Type::Set || other.type != Type::Set)
      throw std::runtime_error("wechselbalg: update (//) requires two sets");
    Set s = std::get<Set>(value);
    for (const auto &kv : std::get<Set>(other.value))
      s[kv.first] = kv.second;
    return fromSet(std::move(s));
  }

  Value concat(const Value &other) const {
    force();
    other.force();
    if (type != Type::List || other.type != Type::List)
      throw std::runtime_error("wechselbalg: concat (++) requires two lists");
    List r;
    const auto &a = std::get<List>(value);
    const auto &b = std::get<List>(other.value);
    r.reserve(a.size() + b.size());
    r.insert(r.end(), a.begin(), a.end());
    r.insert(r.end(), b.begin(), b.end());
    return fromList(std::move(r));
  }

  Value at(long long i) const {
    const auto &l = asList();
    if (i < 0 || static_cast<size_t>(i) >= l.size())
      throw std::runtime_error("wechselbalg: index out of bounds");
    return l[i];
  }

  Value head() const {
    const auto &l = asList();
    if (l.empty())
      throw std::runtime_error("wechselbalg: head of empty list");
    return l.front();
  }

  Value tail() const {
    const auto &l = asList();
    if (l.empty())
      throw std::runtime_error("wechselbalg: tail of empty list");
    return fromList(List(l.begin() + 1, l.end()));
  }

  long long length() const {
    force();
    if (type == Type::List)
      return std::get<List>(value).size();
    throw std::runtime_error("wechselbalg: length requires a list");
  }

  Value map(const Value &func) const {
    const auto &l = asList();
    List r;
    r.reserve(l.size());
    for (const auto &e : l)
      r.push_back(func(e));
    return fromList(std::move(r));
  }

  Value filter(const Value &func) const {
    const auto &l = asList();
    List r;
    for (const auto &e : l)
      if (func(e).asBool())
        r.push_back(e);
    return fromList(std::move(r));
  }

  Value foldl(const Value &op, Value acc) const {
    for (const auto &e : asList())
      acc = op(acc)(e);
    return acc;
  }

  bool all(const Value &func) const {
    for (const auto &e : asList())
      if (!func(e).asBool())
        return false;
    return true;
  }

  bool any(const Value &func) const {
    for (const auto &e : asList())
      if (func(e).asBool())
        return true;
    return false;
  }

  bool elem(const Value &item) const {
    for (const auto &e : asList())
      if (e == item)
        return true;
    return false;
  }

  Value concatMap(const Value &func) const {
    List r;
    for (const auto &e : asList()) {
      Value mapped = func(e);
      const auto &sub = mapped.asList();
      r.insert(r.end(), sub.begin(), sub.end());
    }
    return fromList(std::move(r));
  }

  Value concatStringsSep(const std::string &sep) const {
    const auto &l = asList();
    std::string r;
    for (size_t i = 0; i < l.size(); i++) {
      if (i > 0)
        r += sep;
      r += l[i].asString();
    }
    return fromString(r);
  }

  Value attrNames() const {
    const auto &s = asSet();
    std::vector<std::string> keys;
    keys.reserve(s.size());
    for (const auto &kv : s)
      keys.push_back(kv.first);
    std::sort(keys.begin(), keys.end());
    List r;
    r.reserve(keys.size());
    for (const auto &k : keys)
      r.push_back(fromString(k));
    return fromList(std::move(r));
  }

  Value attrValues() const {
    const auto &s = asSet();
    std::vector<std::string> keys;
    keys.reserve(s.size());
    for (const auto &kv : s)
      keys.push_back(kv.first);
    std::sort(keys.begin(), keys.end());
    List r;
    r.reserve(keys.size());
    for (const auto &k : keys)
      r.push_back(s.at(k));
    return fromList(std::move(r));
  }

  Value removeAttrs(const Value &names) const {
    force();
    Set s = std::get<Set>(value);
    for (const auto &n : names.asList())
      s.erase(n.asString());
    return fromSet(std::move(s));
  }

  Value listToAttrs() const {
    Set s;
    for (const auto &e : asList())
      s[e["name"].asString()] = e["value"];
    return fromSet(std::move(s));
  }

  Value mapAttrs(const Value &f) const {
    Set r;
    for (const auto &kv : asSet()) {
      auto key = kv.first;
      auto val = kv.second;
      auto func = f;
      r[key] = thunk(
          [func, key, val]() mutable { return func(fromString(key))(val); });
    }
    return fromSet(std::move(r));
  }

  Value intersectAttrs(const Value &other) const {
    Set r;
    const auto &a = asSet();
    const auto &b = other.asSet();
    for (const auto &kv : a)
      if (b.count(kv.first))
        r[kv.first] = b.at(kv.first);
    return fromSet(std::move(r));
  }

  Value catAttrs(const std::string &attr) const {
    List r;
    for (const auto &e : asList())
      if (e.hasAttr(attr))
        r.push_back(e[attr]);
    return fromList(std::move(r));
  }

  Value groupBy(const Value &f) const {
    std::map<std::string, List> groups;
    for (const auto &e : asList())
      groups[f(e).asString()].push_back(e);
    Set r;
    for (auto &kv : groups)
      r[kv.first] = fromList(std::move(kv.second));
    return fromSet(std::move(r));
  }

  Value partition(const Value &pred) const {
    List right, wrong;
    for (const auto &e : asList()) {
      if (pred(e).asBool())
        right.push_back(e);
      else
        wrong.push_back(e);
    }
    return fromSet({{"right", fromList(std::move(right))},
                    {"wrong", fromList(std::move(wrong))}});
  }

  Value sort(const Value &cmp) const {
    force();
    List r = std::get<List>(value);
    std::sort(r.begin(), r.end(), [&](const Value &a, const Value &b) {
      return cmp(a)(b).asBool();
    });
    return fromList(std::move(r));
  }

  Value replaceStrings(const Value &from, const Value &to) const {
    std::string s = asString();
    const auto &fromList = from.asList();
    const auto &toList = to.asList();
    for (size_t i = 0; i < fromList.size(); i++) {
      const auto &f = fromList[i].asString();
      const auto &t = toList[i].asString();
      size_t pos = 0;
      while ((pos = s.find(f, pos)) != std::string::npos) {
        s.replace(pos, f.length(), t);
        pos += t.length();
      }
    }
    return fromString(s);
  }

  static Value genList(const Value &func, long long count) {
    List r;
    r.reserve(count);
    for (long long i = 0; i < count; i++)
      r.push_back(func(fromInt(i)));
    return fromList(std::move(r));
  }

  long long ceil() const {
    force();
    if (type == Type::Int)
      return asInt();
    return static_cast<long long>(std::ceil(asFloat()));
  }

  long long floor() const {
    force();
    if (type == Type::Int)
      return asInt();
    return static_cast<long long>(std::floor(asFloat()));
  }

  std::string toString() const {
    force();
    switch (type) {
    case Type::Null:
      return "";
    case Type::Bool:
      return asBool() ? "1" : "";
    case Type::Int:
      return std::to_string(asInt());
    case Type::Float:
      return std::to_string(asFloat());
    case Type::String:
      return asString();
    default:
      throw std::runtime_error("wechselbalg: cannot convert " + typeOf() +
                               " to string");
    }
  }

  std::string toJSON() const {
    force();
    switch (type) {
    case Type::Null:
      return "null";
    case Type::Bool:
      return asBool() ? "true" : "false";
    case Type::Int:
      return std::to_string(asInt());
    case Type::Float:
      return std::to_string(asFloat());
    case Type::String: {
      std::string r = "\"";
      for (char c : asString()) {
        if (c == '"')
          r += "\\\"";
        else if (c == '\\')
          r += "\\\\";
        else if (c == '\n')
          r += "\\n";
        else if (c == '\t')
          r += "\\t";
        else
          r += c;
      }
      return r + "\"";
    }
    case Type::List: {
      std::string r = "[";
      const auto &l = asList();
      for (size_t i = 0; i < l.size(); i++) {
        if (i > 0)
          r += ",";
        r += l[i].toJSON();
      }
      return r + "]";
    }
    case Type::Set: {
      const auto &s = asSet();
      std::vector<std::string> keys;
      keys.reserve(s.size());
      for (const auto &kv : s)
        keys.push_back(kv.first);
      std::sort(keys.begin(), keys.end());
      std::string r = "{";
      bool first = true;
      for (const auto &k : keys) {
        if (!first)
          r += ",";
        first = false;
        r += "\"" + k + "\":" + s.at(k).toJSON();
      }
      return r + "}";
    }
    case Type::Lambda:
      throw std::runtime_error("wechselbalg: cannot serialize lambda to JSON");
    }
    return "null";
  }

  static Value fromJSON(const std::string &s) {
    size_t pos = 0;
    Value result = parseJSON(s, pos);
    return result;
  }

private:
  static void skipWhitespace(const std::string &s, size_t &pos) {
    while (pos < s.size() && (s[pos] == ' ' || s[pos] == '\t' ||
                              s[pos] == '\n' || s[pos] == '\r'))
      pos++;
  }

  static Value parseJSON(const std::string &s, size_t &pos) {
    skipWhitespace(s, pos);
    if (pos >= s.size())
      throw std::runtime_error(
          "wechselbalg: fromJSON: unexpected end of input");
    char c = s[pos];
    if (c == '"')
      return parseJSONString(s, pos);
    if (c == '{')
      return parseJSONObject(s, pos);
    if (c == '[')
      return parseJSONArray(s, pos);
    if (c == 't') { // true
      if (s.compare(pos, 4, "true") == 0) {
        pos += 4;
        return fromBool(true);
      }
      throw std::runtime_error("wechselbalg: fromJSON: unexpected token");
    }
    if (c == 'f') { // false
      if (s.compare(pos, 5, "false") == 0) {
        pos += 5;
        return fromBool(false);
      }
      throw std::runtime_error("wechselbalg: fromJSON: unexpected token");
    }
    if (c == 'n') { // null
      if (s.compare(pos, 4, "null") == 0) {
        pos += 4;
        return null_();
      }
      throw std::runtime_error("wechselbalg: fromJSON: unexpected token");
    }
    // Number
    return parseJSONNumber(s, pos);
  }

  static std::string parseJSONStringRaw(const std::string &s, size_t &pos) {
    if (s[pos] != '"')
      throw std::runtime_error("wechselbalg: fromJSON: expected '\"'");
    pos++;
    std::string result;
    while (pos < s.size() && s[pos] != '"') {
      if (s[pos] == '\\') {
        pos++;
        if (pos >= s.size())
          throw std::runtime_error(
              "wechselbalg: fromJSON: unexpected end in string escape");
        switch (s[pos]) {
        case '"':
          result += '"';
          break;
        case '\\':
          result += '\\';
          break;
        case '/':
          result += '/';
          break;
        case 'b':
          result += '\b';
          break;
        case 'f':
          result += '\f';
          break;
        case 'n':
          result += '\n';
          break;
        case 'r':
          result += '\r';
          break;
        case 't':
          result += '\t';
          break;
        case 'u': {
          if (pos + 4 >= s.size())
            throw std::runtime_error(
                "wechselbalg: fromJSON: incomplete unicode escape");
          unsigned cp = 0;
          for (int i = 1; i <= 4; i++) {
            char h = s[pos + i];
            cp <<= 4;
            if (h >= '0' && h <= '9')
              cp |= (h - '0');
            else if (h >= 'a' && h <= 'f')
              cp |= (h - 'a' + 10);
            else if (h >= 'A' && h <= 'F')
              cp |= (h - 'A' + 10);
            else
              throw std::runtime_error(
                  "wechselbalg: fromJSON: invalid unicode escape");
          }
          pos += 4;
          // UTF-8 encode
          if (cp < 0x80) {
            result += (char)cp;
          } else if (cp < 0x800) {
            result += (char)(0xC0 | (cp >> 6));
            result += (char)(0x80 | (cp & 0x3F));
          } else {
            result += (char)(0xE0 | (cp >> 12));
            result += (char)(0x80 | ((cp >> 6) & 0x3F));
            result += (char)(0x80 | (cp & 0x3F));
          }
          break;
        }
        default:
          throw std::runtime_error("wechselbalg: fromJSON: unknown escape");
        }
      } else {
        result += s[pos];
      }
      pos++;
    }
    if (pos >= s.size())
      throw std::runtime_error("wechselbalg: fromJSON: unterminated string");
    pos++; // skip closing "
    return result;
  }

  static Value parseJSONString(const std::string &s, size_t &pos) {
    return fromString(parseJSONStringRaw(s, pos));
  }

  static Value parseJSONNumber(const std::string &s, size_t &pos) {
    size_t start = pos;
    bool isFloat = false;
    if (pos < s.size() && s[pos] == '-')
      pos++;
    while (pos < s.size() && s[pos] >= '0' && s[pos] <= '9')
      pos++;
    if (pos < s.size() && s[pos] == '.') {
      isFloat = true;
      pos++;
      while (pos < s.size() && s[pos] >= '0' && s[pos] <= '9')
        pos++;
    }
    if (pos < s.size() && (s[pos] == 'e' || s[pos] == 'E')) {
      isFloat = true;
      pos++;
      if (pos < s.size() && (s[pos] == '+' || s[pos] == '-'))
        pos++;
      while (pos < s.size() && s[pos] >= '0' && s[pos] <= '9')
        pos++;
    }
    if (pos == start)
      throw std::runtime_error("wechselbalg: fromJSON: expected number");
    std::string num = s.substr(start, pos - start);
    if (isFloat)
      return fromFloat(std::stod(num));
    return fromInt(std::stoll(num));
  }

  static Value parseJSONArray(const std::string &s, size_t &pos) {
    pos++; // skip [
    List items;
    skipWhitespace(s, pos);
    if (pos < s.size() && s[pos] == ']') {
      pos++;
      return fromList(std::move(items));
    }
    while (true) {
      items.push_back(parseJSON(s, pos));
      skipWhitespace(s, pos);
      if (pos < s.size() && s[pos] == ',') {
        pos++;
        continue;
      }
      if (pos < s.size() && s[pos] == ']') {
        pos++;
        return fromList(std::move(items));
      }
      throw std::runtime_error("wechselbalg: fromJSON: expected ',' or ']'");
    }
  }

  static Value parseJSONObject(const std::string &s, size_t &pos) {
    pos++; // skip {
    Set entries;
    skipWhitespace(s, pos);
    if (pos < s.size() && s[pos] == '}') {
      pos++;
      return fromSet(std::move(entries));
    }
    while (true) {
      skipWhitespace(s, pos);
      std::string key = parseJSONStringRaw(s, pos);
      skipWhitespace(s, pos);
      if (pos >= s.size() || s[pos] != ':')
        throw std::runtime_error("wechselbalg: fromJSON: expected ':'");
      pos++;
      entries[key] = parseJSON(s, pos);
      skipWhitespace(s, pos);
      if (pos < s.size() && s[pos] == ',') {
        pos++;
        continue;
      }
      if (pos < s.size() && s[pos] == '}') {
        pos++;
        return fromSet(std::move(entries));
      }
      throw std::runtime_error("wechselbalg: fromJSON: expected ',' or '}'");
    }
  }

  template <typename T> Value(Type t, T v) : type(t), value(std::move(v)) {}
};

// ── Arithmetic helpers (used by generated code) ───────────────────

inline Value __wb_add(const Value &a, const Value &b) {
  if (a.isInt() && b.isInt())
    return Value::fromInt(a.asInt() + b.asInt());
  if (a.isNumber() && b.isNumber())
    return Value::fromFloat(a.asFloat() + b.asFloat());
  if (a.isString() && b.isString())
    return Value::fromString(a.asString() + b.asString());
  throw std::runtime_error("wechselbalg: cannot add " + a.typeOf() + " and " +
                           b.typeOf());
}

inline Value __wb_sub(const Value &a, const Value &b) {
  if (a.isInt() && b.isInt())
    return Value::fromInt(a.asInt() - b.asInt());
  if (a.isNumber() && b.isNumber())
    return Value::fromFloat(a.asFloat() - b.asFloat());
  throw std::runtime_error("wechselbalg: cannot subtract " + a.typeOf() +
                           " and " + b.typeOf());
}

inline Value __wb_mul(const Value &a, const Value &b) {
  if (a.isInt() && b.isInt())
    return Value::fromInt(a.asInt() * b.asInt());
  if (a.isNumber() && b.isNumber())
    return Value::fromFloat(a.asFloat() * b.asFloat());
  throw std::runtime_error("wechselbalg: cannot multiply " + a.typeOf() +
                           " and " + b.typeOf());
}

inline Value __wb_div(const Value &a, const Value &b) {
  if (a.isInt() && b.isInt()) {
    if (b.asInt() == 0)
      throw std::runtime_error("wechselbalg: division by zero");
    return Value::fromInt(a.asInt() / b.asInt());
  }
  if (a.isNumber() && b.isNumber()) {
    if (b.asFloat() == 0.0)
      throw std::runtime_error("wechselbalg: division by zero");
    return Value::fromFloat(a.asFloat() / b.asFloat());
  }
  throw std::runtime_error("wechselbalg: cannot divide " + a.typeOf() +
                           " and " + b.typeOf());
}

inline Value __wb_unknown_primop(const std::string &name) {
  return Value::lambda([name](const Value &) -> Value {
    throw std::runtime_error("wechselbalg: primop '" + name +
                             "' is not implemented in C++");
  });
}
