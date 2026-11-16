{ pkgs }:
let
  wb = import ../lib pkgs;
  defaultSpec = wb.mkCppLibrary {
    value = { };
    namespace = "batchtest";
  };
  defaultCompileBatchSize = defaultSpec.compileBatchSize;
  defaultChunkSize = defaultSpec.chunkSize;
  # Direct internal fixtures inherit the public API's default, not their own.
  group = args: import ../lib/compile-batches.nix ({ batchSize = defaultCompileBatchSize; } // args);
  builder = import ../lib/builder.nix { inherit pkgs; };

  units = builtins.genList (i: {
    fileName = "scc_${toString i}.cpp";
    content = "unit ${toString i}";
  }) 3000;
  batches = group { inherit units; };
  reverse =
    list:
    builtins.genList (i: builtins.elemAt list (builtins.length list - i - 1)) (builtins.length list);
  enlarged = group {
    units = units ++ [
      {
        fileName = "scc_extra.cpp";
        content = "extra";
      }
    ];
  };
  changed = group {
    units = builtins.map (
      unit: unit // { content = if unit.fileName == "scc_0.cpp" then "changed" else unit.content; }
    ) units;
  };
  splitUnits = builtins.genList (i: {
    fileName = "large_${toString i}.cpp";
    content = "chunk ${toString i}";
    isChunked = true;
  }) 8;
  mixedBatches = group { units = units ++ splitUnits; };
  smallBatches = builtins.filter (
    batch: builtins.all (unit: !(unit.isChunked or false)) batch.units
  ) mixedBatches;
  isolatedBatches = builtins.filter (
    batch: builtins.any (unit: unit.isChunked or false) batch.units
  ) mixedBatches;

  # Test the metadata at the real renderer boundary, without AST introspection.
  ir = import ../lib/ir.nix;
  mkScc =
    size:
    let
      names = builtins.genList (i: "__wb_val_fixture_${toString size}_${toString i}") size;
    in
    {
      sccHash = "fixture${toString size}";
      inherit names;
      items = builtins.listToAttrs (
        builtins.map (name: {
          inherit name;
          value = {
            isFunc = false;
            expr = ir.int 1;
          };
        }) names
      );
    };
  renderedSccs = (import ../lib/render-scc.nix { inherit pkgs; }).render {
    namespace = "metadataTest";
    value = { };
    merkleResult = {
      sccs = builtins.map mkScc [
        15
        16
        31
      ];
      ir = ir.attrs { };
      rootDeps = [ ];
    };
  };
  renderedBatches = group { units = renderedSccs.sccUnits; };
  invalidSize =
    size:
    !(builtins.tryEval (
      builtins.deepSeq (group {
        units = [ ];
        batchSize = size;
      }) true
    )).success;

  checks = {
    apiDefault = builtins.isInt defaultCompileBatchSize && defaultCompileBatchSize > 0;
    chunkApiDefault = defaultChunkSize == 15;
    apiOverride =
      (wb.mkCppLibrary {
        value = { };
        namespace = "batchtest";
        compileBatchSize = 7;
      }).compileBatchSize == 7;
    chunkApiOverride =
      (wb.mkCppLibrary {
        value = { };
        namespace = "batchtest";
        chunkSize = 7;
      }).chunkSize == 7;
    functorDefault =
      (wb.toCpp { } { library.namespace = "batchtest"; }).compileBatchSize == defaultCompileBatchSize;
    functorOverride =
      (wb.toCpp { } {
        library = {
          namespace = "batchtest";
          compileBatchSize = 7;
        };
      }).compileBatchSize == 7;
    functorChunkOverride =
      (wb.toCpp { } {
        library = {
          namespace = "batchtest";
          chunkSize = 7;
        };
      }).chunkSize == 7;
    builderRequiresExplicitSize = !(builtins.functionArgs builder.buildLibrary).compileBatchSize;
    plannerRequiresExplicitSize =
      !(builtins.functionArgs (import ../lib/compile-batches.nix)).batchSize;
    empty = group { units = [ ]; } == [ ];
    bounded = builtins.all (
      batch: builtins.length batch.units <= defaultCompileBatchSize && batch.units != [ ]
    ) batches;
    complete =
      builtins.sort (a: b: a.fileName < b.fileName) (builtins.concatMap (batch: batch.units) batches)
      == builtins.sort (a: b: a.fileName < b.fileName) units;
    fewerDerivations = defaultCompileBatchSize == 1 || builtins.length batches < builtins.length units;
    deterministic = batches == group { units = reverse units; };
    chunksIsolated =
      builtins.length isolatedBatches == 8
      && builtins.all (batch: builtins.length batch.units == 1) isolatedBatches;
    chunksPreserved = builtins.concatMap (batch: batch.units) isolatedBatches == splitUnits;
    chunksDoNotAffectSmallBatches = smallBatches == batches;
    chunksOnly =
      builtins.length (group {
        units = splitUnits;
      }) == 8;
    chunkIdsUnique =
      builtins.length (
        builtins.attrNames (
          builtins.listToAttrs (
            builtins.map (batch: {
              name = batch.id;
              value = null;
            }) mixedBatches
          )
        )
      ) == builtins.length mixedBatches;
    mixedDeterministic = mixedBatches == group { units = reverse (units ++ splitUnits); };
    changedChunksDoNotAffectSmallBatches = builtins.all (
      batch:
      builtins.elem batch (group {
        units =
          units
          ++ builtins.map (
            unit:
            unit
            // {
              fileName = "changed_${unit.fileName}";
              content = "changed";
            }
          ) splitUnits;
      })
    ) batches;
    rendererMarksChunks =
      builtins.map (unit: unit.isChunked) renderedSccs.sccUnits == [
        false
        true
        true
        true
        true
        true
      ];
    rendererChunksIsolated =
      builtins.length renderedBatches == 6
      && builtins.all (batch: builtins.length batch.units == 1) renderedBatches;
    localInsertion =
      builtins.length (builtins.filter (batch: builtins.elem batch enlarged) batches)
      >= builtins.length batches - 1;
    localChange =
      builtins.length (builtins.filter (batch: builtins.elem batch changed) batches)
      == builtins.length batches - 1;
    singletons =
      builtins.length (group {
        inherit units;
        batchSize = 1;
      }) == 3000;
    invalidSizes = builtins.all invalidSize [
      0
      (-1)
      1.5
      "64"
      null
    ];
    collisions =
      builtins.map (batch: builtins.length batch.units) (group {
        batchSize = 2;
        units = builtins.genList (_: { fileName = "same.cpp"; }) 5;
      }) == [
        2
        2
        1
      ];
  };

  count = 9;
  fixtureUnits = builtins.genList (i: {
    sccHash = "fixture_c${toString i}";
    fileName = "scc_fixture_c${toString i}.cpp";
    content = ''
      #include "wechselbalg/value.hpp"
      // Shell metacharacters must survive verbatim: '$HOME $(false) `false`
      namespace { int local() { return ${toString i}; } }
      int unit_${toString i}() { return local() + wbOffset; }
    '';
  }) count;
  rendered = {
    namespace = "batchtest";
    sccUnits = fixtureUnits;
    "include/wechselbalg/value.hpp" = ''
      #pragma once
      inline constexpr int wbOffset = 1;
    '';
    "include/batchtest.hpp" = ''
      #pragma once
      namespace batchtest { int result(); }
    '';
    "src/_primops.cpp" = "int primops() { return 1; }";
    "src/_root.cpp" = ''
      #include "batchtest.hpp"
      int primops();
      ${builtins.concatStringsSep "\n" (builtins.genList (i: "int unit_${toString i}();") count)}
      int batchtest::result() {
        return primops() ${
          builtins.concatStringsSep "" (builtins.genList (i: " + unit_${toString i}()") count)
        };
      }
    '';
  };
  groupedLib = builder.buildLibrary {
    inherit rendered;
    compileBatchSize = 3;
  };
  defaultLib = builder.buildLibrary {
    inherit rendered;
    compileBatchSize = defaultCompileBatchSize;
  };
  singleLib = builder.buildLibrary {
    inherit rendered;
    compileBatchSize = 1;
  };
  mixedUnits = builtins.genList (
    i:
    (builtins.elemAt fixtureUnits i)
    // {
      isChunked = i < 3;
    }
  ) count;
  mixedLib = builder.buildLibrary {
    compileBatchSize = defaultCompileBatchSize;
    rendered = rendered // {
      sccUnits = mixedUnits;
    };
  };
  unchunkedLib = builder.buildLibrary {
    compileBatchSize = defaultCompileBatchSize;
    rendered = rendered // {
      sccUnits = builtins.filter (unit: !unit.isChunked) mixedUnits;
    };
  };
  emptyLib = builder.buildLibrary {
    compileBatchSize = defaultCompileBatchSize;
    rendered = rendered // {
      sccUnits = [ ];
      "src/_root.cpp" = ''
        #include "batchtest.hpp"
        int batchtest::result() { return 46; }
      '';
    };
  };
  runner = pkgs.writeText "batchtest.cpp" ''
    #include "batchtest.hpp"
    int main() { return batchtest::result() == 46 ? 0 : 1; }
  '';
