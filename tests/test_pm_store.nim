## The installed-state store (Tier 5 step 5-5-2; DECISIONS G444, G445, G446;
## docs/PACKAGE-MANAGER.md §8, §9): the root and its lock and path rules, extraction, the commit
## and its crash points, the start, retirement and the retained hash, over signed archives
## opened as an install would open them. POSIX only: elsewhere the suite compiles and skips.

import std/[algorithm, atomics, os, sequtils, strutils]
import unittest2
import logos_sdk/testing/kitbuild
import ./support/lgxbuild

when defined(posix):
  import std/posix
  import logos_sdk/cbor
  import ../src/logos_core/pm/store

  const Linux = "linux-x86_64"

  let work = currentSourcePath().parentDir.parentDir / "build" / "pm_store" / kitVariant
  removeDir(work)
  createDir(work)

  let (orgKey, orgPub) = testKey(1)
  let (_, otherPub) = testKey(2)
  let trust = trustInputOf([("org", orgPub, @["logos.example", "logos.wallet"])])

  proc sourceOf(p: ModulePackage): PackageSource =
    let m = p.decoded
    lgxSource("main", m.identity.package & "@" & m.identity.version)

  type Archive = object
    pkg: ModulePackage
    bytes: seq[byte]

  proc archive(p: ModulePackage): Archive =
    Archive(pkg: p, bytes: p.packed("org", orgKey))

  # Signing takes about a second, so each archive is built once.
  let plain = archive(modulePackage())
  let wallet = archive(modulePackage("logos.wallet", config = Opt.none(ConfigSpec)))
  let later = archive(modulePackage(version = "1.1.0"))
  var treeFiles: seq[(string, seq[byte])]
  for i in 0 ..< 300:
    treeFiles.add(
      (
        "tree/d" & $(i mod 7) & "/e" & $(i mod 3) & "/f" & $i,
        bytesOf("file " & $i & " ").cycle(4),
      )
    )
  var big = newSeq[byte](4 * 1024 * 1024)
  for i in 0 ..< big.len:
    big[i] = byte((i * 7 + i div 4096) and 0xff)
  treeFiles.add(("big/blob", big))
  let deep = archive(modulePackage(version = "2.0.0").withFiles(Linux, treeFiles))
  let cased = archive(
    modulePackage(version = "3.0.0").withFiles(
      Linux, @[("data/Notes", bytesOf("upper")), ("data/notes", bytesOf("lower"))]
    )
  )

  proc opened(a: Archive): LgxPackage =
    ## As an install opens it: under the current trust, for this suite's platform, with
    ## case-sensitive rules so that the store's own rules are what is tested.
    openLgx(a.bytes, trust, linuxHost, DefaultLgxLimits, PathRules()).get

  proc fresh(name: string): string =
    result = work / name
    removeDir(result)
    createDir(result)

  proc staged(s: var InstalledStore, a: Archive, stop: StopFlag = nil): Staged =
    s.stage(a.opened, bytesSource(a.bytes), a.pkg.sourceOf, @[], blake3(a.bytes), stop).get

  proc installed(s: var InstalledStore, a: Archive): Installed =
    let st = s.staged(a)
    discard s.commit([st], []).get
    s.records[s.find(st.file.record.identity).get]

  proc modeOf(path: string): int =
    var st: Stat
    doAssert lstat(cstring(path), st) == 0, path
    int(st.st_mode) and 0o7777

  proc entries(dir: string): seq[string] =
    if dirExists(dir):
      for kind, path in walkDir(dir, relative = true):
        result.add(path)
    result.sort()

  proc fileBytes(path: string): seq[byte] =
    for c in readFile(path):
      result.add(byte(c))

  proc writable(path: string, body: proc()) =
    doAssert chmod(cstring(path), 0o600) == 0
    body()
    doAssert chmod(cstring(path), 0o400) == 0

  proc flip(path: string) =
    writable(path) do():
      var text = readFile(path)
      text[0] = char(ord(text[0]) xor 1)
      writeFile(path, text)

  let example = PackageIdentity(package: "logos.example", version: "1.0.0")

  suite "the installation root (G444)":
    test "[PKG-0487] a fresh root starts empty, and a second writer on it is refused":
      let dir = fresh("lock")
      var s = openStore(dir).get
      check s.records.len == 0
      check s.sequence == 0
      check fileExists(dir / "install" / "index")
      check modeOf(dir / "install") == 0o700
      check modeOf(dir / "install" / "r") == 0o700
      let second = openStore(dir)
      check second.isErr
      check second.error.fault == sfInUse
      s.close()
      var again = openStore(dir).get
      again.close()

    test "[PKG-0489] the root's path rules come from a probe in it":
      let dir = fresh("probe")
      createDir(dir / "own")
      writeFile(dir / "own" / "Mixed", "x")
      let folds = fileExists(dir / "own" / "mixed")
      var s = openStore(dir).get
      defer:
        s.close()
      check s.rules.ignoreCase == (folds or hostPathRules().ignoreCase)
      check entries(dir / "install") == @["index", "lock", "r"]
      # [SPEC PM l.924] a selected variant whose paths collide under the root's rules
      s.rules.ignoreCase = true
      let collides = s.stage(
        cased.opened,
        bytesSource(cased.bytes),
        cased.pkg.sourceOf,
        @[],
        blake3(cased.bytes),
      )
      check collides.isErr
      check collides.error.fault == sfPaths
      check "data/Notes" in collides.error.detail
      check entries(dir / "install" / "r").len == 0
      if not folds:
        s.rules.ignoreCase = false
        let i = s.installed(cased)
        check readFile(i.base & "data/Notes") == "upper"
        check readFile(i.base & "data/notes") == "lower"

  suite "extraction (G446)":
    test "[PKG-0219] [PKG-0499] [PKG-0204] [PKG-0292] the selected variant's files only, 0400 in 0700 directories, named only once committed":
      let dir = fresh("extract")
      var s = openStore(dir).get
      defer:
        s.close()
      let st = s.staged(plain)
      check s.records.len == 0 # [PKG-0219] nothing names it yet
      check st.rid.isRid
      check st.base == dir / "install" / "r" / st.rid / "a" & "/"
      let rdir = dir / "install" / "r" / st.rid
      check entries(rdir) == @["a", "m"]
      check entries(rdir / "a") == @["data", "lib", "schema"]
      check entries(rdir / "a" / "lib") ==
        @["libalpha.so"] # not the darwin variant's files
      check entries(rdir / "m") == @["manifest.cbor", "manifest.cose", "record.1"]
      check fileBytes(rdir / "m" / "manifest.cbor") == plain.pkg.decoded.encoded
      for (path, data) in plain.pkg.files[0][1]:
        check fileBytes(st.base & path) == data
      for path in walkDirRec(rdir, yieldFilter = {pcFile, pcDir}, relative = true):
        let full = rdir / path
        if dirExists(full):
          check modeOf(full) == 0o700
        else:
          # [PKG-0499] nothing executable
          check modeOf(full) == 0o400
      discard s.commit([st], []).get
      let i = s.records[0]
      for a in i.file.record.artifacts:
        # [PKG-0292] a local file in this instance's root, never a Storage object
        let p = localPath(i.base, a)
        check p.startsWith(dir / "install" / "r" / i.rid / "a" & "/")
        check fileExists(p)
      # The handoff reads the installed files (G451).
      let h = buildHandoff(
        i.file.record, i.base, i.manifest, i.file.record.commitment, "alpha_module",
        trust, i.reader,
      ).get
      check h.lookup("artifact").get.lookup("local_path").get.getText.get ==
        i.base & "lib/libalpha.so"
      check h.lookup("configuration").isSome

    test "[PKG-0204] [PKG-0274] a link planted at a file or a directory fails, and nothing outside is written":
      let dir = fresh("planted")
      createDir(dir / "a")
      createDir(dir / "outside")
      createSymlink(dir / "outside", dir / "a" / "lib")
      createSymlink(dir / "outside" / "x", dir / "a" / "x")
      createDir(dir / "a" / "made")
      let root = openDir(dir / "a").get
      defer:
        closeFd(root)
      var tree = initTree(root)
      for path in ["lib/libalpha.so", "x", "made/y"]:
        let r = tree.extractFile(path, bytesOf("payload"), sync = true)
        check r.isErr
        check r.error.fault == efExists
      check entries(dir / "outside").len == 0
      check entries(dir / "a" / "made").len == 0
      # A name this tree made is used again; a file is never written twice.
      check tree.extractFile("new/one", bytesOf("1"), sync = true).isOk
      check tree.extractFile("new/two", bytesOf("2"), sync = true).isOk
      let twice = tree.extractFile("new/one", bytesOf("3"), sync = true)
      check twice.isErr
      check twice.error.fault == efExists
      check readFile(dir / "a" / "new" / "one") == "1"
      check tree.finish(sync = true).isOk

    test "many small files in nested directories and one large file":
      let dir = fresh("many")
      var s = openStore(dir).get
      defer:
        s.close()
      let i = s.installed(deep)
      check i.file.record.artifacts.len == 3 + treeFiles.len
      check checkRetained(i).isOk
      check readFile(i.base & "tree/d6/e2/f272") == textOf(treeFiles[272][1])
      check getFileSize(i.base & "big/blob") == big.len

    test "a stop before or during the writes leaves nothing":
      let dir = fresh("stop")
      var s = openStore(dir).get
      defer:
        s.close()
      var flag: Atomic[bool]
      flag.store(true)
      let r = s.stage(
        plain.opened,
        bytesSource(plain.bytes),
        plain.pkg.sourceOf,
        @[],
        blake3(plain.bytes),
        addr flag,
      )
      check r.isErr
      check r.error.fault == sfStopped
      check entries(dir / "install" / "r").len == 0

    test "[IMPL-DECISION G446] staging reads a spool file judged by inspection; a file changed after it fails, and leaves nothing":
      let spool = work / "spool.lgx"
      writeFile(spool, textOf(deep.bytes))
      let judged = inspectLgx(
        fileSource(spool), trust, linuxHost, DefaultLgxLimits, PathRules()
      ).get
      check judged.artifacts.allIt(it.data.len == 0) # inspection keeps no file's bytes
      block:
        var s = openStore(fresh("spool")).get
        defer:
          s.close()
        let st = s.stage(
          judged, fileSource(spool), deep.pkg.sourceOf, @[], blake3(deep.bytes)
        ).get
        discard s.commit([st], []).get
        let i = s.records[s.find(st.file.record.identity).get]
        check checkRetained(i).isOk
        check readFile(i.base & "tree/d6/e2/f272") == textOf(treeFiles[272][1])
        check fileBytes(i.base & "big/blob") == big
      var flipped = deep.bytes
      flipped[flipped.len div 2] = flipped[flipped.len div 2] xor 0x10
      for (name, changed) in [
        ("another archive", later.bytes),
        ("the same size, a byte flipped", flipped),
        ("truncated", deep.bytes[0 ..< deep.bytes.len div 2]),
      ]:
        checkpoint name
        let dir = fresh("spool-changed")
        var s = openStore(dir).get
        defer:
          s.close()
        writeFile(spool, textOf(changed))
        let r =
          s.stage(judged, fileSource(spool), deep.pkg.sourceOf, @[], blake3(deep.bytes))
        check r.isErr
        check r.error.fault == sfSource
        check entries(dir / "install" / "r").len == 0
      removeFile(spool)

  suite "the commit (G445)":
    test "[PKG-0610] a committed record is there after a restart, its paths rebuilt, in each sync mode":
      var modes = @[smEachFile]
      when defined(linux):
        modes.add(smSyncfs)
      for mode in modes:
        let dir = fresh("commit-" & $mode.ord)
        var s = openStore(dir).get
        checkpoint "the probe chose: " & $s.syncMode
        s.syncMode = mode
        let i = s.installed(plain)
        check s.sequence == 1
        check i.file.generation == 1
        check i.file.archiveDigest == blake3(plain.bytes)
        s.close()
        moveDir(dir, dir & "-moved")
        var t = openStore(dir & "-moved").get
        check t.sequence == 1
        check t.records.len == 1
        check t.records[0].rid == i.rid
        check t.records[0].file == i.file
        check t.records[0].base == dir & "-moved" / "install" / "r" / i.rid / "a" & "/"
        check checkRetained(t.records[0]).isOk
        t.close()

    test "[PKG-0611] a crash at each step leaves the old state or the new one, and the start removes the rest":
      let dir = fresh("crash")
      let rdir = dir / "install" / "r"
      var s = openStore(dir).get
      # After the files, before the sync.
      s.crashAt = cpAfterFiles
      check s.stage(
        plain.opened,
        bytesSource(plain.bytes),
        plain.pkg.sourceOf,
        @[],
        blake3(plain.bytes),
      ).error.fault == sfStopped
      check entries(rdir).len == 1
      s.close()
      s = openStore(dir).get
      check s.records.len == 0
      check entries(rdir).len == 0
      # Synced, never committed.
      discard s.staged(plain)
      s.close()
      s = openStore(dir).get
      check s.records.len == 0
      check entries(rdir).len == 0
      # The new index written to its temporary file, not renamed.
      let st = s.staged(plain)
      s.crashAt = cpAfterIndexTmp
      check s.commit([st], []).error.fault == sfStopped
      check fileExists(dir / "install" / "index.tmp")
      s.close()
      s = openStore(dir).get
      check s.records.len == 0
      check not fileExists(dir / "install" / "index.tmp")
      check entries(rdir).len == 0
      # The new index in place.
      let st2 = s.staged(plain)
      s.crashAt = cpAfterRename
      check s.commit([st2], []).error.fault == sfStopped
      s.close()
      s = openStore(dir).get
      check s.records.len == 1
      check s.records[0].rid == st2.rid
      # A removal, at each side of the rename.
      s.crashAt = cpAfterIndexTmp
      check s.commit([], [st2.rid]).error.fault == sfStopped
      s.close()
      s = openStore(dir).get
      check s.records.len == 1
      s.crashAt = cpAfterRename
      check s.commit([], [st2.rid]).error.fault == sfStopped
      s.close()
      s = openStore(dir).get
      check s.records.len == 0
      check s.sequence == 2
      check entries(rdir).len == 0
      s.close()

    test "[PKG-0182] an identity is installed once; an update replaces it in one commit":
      let dir = fresh("once")
      var s = openStore(dir).get
      defer:
        s.close()
      let first = s.installed(plain)
      let again = s.staged(plain)
      let refused = s.commit([again], [])
      check refused.isErr
      check refused.error.fault == sfConflict
      check refused.error.identity == Opt.some(example)
      check s.abandon(again).isOk
      check not dirExists(dir / "install" / "r" / again.rid)
      let w = s.installed(wallet)
      let next = s.staged(later)
      check s.commit([next], [first.rid]).get == 3
      check s.records.mapIt($it.file.record.identity) ==
        @["logos.example@1.1.0", "logos.wallet@1.0.0"]
      check s.records[1].rid == w.rid

    test "[PKG-0500] a replacement is a new directory; a signer replacement writes the next generation and no artifact":
      let dir = fresh("replace")
      var s = openStore(dir).get
      defer:
        s.close()
      let i = s.installed(plain)
      let lib = i.base & "lib/libalpha.so"
      var before: Stat
      doAssert stat(cstring(lib), before) == 0
      # A committed file is never written again.
      let root = openDir(i.base).get
      var tree = initTree(root)
      check tree.extractFile("lib/libalpha.so", bytesOf("other"), sync = false).error.fault ==
        efExists
      closeFd(root)
      let replacement = s.staged(plain)
      check replacement.rid != i.rid
      check s.abandon(replacement).isOk
      let signer = PackageSigner(profile: signingProfile(), key: otherPub)
      let st = s.stageSigner(0, signer).get
      check s.commit([st], []).get == 2
      var after: Stat
      doAssert stat(cstring(lib), after) == 0
      check s.records[0].rid == i.rid
      check s.records[0].file.generation == 2
      check s.records[0].file.record.signer == signer
      check after.st_ino == before.st_ino
      check checkRetained(s.records[0]).isOk
      s.close()
      s = openStore(dir).get
      check s.records[0].file.generation == 2
      check s.records[0].file.record.signer == signer
      check entries(dir / "install" / "r" / i.rid / "m") ==
        @["manifest.cbor", "manifest.cose", "record.2"]

  suite "the start (G445)":
    test "[S6] no index while records are present stops the start, and nothing is deleted":
      let dir = fresh("noindex")
      var s = openStore(dir).get
      let i = s.installed(plain)
      s.close()
      removeFile(dir / "install" / "index")
      let r = openStore(dir)
      check r.isErr
      check r.error.fault == sfDamaged
      check "no index" in r.error.detail
      check dirExists(dir / "install" / "r" / i.rid)

    test "[IMPL-DECISION G505] the state's number is higher than the library's: sfFormat naming both, and the root is left exactly as it was, no lock file made":
      let dir = fresh("format-higher")
      createDir(dir / "install")
      let index = cborMap(
        (cbor("format"), cbor(FileFormat + 1)),
        (cbor("sequence"), cbor(0'u64)),
        (cbor("records"), CborValue(kind: ckArray)),
      )
      writeFile(dir / "install" / "index", cast[string](encodeCbor(index)))
      let before = treeOf(dir)
      let r = openStore(dir)
      check r.isErr
      if r.isErr:
        check r.error.fault == sfFormat
        check (
          "is installed-files format " & $(FileFormat + 1) &
          "; this library reads format " & $FileFormat & "; nothing was changed"
        ) in r.error.detail
      check treeOf(dir) == before
      check entries(dir / "install") == @["index"]

    test "[IMPL-DECISION G505] the state's number is lower than the library's: refused today, like any other number, and the root is left exactly as it was":
      # A library that brings the next format must still read this one, so this case
      # changes then; the hook stands in for that library's number.
      let dir = fresh("format-lower")
      var s = openStore(dir).get
      discard s.installed(plain)
      s.close()
      let before = treeOf(dir)
      libraryFormatForTests = FileFormat + 1
      let r = openStore(dir)
      libraryFormatForTests = FileFormat
      check r.isErr
      if r.isErr:
        check r.error.fault == sfFormat
        check (
          "is installed-files format " & $FileFormat & "; this library reads format " &
          $(FileFormat + 1) & "; nothing was changed"
        ) in r.error.detail
      check treeOf(dir) == before
      var again = openStore(dir).get
      check again.records.len == 1
      again.close()

    test "[R3] an index naming a missing or invalid record stops the start, naming its identity":
      let dir = fresh("missing")
      var s = openStore(dir).get
      let i = s.installed(plain)
      discard s.installed(wallet)
      s.close()
      let m = dir / "install" / "r" / i.rid / "m"
      createDir(dir / "install" / "r" / "0123456789abcdef0123456789abcdef")
      moveFile(m / "record.1", dir / "record.1")
      var r = openStore(dir)
      check r.isErr
      check r.error.fault == sfDamaged
      check r.error.identity == Opt.some(example)
      check "record.1" in r.error.detail
      # nothing is deleted when the start stops, not even an orphan
      check dirExists(dir / "install" / "r" / "0123456789abcdef0123456789abcdef")
      moveFile(dir / "record.1", m / "record.1")
      flip(m / "manifest.cbor")
      r = openStore(dir)
      check r.isErr
      check r.error.fault == sfDamaged
      check r.error.identity == Opt.some(example)
      flip(m / "manifest.cbor")
      writable(m / "record.1") do():
        writeFile(m / "record.1", "not a record")
      r = openStore(dir)
      check r.isErr
      check r.error.identity == Opt.some(example)
      writeFile(dir / "install" / "index", "not an index")
      r = openStore(dir)
      check r.isErr
      check r.error.fault == sfDamaged
      check r.error.identity.isNone

    test "[PKG-0471] a record that no longer fits once the state directory moves to a longer path stops the start":
      let dir = fresh("moved")
      var s = openStore(dir).get
      let i = s.installed(plain)
      s.close()
      let r = i.file.record
      proc largest(base: string): int =
        ## The largest required result at `base`, as the start checks them (G452).
        let rv = recordValue(r, base)
        result = envelopeBytes(cborMap((cbor("installed"), rv))).get
        let page = cborMap(
          (cbor("packages"), cborArray(rv)), (cbor("next_cursor"), cbor(maxCursor()))
        )
        result = max(result, envelopeBytes(page).get)
        for (module, h) in admissionHandoffs(
          r, base, i.manifest, r.commitment, i.reader
        ).get:
          result = max(result, envelopeBytes(cborMap((cbor("handoff"), h.get))).get)

      # The record stands exactly at a lowered edge: the 16 MiB edge itself is
      # test_pm_records' (PKG-0468), and a package of some 20,000 files would take minutes.
      admissionLimitForTests = largest(i.base)
      defer:
        admissionLimitForTests = 0
      var t = openStore(dir).get
      check t.records.len == 1
      t.close()
      let longer = work / "moved-" & "x".repeat(100)
      moveDir(dir, longer)
      let moved = openStore(longer)
      check moved.isErr
      check moved.error.fault == sfDamaged
      check moved.error.identity == Opt.some(r.identity)
      check "admission bound" in moved.error.detail
      moveDir(longer, dir)
      t = openStore(dir).get
      check t.records.len == 1
      t.close()

  suite "retirement (R1)":
    test "a directory retired at sequence s stays while an older snapshot is held":
      let dir = fresh("retire")
      var s = openStore(dir).get
      defer:
        s.close()
      let i = s.installed(plain)
      let held = s.sequence
      check s.commit([], [i.rid]).get == 2
      check s.records.len == 0
      check s.retiredCount == 1
      check s.collect(Opt.some(held)).deleted == 0
      check dirExists(dir / "install" / "r" / i.rid)
      check checkRetained(i).isOk # the snapshot's reader still finds the bytes
      check s.collect(Opt.some(2'u64)).deleted == 1
      check not dirExists(dir / "install" / "r" / i.rid)
      check s.retiredCount == 0
      # A replaced generation is retired the same way.
      let j = s.installed(plain)
      let st =
        s.stageSigner(0, PackageSigner(profile: signingProfile(), key: otherPub)).get
      discard s.commit([st], []).get
      let m = dir / "install" / "r" / j.rid / "m"
      check fileExists(m / "record.1")
      check s.collect(Opt.none(uint64)).deleted == 1
      check not fileExists(m / "record.1")
      check fileExists(m / "record.2")

  suite "the retained bytes (PKG-0181, PKG-0293)":
    test "[PKG-0181] [PKG-0293] [TXT-0472] the retained hash fails after a flipped byte, a removed file, or a link in place of a file or a directory":
      let dir = fresh("retained")
      var s = openStore(dir).get
      defer:
        s.close()
      let i = s.installed(plain)
      let lib = i.base & "lib/libalpha.so" # a packaged native library (l.1185)
      check checkRetained(i).isOk
      flip(lib)
      var r = checkRetained(i)
      check r.isErr
      check r.error.fault == sfIntegrity
      check r.error.identity == Opt.some(example)
      flip(lib)
      check checkRetained(i).isOk
      copyFile(lib, dir / "copy.so")
      removeFile(lib)
      check checkRetained(i).error.fault == sfIntegrity
      createSymlink(dir / "copy.so", lib)
      check checkRetained(i).error.fault == sfIntegrity
      removeFile(lib)
      copyFile(dir / "copy.so", lib)
      check checkRetained(i).isOk
      moveDir(i.base & "lib", i.base & "lib.real")
      createSymlink("lib.real", i.base & "lib")
      check checkRetained(i).error.fault == sfIntegrity
      var flag: Atomic[bool]
      flag.store(true)
      removeFile(i.base & "lib")
      moveDir(i.base & "lib.real", i.base & "lib")
      check checkRetained(i, addr flag).error.fault == sfStopped

  suite "teardown (S4)":
    test "temporary roots go with the plain recursive delete":
      removeDir(work)
      check not dirExists(work)
else:
  suite "the installed-state store":
    test "POSIX only":
      skip()
