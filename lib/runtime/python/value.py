# Wechselbalg Python Value type.
#
# This file provides the Value class used by toPython-generated code.
# Include it in your project before using any wechselbalg output.
#
# API mirrors the JS/C++ Value types for consistency across backends.

import json
import math
import re
import sys
from typing import Any, Callable, Optional


class _Thunk:
    """Transparent lazy wrapper. Forces on any attribute access."""
    __slots__ = ("_fn", "_cached", "_forcing")

    _UNFORCED = object()

    def __init__(self, fn: Callable[[], "Value"]):
        object.__setattr__(self, "_fn", fn)
        object.__setattr__(self, "_cached", _Thunk._UNFORCED)
        object.__setattr__(self, "_forcing", False)

    def _force(self) -> "Value":
        cached = object.__getattribute__(self, "_cached")
        if cached is not _Thunk._UNFORCED:
            return cached
        if object.__getattribute__(self, "_forcing"):
            raise RuntimeError("wechselbalg: infinite recursion in thunk")
        object.__setattr__(self, "_forcing", True)
        result = object.__getattribute__(self, "_fn")()
        object.__setattr__(self, "_cached", result)
        object.__setattr__(self, "_forcing", False)
        return result

    def __getattr__(self, name: str) -> Any:
        return getattr(self._force(), name)

    def __repr__(self) -> str:
        return repr(self._force())


class _LazySetProxy:
    """Lazy attrset — entries are thunks evaluated on first access and cached."""
    __slots__ = ("_factories", "_cache")

    def __init__(self, factories: dict[str, Callable[[], "Value"]]):
        object.__setattr__(self, "_factories", factories)
        object.__setattr__(self, "_cache", {})

    def __contains__(self, key: str) -> bool:
        return key in object.__getattribute__(self, "_factories")

    def __getitem__(self, key: str) -> "Value":
        cache = object.__getattribute__(self, "_cache")
        if key in cache:
            return cache[key]
        factories = object.__getattribute__(self, "_factories")
        if key not in factories:
            raise KeyError(key)
        val = factories[key]()
        cache[key] = val
        return val

    def keys(self) -> list[str]:
        return list(object.__getattribute__(self, "_factories").keys())

    def items(self):
        for k in self.keys():
            yield k, self[k]

    def __iter__(self):
        return iter(self.keys())


class _MergedSetProxy:
    """Lazy merge of two attrsets. Keys from ext shadow keys from base."""
    __slots__ = ("_base", "_ext")

    def __init__(self, base: "Value", ext: "Value"):
        object.__setattr__(self, "_base", base)
        object.__setattr__(self, "_ext", ext)

    def __contains__(self, key: str) -> bool:
        ext = object.__getattribute__(self, "_ext")
        base = object.__getattribute__(self, "_base")
        return ext.has_attr(key) or base.has_attr(key)

    def __getitem__(self, key: str) -> "Value":
        ext = object.__getattribute__(self, "_ext")
        base = object.__getattribute__(self, "_base")
        if ext.has_attr(key):
            return ext.get(key)
        return base.get(key)

    def keys(self) -> list[str]:
        ext = object.__getattribute__(self, "_ext")
        base = object.__getattribute__(self, "_base")
        return list(dict.fromkeys(list(base.as_set().keys()) + list(ext.as_set().keys())))

    def items(self):
        for k in self.keys():
            yield k, self[k]

    def __iter__(self):
        return iter(self.keys())


