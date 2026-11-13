## The reference orchestration module's retry accounting (DECISIONS I94;
## RUNTIME l.3511, l.3789; C-9).
##
## One file, `<state directory>/orchestrator-state.cbor`
## (`logos-core-nim.orchestrator-state.v1`, `state.cddl`): one episode per
## instance and intent revision. Only charged calls are written, each before it
## is made (write-ahead) and again when it is answered; uncharged calls are
## spaced in memory (I94). The file survives orchestration restart, Runtime
## restart and lost answers (l.3789), so a file that does not decode or breaks
## a rule fails the module's start: it never starts over with lost accounting.
## The operator's remedy is to delete it (docs/HOST-CONFIG.md), which resets the
## accounting.
##
## The directory is locked (`durable.acquire`) for the instance's lifetime: a
## second orchestration instance on the same state directory is refused.

{.push raises: [], gcsafe.}

import std/[algorithm, os, tables]
import results
import ../durable
import ./[policy, settings, state_types]

export results

const
  StateFileName* = "orchestrator-state.cbor"
  StateFormat* = "logos-core-nim.orchestrator-state.v1"
  MaxStateBytes* = 1 shl 20 ## [IMPL] `readBounded`
  MaxEntries* = 4096 ## [IMPL] episodes in one file

type Accounting* = object
  dir*: string ## empty: no state directory, nothing is written
  runtimeId*: Opt[string]
  entries*: Table[string, Entry]

func toInt64(v: uint64): int64 =
  if v > uint64(high(int64)):
    high(int64)
  else:
    int64(v)

proc decodeState*(data: openArray[byte]): Result[Accounting, string] =
  ## The accounting a file holds, checked: its schema, at most 4096 entries,
  ## one per instance.
  let st = LcnOrchState.decode(data).valueOr:
    return err("not a " & StateFormat & " value: " & error)
  if st.format != StateFormat:
    return err("the format is not " & StateFormat)
  if st.entries.len > MaxEntries:
    return err("more than 4096 entries")
  var a = Accounting(runtimeId: st.runtime_instance_id)
  for e in st.entries:
    if e.instance in a.entries:
      return err("two entries for " & e.instance)
    a.entries[e.instance] = Entry(
      module: e.module,
      instance: e.instance,
      intentRevision: e.intent_revision,
      attempts: int64(e.attempts),
      calls: toInt64(e.calls),
      lastCallAt: (
        if e.last_call_at.isSome:
          Opt.some(toInt64(e.last_call_at.get))
        else:
          Opt.none(int64)
      ),
      pending: e.pending,
      exhausted: e.exhausted.get(false),
    )
  ok(a)

proc encodeState*(a: Accounting): Result[seq[byte], string] =
  ## The file's bytes: deterministic CBOR, entries ordered by instance.
  var names: seq[string]
  for k in a.entries.keys:
    names.add(k)
  names.sort()
  var st = LcnOrchState(format: StateFormat, runtime_instance_id: a.runtimeId)
  for n in names:
    let e = a.entries.getOrDefault(n)
    st.entries.add(
      LcnOrchEntry(
        instance: e.instance,
        module: e.module,
        intent_revision: e.intentRevision,
        attempts: uint32(clamp(e.attempts, 0'i64, int64(high(uint32)))),
        calls: uint64(max(e.calls, 0)),
        last_call_at: (
          if e.lastCallAt.isSome:
            Opt.some(uint64(max(e.lastCallAt.get, 0)))
          else:
            Opt.none(uint64)
        ),
        pending: e.pending,
        exhausted: (if e.exhausted: Opt.some(true) else: Opt.none(bool)),
      )
    )
  encode(st)

proc openAccounting*(
    stateDir: Opt[string], s: Settings
): Result[(Accounting, DurableLock), string] =
  ## [SPEC RUNTIME l.3789; I94] The directory locked and its file loaded. No
  ## state directory is accepted only when every policy is disabled; then
  ## nothing is counted.
  if stateDir.isNone or stateDir.get.len == 0:
    if s.needsStateDir:
      return err(
        "the orchestration module needs a state directory for its retry " &
          "accounting (RUNTIME l.3789)"
      )
    return ok((Accounting(), DurableLock()))
  let dir = stateDir.get
  ?ensurePrivateDir(dir)
  var lock = ?acquire(dir)
  let path = dir / StateFileName
  let bytes = readBounded(path, MaxStateBytes).valueOr:
    lock.release()
    return err(path & ": " & error)
  if bytes.isNone:
    return ok((Accounting(dir: dir), lock))
  var a = decodeState(bytes.get).valueOr:
    lock.release()
    return err(path & ": " & error)
  a.dir = dir
  ok((a, lock))

proc save*(a: Accounting): Result[void, string] =
  ## Replaces the file durably; nothing without a state directory.
  if a.dir.len == 0:
    return ok()
  let bytes = ?encodeState(a)
  writeAtomic(a.dir, StateFileName, bytes)

proc checkRuntime*(a: var Accounting, runtimeId: string): bool =
  ## [I94] The file belongs to the Runtime `get_self` named: a different id
  ## (a new store) discards every entry; true when it did. A file without one
  ## takes the id.
  if a.runtimeId.isSome and a.runtimeId.get == runtimeId:
    return false
  let discarded = a.runtimeId.isSome and a.entries.len > 0
  if a.runtimeId.isSome:
    a.entries.clear()
  a.runtimeId = Opt.some(runtimeId)
  discarded

proc placeOnClock*(a: var Accounting, s: Settings, nowWall, nowMono: int64) =
  ## [IMPL; I94] Each loaded `last_call_at` placed on the monotonic clock,
  ## its remaining delay clamped to `0..delay` (`monoOfLastCall`).
  for e in a.entries.mvalues:
    if e.lastCallAt.isSome:
      let d = delay(s.restartFor(e.instance).backoff, e.calls)
      e.lastCallMono = Opt.some(monoOfLastCall(e.lastCallAt.get, d, nowWall, nowMono))

{.pop.}
