# A derivation that builds with the locked Nim dependencies laid out exactly
# as `nimble setup -l` would: copies under nimbledeps/pkgs2/, listed in
# nimble.paths, which config.nims includes.
{
  lib,
  stdenv,
  nim,
  deps,
}:
args@{
  nativeBuildInputs ? [ ],
  ...
}:
stdenv.mkDerivation (
  args
  // {
    nativeBuildInputs = [ nim ] ++ nativeBuildInputs;

    configurePhase = ''
      runHook preConfigure
      export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR/cache
      mkdir -p nimbledeps/pkgs2
      echo '--noNimblePath' > nimble.paths
    ''
    + lib.concatMapStrings (dep: ''
      cp -r ${dep.src} nimbledeps/pkgs2/${dep.dirName}
      srcDir=$(sed -nE 's/^[[:space:]]*srcDir[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' \
        nimbledeps/pkgs2/${dep.dirName}/*.nimble | head -1)
      echo "--path:\"$PWD/nimbledeps/pkgs2/${dep.dirName}''${srcDir:+/$srcDir}\"" >> nimble.paths
    '') (lib.attrValues deps)
    + ''
      chmod -R u+w nimbledeps
      runHook postConfigure
    '';

    installPhase = args.installPhase or "touch $out";
  }
)
