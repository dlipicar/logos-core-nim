# The Nim dependencies for Nix builds: nimble.lock decides every package and
# revision; nimble-deps.json only adds the content hash Nix needs to fetch each
# one as a fixed-output derivation. A mismatch between the two fails evaluation.
{
  lib,
  fetchgit,
  lockFile,
  hashesFile,
}:
let
  # [G433] Locks are made with --useSystemNim, which writes no `nim` entry: one means a lock made
  # without the flag. lint-packaging refuses it too.
  packages = (builtins.fromJSON (builtins.readFile lockFile)).packages;
  locked =
    if packages ? nim then
      throw "nimble.lock has a nim entry, so it was made without --useSystemNim. Lock again with the flag."
    else
      packages;
  pinned = builtins.fromJSON (builtins.readFile hashesFile);

  matches =
    name: pkg:
    pkg.downloadMethod == "git"
    && pinned ? ${name}
    && pinned.${name}.url == pkg.url
    && pinned.${name}.rev == pkg.vcsRevision;

  problems =
    lib.filter (n: !(matches n locked.${n})) (builtins.attrNames locked)
    ++ lib.filter (n: !(locked ? ${n})) (builtins.attrNames pinned);
in
if problems != [ ] then
  throw (
    "nix/nimble-deps.json does not match nimble.lock for: "
    + lib.concatStringsSep ", " problems
    + ". Run `nix run .#update-nimble-deps`."
  )
else
  lib.mapAttrs (name: pkg: {
    inherit name;
    inherit (pkg) version;
    dirName = "${name}-${pkg.version}";
    src = fetchgit {
      inherit (pinned.${name}) url rev hash;
      fetchSubmodules = true;
    };
  }) locked
