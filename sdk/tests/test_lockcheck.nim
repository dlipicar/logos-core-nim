## logos_sdk/testing/lockcheck: the installs `nimble.paths` names against `nimble.lock`'s checksums
## (DECISIONS G436). Nimble 0.26.2 checks none of them itself (draft #191).

import std/[json, os, strutils]
import unittest2
import logos_sdk/testing/lockcheck

const
  shaA = repeat('a', 40)
  shaB = repeat('b', 40)
  shaC = repeat('c', 40)

proc lockOf(entries: openArray[(string, string, string)]): string =
  ## A lock in Nimble's form from (name, version, sha1) triples.
  var packages = newJObject()
  for (name, version, sha1) in entries:
    packages[name] = %*{
      "version": version,
      "vcsRevision": repeat('0', 40),
      "url": "https://example.invalid/" & name,
      "downloadMethod": "git",
      "dependencies": [],
      "checksums": {"sha1": sha1},
    }
  $(%*{"version": 2, "packages": packages, "tasks": {}})

proc pathsOf(dirs: openArray[string]): string =
  ## A `nimble.paths` as Nimble writes it: each directory a Nim string literal.
  result = "--noNimblePath\n"
  for dir in dirs:
    result.add "--path:" & escape(dir) & "\n"

let goodLock = lockOf([("results", "0.5.1", shaA), ("chronos", "4.4.1", shaB)])

