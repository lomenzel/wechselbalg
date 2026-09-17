// Wechselbalg Kotlin Value type.
//
// This file provides the Value class used by toKotlin-generated code.
// Include it in your project before using any wechselbalg output.
//
// API mirrors the JS/Python/C++ Value types for consistency across backends.

package wechselbalg

import java.security.MessageDigest
import java.util.regex.Pattern

class LazySetMap(private val factories: Map<String, () -> Value>) : Map<String, Value> {
    private val cache = mutableMapOf<String, Value>()

    override val entries: Set<Map.Entry<String, Value>>
        get() = keys.map { java.util.AbstractMap.SimpleImmutableEntry(it, getValue(it)) }.toSet()

    override val keys: Set<String>
        get() = factories.keys

    override val size: Int
        get() = factories.size

    override val values: Collection<Value>
        get() = keys.map { getValue(it) }

    override fun containsKey(key: String): Boolean = factories.containsKey(key)

    override fun containsValue(value: Value): Boolean = values.contains(value)

    override fun get(key: String): Value? = if (containsKey(key)) getValue(key) else null

    override fun isEmpty(): Boolean = factories.isEmpty()

    private fun getValue(key: String): Value {
        return cache.getOrPut(key) {
            val factory = factories[key] ?: throw NoSuchElementException("Key $key not found")
            factory()
        }
    }
}

class MergedSetMap(private val base: Value, private val ext: Value) : Map<String, Value> {
    private val cache = mutableMapOf<String, Value>()

    override val keys: Set<String>
        get() {
            val set = LinkedHashSet<String>()
            set.addAll(base.asSet().keys)
            set.addAll(ext.asSet().keys)
            return set
        }

    override val size: Int
        get() = keys.size

    override val entries: Set<Map.Entry<String, Value>>
        get() = keys.map { java.util.AbstractMap.SimpleImmutableEntry(it, getValue(it)) }.toSet()

    override val values: Collection<Value>
        get() = keys.map { getValue(it) }

    override fun containsKey(key: String): Boolean = ext.hasAttr(key) || base.hasAttr(key)

    override fun containsValue(value: Value): Boolean = values.contains(value)

    override fun get(key: String): Value? = if (containsKey(key)) getValue(key) else null

    override fun isEmpty(): Boolean = keys.isEmpty()

    private fun getValue(key: String): Value {
        return cache.getOrPut(key) {
            if (ext.hasAttr(key)) ext.get(key) else base.get(key)
        }
    }
}

