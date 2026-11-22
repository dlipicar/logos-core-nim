# Nimble 0.26.2, built from the copy the Nim tree ships at `nim/dist/nimble`, so it costs no download
# (DECISIONS G436). Its dependencies are vendored there. nixpkgs' release-25.11 has 0.20.1, whose
# `nimble lock` over an existing lock empties the package list (I35), and which crashes on macOS
# without `--useSystemNim`.
{
  stdenv,
  nim,
  nim-unwrapped-2_2,
}:
stdenv.mkDerivation rec {
  pname = "nimble";
  version = "0.26.2";
  src = "${nim-unwrapped-2_2}/nim/dist/nimble";
  nativeBuildInputs = [ nim ];
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    nim c -d:release --hints:off --nimcache:$TMPDIR/nimcache -o:nimble src/nimble.nim
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 nimble $out/bin/nimble
    runHook postInstall
  '';
  # The source is whatever Nim's tree carries: a Nim update that brings another Nimble fails here, not
  # later in a lock.
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/nimble --version | grep -q "^nimble v${version} "
  '';
  meta.mainProgram = "nimble";
}
