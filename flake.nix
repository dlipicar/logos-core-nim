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
      url = "git+https://github.com/logos-co/logos-lips?ref=draft/logos-core-module-specs&rev=6cac8335af8cea0e5d4e2f9ccb2e584c5b27a7c2";
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
      # [G433] Our packages' versions live in their nimble files, read here as the Nim pin is;
      # lint-packaging refuses a version written in this file.
      versionOf =
        file:
        let
          lines = lib.splitString "\n" (builtins.readFile file);
        in
        lib.head (lib.head (lib.remove null (map (builtins.match "^version = \"([0-9.]+)\".*") lines)));
      coreVersion = versionOf ./logos_core.nimble;
      sdkVersion = versionOf ./sdk/logos_sdk.nimble;

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
              # test_lockcheck checks the helper against the real lock (DECISIONS G436).
              ./nimble.lock
              ./config.nims
              ./.nph.toml
              ./src
              ./sdk
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
              # test_resolver checks the documented resolver maxima are the ones in src (G361).
              ./docs/CONFORMANCE.md
              # The service-manager units for logosd (DAEMON.md §13).
              ./contrib
              # The digest the logosd package compiles in for liblcn_call (G343).
              ./tools/artifact_hash.nim
            ];
          };

          # Each suite by its path from the repository root, where every suite runs.
          testFilesIn =
            dir:
            map (n: "${dir}/${n}") (
              lib.filter (n: lib.hasPrefix "test_" n && lib.hasSuffix ".nim" n) (
                builtins.attrNames (builtins.readDir (./. + "/${dir}"))
              )
            );
          testFiles = testFilesIn "tests" ++ testFilesIn "sdk/tests";
          # Both memory managers (refc modules link this code), and a release
          # build: INTERFACE §4.5 forbids build-mode-dependent bytes.
          baseVariants = [
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
          ];
          # Sanitizers (switches in config.nims) on Linux: macOS has no MemorySanitizer, and
          # nixpkgs' clang 21 sanitizer runtimes do not start on macOS 27, so the Mac runs
          # `nimble test_asan` and `nimble test_tsan` with the Xcode toolchain instead.
          sanitizerVariants = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
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
              # Beside them, test_hosted_routes' run.mixed cases and test_kit_mixed's
              # cases skip themselves under MemorySanitizer on every architecture (DECISIONS
              # G342): their refc module libraries are built without the sanitizer, and an
              # uninstrumented library's writes read as uninitialized.
              skip =
                file:
                pkgs.stdenv.hostPlatform.isAarch64
                && lib.elem (baseNameOf file) [
                  "test_boundary_invariance.nim"
                  "test_deployment.nim"
                  "test_engine.nim"
                  "test_host.nim"
                  "test_host_dylib.nim"
                  "test_hosted.nim"
                  "test_hosted_permissions.nim"
                  "test_hosted_routes.nim"
                  "test_kit_dylib.nim"
                  "test_kit_mixed.nim"
                  "test_lcn_call.nim"
                  "test_logosd.nim"
                  "test_module_host.nim"
                  "test_realizer.nim"
                  "test_routes.nim"
                  "test_storage_fetch.nim"
                  "test_wipe_cli.nim"
                  "test_wipe_routes.nim"
                ];
            }
          ];
          testVariants = baseVariants ++ sanitizerVariants;
          # [DECISIONS G442] Under a sanitizer the suite runs through tools/sanitizer/reports.sh: every
          # report, the suite's own and any child's (a Module Host's included), goes to a file in
          # the check's own directory, and the check fails on any, prints them, and fails if the
          # directory's marker is gone or a canary suite's canary is missing. A base variant's
          # command is the bare `nim c -r`, so its derivation does not change.
          sanitizerReports = ./tools/sanitizer/reports.sh;
          suiteRun =
            variant: file:
            if variant.sanitizer or false then
              "bash ${sanitizerReports} run --suite ${lib.removeSuffix ".nim" (baseNameOf file)} --dir \"$TMPDIR/sanitizer-reports\" -- "
            else
              "";
          testChecks = lib.listToAttrs (
            lib.concatMap (
              file:
              map (
                variant:
                let
                  name = "${lib.removeSuffix ".nim" (baseNameOf file)}-${variant.suffix}";
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
                        ${suiteRun variant file}nim c -r ${variant.flags} --outdir:build ${file}
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
                    // lib.optionalAttrs (baseNameOf file == "test_remote_tls.nim") {
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
              ./sdk/tests
              ./sdk/conformance
              ./oracle
              ./sdk/src/logos_sdk/pins.nim
              ./src/logos_core/pins.nim
              ./sdk/src/logos_sdk/base/nfc_tables.nim
              # spec-deploydoc checks the deployment document against the claims (G309).
              ./docs/DEPLOYMENT.md
            ];
          };
          # `spectrace pending` also reads the code a reading names and the decision rows (DECISIONS I104).
          pendingSources = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./spec
              ./conformance
              ./tests
              ./sdk/tests
              ./sdk/conformance
              ./src
              ./sdk/src
              ./docs/DECISIONS.md
              ./docs/DEPLOYMENT.md
            ];
          };
          specCheckIn =
            sources: name: command:
            pkgs.runCommand name { nativeBuildInputs = [ spectrace python ]; } ''
              cd ${sources}
              # A subshell: under `set -e` a failure before the last step of an
              # `a && b` list would not stop the script, and the check would pass.
              ( ${command} ) || exit 1
              touch $out
            '';
          specCheck = specCheckIn specSources;
          specChecks = {
            spec-mirrors = specCheck "spec-mirrors" "spectrace mirror";
            spec-pins = specCheck "spec-pins" "spectrace pins";
            spec-ledger = specCheck "spec-ledger" "spectrace check";
            spec-owners = specCheck "spec-owners" "spectrace owners --self-test && spectrace owners";
            spec-gate = specCheck "spec-gate" "spectrace gate --closed-tier 1 --closed-tier 2 --closed-tier 3 --closed-tier 4 --closed-tier 4b";
            spec-deploydoc = specCheck "spec-deploydoc" "spectrace deploydoc";
            spec-pending = specCheckIn pendingSources "spec-pending" "spectrace pending --self-test && spectrace pending";
            oracle-selftest = specCheck "oracle-selftest" "python3 oracle/selftest.py && python3 oracle/gen_cddl_vectors.py --check && python3 oracle/gen_hash_vectors.py --check && python3 oracle/gen_cose_vectors.py --check && python3 oracle/gen_nfc_tables.py --check";
          };

          # INTERFACE §2.1-§2.3, §2.5, §5.2 C type headers (types only, D29).
          lcnGen = nimDerivation {
            pname = "lcn-gen";
            version = sdkVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c -d:release --outdir:build/bin sdk/src/lcn_gen.nim
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
            version = coreVersion;
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

          # The key holder (Tier 5 step 5-7a-1; DECISIONS G410; docs/REMOTE.md): logosd's
          # `remote.signing = "key-holder"` program, which loads the Runtime's key itself.
          # `remote.key_holder` names it; logosd's package puts it at
          # ../libexec/logos-core/logos_keyholder. A release build without test hooks (R5, D27).
          logosKeyholder = nimDerivation {
            pname = "logos-keyholder";
            version = coreVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c --mm:orc -d:release --outdir:build/bin src/logos_keyholder.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/logos_keyholder $out/bin/logos_keyholder
            '';
            meta.mainProgram = "logos_keyholder";
          };

          # The remote program (Tier 5 step 5-7a-2; DECISIONS G411; docs/REMOTE.md): logosd's
          # TLS processes, the programs that link BoringSSL's libssl, which logosd does not
          # (G409). logosd starts it from `runtime.remote_program`, by default
          # ../libexec/logos-core/logos_remote. A release build without test hooks or test
          # signing (R5, D27).
          logosRemote = nimDerivation {
            pname = "logos-remote";
            version = coreVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c --mm:orc -d:release --outdir:build/bin src/logos_remote.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/logos_remote $out/bin/logos_remote
            '';
            meta.mainProgram = "logos_remote";
          };

          # PM §3, §4, §4.3, §7.1 package tools (a subset: no fetch or install).
          lcnPkg = nimDerivation {
            pname = "lcn-pkg";
            version = coreVersion;
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

          # The CLI module's library (Tier 5 step N-2b; DECISIONS G343, G340, G341): an orc
          # release library with its own NimMain prefix, no signal handlers and its export
          # list. Its own derivation, so the file logosd's digest is taken of is final.
          sharedLib = pkgs.stdenv.hostPlatform.extensions.sharedLibrary;
          lcnCallLib = nimDerivation {
            pname = "liblcn_call";
            version = daemonVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c --mm:orc -d:release -d:noSignalHandler --app:lib \
                --nimMainPrefix:liblcn_call ${
                  if pkgs.stdenv.hostPlatform.isDarwin then
                    "--passL:-Wl,-exported_symbols_list,src/logos_core/cli/lcn_call_kit.exports"
                  else
                    "--passL:-Wl,--version-script=src/logos_core/cli/lcn_call_kit.map"
                } -o:build/lib/liblcn_call${sharedLib} src/lcn_call.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm444 build/lib/liblcn_call${sharedLib} $out/lib/logos-core/liblcn_call${sharedLib}
            '';
          };

          # The Package Manager module's library (Tier 5 step 5-6a-1; DECISIONS G491, G340,
          # G341): as liblcn_call, and its kit is confined, so it imports hostsignals first
          # (G340, P5). logosd composes it as the reserved instance `package_manager`.
          pmLib = nimDerivation {
            pname = "liblogos_package_manager";
            version = daemonVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c --mm:orc -d:release -d:noSignalHandler --app:lib \
                --import:logos_sdk/base/hostsignals \
                --nimMainPrefix:liblogos_package_manager ${
                  if pkgs.stdenv.hostPlatform.isDarwin then
                    "--passL:-Wl,-exported_symbols_list,src/logos_core/pm/logos_package_manager_kit.exports"
                  else
                    "--passL:-Wl,--version-script=src/logos_core/pm/logos_package_manager_kit.map"
                } -o:build/lib/liblogos_package_manager${sharedLib} src/logos_package_manager.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm444 build/lib/liblogos_package_manager${sharedLib} \
                $out/lib/logos-core/liblogos_package_manager${sharedLib}
            '';
          };

          # logosd and logosctl (Tier 4b step 4b-6; DECISIONS I95; docs/DAEMON.md): orc
          # release builds without test hooks (R5, D27). logosd finds the Module Host, the key
          # holder and the remote program at ../libexec/logos-core and liblcn_call at
          # ../lib/logos-core, where its package puts them. [G343] logosd is built with the BLAKE3-256 of liblcn_call's final
          # store file, and the library is copied after the fixup, so no strip or patchelf
          # changes the bytes the Module Loader checks against that digest. [G491] The same
          # for liblogos_package_manager (`pmArtifactHash`).
          daemonVersion = coreVersion;
          # [DECISIONS G409] logosd's switches, which the flake check `logosd-no-ssl` builds its
          # probe with, so the same BoringSSL objects compile under the same nimcache names.
          # logosd adds only `lcnVersion`, `lcnCallArtifactHash` and `pmArtifactHash`, constants of its own Nim
          # code. The binding reads platform defines, BORINGSSL_USE_ASM and
          # BORINGSSL_ZERO_RECORD_BUFFERS, and neither of these.
          logosdSwitches = "--mm:orc -d:release";
          logosd = nimDerivation {
            pname = "logosd";
            version = daemonVersion;
            src = nimSources;
            buildPhase = ''
              runHook preBuild
              nim c -d:release --outdir:build/bin tools/artifact_hash.nim
              cliHash=$(build/bin/artifact_hash ${lcnCallLib}/lib/logos-core/liblcn_call${sharedLib})
              pmHash=$(build/bin/artifact_hash ${pmLib}/lib/logos-core/liblogos_package_manager${sharedLib})
              nim c ${logosdSwitches} -d:lcnVersion=${daemonVersion} \
                -d:lcnCallArtifactHash=$cliHash -d:pmArtifactHash=$pmHash \
                --outdir:build/bin src/logosd.nim
              runHook postBuild
            '';
            installPhase = ''
              install -Dm755 build/bin/logosd $out/bin/logosd
              install -Dm755 ${lib.getExe logosModuleHost} $out/libexec/logos-core/logos-module-host
              install -Dm755 ${lib.getExe logosKeyholder} $out/libexec/logos-core/logos_keyholder
              install -Dm755 ${lib.getExe logosRemote} $out/libexec/logos-core/logos_remote
            '';
            postFixup = ''
              install -Dm444 ${lcnCallLib}/lib/logos-core/liblcn_call${sharedLib} \
                $out/lib/logos-core/liblcn_call${sharedLib}
              install -Dm444 ${pmLib}/lib/logos-core/liblogos_package_manager${sharedLib} \
                $out/lib/logos-core/liblogos_package_manager${sharedLib}
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
                # [G343] One grant, so `describe` below runs the packaged lcn_call to the end.
                echo '[{"kind": "allow", "subject": {"instances": ["lcn_call"]}, "scopes": [{"kind": "provider-access", "contract": "capability-authority", "actions": ["discover"]}]}]' > cli.diag
                ctl init --policy @cli.diag > init.out
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
                # [G343] The packaged lcn_call, started from its compiled digest by the
                # first CLI command; the build sandbox's store ownership does not matter
                # to an artifact, only its digest does.
                test -f ${logosd}/lib/logos-core/liblcn_call${sharedLib}
                # [G491] The companion Package Manager library, composed only with a
                # `package_manager` section (none here).
                test -f ${logosd}/lib/logos-core/liblogos_package_manager${sharedLib}
                ctl --json describe logos_capability_authority > describe.json \
                  || { echo "describe failed"; cat describe.json logosd.err; exit 1; }
                grep -q '"status":"ok"' describe.json
                grep -q '"module":"logos_capability_authority"' describe.json
                ctl --text module ls > modules.out
                grep -q "^lcn_call .* ready" modules.out || { echo "lcn_call is not ready"; cat modules.out; exit 1; }
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
                  ;
                # Not the host's sanitizers (DECISIONS I46): the NDK's clang has no
                # MemorySanitizer for Android, and links the others' runtimes as shared
                # libraries, which the suites' static check refuses (G124).
                testVariants = baseVariants;
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
            logosKeyholder
            logosRemote
            logosd
            logosdSwitches
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
          logos-keyholder = s.logosKeyholder;
          logos-remote = s.logosRemote;
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
            nph --check src sdk/src sdk/tests tests logos_core.nimble sdk/logos_sdk.nimble config.nims
            touch $out
          '';
          # The test-hook rule (sdk/src/logos_sdk/base/testhooks.nim; D27 revised 2026-11-13, I89):
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
                # [DECISIONS G438] The same for a strict confined kit's marker.
                strict=LCN_KIT_STRICT_DESTROY_BUILD
                for p in ${lib.escapeShellArgs (map toString deployed)}; do
                  if grep -rlaF "$strict" "$p"; then
                    echo "a deployment output is a strict-destroy kit build: $p"
                    exit 1
                  fi
                done
                nim c --hints:off -d:lcnKitStrictDestroy --outdir:build tests/support/strictprobe.nim
                if ! grep -qaF "$strict" build/strictprobe; then
                  echo "the probe built with lcnKitStrictDestroy holds no marker"
                  exit 1
                fi
                runHook postBuild
              '';
            };
          logosd-smoke = s.logosdSmoke;
          # [DECISIONS G409] The shipped logosd holds no libssl code (Fable's check of logosd's
          # link and planning's ruling, 2026-11-22). A probe that imports the BoringSSL binding
          # is built with logosd's switches (`logosdSwitches`); none of the symbols that only
          # libssl's objects in its nimcache define may be in the deployed binary
          # (tests/support/nossl.nim). The probe itself, linked without dead stripping, must
          # fail the check, so the search is not vacuous. The test build's check is in
          # test_logosd.
          logosd-no-ssl = s.nimDerivation {
            name = "logosd-no-ssl";
            src = s.nimSources;
            buildPhase = ''
              runHook preBuild
              nim c --hints:off ${s.logosdSwitches} --nimcache:build/sslprobe \
                -o:build/sslprobe-bin tests/support/sslprobe.nim
              nim c --hints:off -d:release --outdir:build tests/support/nosslcheck.nim
              build/nosslcheck build/sslprobe ${s.logosd}/bin/logosd
              if build/nosslcheck build/sslprobe build/sslprobe-bin; then
                echo "the probe, which links libssl's objects whole, passes the check"
                exit 1
              fi
              runHook postBuild
            '';
          };
          # No `?` inside a half-built constructor: it leaks on Nim 2.2.14 (I77).
          lint-ctor-try = s.pkgs.runCommand "lint-ctor-try" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 ${./tools/lint/ctortry.py} --self-test
            python3 ${./tools/lint/ctortry.py} src sdk/src sdk/tests tests
            touch $out
          '';
          # No local first written in a branch and written again after it: that write drops
          # the branch's value undestroyed, so unwiped, on Nim 2.2.14 (I92; Nim#26725).
          lint-first-write = s.pkgs.runCommand "lint-first-write" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 ${./tools/lint/firstwrite.py} --self-test
            python3 ${./tools/lint/firstwrite.py} src sdk/src sdk/tests tests
            touch $out
          '';
          # [DECISIONS I147] One `importc` of each function our C sources define: a second copy
          # of its prototype falls behind when its parameters change, and still compiles.
          lint-cimports = s.pkgs.runCommand "lint-cimports" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 ${./tools/lint/cimports.py} --self-test
            python3 ${./tools/lint/cimports.py} src sdk/src sdk/tests tests
            touch $out
          '';
          # [DECISIONS G433-G436] The SDK's and core's Nimble packages: install lists, requirements,
          # the lock against the SDK's ranges, the Nimble 0.26 guard, and no hand-typed URL of our
          # repositories (tools/lint/packaging.py). The whole tree but build outputs, for that last
          # rule.
          lint-packaging =
            let
              tree = lib.cleanSourceWith {
                src = ./.;
                filter =
                  path: _:
                  let
                    name = baseNameOf path;
                  in
                  !(lib.elem name [ ".git" "build" "nimbledeps" "nimcache" ] || lib.hasPrefix "result" name);
              };
            in
            s.pkgs.runCommand "lint-packaging" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
              cd ${tree}
              python3 ${./tools/lint/packaging.py} --self-test
              python3 ${./tools/lint/packaging.py}
              touch $out
            '';
          # [DECISIONS G464-G467] Every C-callable procedure of the SDK, core and the test kit
          # modules registers its thread first, or carries its exemption and reason; no
          # `Entered` value is made without `entered`. The command module repositories run.
          lint-callbacks = s.pkgs.runCommand "lint-callbacks" { nativeBuildInputs = [ s.lcnGen ]; } ''
            cd ${s.nimSources}
            lcn-gen lint-callbacks --self-test
            lcn-gen lint-callbacks sdk/src src tests/kit
            touch $out
          '';
          # [DECISIONS G442] Every environment a test gives a Module Host names the sanitizer
          # variables (tests/support/sanitizerenv.nim), so a sanitizer check sees its hosts' reports.
          lint-sanitizer-env = s.pkgs.runCommand "lint-sanitizer-env" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 -I ${./tools/lint/sanitizerenv.py} --self-test
            python3 -I ${./tools/lint/sanitizerenv.py} tests sdk/tests
            touch $out
          '';
          # [DECISIONS G442] The sanitizer checks' report script over made-up directories and stub
          # suites, without a sanitizer: the causes, the printing, the marker, the canaries.
          sanitizer-reports = s.pkgs.runCommand "sanitizer-reports" { } ''
            bash ${./tools/sanitizer/reports.sh} self-test
            touch $out
          '';
          # The import direction between the SDK, core, the daemon and the CLI.
          lint-layers = s.pkgs.runCommand "lint-layers" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
            cd ${s.nimSources}
            python3 ${./tools/lint/layers.py} --self-test
            python3 ${./tools/lint/layers.py} --config ${./tools/lint/layers.toml}
            touch $out
          '';
          # No storage library among the dependencies or in the Package Manager's link inputs
          # (G406): it reaches Logos Storage only through lcn.storage_fetch. nostorage.py
          # reads layers.py beside it, so it runs from the copied tree.
          lint-nostorage =
            let
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./logos_core.nimble
                  ./nimble.lock
                  ./nix/nimble-deps.json
                  ./flake.nix
                  ./flake.lock
                  ./config.nims
                  ./src
                  ./sdk
                  ./tests
                  ./tools/lint
                ];
              };
            in
            s.pkgs.runCommand "lint-nostorage" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
              cd ${src}
              python3 -I tools/lint/nostorage.py --self-test
              python3 -I tools/lint/nostorage.py --config tools/lint/nostorage.toml
              touch $out
            '';
          # The suites a change can reach (tools/affected_suites.py, wave 2's merge rule 1): its
          # planted cases, and on this tree the suites the rule names for genfixtures.nim,
          # DAEMON.md and commitment/choice.nim.
          affected-suites =
            let
              tool = lib.fileset.toSource {
                root = ./tools;
                fileset = lib.fileset.unions [
                  ./tools/affected_suites.py
                  ./tools/lint/layers.py
                ];
              };
            in
            s.pkgs.runCommand "affected-suites" { nativeBuildInputs = [ s.pkgs.python3 ]; } ''
              cd ${s.nimSources}
              python3 -I ${tool}/affected_suites.py --self-test --root .
              touch $out
            '';
        }
        // lib.optionalAttrs s.pkgs.stdenv.hostPlatform.isLinux (
          let
            # [DECISIONS G341] The test kit libraries built with the switches the node's libraries
            # build with (`LCN_KIT_SWITCHES`, `testing/kitbuild`), on this toolchain. Under each
            # set, refc libraries in a refc host (`test_kit_dylib`, the confined sensor included)
            # and in orc Runtimes and Module Hosts (`run.mixed`, and `test_kit_mixed`'s confined
            # ledger), the node's pairing. [IMPL] One check per set, so CI can build them in
            # parallel: as one check they took 57 minutes on x86_64 (run 44888184613), 35.5 for
            # storage's set and 21.7 for delivery's.
            kitSuites = ''
              nim c -r --mm:refc --outdir:build sdk/tests/test_kit_dylib.nim
              nim c -r --mm:orc --outdir:build tests/test_hosted_routes.nim 'run.mixed:*::*'
              nim c -r --mm:orc --outdir:build tests/test_kit_mixed.nim
            '';
            # logos-storage-nim 4fe02344's switches (`config.nims`; `-d:chronosHandleException`
            # changes how `async` procs compile).
            storageSwitches = "--threads:on --tlsEmulation:off --opt:speed --excessiveStackTrace:on -d:metrics -d:nimTypeNames --styleCheck:usages --styleCheck:error --fieldChecks:on --warningAsError:ProveField:on --legacy:procParamTypeBackendAliases -d:withoutPCRE -d:nimOldCaseObjects -d:chronosHandleException -d:release";
            # logos-delivery d20ee361's library set (`config.nims`, `library/config.nims`).
            deliverySwitches = "--threads:on --deepcopy:on -d:nimOldCaseObjects -d:nimTypeNames -d:metrics";
            kitToolchains =
              set: switches:
              s.nimDerivation {
                name = "kit-toolchains-${set}";
                src = s.nimSources;
                buildPhase = ''
                  runHook preBuild
                  export LCN_KIT_SWITCHES=${lib.escapeShellArg switches}
                  echo "kit-toolchains-${set}: $LCN_KIT_SWITCHES"
                  ${kitSuites}
                  runHook postBuild
                '';
              };
            # [DECISIONS G439] The same suites with the kit libraries built against a library's own
            # chronos, and the stew, bearssl or httputils it locks at another revision than core's:
            # the commits W2-P fetched under the owner's D-4 (tier5-plans/stepW2-P-downloads.md),
            # from logos-storage-nim 4fe02344's and logos-delivery d20ee361's locks. `kept` is what
            # the library locks at core's own revision; evaluation fails when core's lock moves it,
            # since the variant would then need a fetch for it.
            kitSource =
              repo: pkg: rev: hash:
              s.pkgs.fetchFromGitHub {
                owner = "status-im";
                inherit repo rev hash;
                # The revision in the store path, so the kits' generated C names it.
                name = "${pkg}-${builtins.substring 0 8 rev}";
              };
            kitVariants = [
              {
                set = "storage";
                rev = "2d81a762";
                switches = storageSwitches;
                swapped = {
                  chronos = kitSource "nim-chronos" "chronos" "2d81a7625d74269581ba24c8bc40b69fccf27d47" "sha256-Lg125xjVtfhtnSDRvrn2QRSOnqoA58MYNcZv0TjPuK8=";
                  stew = kitSource "nim-stew" "stew" "85c6e3131f44bee0f4b9884754599be0d95aefb7" "sha256-g6zG0VEUwukTHXD6vyWgJtp4WwWY3z6akoDkGu2tk+g=";
                  bearssl = kitSource "nim-bearssl" "bearssl" "38a5622be728fb083f6fe55c124502995b2f4e3d" "sha256-sB5YN158rDkcOaSgpeVT5Rly2etp1gP+/bMSZG4xZl0=";
                };
                kept.httputils = "7d771ca337bd3bf563f6834569d2a06085ac21f1";
              }
              {
                set = "delivery";
                rev = "0de7b335";
                switches = deliverySwitches;
                swapped = {
                  chronos = kitSource "nim-chronos" "chronos" "0de7b335d0ad5557ad5ba71a4b7662f7b201750e" "sha256-FVQ1gf6/pRr7A06yL37ru7YRDUWDToaeV/gQhwKtSrw=";
                  stew = kitSource "nim-stew" "stew" "6a930214323f48d879015a1d2d68db6ace3446fb" "sha256-viiUZTlz3PNPgxccu1iIfBpwwEYmhEQ9iU7DajS7z6A=";
                  httputils = kitSource "nim-http-utils" "httputils" "97eafdb8852c52beeedcf49e1c8d16e4b559d331" "sha256-gDc60IW7/DaEGgO72Mpmv+X/utZ3reyr9Xw5UQKaZCU=";
                };
                kept.bearssl = "b6c9a38964a574f6bc51f69efaf8fb2fedea905e";
              }
            ];
            lockedRevision = pkg: (lib.importJSON ./nimble.lock).packages.${pkg}.vcsRevision;
            # A `--path` in `LCN_KIT_SWITCHES` loses to `nimble.paths`, so the swap is the define
            # `lcnKitVariant`, which only kit compiles get (through `LCN_KIT_SWITCHES`), read by this
            # check's own copy of `config.nims`: the repository's never names it
            # (`kit-toolchains-isolated`). The copy's paths file replaces the swapped packages'
            # entries and adds none in front of them, so no module of core's copy can fill a gap in
            # the library's (Fable, fable-checks/stepW2-P-plan.md §8). Asserted (Fable,
            # fable-checks/stepN-1e-plan.md §8): a host compile of each suite has the same whole
            # configuration under this `config.nims` as under the repository's, without the define;
            # each kit build's own record (`-d:nimBetterRun`: every file it read) names the
            # variant's chronos and no file of a swapped package of core's; the kits' generated C
            # names the variant's chronos and never core's.
            kitToolchainsVariant =
              v:
              let
                name = "kit-toolchains-${v.set}-${v.rev}";
                moved = lib.filterAttrs (pkg: rev: lockedRevision pkg != rev) v.kept;
                hostSuites = [
                  "--mm:refc sdk/tests/test_kit_dylib.nim"
                  "--mm:orc tests/test_hosted_routes.nim"
                  "--mm:orc tests/test_kit_mixed.nim"
                ];
              in
              assert lib.assertMsg (moved == { })
                "${name}: core's lock moved ${lib.concatStringsSep ", " (builtins.attrNames moved)}, which ${v.set} locks at core's old revision: the variant needs a fetch for it";
              s.nimDerivation {
                inherit name;
                src = s.nimSources;
                buildPhase = ''
                  runHook preBuild
                  fail() { echo "${name}: $*" >&2; exit 1; }
                  # The variant's paths: each swapped package's entry replaced, exactly once.
                  cp nimble.paths nimble-kit-variant.paths
                  ${lib.concatStrings (
                    lib.mapAttrsToList (pkg: src: ''
                      n=$(grep -c "^--path:\".*/pkgs2/${pkg}-[^\"]*\"$" nimble-kit-variant.paths || true)
                      [ "$n" = 1 ] || fail "nimble.paths has $n entries for ${pkg}"
                      sed -i "s#^--path:\".*/pkgs2/${pkg}-[^\"]*\"\$#--path:\"${src}\"#" nimble-kit-variant.paths
                    '') v.swapped
                  )}
                  # The define's branch, in this copy of config.nims only.
                  block='when withDir(thisDir(), system.fileExists("nimble.paths")):'
                  [ "$(grep -cxF "$block" config.nims)" = 1 ] || fail "config.nims's Nimble block changed"
                  cp config.nims config.nims.orig
                  sed -i "s/^when withDir(/when defined(lcnKitVariant):\n  include \"nimble-kit-variant.paths\"\nelif withDir(/" config.nims
                  cp config.nims config.nims.variant
                  grep -qx '  include "nimble-kit-variant.paths"' config.nims || fail "config.nims not patched"
                  # A host compile of each suite: the same configuration under either config.nims.
                  ${lib.concatMapStrings (h: ''
                    nim dump --hints:off ${h} > host.dump 2>&1 || fail "nim dump ${h}: $(cat host.dump)"
                    ! grep -qx lcnKitVariant host.dump || fail "the host of ${h} has lcnKitVariant"
                    cp config.nims.orig config.nims
                    nim dump --hints:off ${h} > host.orig.dump 2>&1 || fail "nim dump ${h}: $(cat host.orig.dump)"
                    cp config.nims.variant config.nims
                    cmp host.dump host.orig.dump || fail "the variant changed the host configuration of ${h}"
                  '') hostSuites}
                  export LCN_KIT_SWITCHES=${lib.escapeShellArg "${v.switches} -d:lcnKitVariant -d:nimBetterRun"}
                  echo "${name}: $LCN_KIT_SWITCHES"
                  ${kitSuites}
                  # What each kit build read.
                  records=$(ls build/kit-dylib/*/nimcache-*/*.json) || fail "no kit build record"
                  ! grep -l '"depfiles": \[\]' $records || fail "a kit build recorded no files"
                  grep -l "${v.swapped.chronos}/" $records > /dev/null || fail "no kit read ${v.swapped.chronos}"
                  ${lib.concatStrings (
                    lib.mapAttrsToList (pkg: src: ''
                      ! grep -l "/pkgs2/${pkg}-" $records || fail "a kit read core's ${pkg}"
                    '') v.swapped
                  )}
                  # The kits' generated C names the variant's chronos and never core's.
                  grep -rqs --include='*.c' "${v.swapped.chronos}/" build/kit-dylib || fail "no kit's C names ${v.swapped.chronos}"
                  ! grep -rls --include='*.c' "/pkgs2/chronos-" build/kit-dylib || fail "a kit's C names core's chronos"
                  runHook postBuild
                '';
              };
            kitChecksFor =
              variants:
              {
                kit-toolchains-storage = kitToolchains "storage" storageSwitches;
                kit-toolchains-delivery = kitToolchains "delivery" deliverySwitches;
              }
              // lib.listToAttrs (
                map (v: lib.nameValuePair "kit-toolchains-${v.set}-${v.rev}" (kitToolchainsVariant v)) variants
              );
            kitChecks = kitChecksFor kitVariants;
          in
          kitChecks
          // {
            # [DECISIONS G439] Only the variant checks see the variant. The other kit checks'
            # derivations are those made without it (compared in this one check, so evaluating any
            # other does not make them twice: a guard against later wiring), and no source every
            # other check builds from names the define.
            kit-toolchains-isolated =
              let
                bare = kitChecksFor [ ];
              in
              assert lib.assertMsg (lib.all (n: kitChecks.${n}.drvPath == bare.${n}.drvPath) (
                builtins.attrNames bare
              )) "kit-toolchains-isolated: a kit check's derivation changes with the chronos variants";
              s.pkgs.runCommand "kit-toolchains-isolated" { } ''
                if grep -rl --include='*.nim' --include='*.nims' --include='*.nimble' --include='*.cfg' \
                  --include='*.paths' lcnKitVariant ${s.nimSources}; then
                  echo "kit-toolchains-isolated: a source names lcnKitVariant" >&2
                  exit 1
                fi
                touch $out
              '';
          }
        )
      );

      # Every check in exactly one group, so CI can run each leg as parallel jobs
      # (.github/workflows/ci.yml): one runner took over two hours for all of them on x86_64.
      # A check whose name ends in no known variant goes to `orc-spec`, so a new variant is
      # still built. `nix build .#ciGroups.asan` builds one group locally.
      #
      # [IMPL] `ciShards` splits each group into `ciShardCount group` parts, `<group>-1` to
      # `<group>-N`: heaviest check first, each to the part with the least weight so far (ties to
      # the lower part, equal weights by name). On Linux a part whose heaviest check weighs at least
      # `ciHeadMinutes` has it as its head (`ciShardHeads.<label>`) and the rest as its tail
      # (`ciShardTails.<label>`); CI builds the head on one build slot from the job's start and the
      # tail beside it on the runner's other three. Nix starts a build's checks in no order of
      # weight, and every job first spends about 8 minutes building Nim, so a shard took about as
      # long as its heaviest check's start plus its length: on 0a459c9 (2026-11-21, run 44888184613)
      # the x86_64 asan and msan shards that held test_lcn_call (80 and 73 minutes) and orc-spec's
      # with kit-toolchains (57 minutes, now one check per switch set) passed the 90-minute limit,
      # and the slowest tsan shard took 83. A simulation of that run's weights with random start
      # orders put each group's slowest shard, 9 times in 10, at 59 to 69 minutes with these counts
      # and heads, asan's at 87 and msan's at 80 while test_lcn_call alone takes as long. Every
      # check is placed exactly once whatever the weights say: evaluation fails if a group's heads
      # and tails do not hold its checks exactly once, or if a check heads two shards. The counts
      # must match the `shard` lists in ci.yml. macOS builds refc and orc-release whole and orc-spec
      # as two parts, without heads (its runners have three cores, and the weights are x86_64 Linux
      # times).
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
          isLinux = bySystem.${system}.pkgs.stdenv.hostPlatform.isLinux;
          ciShardCount =
            group:
            if isLinux then
              {
                orc-spec = 4;
                refc = 3;
                orc-release = 2;
                asan = 4;
                tsan = 4;
                msan = 5;
              }
              .${group} or 2
            else if group == "orc-spec" then
              2
            else
              1;
          ciHeadMinutes = if isLinux then 25 else null;
          # [IMPL] A check's weight: its minutes on x86_64 Linux CI, from its first to its last
          # `nix build -L` line in the job that built it (nix/ci-weights.json, which
          # tools/ci_weights.py writes from a run's job logs; see its header for refreshing it). A
          # suite costs very differently per group (test_lcn_call: over 80 minutes under asan, 15
          # under orc-release on 0a459c9), so each check has its own. A check the file lacks weighs
          # its group's mean there, and 6 minutes without one or without the file: a weight missing
          # or gone stale only balances the parts worse, and never fails evaluation.
          ciWeights =
            if builtins.pathExists ./nix/ci-weights.json then lib.importJSON ./nix/ci-weights.json else { };
          weight = name: ciWeights.minutes.${name} or ciWeights.groupMeans.${groupOf name} or 6;
          shardOf =
            n: names:
            let
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
              # A part's head is its first check, the heaviest, when it weighs `ciHeadMinutes`.
              split =
                part:
                let
                  first = builtins.head part;
                  headed = part != [ ] && ciHeadMinutes != null && weight first >= ciHeadMinutes;
                in
                {
                  head = if headed then first else null;
                  tail = if headed then builtins.tail part else part;
                };
              shards = map split parts;
              members = s: lib.optional (s.head != null) s.head ++ s.tail;
            in
            assert lib.sort lib.lessThan (lib.concatMap members shards) == lib.sort lib.lessThan names;
            shards;
          # Each shard's head and tail, by label `<group>-<i>`. Evaluating any one evaluates its
          # group's parts with the assertion above, and every head with the one below.
          layout =
            let
              byLabel = lib.concatMapAttrs (
                group: names:
                lib.listToAttrs (
                  lib.imap0 (i: shard: lib.nameValuePair "${group}-${toString (i + 1)}" shard) (
                    shardOf (ciShardCount group) names
                  )
                )
              ) groups;
              heads = lib.filter (h: h != null) (lib.mapAttrsToList (_: s: s.head) byLabel);
            in
            assert lib.length (lib.unique heads) == lib.length heads;
            byLabel;
          sum = names: lib.foldl' (total: name: total + weight name) 0 names;
        in
        {
          ciGroups = lib.mapAttrs farm groups;
          ciShards = lib.mapAttrs (
            label: s: farm label (lib.optional (s.head != null) s.head ++ s.tail)
          ) layout;
          ciShardHeads = lib.mapAttrs (_: s: checks.${s.head}) (lib.filterAttrs (_: s: s.head != null) layout);
          ciShardTails = lib.mapAttrs (label: s: farm "${label}-tail" s.tail) layout;
          # The same parts as data, with their weights: `nix eval --json
          # <flake>#legacyPackages.x86_64-linux.ciLayout` shows how a change spreads the checks.
          # `head` is "" for a part without one; CI reads it to choose how to build the part.
          ciLayout = lib.mapAttrs (_: s: rec {
            head = if s.head == null then "" else s.head;
            headMinutes = if s.head == null then 0 else weight s.head;
            tailMinutes = sum s.tail;
            minutes = headMinutes + tailMinutes;
            checks = lib.optional (s.head != null) s.head ++ s.tail;
          }) layout;
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
