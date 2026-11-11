# Android (DECISIONS I46, G124): the SDK pinned from nixpkgs' androidenv, every
# suite cross-compiled with its NDK, and `test-android`, which boots an x86_64
# emulator and runs them. aarch64 suites are built and checked, not run.
#
# Accepting the Android SDK license is the owner's answer (I46); it lives only in
# the package set below, which nothing outside this file uses.
{
  lib,
  pkgs,
  nixpkgs,
  system,
  nimDerivation,
  nimSources,
  testFiles,
  testVariants,
  boringsslSrc,
}:
let
  androidPkgs = import nixpkgs {
    inherit system;
    config = {
      android_sdk.accept_license = true;
      # androidenv's packages are unfree; this set builds nothing else.
      allowUnfree = true;
    };
  };

  # Explicit versions from the pinned nixpkgs (its "latest", written out).
  platformVersion = "35";
  systemImageType = "default"; # AOSP: `adb root` works, no Google services
  sdk = androidPkgs.androidenv.composeAndroidPackages {
    cmdLineToolsVersion = "19.0";
    platformToolsVersion = "36.0.0";
    buildToolsVersions = [ "36.1.0" ];
    platformVersions = [ platformVersion ];
    includeEmulator = true;
    emulatorVersion = "36.3.10";
    includeSystemImages = true;
    systemImageTypes = [ systemImageType ];
    abiVersions = [ "x86_64" ];
    includeNDK = true;
    ndkVersions = [ "29.0.14206865" ];
    includeCmake = false;
  };

  # [IMPL] The oldest Android the binaries target: 10 (API 29).
  minApi = "29";
  ndkBin = "${sdk.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin";

  abis = {
    x86_64 = {
      cpu = "amd64";
      target = "x86_64-linux-android${minApi}";
      machine = "Advanced Micro Devices X86-64";
    };
    arm64-v8a = {
      cpu = "arm64";
      target = "aarch64-linux-android${minApi}";
      machine = "AArch64";
    };
  };

  # Every suite, under every host variant, for one ABI. nixpkgs' Nim takes the C
  # and C++ compilers from $CC and $CXX and links with $CC; the NDK's clang finds
  # its own sysroot.
  suites =
    abi:
    let
      a = abis.${abi};
      flags = lib.concatStringsSep " " [
        "--os:android"
        "--cpu:${a.cpu}"
        "--cc:clang"
        "--passC:--target=${a.target}"
        "--passL:--target=${a.target}"
      ];
    in
    nimDerivation {
      name = "logos-core-nim-android-suites-${abi}";
      src = nimSources;
      buildPhase = ''
        runHook preBuild
        export CC=${ndkBin}/clang CXX=${ndkBin}/clang++
        mkdir -p build/bin
      ''
      + lib.concatMapStrings (
        file:
        lib.concatMapStrings (variant: ''
          nim c ${variant.flags} ${flags} --hints:off \
            -o:build/bin/${lib.removeSuffix ".nim" file}-${variant.suffix} tests/${file}
        '') testVariants
      ) testFiles
      + ''
        runHook postBuild
      '';
      # The static check (G124): each binary is a PIE for this ABI and needs only
      # libraries every Android system has; libc++ is linked in (I46).
      installPhase = ''
        runHook preInstall
        for b in build/bin/*; do
          ${ndkBin}/llvm-readelf -h "$b" | grep -q 'Machine: *${a.machine}' \
            || { echo "$b: not ${abi}"; exit 1; }
          ${ndkBin}/llvm-readelf -h "$b" | grep -q 'Type: *DYN' \
            || { echo "$b: not a PIE"; exit 1; }
          extra=$(${ndkBin}/llvm-readelf -d "$b" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' \
            | grep -vxE 'lib(c|m|dl|log)\.so' || true)
          [ -z "$extra" ] || { echo "$b needs $extra"; exit 1; }
        done
        install -Dm755 -t $out/bin build/bin/*
        runHook postInstall
      '';
      # The host's strip and patchelf have no business with Android binaries.
      dontFixup = true;
    };

  # What the suites read at run time, laid out as on the host: the repository
  # (they run from its root) and the two vector files test_ed25519 reads from
  # nim-boringssl (through LCN_BORINGSSL_DIR).
  data = pkgs.runCommand "logos-core-nim-android-data" { } ''
    mkdir -p $out
    cp -r ${nimSources} $out/repo
    for f in crypto/curve25519/ed25519_tests.txt \
             third_party/wycheproof_testvectors/ed25519_test.txt; do
      install -Dm444 ${boringsslSrc}/boringssl/$f $out/boringssl/boringssl/$f
    done
  '';

  x86_64 = suites "x86_64";
  arm64 = suites "arm64-v8a";

  testAndroid = pkgs.writeShellApplication {
    name = "test-android";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      # Built alongside, so a run also proves the aarch64 suites build and pass
      # their static check: ${arm64}
      sdk=${sdk.androidsdk}
      suites=${x86_64}/bin
      data=${data}
      systemImage="system-images;android-${platformVersion};${systemImageType};x86_64"
      ${builtins.readFile ./test-android.sh}
    '';
  };
in
{
  inherit sdk testAndroid;
  suites-x86_64 = x86_64;
  suites-arm64 = arm64;
}