class Value:
    __slots__ = ("type", "value")

    def __init__(self, type_: str, value: Any):
        self.type = type_
        self.value = value

    # ── Construction ──────────────────────────────────────────────

    @staticmethod
    def null_() -> "Value":
        return Value("null", None)

    @staticmethod
    def from_bool(v: bool) -> "Value":
        return Value("bool", v)

    @staticmethod
    def from_int(v: int) -> "Value":
        return Value("int", int(v))

    @staticmethod
    def from_float(v: float) -> "Value":
        return Value("float", float(v))

    @staticmethod
    def from_string(v: str) -> "Value":
        return Value("string", v)

    @staticmethod
    def from_list(v: list["Value"]) -> "Value":
        return Value("list", list(v))

    @staticmethod
    def from_set(v) -> "Value":
        return Value("set", v)

    @staticmethod
    def lambda_(v: Callable[["Value"], "Value"]) -> "Value":
        return Value("lambda", v)

    @staticmethod
    def thunk(fn: Callable[[], "Value"]) -> "_Thunk":
        return _Thunk(fn)

    @staticmethod
    def lazy_set(factories: dict[str, Callable[[], "Value"]]) -> "Value":
        return Value.from_set(_LazySetProxy(factories))

    # ── Type checks ───────────────────────────────────────────────

    def is_null(self) -> bool:
        return self.type == "null"

    def is_int(self) -> bool:
        return self.type == "int"

    def is_float(self) -> bool:
        return self.type == "float"

    def is_bool(self) -> bool:
        return self.type == "bool"

    def is_string(self) -> bool:
        return self.type == "string"

    def is_number(self) -> bool:
        return self.type in ("int", "float")

    def is_list(self) -> bool:
        return self.type == "list"

    def is_set(self) -> bool:
        return self.type == "set"

    is_attrs = is_set

    def is_function(self) -> bool:
        return self.type == "lambda"

    def type_of(self) -> str:
        return self.type

    # ── Accessors ─────────────────────────────────────────────────

    def as_int(self) -> int:
        if self.type == "int":
            return self.value
        raise RuntimeError(f"wechselbalg: expected int, got {self.type}")

    def as_float(self) -> float:
        if self.type == "float":
            return self.value
        if self.type == "int":
            return float(self.value)
        raise RuntimeError(f"wechselbalg: expected float, got {self.type}")

    def as_bool(self) -> bool:
        if self.type == "bool":
            return self.value
        raise RuntimeError(f"wechselbalg: expected bool, got {self.type}")

    def as_string(self) -> str:
        if self.type == "string":
            return self.value
        raise RuntimeError(f"wechselbalg: expected string, got {self.type}")

    def as_list(self) -> list["Value"]:
        if self.type == "list":
            return self.value
        raise RuntimeError(f"wechselbalg: expected list, got {self.type}")

    def as_set(self):
        if self.type == "set":
            return self.value
        raise RuntimeError(f"wechselbalg: expected set, got {self.type}")

    def as_function(self) -> Callable:
        if self.type == "lambda":
            return self.value
        raise RuntimeError(f"wechselbalg: expected lambda, got {self.type}")

    # ── Call ───────────────────────────────────────────────────────

    def call(self, arg: "Value") -> "Value":
        if self.type == "set" and "__functor" in self.value:
            return self.value["__functor"].call(self).call(arg)
        if self.type != "lambda":
            raise RuntimeError(f"wechselbalg: tried to call a {self.type}")
        return self.value(arg)

    # ── Attribute access ──────────────────────────────────────────

    def get(self, key) -> "Value":
        if self.type != "set":
            raise RuntimeError(f"wechselbalg: attribute access on {self.type}")
        k = key if isinstance(key, str) else key.as_string()
        s = self.value
        if isinstance(s, dict):
            if k not in s:
                raise RuntimeError(f"wechselbalg: attribute '{k}' not found")
            return s[k]
        # proxy types
        try:
            return s[k]
        except KeyError:
            raise RuntimeError(f"wechselbalg: attribute '{k}' not found")

    def get_or(self, key, default: "Value") -> "Value":
        if self.type != "set":
            return default
        k = key if isinstance(key, str) else key.as_string()
        s = self.value
        if k in s:
            return s[k]
        return default

    def has_attr(self, key) -> bool:
        if self.type != "set":
            return False
        k = key if isinstance(key, str) else key.as_string()
        return k in self.value

    # ── Comparison ────────────────────────────────────────────────

    def eq(self, other: "Value") -> "Value":
        return Value.from_bool(Value._deep_eq(self, other))

    @staticmethod
    def _deep_eq(a: "Value", b: "Value") -> bool:
        if a.type != b.type:
            if a.is_number() and b.is_number():
                return a.as_float() == b.as_float()
            return False
        t = a.type
        if t == "null":
            return True
        if t in ("bool", "int", "float", "string"):
            return a.value == b.value
        if t == "list":
            al, bl = a.value, b.value
            if len(al) != len(bl):
                return False
            return all(Value._deep_eq(al[i], bl[i]) for i in range(len(al)))
        if t == "set":
            ak = sorted(a.value.keys())
            bk = sorted(b.value.keys())
            if ak != bk:
                return False
            return all(Value._deep_eq(a.value[k], b.value[k]) for k in ak)
        if t == "lambda":
            return False
        return False

    def less_than(self, other: "Value") -> "Value":
        if self.is_int() and other.is_int():
            return Value.from_bool(self.value < other.value)
        if self.is_number() and other.is_number():
            return Value.from_bool(self.as_float() < other.as_float())
        if self.is_string() and other.is_string():
            return Value.from_bool(self.value < other.value)
        raise RuntimeError(f"wechselbalg: cannot compare {self.type} < {other.type}")

    # ── Arithmetic ────────────────────────────────────────────────

    def add(self, other: "Value") -> "Value":
        if self.is_int() and other.is_int():
            return Value.from_int(self.value + other.value)
        if self.is_number() and other.is_number():
            return Value.from_float(self.as_float() + other.as_float())
        if self.is_string() and other.is_string():
            return Value.from_string(self.value + other.value)
        raise RuntimeError(f"wechselbalg: cannot add {self.type} and {other.type}")

    def sub(self, other: "Value") -> "Value":
        if self.is_int() and other.is_int():
            return Value.from_int(self.value - other.value)
        if self.is_number() and other.is_number():
            return Value.from_float(self.as_float() - other.as_float())
        raise RuntimeError(f"wechselbalg: cannot subtract {self.type} and {other.type}")

    def mul(self, other: "Value") -> "Value":
        if self.is_int() and other.is_int():
            return Value.from_int(self.value * other.value)
        if self.is_number() and other.is_number():
            return Value.from_float(self.as_float() * other.as_float())
        raise RuntimeError(f"wechselbalg: cannot multiply {self.type} and {other.type}")

    def div(self, other: "Value") -> "Value":
        if self.is_int() and other.is_int():
            if other.value == 0:
                raise RuntimeError("wechselbalg: division by zero")
            # Python integer division truncates toward negative infinity,
            # but Nix truncates toward zero (like C). Use int(a/b).
            return Value.from_int(int(self.value / other.value))
        if self.is_number() and other.is_number():
            if other.as_float() == 0:
                raise RuntimeError("wechselbalg: division by zero")
            return Value.from_float(self.as_float() / other.as_float())
        raise RuntimeError(f"wechselbalg: cannot divide {self.type} and {other.type}")

    def negate(self) -> "Value":
        return Value.from_bool(not self.as_bool())

    # ── Collection operations ─────────────────────────────────────

    def update(self, other: "Value") -> "Value":
        return Value.from_set(_MergedSetProxy(self, other))

    def concat(self, other: "Value") -> "Value":
        if self.type != "list" or other.type != "list":
            raise RuntimeError("wechselbalg: concat (++) requires two lists")
        return Value.from_list(self.value + other.value)

    def at(self, index) -> "Value":
        lst = self.as_list()
        i = index if isinstance(index, int) else int(index)
        if i < 0 or i >= len(lst):
            raise RuntimeError("wechselbalg: index out of bounds")
        return lst[i]

    def head(self) -> "Value":
        lst = self.as_list()
        if len(lst) == 0:
            raise RuntimeError("wechselbalg: head of empty list")
        return lst[0]

    def tail(self) -> "Value":
        lst = self.as_list()
        if len(lst) == 0:
            raise RuntimeError("wechselbalg: tail of empty list")
        return Value.from_list(lst[1:])

    def length(self) -> "Value":
        return Value.from_int(len(self.as_list()))

    def map(self, func: "Value") -> "Value":
        return Value.from_list([func.call(e) for e in self.as_list()])

    def filter(self, func: "Value") -> "Value":
        return Value.from_list([e for e in self.as_list() if func.call(e).as_bool()])

    def foldl(self, op: "Value", acc: "Value") -> "Value":
        for e in self.as_list():
            acc = op.call(acc).call(e)
        return acc

    def all(self, func: "Value") -> "Value":
        return Value.from_bool(all(func.call(e).as_bool() for e in self.as_list()))

    def any(self, func: "Value") -> "Value":
        return Value.from_bool(any(func.call(e).as_bool() for e in self.as_list()))

    def elem(self, item: "Value") -> "Value":
        return Value.from_bool(any(Value._deep_eq(e, item) for e in self.as_list()))

    def concat_map(self, func: "Value") -> "Value":
        result = []
        for e in self.as_list():
            result.extend(func.call(e).as_list())
        return Value.from_list(result)

    def concat_strings_sep(self, sep) -> "Value":
        s = sep if isinstance(sep, str) else sep.as_string()
        return Value.from_string(s.join(e.as_string() for e in self.as_list()))

    def attr_names(self) -> "Value":
        return Value.from_list([Value.from_string(k) for k in sorted(self.as_set().keys())])

    def attr_values(self) -> "Value":
        s = self.as_set()
        return Value.from_list([s[k] for k in sorted(s.keys())])

    def remove_attrs(self, names: "Value") -> "Value":
        s = dict(self.as_set().items())
        for n in names.as_list():
            s.pop(n.as_string(), None)
        return Value.from_set(s)

    def list_to_attrs(self) -> "Value":
        s = {}
        for e in self.as_list():
            s[e.get("name").as_string()] = e.get("value")
        return Value.from_set(s)

    def map_attrs(self, f: "Value") -> "Value":
        s = self.as_set()
        r = {}
        for k in s.keys():
            r[k] = f.call(Value.from_string(k)).call(s[k])
        return Value.from_set(r)

    def intersect_attrs(self, other: "Value") -> "Value":
        a, b = self.as_set(), other.as_set()
        r = {}
        for k in a.keys():
            if k in b:
                r[k] = b[k]
        return Value.from_set(r)

    def cat_attrs(self, attr) -> "Value":
        a = attr if isinstance(attr, str) else attr.as_string()
        return Value.from_list([e.get(a) for e in self.as_list() if e.has_attr(a)])

    def group_by(self, f: "Value") -> "Value":
        groups: dict[str, list[Value]] = {}
        for e in self.as_list():
            k = f.call(e).as_string()
            if k not in groups:
                groups[k] = []
            groups[k].append(e)
        r = {}
        for k, v in groups.items():
            r[k] = Value.from_list(v)
        return Value.from_set(r)

    def partition(self, pred: "Value") -> "Value":
        right, wrong = [], []
        for e in self.as_list():
            if pred.call(e).as_bool():
                right.append(e)
            else:
                wrong.append(e)
        return Value.from_set({
            "right": Value.from_list(right),
            "wrong": Value.from_list(wrong),
        })

    def sort(self, cmp: "Value") -> "Value":
        import functools
        def compare(a, b):
            if cmp.call(a).call(b).as_bool():
                return -1
            if cmp.call(b).call(a).as_bool():
                return 1
            return 0
        lst = list(self.as_list())
        lst.sort(key=functools.cmp_to_key(compare))
        return Value.from_list(lst)

    def replace_strings(self, from_: "Value", to: "Value") -> "Value":
        s = self.as_string()
        fl, tl = from_.as_list(), to.as_list()
        for i in range(len(fl)):
            s = s.replace(fl[i].as_string(), tl[i].as_string())
        return Value.from_string(s)

    @staticmethod
    def gen_list(func: "Value", count: int) -> "Value":
        return Value.from_list([func.call(Value.from_int(i)) for i in range(int(count))])

    def ceil(self) -> "Value":
        if self.is_int():
            return self
        return Value.from_int(math.ceil(self.as_float()))

    def floor(self) -> "Value":
        if self.is_int():
            return self
        return Value.from_int(math.floor(self.as_float()))

    def to_string_(self) -> "Value":
        t = self.type
        if t == "null":
            return Value.from_string("")
        if t == "bool":
            return Value.from_string("1" if self.value else "")
        if t == "int":
            return Value.from_string(str(self.value))
        if t == "float":
            return Value.from_string(str(self.value))
        if t == "string":
            return self
        raise RuntimeError(f"wechselbalg: cannot convert {self.type} to string")

    def to_json_(self) -> "Value":
        t = self.type
        if t == "null":
            return Value.from_string("null")
        if t == "bool":
            return Value.from_string("true" if self.value else "false")
        if t == "int":
            return Value.from_string(str(self.value))
        if t == "float":
            return Value.from_string(json.dumps(self.value))
        if t == "string":
            return Value.from_string(json.dumps(self.value))
        if t == "list":
            return Value.from_string("[" + ",".join(e.to_json_().as_string() for e in self.value) + "]")
        if t == "set":
            s = self.value
            pairs = []
            for k in sorted(s.keys()):
                pairs.append(json.dumps(k) + ":" + s[k].to_json_().as_string())
            return Value.from_string("{" + ",".join(pairs) + "}")
        if t == "lambda":
            raise RuntimeError("wechselbalg: cannot serialize lambda to JSON")
        raise RuntimeError(f"wechselbalg: cannot serialize {self.type} to JSON")

    @staticmethod
    def from_json_(s) -> "Value":
        st = s if isinstance(s, str) else s.as_string()
        return Value._from_py_value(json.loads(st))

    @staticmethod
    def _from_py_value(v) -> "Value":
        if v is None:
            return Value.null_()
        if isinstance(v, bool):
            return Value.from_bool(v)
        if isinstance(v, int):
            return Value.from_int(v)
        if isinstance(v, float):
            return Value.from_float(v)
        if isinstance(v, str):
            return Value.from_string(v)
        if isinstance(v, list):
            return Value.from_list([Value._from_py_value(e) for e in v])
        if isinstance(v, dict):
            return Value.from_set({k: Value._from_py_value(val) for k, val in v.items()})
        raise RuntimeError(f"wechselbalg: cannot convert Python value to Value")

    def __repr__(self) -> str:
        return f"Value({self.type}, {self.value!r})"