in
assert builtins.all (name: pkgs.lib.assertMsg checks.${name} "compile-batches: ${name}") (
  builtins.attrNames checks
);
assert builtins.length groupedLib.compileBatches >= 3;
assert builtins.length defaultLib.compileBatches == 1;
assert builtins.length singleLib.compileBatches == count;
assert builtins.length mixedLib.compileBatches == 4;
assert builtins.all (
  batch: builtins.elem (toString batch) (builtins.map toString mixedLib.compileBatches)
) unchunkedLib.compileBatches;
assert emptyLib.compileBatches == [ ];
pkgs.runCommandCC "wechselbalg-compile-batches" { } ''
  for library in ${groupedLib} ${defaultLib} ${singleLib} ${mixedLib} ${emptyLib}; do
    $CXX -std=c++23 ${runner} -I"$library/include" "$library/lib/libbatchtest.a" -o runner
    ./runner
    test -f "$library/include/wechselbalg/value.hpp"
  done

  # A batch outputs separate objects, not a unity TU or nested archive.
  objects=0
  for batch in ${builtins.concatStringsSep " " (builtins.map toString groupedLib.compileBatches)}; do
    batch_objects=0
    for object in "$batch"/*.o; do
      test -f "$object"
      objects=$((objects + 1))
      batch_objects=$((batch_objects + 1))
    done
    test "$batch_objects" -le 3
  done
  test "$objects" -eq ${toString count}
  test "$($AR t ${groupedLib}/lib/libbatchtest.a | wc -l)" -eq ${toString (count + 2)}

  # Split-SCC chunks must never share a compilation derivation with any unit.
  standalone=0
  grouped=0
  for batch in ${builtins.concatStringsSep " " (builtins.map toString mixedLib.compileBatches)}; do
    set -- "$batch"/*.o
    case "$batch" in
      *-wb-scc-batch-chunk-*)
        test "$#" -eq 1
        standalone=$((standalone + 1))
        ;;
      *)
        test "$#" -eq 6
        grouped=$((grouped + 1))
        ;;
    esac
  done
  test "$standalone" -eq 3
  test "$grouped" -eq 1
  touch "$out"
''
