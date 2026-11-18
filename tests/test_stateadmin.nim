## Offline administration of module state (`runtime/stateadmin.nim`; Tier 4b
## step 4b-7, part 7c; DECISIONS G143 as re-decided 2026-11-15, I96): what
## `logosctl state list` and `state purge` do. Stores are written directly
## (`store.nim`), as a stopped Runtime leaves them; state directories live in
## the worktree's `build/` (renames and modes need POSIX semantics).

import std/[os, sequtils, strutils]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/runtime/[plumbing, records, stateadmin, statexfer, store]
import logos_sdk/testing/kitbuild

let work = currentSourcePath().parentDir.parentDir / "build" / "stateadmin" / kitVariant
removeDir(work)
createDir(work)

var bases = 0

proc freshBase(): string =
  inc bases
  result = work / ("s" & $bases)
  createDir(result / "state")

proc storeOf(base: string): string =
  base / "store"

proc rootOf(base: string): string =
  base / "state"

proc stateOf(base, assignment: string): string =
  base / "state" / assignment

func rec(assignment: string): ModuleRecord =
  ModuleRecord(
    module: "holder_module",
    strategy: stDirectStatic,
    binding: "holder",
    stateAssignment: Opt.some(assignment),
  )

proc live(id, assignment: string, n: uint64): StoredInstance =
  let ep = 3_000_000'u64
  StoredInstance(
    instance: id,
    record: rec(assignment),
    state: msUnloaded,
    revision: (ep shl 32) + n,
    intent: inUninitialized,
  )

proc writeStore(
    base: string,
    instances: seq[StoredInstance],
    retired: seq[RetiredId],
    xfers: seq[(string, XferRecord)] = @[],
) =
  var (s, _) = openStore(storeOf(base)).tryGet
  s.write(
    Snapshot(
      runtimeInstanceId: "rt-admin",
      epoch: 3_000_000,
      instances: instances,
      retired: retired,
    )
  ).tryGet
  for (id, r) in xfers:
    s.putSide(XferSide, id, xferBytes(r).tryGet).tryGet
  s.close()

proc snapshotBytes(base: string): string =
  readFile(storeOf(base) / SnapshotName)

proc fill(dir: string, files: openArray[(string, string)]) =
  createDir(dir)
  for (name, text) in files:
    createDir(parentDir(dir / name))
    writeFile(dir / name, text)

proc asRoot(): bool =
  when defined(posix):
    getuid() == 0
  else:
    true

proc setMode(path: string, mode: int) =
  when defined(posix):
    doAssert chmod(cstring(path), Mode(mode)) == 0

proc reserved(base: string): seq[string] =
  var found: seq[string] = @[]
  for f in walkDir(rootOf(base), relative = true):
    if isReserved(f.path):
      found.add(f.path)
  found

proc layout(): string =
  ## `a` live with `a-state`; `r` retired with `r-state`; `m` retired, its
  ## state moved to the live `b`; `gone` retired without a directory; `c`
  ## retired after `r`'s state was copied to it (its record kept with its
  ## tombstone); an operator's `orphan`; an unfinished staging name.
  let base = freshBase()
  writeStore(
    base,
    @[live("a", "a-state", 1), live("b", "b-state", 2)],
    @[
      RetiredId(instance: "r", stateAssignment: Opt.some("r-state")),
      RetiredId(instance: "m", stateAssignment: Opt.some("m-state")),
      RetiredId(instance: "gone", stateAssignment: Opt.some("gone-state")),
      RetiredId(instance: "nothing", stateAssignment: Opt.none(string)),
      RetiredId(instance: "c", stateAssignment: Opt.some("c-state")),
    ],
    @[
      (
        "b",
        XferRecord(
          source: "m", sourceAssignment: "m-state", mode: tmMove, epoch: 3_000_000
        ),
      ),
      (
        "c",
        XferRecord(
          source: "r",
          sourceAssignment: "r-state",
          mode: tmCopy,
          bytes: 5,
          files: 1,
          epoch: 3_000_000,
        ),
      ),
    ],
  )
  fill(stateOf(base, "a-state"), [("data", "aaaa")])
  fill(stateOf(base, "b-state"), [("data", "bb"), ("sub/more", "bbb")])
  fill(stateOf(base, "r-state"), [("data", "rrrrr")])
  fill(stateOf(base, "c-state"), [("data", "rrrrr")])
  fill(stateOf(base, "orphan"), [])
  fill(stateOf(base, stagingName("z-state")), [("half", "x")])
  base