suite "testing.lockcheck: installs against nimble.lock (DECISIONS G436) [IMPL]":
  test "[IMPL-DECISION G436] installs whose checksums are the lock's pass, in POSIX and Windows paths":
    check lockMismatches(
      goodLock,
      pathsOf(
        [
          "/r/nimbledeps/pkgs2/results-0.5.1-" & shaA,
          "/r/nimbledeps/pkgs2/chronos-4.4.1-" & shaB & "/src",
          "/r/src",
        ]
      ),
      ownDir = "/r/src",
    ).len == 0
    let windows = pathsOf(
      [
        "C:\\r\\nimbledeps\\pkgs2\\results-0.5.1-" & shaA,
        "C:\\r\\nimbledeps\\pkgs2\\chronos-4.4.1-" & shaB,
        "C:\\r\\src",
      ]
    )
    check "\\\\" in windows
    check nimblePaths(windows)[0] == "C:\\r\\nimbledeps\\pkgs2\\results-0.5.1-" & shaA
    check lockMismatches(goodLock, windows, ownDir = "C:\\r\\src").len == 0

  test "[IMPL-DECISION G436] an install whose checksum is not the lock's is reported, with the setup hint":
    let found = lockMismatches(
      goodLock,
      pathsOf(["/p/pkgs2/results-0.5.1-" & shaC, "/p/pkgs2/chronos-4.4.1-" & shaB]),
    )
    checkpoint $found
    check found.len == 1
    check found[0].startsWith("results: ")
    check shaA in found[0] and shaC in found[0] and setupHint in found[0]

  test "[IMPL-DECISION G436] a lock entry with no SHA-1 checksum is reported":
    let lock = lockOf([("results", "0.5.1", ""), ("chronos", "4.4.1", "38d45a83")])
    let found = lockMismatches(
      lock,
      pathsOf(["/p/pkgs2/results-0.5.1-" & shaA, "/p/pkgs2/chronos-4.4.1-" & shaB]),
    )
    checkpoint $found
    check found.len == 2
    check found[0].startsWith("results: nimble.lock records no SHA-1 checksum")
    check found[1].startsWith("chronos: nimble.lock records no SHA-1 checksum")

  test "[IMPL-DECISION G436] a locked package with no install is reported, unless a listed develop link holds it":
    let paths = pathsOf(["/p/pkgs2/results-0.5.1-" & shaA])
    let found = lockMismatches(goodLock, paths)
    check found.len == 1
    check found[0].startsWith("chronos: ") and setupHint in found[0]
    let linkedPaths = pathsOf(["/p/pkgs2/results-0.5.1-" & shaA, "/dev/nim-chronos"])
    check lockMismatches(
      goodLock, linkedPaths, ["chronos"], linkNames = [("/dev/nim-chronos", "chronos")]
    ).len == 0
    let unlisted = lockMismatches(
      goodLock, linkedPaths, linkNames = [("/dev/nim-chronos", "chronos")]
    )
    checkpoint $unlisted
    check unlisted.len == 2
    check unlisted[0].startsWith("/dev/nim-chronos: ") and "not listed" in unlisted[0]
    let unknown = lockMismatches(goodLock, paths, ["chronos", "stew"])
    checkpoint $unknown
    check unknown.len == 2
    check unknown[0].startsWith("stew: listed as a develop link")
    check unknown[1].startsWith("chronos: ") and "nor a develop link" in unknown[1]

  test "[IMPL-DECISION G436] a directory outside the installs and the project, a local source, is reported":
    let found = lockMismatches(
      goodLock,
      pathsOf(
        [
          "/r/nimbledeps/pkgs2/results-0.5.1-" & shaA,
          "/r/nimbledeps/pkgs2/chronos-4.4.1-" & shaB,
          "/r/src",
          "/elsewhere/stew/src",
          "/r/nimbledeps/pkgs2/stew-0.5.2",
          "/r/sdk/src",
        ]
      ),
      ownDir = "/r/src",
    )
    checkpoint $found
    check found.len == 3
    check found[0].startsWith("/elsewhere/stew/src: ")
    check found[1].startsWith("/r/nimbledeps/pkgs2/stew-0.5.2: ")
    check found[2].startsWith("/r/sdk/src: ")

  test "[IMPL-DECISION G436] an install the lock lacks, such as a Nim tree 0.20.1 left, is reported":
    let found = lockMismatches(
      goodLock,
      pathsOf(
        [
          "/p/pkgs2/results-0.5.1-" & shaA,
          "/p/pkgs2/chronos-4.4.1-" & shaB,
          "/p/pkgs2/nim-2.2.14-" & shaC,
        ]
      ),
    )
    check found.len == 1
    check found[0].startsWith(
      "/p/pkgs2/nim-2.2.14-" & shaC &
        ": nimble.paths names an install nimble.lock does not have"
    )

  test "[IMPL-DECISION G436] two installs of one package are reported (draft #189)":
    let found = lockMismatches(
      goodLock,
      pathsOf(
        [
          "/p/pkgs2/results-0.5.1-" & shaA,
          "/p/pkgs2/results-0.5.1-" & shaC,
          "/p/pkgs2/chronos-4.4.1-" & shaB,
        ]
      ),
    )
    check found.len == 1
    check found[0].startsWith("results: nimble.paths names 2 installs")

  test "[IMPL-DECISION G468] an install and its own srcDir, both named, are one install; another directory under it is not":
    let
      whole = "/p/pkgs2/results-0.5.1-" & shaA
      chronos = "/p/pkgs2/chronos-4.4.1-" & shaB
      paths = pathsOf([whole, whole & "/src", chronos])
    check lockMismatches(goodLock, paths, srcDirs = [(whole, whole & "/src")]).len == 0
    # Without the srcDir its nimble file declares, the two are two installs, as before.
    let unpaired = lockMismatches(goodLock, paths)
    check unpaired.len == 1
    check unpaired[0].startsWith("results: nimble.paths names 2 installs")
    # A directory under the install that is not its srcDir does not pair.
    let other = lockMismatches(
      goodLock,
      pathsOf([whole, whole & "/tools", chronos]),
      srcDirs = [(whole, whole & "/src")],
    )
    check other.len == 1
    check other[0].startsWith("results: nimble.paths names 2 installs")
    # Another install's srcDir does not pair with this one.
    let crossed = lockMismatches(
      goodLock,
      pathsOf([whole, chronos & "/src", chronos]),
      srcDirs = [(whole, chronos & "/src")],
    )
    check crossed.len == 1
    check crossed[0].startsWith("chronos: nimble.paths names 2 installs")
    let windows = "C:\\p\\pkgs2\\results-0.5.1-" & shaA
    check lockMismatches(
      goodLock,
      pathsOf([windows, windows & "\\src", "C:\\p\\pkgs2\\chronos-4.4.1-" & shaB]),
      srcDirs = [(windows, windows & "\\src")],
    ).len == 0
    const inVm = lockMismatches(
      lockOf([("results", "0.5.1", repeat('a', 40))]),
      "--path:\"/p/pkgs2/results-0.5.1-" & repeat('a', 40) & "\"\n" &
        "--path:\"/p/pkgs2/results-0.5.1-" & repeat('a', 40) & "/src\"\n",
      srcDirs = [
        (
          "/p/pkgs2/results-0.5.1-" & repeat('a', 40),
          "/p/pkgs2/results-0.5.1-" & repeat('a', 40) & "/src",
        )
      ],
    )
    check inVm.len == 0

  test "[IMPL-DECISION G468] two installs of one package, each with its srcDir, are still two installs":
    let
      a = "/p/pkgs2/results-0.5.1-" & shaA
      c = "/p/pkgs2/results-0.5.1-" & shaC
    let found = lockMismatches(
      goodLock,
      pathsOf([a, a & "/src", c, c & "/src", "/p/pkgs2/chronos-4.4.1-" & shaB]),
      srcDirs = [(a, a & "/src"), (c, c & "/src")],
    )
    checkpoint $found
    check found.len == 1
    check found[0] == "results: nimble.paths names 2 installs of it: " & a & ", " & c

  test "[IMPL-DECISION G468] an install and its srcDir under a checksum not the lock's are one finding":
    let c = "/p/pkgs2/results-0.5.1-" & shaC
    let found = lockMismatches(
      goodLock,
      pathsOf([c, c & "/src", "/p/pkgs2/chronos-4.4.1-" & shaB]),
      srcDirs = [(c, c & "/src")],
    )
    checkpoint $found
    check found.len == 1
    check found[0].startsWith(
      "results: nimble.paths names " & c & ", but nimble.lock records"
    )

  test "[IMPL-DECISION G436] a directory name is read from the right: a dashed name parses":
    var install: Install
    check installOf("/p/pkgs2/nim-foo_bar-1.2.3-" & shaA & "/src", install)
    check install.name == "nim-foo_bar" and install.version == "1.2.3" and
      install.checksum == shaA
    check not installOf("/p/pkgs2/results-0.5.1", install)
    check not installOf("/p/other/results-0.5.1-" & shaA, install)

  test "[IMPL-DECISION G436] a plain version is compared, a #commit one is not, and the lock's nim is skipped":
    let found = lockMismatches(
      goodLock,
      pathsOf(["/p/pkgs2/results-0.5.2-" & shaA, "/p/pkgs2/chronos-4.4.1-" & shaB]),
    )
    check found.len == 1
    check found[0].startsWith("results: nimble.paths names version 0.5.2")
    let pinned = lockOf([("storage", "#4fe02344", shaA), ("nim", "2.2.14", shaC)])
    check lockMismatches(pinned, pathsOf(["/p/pkgs2/storage-0.5.3-" & shaA])).len == 0

  test "[IMPL-DECISION G436] a lock that is not Nimble's is one finding":
    check lockMismatches("not json", "").len == 1
    check lockMismatches("{}", "") == @["nimble.lock has no `packages` object"]

  test "[IMPL-DECISION G436] the comparison runs in Nim's VM":
    const found = lockMismatches(
      lockOf([("results", "0.5.1", repeat('a', 40))]),
      "--path:\"/p/pkgs2/results-0.5.1-" & repeat('c', 40) & "\"\n",
    )
    check found.len == 1

  test "[IMPL-DECISION G436] from a root: no nimble.paths, or installs that are gone, is one finding; links resolve":
    let root = getTempDir() / ("lcn-lockcheck-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer:
      removeDir(root)
    check installMismatches(root).len == 1 # no nimble.lock
    writeFile(root / "nimble.lock", goodLock)
    writeFile(root / "proj.nimble", "version = \"0.1.0\"\nsrcDir = \"src\"\n")
    let missing = installMismatches(root)
    check missing.len == 1
    check "nimble.paths is missing" in missing[0] and setupHint in missing[0]
    let dirs = [
      root / "nimbledeps" / "pkgs2" / ("results-0.5.1-" & shaA),
      root / "nimbledeps" / "pkgs2" / ("chronos-4.4.1-" & shaB),
      root / "src",
    ]
    writeFile(root / "nimble.paths", pathsOf(dirs))
    let gone = installMismatches(root)
    check gone.len == 1
    check "2 install directories that do not exist" in gone[0] and setupHint in gone[0]
    for dir in dirs:
      createDir(dir)
    check installMismatches(root).len == 0
    # chronos from a develop link: its directory is found by the nimble file above its srcDir.
    let link = root / "dev" / "nim-chronos"
    createDir(link / "src")
    writeFile(link / "chronos.nimble", "version = \"4.4.1\"\n")
    writeFile(root / "nimble.paths", pathsOf([dirs[0], link / "src", dirs[2]]))
    check installMismatches(root, ["chronos"]).len == 0
    let unlisted = installMismatches(root)
    checkpoint $unlisted
    check unlisted.len == 2
    check "a develop link of chronos, which is not listed" in unlisted[0]

  test "[IMPL-DECISION G468] from a root: an install and the srcDir its nimble file declares pass as one":
    let root = getTempDir() / ("lcn-lockcheck-pair-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer:
      removeDir(root)
    writeFile(root / "nimble.lock", goodLock)
    writeFile(root / "proj.nimble", "version = \"0.1.0\"\nsrcDir = \"src\"\n")
    let
      results = root / "nimbledeps" / "pkgs2" / ("results-0.5.1-" & shaA)
      chronos = root / "nimbledeps" / "pkgs2" / ("chronos-4.4.1-" & shaB)
    for dir in [results, chronos / "src", root / "src"]:
      createDir(dir)
    writeFile(chronos / "chronos.nimble", "version = \"4.4.1\"\nsrcDir = \"src\"\n")
    writeFile(
      root / "nimble.paths", pathsOf([results, chronos, chronos / "src", root / "src"])
    )
    check installMismatches(root).len == 0
    # Its nimble file declares another srcDir: the two directories are two installs.
    writeFile(chronos / "chronos.nimble", "version = \"4.4.1\"\nsrcDir = \"lib\"\n")
    let found = installMismatches(root)
    checkpoint $found
    check found.len == 1
    check found[0].startsWith("chronos: nimble.paths names 2 installs")

  test "[IMPL-DECISION G436] the repository's own lock: installs named from it pass, and a changed one fails":
    let lockText = readFile("nimble.lock")
    var dirs: seq[string]
    for name, entry in parseJson(lockText)["packages"]:
      dirs.add "/p/nimbledeps/pkgs2/" & name & "-" & entry["version"].getStr & "-" &
        entry["checksums"]["sha1"].getStr
    check dirs.len > 0
    check lockMismatches(lockText, pathsOf(dirs)).len == 0
    dirs[0] = dirs[0][0 ..< dirs[0].len - 40] & shaC
    check lockMismatches(lockText, pathsOf(dirs)).len == 1
