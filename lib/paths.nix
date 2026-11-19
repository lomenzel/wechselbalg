# Paths — translation-time filesystem probes for Nix path literals.
#
# The walker lowers every path to an IR `path` node:
#
#   { _t = "path"; path = <absolute string, as reify produced it>;
#     fs = <result of `probe` below>;
#     value = <IR of the imported value> | null; }
#
# A target language has no access to the filesystem that existed while
# translating, so everything `builtins.readFile`, `readDir`, `pathExists`,
# `readFileType` and `import` would answer is *recorded here* and embedded
# in the generated code as lazy metadata attached to the path value.
#
# Safety notes (the Nix evaluator does NOT protect the translator):
# - `tryEval` catches SysError (ENOENT, is-a-directory, …) but NOT
#   restricted-path errors (pure evaluation) and NOT ParseError.
# - `builtins.pathExists` never throws for ordinary paths (it returns false
#   for inaccessible paths, e.g. outside a pure-mode sandbox), but throws for
#   strings that start with `builtins.storeDir` yet lack a valid store-path
#   basename — hence `storeStringSafe` gates every string probe.
# - `import` of a non-parsable file raises an uncatchable ParseError, so we
#   only import `.nix` files and directories containing `default.nix`.
# - NUL bytes cannot be represented in Nix strings; binary files are recorded
#   as "exists, unreadable" instead of embedding garbage.

{
  maxFileChars ? null,
}:
let
  storeDir = builtins.storeDir;
  storeDirLen = builtins.stringLength storeDir;

  # Absolute, and not a truncated/invalid store path (those make string
  # filesystem builtins throw "too short to be a valid store path").
  # NOTE: `substring` is strict in its argument even inside `&&`, so the guard
  # must be an explicit if/else.
  storeStringSafe =
    s:
    let
      isStorePrefix = builtins.substring 0 storeDirLen s == storeDir;
      rest = builtins.substring (storeDirLen + 1) (builtins.stringLength s - storeDirLen - 1) s;
      # `builtins.match` anchors fully, so a bare prefix pattern never matches
      # a path with sub-components. Match the basename (Nix's own name grammar:
      # [a-z0-9]+-[a-zA-Z0-9._+-]+ — an unescaped trailing '-' in a class was
      # silently dropped, rejecting names like `*-source` or `*-test-*`) with
      # an optional sub-path tail.
      nameParts = builtins.match "([a-z0-9]+-[a-zA-Z0-9._+-]+)(/[^/]*)*" rest;
      hasStoreName = nameParts != null && builtins.length nameParts > 0;
    in
    if builtins.substring 0 1 s != "/" then
      false
    else if !isStorePrefix || builtins.stringLength s <= (storeDirLen + 1) then
      true
    else
      hasStoreName;

  hasNixSuffix =
    s: builtins.stringLength s >= 4 && builtins.substring (builtins.stringLength s - 4) 4 s == ".nix";

  hasDefaultNix = dir: builtins.pathExists (dir + "/default.nix");

  # Probe `s`. Accepts either a Nix path or its absolute-string form (reify
  # gives strings); converts with `builtins.toString`, which for an *existing*
  # path is pure-safe, and never throws on ordinary filesystem paths.
  probe =
    s0:
    let
      s = builtins.toString s0;
      accessible = storeStringSafe s && builtins.pathExists s;
      # `readFileType` is a fork extension. It takes a *string* argument and —
      # unlike readDir/readFile — its "does not exist" error is NOT caught by
      # tryEval, so it may only run after the string-argument existence gate
      # below (`existsStr`).
      hasReadFileType = builtins.hasAttr "readFileType" builtins;
      fileTypeTry =
        if existsStr && hasReadFileType then
          builtins.tryEval (builtins.readFileType s)
        else
          {
            success = false;
            value = null;
          };
      fileTypeRaw = if fileTypeTry.success then fileTypeTry.value else null;
      fileType = if fileTypeRaw == null then "unknown" else fileTypeRaw;
      isFile = fileType == "regular" || fileType == "symlink";
      isDir = fileType == "directory";

      # Without `readFileType` (stock evaluator), distinguish file from dir by
      # a tryEval'd probe: readDir succeeds on dirs, throws SysError (caught)
      # on files. Gated on the string-argument existence check so pure-mode
      # restricted paths can't raise uncatchable errors here either.
      typeByTry =
        if !existsStr then
          "unknown"
        else
          let
            dirTry = builtins.tryEval (builtins.readDir s);
          in
          if dirTry.success then "directory" else "regular";
      fileTypeFinal = if fileType == "unknown" && existsStr then typeByTry else fileType;
      # Gate every *string*-argument filesystem call on a string-argument
      # `pathExists`: under pure evaluation, string fs calls on inaccessible
      # paths raise uncatchable RestrictedPathErrors (even for ENOENT), which
      # tryEval cannot catch. This check itself never throws.
      existsStr = storeStringSafe s && builtins.pathExists s;

      # Binary files are rejected by `builtins.readFile` itself (NUL bytes /
      # invalid UTF-8) and caught by tryEval; a few binaries fail with an
      # *uncatchable* error instead — the size cap below keeps those out. Only
      # *content* is capped: the metadata record (exists/fileType/dir listing)
      # never depends on reading the file, so an over-large or unreadable file
      # still gets a complete record — just no embedded content (a runtime
      # throw in target code names the limit).
      maxContentChars = if maxFileChars != null then maxFileChars else 10000;

      readFileTry =
        if existsStr && (fileTypeFinal == "regular" || fileTypeFinal == "symlink") then
          builtins.tryEval (builtins.readFile s)
        else
          {
            success = false;
            value = null;
          };
      content =
        if readFileTry.success && builtins.stringLength readFileTry.value <= maxContentChars then
          readFileTry.value
        else
          null;

      readDirTry =
        if existsStr && fileTypeFinal == "directory" then
          builtins.tryEval (builtins.readDir s)
        else
          {
            success = false;
            value = null;
          };
      dirListing = if readDirTry.success then readDirTry.value else null;

      # Only `.nix` files and dirs with a default.nix may be imported without
      # risking an uncatchable ParseError; the actual import (which can throw
      # in ways tryEval *does* catch) happens in the walker.
      # NOTE: `hasDefaultNix` must never run on inaccessible paths — under
      # pure evaluation it would raise an uncatchable RestrictedPathError.
      importable =
        accessible
        && (
          (fileTypeFinal == "directory" && hasDefaultNix s)
          || ((fileTypeFinal == "regular" || fileTypeFinal == "symlink") && hasNixSuffix s)
        );
    in
    {
      inherit accessible importable;
      fs = {
        origin = if accessible then "available" else "unreachable";
        exists = accessible;
        fileType = fileTypeFinal;
        inherit content;
        dir = dirListing;
      };
    };
in
{
  inherit
    storeStringSafe
    hasNixSuffix
    hasDefaultNix
    probe
    ;
}