def __wb_select_or(fn, default_val):
    """Helper for attribute selection with a default value (try/except in expression context)."""
    try:
        return fn()
    except RuntimeError:
        return default_val


def __wb_add(a, b):
    return a.add(b)

def __wb_sub(a, b):
    return a.sub(b)

def __wb_mul(a, b):
    return a.mul(b)

def __wb_div(a, b):
    return a.div(b)


# ── Primop helpers (complex operations that can't be one-liner lambdas) ───

def __wb_trace(msg, val):
    print("[trace]", msg.as_string(), file=sys.stderr)
    return val

def __wb_warn(msg, val):
    print("[warn]", msg.as_string(), file=sys.stderr)
    return val

def __wb_abort(msg):
    raise RuntimeError("abort: " + msg.as_string())

def __wb_throw(msg):
    raise RuntimeError(msg.as_string())

def __wb_try_eval(e):
    try:
        # Force the value to see if it throws
        if isinstance(e, _Thunk):
            v = e._force()
        else:
            v = e
        return Value.from_set({"success": Value.from_bool(True), "value": v})
    except Exception:
        return Value.from_set({"success": Value.from_bool(False), "value": Value.from_bool(False)})

def __wb_split(regex_str, s):
    pattern = re.compile(regex_str.as_string())
    string = s.as_string()
    parts = []
    last_end = 0
    for m in pattern.finditer(string):
        parts.append(Value.from_string(string[last_end:m.start()]))
        parts.append(Value.from_list([Value.from_string(m.group(0))]))
        last_end = m.end()
    parts.append(Value.from_string(string[last_end:]))
    return Value.from_list(parts)

