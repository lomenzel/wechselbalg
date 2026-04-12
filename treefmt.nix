{ pkgs, ... }:
{
  programs = {
    nixfmt.enable = true;
    prettier.enable = true;
    clang-format.enable = true;
    black.enable = true;
  };
}
