# iOS (DECISIONS I47): `test-ios` cross-compiles every suite with the host's
# Xcode for the arm64 iOS simulator, runs them on a simulator it creates and
# deletes, and builds them once for devices as a static check. Xcode is the one
# input Nix does not pin (D31), so the build happens when the app runs, not in a
# derivation.
{
  lib,
  pkgs,
  nim,
  nimSources,
  testVariants,
  deps,
}:
{
  testIos = pkgs.writeShellApplication {
    name = "test-ios";
    runtimeInputs = [
      nim
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.jq
    ];
    text = ''
      sources=${nimSources}
      # The locked dependencies, one "dirName storePath" per line.
      deps=${lib.escapeShellArg (lib.concatMapStringsSep "\n" (d: "${d.dirName} ${d.src}") (lib.attrValues deps))}
      # The host variants, one "suffix flags" per line.
      variants=${lib.escapeShellArg (lib.concatMapStringsSep "\n" (v: "${v.suffix} ${v.flags}") testVariants)}
      ${builtins.readFile ./test-ios.sh}
    '';
  };
}
