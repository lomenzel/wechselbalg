use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

pub struct ThunkState {
    pub func: Option<Box<dyn FnOnce() -> Value>>,
    pub value: Option<Value>,
    pub computing: bool,
}

#[derive(Clone)]
pub struct Meta {
    pub ast: Option<String>,
    pub primop: Option<String>,
    pub env: Option<Value>,
}

#[derive(Clone)]
pub struct LambdaData {
    pub func: Rc<dyn Fn(Value) -> Value>,
    pub formals: Option<HashMap<String, bool>>,
    pub meta: Option<Rc<Meta>>,
}

#[derive(Clone)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(Rc<String>),
    List(Rc<Vec<Value>>),
    Set(Rc<HashMap<String, Value>>),
    Lambda(Rc<LambdaData>),
    Thunk(Rc<RefCell<ThunkState>>),
}

impl Value {
    #[inline(always)]
    pub fn get(cell: &Rc<RefCell<Value>>) -> Value {
        cell.borrow().clone()
    }

    // ── Constructors ──────────────────────────────────────────────
    pub fn null_() -> Self { Value::Null }
    pub fn from_bool(v: bool) -> Self { Value::Bool(v) }
    pub fn from_int(v: i64) -> Self { Value::Int(v) }
    pub fn from_float(v: f64) -> Self { Value::Float(v) }
    pub fn from_str(v: &str) -> Self { Value::String(Rc::new(v.to_string())) }
    pub fn from_list(v: Vec<Value>) -> Self { Value::List(Rc::new(v)) }
    pub fn from_set(v: Vec<(String, Value)>) -> Self {
        Value::Set(Rc::new(v.into_iter().collect()))
    }

    pub fn lambda<F>(f: F) -> Self
    where
        F: Fn(Value) -> Value + 'static,
    {
        Value::Lambda(Rc::new(LambdaData {
            func: Rc::new(f),
            formals: None,
            meta: None,
        }))
    }

    pub fn lambda_with_meta<F>(
        f: F,
        formals: Option<Vec<(String, bool)>>,
        ast: Option<&str>,
        env: Option<Value>,
    ) -> Self
    where
        F: Fn(Value) -> Value + 'static,
    {
        let formals_map = formals.map(|v| v.into_iter().collect());
        let meta = if ast.is_some() || env.is_some() {
            let env_opt = match env {
                Some(e) => {
                    if matches!(e.force(), Value::Null) { None } else { Some(e) }
                }
                None => None,
            };
            Some(Rc::new(Meta {
                ast: ast.map(|s| s.to_string()),
                primop: None,
                env: env_opt,
            }))
        } else {
            None
        };
        Value::Lambda(Rc::new(LambdaData {
            func: Rc::new(f),
            formals: formals_map,
            meta,
        }))
    }

    pub fn primop(name: &str, val: Value) -> Value {
        let forced = val.force();
        match forced {
            Value::Lambda(l) => {
                let mut data = (*l).clone();
                data.meta = Some(Rc::new(Meta {
                    ast: None,
                    primop: Some(name.to_string()),
                    env: None,
                }));
                Value::Lambda(Rc::new(data))
            }
            other => panic!("Value::primop expected lambda, got {}", other.type_of()),
        }
    }

    pub fn thunk<F>(f: F) -> Self
    where
        F: FnOnce() -> Value + 'static,
    {
        Value::Thunk(Rc::new(RefCell::new(ThunkState {
            func: Some(Box::new(f)),
            value: None,
            computing: false,
        })))
    }