class Value private constructor(
    val type: Type,
    private val rawValue: Any?,
    private val thunkFn: (() -> Value)? = null,
    val formals: Map<String, Boolean>? = null
) {
    enum class Type {
        NULL, BOOL, INT, FLOAT, STRING, LIST, SET, LAMBDA, THUNK
    }

    private var cachedVal: Value? = null
    private var forcing = false

    fun force(): Value {
        if (type != Type.THUNK) return this
        if (forcing) throw RuntimeException("wechselbalg: infinite recursion in thunk")
        cachedVal?.let { return it }
        forcing = true
        try {
            var res = thunkFn!!()
            while (res.type == Type.THUNK) {
                res = res.force()
            }
            cachedVal = res
            return res
        } finally {
            forcing = false
        }
    }

    companion object {
        fun null_(): Value = Value(Type.NULL, null)
        fun fromBool(v: Boolean): Value = Value(Type.BOOL, v)
        fun fromInt(v: Long): Value = Value(Type.INT, v)
        fun fromInt(v: Number): Value = Value(Type.INT, v.toLong())
        fun fromFloat(v: Double): Value = Value(Type.FLOAT, v)
        fun fromFloat(v: Number): Value = Value(Type.FLOAT, v.toDouble())
        fun fromString(v: String): Value = Value(Type.STRING, v)
        fun fromList(v: List<Value>): Value = Value(Type.LIST, ArrayList(v))
        fun fromSet(v: Map<String, Value>): Value = Value(Type.SET, v)
        fun lambda(v: (Value) -> Value): Value = Value(Type.LAMBDA, v)
        fun lambdaWithFormals(v: (Value) -> Value, formals: Map<String, Boolean>): Value =
            Value(Type.LAMBDA, v, null, formals)
        fun thunk(fn: () -> Value): Value = Value(Type.THUNK, null, fn)
        fun lazySet(factories: Map<String, () -> Value>): Value = Value(Type.SET, LazySetMap(factories))

        fun _deepEq(a: Value, b: Value): Boolean {
            val fa = a.force()
            val fb = b.force()
            if (fa.type != fb.type) {
                if (fa.isNumber() && fb.isNumber()) {
                    return fa.asFloat() == fb.asFloat()
                }
                return false
            }
            return when (fa.type) {
                Type.NULL -> true
                Type.BOOL -> fa.asBool() == fb.asBool()
                Type.INT -> fa.asInt() == fb.asInt()
                Type.FLOAT -> fa.asFloat() == fb.asFloat()
                Type.STRING -> fa.asString() == fb.asString()
                Type.LIST -> {
                    val al = fa.asList()
                    val bl = fb.asList()
                    if (al.size != bl.size) false
                    else al.indices.all { _deepEq(al[it], bl[it]) }
                }
                Type.SET -> {
                    val asMap = fa.asSet()
                    val bsMap = fb.asSet()
                    val ak = asMap.keys.sorted()
                    val bk = bsMap.keys.sorted()
                    if (ak != bk) false
                    else ak.all { _deepEq(asMap[it]!!, bsMap[it]!!) }
                }
                Type.LAMBDA -> false
                Type.THUNK -> false
            }
        }

        fun genList(func: Value, count: Long): Value {
            val r = ArrayList<Value>(count.toInt())
            for (i in 0L until count) {
                r.add(func.call(fromInt(i)))
            }
            return fromList(r)
        }

        fun fromJSON_(s: Value): Value = fromJSON_(s.asString())

        fun fromJSON_(s: String): Value {
            var idx = 0
            fun skipWs() {
                while (idx < s.length && s[idx].isWhitespace()) idx++
            }
            fun parseValue(): Value {
                skipWs()
                if (idx >= s.length) throw RuntimeException("wechselbalg: unexpected end of JSON")
                return when (val c = s[idx]) {
                    'n' -> {
                        if (s.startsWith("null", idx)) { idx += 4; null_() }
                        else throw RuntimeException("wechselbalg: invalid JSON null at $idx")
                    }
                    't' -> {
                        if (s.startsWith("true", idx)) { idx += 4; fromBool(true) }
                        else throw RuntimeException("wechselbalg: invalid JSON true at $idx")
                    }
                    'f' -> {
                        if (s.startsWith("false", idx)) { idx += 5; fromBool(false) }
                        else throw RuntimeException("wechselbalg: invalid JSON false at $idx")
                    }
                    '"' -> {
                        idx++
                        val sb = StringBuilder()
                        while (idx < s.length) {
                            val ch = s[idx++]
                            if (ch == '"') break
                            if (ch == '\\') {
                                if (idx >= s.length) throw RuntimeException("wechselbalg: invalid escape in JSON")
                                when (val esc = s[idx++]) {
                                    '"' -> sb.append('"')
                                    '\\' -> sb.append('\\')
                                    '/' -> sb.append('/')
                                    'b' -> sb.append('\b')
                                    'f' -> sb.append('\u000C')
                                    'n' -> sb.append('\n')
                                    'r' -> sb.append('\r')
                                    't' -> sb.append('\t')
                                    'u' -> {
                                        val hex = s.substring(idx, idx + 4)
                                        sb.append(hex.toInt(16).toChar())
                                        idx += 4
                                    }
                                    else -> sb.append(esc)
                                }
                            } else {
                                sb.append(ch)
                            }
                        }
                        fromString(sb.toString())
                    }
                    '[' -> {
                        idx++
                        skipWs()
                        val list = mutableListOf<Value>()
                        if (idx < s.length && s[idx] == ']') {
                            idx++
                            return fromList(list)
                        }
                        while (idx < s.length) {
                            list.add(parseValue())
                            skipWs()
                            if (idx < s.length && s[idx] == ',') {
                                idx++
                            } else if (idx < s.length && s[idx] == ']') {
                                idx++
                                break
                            } else {
                                throw RuntimeException("wechselbalg: expected ',' or ']' at $idx")
                            }
                        }
                        fromList(list)
                    }
                    '{' -> {
                        idx++
                        skipWs()
                        val map = mutableMapOf<String, Value>()
                        if (idx < s.length && s[idx] == '}') {
                            idx++
                            return fromSet(map)
                        }
                        while (idx < s.length) {
                            skipWs()
                            val keyVal = parseValue()
                            val key = keyVal.asString()
                            skipWs()
                            if (idx >= s.length || s[idx] != ':') throw RuntimeException("wechselbalg: expected ':' at $idx")
                            idx++
                            val value = parseValue()
                            map[key] = value
                            skipWs()
                            if (idx < s.length && s[idx] == ',') {
                                idx++
                            } else if (idx < s.length && s[idx] == '}') {
                                idx++
                                break
                            } else {
                                throw RuntimeException("wechselbalg: expected ',' or '}' at $idx")
                            }
                        }
                        fromSet(map)
                    }
                    else -> {
                        if (c == '-' || c in '0'..'9') {
                            val start = idx
                            if (s[idx] == '-') idx++
                            while (idx < s.length && s[idx] in '0'..'9') idx++
                            var isFloat = false
                            if (idx < s.length && s[idx] == '.') {
                                isFloat = true
                                idx++
                                while (idx < s.length && s[idx] in '0'..'9') idx++
                            }
                            if (idx < s.length && (s[idx] == 'e' || s[idx] == 'E')) {
                                isFloat = true
                                idx++
                                if (idx < s.length && (s[idx] == '+' || s[idx] == '-')) idx++
                                while (idx < s.length && s[idx] in '0'..'9') idx++
                            }
                            val numStr = s.substring(start, idx)
                            if (isFloat) fromFloat(numStr.toDouble()) else fromInt(numStr.toLong())
                        } else {
                            throw RuntimeException("wechselbalg: unexpected char '$c' at $idx")
                        }
                    }
                }
            }
            return parseValue()
        }

        fun jsonEscape(s: String): String {
            val sb = StringBuilder("\"")
            for (ch in s) {
                when (ch) {
                    '"' -> sb.append("\\\"")
                    '\\' -> sb.append("\\\\")
                    '\b' -> sb.append("\\b")
                    '\u000C' -> sb.append("\\f")
                    '\n' -> sb.append("\\n")
                    '\r' -> sb.append("\\r")
                    '\t' -> sb.append("\\t")
                    else -> if (ch.code < 0x20) {
                        sb.append("\\u%04x".format(ch.code))
                    } else {
                        sb.append(ch)
                    }
                }
            }
            sb.append("\"")
            return sb.toString()
        }
    }

    // ── Type checks ───────────────────────────────────────────────

    fun functionArgs(): Value {
        val f = force()
        if (f.type == Type.SET) return fromSet(emptyMap())
        if (f.type != Type.LAMBDA) throw RuntimeException("wechselbalg: functionArgs requires a function")
        val formalsMap = f.formals ?: return fromSet(emptyMap())
        return fromSet(formalsMap.mapValues { fromBool(it.value) })
    }

    fun isNull(): Boolean = force().type == Type.NULL
    fun isInt(): Boolean = force().type == Type.INT
    fun isFloat(): Boolean = force().type == Type.FLOAT
    fun isBool(): Boolean = force().type == Type.BOOL
    fun isString(): Boolean = force().type == Type.STRING
    fun isNumber(): Boolean = force().let { it.type == Type.INT || it.type == Type.FLOAT }
    fun isList(): Boolean = force().type == Type.LIST
    fun isSet(): Boolean = force().type == Type.SET
    fun isAttrs(): Boolean = force().type == Type.SET
    fun isFunction(): Boolean = force().type == Type.LAMBDA
    fun typeOf(): String = when (force().type) {
        Type.NULL -> "null"
        Type.BOOL -> "bool"
        Type.INT -> "int"
        Type.FLOAT -> "float"
        Type.STRING -> "string"
        Type.LIST -> "list"
        Type.SET -> "set"
        Type.LAMBDA -> "lambda"
        Type.THUNK -> "thunk"
    }

    // ── Accessors ─────────────────────────────────────────────────

    fun asInt(): Long {
        val f = force()
        if (f.type == Type.INT) return f.rawValue as Long
        throw RuntimeException("wechselbalg: expected int, got ${f.type}")
    }

    fun asFloat(): Double {
        val f = force()
        if (f.type == Type.FLOAT) return f.rawValue as Double
        if (f.type == Type.INT) return (f.rawValue as Long).toDouble()
        throw RuntimeException("wechselbalg: expected float, got ${f.type}")
    }

    fun asBool(): Boolean {
        val f = force()
        if (f.type == Type.BOOL) return f.rawValue as Boolean
        throw RuntimeException("wechselbalg: expected bool, got ${f.type}")
    }

    fun asString(): String {
        val f = force()
        if (f.type == Type.STRING) return f.rawValue as String
        throw RuntimeException("wechselbalg: expected string, got ${f.type}")
    }

    @Suppress("UNCHECKED_CAST")
    fun asList(): List<Value> {
        val f = force()
        if (f.type == Type.LIST) return f.rawValue as List<Value>
        throw RuntimeException("wechselbalg: expected list, got ${f.type}")
    }

    @Suppress("UNCHECKED_CAST")
    fun asSet(): Map<String, Value> {
        val f = force()
        if (f.type == Type.SET) return f.rawValue as Map<String, Value>
        throw RuntimeException("wechselbalg: expected set, got ${f.type}")
    }

    @Suppress("UNCHECKED_CAST")
    fun asFunction(): (Value) -> Value {
        val f = force()
        if (f.type == Type.LAMBDA) return f.rawValue as (Value) -> Value
        throw RuntimeException("wechselbalg: expected lambda, got ${f.type}")
    }

    // ── Call ───────────────────────────────────────────────────────

    fun call(arg: Value): Value {
        val f = force()
        if (f.type == Type.SET && f.hasAttr("__functor")) {
            return f.get("__functor").call(f).call(arg)
        }
        if (f.type != Type.LAMBDA) {
            throw RuntimeException("wechselbalg: tried to call a ${f.type}")
        }
        return f.asFunction()(arg)
    }

    // ── Attribute access ──────────────────────────────────────────

    fun get(key: String): Value {
        val f = force()
        if (f.type != Type.SET) throw RuntimeException("wechselbalg: attribute access on ${f.type}")
        val map = f.asSet()
        return map[key] ?: throw RuntimeException("wechselbalg: attribute '$key' not found")
    }

    fun get(key: Value): Value = get(key.asString())

    fun getOr(key: String, def: Value): Value {
        val f = force()
        if (f.type != Type.SET) return def
        return f.asSet()[key] ?: def
    }

    fun getOr(key: Value, def: Value): Value = getOr(key.asString(), def)

    fun hasAttr(key: String): Boolean {
        val f = force()
        if (f.type != Type.SET) return false
        return f.asSet().containsKey(key)
    }

    fun hasAttr(key: Value): Boolean = hasAttr(key.asString())

    // ── Comparison ────────────────────────────────────────────────

    fun eq(other: Value): Value = fromBool(_deepEq(this, other))

    fun lessThan(other: Value): Value {
        val fa = force()
        val fb = other.force()
        if (fa.isInt() && fb.isInt()) return fromBool(fa.asInt() < fb.asInt())
        if (fa.isNumber() && fb.isNumber()) return fromBool(fa.asFloat() < fb.asFloat())
        if (fa.isString() && fb.isString()) return fromBool(fa.asString() < fb.asString())
        throw RuntimeException("wechselbalg: cannot compare ${fa.type} < ${fb.type}")
    }

    // ── Arithmetic ────────────────────────────────────────────────

    fun add(other: Value): Value {
        val fa = force()
        val fb = other.force()
        if (fa.isInt() && fb.isInt()) return fromInt(fa.asInt() + fb.asInt())
        if (fa.isNumber() && fb.isNumber()) return fromFloat(fa.asFloat() + fb.asFloat())
        if (fa.isString() && fb.isString()) return fromString(fa.asString() + fb.asString())
        throw RuntimeException("wechselbalg: cannot add ${fa.type} and ${fb.type}")
    }

    fun sub(other: Value): Value {
        val fa = force()
        val fb = other.force()
        if (fa.isInt() && fb.isInt()) return fromInt(fa.asInt() - fb.asInt())
        if (fa.isNumber() && fb.isNumber()) return fromFloat(fa.asFloat() - fb.asFloat())
        throw RuntimeException("wechselbalg: cannot subtract ${fa.type} and ${fb.type}")
    }

    fun mul(other: Value): Value {
        val fa = force()
        val fb = other.force()
        if (fa.isInt() && fb.isInt()) return fromInt(fa.asInt() * fb.asInt())
        if (fa.isNumber() && fb.isNumber()) return fromFloat(fa.asFloat() * fb.asFloat())
        throw RuntimeException("wechselbalg: cannot multiply ${fa.type} and ${fb.type}")
    }

    fun div(other: Value): Value {
        val fa = force()
        val fb = other.force()
        if (fa.isInt() && fb.isInt()) {
            val b = fb.asInt()
            if (b == 0L) throw RuntimeException("wechselbalg: division by zero")
            return fromInt(fa.asInt() / b)
        }
        if (fa.isNumber() && fb.isNumber()) {
            val b = fb.asFloat()
            if (b == 0.0) throw RuntimeException("wechselbalg: division by zero")
            return fromFloat(fa.asFloat() / b)
        }
        throw RuntimeException("wechselbalg: cannot divide ${fa.type} and ${fb.type}")
    }

    fun negate(): Value = fromBool(!asBool())

    // ── Collection operations ─────────────────────────────────────

    fun update(other: Value): Value = fromSet(MergedSetMap(this, other))

    fun concat(other: Value): Value {
        val l1 = asList()
        val l2 = other.asList()
        val r = ArrayList<Value>(l1.size + l2.size)
        r.addAll(l1)
        r.addAll(l2)
        return fromList(r)
    }

    fun at(index: Long): Value {
        val l = asList()
        if (index < 0 || index >= l.size) throw RuntimeException("wechselbalg: index out of bounds")
        return l[index.toInt()]
    }

    fun at(index: Value): Value = at(index.asInt())

    fun head(): Value {
        val l = asList()
        if (l.isEmpty()) throw RuntimeException("wechselbalg: head of empty list")
        return l[0]
    }

    fun tail(): Value {
        val l = asList()
        if (l.isEmpty()) throw RuntimeException("wechselbalg: tail of empty list")
        return fromList(l.subList(1, l.size))
    }

    fun length(): Value = fromInt(asList().size.toLong())

    fun map(func: Value): Value = fromList(asList().map { func.call(it) })

    fun filter(func: Value): Value = fromList(asList().filter { func.call(it).asBool() })

    fun foldl(op: Value, acc: Value): Value {
        var current = acc
        for (e in asList()) {
            current = op.call(current).call(e)
        }
        return current
    }

    fun all(func: Value): Value = fromBool(asList().all { func.call(it).asBool() })

    fun any(func: Value): Value = fromBool(asList().any { func.call(it).asBool() })

    fun elem(item: Value): Value = fromBool(asList().any { _deepEq(it, item) })

    fun concatMap(func: Value): Value {
        val r = mutableListOf<Value>()
        for (e in asList()) {
            r.addAll(func.call(e).asList())
        }
        return fromList(r)
    }

    fun concatStringsSep(sep: Value): Value = concatStringsSep(sep.asString())

    fun concatStringsSep(sep: String): Value =
        fromString(asList().joinToString(sep) { it.asString() })

    fun attrNames(): Value =
        fromList(asSet().keys.sorted().map { fromString(it) })

    fun attrValues(): Value {
        val s = asSet()
        return fromList(s.keys.sorted().map { s[it]!! })
    }

    fun removeAttrs(names: Value): Value {
        val orig = asSet()
        val remove = names.asList().map { it.asString() }.toSet()
        val factories = mutableMapOf<String, () -> Value>()
        for (k in orig.keys) {
            if (!remove.contains(k)) {
                val key = k
                factories[key] = { orig[key]!! }
            }
        }
        return lazySet(factories)
    }

    fun listToAttrs(): Value {
        val map = mutableMapOf<String, Value>()
        for (e in asList()) {
            val nameVal = e.get("name")
            if (!nameVal.isNull()) {
                map[nameVal.asString()] = e.get("value")
            }
        }
        return fromSet(map)
    }

    fun mapAttrs(f: Value): Value {
        val s = asSet()
        val factories = mutableMapOf<String, () -> Value>()
        for (k in s.keys) {
            val key = k
            factories[key] = { f.call(fromString(key)).call(s[key]!!) }
        }
        return lazySet(factories)
    }

    fun intersectAttrs(other: Value): Value {
        val a = asSet()
        val b = other.asSet()
        val r = mutableMapOf<String, Value>()
        for (k in a.keys) {
            if (b.containsKey(k)) r[k] = b[k]!!
        }
        return fromSet(r)
    }

    fun catAttrs(attr: Value): Value = catAttrs(attr.asString())

    fun catAttrs(attr: String): Value =
        fromList(asList().filter { it.hasAttr(attr) }.map { it.get(attr) })

    fun groupBy(f: Value): Value {
        val groups = mutableMapOf<String, MutableList<Value>>()
        for (e in asList()) {
            val k = f.call(e).asString()
            groups.getOrPut(k) { mutableListOf() }.add(e)
        }
        val r = mutableMapOf<String, Value>()
        for ((k, v) in groups) {
            r[k] = fromList(v)
        }
        return fromSet(r)
    }

    fun partition(pred: Value): Value {
        val right = mutableListOf<Value>()
        val wrong = mutableListOf<Value>()
        for (e in asList()) {
            if (pred.call(e).asBool()) right.add(e) else wrong.add(e)
        }
        return fromSet(mapOf("right" to fromList(right), "wrong" to fromList(wrong)))
    }

    fun sort(cmp: Value): Value {
        val l = ArrayList(asList())
        l.sortWith { a, b ->
            if (cmp.call(a).call(b).asBool()) -1
            else if (cmp.call(b).call(a).asBool()) 1
            else 0
        }
        return fromList(l)
    }

    fun replaceStrings(from: Value, to: Value): Value {
        var s = asString()
        val fl = from.asList()
        val tl = to.asList()
        for (i in fl.indices) {
            s = s.replace(fl[i].asString(), tl[i].asString())
        }
        return fromString(s)
    }

    fun ceil(): Value {
        if (isInt()) return this
        return fromInt(Math.ceil(asFloat()).toLong())
    }

    fun floor(): Value {
        if (isInt()) return this
        return fromInt(Math.floor(asFloat()).toLong())
    }

    fun toString_(): Value = when (force().type) {
        Type.NULL -> fromString("")
        Type.BOOL -> fromString(if (asBool()) "1" else "")
        Type.INT -> fromString(asInt().toString())
        Type.FLOAT -> fromString(asFloat().toString())
        Type.STRING -> this
        else -> throw RuntimeException("wechselbalg: cannot convert $type to string")
    }

    fun toJSON_(): Value = when (force().type) {
        Type.NULL -> fromString("null")
        Type.BOOL -> fromString(if (asBool()) "true" else "false")
        Type.INT -> fromString(asInt().toString())
        Type.FLOAT -> fromString(asFloat().toString())
        Type.STRING -> fromString(jsonEscape(asString()))
        Type.LIST -> {
            val elements = asList().map { it.toJSON_().asString() }
            fromString("[${elements.joinToString(",")}]")
        }
        Type.SET -> {
            val s = asSet()
            val pairs = s.keys.sorted().map {
                "${jsonEscape(it)}:${s[it]!!.toJSON_().asString()}"
            }
            fromString("{${pairs.joinToString(",")}}")
        }
        Type.LAMBDA -> throw RuntimeException("wechselbalg: cannot serialize lambda to JSON")
        Type.THUNK -> force().toJSON_()
    }
}

