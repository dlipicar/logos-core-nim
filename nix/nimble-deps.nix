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
  lock = builtins.fromJSON (builtins.readFile lockFile);
  packages = lock.packages;
  # [G436] What Nimble 0.26.2 writes, refused here rather than built wrong:
  # - a `nim` entry: locks are made with --useSystemNim, which writes none (lint-packaging refuses it too);
  # - an empty `url`, which a requirement by `file://` writes;
  # - an empty `vcsRevision`, which a failed read of a remote writes, with exit status 0;
  # - task requirements, which this reader would drop.
  emptyField =
    field: lib.filter (n: (packages.${n}.${field} or "") == "") (builtins.attrNames packages);
  locked =
    if packages ? nim then
      throw "nimble.lock has a nim entry, so it was made without --useSystemNim. Lock again with the flag."
    else if emptyField "url" != [ ] then
      throw (
        "nimble.lock has an empty url for: "
        + lib.concatStringsSep ", " (emptyField "url")
        + ". Require it by name or URL, never by file://, and lock again."
      )
    else if emptyField "vcsRevision" != [ ] then
      throw (
        "nimble.lock has an empty vcsRevision for: "
        + lib.concatStringsSep ", " (emptyField "vcsRevision")
        + ". Nimble could not read its remote; lock again once it can."
      )
    else if (lock.tasks or { }) != { } then
      throw "nimble.lock has task requirements, which Nix does not build. Use requires, not taskRequires."
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