def __wb_match(regex_str, s):
    m = re.fullmatch(regex_str.as_string(), s.as_string())
    if m is None:
        return Value.null_()
    return Value.from_list([
        Value.null_() if g is None else Value.from_string(g)
        for g in m.groups()
    ])

def __wb_zip_attrs_with(f, list_val):
    combined: dict[str, list] = {}
    for s in list_val.as_list():
        for k in s.as_set().keys():
            if k not in combined:
                combined[k] = []
            combined[k].append(s.as_set()[k])
    r = {}
    for k, v in combined.items():
        r[k] = f.call(Value.from_string(k)).call(Value.from_list(v))
    return Value.from_set(r)

def __wb_parse_drv_name(s):
    string = s.as_string()
    m = re.match(r"^(.+?)-([0-9].*)$", string)
    if m:
        return Value.from_set({
            "name": Value.from_string(m.group(1)),
            "version": Value.from_string(m.group(2)),
        })
    return Value.from_set({
        "name": s,
        "version": Value.from_string(""),
    })

def __wb_compare_versions(a, b):
    pa = a.as_string().split(".")
    pb = b.as_string().split(".")
    length = max(len(pa), len(pb))
    for i in range(length):
        na = int(pa[i]) if i < len(pa) else 0
        nb = int(pb[i]) if i < len(pb) else 0
        if na < nb:
            return Value.from_int(-1)
        if na > nb:
            return Value.from_int(1)
    return Value.from_int(0)

def __wb_split_version(s):
    return Value.from_list([
        Value.from_string(p) for p in re.findall(r"[0-9]+|[^0-9]+", s.as_string())
    ])