object Primops {
    fun substring(start: Value, len: Value, s: Value): Value {
        val str = s.asString()
        val st = start.asInt().toInt()
        val l = len.asInt().toInt()
        if (st < 0 || st >= str.length) return Value.fromString("")
        if (l < 0) return Value.fromString(str.substring(st))
        val end = minOf(st + l, str.length)
        return Value.fromString(str.substring(st, end))
    }

    fun stringLength(s: Value): Value = Value.fromInt(s.asString().length.toLong())

    fun split(regexVal: Value, sVal: Value): Value {
        val pattern = Pattern.compile(regexVal.asString())
        val matcher = pattern.matcher(sVal.asString())
        val string = sVal.asString()
        val parts = mutableListOf<Value>()
        var lastEnd = 0
        while (matcher.find()) {
            parts.add(Value.fromString(string.substring(lastEnd, matcher.start())))
            val groupCount = matcher.groupCount()
            val matched = (1..groupCount).map { i ->
                val g = matcher.group(i)
                if (g == null) Value.null_() else Value.fromString(g)
            }
            parts.add(Value.fromList(matched))
            lastEnd = matcher.end()
        }
        parts.add(Value.fromString(string.substring(lastEnd)))
        return Value.fromList(parts)
    }

    fun match(regexVal: Value, sVal: Value): Value {
        val pattern = Pattern.compile(regexVal.asString())
        val matcher = pattern.matcher(sVal.asString())
        if (!matcher.matches()) return Value.null_()
        val groupCount = matcher.groupCount()
        val list = (1..groupCount).map { i ->
            val g = matcher.group(i)
            if (g == null) Value.null_() else Value.fromString(g)
        }
        return Value.fromList(list)
    }