    // ── Lazy Evaluation ───────────────────────────────────────────
    pub fn force(&self) -> Value {
        match self {
            Value::Thunk(cell) => {
                let cached = {
                    let state = cell.borrow();
                    if state.computing {
                        panic!("wechselbalg: infinite recursion in thunk");
                    }
                    state.value.clone()
                };

                let val = match cached {
                    Some(v) => v,
                    None => {
                        cell.borrow_mut().computing = true;
                        let func = cell.borrow_mut().func.take().expect("thunk missing closure");

                        let evaluated = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| func()));

                        let mut state = cell.borrow_mut();
                        state.computing = false;

                        match evaluated {
                            Ok(v) => {
                                state.value = Some(v.clone());
                                v
                            }
                            Err(e) => std::panic::resume_unwind(e),
                        }
                    }
                };

                val.force()
            }
            other => other.clone(),
        }
    }

    // ── Accessors ─────────────────────────────────────────────────
    pub fn as_int(&self) -> i64 {
        match self.force() {
            Value::Int(v) => v,
            other => panic!("expected int, got {}", other.type_of()),
        }
    }

    pub fn as_float(&self) -> f64 {
        match self.force() {
            Value::Float(v) => v,
            Value::Int(v) => v as f64,
            other => panic!("expected float, got {}", other.type_of()),
        }
    }

    pub fn as_bool(&self) -> bool {
        match self.force() {
            Value::Bool(v) => v,
            other => panic!("expected bool, got {}", other.type_of()),
        }
    }

    pub fn as_str(&self) -> Rc<String> {
        match self.force() {
            Value::String(s) => s,
            other => panic!("expected string, got {}", other.type_of()),
        }
    }

    pub fn as_list(&self) -> Rc<Vec<Value>> {
        match self.force() {
            Value::List(l) => l,
            other => panic!("expected list, got {}", other.type_of()),
        }
    }

    pub fn as_set(&self) -> Rc<HashMap<String, Value>> {
        match self.force() {
            Value::Set(s) => s,
            other => panic!("expected set, got {}", other.type_of()),
        }
    }

    pub fn type_of(&self) -> &'static str {
        match self.force() {
            Value::Null => "null",
            Value::Bool(_) => "bool",
            Value::Int(_) => "int",
            Value::Float(_) => "float",
            Value::String(_) => "string",
            Value::List(_) => "list",
            Value::Set(_) => "set",
            Value::Lambda(_) => "lambda",
            Value::Thunk(_) => "thunk",
        }
    }

    pub fn call(&self, arg: Value) -> Value {
        match self.force() {
            Value::Lambda(l) => (l.func)(arg),
            Value::Set(s) => {
                if let Some(functor) = s.get("__functor") {
                    return functor.call(self.clone()).call(arg);
                }
                panic!("tried to call set without __functor");
            }
            other => panic!("tried to call a {}", other.type_of()),
        }
    }

    pub fn select_attr(&self, key: &str) -> Value {
        match self.force() {
            Value::Set(s) => s
                .get(key)
                .unwrap_or_else(|| panic!("attribute '{}' not found", key))
                .clone(),
            other => panic!("attribute access on {}", other.type_of()),
        }
    }

    pub fn has_attr(&self, key: &str) -> bool {
        match self.force() {
            Value::Set(s) => s.contains_key(key),
            _ => false,
        }
    }

    pub fn add(&self, other: &Value) -> Value {
        let a = self.force();
        let b = other.force();
        match (&a, &b) {
            (Value::Int(x), Value::Int(y)) => Value::from_int(x + y),
            (Value::Int(x), Value::Float(y)) => Value::from_float(*x as f64 + y),
            (Value::Float(x), Value::Int(y)) => Value::from_float(x + *y as f64),
            (Value::Float(x), Value::Float(y)) => Value::from_float(x + y),
            (Value::String(x), Value::String(y)) => Value::from_str(&format!("{}{}", x, y)),
            _ => panic!("cannot add {} and {}", a.type_of(), b.type_of()),
        }
    }

    pub fn sub(&self, other: &Value) -> Value {
        let a = self.force();
        let b = other.force();
        match (&a, &b) {
            (Value::Int(x), Value::Int(y)) => Value::from_int(x - y),
            (Value::Float(x), Value::Float(y)) => Value::from_float(x - y),
            _ => panic!("cannot subtract {} and {}", a.type_of(), b.type_of()),
        }
    }

    pub fn mul(&self, other: &Value) -> Value {
        let a = self.force();
        let b = other.force();
        match (&a, &b) {
            (Value::Int(x), Value::Int(y)) => Value::from_int(x * y),
            (Value::Float(x), Value::Float(y)) => Value::from_float(x * y),
            _ => panic!("cannot multiply {} and {}", a.type_of(), b.type_of()),
        }
    }

    pub fn div(&self, other: &Value) -> Value {
        let a = self.force();
        let b = other.force();
        match (&a, &b) {
            (Value::Int(x), Value::Int(y)) => {
                if *y == 0 { panic!("division by zero"); }
                Value::from_int(x / y)
            }
            (Value::Float(x), Value::Float(y)) => {
                if *y == 0.0 { panic!("division by zero"); }
                Value::from_float(x / y)
            }
            _ => panic!("cannot divide {} and {}", a.type_of(), b.type_of()),
        }
    }

    pub fn deep_eq(&self, other: &Value) -> bool {
        let a = self.force();
        let b = other.force();
        match (&a, &b) {
            (Value::Null, Value::Null) => true,
            (Value::Bool(x), Value::Bool(y)) => x == y,
            (Value::Int(x), Value::Int(y)) => x == y,
            (Value::Float(x), Value::Float(y)) => x == y,
            (Value::String(x), Value::String(y)) => x == y,
            (Value::List(x), Value::List(y)) => {
                x.len() == y.len() && x.iter().zip(y.iter()).all(|(i, j)| i.deep_eq(j))
            }
            (Value::Set(x), Value::Set(y)) => {
                x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).map_or(false, |w| v.deep_eq(w)))
            }
            _ => false,
        }
    }

    pub fn lt(&self, other: &Value) -> bool {
        let a = self.force();
        let b = other.force();
        match (&a, &b) {
            (Value::Int(x), Value::Int(y)) => x < y,
            (Value::Float(x), Value::Float(y)) => x < y,
            (Value::String(x), Value::String(y)) => x < y,
            _ => panic!("cannot compare {} < {}", a.type_of(), b.type_of()),
        }
    }

    pub fn update(&self, other: &Value) -> Value {
        let mut map = (*self.as_set()).clone();
        for (k, v) in other.as_set().iter() {
            map.insert(k.clone(), v.clone());
        }
        Value::Set(Rc::new(map))
    }

    pub fn concat_lists(&self, other: &Value) -> Value {
        let mut list = (*self.as_list()).clone();
        list.extend(other.as_list().iter().cloned());
        Value::List(Rc::new(list))
    }

    pub fn to_json(&self) -> String {
        match self.force() {
            Value::Null => "null".to_string(),
            Value::Bool(b) => if b { "true".to_string() } else { "false".to_string() },
            Value::Int(i) => i.to_string(),
            Value::Float(f) => f.to_string(),
            Value::String(s) => format!("\"{}\"", s.escape_default()),
            Value::List(l) => {
                let items: Vec<String> = l.iter().map(|v| v.to_json()).collect();
                format!("[{}]", items.join(","))
            }
            Value::Set(s) => {
                let mut keys: Vec<&String> = s.keys().collect();
                keys.sort();
                let items: Vec<String> = keys
                    .into_iter()
                    .map(|k| format!("\"{}\":{}", k, s[k].to_json()))
                    .collect();
                format!("{{{}}}", items.join(","))
            }
            Value::Lambda(_) => panic!("cannot serialize lambda to JSON"),
            Value::Thunk(_) => unreachable!(),
        }
    }

    // ── JSON Parsing (fromJSON) ──────────────────────────────────
    pub fn from_json(s: &str) -> Value {
        let chars: Vec<char> = s.chars().collect();
        let mut pos = 0;
        Self::parse_json(&chars, &mut pos)
    }

    fn skip_ws(chars: &[char], pos: &mut usize) {
        while *pos < chars.len() && chars[*pos].is_ascii_whitespace() {
            *pos += 1;
        }
    }

    fn parse_json(chars: &[char], pos: &mut usize) -> Value {
        Self::skip_ws(chars, pos);
        if *pos >= chars.len() {
            panic!("fromJSON: unexpected end of input");
        }
        match chars[*pos] {
            '"' => Value::from_str(&Self::parse_json_str(chars, pos)),
            '{' => Self::parse_json_obj(chars, pos),
            '[' => Self::parse_json_arr(chars, pos),
            't' => {
                if *pos + 4 <= chars.len() && &chars[*pos..*pos + 4] == ['t', 'r', 'u', 'e'] {
                    *pos += 4;
                    Value::from_bool(true)
                } else {
                    panic!("fromJSON: unexpected token");
                }
            }
            'f' => {
                if *pos + 5 <= chars.len() && &chars[*pos..*pos + 5] == ['f', 'a', 'l', 's', 'e'] {
                    *pos += 5;
                    Value::from_bool(false)
                } else {
                    panic!("fromJSON: unexpected token");
                }
            }
            'n' => {
                if *pos + 4 <= chars.len() && &chars[*pos..*pos + 4] == ['n', 'u', 'l', 'l'] {
                    *pos += 4;
                    Value::null_()
                } else {
                    panic!("fromJSON: unexpected token");
                }
            }
            _ => Self::parse_json_num(chars, pos),
        }
    }

    fn parse_json_str(chars: &[char], pos: &mut usize) -> String {
        *pos += 1;
        let mut out = String::new();
        while *pos < chars.len() && chars[*pos] != '"' {
            if chars[*pos] == '\\' {
                *pos += 1;
                if *pos >= chars.len() { panic!("fromJSON: unexpected end in string escape"); }
                match chars[*pos] {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'b' => out.push('\x08'),
                    'f' => out.push('\x0c'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'u' => {
                        *pos += 1;
                        if *pos + 4 > chars.len() { panic!("fromJSON: invalid unicode escape"); }
                        let hex_str: String = chars[*pos..*pos + 4].iter().collect();
                        *pos += 3;
                        let cp = u32::from_str_radix(&hex_str, 16).expect("invalid unicode");
                        out.push(char::from_u32(cp).unwrap_or('\u{FFFD}'));
                    }
                    c => out.push(c),
                }
            } else {
                out.push(chars[*pos]);
            }
            *pos += 1;
        }
        if *pos >= chars.len() { panic!("fromJSON: unterminated string"); }
        *pos += 1;
        out
    }

    fn parse_json_num(chars: &[char], pos: &mut usize) -> Value {
        let start = *pos;
        let mut is_float = false;
        if *pos < chars.len() && (chars[*pos] == '-' || chars[*pos] == '+') { *pos += 1; }
        while *pos < chars.len() && chars[*pos].is_ascii_digit() { *pos += 1; }
        if *pos < chars.len() && chars[*pos] == '.' {
            is_float = true;
            *pos += 1;
            while *pos < chars.len() && chars[*pos].is_ascii_digit() { *pos += 1; }
        }
        if *pos < chars.len() && (chars[*pos] == 'e' || chars[*pos] == 'E') {
            is_float = true;
            *pos += 1;
            if *pos < chars.len() && (chars[*pos] == '-' || chars[*pos] == '+') { *pos += 1; }
            while *pos < chars.len() && chars[*pos].is_ascii_digit() { *pos += 1; }
        }
        let s: String = chars[start..*pos].iter().collect();
        if is_float {
            Value::from_float(s.parse::<f64>().expect("invalid float"))
        } else {
            Value::from_int(s.parse::<i64>().expect("invalid int"))
        }
    }

    fn parse_json_arr(chars: &[char], pos: &mut usize) -> Value {
        *pos += 1;
        Self::skip_ws(chars, pos);
        if *pos < chars.len() && chars[*pos] == ']' {
            *pos += 1;
            return Value::from_list(Vec::new());
        }
        let mut items = Vec::new();
        loop {
            items.push(Self::parse_json(chars, pos));
            Self::skip_ws(chars, pos);
            if *pos >= chars.len() { panic!("fromJSON: unterminated array"); }
            if chars[*pos] == ',' {
                *pos += 1;
                continue;
            }
            if chars[*pos] == ']' {
                *pos += 1;
                return Value::from_list(items);
            }
            panic!("fromJSON: expected ',' or ']'");
        }
    }

    fn parse_json_obj(chars: &[char], pos: &mut usize) -> Value {
        *pos += 1;
        Self::skip_ws(chars, pos);
        if *pos < chars.len() && chars[*pos] == '}' {
            *pos += 1;
            return Value::from_set(Vec::new());
        }
        let mut entries = Vec::new();
        loop {
            Self::skip_ws(chars, pos);
            if *pos >= chars.len() || chars[*pos] != '"' { panic!("fromJSON: expected string key"); }
            let key = Self::parse_json_str(chars, pos);
            Self::skip_ws(chars, pos);
            if *pos >= chars.len() || chars[*pos] != ':' { panic!("fromJSON: expected ':'"); }
            *pos += 1;
            let val = Self::parse_json(chars, pos);
            entries.push((key, val));
            Self::skip_ws(chars, pos);
            if *pos >= chars.len() { panic!("fromJSON: unterminated object"); }
            if chars[*pos] == ',' {
                *pos += 1;
                continue;
            }
            if chars[*pos] == '}' {
                *pos += 1;
                return Value::from_set(entries);
            }
            panic!("fromJSON: expected ',' or '}}'");
        }
    }

    pub fn is_set(&self) -> bool {
        matches!(self.force(), Value::Set(_))
    }

    pub fn is_list(&self) -> bool {
        matches!(self.force(), Value::List(_))
    }

    pub fn is_attrs(&self) -> bool {
        matches!(self.force(), Value::Set(_))
    }

    pub fn is_function(&self) -> bool {
        matches!(self.force(), Value::Lambda(_))
    }

    pub fn same_function(a: &Value, b: &Value) -> bool {
        let fa = a.force();
        let fb = b.force();
        match (&fa, &fb) {
            (Value::Lambda(la), Value::Lambda(lb)) => {
                let pa = la.meta.as_ref().and_then(|m| m.primop.as_ref());
                let pb = lb.meta.as_ref().and_then(|m| m.primop.as_ref());
                if pa.is_some() || pb.is_some() {
                    return pa == pb;
                }
                if Rc::ptr_eq(la, lb) {
                    return true;
                }
                match (&la.meta, &lb.meta) {
                    (Some(ma), Some(mb)) => Rc::ptr_eq(ma, mb),
                    _ => false,
                }
            }
            _ => panic!("wechselbalg: sameFunction expects two functions"),
        }
    }

    pub fn function_args(&self) -> Value {
        match self.force() {
            Value::Lambda(l) => {
                let entries = match &l.formals {
                    Some(m) => m
                        .iter()
                        .map(|(k, v)| (k.clone(), Value::from_bool(*v)))
                        .collect(),
                    None => Vec::new(),
                };
                Value::from_set(entries)
            }
            _ => panic!("wechselbalg: functionArgs requires a function"),
        }
    }

    pub fn reify(&self) -> Value {
        let f = self.force();
        match f {
            Value::Lambda(l) => {
                let meta = match &l.meta {
                    Some(m) => m,
                    None => panic!(
                        "wechselbalg: reify: this function carries no AST (not generated by wechselbalg)"
                    ),
                };
                if let Some(primop_name) = &meta.primop {
                    return Value::from_set(vec![
                        ("_expr".to_string(), Value::from_str("primop")),
                        ("value".to_string(), Value::from_str(primop_name)),
                    ]);
                }
                let ast_str = match &meta.ast {
                    Some(a) => a,
                    None => panic!(
                        "wechselbalg: reify: this function carries no AST (not generated by wechselbalg)"
                    ),
                };
                let parsed = Value::from_json(ast_str);
                let env_rc = meta.env.as_ref().map(|e| Rc::new(e.clone()));
                Self::reify_node(&parsed, env_rc)
            }
            _ => panic!("wechselbalg: reify expects a function"),
        }
    }

    fn reify_node(node: &Value, env: Option<Rc<Value>>) -> Value {
        let forced = node.force();
        match forced {
            Value::List(l) => {
                let out: Vec<Value> = l
                    .iter()
                    .map(|e| Self::reify_node(e, env.clone()))
                    .collect();
                Value::from_list(out)
            }
            Value::Set(s) => {
                let mut out = Vec::new();
                let mut free = false;
                for (k, v) in s.iter() {
                    if k == "__free" {
                        free = true;
                        continue;
                    }
                    out.push((k.clone(), Self::reify_node(v, env.clone())));
                }
                if free {
                    let name = s
                        .get("name")
                        .expect("free var missing name")
                        .as_str()
                        .to_string();
                    let env_clone = env.clone();
                    out.push((
                        "closureEnvValue".to_string(),
                        Value::thunk(move || {
                            Self::env_lookup(env_clone.as_deref(), &name)
                        }),
                    ));
                }
                Value::from_set(out)
            }
            other => other,
        }
    }

    fn env_lookup(env: Option<&Value>, name: &str) -> Value {
        let env_val = match env {
            Some(e) => e,
            None => panic!("wechselbalg: reify: '{}' has no captured environment", name),
        };
        if env_val.has_attr(name) {
            return env_val.select_attr(name);
        }
        let prefix = format!("{}.", name);
        let mut out: std::collections::BTreeMap<String, Value> =
            std::collections::BTreeMap::new();
        let mut any = false;
        let env_set = env_val.as_set();
        for k in env_set.keys() {
            if !k.starts_with(&prefix) {
                continue;
            }
            any = true;
            let rest = &k[prefix.len()..];
            let head = match rest.find('.') {
                Some(idx) => &rest[..idx],
                None => rest,
            };
            if !out.contains_key(head) {
                let sub = format!("{}.{}", name, head);
                let env_rc = Some(Rc::new(env_val.clone()));
                out.insert(
                    head.to_string(),
                    Value::thunk(move || {
                        Self::env_lookup(env_rc.as_deref(), &sub)
                    }),
                );
            }
        }
        if !any {
            panic!(
                "wechselbalg: reify: captured variable '{}' is unavailable",
                name
            );
        }
        Value::from_set(out.into_iter().collect())
    }

    pub fn regex_compile(pattern: &str) -> CompiledRegex {
        CompiledRegex::compile(pattern)
    }
}

