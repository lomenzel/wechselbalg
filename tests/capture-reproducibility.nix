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
