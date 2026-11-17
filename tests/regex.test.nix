# Regex semantics — builtins.match engine differences.
#
# Nix's builtins.match uses Boost.Regex with the POSIX extended grammar,
# which understands POSIX character classes like [[:digit:]] and [[:space:]].
# JavaScript's RegExp and C++'s std::regex (libstdc++/libc++) both implement
# the ECMAScript grammar, where [[:digit:]] degenerates to the character set
# { [, :, d, i, g, t }.
#
# These cases pin the reference (Nix/Boost) semantics, so every backend that
# deviates shows up as a failing test instead of a silently wrong value.
#
# Every func takes its arguments from `params`: a body that ignored them would
# be constant-folded at capture time, so the target engine's `match` primop
# would never run and the test would pass vacuously.
{ lib, ... }:
[
  # nixpkgs' lib.strings.toIntBase10 strip-input regex; the reference value is
  # what `builtins.match` computes in Nix itself.
  {
    description = "POSIX classes: toIntBase10 strip regex matches plain digits";
    func = params: builtins.match params.regex "123";
    params = {
      regex = "[[:space:]]*0*(-?[[:digit:]]+)[[:space:]]*";
    };
    expected.toBe = [ "123" ];
  }
  {
    description = "POSIX class [[:digit:]] matches a digit (7)";
    func = params: builtins.match params.regex params.str;
    params = {
      regex = "([[:digit:]])";
      str = "7";
    };
    # POSIX / Nix / libstdc++ treat [[:digit:]] as the digit class -> matches the
    # digit 7 and captures it (the ( ) group). JS's RegExp has no POSIX classes,
    # so it produces null here.
    expected.toBe = [ "7" ];
  }
  {
    description = "POSIX class [[:digit:]] does NOT match the letter d";
    func = params: builtins.match params.regex params.str;
    params = {
      regex = "([[:digit:]])";
      str = "d";
    };
    # 'd' is not a digit, so POSIX must not match it.
    expected.toBe = null;
  }
  # Control: an ECMAScript-compatible regex that every engine must agree on.
  {
    description = "plain character classes still work (control)";
    func = params: builtins.match params.regex params.str;
    params = {
      regex = "([0-9]+)";
      str = "123";
    };
    expected.toBe = [ "123" ];
  }

  # End-to-end: the actual nixpkgs function through the translator.
  {
    description = "lib.toIntBase10 still converts '123'";
    func = params: lib.toIntBase10 params.x;
    params = {
      x = "123";
    };
    expected.toBe = 123;
  }
]
