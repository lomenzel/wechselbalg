# Import fixture for paths.test.nix: a module directory consumed via
# `imports = [ ./path-import-mod ]` — evalModules-style path imports resolved
# at translation time and carried in the translated program.
{
  value = 42;
}