#[derive(Debug, Clone)]
pub enum RegexAtom {
    Char(char),
    Any,
    Class {
        ranges: Vec<(char, char)>,
        inverted: bool,
    },
    Group(RegexAST, usize),
    NonCapturing(RegexAST),
}

#[derive(Debug, Clone)]
pub enum RegexPiece {
    Atom(RegexAtom),
    Star(RegexAtom),
    Plus(RegexAtom),
    Opt(RegexAtom),
}

#[derive(Debug, Clone)]
pub struct RegexBranch {
    pub pieces: Vec<RegexPiece>,
}

#[derive(Debug, Clone)]
pub struct RegexAST {
    pub branches: Vec<RegexBranch>,
}

pub struct CompiledRegex {
    pub ast: RegexAST,
    pub num_groups: usize,
}

impl CompiledRegex {
    pub fn compile(pattern: &str) -> Self {
        let chars: Vec<char> = pattern.chars().collect();
        let mut pos = 0;
        let mut group_counter = 0;
        let ast = Self::parse_regex(&chars, &mut pos, &mut group_counter);
        CompiledRegex {
            ast,
            num_groups: group_counter,
        }
    }

    fn parse_regex(chars: &[char], pos: &mut usize, group_counter: &mut usize) -> RegexAST {
        let mut branches = Vec::new();
        branches.push(Self::parse_branch(chars, pos, group_counter));
        while *pos < chars.len() && chars[*pos] == '|' {
            *pos += 1;
            branches.push(Self::parse_branch(chars, pos, group_counter));
        }
        RegexAST { branches }
    }