    fun hashString(algo: Value, s: Value): Value {
        val algoName = when (algo.asString().lowercase()) {
            "sha256" -> "SHA-256"
            "sha512" -> "SHA-512"
            "sha1" -> "SHA-1"
            "md5" -> "MD5"
            else -> "SHA-256"
        }
        val md = MessageDigest.getInstance(algoName)
        val digest = md.digest(s.asString().toByteArray(Charsets.UTF_8))
        return Value.fromString(digest.joinToString("") { "%02x".format(it) })
    }

    fun genericClosure(args: Value): Value {
        val startSet = args.get("startSet").asList()
        val op = args.get("operator")
        val result = mutableListOf<Value>()
        val seen = mutableSetOf<String>()
        val work = ArrayDeque<Value>(startSet)
        while (work.isNotEmpty()) {
            val item = work.removeFirst()
            val key = item.get("key").toJSON_().asString()
            if (seen.add(key)) {
                result.add(item)
                val newItems = op.call(item).asList()
                work.addAll(newItems)
            }
        }
        return Value.fromList(result)
    }

    fun zipAttrsWith(f: Value, listVal: Value): Value {
        val sets = listVal.asList().map { it.asSet() }
        val allKeys = LinkedHashSet<String>()
        for (s in sets) {
            allKeys.addAll(s.keys)
        }
        val factories = mutableMapOf<String, () -> Value>()
        for (k in allKeys) {
            val key = k
            factories[key] = {
                val vals = mutableListOf<Value>()
                for (s in sets) {
                    if (s.containsKey(key)) {
                        vals.add(s[key]!!)
                    }
                }
                f.call(Value.fromString(key)).call(Value.fromList(vals))
            }
        }
        return Value.lazySet(factories)
    }

