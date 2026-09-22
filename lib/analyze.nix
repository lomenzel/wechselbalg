# Syntactic analysis of reified lambda ASTs.
#
# This module is the *single source of truth* for two things that must never
# disagree (invariant I1 / I5 in PLAN-closure-conversion.md):
#
#   1. `key`     — the identity of a code template. Two lambdas with the same
#                  key compile to the same body and may share one definition.
#   2. `capture` — which free variables the body reads, and under which
#                  environment key each one is reached.
#
# `walkValue` uses `capture` to build a closure's environment; `walkAST` uses
# it to emit environment accesses. Because both read the same table they cannot
# drift apart.
#
# Traversal MUST mirror `walkAST` exactly: any subtree that `walkAST` refuses
# to descend into (`with`, unsupported nodes) is collapsed here too, otherwise
# a variable would be captured that the body never reads.

let
  # ── Static attribute path, or null if any element is dynamic ────
  staticPath =
    path:
    let
      names = builtins.map (p: if (p._expr or null) == "attrName" then p.value else null) path;
    in
    if builtins.any (n: n == null) names then null else names;

  isFreeVar = node: (node._expr or null) == "var" && builtins.hasAttr "closureEnvValue" node.value;

  joinKey = root: path: builtins.concatStringsSep "." ([ root ] ++ path);

  # Name-keyed AST maps (attrset entries, let bindings) are carried as an
  # explicit list of pairs rather than a Nix attrset.  User attribute names
  # must never become Nix attrset keys: `builtins.toJSON`, which hashes the
  # stripped AST and ships it to the runtimes, special-cases `__toString` and
  # `outPath` and would try to *call* the AST node stored under them.
  # `builtins.attrNames` is sorted, so the list is deterministic.
  pairsOf = entries: {
    __pairs = entries;
  };

  # ── Single pass: strip + collect uses ───────────────────────────
  # Returns { stripped; uses; } where `uses` is a list of
  #   { root = <var name>; path = [ <attr> ] | null; env = <thunk>; }
  # `path == null` means the variable is read as a whole.
  scan =
    node:
    let
      e = node._expr or null;
      v = node.value or null;

      binary =
        name:
        let
          a = scan v.e1;
          b = scan v.e2;
        in
        {
          stripped = {
            _expr = name;
            value = {
              e1 = a.stripped;
              e2 = b.stripped;
            };
          };
          uses = a.uses ++ b.uses;
        };

      seq =
        name: nodes:
        let
          rs = builtins.map scan nodes;
        in
        {
          stripped = {
            _expr = name;
            value = builtins.map (r: r.stripped) rs;
          };
          uses = builtins.concatMap (r: r.uses) rs;
        };
    in

    if e == "literal" || e == "attrName" || e == "path" || e == "primop" then
      {
        stripped = {
          _expr = e;
          inherit (node) value;
        };
        uses = [ ];
      }

    else if e == "pos" then
      {
        stripped = {
          _expr = e;
        };
        uses = [ ];
      }

    else if e == "var" then
      if builtins.hasAttr "closureEnvValue" v then
        {
          stripped = {
            _expr = "var";
            value = {
              inherit (v) name;
              __free = true;
            };
          };
          uses = [
            {
              root = v.name;
              path = null;
              env = v.closureEnvValue;
            }
          ];
        }
      else
        {
          stripped = {
            _expr = "var";
            value = {
              inherit (v) name;
            };
          };
          uses = [ ];
        }

    else if e == "concatString/addition" || e == "list" then
      seq e v

    else if e == "not" then
      let
        r = scan v;
      in
      {
        stripped = {
          _expr = "not";
          value = r.stripped;
        };
        inherit (r) uses;
      }

    else if
      e == "update"
      || e == "concatLists"
      || e == "equals"
      || e == "notEquals"
      || e == "and"
      || e == "or"
      || e == "implies"
    then
      binary e

    else if e == "if" then
      let
        c = scan v.condition;
        t = scan v.${"then"};
        f = scan v.${"else"};
      in
      {
        stripped = {
          _expr = "if";
          value = {
            condition = c.stripped;
            "then" = t.stripped;
            "else" = f.stripped;
          };
        };
        uses = c.uses ++ t.uses ++ f.uses;
      }

    else if e == "assert" then
      let
        c = scan v.condition;
        b = scan v.body;
      in
      {
        stripped = {
          _expr = "assert";
          value = {
            condition = c.stripped;
            body = b.stripped;
          };
        };
        uses = c.uses ++ b.uses;
      }

    else if e == "call" then
      let
        f = scan v.function;
        as = builtins.map scan v.args;
      in
      {
        stripped = {
          _expr = "call";
          value = {
            function = f.stripped;
            args = builtins.map (r: r.stripped) as;
          };
        };
        uses = f.uses ++ builtins.concatMap (r: r.uses) as;
      }

    else if e == "hasAttr" then
      let
        x = scan v.expression;
        ps = builtins.map scan v.path;
      in
      {
        stripped = {
          _expr = "hasAttr";
          value = {
            expression = x.stripped;
            path = builtins.map (r: r.stripped) ps;
          };
        };
        uses = x.uses ++ builtins.concatMap (r: r.uses) ps;
      }

    else if e == "select" then
      let
        x = scan v.expression;
        ps = builtins.map scan v.path;
        hasDefault = builtins.hasAttr "default" v;
        d = if hasDefault then scan v.default else null;
        sp = staticPath v.path;

        # Path narrowing: capture `lib.strings.toUpper` instead of all of `lib`.
        # Only when the whole path is static and there is no `or` fallback, so
        # the selection cannot fail at capture time.
        narrowable = !hasDefault && sp != null && sp != [ ] && isFreeVar v.expression;
      in
      {
        stripped = {
          _expr = "select";
          value = {
            expression = x.stripped;
            path = builtins.map (r: r.stripped) ps;
          }
          // (if hasDefault then { default = d.stripped; } else { });
        };
        uses =
          if narrowable then
            [
              {
                root = v.expression.value.name;
                path = sp;
                env = v.expression.value.closureEnvValue;
              }
            ]
          else
            x.uses ++ builtins.concatMap (r: r.uses) ps ++ (if hasDefault then d.uses else [ ]);
      }

    else if e == "attrSet" then
      let
        attrs = v.attrs or { };
        names = builtins.attrNames attrs;
        as = builtins.map (n: {
          inherit n;
          r = scan attrs.${n};
        }) names;
        ds = builtins.map (d: {
          nameR = scan d.name;
          valueR = scan d.value;
        }) (v.dynamicAttrs or [ ]);
      in
      {
        stripped = {
          _expr = "attrSet";
          value = {
            recursive = v.recursive or false;
            attrs = pairsOf (
              builtins.map (a: {
                name = a.n;
                value = a.r.stripped;
              }) as
            );
            dynamicAttrs = builtins.map (d: {
              name = d.nameR.stripped;
              value = d.valueR.stripped;
            }) ds;
          };
        };
        uses =
          builtins.concatMap (a: a.r.uses) as ++ builtins.concatMap (d: d.nameR.uses ++ d.valueR.uses) ds;
      }

    else if e == "let" then
      let
        attrs = v.attrs.value.attrs or { };
        names = builtins.attrNames attrs;
        bs = builtins.map (n: {
          inherit n;
          r = scan attrs.${n};
        }) names;
        b = scan v.body;
      in
      {
        stripped = {
          _expr = "let";
          value = {
            attrs = pairsOf (
              builtins.map (x: {
                name = x.n;
                value = x.r.stripped;
              }) bs
            );
            body = b.stripped;
          };
        };
        uses = builtins.concatMap (x: x.r.uses) bs ++ b.uses;
      }

    else if e == "lambda" then
      let
        a = scanArguments v.arguments;
        b = scan v.body;
      in
      {
        stripped = {
          _expr = "lambda";
          value = {
            arguments = a.stripped;
            body = b.stripped;
          };
        };
        uses = a.uses ++ b.uses;
      }

    else if e == "primopApp" then
      # `appendBindingExpr` never produces this inside a body; it only appears
      # at the root of `reify`, which `walkValue` handles before analysis.
      throw "wechselbalg analyze: unexpected 'primopApp' inside a lambda body"

    else
      # `with` and anything unrecognised: walkAST emits a runtime throw without
      # descending, so the subtree contributes neither code nor captures.
      # Collapsing it keeps the key stable and captures nothing.
      {
        stripped = {
          _expr = e;
          __opaque = true;
        };
        uses = [ ];
      };

  scanArguments =
    args:
    let
      hasFormals = builtins.hasAttr "formals" args;
      fs =
        if hasFormals then
          builtins.map (
            f:
            if builtins.hasAttr "defaultExpr" f then
              let
                r = scan f.defaultExpr;
              in
              {
                stripped = {
                  inherit (f) name;
                  defaultExpr = r.stripped;
                };
                inherit (r) uses;
              }
            else
              {
                stripped = {
                  inherit (f) name;
                };
                uses = [ ];
              }
          ) args.formals
        else
          [ ];
    in
    {
      stripped = {
        identifier = args.identifier or null;
      }
      // (
        if hasFormals then
          {
            formals = builtins.map (r: r.stripped) fs;
            ellipsis = args.ellipsis or true;
          }
        else
          { }
      );
      uses = builtins.concatMap (r: r.uses) fs;
    };

  # ── Turn raw uses into a capture plan ───────────────────────────
  # All-or-nothing per root: if a root is ever read whole (bare variable,
  # dynamic path, or `or` fallback) it is captured whole and every selection
  # goes through it. Otherwise each static path is captured individually.
  buildCapture =
    uses:
    let
      grouped = builtins.groupBy (u: u.root) uses;
      roots = builtins.attrNames grouped;

      perRoot =
        root:
        let
          us = grouped.${root};
          whole = builtins.any (u: u.path == null) us;
        in
        if whole then
          {
            inherit root;
            mode = "whole";
            entries = [
              {
                key = root;
                inherit root;
                path = [ ];
                env = (builtins.head us).env;
              }
            ];
          }
        else
          {
            inherit root;
            mode = "narrow";
            entries = builtins.map (u: {
              key = joinKey root u.path;
              inherit root;
              inherit (u) path env;
            }) us;
          };

      plans = builtins.map perRoot roots;
    in
    {
      mode = builtins.listToAttrs (
        builtins.map (p: {
          name = p.root;
          value = p.mode;
        }) plans
      );
      entries = builtins.listToAttrs (
        builtins.concatMap (
          p:
          builtins.map (entry: {
            name = entry.key;
            value = entry;
          }) p.entries
        ) plans
      );
    };

  # ── Scope-tracking scan, for runtime `builtins.reify` ───────────
  # Independent of `closureEnvValue`: a variable is free when no binder
  # *inside* the analysed node introduces it.  At a template root this agrees
  # with the `closureEnvValue` marking, but it also works for lambdas nested
  # inside a template body, whose captures are ordinary generated variables.
  addBound =
    bound: names:
    bound
    // builtins.listToAttrs (
      builtins.map (n: {
        name = n;
        value = true;
      }) names
    );

  scopedScan =
    bound: node:
    let
      e = node._expr or null;
      v = node.value or null;
      go = scopedScan bound;

      binary =
        name:
        let
          a = go v.e1;
          b = go v.e2;
        in
        {
          stripped = {
            _expr = name;
            value = {
              e1 = a.stripped;
              e2 = b.stripped;
            };
          };
          free = a.free ++ b.free;
        };

      seq =
        name: nodes:
        let
          rs = builtins.map go nodes;
        in
        {
          stripped = {
            _expr = name;
            value = builtins.map (r: r.stripped) rs;
          };
          free = builtins.concatMap (r: r.free) rs;
        };
    in

    if e == "literal" || e == "attrName" || e == "path" || e == "primop" then
      {
        stripped = {
          _expr = e;
          inherit (node) value;
        };
        free = [ ];
      }

    else if e == "pos" then
      {
        stripped = {
          _expr = e;
        };
        free = [ ];
      }

    else if e == "var" then
      if bound ? ${v.name} then
        {
          stripped = {
            _expr = "var";
            value = {
              inherit (v) name;
            };
          };
          free = [ ];
        }
      else
        {
          stripped = {
            _expr = "var";
            value = {
              inherit (v) name;
              __free = true;
            };
          };
          free = [ v.name ];
        }

    else if e == "concatString/addition" || e == "list" then
      seq e v

    else if e == "not" then
      let
        r = go v;
      in
      {
        stripped = {
          _expr = "not";
          value = r.stripped;
        };
        inherit (r) free;
      }

    else if
      e == "update"
      || e == "concatLists"
      || e == "equals"
      || e == "notEquals"
      || e == "and"
      || e == "or"
      || e == "implies"
    then
      binary e

    else if e == "if" then
      let
        c = go v.condition;
        t = go v.${"then"};
        f = go v.${"else"};
      in
      {
        stripped = {
          _expr = "if";
          value = {
            condition = c.stripped;
            "then" = t.stripped;
            "else" = f.stripped;
          };
        };
        free = c.free ++ t.free ++ f.free;
      }

    else if e == "assert" then
      let
        c = go v.condition;
        b = go v.body;
      in
      {
        stripped = {
          _expr = "assert";
          value = {
            condition = c.stripped;
            body = b.stripped;
          };
        };
        free = c.free ++ b.free;
      }

    else if e == "call" then
      let
        f = go v.function;
        as = builtins.map go v.args;
      in
      {
        stripped = {
          _expr = "call";
          value = {
            function = f.stripped;
            args = builtins.map (r: r.stripped) as;
          };
        };
        free = f.free ++ builtins.concatMap (r: r.free) as;
      }

    else if e == "hasAttr" || e == "select" then
      let
        x = go v.expression;
        ps = builtins.map go v.path;
        hasDefault = e == "select" && builtins.hasAttr "default" v;
        d = if hasDefault then go v.default else null;
      in
      {
        stripped = {
          _expr = e;
          value = {
            expression = x.stripped;
            path = builtins.map (r: r.stripped) ps;
          }
          // (if hasDefault then { default = d.stripped; } else { });
        };
        free = x.free ++ builtins.concatMap (r: r.free) ps ++ (if hasDefault then d.free else [ ]);
      }

    else if e == "attrSet" then
      let
        attrs = v.attrs or { };
        names = builtins.attrNames attrs;
        bound' = if v.recursive or false then addBound bound names else bound;
        as = builtins.map (n: {
          inherit n;
          r = scopedScan bound' attrs.${n};
        }) names;
        ds = builtins.map (d: {
          nameR = scopedScan bound' d.name;
          valueR = scopedScan bound' d.value;
        }) (v.dynamicAttrs or [ ]);
      in
      {
        stripped = {
          _expr = "attrSet";
          value = {
            recursive = v.recursive or false;
            attrs = pairsOf (
              builtins.map (a: {
                name = a.n;
                value = a.r.stripped;
              }) as
            );
            dynamicAttrs = builtins.map (d: {
              name = d.nameR.stripped;
              value = d.valueR.stripped;
            }) ds;
          };
        };
        free =
          builtins.concatMap (a: a.r.free) as ++ builtins.concatMap (d: d.nameR.free ++ d.valueR.free) ds;
      }

    else if e == "let" then
      let
        attrs = v.attrs.value.attrs or { };
        names = builtins.attrNames attrs;
        bound' = addBound bound names;
        bs = builtins.map (n: {
          inherit n;
          r = scopedScan bound' attrs.${n};
        }) names;
        b = scopedScan bound' v.body;
      in
      {
        stripped = {
          _expr = "let";
          value = {
            attrs = pairsOf (
              builtins.map (x: {
                name = x.n;
                value = x.r.stripped;
              }) bs
            );
            body = b.stripped;
          };
        };
        free = builtins.concatMap (x: x.r.free) bs ++ b.free;
      }

    else if e == "lambda" then
      let
        args = v.arguments;
        hasFormals = builtins.hasAttr "formals" args;
        binderNames =
          (if (args.identifier or null) != null then [ args.identifier ] else [ ])
          ++ (if hasFormals then builtins.map (f: f.name) args.formals else [ ]);
        bound' = addBound bound binderNames;
        fs =
          if hasFormals then
            builtins.map (
              f:
              if builtins.hasAttr "defaultExpr" f then
                let
                  r = scopedScan bound' f.defaultExpr;
                in
                {
                  stripped = {
                    inherit (f) name;
                    defaultExpr = r.stripped;
                  };
                  inherit (r) free;
                }
              else
                {
                  stripped = {
                    inherit (f) name;
                  };
                  free = [ ];
                }
            ) args.formals
          else
            [ ];
        b = scopedScan bound' v.body;
      in
      {
        stripped = {
          _expr = "lambda";
          value = {
            arguments = {
              identifier = args.identifier or null;
            }
            // (
              if hasFormals then
                {
                  formals = builtins.map (r: r.stripped) fs;
                  ellipsis = args.ellipsis or true;
                }
              else
                { }
            );
            body = b.stripped;
          };
        };
        free = builtins.concatMap (r: r.free) fs ++ b.free;
      }

    else
      {
        stripped = {
          _expr = e;
          __opaque = true;
        };
        free = [ ];
      };

in
{
  inherit staticPath isFreeVar joinKey;

  # AST + free-variable set of any lambda node, for runtime `builtins.reify`.
  reifyInfo =
    node:
    let
      r = scopedScan { } node;
    in
    {
      inherit (r) stripped;
      free = builtins.attrNames (
        builtins.listToAttrs (
          builtins.map (n: {
            name = n;
            value = true;
          }) r.free
        )
      );
    };

  # ast must be a reified lambda node: { _expr = "lambda"; value = { … }; }
  analyze =
    ast:
    let
      s = scan ast;
      capture = buildCapture s.uses;
    in
    {
      inherit (s) stripped;
      key = builtins.hashString "sha256" (builtins.toJSON s.stripped);
      inherit capture;
      envKeys = builtins.attrNames capture.entries;
      closed = capture.entries == { };
    };
}
