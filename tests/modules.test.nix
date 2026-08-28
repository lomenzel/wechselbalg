# evalModules tests — using the REAL nixpkgs lib.evalModules.
#
# Each test translates a function that calls the real lib.evalModules.
# The entire module system (evalModules + types + merge logic) is carried
# as closure values and translated alongside the test logic.
#
# This exercises the full pipeline: reify → walk → IR → backend for the
# real-world NixOS module system.
#
# Note: each test independently translates evalModules (~9M chars), so
# we keep the number of tests small to avoid very long build times.
# lib: [
#   {
#     description = "evalModules";
#     func =
#       params:
#       let
#         result = evalModules {
#           modules = [
#             (
#               { lib, config, ... }:
#               {
#                 options.unset = lib.mkOption {
#                   type = lib.types.int;
#                   default = 99 + params.p1;
#                 };
#                 options.base = lib.mkOption {
#                   type = lib.types.int;
#                   default = 0;
#                 };
#                 options.doubled = lib.mkOption {
#                   type = lib.types.int;
#                   default = config.base * 2;
#                 };
#                 options.list = lib.mkOption {
#                   type = lib.types.listOf lib.types.int;
#                 };
#                 config.list = [
#                   1
#                   2
#                 ];
#               }
#             )
#             (
#               { config, ... }:
#               {
#                 base = params.p2;
#                 #doubled = config.base * 2;
#                 list = [ params.p3 ];
#               }
#             )
#           ];
#         };
#       in
#       result.config;
#     params = {
#       p1 = 1;
#       p2 = 7;
#       p3 = 3;
#     };
#     expected.toBe = {
#       unset = 100;
#       base = 7;
#       doubled = 14;
#       list = [
#         3
#         1
#         2
#       ];
#     };
#   }
# ]
lib: [ ]
