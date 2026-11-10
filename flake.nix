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
      url = "git+https://github.com/logos-co/logos-lips?ref=draft/logos-core-module-specs&rev=f4f83471bed90139901a4230299a66d1bc0cd9dd";
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
          ];
          testChecks = lib.listToAttrs (
            lib.concatMap (
              file:
              map (
                variant:
                let
                  name = "${lib.removeSuffix ".nim" file}-${variant.suffix}";
                in
                lib.nameValuePair name (nimDerivation {
                  inherit name;
                  src = nimSources;
                  buildPhase = ''
                    runHook preBuild
                    nim c -r ${variant.flags} --outdir:build tests/${file}
                    runHook postBuild
                  '';
                })
              ) testVariants
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
            ];
          };
          specCheck =
            name: command:
            pkgs.runCommand name { nativeBuildInputs = [ spectrace python ]; } ''
              cd ${specSources}
              ${command}
              touch $out
            '';
          specChecks = {
            spec-mirrors = specCheck "spec-mirrors" "spectrace mirror";
            spec-pins = specCheck "spec-pins" "spectrace pins";
            spec-ledger = specCheck "spec-ledger" "spectrace check";
            spec-gate = specCheck "spec-gate" "spectrace gate";
            oracle-selftest = specCheck "oracle-selftest" "python3 oracle/selftest.py && python3 oracle/gen_cddl_vectors.py --check && python3 oracle/gen_hash_vectors.py --check";
          };

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
            updateNimbleDeps
            ;
        };

      bySystem = forAllSystems perSystem;
    in
    {
      packages = forAllSystems (system: {
        inherit (bySystem.${system}) nim nph spectrace;
      });

      apps = forAllSystems (system: {
        update-nimble-deps = {
          type = "app";
          program = lib.getExe bySystem.${system}.updateNimbleDeps;
        };
        spectrace = {
          type = "app";
          program = lib.getExe bySystem.${system}.spectrace;
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
      );

      formatter = forAllSystems (system: bySystem.${system}.nph);
    };
}
