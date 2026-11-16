## Offline administration of module state (Tier 4b step 4b-7, part 7c;
## DECISIONS G143 as re-decided 2026-11-15, I96): what `logosctl state list`
## and `logosctl state purge` do, with the Runtime stopped.
##
## Both read the Runtime's store under its lock (`store.openStore`: refused
## while a Runtime holds it) and never write its snapshot: the engine stays
## its only writer. A purge removes the preserved state directory of a
## retired instance (RUNTIME l.3587-3588: retirement is not deletion; this is
## the separately authorized disposal, BCP l.394-395): the directory is first
## renamed to a `+purge-…` name and `state_root` flushed, then removed without
## following any link, so an interrupted purge leaves a name the next start
## removes (`engine.sweepTransfers`). The tombstone keeps reserving the
## assignment: it is never reused.
##
## Every proc returns its failure; none raises.

{.push raises: [], gcsafe.}

import std/[algorithm, os, strutils, sysrand, tables]
import results
import ../iface/outcome
import ./[statexfer, store]

export results, outcome

type
  Holder* = enum
    hoLive = "live" ## a known instance's assignment
    hoRetired = "retired" ## a tombstone's, kept reserved
    hoNone = "none" ## a directory no instance and no tombstone names
    hoUnfinished = "unfinished" ## a `+transfer-…` or `+purge-…` name

  StateEntry* = object ## One line of `state list`.
    name*: string ## the assignment, or the reserved name
    holder*: Holder
    instance*: string ## the live or retired holder; empty for none
    present*: bool ## a directory (or a link to one) is there
    link*: bool ## it is a symbolic link
    bytes*: uint64 ## regular files' bytes; links inside are not followed
    files*: uint64
    origin*: string ## "from a (a-state), move": how its state came
    moved*: string ## "to b, move": where its state went

  StateError* = object
    code*: ErrorCode
      ## INVALID_PARAMS: refused; NOT_READY: a transfer is owed; MODULE_ERROR: the
      ## store or the file system failed
    message*: string

  Purged* = object
    assignment*: string
    dir*: string
    removed*: bool ## false: there was no directory
    bytes*: uint64
    files*: uint64

func stateError(code: ErrorCode, message: string): StateError =
  StateError(code: code, message: message)

type Opened = object
  store: Store
  snap: Snapshot
  xfers: OrderedTable[string, XferRecord] ## target → record

proc open(storeDir: string): Result[Opened, StateError] =
  ## The store, locked, and what the snapshot and the transfer records say.
  ## A missing store is not created.
  if not dirExists(storeDir):
    return err(stateError(ecInvalidParams, "there is no Runtime store at " & storeDir))
  let (st, snap) = openStore(storeDir).valueOr:
    return err(stateError(ecModule, "the Runtime store: " & error))
  var o = Opened(store: st, snap: snap.get(Snapshot()))
  let sides = o.store.listSide(XferSide).valueOr:
    o.store.close()
    return err(stateError(ecModule, "the Runtime store cannot be read: " & error))
  for (id, data) in sides:
    let r = xferOf(data).valueOr:
      o.store.close()
      return err(
        stateError(ecModule, "the transfer record of " & id & " is malformed: " & error)
      )
    o.xfers[id] = r
  ok(o)

proc usage(dir: string): (uint64, uint64) =
  ## Regular files' bytes and count under `dir`; links inside are not
  ## followed, and what cannot be read is left out.
  var bytes, files = 0'u64
  try:
    for f in walkDirRec(dir, yieldFilter = {pcFile}, followFilter = {pcDir}):
      bytes += uint64(max(getFileSize(f), 0))
      inc files
  except CatchableError:
    discard
  (bytes, files)

func assignmentOf(o: Opened, instance: string, retired = false): Opt[string] =
  ## A live instance's assignment; with `retired`, a tombstone's too (a
  ## target's transfer record is kept with its tombstone: owner's condition 4).
  for x in o.snap.instances:
    if x.instance == instance:
      return x.record.stateAssignment
  if retired:
    for r in o.snap.retired:
      if r.instance == instance:
        return r.stateAssignment
  Opt.none(string)

proc listState*(storeDir, stateRoot: string): Result[seq[StateEntry], StateError] =
  ## [G143] Every assignment the store names and every directory in
  ## `state_root`, by name: its holder, size and transfer provenance.
  var o = ?open(storeDir)
  defer:
    o.store.close()
  var byName = initOrderedTable[string, StateEntry]()
  template at(n: string): var StateEntry =
    byName.mgetOrPut(n, StateEntry(name: n, holder: hoNone))

  for x in o.snap.instances:
    if x.record.stateAssignment.isSome:
      let n = x.record.stateAssignment.get
      at(n).holder = hoLive
      at(n).instance = x.instance
  for r in o.snap.retired:
    if r.stateAssignment.isSome:
      let n = r.stateAssignment.get
      if at(n).holder == hoNone:
        at(n).holder = hoRetired
        at(n).instance = r.instance
  var names: seq[string] = @[]
  try:
    for f in walkDir(stateRoot, relative = true):
      names.add(f.path)
  except CatchableError as e:
    return err(stateError(ecModule, "the state root cannot be read: " & e.msg))
  for n in names:
    if isReserved(n):
      at(n).holder = hoUnfinished
    else:
      at(n).name = n # a directory no instance names: `none`
  for target, r in o.xfers:
    let to = o.assignmentOf(target, retired = true)
    let mode = $r.mode
    if to.isSome and to.get in byName:
      at(to.get).origin = "from " & r.source & " (" & r.sourceAssignment & "), " & mode
    if r.sourceAssignment in byName:
      at(r.sourceAssignment).moved = "to " & target & ", " & mode
  var found: seq[StateEntry] = @[]
  for name, e in byName:
    var e = e
    let kind = entryKind(dirOf(stateRoot, name))
    e.present = kind in {ekDir, ekLinkToDir}
    e.link = kind == ekLinkToDir
    if e.present:
      (e.bytes, e.files) = usage(dirOf(stateRoot, name))
    found.add(e)
  found.sort(
    proc(a, b: StateEntry): int =
      cmp(a.name, b.name)
  )
  ok(found)