suite "run.state: offline state list and purge (G143; I96, part 7c)":
  test "[IMPL-DECISION G143] state list: every assignment and directory with its holder, size and provenance":
    let base = layout()
    let before = snapshotBytes(base)
    let xs = listState(storeOf(base), rootOf(base)).tryGet
    check xs.mapIt(it.name) ==
      @[
        stagingName("z-state"), "a-state", "b-state", "c-state", "gone-state",
        "m-state", "orphan", "r-state",
      ]
    proc at(name: string): StateEntry =
      for x in xs:
        if x.name == name:
          return x

    check at("a-state").holder == hoLive and at("a-state").instance == "a"
    check at("a-state").present and at("a-state").bytes == 4 and at("a-state").files == 1
    check at("b-state").bytes == 5 and at("b-state").files == 2
    check at("b-state").origin == "from m (m-state), move"
    check at("m-state").holder == hoRetired and at("m-state").instance == "m"
    check not at("m-state").present
    check at("m-state").moved == "to b, move"
    check at("r-state").holder == hoRetired and at("r-state").present
    # A retired target keeps its provenance (owner's condition 4).
    check at("c-state").holder == hoRetired and at("c-state").instance == "c"
    check at("c-state").origin == "from r (r-state), copy"
    check at("r-state").moved == "to c, copy"
    check at("gone-state").holder == hoRetired and not at("gone-state").present
    check at("orphan").holder == hoNone and at("orphan").instance == ""
    check at(stagingName("z-state")).holder == hoUnfinished
    # Nothing written.
    check snapshotBytes(base) == before

  test "[IMPL-DECISION G143] state list and purge: refused while a Runtime holds the store, and without one":
    let base = layout()
    var (held, _) = openStore(storeOf(base)).tryGet
    let r = listState(storeOf(base), rootOf(base))
    check r.isErr and r.error.code == ecModule and "in use" in r.error.message
    let p = purgeState(storeOf(base), rootOf(base), instance = Opt.some("r"))
    check p.isErr and p.error.code == ecModule
    held.close()
    check dirExists(stateOf(base, "r-state"))
    let none = listState(base / "no-store", rootOf(base))
    check none.isErr and none.error.code == ecInvalidParams
    check not dirExists(base / "no-store")

  test "[IMPL-DECISION G143] [RUN-1020] [BCP-0092] state purge: a retired instance's directory is removed; its tombstone keeps the assignment":
    when not defined(posix):
      let base = layout()
      let r = purgeState(storeOf(base), rootOf(base), instance = Opt.some("r"))
      check r.isErr and r.error.code == ecModule
      check dirExists(stateOf(base, "r-state"))
    else:
      let base = layout()
      let before = snapshotBytes(base)
      # `c`, the copy's target, is retired and its directory gone: no rename
      # is owed to it, so `r` stays purgeable.
      removeDir(stateOf(base, "c-state"))
      let p = purgeState(storeOf(base), rootOf(base), instance = Opt.some("r")).tryGet
      check p.removed and p.assignment == "r-state"
      check p.bytes == 5 and p.files == 1
      check not dirExists(stateOf(base, "r-state"))
      check reserved(base) == @[stagingName("z-state")]
      check snapshotBytes(base) == before
      let xs = listState(storeOf(base), rootOf(base)).tryGet
      check xs.anyIt(it.name == "r-state" and it.holder == hoRetired and not it.present)
      # Again: nothing left to remove.
      let again =
        purgeState(storeOf(base), rootOf(base), instance = Opt.some("r")).tryGet
      check not again.removed
      # A directory no instance names.
      let o =
        purgeState(storeOf(base), rootOf(base), assignment = Opt.some("orphan")).tryGet
      check o.removed and not dirExists(stateOf(base, "orphan"))

  test "[IMPL-DECISION G143] state purge refusals: live state, unknown names, configured assignments, links":
    when not defined(posix):
      skip()
      break
    let base = layout()
    proc refused(
        instance = Opt.none(string),
        assignment = Opt.none(string),
        configured: seq[string] = @[],
        text: string,
    ): bool =
      let r = purgeState(storeOf(base), rootOf(base), instance, assignment, configured)
      result = r.isErr and r.error.code == ecInvalidParams and text in r.error.message
      if not result:
        echo "purge: ", r

    check refused(instance = Opt.some("a"), text = "is live: retire it first")
    check refused(instance = Opt.some("zz"), text = "was never retired")
    check refused(instance = Opt.some("nothing"), text = "kept no state assignment")
    check refused(assignment = Opt.some("a-state"), text = "live instance a's")
    check refused(assignment = Opt.some("r-state"), text = "purge it by its instance")
    check refused(assignment = Opt.some("../x"), text = "not a state assignment")
    check refused(
      assignment = Opt.some(stagingName("z-state")), text = "not a state assignment"
    )
    check refused(
      instance = Opt.some("r"),
      configured = @["r-state"],
      text = "the configuration names",
    )
    check refused(text = "name an instance or an assignment")
    check refused(
      instance = Opt.some("r"),
      assignment = Opt.some("orphan"),
      text = "name an instance",
    )
    # A link: its target is the operator's to remove.
    let elsewhere = base / "elsewhere"
    fill(elsewhere, [("data", "kept")])
    removeDir(stateOf(base, "r-state"))
    createSymlink(elsewhere, stateOf(base, "r-state"))
    check refused(instance = Opt.some("r"), text = "is a symbolic link")
    check readFile(elsewhere / "data") == "kept"
    check dirExists(stateOf(base, "a-state")) and dirExists(stateOf(base, "orphan"))

  test "[IMPL-DECISION I96] state purge is refused while a state transfer from the assignment is owed (owner's condition 3)":
    when not defined(posix):
      skip()
      break
    let base = layout()
    # The rename to `b` is owed: `b-state` is missing and `m-state` is there.
    removeDir(stateOf(base, "b-state"))
    fill(stateOf(base, "m-state"), [("data", "m's")])
    let r = purgeState(storeOf(base), rootOf(base), instance = Opt.some("m"))
    check r.isErr and r.error.code == ecNotReady
    check "start the Runtime once to complete it" in r.error.message
    check readFile(stateOf(base, "m-state") / "data") == "m's"
    # Once `b`'s directory is there, `m`'s leftover may go.
    fill(stateOf(base, "b-state"), [])
    check purgeState(storeOf(base), rootOf(base), instance = Opt.some("m")).tryGet.removed

  test "[IMPL-DECISION G143] state purge removes what the module locked itself out of, and follows no link inside":
    when not defined(posix):
      skip()
      break
    if asRoot():
      skip()
      break
    let base = layout()
    let dir = stateOf(base, "r-state")
    fill(dir, [("locked/inner/f", "x"), ("closed/g", "y")])
    let outside = base / "outside"
    fill(outside, [("keep", "kept")])
    createSymlink(outside, dir / "link")
    setMode(dir / "locked" / "inner", 0o500)
    setMode(dir / "closed", 0)
    check purgeState(storeOf(base), rootOf(base), instance = Opt.some("r")).tryGet.removed
    check not dirExists(dir)
    check readFile(outside / "keep") == "kept"
    check reserved(base) == @[stagingName("z-state")]
