# C++ backend for Wechselbalg.
#
# Translates IR nodes to C++ code strings.
# All values are wrapped in a `Value` type (provided by the runtime header).
#
# Memory model: all variable bindings (let-bindings, function parameters,
# function definitions) use std::shared_ptr<Value> so that closures
# (which capture by value via [=]) keep referenced Values alive even
# after the defining scope has returned.  References and variables are
# dereferenced with (*name).
let
  join = sep: list: builtins.concatStringsSep sep list;

  hasPrefix = prefix: str: builtins.substring 0 (builtins.stringLength prefix) str == prefix;

  # Detect rendered expressions that are cheap/pure and can't fail.
  # These don't need thunk wrapping for lazy evaluation.
  # Used by renderLet (let-bindings) and renderAttrs (attrset entries).
  # Must NOT include compound values (fromSet/fromList) because
  # let-bindings may have forward references that require lazy init.
  isCheapExpr =
    str:
    let
      pfx7 = builtins.substring 0 7 str;
      pfx5 = builtins.substring 0 5 str;
    in
    if pfx7 == "Value::" then
      let
        sub = builtins.substring 7 7 str;
      in
      sub == "fromInt"
      || sub == "fromStr"
      || sub == "fromFlo"
      # fromBool must be the EXACT boolean literal. renderEq/renderLessThan
      # also produce a `Value::fromBool(` prefix around arbitrary (possibly
      # failing, forward-referencing) operands, which are NOT pure — treating
      # them as cheap evaluates them eagerly at let-binding init time, before
      # forward-referenced sibling bindings are assigned (see toIntBase10).
      || str == "Value::fromBool(true)"
      || str == "Value::fromBool(false)"
      || str == "Value::null_()"
    else if pfx5 == "__wb_" then
      let
        sub = builtins.substring 5 7 str;
      in
      sub == "primop_" || sub == "unknown"
    else
      false;

  isPureExpr =
    str:
    isCheapExpr str
    || builtins.substring 0 15 str == "Value::fromSet("
    || builtins.substring 0 16 str == "Value::fromList(";

  sanitize =
    name:
    let
      reserved = [
        "int"
        "float"
        "double"
        "char"
        "void"
        "bool"
        "class"
        "struct"
        "enum"
        "union"
        "const"
        "static"
        "extern"
        "register"
        "volatile"
        "return"
        "if"
        "else"
        "for"
        "while"
        "do"
        "switch"
        "case"
        "break"
        "continue"
        "default"
        "goto"
        "sizeof"
        "typedef"
        "namespace"
        "using"
        "template"
        "typename"
        "public"
        "private"
        "protected"
        "virtual"
        "override"
        "final"
        "new"
        "delete"
        "throw"
        "try"
        "catch"
        "operator"
        "friend"
        "inline"
        "auto"
        "nullptr"
        "true"
        "false"
        "this"
        "and"
        "or"
        "not"
        "xor"
        "bitand"
        "bitor"
        "compl"
        "and_eq"
        "or_eq"
        "xor_eq"
        "not_eq"
        "export"
        "import"
        "module"
        "requires"
        "concept"
        "long"
        "short"
        "signed"
        "unsigned"
        "asm"
        "explicit"
        "mutable"
        "constexpr"
        "consteval"
        "constinit"
        "decltype"
        "noexcept"
        "typeid"
      ];
      # Replace characters valid in Nix identifiers but not in C++
      cleaned = builtins.replaceStrings [ "'" "-" ] [ "_q" "_h" ] name;
    in
    if builtins.elem cleaned reserved then "__wb_rsv_${cleaned}" else cleaned;

  cppPrimopDefs = import ../primops/cpp.nix;

  backend = {
    name = "cpp";
    extension = "cpp";

    # Unknown primops become runtime errors so translation proceeds.
    # Uses a factory function defined once in the program preamble.
    renderUnknownPrimop = name: "__wb_unknown_primop(${builtins.toJSON name})";

    # ── Literals ────────────────────────────────────────────────
    renderInt = value: "Value::fromInt(${toString value})";
    renderFloat = value: "Value::fromFloat(${builtins.toJSON value})";
    renderString = value: "Value::fromString(${builtins.toJSON value})";
    renderBool = value: "Value::fromBool(${if value then "true" else "false"})";
    renderNull = "Value::null_()";

    # Nix paths become dedicated Path values carrying the translation-time
    # filesystem record (see Value::fromPath in the runtime). The meta record
    # is wrapped in a thunk: let-bindings are forward-declared shared_ptrs
    # assigned after their use sites, so eagerly reading it could observe an
    # uninitialised sibling binding.
    renderPath =
      pathStr: metaExpr:
      "Value::fromPath(${builtins.toJSON pathStr}, Value::thunk([=]() -> Value { return ${metaExpr}; }))";

    # A runtime path value reached through a value position (parameter, attr
    # select): the path string plus its hidden fs record travel as one value.
    renderPathValue =
      pathStr: metaName:
      "Value::fromPath(${builtins.toJSON pathStr}, Value::thunk([=]() -> Value { return *${metaName}; }))";

    # ── Collections ─────────────────────────────────────────────
    renderList =
      elements:
      if builtins.length elements > 4 then
        "Value::fromList({\n${join ",\n" elements}\n})"
      else
        "Value::fromList({${join ", " elements}})";

    renderAttrs =
      entries:
      let
        names = builtins.attrNames entries;
        pairs = builtins.map (
          name:
          let
            val = entries.${name};
          in
          if isCheapExpr val then
            "{${builtins.toJSON name}, ${val}}"
          else
            "{${builtins.toJSON name}, Value::thunk([=]() -> Value {\n  return ${val};\n})}"
        ) names;
      in
      "Value::fromSet({\n${join ",\n" pairs}\n})";

    # ── Let bindings (thunked for recursive scoping) ────────────
    renderLet =
      bindings: body: localDefs: localDefNames:
      let
        names = builtins.attrNames bindings;
        # All bindings and local defs are shared_ptr<Value> so closures
        # that escape this scope keep them alive.
        fwdDecls = builtins.map (name: "auto ${sanitize name} = std::make_shared<Value>();") (
          names ++ localDefNames
        );
        defsBlock = if localDefs == [ ] then [ ] else localDefs;
        assigns = builtins.map (
          name:
          if isCheapExpr bindings.${name} then
            "*${sanitize name} = ${bindings.${name}};"
          else
            "*${sanitize name} = Value::thunk([=]() -> Value {\n  return ${bindings.${name}};\n});"
        ) names;
        lines = fwdDecls ++ defsBlock ++ assigns;
      in
      ''
        ([=]() -> Value {
          ${join "\n  " lines}
          return ${body};
        }())'';

    # ── References ──────────────────────────────────────────────
    # All named values are shared_ptr<Value>, so dereference on use.
    renderRef = name: "(*${sanitize name})";
    renderVar = name: "(*${sanitize name})";

    # ── Application ─────────────────────────────────────────────
    # Arguments are thunked to emulate Nix's call-by-need semantics,
    # unless the argument is a pure expression that can't fail.
    renderApply =
      fn: arg:
      if isPureExpr arg then
        "(${fn})(${arg})"
      else
        "(${fn})(Value::thunk([=]() -> Value {\n  return ${arg};\n}))";

    # ── Control flow ────────────────────────────────────────────
    renderIf =
      cond: then_: else_:
      "(${cond}.asBool() ? ${then_} : ${else_})";

    # ── Comparison ──────────────────────────────────────────────────
    renderEq = a: b: "Value::fromBool(${a} == ${b})";
    renderLessThan = a: b: "Value::fromBool(${a} < ${b})";

    # ── Arithmetic ──────────────────────────────────────────────
    renderAdd = a: b: "__wb_add(${a}, ${b})";

    # Collection ops
    renderUpdate = base: ext: "${base}.update(${ext})";
    renderConcatLists = a: b: "${a}.concat(${b})";

    renderSelect =
      expr: path: default:
      let
        access = join "" (builtins.map (p: "[${p}]") path);
      in
      if default == null then
        "${expr}${access}"
      else
        ''
          ([=]() -> Value {
            try { return ${expr}${access}; }
            catch(...) { return ${default}; }
          }())'';

    # ── Function definitions ────────────────────────────────────
    renderParams = params: params;

    renderFuncDef =
      name: params: bodyStr: localDefs: localDefNames:
      let
        paramName = "__p";
        identifier = params.identifier or null;
        formals = params.formals or null;
        ellipsis = params.ellipsis or true;

        # Parameters are shared_ptr<Value> so nested lambdas can
        # safely capture them after this call frame returns.
        # Formal parameters need forward declarations because defaults
        # can reference other formals in any order (Nix formals are lazy).
        identifierBinding =
          if identifier != null then
            "auto ${sanitize identifier} = std::make_shared<Value>(${paramName});"
          else
            "";

        formalsFwdDecls =
          if formals != null then
            join "\n    " (builtins.map (f: "auto ${sanitize f.name} = std::make_shared<Value>();") formals)
          else
            "";

        formalsBindings =
          if formals != null then
            join "\n    " (
              builtins.map (
                f:
                if f.hasDefault then
                  ''
                    *${sanitize f.name} = Value::thunk([=]() -> Value {
                      if (${paramName}.hasAttr(${builtins.toJSON f.name})) {
                        return ${paramName}[${builtins.toJSON f.name}];
                      }
                      return ${f.default};
                    });
                  ''
                else
                  "*${sanitize f.name} = Value::thunk([=]() -> Value { return ${paramName}[${builtins.toJSON f.name}]; });"
              ) formals
            )
          else
            "";

        ellipsisCheck =
          if formals != null && !ellipsis then
            let
              checks = builtins.map (f: "_kv.first != ${builtins.toJSON f.name}") formals;
              cond = if checks == [ ] then "true" else join " && " checks;
            in
            ''
              if (${paramName}.isSet()) {
                for (const auto& _kv : ${paramName}.asSet()) {
                  if (${cond}) {
                    throw std::runtime_error("wechselbalg: unexpected argument '" + _kv.first + "'");
                  }
                }
              }
            ''
          else
            "";

        # Forward-declare local defs as shared_ptr so mutual references work
        localDefFwdDecls =
          if localDefNames != [ ] then
            join "\n    " (builtins.map (n: "auto ${sanitize n} = std::make_shared<Value>();") localDefNames)
          else
            "";

        localDefsBlock = if localDefs == [ ] then "" else join "\n    " localDefs;

        bindings = builtins.concatStringsSep "\n    " (
          builtins.filter (s: s != "") [
            identifierBinding
            formalsFwdDecls
            localDefFwdDecls
            formalsBindings
            localDefsBlock
            ellipsisCheck
          ]
        );

        # Build formals metadata for functionArgs support
        formalsMetadata =
          if formals != null then
            let
              entries = builtins.map (
                f: "{${builtins.toJSON f.name}, ${if f.hasDefault then "true" else "false"}}"
              ) formals;
            in
            "{${join ", " entries}}"
          else
            null;

        lambdaCtor = if formalsMetadata != null then "Value::lambdaWithFormals" else "Value::lambda";

        formalsArg = if formalsMetadata != null then ", ${formalsMetadata}" else "";

        ctor = ''
          ${lambdaCtor}([=](const Value& ${paramName}) -> Value {
            ${bindings}
            return ${bodyStr};
          }${formalsArg})'';

        astJson = params.ast or null;
        tagged =
          if astJson == null then
            ctor
          else
            "Value::withMeta(${ctor}, ${builtins.toJSON astJson}, ${
              if (params.env or null) == null then "Value::null_()" else params.env
            })";
      in
      ''
        *${sanitize name} = ${tagged};
      '';

    # ── Program assembly ────────────────────────────────────────
    # Emits a bare C++ expression/block. Does NOT include headers.
    # Users must #include the wechselbalg Value header themselves.
    # Access the header via lib.cppRuntime.
    renderProgram =
      {
        defs,
        defNames ? [ ],
        expr,
        usedPrimops ? { },
        stringDefs ? { },
        stringDefNames ? [ ],
        bindings ? { },
        bindingNames ? [ ],
      }:
      let
        # Only emit definitions for primops that are actually used
        usedKnown = builtins.filter (name: builtins.hasAttr name cppPrimopDefs) (
          builtins.attrNames usedPrimops
        );
        usedUnknown = builtins.filter (name: !(builtins.hasAttr name cppPrimopDefs)) (
          builtins.attrNames usedPrimops
        );
        primopDecls = builtins.map (
          name:
          "auto __wb_primop_${sanitize name} = Value::primop(${builtins.toJSON name}, ${cppPrimopDefs.${name}});"
        ) usedKnown;
        # Factory for unknown primops — defined once, called with name string.
        unknownFactory =
          if usedUnknown != [ ] then
            [
              ''
                auto __wb_unknown_primop = [](const std::string& name) -> Value {
                  return Value::primop(name, Value::lambda([name](const Value&) -> Value {
                    throw std::runtime_error("wechselbalg: primop '" + name + "' is not implemented in C++");
                  }));
                };''
            ]
          else
            [ ];
        primopBlock = join "\n" (unknownFactory ++ primopDecls);
        # Deduplicated string constants
        stringDecls = builtins.map (
          name: "auto ${name} = std::make_shared<Value>(${stringDefs.${name}});"
        ) stringDefNames;
        # Path/fs records, closures and captured sets the walker hoisted to the
        # root (`splitRootBindings` in lib/render.nix). Shared function
        # definitions reference them — refs to *this* scope, not to a `let`
        # inside the program — so they are declared here, before the defs, and
        # assigned after them, exactly as `renderLet` orders them: defs reach a
        # record lazily through a thunk, a record's `value` may reach a def.
        # Unreachable records were pruned by dead-code elimination.
        bindingFwdDecls = builtins.map (n: "auto ${sanitize n} = std::make_shared<Value>();") bindingNames;
        bindingAssigns = builtins.map (
          name:
          if isCheapExpr bindings.${name} then
            "*${sanitize name} = ${bindings.${name}};"
          else
            "*${sanitize name} = Value::thunk([=]() -> Value {\n  return ${bindings.${name}};\n});"
        ) bindingNames;
        hasContent = defs != [ ] || primopBlock != "" || stringDecls != [ ] || bindingNames != [ ];
      in
      if !hasContent then
        expr
      else
        let
          fwdDecls = builtins.map (n: "auto ${sanitize n} = std::make_shared<Value>();") defNames;
          defBlock = join "\n" (stringDecls ++ bindingFwdDecls ++ fwdDecls ++ defs ++ bindingAssigns);
        in
        ''
          ([]() -> Value {
            ${primopBlock}
            ${defBlock}
            return ${expr};
          }())'';

    # ── Library assembly ───────────────────────────────────────
    # Emits a set of C++ source files suitable for compiling to a static
    # library plus a public header that exposes the generated value under
    # a caller-chosen name in a caller-chosen namespace.
    # well thats not true anymore, it should only work on attrSets
    # and exposing all attrs of that set as caller-chosen-namespace::attrName
    #
    # Input:
    #   library = { namespace = "myns"; };
    #
    # Output is an attrset:
    #   {
    #     "include/wechselbalg/value.hpp" = <runtime header text>;
    #     "include/<namespace>/<name>.hpp" = <public header>;
    #     "src/_internals.hpp"             = <shared private header>;
    #     "src/_primops.cpp"               = <primop definitions>;
    #     "src/_strings.cpp"               = <string dedup globals>;   (optional)
    #     "src/_func_<i>.cpp"              = <one per hoisted function>;
    #     "src/_value_<attr>.cpp"          = <exported value initializers>;
    #   }
    #
    # Rationale: a single ~6MB .cpp blows up gcc; splitting each hoisted
    # function into its own translation unit keeps individual compilation
    # units small and parallelisable.  All generated globals live in
    # <namespace>::detail; only the exported value is in <namespace>.
    renderLibrary =
      {
        defs,
        defNames ? [ ],
        expr,
        usedPrimops ? { },
        stringDefs ? { },
        stringDefNames ? [ ],
        bindings ? { },
        bindingNames ? [ ],
        library,
        value,
      }:
      if builtins.typeOf value != "set" then
        throw "only sets can be converted to libraries"
      else
        let
          ns = library.namespace;
          detailNs = "${ns}::detail";
          valueName = "wb_value";
          runtimeHpp = builtins.readFile ../runtime/cpp/value.hpp;

          usedKnown = builtins.filter (name: builtins.hasAttr name cppPrimopDefs) (
            builtins.attrNames usedPrimops
          );
          usedUnknown = builtins.filter (name: !(builtins.hasAttr name cppPrimopDefs)) (
            builtins.attrNames usedPrimops
          );

          primopExterns = builtins.map (n: "  extern Value __wb_primop_${sanitize n};") usedKnown;
          unknownExtern =
            if usedUnknown != [ ] then [ "  Value __wb_unknown_primop(const std::string& name);" ] else [ ];
          stringExterns = builtins.map (n: "  extern std::shared_ptr<Value> ${n};") stringDefNames;
          funcExterns = builtins.map (n: "  extern std::shared_ptr<Value> ${sanitize n};") defNames;
          # Root value bindings (path/fs records, closures, captured sets): one
          # global per name, referenced by the function translation units.
          bindingExterns = builtins.map (n: "  extern std::shared_ptr<Value> ${sanitize n};") bindingNames;

          internalsHpp = ''
            // Auto-generated by wechselbalg.  Do not edit.
            #pragma once
            #include "wechselbalg/value.hpp"
            #include <memory>
            #include <stdexcept>
            #include <string>
            namespace ${detailNs} {
            ${join "\n" (primopExterns ++ unknownExtern ++ stringExterns ++ funcExterns ++ bindingExterns)}
            Value __wb_get_root_expr();
            }
          '';

          publicHpp = ''
            // Auto-generated by wechselbalg.
            #pragma once
            #include "wechselbalg/value.hpp"
            namespace ${ns} {
              ${join "\n" (value |> builtins.attrNames |> builtins.map (v: "extern Value ${sanitize v};"))}
            }
          '';

          primopDefsCpp = builtins.map (
            n: "  Value __wb_primop_${sanitize n} = Value::primop(${builtins.toJSON n}, ${cppPrimopDefs.${n}});"
          ) usedKnown;
          unknownDefCpp =
            if usedUnknown != [ ] then
              [
                ''
                  Value __wb_unknown_primop(const std::string& name) {
                    return Value::primop(name, Value::lambda([name](const Value&) -> Value {
                      throw std::runtime_error("wechselbalg: primop '" + name + "' is not implemented in C++");
                    }));
                  }''
              ]
            else
              [ ];

          primopsCpp = ''
            // Auto-generated by wechselbalg.
            #include "_internals.hpp"
            namespace ${detailNs} {
            ${join "\n" (primopDefsCpp ++ unknownDefCpp)}
            }
          '';

          stringsCpp =
            if stringDefNames == [ ] then
              null
            else
              ''
                // Auto-generated by wechselbalg.
                #include "_internals.hpp"
                namespace ${detailNs} {
                ${join "\n" (
                  builtins.map (
                    n: "  std::shared_ptr<Value> ${n} = std::make_shared<Value>(${stringDefs.${n}});"
                  ) stringDefNames
                )}
                }
              '';

          # Each hoisted def (a statement like `*__wb_func_N = Value::lambda(...)`)
          # becomes its own translation unit.
          funcFiles = builtins.genList (
            i:
            let
              n = builtins.elemAt defNames i;
              defStmt = builtins.elemAt defs i;
              safe = sanitize n;
            in
            {
              path = "src/_func_${toString i}.cpp";
              content = ''
                // Auto-generated by wechselbalg.
                #include "_internals.hpp"
                namespace ${detailNs} {
                  std::shared_ptr<Value> ${safe} = std::make_shared<Value>();
                  namespace {
                    [[maybe_unused]] const int _wb_init_${toString i} = []() -> int {
                      ${defStmt}
                      return 0;
                    }();
                  }
                }
              '';
            }
          ) (builtins.length defNames);

          # Root value bindings (path/fs records, closures, captured sets — see
          # the header comment on render) get one translation unit each, like
          # the functions: a record embeds a whole imported file, so the
          # generated code per record can be large. Every binding is a
          # forward-initialised shared_ptr assigned in a dynamic-initialiser;
          # its value is a thunk, so the knot between records, closures and
          # functions resolves at first use, not at static-init time.
          bindingFiles = builtins.genList (
            i:
            let
              n = builtins.elemAt bindingNames i;
              safe = sanitize n;
            in
            {
              path = "src/_binding_${toString i}.cpp";
              content = ''
                // Auto-generated by wechselbalg.
                #include "_internals.hpp"
                namespace ${detailNs} {
                  std::shared_ptr<Value> ${safe} = std::make_shared<Value>();
                  namespace {
                    [[maybe_unused]] const int _wb_bind_${toString i} = []() -> int {
                      *${safe} = Value::thunk([=]() -> Value {
                        return ${bindings.${n}};
                      });
                      return 0;
                    }();
                  }
                }
              '';
            }
          ) (builtins.length bindingNames);

          # The exported value.  Wrapped in Value::thunk so that evaluation is
          # deferred until first use — this avoids static-initialisation-order
          # issues across the per-function translation units.
          valueFilesAttrs = builtins.listToAttrs (
            builtins.map (n: {
              name = "src/_value_${sanitize n}.cpp";
              value = ''
                // Auto-generated by wechselbalg.
                #include "${ns}.hpp"
                #include "_internals.hpp"
                namespace ${ns} {
                  using namespace ${detailNs};
                      Value ${sanitize n} = Value::thunk([]() -> Value {
                              return __wb_get_root_expr()[${builtins.toJSON n}];                });
                }
              '';
            }) (builtins.attrNames value)
          );

          funcFilesAttrs = builtins.listToAttrs (
            builtins.map (f: {
              name = f.path;
              value = f.content;
            }) funcFiles
          );

          bindingFilesAttrs = builtins.listToAttrs (
            builtins.map (f: {
              name = f.path;
              value = f.content;
            }) bindingFiles
          );

          baseFiles = {
            "include/wechselbalg/value.hpp" = runtimeHpp;
            "include/${ns}.hpp" = publicHpp;
            "src/_internals.hpp" = internalsHpp;
            "src/_primops.cpp" = primopsCpp;
            "src/_root_expr.cpp" = ''
              // Auto-generated by wechselbalg
              #include "_internals.hpp"
              namespace ${detailNs} {
                      Value __wb_get_root_expr() {
                              static Value root = Value::thunk([]() -> Value {
                                      return ${expr};
                              });
                              return root;
                      }
              }
            '';
          };

          stringFile = if stringsCpp == null then { } else { "src/_strings.cpp" = stringsCpp; };
        in
        baseFiles // stringFile // funcFilesAttrs // bindingFilesAttrs // valueFilesAttrs;

    # ── Primops ─────────────────────────────────────────────────
    # Primop definitions are the full C++ lambda code.
    # Primop references (used during rendering) are just variable names.
    # renderProgram emits all primop definitions once in the preamble.
    primopDefs = cppPrimopDefs;
    primops = builtins.mapAttrs (name: _: "__wb_primop_${sanitize name}") cppPrimopDefs;
  };
in
backend
