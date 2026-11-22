## Durable remote disables (Tier 5 step 5-7a-2; DECISIONS G412; Q4 as planning
## ruled; 5-7a plan §3.8). docs/DAEMON.md §6b, docs/REMOTE.md.
##
## A listener's `enabled` or `runtime_control_enabled`, or an export's
## `enabled`, turned off through Runtime Control stays off across restarts and
## crashes; an enable through Runtime Control lasts for the run. The fields
## turned off are kept in `<session>/state/remote-exposure.cbor`
## (`remote_exposure.cddl`), one entry per key, with the digest of the
## configuration's entry for that key as that run started:
##
## - **The engine's write** (`persistHook`, set through
##   `host.runtimeSetRemoteHooks`): on the Runtime Control call's own thread,
##   with the engine's remote lock held, so writes never overlap. The entry
##   becomes the fields the requested record has off; none removes it. A
##   disable has already turned the exposure off for the run when it writes;
##   an enable writes before it turns anything on (`invoke.remoteWork`).
## - **At start** (`applyRetained`, from compose): each entry whose digest
##   matches its configuration entry now is applied, so that record starts
##   with those fields off; any other entry (its entry changed or gone, or
##   the record was one Runtime Control made) is dropped, and logosd rewrites
##   the file.
## - **Offline**: `logosctl remote exposure list` and `reset`, under the
##   session lock, applying at the next start.

{.push raises: [].}

import std/[algorithm, os, strutils, tables, times]
import results
import logos_sdk/crypto/blake3
import ../durable
import ../runtime/host
import ./[daemon_config_types, remote_exposure_types, session]

export remote_exposure_types

when defined(lcnTestHooks):
  const ExposureFailVar* = "LCN_REMOTE_TEST_EXPOSURE_FAIL_FILE"
    ## [plan §3.8; lcnTestHooks builds only] while the file this names
    ## exists, every write of the exposure file fails

const
  RemoteExposureName* = "remote-exposure.cbor"
  RemoteExposureFile* = "state/" & RemoteExposureName
  MaxExposureBytes = 16 * 1024 * 1024 ## [IMPL]

type
  ExposureKey* = tuple[listener: seq[byte], provider: string]
    ## a listener (`provider` empty) or one of its exports

  Retained* = object ## What a start did with the file's entries (`applyRetained`).
    kept*: seq[LcnRemoteExposureEntry] ## applied: the record starts with them off
    dropped*: seq[LcnRemoteExposureEntry] ## no matching configuration entry

  ExposureSinkObj = object
    stateDir: string
    digests: Table[ExposureKey, seq[byte]]

  ExposureSink* = ptr ExposureSinkObj
    ## The engine's write: what `persistHook` reads. Read only once made.

func remoteExposurePath*(s: Session): string =
  s.stateDir / RemoteExposureName

func keyOf*(e: LcnRemoteExposureEntry): ExposureKey =
  (e.listener, e.provider.get(""))

func cmpBytes(a, b: openArray[byte]): int =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return cmp(a[i], b[i])
  cmp(a.len, b.len)

func cmpKey*(a, b: ExposureKey): int =
  ## Listener bytes first, then the provider (none first).
  result = cmpBytes(a.listener, b.listener)
  if result == 0:
    result = cmp(a.provider, b.provider)

func fieldOf(f: LcnRemoteExposureField): ExposureField =
  case f.kind
  of LcnRemoteExposureFieldKind.Enabled: efEnabled
  of LcnRemoteExposureFieldKind.Runtime_control_enabled: efRuntimeControl

func fieldChoice(f: ExposureField): LcnRemoteExposureField =
  case f
  of efEnabled:
    LcnRemoteExposureField(kind: LcnRemoteExposureFieldKind.Enabled)
  of efRuntimeControl:
    LcnRemoteExposureField(kind: LcnRemoteExposureFieldKind.Runtime_control_enabled)

func offOf*(e: LcnRemoteExposureEntry): set[ExposureField] =
  for f in e.off:
    result.incl(fieldOf(f))

func offText*(off: set[ExposureField]): string =
  var names: seq[string]
  for f in off:
    names.add($f)
  names.join(" and ")

# The address --------------------------------------------------------------------------------

proc addressOf*(listener: openArray[byte]): Result[LcnRcRemoteListenerAddress, string] =
  LcnRcRemoteListenerAddress.decode(listener)

proc listenerKey*(a: LcnRcRemoteListenerAddress): Result[seq[byte], string] =
  ## The address as the engine keys it: its deterministic CBOR, as
  ## `remoterecords.addressKey`.
  a.encode