    fn parse_branch(
        chars: &[char],
        pos: &mut usize,
        group_counter: &mut usize,
    ) -> RegexBranch {
        let mut pieces = Vec::new();
        while *pos < chars.len() && chars[*pos] != '|' && chars[*pos] != ')' {
            pieces.push(Self::parse_piece(chars, pos, group_counter));
        }
        RegexBranch { pieces }
    }

    fn parse_piece(
        chars: &[char],
        pos: &mut usize,
        group_counter: &mut usize,
    ) -> RegexPiece {
        let atom = Self::parse_atom(chars, pos, group_counter);
        if *pos < chars.len() {
            match chars[*pos] {
                '*' => {
                    *pos += 1;
                    RegexPiece::Star(atom)
                }
                '+' => {
                    *pos += 1;
                    RegexPiece::Plus(atom)
                }
                '?' => {
                    *pos += 1;
                    RegexPiece::Opt(atom)
                }
                _ => RegexPiece::Atom(atom),
            }
        } else {
            RegexPiece::Atom(atom)
        }
    }

    fn parse_atom(
        chars: &[char],
        pos: &mut usize,
        group_counter: &mut usize,
    ) -> RegexAtom {
        if *pos >= chars.len() {
            panic!("regex: unexpected end of pattern");
        }
        match chars[*pos] {
            '.' => {
                *pos += 1;
                RegexAtom::Any
            }
            '(' => {
                *pos += 1;
                if *pos + 1 < chars.len() && chars[*pos] == '?' && chars[*pos + 1] == ':' {
                    *pos += 2;
                    let inner = Self::parse_regex(chars, pos, group_counter);
                    if *pos < chars.len() && chars[*pos] == ')' {
                        *pos += 1;
                    }
                    RegexAtom::NonCapturing(inner)
                } else {
                    *group_counter += 1;
                    let grp = *group_counter;
                    let inner = Self::parse_regex(chars, pos, group_counter);
                    if *pos < chars.len() && chars[*pos] == ')' {
                        *pos += 1;
                    }
                    RegexAtom::Group(inner, grp)
                }
            }
            '[' => {
                *pos += 1;
                let inverted = if *pos < chars.len() && chars[*pos] == '^' {
                    *pos += 1;
                    true
                } else {
                    false
                };
                let mut ranges = Vec::new();
                while *pos < chars.len() && chars[*pos] != ']' {
                    let c1 = Self::parse_char_literal(chars, pos);
                    if *pos + 1 < chars.len() && chars[*pos] == '-' && chars[*pos + 1] != ']' {
                        *pos += 1;
                        let c2 = Self::parse_char_literal(chars, pos);
                        ranges.push((c1, c2));
                    } else {
                        ranges.push((c1, c1));
                    }
                }
                if *pos < chars.len() && chars[*pos] == ']' {
                    *pos += 1;
                }
                RegexAtom::Class { ranges, inverted }
            }
            '\\' => {
                *pos += 1;
                if *pos >= chars.len() {
                    panic!("regex: trailing backslash");
                }
                let c = chars[*pos];
                *pos += 1;
                match c {
                    'n' => RegexAtom::Char('\n'),
                    't' => RegexAtom::Char('\t'),
                    'r' => RegexAtom::Char('\r'),
                    'd' => RegexAtom::Class {
                        ranges: vec![('0', '9')],
                        inverted: false,
                    },
                    's' => RegexAtom::Class {
                        ranges: vec![
                            (' ', ' '),
                            ('\t', '\t'),
                            ('\n', '\n'),
                            ('\r', '\r'),
                        ],
                        inverted: false,
                    },
                    other => RegexAtom::Char(other),
                }
            }
            c => {
                *pos += 1;
                RegexAtom::Char(c)
            }
        }
    }

