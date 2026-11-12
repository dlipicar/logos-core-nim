{
  description = "logos-core-nim: the Logos Core module specs in Nim";

  inputs = {
    # The release-25.11 commit logos-storage-nim pins, so the Nim 2.2.14
    # overlay builds the same compiler derivation.
    nixpkgs.url = "github:NixOS/nixpkgs/cd648d6ea62bc0ffba91e61fcfe5e33c1e2004b1";
    # Only for nph 0.7.0 (release-25.11 has 0.6.1, which formats differently).
    nixpkgs-nph.url = "github:NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6";
    # The specs under implementation.
    logos-lips = {
      url = "git+https://github.com/logos-co/logos-lips?ref=draft/logos-core-module-specs&rev=6a4dfa2846ab9f1f679ad285f8caa848ee8544ad";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-nph,
      logos-lips,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system);

      nimbleFile = builtins.readFile ./logos_core.nimble;
      nimVersion = lib.head (
        lib.head (
          lib.remove null (
            map (builtins.match "^requires \"nim == ([0-9.]+)\".*") (lib.splitString "\n" nimbleFile)
          )
        )
      );

      perSystem =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import ./nix/nim-overlay.nix) ];
          };
          nim =
            assert lib.assertMsg (pkgs.nim-2_2.version == nimVersion)
              "logos_core.nimble requires Nim ${nimVersion}, but nix/nim-overlay.nix provides ${pkgs.nim-2_2.version}";
            pkgs.nim-2_2;
          nph = nixpkgs-nph.legacyPackages.${system}.nph;
          python = pkgs.python3.withPackages (ps: [
            ps.cbor2
            ps.blake3
          ]);

          deps = import ./nix/nimble-deps.nix {
            inherit (pkgs) lib fetchgit;
            lockFile = ./nimble.lock;
            hashesFile = ./nix/nimble-deps.json;
          };
          nimDerivation = pkgs.callPackage ./nix/nim-derivation.nix { inherit nim deps; };

          nimSources = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./logos_core.nimble
              ./config.nims
              ./.nph.toml
              ./src
              ./tests
              ./spec
            ];
          };

          testFiles = lib.filter (n: lib.hasPrefix "test_" n && lib.hasSuffix ".nim" n) (
            builtins.attrNames (builtins.readDir ./tests)
          );
          # Both memory managers (refc modules link this code), and a release
          # build: INTERFACE §4.5 forbids build-mode-dependent bytes.
          testVariants = [
            {
              suffix = "orc";
              flags = "--mm:orc";
            }
            {
              suffix = "refc";
              flags = "--mm:refc";
            }
            {
              suffix = "orc-release";
              flags = "--mm:orc -d:release";
            }
          ]
          # Sanitizers (switches in config.nims) on Linux: macOS has no MemorySanitizer, and
          # nixpkgs' clang 21 sanitizer runtimes do not start on macOS 27, so the Mac runs
          # `nimble test_asan` and `nimble test_tsan` with the Xcode toolchain instead.
          ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            {
              suffix = "asan";
              flags = "--mm:orc -d:asan";
              sanitizer = true;
            }
            {
              suffix = "tsan";
              flags = "--mm:orc -d:tsan";
              sanitizer = true;
            }
            {
              suffix = "msan";
              flags = "--mm:orc -d:msan";
              sanitizer = true;
              # llvm-symbolizer, for the reports' stack traces.
              nativeBuildInputs = [
                pkgs.clang
                pkgs.llvm
              ];
              # The Nix Nim build takes its C compiler from CC, which stdenv sets to gcc.
              setup = "export CC=clang";
              # On aarch64 a library loaded with dlopen reaches its thread-local variables
              # through TLS descriptors, which bypass the `__tls_get_addr` interceptor that
              # tells MemorySanitizer glibc initialized them: Nim's start-up in every such
              # library reads as uninitialized. x86_64 runs these suites (DECISIONS I77).
              skip =
                file:
                pkgs.stdenv.hostPlatform.isAarch64
                && lib.elem file [
                  "test_engine.nim"
                  "test_kit_dylib.nim"
                  "test_realizer.nim"
                  "test_routes.nim"
                ];
            }
          ];
          testChecks = lib.listToAttrs (
            lib.concatMap (
              file:
              map (
                variant:
                let
                  name = "${lib.removeSuffix ".nim" file}-${variant.suffix}";
                in
                lib.nameValuePair name (
                  nimDerivation (
                    {
                      inherit name;
                      src = nimSources;
                      nativeBuildInputs = variant.nativeBuildInputs or [ ];
                      buildPhase = ''
                        runHook preBuild
                        ${variant.setup or ""}
                        nim c -r ${variant.flags} --outdir:build tests/${file}
                        runHook postBuild
                      '';
                    }
                    // lib.optionalAttrs (variant.sanitizer or false) {
                      # The sanitizers do not intercept _FORTIFY_SOURCE's checked libc calls.
                      hardeningDisable = [
                        "fortify"
                        "fortify3"
                      ];
                    }
                  )
                )
              ) (lib.filter (variant: !(variant.skip or (_: false)) file) testVariants)
            ) testFiles
          );

          specRaw = "${logos-lips}/docs/logos-core/raw";

          # Requirement traceability and spec mirrors against the pinned specs;
          # pass --specs <dir> to compare with another revision.
          spectrace = pkgs.writeShellApplication {
            name = "spectrace";
            runtimeInputs = [ python ];
            text = ''
              export SPECTRACE_SPECS="''${SPECTRACE_SPECS:-${specRaw}}"
              export SPECTRACE_REV="''${SPECTRACE_REV:-${logos-lips.rev}}"
              exec python3 ${./tools/spectrace/spectrace.py} "$@"
            '';
          };

          specSources = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./spec
              ./conformance
              ./tests
              ./oracle
              ./src/logos_core/pins.nim
              ./src/logos_core/base/nfc_tables.nim
            ];
          };
          specCheck =
            name: command:
            pkgs.runCommand name { nativeBuildInputs = [ spectrace python ]; } ''
              cd ${specSources}
              # A subshell: under `set -e` a failure before the last step of an
              # `a && b` list would not stop the script, and the check would pass.
              ( ${command} ) || exit 1
              touch $out
            '';
          specChecks = {
            spec-mirrors = specCheck "spec-mirrors" "spectrace mirror";
            spec-pins = specCheck "spec-pins" "spectrace pins";
            spec-ledger = specCheck "spec-ledger" "spectrace check";
            spec-gate = specCheck "spec-gate" "spectrace gate";
            oracle-selftest = specCheck "oracle-selftest" "python3 oracle/selftest.py && python3 oracle/gen_cddl_vectors.py --check && python3 oracle/gen_hash_vectors.py --check && python3 oracle/gen_cose_vectors.py --check && python3 oracle/gen_nfc_tables.py --check";
          };

          # INTERFACE §2.1-§2.3, §2.5, §5.2 C type headers (types only, D29).
          lcnGen = nimDerivation {
            pname = "lcn-gen";
            version = "0.0.1";
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c -d:release --outdir:build/bin src/lcn_gen.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/lcn_gen $out/bin/lcn-gen
            '';
            meta.mainProgram = "lcn-gen";
          };

          # PM §3, §4, §4.3, §7.1 package tools (a subset: no fetch or install).
          lcnPkg = nimDerivation {
            pname = "lcn-pkg";
            version = "0.0.1";
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c -d:release --outdir:build/bin src/lcn_pkg.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/lcn_pkg $out/bin/lcn-pkg
            '';
            meta.mainProgram = "lcn-pkg";
          };

          # Android suites, SDK and emulator runner (nix/android.nix); x86_64 Linux
          # hosts only, where the emulator has KVM. Not part of `checks`.
          android =
            if system == "x86_64-linux" then
              import ./nix/android.nix {
                inherit
                  lib
                  pkgs
                  nixpkgs
                  system
                  nimDerivation
                  nimSources
                  testFiles
                  testVariants
                  ;
              }
            else
              null;

          # iOS simulator runner (nix/ios.nix); Apple silicon hosts with Xcode.
          ios =
            if system == "aarch64-darwin" then
              import ./nix/ios.nix {
                inherit
                  lib
                  pkgs
                  nim
                  nimSources
                  testVariants
                  deps
                  ;
              }
            else
              null;

          updateNimbleDeps = pkgs.writeShellApplication {
            name = "update-nimble-deps";
            runtimeInputs = [
              pkgs.jq
              pkgs.nix-prefetch-git
              pkgs.git
              pkgs.nix
            ];
            text = builtins.readFile ./nix/update-nimble-deps.sh;
          };
        in
        {
          inherit
            pkgs
            nim
            nph
            python
            nimSources
            testChecks
            specChecks
            spectrace
            lcnGen
            lcnPkg
            android
            ios
            updateNimbleDeps
            ;
        };

      bySystem = forAllSystems perSystem;
    in
    {
      packages = forAllSystems (
        system:
        let
          s = bySystem.${system};
        in
        {
          inherit (s) nim nph spectrace;
          lcn-gen = s.lcnGen;
          lcn-pkg = s.lcnPkg;
        }
        // lib.optionalAttrs (s.android != null) {
          android-sdk = s.android.sdk.androidsdk;
          android-suites-x86_64 = s.android.suites-x86_64;
          android-suites-arm64 = s.android.suites-arm64;
        }
      );

      apps = forAllSystems (system: {
        update-nimble-deps = {
          type = "app";
          program = lib.getExe bySystem.${system}.updateNimbleDeps;
        };
        spectrace = {
          type = "app";
          program = lib.getExe bySystem.${system}.spectrace;
        };
        lcn-gen = {
          type = "app";
          program = lib.getExe bySystem.${system}.lcnGen;
        };
        lcn-pkg = {
          type = "app";
          program = lib.getExe bySystem.${system}.lcnPkg;
        };
      }
      // lib.optionalAttrs (bySystem.${system}.android != null) {
        test-android = {
          type = "app";
          program = lib.getExe bySystem.${system}.android.testAndroid;
        };
      }
      // lib.optionalAttrs (bySystem.${system}.ios != null) {
        test-ios = {
          type = "app";
          program = lib.getExe bySystem.${system}.ios.testIos;
        };
      });

      checks = forAllSystems (
        system:
        let
          s = bySystem.${system};
        in
        s.testChecks
        // s.specChecks
        // {
          nph = s.pkgs.runCommand "nph-check" { nativeBuildInputs = [ s.nph ]; } ''
            cd ${s.nimSources}
            nph --check src tests logos_core.nimble config.nims
            touch $out
          '';
          # No `?` inside a half-built constructor: it leaks on Nim 2.2.14 (I77).
          lint-ctor-try = s.pkgs.runCommand "lint-ctor-try" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 ${./tools/lint/ctortry.py} src tests
            touch $out
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          s = bySystem.${system};
        in
        {
          default = s.pkgs.mkShell {
            packages = [
              s.nim
              s.pkgs.nimble
              s.nph
              s.python
              s.pkgs.jq
              # Nimble shells out to git; on macOS the /usr/bin/git shim fails inside the shell.
              s.pkgs.git
              s.pkgs.nix-prefetch-git
              s.spectrace
            ];
          };
        }
        // lib.optionalAttrs (s.android != null) {
          # adb, the emulator and the NDK, for working on a device by hand.
          android = s.pkgs.mkShell {
            packages = [
              s.nim
              s.pkgs.nimble
              s.android.sdk.androidsdk
            ];
            ANDROID_SDK_ROOT = "${s.android.sdk.androidsdk}/libexec/android-sdk";
            ANDROID_NDK_ROOT = "${s.android.sdk.ndk-bundle}/libexec/android-sdk/ndk-bundle";
          };
        }
      );

      formatter = forAllSystems (system: bySystem.${system}.nph);
    };
}
