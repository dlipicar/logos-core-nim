## The Runtime state store (`runtime/store.nim`, `durable.nim`; DECISIONS I82):
## the snapshot's format and invariants, atomic replace, the lock, directory
## modes, side records. No engine runs here.

import std/[os, sets, strutils, tables]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/cbor
import ../src/logos_core/durable
import ../src/logos_core/runtime/[plumbing, store, store_types]
import ./support/kitbuild

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "store" / kitVariant
removeDir(work)
createDir(work)

var dirs = 0

proc freshDir(): string =
  inc dirs
  work / ("s" & $dirs)

func meterRecord(assignment = Opt.none(string)): ModuleRecord =
  var root: Digest
  root[0] = 7
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "meter",
    primaryContract: Opt.some(root),
    stateAssignment: assignment,
  )

func dynRecord(path: string, reason = Opt.none(string)): ModuleRecord =
  var h: array[32, byte]
  h[3] = 9
  ModuleRecord(
    module: "sensor_module",
    strategy: stDirectDynamic,
    artifact: ArtifactRecord(
      id: "sensor", localPath: path, hash: h, hashSuite: "logos.hash-suite.blake3-256"
    ),
    requestedPermissions: @[
      RequestedPermission(
        permission: "net", constraints: encodeCbor(cbor(1'u64)), reason: reason
      )
    ],
  )

proc sample(): Snapshot =
  Snapshot(
    runtimeInstanceId: "rt-1",
    epoch: 1_800_000_000'u64,
    instances: @[
      StoredInstance(
        instance: "meter-1",
        providerId: "p-00-1",
        record: meterRecord(Opt.some("meter-state")),
        state: msReady,
        revision: (1_800_000_000'u64 shl 32) + 5,
        intent: inRequested,
        intentRevision: (1_800_000_000'u64 shl 32) + 2,
        origin: hostOrigin(),
      ),
      StoredInstance(
        instance: "sensor-1",
        record: dynRecord("/opt/sensor.so"),
        state: msError,
        failure: Opt.some(Failure(kind: fkOther, reason: "why")),
        revision: 3,
        intent: inRequested,
        intentRevision: 2,
        origin: moduleOrigin("meter-1"),
      ),
      StoredInstance(
        instance: "m-x",
        created: true,
        record: meterRecord(),
        providerId: "p-00-2",
        state: msUnloaded,
        revision: 1,
        intent: inStopped,
      ),
    ],
    retired: @[RetiredId(instance: "old", stateAssignment: Opt.some("old-state"))],
    createKeys: @[
      CreateKey(consumer: "meter-1", key: "k1", module: "meter_module", instance: "m-x")
    ],
  )

proc writeRaw(dir: string, bytes: seq[byte]) =
  createDir(dir)
  when defined(posix):
    discard chmod(cstring(dir), 0o700)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  writeFile(dir / SnapshotName, s)

proc rawOf(dir: string): string =
  readFile(dir / SnapshotName)

proc reopen(dir: string): Snapshot =
  var (s, snap) = openStore(dir).tryGet
  s.close()
  snap.get

suite "run.store: the Runtime state store [IMPL]":
  test "a snapshot round-trips as deterministic CBOR":
    let a = sample()
    let bytes = encodeSnapshot(a).tryGet
    let b = decodeSnapshot(bytes).tryGet
    check encodeSnapshot(b).tryGet == bytes
    check b.instances.len == 3
    check b.instances[0].origin.host
    check b.instances[1].origin.instance == "meter-1"
    check b.instances[1].failure.get.classification == "other"
    check b.instances[1].failure.get.reason == "why"
    check b.instances[2].created
    check b.instances[2].intent == inStopped
    check b.retired[0].stateAssignment == Opt.some("old-state")
    check b.createKeys[0].instance == "m-x"
    # Written and read through the store.
    let dir = freshDir()
    var (s, none) = openStore(dir).tryGet
    check none.isNone
    s.write(a).tryGet
    s.close()
    check encodeSnapshot(reopen(dir)).tryGet == bytes

  test "every classification RUNTIME l.3753 lists is stored and read back":
    for k in FailureKind:
      if k != fkLoader:
        check classificationOf($k).tryGet.kind == k
    # [I89] `loader-<code>` for each typed Module Loader error (l.3754).
    for c in LoaderErrorCode:
      let f = classificationOf("loader-" & $c).tryGet
      check f.kind == fkLoader and f.loader == c
    check classificationOf($fkLoader).isErr
    check classificationOf("loader-").isErr
    check classificationOf("loader-crashed").isErr
    check classificationOf("crashed").isErr

  test "[IMPL] a Module Loader's failure text, which may name host paths, is not stored":
    var a = sample()
    a.instances[1].failure = Opt.some(
      Failure(kind: fkLoader, loader: lecAbiInvalid, reason: "/opt/x", internal: true)
    )
    let b = decodeSnapshot(encodeSnapshot(a).tryGet).tryGet
    check b.instances[1].failure.get.classification == "loader-abi-invalid"
    check b.instances[1].failure.get.reason == ""

  test "a leftover temporary file is removed and the earlier snapshot read":
    let dir = freshDir()
    var (s, _) = openStore(dir).tryGet
    s.write(sample()).tryGet
    s.close()
    let before = rawOf(dir)
    writeFile(dir / (SnapshotName & ".tmp"), "torn")
    check encodeSnapshot(reopen(dir)).tryGet.len == before.len
    check not fileExists(dir / (SnapshotName & ".tmp"))
    check rawOf(dir) == before

  test "corrupt or foreign content fails to open and is left as it is":
    let good = encodeSnapshot(sample()).tryGet
    var cases: seq[(string, seq[byte])]
    cases.add(("truncated", good[0 ..< good.len - 3]))
    # A non-deterministic encoding of the same value: the top-level map's
    # length in two bytes.
    var nd = @[0xB9'u8, 0x00'u8, good[0] and 0x1F'u8]
    nd.add(good[1 ..^ 1])
    cases.add(("non-deterministic", nd))
    cases.add(
      ("schema mismatch", encodeCbor(cborMap(@[(cbor("format"), cbor(1'u64))])))
    )
    var v2 = LcnRsState.decode(good).tryGet
    let v2bytes = encodeCbor(
      cborMap(
        @[
          (cbor("format"), cbor("logos-core-nim.runtime-state.v2")),
          (cbor("runtime_instance_id"), cbor(v2.runtime_instance_id)),
          (cbor("epoch"), cbor(v2.epoch)),
          (cbor("instances"), cborArray(@[])),
          (cbor("retired"), cborArray(@[])),
          (cbor("create_keys"), cborArray(@[])),
        ]
      )
    )
    cases.add(("another format", v2bytes))
    # Hand-built invariant failures, encoded without the store's checks.
    proc raw(s: Snapshot): seq[byte] =
      var x = LcnRsState.decode(encodeSnapshot(sample()).tryGet).tryGet
      x.instances.setLen(0)
      for i in s.instances:
        var one = sample()
        one.instances = @[i]
        one.createKeys.setLen(0)
        x.instances.add(
          LcnRsState.decode(encodeSnapshot(one).tryGet).tryGet.instances[0]
        )
      x.retired.setLen(0)
      x.create_keys.setLen(0)
      for k in s.createKeys:
        x.create_keys.add(
          LcnRsCreateKey(
            consumer: k.consumer, key: k.key, module: k.module, instance: k.instance
          )
        )
      encodeCbor(toCbor(x))

    var twice = sample()
    twice.createKeys.setLen(0)
    twice.instances.add(twice.instances[1])
    cases.add(("an instance listed twice", raw(twice)))
    var twoProviders = sample()
    twoProviders.createKeys.setLen(0)
    twoProviders.instances[2].providerId = "p-00-1"
    cases.add(("a provider id used twice", raw(twoProviders)))
    var ahead = sample()
    ahead.createKeys.setLen(0)
    ahead.instances[0].revision = (ahead.epoch + 1) shl 32
    cases.add(("a revision from a later epoch", raw(ahead)))
    var shared = sample()
    shared.createKeys.setLen(0)
    shared.instances[2].record.stateAssignment = Opt.some("meter-state")
    cases.add(("a shared assignment", raw(shared)))
    var unknownKey = sample()
    unknownKey.createKeys[0].instance = "nobody"
    cases.add(("a key naming an unknown instance", raw(unknownKey)))
    var stray = LcnRsState.decode(good).tryGet
    stray.instances[2].intent_revision = Opt.some(1'u64)
    cases.add(
      ("an intent revision without requested intent", encodeCbor(toCbor(stray)))
    )
    var errNoFailure = LcnRsState.decode(good).tryGet
    errNoFailure.instances[1].failure = Opt.none(LcnRsFailure)
    cases.add(("error without a failure", encodeCbor(toCbor(errNoFailure))))
    let expected = {
      "truncated": "malformed-cbor",
      "non-deterministic": "non-deterministic-cbor",
      "schema mismatch": "not a lcn.rs_state value at []",
      "another format": "at [\"format\"]",
      "an instance listed twice": "listed twice",
      "a provider id used twice": "provider p-00-1 is listed twice",
      "a revision from a later epoch": "past the stored epoch",
      "a shared assignment": "share the state assignment",
      "a key naming an unknown instance": "unknown instance",
      "an intent revision without requested intent": "without requested intent",
      "error without a failure": "error without a failure",
    }.toTable
    check expected.len == cases.len
    for (name, bytes) in cases:
      checkpoint name
      let dir = freshDir()
      writeRaw(dir, bytes)
      let before = rawOf(dir)
      let r = openStore(dir)
      check r.isErr and expected[name] in r.error
      check rawOf(dir) == before
      # The failed open left the lock free.
      var (s2, _) = openStore(dir & "-other").tryGet
      s2.close()

  test "the directory is made 0700 and the snapshot 0600; group access is refused":
    when defined(posix):
      let dir = freshDir() / "nested"
      var (s, _) = openStore(dir).tryGet
      s.write(sample()).tryGet
      s.close()
      var st: Stat
      check stat(cstring(dir), st) == 0
      check (st.st_mode.cint and 0o777) == 0o700
      check stat(cstring(dir / SnapshotName), st) == 0
      check (st.st_mode.cint and 0o777) == 0o600
      check chmod(cstring(dir), 0o750) == 0
      let r = openStore(dir)
      check r.isErr
      check "group or other" in r.error
      check chmod(cstring(dir), 0o700) == 0
      check openStore(dir).isOk

  test "a second open of one directory is refused while the first holds it":
    let dir = freshDir()
    var (a, _) = openStore(dir).tryGet
    let b = openStore(dir)
    check b.isErr
    check "in use" in b.error
    a.close()
    var (c, _) = openStore(dir).tryGet
    c.close()

  test "a snapshot over MaxStoreBytes is refused and the old one stays":
    let dir = freshDir()
    var (s, _) = openStore(dir).tryGet
    s.write(sample()).tryGet
    let before = rawOf(dir)
    var big = sample()
    let constraints = encodeCbor(cbor(newSeq[byte](1_048_000)))
    for i in 0 ..< 70:
      var x = StoredInstance(
        instance: "big-" & $i,
        record: dynRecord("/opt/x.so"),
        state: msUnloaded,
        revision: 1,
        intent: inUninitialized,
      )
      x.record.requestedPermissions[0].constraints = constraints
      big.instances.add(x)
    let r = s.write(big)
    check r.isErr
    check "exceed" in r.error
    s.close()
    check rawOf(dir) == before

  test "a write the file system refuses fails and the old snapshot stays":
    when defined(posix):
      if getuid() != 0:
        let dir = freshDir()
        var (s, _) = openStore(dir).tryGet
        s.write(sample()).tryGet
        let before = rawOf(dir)
        check chmod(cstring(dir), 0o500) == 0
        var changed = sample()
        changed.epoch += 1
        check s.write(changed).isErr
        check chmod(cstring(dir), 0o700) == 0
        s.close()
        check rawOf(dir) == before

  test "side records: put, get, list, delete, and reaping at open":
    for persistent in [true, false]:
      checkpoint $persistent
      let dir = (if persistent: freshDir() else: "")
      var (s, _) = openStore(dir).tryGet
      check s.isPersistent == persistent
      let odd = "inst/with:oddéchars"
      s.putSide("cfg", odd, [1'u8, 2, 3]).tryGet
      s.putSide("cfg", "b", [4'u8]).tryGet
      s.putSide("other", "b", [5'u8]).tryGet
      check s.getSide("cfg", odd).tryGet == Opt.some(@[1'u8, 2, 3])
      check s.getSide("cfg", "none").tryGet.isNone
      s.putSide("cfg", odd, [9'u8]).tryGet
      check s.getSide("cfg", odd).tryGet == Opt.some(@[9'u8])
      var names: seq[string]
      for (i, _) in s.listSide("cfg").tryGet:
        names.add(i)
      check names.len == 2 and odd in names and "b" in names
      s.deleteSide("cfg", "b").tryGet
      check s.getSide("cfg", "b").tryGet.isNone
      check s.reapSides(toHashSet(["b"])).tryGet == @[odd]
      check s.getSide("cfg", odd).tryGet.isNone
      check s.getSide("other", "b").tryGet == Opt.some(@[5'u8])
      s.close()

  test "a side record whose name does not match its instance fails":
    let dir = freshDir()
    var (s, _) = openStore(dir).tryGet
    s.putSide("cfg", "a", [1'u8]).tryGet
    s.putSide("cfg", "b", [2'u8]).tryGet
    var a, b: string
    for name in fileNames(dir):
      if name.startsWith("cfg-"):
        if a.len == 0:
          a = name
        else:
          b = name
    # Each record now sits under the other instance's name.
    moveFile(dir / a, dir / "swap")
    moveFile(dir / b, dir / a)
    moveFile(dir / "swap", dir / b)
    check s.listSide("cfg").isErr
    s.close()

  test "[IMPL] names the store did not write are neither read nor reaped":
    # An exFAT or network volume adds AppleDouble `._<name>` files beside each
    # file; they are not side records, whatever they hold (I88).
    let dir = freshDir()
    var (s, _) = openStore(dir).tryGet
    s.putSide("cfg", "a", [1'u8]).tryGet
    var a: string
    for name in fileNames(dir):
      if name.startsWith("cfg-"):
        a = name
    let strangers = [
      "._" & a,
      "._runtime-state.cbor",
      "cfg-0000.cbor",
      "cfg-.cbor",
      a[0 ..^ 7] & ".cbor",
      "notes.txt",
    ]
    for name in strangers:
      writeFile(dir / name, "\x00\x05\x16\x07not cbor")
    var names: seq[string]
    for (i, _) in s.listSide("cfg").tryGet:
      names.add(i)
    check names == @["a"]
    check s.reapSides(initHashSet[string]()).tryGet == @["a"]
    for name in strangers:
      check fileExists(dir / name)
    s.close()

  test "[IMPL-DECISION G160] declaration facts leave out local_path and reason text":
    let a = dynRecord("/opt/a/sensor.so", Opt.some("to measure"))
    let b = dynRecord("/srv/b/sensor.so")
    check recordBytes(a) != recordBytes(b)
    check factBytes(a) == factBytes(b)
    var c = b
    c.artifact.hash[0] = 1
    check factBytes(c) != factBytes(b)
    var d = b
    d.requestedPermissions[0].constraints = encodeCbor(cbor(2'u64))
    check factBytes(d) != factBytes(b)