    fn parse_char_literal(chars: &[char], pos: &mut usize) -> char {
        if chars[*pos] == '\\' && *pos + 1 < chars.len() {
            *pos += 1;
            let c = chars[*pos];
            *pos += 1;
            match c {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                other => other,
            }
        } else {
            let c = chars[*pos];
            *pos += 1;
            c
        }
    }

    pub fn match_str(&self, s: &str) -> Value {
        let chars: Vec<char> = s.chars().collect();
        let mut captures = vec![None; self.num_groups + 1];
        if let Some(end) = Self::match_ast(&self.ast, &chars, 0, &mut captures) {
            if end == chars.len() {
                let mut list = Vec::new();
                for i in 1..=self.num_groups {
                    match captures[i] {
                        Some((st, en)) => {
                            let sub: String = chars[st..en].iter().collect();
                            list.push(Value::from_str(&sub));
                        }
                        None => {
                            list.push(Value::null_());
                        }
                    }
                }
                return Value::from_list(list);
            }
        }
        Value::null_()
    }

    pub fn split_str(&self, s: &str) -> Value {
        let chars: Vec<char> = s.chars().collect();
        let mut result = Vec::new();
        let mut cur_pos = 0;

        while cur_pos <= chars.len() {
            let mut match_found = None;
            for start in cur_pos..=chars.len() {
                let mut captures = vec![None; self.num_groups + 1];
                if let Some(end) = Self::match_ast(&self.ast, &chars, start, &mut captures) {
                    if end > start || (end == start && match_found.is_none()) {
                        match_found = Some((start, end, captures));
                        break;
                    }
                }
            }

            match match_found {
                Some((m_start, m_end, caps)) => {
                    let prefix: String = chars[cur_pos..m_start].iter().collect();
                    result.push(Value::from_str(&prefix));

                    let mut groups = Vec::new();
                    for i in 1..=self.num_groups {
                        match caps[i] {
                            Some((st, en)) => {
                                let g: String = chars[st..en].iter().collect();
                                groups.push(Value::from_str(&g));
                            }
                            None => {
                                groups.push(Value::null_());
                            }
                        }
                    }
                    result.push(Value::from_list(groups));

                    if m_end == cur_pos {
                        cur_pos += 1;
                    } else {
                        cur_pos = m_end;
                    }
                }
                None => {
                    let suffix: String = chars[cur_pos..].iter().collect();
                    result.push(Value::from_str(&suffix));
                    break;
                }
            }
        }
        Value::from_list(result)
    }

