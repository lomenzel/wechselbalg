{ pkgs }:
let
  wb = import ../lib pkgs;
  analyze = import ../lib/analyze.nix;
  captureOf = fn: (analyze.analyze (builtins.reify fn)).capture;

  # Follow the public wrapper to the real translator closure. Checking just
  # toJS's own captures would miss the whole namespace one level underneath.
  wrapperCapture = captureOf wb.toJS;
  translatorCapture = captureOf wrapperCapture.entries.translate.env;

  # Model evaluations at different times without timing-dependent sleeps.
  capabilityProbe =
    clock:
    let
      namespace = {
        currentTime = clock;
        reify = true;
      };
      available = builtins.hasAttr "reify" namespace;
    in
    _: available;
  wholeProbe =
    clock:
    let
      builtins = {
        currentTime = clock;
        reify = true;
      };
    in
    _: builtins;
  timeProbe =
    clock:
    let
      builtins = {
        currentTime = clock;
      };
    in
    _: builtins.currentTime;
  code = fn: wb.toJS fn;
  library =
    fn:
    wb.mkCppLibrary {
      value.probe = fn;
      namespace = "capturetest";
    };

  # Reproducibility of lambda *parameters*: Nix reports a lambda's formals
  # sorted by interned-symbol id — the order the identifiers happened to be
  # first parsed in *this evaluation*, which varies between nix invocations.
  # Without canonicalisation that order leaks into the template key (the
  # memoisation/caching key walk.nix groups closures by) and into the
  # generated parameter code of every backend, including the `!ellipsis`
  # guard (`if (_kv.first != ...` in C++). The output must be
  # deterministically alphabetical regardless.
  # The three names below are unique to this file and spelled in scrambled
  # (non-alphabetical) order, so in *any* evaluation context Nix reports them
  # in exactly this scrambled order: each assertion genuinely fails without
  # the corresponding normalisation.
  formalsScrambled =
    {
      xqzWbScrambleZebra,
      xqzWbScrambleApple,
      xqzWbScrambleMango ? 3,
    }:
    xqzWbScrambleZebra + xqzWbScrambleApple + xqzWbScrambleMango;
  formalsReversedAST =
    let
      ast = builtins.reify formalsScrambled;
      n = builtins.length ast.value.arguments.formals;
      reversed = builtins.genList (i: builtins.elemAt ast.value.arguments.formals (n - 1 - i)) n;
    in
    ast
    // {
      value = ast.value // {
        arguments = ast.value.arguments // {
          formals = reversed;
        };
      };
    };

  checks = {
    capabilityIsBoolean = translatorCapture.entries.hasReify.env == true;
    builtinNamespaceIsNarrow = translatorCapture.mode.builtins == "narrow";
    noWholeBuiltinCapture = !(translatorCapture.entries ? builtins);
    onlyRequiredBuiltins =
      builtins.filter (name: pkgs.lib.hasPrefix "builtins." name) (
        builtins.attrNames translatorCapture.entries
      ) == [
        "builtins.attrNames"
        "builtins.concatStringsSep"
        "builtins.hasAttr"
      ];
    stableCode = code (capabilityProbe 1) == code (capabilityProbe 2);
    stableUnits = (library (capabilityProbe 1)).sccUnits == (library (capabilityProbe 2)).sccUnits;
    stableDerivation =
      toString ((library (capabilityProbe 1)).mkDerivation pkgs)
      == toString ((library (capabilityProbe 2)).mkDerivation pkgs);
    # The template key must not depend on how the formals were listed:
    # `formalsReversedAST` is the same AST as `formalsScrambled`'s with the
    # formals reversed — both must hash to one key.
    # Exercises the analyze/scan path:
    formalsKeySpellingStable =
      (analyze.analyze (builtins.reify formalsScrambled)).key == (analyze.analyze formalsReversedAST).key;
    # The runtime `reify` metadata (`params.ast`) must be alphabetical —
    # exercises the analyze/scopedScan path endtoend:
    formalsAstAlphabetical =
      builtins.map (f: f.name)
        (analyze.reifyInfo (builtins.reify formalsScrambled)).stripped.value.arguments.formals == [
        "xqzWbScrambleApple"
        "xqzWbScrambleMango"
        "xqzWbScrambleZebra"
      ];
    # The generated code itself must order its per-formal bindings and its
    # unexpected-argument guard alphabetically — this exercises the
    # walk/params/backend path. The JS backend inlines the emitted source,
    # including the guard's allowed-keys list verbatim.
    formalsCodeAlphabetical = pkgs.lib.strings.hasInfix ("\"xqzWbScrambleApple\", \"xqzWbScrambleMango\", \"xqzWbScrambleZebra\"") (
      code formalsScrambled
    );
    intentionalWholeCapture = (captureOf (wholeProbe 1)).mode.builtins == "whole";
    intentionalWholeValueChanges = code (wholeProbe 1) != code (wholeProbe 2);
    intentionalTimeChanges = code (timeProbe 1) != code (timeProbe 2);
  };
  runner = pkgs.writeText "capture-reproducibility.js" ''
    ${wb.jsRuntime}
    const arg = Value.null_();
    const probe = ${code (capabilityProbe 2)};
    const whole = ${code (wholeProbe 2)};
    const time = ${code (timeProbe 2)};
    if (!probe.call(arg).asBool()) throw new Error("capability changed");
    if (whole.call(arg).get("currentTime").asInt() !== 2n) throw new Error("whole capture changed");
    if (time.call(arg).asInt() !== 2n) throw new Error("explicit time capture changed");
  '';
in
assert builtins.all (name: pkgs.lib.assertMsg checks.${name} "capture-reproducibility: ${name}") (
  builtins.attrNames checks
);
pkgs.runCommand "wechselbalg-capture-reproducibility" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
  node ${runner}
  touch "$out"
''
