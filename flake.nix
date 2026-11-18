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
          tlsPeerPython = pkgs.python3.withPackages (ps: [ ps.pyopenssl ]);

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
              # test_host checks the documented schema is the one in src.
              ./docs/HOST-CONFIG.md
              # test_authority loads the documented example policy and format.
              ./docs/AUTHORITY-POLICY.md
              # test_daemon_config checks the documented CDDL is the one in src.
              ./docs/DAEMON.md
              # test_deployment checks the deployment document's facts block.
              ./docs/DEPLOYMENT.md
              # The service-manager units for logosd (DAEMON.md §13).
              ./contrib
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
              # Beside them, test_hosted_routes' run.mixed cases skip themselves under
              # MemorySanitizer on every architecture (DECISIONS G342): their refc module
              # libraries are built without the sanitizer, and an uninstrumented library's
              # writes read as uninitialized.
              skip =
                file:
                pkgs.stdenv.hostPlatform.isAarch64
                && lib.elem file [
                  "test_boundary_invariance.nim"
                  "test_deployment.nim"
                  "test_engine.nim"
                  "test_host.nim"
                  "test_host_dylib.nim"
                  "test_hosted.nim"
                  "test_hosted_permissions.nim"
                  "test_hosted_routes.nim"
                  "test_kit_dylib.nim"
                  "test_logosd.nim"
                  "test_module_host.nim"
                  "test_realizer.nim"
                  "test_routes.nim"
                  "test_wipe_routes.nim"
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
                    // lib.optionalAttrs (file == "test_remote_tls.nim") {
                      # The independent TLS peer (DECISIONS G128): test only.
                      LCN_TLS_PEER_PYTHON = "${tlsPeerPython}/bin/python3";
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
              # spec-deploydoc checks the deployment document against the claims (G309).
              ./docs/DEPLOYMENT.md
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
            spec-gate = specCheck "spec-gate" "spectrace gate --closed-tier 1 --closed-tier 2 --closed-tier 3 --closed-tier 4 --closed-tier 4b";
            spec-deploydoc = specCheck "spec-deploydoc" "spectrace deploydoc";
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

          # The Module Host program (Tier 4b step 4b-3; DECISIONS G264): one process per
          # hosted module instance, started by the Runtime from `runtime.module_host`.
          logosModuleHost = nimDerivation {
            pname = "logos-module-host";
            version = "0.0.1";
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c -d:release --outdir:build/bin src/logos_module_host.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/logos_module_host $out/bin/logos-module-host
            '';
            meta.mainProgram = "logos-module-host";
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

          # logosd and logosctl (Tier 4b step 4b-6; DECISIONS I95; docs/DAEMON.md): orc
          # release builds without test hooks (R5, D27). logosd finds the Module Host at
          # ../libexec/logos-core, where its package puts it.
          daemonVersion = "0.0.1";
          logosd = nimDerivation {
            pname = "logosd";
            version = daemonVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c --mm:orc -d:release -d:lcnVersion=${daemonVersion} --outdir:build/bin src/logosd.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/logosd $out/bin/logosd
              install -Dm755 ${lib.getExe logosModuleHost} $out/libexec/logos-core/logos-module-host
            '';
            meta.mainProgram = "logosd";
          };
          logosctl = nimDerivation {
            pname = "logosctl";
            version = daemonVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c --mm:orc -d:release -d:lcnVersion=${daemonVersion} --outdir:build/bin src/logosctl.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/logosctl $out/bin/logosctl
            '';
            meta.mainProgram = "logosctl";
          };

          # The packaged daemon and shell, run (step 4b-6 plan §4.6): init, start, status,
          # module ls, stop; then test_hooks with the switch on, which this logosd refuses.
          logosdSmoke =
            pkgs.runCommand "logosd-smoke"
              {
                nativeBuildInputs = [
                  logosd
                  logosctl
                ];
              }
              ''
                set -eu
                s=$TMPDIR/s
                ctl() { logosctl --session-dir "$s" "$@"; }
                ctl init > init.out
                # The default module_host is the packaged one. The build sandbox shows the
                # store as owned by nobody, which G272 refuses for a Module Host (a deployed
                # store is root's or the user's), so the smoke runs a copy of it instead.
                host=${logosd}/libexec/logos-core/logos-module-host
                test -x "$host"
                mkdir "$TMPDIR/host"
                cp "$host" "$TMPDIR/host/logos-module-host"
                chmod 0755 "$TMPDIR/host/logos-module-host"
                ctl daemon config get --format diag --out init.diag
                sed "s|\"runtime\": {|\"runtime\": {\"module_host\": \"$TMPDIR/host/logos-module-host\", |" \
                  init.diag > host.diag
                grep -q '"module_host"' host.diag
                ctl daemon config set @host.diag
                logosd --session-dir "$s" 2> logosd.err &
                pid=$!
                i=0
                until ctl status > /dev/null 2>&1; do
                  i=$((i + 1))
                  if [ $i -gt 600 ] || ! kill -0 $pid 2> /dev/null; then
                    echo "logosd did not answer"; cat logosd.err; exit 1
                  fi
                  sleep 0.1
                done
                ctl --json status > status.json
                grep -q '"deployment":"production"' status.json
                ctl --text module ls > modules.out
                for i in orchestrator authority logosctl; do
                  grep -q "^$i .* ready" modules.out || { echo "$i is not ready"; cat modules.out; exit 1; }
                done
                ctl daemon stop --wait
                if ! wait $pid; then echo "logosd did not exit 0"; cat logosd.err; exit 1; fi
                grep -q "ready: runtime " logosd.err
                if grep -o '/nix/store/[^ ,:]*' logosd.err | grep -v "^${logosd}/"; then
                  echo "the log names a store path outside logosd"; exit 1
                fi
                ctl trust development on
                ctl daemon config get --format diag --out cfg.diag
                sed '1s/^{/{"test_hooks": {"ctl_command_delay_ms": 1}, /' cfg.diag > hooks.diag
                ctl daemon config set @hooks.diag
                rc=0
                logosd --session-dir "$s" 2> hooks.err || rc=$?
                [ $rc -eq 1 ] || { echo "logosd exited $rc, not 1"; cat hooks.err; exit 1; }
                grep -q "this logosd has no test hooks" hooks.err
                touch $out
              '';

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
            logosModuleHost
            logosd
            logosctl
            logosdSmoke
            android
            ios
            updateNimbleDeps
            nimDerivation
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
          logos-module-host = s.logosModuleHost;
          inherit (s) logosd logosctl;
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
        logosd = {
          type = "app";
          program = lib.getExe bySystem.${system}.logosd;
        };
        logosctl = {
          type = "app";
          program = lib.getExe bySystem.${system}.logosctl;
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
          # The test-hook rule (src/logos_core/base/testhooks.nim; D27 revised 2026-11-13, I89):
          # no deployment output holds the marker, and a probe built with the define does, so
          # the search is not vacuous. Deployment outputs are this system's packages and apps
          # except the toolchain (nim, nph), the Android SDK and the test-suite builds and
          # runners, which are test builds.
          no-test-hooks =
            let
              notDeployed = [
                "nim"
                "nph"
                "android-sdk"
                "android-suites-x86_64"
                "android-suites-arm64"
                "test-android"
                "test-ios"
              ];
              deployed =
                lib.attrValues (removeAttrs self.packages.${system} notDeployed)
                ++ map (a: a.program) (lib.attrValues (removeAttrs self.apps.${system} notDeployed));
            in
            s.nimDerivation {
              name = "no-test-hooks";
              src = s.nimSources;
              buildPhase = ''
                runHook preBuild
                marker=LCN_TEST_HOOKS_BUILD
                for p in ${lib.escapeShellArgs (map toString deployed)}; do
                  if grep -rlaF "$marker" "$p"; then
                    echo "a deployment output holds test hooks: $p"
                    exit 1
                  fi
                done
                nim c --hints:off -d:lcnTestHooks --outdir:build tests/support/hookprobe.nim
                if ! grep -qaF "$marker" build/hookprobe; then
                  echo "the probe built with the define holds no marker"
                  exit 1
                fi
                runHook postBuild
              '';
            };
          logosd-smoke = s.logosdSmoke;
          # No `?` inside a half-built constructor: it leaks on Nim 2.2.14 (I77).
          lint-ctor-try = s.pkgs.runCommand "lint-ctor-try" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 ${./tools/lint/ctortry.py} src tests
            touch $out
          '';
          # No local first written in a branch and written again after it: that write drops
          # the branch's value undestroyed, so unwiped, on Nim 2.2.14 (I92; Nim#26725).
          lint-first-write = s.pkgs.runCommand "lint-first-write" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 ${./tools/lint/firstwrite.py} src tests
            touch $out
          '';
        }
      );

      # Every check in exactly one group, so CI can run each Linux leg as parallel jobs
      # (.github/workflows/ci.yml): one runner took over two hours for all of them on x86_64.
      # A check whose name ends in no known variant goes to `orc-spec`, so a new variant is
      # still built. `nix build .#ciGroups.asan` builds one group locally.
      #
      # `ciShards` splits each group into `ciShardCount group` parts, `<group>-1` to `<group>-N`,
      # heaviest check first, each to the part with the least weight so far (`ciWeights`; ties to
      # the lower part, equal weights by name). Every check is placed exactly once whatever the
      # weights say, and evaluation fails if a group's parts do not hold its checks exactly once.
      # The Linux jobs build shards: on 36f355c (2026-11-14) the x86_64 asan and msan groups passed
      # the 90-minute job limit and tsan took 81 minutes; on 5ddd886 and eed9d58 (2026-11-15) the
      # second x86_64 asan and msan shards of two did; and on b3af640 (2026-11-16) msan's second of
      # three did. Those parts were dealt round-robin by name. On 5887c5a (2026-11-16) x86_64
      # tsan's second shard of two took 81 minutes, asan's second of three 74, and msan's four 55
      # to 68. A shard took about 7 minutes plus its checks' build and test time over the runner's
      # four parallel builds, and the slow shards held the heaviest suites together. asan and msan
      # now have four and five parts, tsan three: on that run's times each comes to about 45 to 55
      # minutes. On dc2e7ef (2026-11-16) they took 25 to 66 minutes, so the weights are now the mean
      # of two runs; orc-spec's checks, `<suite>-orc`, had found no weight. The counts must match
      # the `shard` lists in ci.yml.
      legacyPackages = forAllSystems (
        system:
        let
          checks = self.checks.${system};
          variant =
            name:
            lib.findFirst (v: lib.hasSuffix "-${v}" name) null [
              "asan"
              "tsan"
              "msan"
              "refc"
              "orc-release"
            ];
          groupOf =
            name:
            let
              v = variant name;
            in
            if v == null then "orc-spec" else v;
          groups = lib.groupBy groupOf (builtins.attrNames checks);
          farm =
            label: names:
            bySystem.${system}.pkgs.linkFarm "ci-${label}" (
              map (name: {
                inherit name;
                path = checks.${name};
              }) names
            );
          ciShardCount =
            group:
            if group == "msan" then
              5
            else if group == "asan" then
              4
            else if group == "tsan" then
              3
            else
              2;
          # A suite's weight: its build and test minutes on x86_64 CI, the mean of its asan, tsan
          # and msan checks in runs 43909188165 (5887c5a) and 43942225210 (dc2e7ef, 2026-11-16),
          # for the twelve heaviest suites. Every other check weighs `ciDefaultWeight`, about the
          # mean of the rest (5.6). An orc-spec check `<suite>-orc` weighs as its suite. A suite
          # missing here, or a weight gone stale, only balances the parts worse. To refresh, take
          # each suite's first and last `nix build -L` line in a run's sanitizer jobs.
          ciWeights = {
            test_boundary_invariance = 35;
            test_logosd = 35;
            test_hosted_routes = 27;
            test_wipe_routes = 18;
            test_hosted = 18;
            test_authority = 17;
            test_host = 16;
            test_orchestration = 14;
            test_ctl_module = 13;
            test_routes_ca = 13;
            test_config = 12;
            test_deployment = 12;
          };
          ciDefaultWeight = 6;
          shardOf =
            group: n: names:
            let
              weight =
                name:
                ciWeights.${lib.removeSuffix "-${if group == "orc-spec" then "orc" else group}" name}
                  or ciDefaultWeight;
              heaviestFirst = lib.sort (
                a: b: weight a > weight b || (weight a == weight b && a < b)
              ) names;
              lightest =
                loads:
                lib.foldl' (
                  best: i: if builtins.elemAt loads i < builtins.elemAt loads best then i else best
                ) 0 (lib.range 1 (n - 1));
              place =
                acc: name:
                let
                  k = lightest acc.loads;
                in
                {
                  loads = lib.imap0 (i: l: if i == k then l + weight name else l) acc.loads;
                  parts = lib.imap0 (i: p: if i == k then p ++ [ name ] else p) acc.parts;
                };
              parts =
                (builtins.foldl' place {
                  loads = lib.genList (_: 0) n;
                  parts = lib.genList (_: [ ]) n;
                } heaviestFirst).parts;
            in
            assert lib.sort lib.lessThan (lib.concatLists parts) == lib.sort lib.lessThan names;
            parts;
          shardsOf =
            group: names:
            let
              parts = shardOf group (ciShardCount group) names;
            in
            lib.listToAttrs (
              lib.imap0 (
                i: part:
                let
                  label = "${group}-${toString (i + 1)}";
                in
                lib.nameValuePair label (farm label part)
              ) parts
            );
        in
        {
          ciGroups = lib.mapAttrs farm groups;
          ciShards = lib.concatMapAttrs shardsOf groups;
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