    fn match_ast(
        ast: &RegexAST,
        chars: &[char],
        pos: usize,
        captures: &mut Vec<Option<(usize, usize)>>,
    ) -> Option<usize> {
        for branch in &ast.branches {
            let saved = captures.clone();
            if let Some(end) = Self::match_branch(&branch.pieces, 0, chars, pos, captures) {
                return Some(end);
            }
            *captures = saved;
        }
        None
    }

    fn match_branch(
        pieces: &[RegexPiece],
        piece_idx: usize,
        chars: &[char],
        pos: usize,
        captures: &mut Vec<Option<(usize, usize)>>,
    ) -> Option<usize> {
        if piece_idx == pieces.len() {
            return Some(pos);
        }

        match &pieces[piece_idx] {
            RegexPiece::Atom(atom) => {
                let saved = captures.clone();
                if let Some(next_pos) = Self::match_atom(atom, chars, pos, captures) {
                    if let Some(end) =
                        Self::match_branch(pieces, piece_idx + 1, chars, next_pos, captures)
                    {
                        return Some(end);
                    }
                }
                *captures = saved;
                None
            }
            RegexPiece::Star(atom) => {
                Self::match_star(atom, pieces, piece_idx, chars, pos, captures)
            }
            RegexPiece::Plus(atom) => {
                let saved = captures.clone();
                if let Some(next_pos) = Self::match_atom(atom, chars, pos, captures) {
                    if next_pos > pos {
                        if let Some(end) =
                            Self::match_star(atom, pieces, piece_idx, chars, next_pos, captures)
                        {
                            return Some(end);
                        }
                    } else {
                        if let Some(end) =
                            Self::match_branch(pieces, piece_idx + 1, chars, next_pos, captures)
                        {
                            return Some(end);
                        }
                    }
                }
                *captures = saved;
                None
            }
            RegexPiece::Opt(atom) => {
                let saved = captures.clone();
                if let Some(next_pos) = Self::match_atom(atom, chars, pos, captures) {
                    if let Some(end) =
                        Self::match_branch(pieces, piece_idx + 1, chars, next_pos, captures)
                    {
                        return Some(end);
                    }
                }
                *captures = saved;
                Self::match_branch(pieces, piece_idx + 1, chars, pos, captures)
            }
        }
    }