func validName(s: string): bool =
  ## An assignment's alphabet (`realizer.pathSafe`), so the directory is
  ## inside `state_root` and never a reserved name.
  s.len > 0 and s notin [".", ".."] and
    s.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'})

proc purgeName(): Result[string, string] =
  var b: array[16, byte]
  if not urandom(b):
    return err("no random bytes for the purge's name")
  var s = PurgePrefix
  for x in b:
    s.add(toHex(int(x), 2).toLowerAscii)
  ok(s)

proc purgeState*(
    storeDir, stateRoot: string,
    instance = Opt.none(string),
    assignment = Opt.none(string),
    configured: seq[string] = @[],
): Result[Purged, StateError] =
  ## [G143; I96; owner's condition 3] Removes the preserved state directory
  ## of the retired `instance`, or, with `assignment`, a directory that no
  ## instance and no tombstone holds. Refused for a live instance, for an
  ## assignment one of `configured` (the deployment's own) names, for a
  ## symbolic link, and while a state transfer from it is owed. Windows:
  ## MODULE_ERROR.
  when not defined(posix):
    return err(stateError(ecModule, "purge is not supported on this platform"))
  else:
    if instance.isSome == assignment.isSome:
      return err(stateError(ecInvalidParams, "name an instance or an assignment"))
    var o = ?open(storeDir)
    defer:
      o.store.close()
    var name = ""
    if instance.isSome:
      let id = instance.get
      for x in o.snap.instances:
        if x.instance == id:
          return err(
            stateError(
              ecInvalidParams,
              "instance " & id & " is live: retire it first (retirement is not deletion)",
            )
          )
      for r in o.snap.retired:
        if r.instance == id:
          if r.stateAssignment.isNone:
            return err(
              stateError(
                ecInvalidParams, "instance " & id & " kept no state assignment"
              )
            )
          name = r.stateAssignment.get
      if name.len == 0:
        return
          err(stateError(ecInvalidParams, "instance " & id & " was never retired here"))
    else:
      name = assignment.get
      if not validName(name):
        return err(stateError(ecInvalidParams, "not a state assignment: " & name))
      for x in o.snap.instances:
        if x.record.stateAssignment == Opt.some(name):
          return err(
            stateError(
              ecInvalidParams,
              "the assignment " & name & " is live instance " & x.instance &
                "'s: retire it first (retirement is not deletion)",
            )
          )
      for r in o.snap.retired:
        if r.stateAssignment == Opt.some(name):
          return err(
            stateError(
              ecInvalidParams,
              "the assignment " & name & " is retired instance " & r.instance &
                "'s: purge it by its instance",
            )
          )
    if name in configured:
      return err(
        stateError(
          ecInvalidParams,
          "the configuration names the assignment " & name & " for one of its instances",
        )
      )
    for target, r in o.xfers:
      # [owner's condition 3] The next start still owes this transfer's rename.
      # Only a live target is owed one: a retired target's directory may be
      # purged, and its source must stay purgeable.
      let to = o.assignmentOf(target)
      if r.sourceAssignment == name and to.isSome and
          entryKind(dirOf(stateRoot, to.get)) == ekMissing:
        return err(
          stateError(
            ecNotReady,
            "the state transfer from " & name & " to " & target &
              " is not complete: start the Runtime once to complete it",
          )
        )
    let dir = dirOf(stateRoot, name)
    case entryKind(dir)
    of ekMissing:
      return ok(Purged(assignment: name, dir: dir, removed: false))
    of ekLinkToDir:
      return err(
        stateError(
          ecInvalidParams,
          dir & " is a symbolic link: remove it and its target yourself",
        )
      )
    of ekOther:
      return err(stateError(ecInvalidParams, dir & " is not a directory"))
    of ekDir:
      discard
    let (bytes, files) = usage(dir)
    let aside = purgeName().valueOr:
      return err(stateError(ecModule, error))
    moveDir(stateRoot, name, aside).isOkOr:
      return err(stateError(ecModule, error))
    removeTree(stateRoot, aside).isOkOr:
      return err(
        stateError(
          ecModule,
          error & "; the rest is removed at the next start (" & dirOf(stateRoot, aside) &
            ")",
        )
      )
    ok(Purged(assignment: name, dir: dir, removed: true, bytes: bytes, files: files))