    fun parseDrvName(sVal: Value): Value {
        val s = sVal.asString()
        val match = Regex("""^(.+?)-([0-9].*)$""").find(s)
        return if (match != null) {
            Value.fromSet(mapOf(
                "name" to Value.fromString(match.groupValues[1]),
                "version" to Value.fromString(match.groupValues[2])
            ))
        } else {
            Value.fromSet(mapOf(
                "name" to sVal,
                "version" to Value.fromString("")
            ))
        }
    }

    fun compareVersions(aVal: Value, bVal: Value): Value {
        val pa = aVal.asString().split(".")
        val pb = bVal.asString().split(".")
        val len = maxOf(pa.size, pb.size)
        for (i in 0 until len) {
            val na = if (i < pa.size) pa[i].toLongOrNull() ?: 0L else 0L
            val nb = if (i < pb.size) pb[i].toLongOrNull() ?: 0L else 0L
            if (na < nb) return Value.fromInt(-1L)
            if (na > nb) return Value.fromInt(1L)
        }
        return Value.fromInt(0L)
    }

    fun splitVersion(sVal: Value): Value {
        val parts = Regex("""[0-9]+|[^0-9]+""").findAll(sVal.asString()).map { Value.fromString(it.value) }.toList()
        return Value.fromList(parts)
    }

    fun tryEval(e: Value): Value {
        return try {
            val v = e.force()
            Value.fromSet(mapOf("success" to Value.fromBool(true), "value" to v))
        } catch (_: Throwable) {
            Value.fromSet(mapOf("success" to Value.fromBool(false), "value" to Value.fromBool(false)))
        }
    }
}