    fn match_star(
        atom: &RegexAtom,
        pieces: &[RegexPiece],
        piece_idx: usize,
        chars: &[char],
        pos: usize,
        captures: &mut Vec<Option<(usize, usize)>>,
    ) -> Option<usize> {
        let saved = captures.clone();
        if let Some(next_pos) = Self::match_atom(atom, chars, pos, captures) {
            if next_pos > pos {
                if let Some(end) =
                    Self::match_star(atom, pieces, piece_idx, chars, next_pos, captures)
                {
                    return Some(end);
                }
            }
        }
        *captures = saved;
        Self::match_branch(pieces, piece_idx + 1, chars, pos, captures)
    }

    fn match_atom(
        atom: &RegexAtom,
        chars: &[char],
        pos: usize,
        captures: &mut Vec<Option<(usize, usize)>>,
    ) -> Option<usize> {
        match atom {
            RegexAtom::Char(c) => {
                if pos < chars.len() && chars[pos] == *c {
                    Some(pos + 1)
                } else {
                    None
                }
            }
            RegexAtom::Any => {
                if pos < chars.len() && chars[pos] != '\n' {
                    Some(pos + 1)
                } else {
                    None
                }
            }
            RegexAtom::Class { ranges, inverted } => {
                if pos < chars.len() {
                    let ch = chars[pos];
                    let in_range = ranges.iter().any(|(lo, hi)| ch >= *lo && ch <= *hi);
                    if in_range != *inverted {
                        Some(pos + 1)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            RegexAtom::Group(inner, grp) => {
                let old = captures[*grp];
                if let Some(end) = Self::match_ast(inner, chars, pos, captures) {
                    captures[*grp] = Some((pos, end));
                    Some(end)
                } else {
                    captures[*grp] = old;
                    None
                }
            }
            RegexAtom::NonCapturing(inner) => Self::match_ast(inner, chars, pos, captures),
        }
    }
}