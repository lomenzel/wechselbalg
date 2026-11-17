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

let
  storeDir = builtins.storeDir;
  storeDirLen = builtins.stringLength storeDir;

  # Absolute, and not a truncated/invalid store path (those make string
  # filesystem builtins throw "too short to be a valid store path").
  storeStringSafe =
    s:
    let
      isStorePrefix = builtins.substring 0 storeDirLen s == storeDir;
      rest = builtins.substring (storeDirLen + 1) (builtins.stringLength s - storeDirLen - 1) s;
      hasStoreName = builtins.match "[a-z0-9]+-[A-Za-z0-9_\\+\\.=\\+-]+" rest != null;
    in
    builtins.substring 0 1 s == "/"
    && (!isStorePrefix || builtins.stringLength s <= (storeDirLen + 1) || hasStoreName);

  hasNixSuffix =
    s: builtins.stringLength s >= 4 && builtins.substring (builtins.stringLength s - 4) 4 s == ".nix";

  hasDefaultNix = dir: builtins.pathExists (dir + "/default.nix");

  # Nix strings cannot carry NUL bytes; treat NUL-containing input as binary
  # so compiled output doesn't inline megabytes of a binary blob.
  hasNullByte = s: builtins.match "[^\u0000]*" s == null;

  # Probe `s`. Never throws (string args only used after `storeStringSafe`,
  # existence confirmed with `pathExists` / `readFileType` first).
  probe =
    s:
    let
      accessible = storeStringSafe s && builtins.pathExists s;
      fileTypeRaw = if accessible then (builtins.readFileType s or null) else null;
      fileType = if fileTypeRaw == null then "unknown" else fileTypeRaw;
      isFile = fileType == "regular" || fileType == "symlink";
      isDir = fileType == "directory";

      readFileTry =
        if isFile then
          builtins.tryEval (builtins.readFile s)
        else
          {
            success = false;
            value = null;
          };
      content = if readFileTry.success && !hasNullByte readFileTry.value then readFileTry.value else null;

      readDirTry =
        if isDir then
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
      importable = (isDir && hasDefaultNix s) || (isFile && hasNixSuffix s);
    in
    {
      inherit accessible importable;
      fs = {
        origin = if accessible then "available" else "unreachable";
        exists = accessible;
        inherit fileType;
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
    hasNullByte
    probe
    ;
}