func addressText*(a: LcnRcRemoteListenerAddress): string =
  ## The whole address, as `remote exposure list` prints it and `reset`
  ## takes it: `tls-tcp host:port` or `quic host:port`, then each optional
  ## field present as ` name=value`.
  case a.kind
  of LcnRcRemoteListenerAddressKind.lcn_Rc_tls_tcp_runtime_address:
    let t = a.arm_lcn_Rc_tls_tcp_runtime_address
    result = "tls-tcp " & t.host & ":" & $t.port
    if t.server_name.isSome:
      result.add(" server_name=" & t.server_name.get)
    if t.profile.isSome:
      result.add(" profile=" & t.profile.get)
  of LcnRcRemoteListenerAddressKind.lcn_Rc_quic_runtime_address:
    let q = a.arm_lcn_Rc_quic_runtime_address
    result = "quic " & q.host & ":" & $q.port
    if q.server_name.isSome:
      result.add(" server_name=" & q.server_name.get)
    if q.alpn.isSome:
      result.add(" alpn=" & q.alpn.get)
    if q.profile.isSome:
      result.add(" profile=" & q.profile.get)

proc entryText*(e: LcnRemoteExposureEntry): string =
  ## One line of `remote exposure list` and of the start's log.
  let a = addressOf(e.listener)
  let where = if a.isOk: a.get.addressText else: "an address that does not decode"
  result =
    (if e.provider.isSome: "export of " & e.provider.get & " on "
    else: "listener ") & where & ": " & offText(e.offOf) & " off since " &
    $fromUnix(int64(e.at_ms div 1000)).utc & " by " & e.by

# The file -----------------------------------------------------------------------------------

proc checkEntries(entries: openArray[LcnRemoteExposureEntry]): Result[void, string] =
  for i, e in entries:
    if e.off.len == 0:
      return err("an entry turns no field off")
    for j in 1 ..< e.off.len:
      if ord(fieldOf(e.off[j - 1])) >= ord(fieldOf(e.off[j])):
        return err("an entry's fields are not ascending")
    if e.provider.isSome and e.offOf != {efEnabled}:
      return err("an export entry turns off another field than enabled")
    addressOf(e.listener).isOkOr:
      return err("an entry's listener is not a listener address: " & error)
    if i > 0 and cmpKey(entries[i - 1].keyOf, e.keyOf) >= 0:
      return err("the entries are not ascending by key, or a key repeats")
  ok()

proc readExposure*(stateDir: string): Result[seq[LcnRemoteExposureEntry], string] =
  ## The file's entries; none when it is absent. A file that is not one
  ## (`remote_exposure.cddl`, and the order and the fields) is an error.
  let bytes = ?readSessionFile(stateDir / RemoteExposureName, MaxExposureBytes)
  if bytes.isNone:
    return ok(newSeq[LcnRemoteExposureEntry]())
  let x = LcnRemoteExposure.decode(bytes.get).valueOr:
    return err(RemoteExposureFile & " is not a remote exposure file: " & error)
  checkEntries(x.entries).isOkOr:
    return err(RemoteExposureFile & ": " & error)
  ok(x.entries)

proc readExposure*(s: Session): Result[seq[LcnRemoteExposureEntry], string] =
  readExposure(s.stateDir)

proc writeExposure*(
    stateDir: string, entries: openArray[LcnRemoteExposureEntry]
): Result[void, string] =
  ## Replaces the file durably (temp, fsync, rename, fsync of the directory);
  ## no entry removes it.
  when defined(lcnTestHooks):
    let fail = getEnv(ExposureFailVar)
    if fail.len > 0 and fileExists(fail):
      return err("the test hook fails the write")
  var sorted = @entries
  sorted.sort(
    proc(a, b: LcnRemoteExposureEntry): int =
      cmpKey(a.keyOf, b.keyOf)
  )
  ?checkEntries(sorted)
  if sorted.len == 0:
    return removeDurably(stateDir, RemoteExposureName)
  let bytes = ?LcnRemoteExposure(entries: sorted).encode
  writeAtomic(stateDir, RemoteExposureName, bytes)

proc writeExposure*(
    s: Session, entries: openArray[LcnRemoteExposureEntry]
): Result[void, string] =
  writeExposure(s.stateDir, entries)

# At start -----------------------------------------------------------------------------------

proc configDigests*(x: LcnDcRemote): Result[Table[ExposureKey, seq[byte]], string] =
  ## The BLAKE3-256 of each configuration entry's deterministic CBOR, by key.
  var t: Table[ExposureKey, seq[byte]]
  for r in x.listeners.get(@[]):
    t[(?listenerKey(r.address), "")] = @(blake3(?r.encode))
  for e in x.exports.get(@[]):
    t[(?listenerKey(e.listener), e.provider.provider)] = @(blake3(?e.encode))
  ok(t)

proc applyRetained*(
    x: var LcnDcRemote, entries: openArray[LcnRemoteExposureEntry]
): Result[Retained, string] =
  ## [Q4] The configuration's records with each retained disable whose
  ## configuration entry is unchanged applied; the others dropped.
  let digests = ?configDigests(x)
  var r: Retained
  for e in entries:
    let want = digests.getOrDefault(e.keyOf, @[])
    if e.config.isNone or want.len == 0 or e.config.get != want:
      r.dropped.add(e)
      continue
    let off = e.offOf
    if e.provider.isNone:
      var ls = x.listeners.get
      for i in 0 ..< ls.len:
        if ?listenerKey(ls[i].address) == e.listener:
          if efEnabled in off:
            ls[i].enabled = false
          if efRuntimeControl in off:
            ls[i].runtime_control_enabled = false
      x.listeners = Opt.some(ls)
    else:
      var xs = x.exports.get
      for i in 0 ..< xs.len:
        if ?listenerKey(xs[i].listener) == e.listener and
            xs[i].provider.provider == e.provider.get:
          xs[i].enabled = false
      x.exports = Opt.some(xs)
    r.kept.add(e)
  ok(r)

# The engine's write -------------------------------------------------------------------------

proc nowMs(): uint64 =
  let t = getTime()
  uint64(t.toUnix) * 1000 + uint64(t.nanosecond div 1_000_000)

proc record*(
    stateDir: string,
    digests: Table[ExposureKey, seq[byte]],
    listener: seq[byte],
    provider: string,
    off: set[ExposureField],
    consumer: string,
): Result[void, string] =
  ## [Q4] The entry for the key becomes `off`, by `consumer`, now; none
  ## removes it.
  var entries = ?readExposure(stateDir)
  let key: ExposureKey = (listener, provider)
  var kept: seq[LcnRemoteExposureEntry]
  for e in entries:
    if cmpKey(e.keyOf, key) != 0:
      kept.add(e)
  if off.len > 0:
    var e = LcnRemoteExposureEntry(
      listener: listener,
      provider: (if provider.len > 0: Opt.some(provider)
      else: Opt.none(string)),
      by: (if consumer.len > 0: consumer else: "an unnamed consumer"),
      at_ms: nowMs(),
    )
    for f in off:
      e.off.add(fieldChoice(f))
    let d = digests.getOrDefault(key, @[])
    if d.len > 0:
      e.config = Opt.some(d)
    kept.add(e)
  writeExposure(stateDir, kept)

proc persistHook(
    data: pointer,
    listener: seq[byte],
    provider: string,
    off: set[ExposureField],
    consumer: string,
): Result[void, string] {.nimcall, gcsafe, raises: [].} =
  let sink = cast[ExposureSink](data)
  {.cast(gcsafe).}:
    record(sink.stateDir, sink.digests, listener, provider, off, consumer)

proc newExposureSink*(s: Session, x: LcnDcRemote): Result[ExposureSink, string] =
  ## The engine's write for this run: the digests of the configuration as it
  ## started.
  let digests = ?configDigests(x)
  let sink = createShared(ExposureSinkObj)
  sink.stateDir = s.stateDir
  sink.digests = digests
  ok(sink)

func persist*(sink: ExposureSink): RemotePersist =
  if sink == nil: nil else: persistHook

proc closeExposureSink*(sink: ExposureSink) =
  ## Once the Runtime is destroyed.
  if sink != nil:
    reset(sink[])
    freeShared(sink)

# Offline ------------------------------------------------------------------------------------

proc resetExposure*(
    s: Session, listener = "", provider = "", all = false
): Result[seq[LcnRemoteExposureEntry], string] =
  ## [Q4] `logosctl remote exposure reset`: the entries removed, those of the
  ## listener whose address text is `listener` (its own, or with `provider`
  ## its export of `provider`), or every one with `all`.
  let entries = ?readExposure(s)
  var keep, removed: seq[LcnRemoteExposureEntry]
  for e in entries:
    var hit = all
    if not hit:
      let a = addressOf(e.listener)
      hit = a.isOk and a.get.addressText == listener and e.provider.get("") == provider
    if hit:
      removed.add(e)
    else:
      keep.add(e)
  if removed.len > 0:
    ?writeExposure(s, keep)
  ok(removed)

{.pop.}
