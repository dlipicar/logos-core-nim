## The Package Manager module (Tier 5 step 5-6a-1; DECISIONS G490, G491, G494, G495;
## docs/PACKAGE-MANAGER.md §6): `logos_package_manager`'s handlers over the shell
## (`shell.nim`, G405), exported through its kit (`logos_package_manager_kit.nim`:
## PM App A, confined, the asynchronous provider API, G338). `logosd` composes it as
## the reserved `hosted_dynamic` instance `package_manager` (G491, C1), and the host
## configuration's top-level `package_manager` mark lets the Module Host accept its
## reserved name (G490).
##
## - **The four operations** (`inspect_package`, `install_package`, `remove_package`,
##   `update_package`) map onto the engine's requests in `requests.nim`, as
##   `pmtest_module` mapped them (G449).
## - **The answers** (G494): the worker's encoded response (`oaEncoded`) passes through
##   as pre-encoded bytes, which the boundary checks against the method's schema; an
##   engine response (`{error}` or `{}`) is encoded here; a full queue or an admission
##   bound (`oaModuleError`) is the invocation error MODULE_ERROR (PM l.1516-1517).
## - **A cancellation** the Runtime sends reaches the handler as `CancelledError`: the
##   shell cancels the operation in the engine, the handler logs one line and ends
##   CANCELLED (G338, G449). What the caller sees is the boundary's code.
## - **Readers** (5-6b-1; G498; C4): the protected input names them (`readers`, with the
##   Runtime their calls come from). A caller is a reader when it is an ordinary caller of
##   that Runtime and its module instance is listed; a SYSTEM_SERVICE caller never is.
##   The check runs first, before any filter, snapshot or cursor (PKG-0529), on every
##   call and page (PKG-0385). Visibility is all or nothing (PKG-0530): a reader sees
##   every record, a non-reader none.
## - **`get_runtime_handoff`** is served to a SYSTEM_SERVICE caller, the Runtime's own
##   binding (5-6a-2, G493), on the first worker; and to a reader (Q7 (b)) as a page job
##   on the read-only worker (G500, ruling A). Anyone else is refused.
## - **The lists** (`list_packages`, `list_installed_packages`; G499, G500) are served to
##   readers; their pages' bytes pass through as the engine framed them.
## - **`watch_installed_packages`** (5-6b-2; G501) is a reader's, at most `WatchesPerOrigin`
##   per caller and `WatchesAggregate` in all. It waits for a landed commit, then publishes
##   one `installed_packages_changed` (`{}`) through its own invocation's scope, never
##   broadcast; changes while a hint is in flight make one more. It ends CANCELLED when the
##   Runtime cancels it (the caller's cancel, a lost connection, a deadline: the provider
##   sees none of these but the cancel), at once, whether it waits or publishes; with `{}`
##   when a hint is not delivered or the Package Manager stops. Ending touches no operation.
## - **Progress** (5-6b-2; G502): an operation with a `progress_key` from a reader publishes
##   `operation_progress` with the key echoed through its invocation's scope, one in flight,
##   the latest report replacing a pending one, none after its answer. A non-reader's key
##   publishes nothing.
## - **Refusals** are MODULE_ERROR with no message or detail: a provider cannot answer
##   NOT_AUTHORISED (INTERFACE l.3308-3311; G495, Q6 (b)). The operator's log gets one
##   line naming the caller, the method and why: not a reader, or the bound it met
##   (Fable §11.2, point 1), so the log tells the causes of an opaque MODULE_ERROR apart.
##   The lines are limited for each caller (`refusals.nim`; Fable §17.3 point 3): the
##   same line again within a minute is counted, and written with its count after that.
## - **The stop**: the Runtime cancels the calls in flight first; `destroyModule` then
##   runs `closeShell`, which stops the engine and the worker (§4.1 of the plan).

{.push raises: [], gcsafe.}
{.used.}

import std/[monotimes, tables]
import results
import logos_sdk/cbor
from logos_sdk/base/logtext import oneLine
import ../package/records
import ./[logos_package_manager_kit, refusals, requests, shell]

export logos_package_manager_kit

const
  WatchesPerOrigin* = 4 ## [IMPL; G501] watches one caller holds at once
  WatchesAggregate* = 16 ## [IMPL; G501] watches in all

type
  PackageManager* = ref object
    shell: Shell
    log: ShellLog
    readers: seq[string] ## [G498] the protected input's
    runtime: string ## [G498] the Runtime readers' calls come from
    watches: Table[string, int] ## [G501] by origin (`keyOf`)
    watching: int ## [G501] in all
    refusals: RefusalLog ## [G495; Fable §17.3 point 3] the refusal lines, limited

  Progress = ref object
    ## [G502] One operation's progress publications: one in flight, the latest report
    ## replacing a pending one; none once the operation was answered or a publication
    ## failed.
    inv: Invocation
    key: string
    inflight: bool
    pending: Opt[ProgressReport]
    ended: bool

when defined(lcnTestHooks):
  import std/os
  from chronos import sleepAsync, milliseconds

  proc handoffHeld() {.async: (raises: [CancelledError]).} =
    ## [IMPL; plan §10.2, ruling 1] `test_system_binding`'s hold: while the file named
    ## by `LCN_TEST_HANDOFF_GATE` exists, a system-service `get_runtime_handoff` waits
    ## before the shell answers it, and appends a line to `<file>.held` as it begins to
    ## wait. A cancellation ends the wait. Test builds only.
    let gate = getEnv("LCN_TEST_HANDOFF_GATE")
    if gate.len == 0 or not fileExists(gate):
      return
    try:
      let f = open(gate & ".held", fmAppend)
      f.write("held\n")
      f.close()
    except CatchableError:
      discard
    while fileExists(gate):
      await sleepAsync(5.milliseconds)

# Answers ----------------------------------------------------------------------------------

func cancelled(): InvocationFailure =
  ## [G338; G449] A handler the kit cancelled (the Runtime's cancel, a stop): its
  ## operation was cancelled in the engine, and the call ends CANCELLED.
  failure(ecCancelled, "the operation was cancelled")

func refused(): InvocationFailure =
  ## [G495; Q6 (b)] A refused observation: MODULE_ERROR with no message and no detail,
  ## the only refusal a provider may answer (INTERFACE l.3308-3311). The reason is the
  ## operator's (`refuse`).
  InvocationFailure(code: ecModule)

proc answered(a: OperationAnswer): Result[PreEncoded, InvocationFailure] =
  ## [G494] An engine answer as the handler's response.
  case a.kind
  of oaResponse:
    ok(preEncoded(encodeCbor(a.response)))
  of oaModuleError:
    err(moduleError(a.reason))
  of oaEncoded:
    # The one copy (§4.2 of the plan): `OperationAnswer.encoded` is a string until 5-6b.
    var b = newSeq[byte](a.encoded.len)
    if b.len > 0:
      copyMem(addr b[0], unsafeAddr a.encoded[0], b.len)
    ok(preEncoded(move b))

func describe(c: Result[Caller, InvocationFailure]): string =
  ## The caller for the operator's log: its Runtime and module instance.
  if c.isErr:
    return "an unknown caller"
  let k = c.get
  case k.kind
  of ckModule:
    "module instance " & k.moduleInstance.get("?") & " of Runtime " & k.runtimeInstance
  of ckSystemService:
    "the system service of Runtime " & k.runtimeInstance

proc readerOf(m: PackageManager, inv: Invocation): Opt[Origin] =
  ## [G498; C4; PKG-0529] The caller as an origin, when it is a reader: an ordinary
  ## caller of the readers' Runtime whose module instance is listed. A SYSTEM_SERVICE
  ## caller never is.
  let c = inv.caller()
  if c.isErr:
    return Opt.none(Origin)
  let k = c.get
  if k.kind != ckModule or k.moduleInstance.isNone or m.runtime.len == 0 or
      k.runtimeInstance != m.runtime or k.moduleInstance.get notin m.readers:
    return Opt.none(Origin)
  Opt.some(Origin(runtime: k.runtimeInstance, instance: k.moduleInstance.get))

func keyOf(o: Origin): string =
  o.runtime & "\0" & o.instance

proc refuse(m: PackageManager, inv: Invocation, meth, why: string): InvocationFailure =
  ## [G495] One operator log line naming the caller, the method and why, limited for
  ## each caller (`refusals.nim`); the caller gets MODULE_ERROR with nothing more.
  let line =
    "package-manager: " & meth & " refused for " & oneLine(describe(inv.caller())) & ": " &
    why
  for l in m.refusals.admit(line, getMonoTime()):
    m.log(l)
  refused()

proc queried(
    m: PackageManager, inv: Invocation, meth: string, a: OperationAnswer
): Result[PreEncoded, InvocationFailure] =
  ## [G499, G500] A query's answer: a bound the engine met is MODULE_ERROR with no
  ## detail, and the log names it.
  if a.kind == oaModuleError:
    return err(m.refuse(inv, meth, a.reason))
  answered(a)

# Progress (G502) -------------------------------------------------------------------------

func phaseOf(p: ProgressPhase): LogosNSPackageManagerProgressPhase =
  type K = LogosNSPackageManagerProgressPhaseKind
  case p
  of ppResolving:
    LogosNSPackageManagerProgressPhase(kind: K.Resolving)
  of ppFetching:
    LogosNSPackageManagerProgressPhase(kind: K.Fetching)
  of ppVerifying:
    LogosNSPackageManagerProgressPhase(kind: K.Verifying)
  of ppInstalling:
    LogosNSPackageManagerProgressPhase(kind: K.Installing)
  of ppRemoving:
    LogosNSPackageManagerProgressPhase(kind: K.Removing)

proc publishing(
    m: PackageManager, p: Progress, first: ProgressReport
) {.async: (raises: []).} =
  ## [G502; PKG-0565, PKG-0567, PKG-0571, PKG-0572] Each report through the operation's
  ## own scope, the key echoed, the caller a reader at each publication; a failure ends
  ## the operation's progress.
  var r = first
  while true:
    if m.readerOf(p.inv).isNone:
      p.ended = true
      break
    let sent = await p.inv.publishScoped(
      LogosNSPackageManagerOperationProgressEvent(
        bytes_completed: r.completed,
        bytes_total: r.total,
        phase: phaseOf(r.phase),
        progress_key: p.key,
      )
    )
    if sent.isErr:
      p.ended = true
      break
    if p.ended or p.pending.isNone:
      break
    r = p.pending.get
    p.pending = Opt.none(ProgressReport)
  p.inflight = false

proc sinkOf(m: PackageManager, p: Progress): ProgressSink =
  proc(r: ProgressReport) {.gcsafe, raises: [].} =
    if p.ended:
      return
    if p.inflight:
      p.pending = Opt.some(r)
      return
    p.inflight = true
    asyncSpawn m.publishing(p, r)

proc operate(
    m: PackageManager,
    meth: string,
    op: OperationRequest,
    inv: Invocation = nil,
    progressKey = Opt.none(string),
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [G449] One operation through the shell. [G502; Q12 (a)] With a `progress_key` from a
  ## reader, its progress is published until the answer.
  var p: Progress = nil
  if progressKey.isSome and not inv.isNil and m.readerOf(inv).isSome:
    p = Progress(inv: inv, key: progressKey.get)
  let a =
    try:
      await m.shell.operate(
        op,
        if p.isNil:
          nil
        else:
          m.sinkOf(p),
      )
    except CancelledError:
      if not p.isNil:
        p.ended = true
      m.log("package-manager: " & meth & " cancelled by the Runtime")
      return err(cancelled())
  if not p.isNil:
    p.ended = true
  answered(a)

# The kit's hooks --------------------------------------------------------------------------

proc initModule*(
    _: type PackageManager, init: ModuleInit
): Result[PackageManager, InvocationFailure] =
  ## [G405] The shell, from the protected input (G400); the engine starts once
  ## `_MODULE_init` returned.
  let s = ?openShell(init, log = stderrLog)
  ok(
    PackageManager(
      shell: s, log: stderrLog, readers: s.readers, runtime: s.runtimeInstanceId
    )
  )

proc destroyModule*(m: PackageManager) {.async: (raises: []).} =
  ## [G437] After the Runtime ended the calls in flight: the engine and the worker stop.
  ## The refusals counted and not written yet are written first.
  for l in m.refusals.flush():
    m.log(l)
  await m.shell.closeShell()

proc `inspect_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerInspectPackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `inspect_package`, through the engine's slots (G449).
  let op = ?inspectOp(request)
  await m.operate("inspect_package", op)

proc `install_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerInstallPackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `install_package`; [G502] a reader's `progress_key` has its progress.
  let op = ?installOp(request)
  await m.operate("install_package", op, inv, request.progress_key)

proc `remove_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerRemovePackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `remove_package`; [G502] a reader's `progress_key` has its progress.
  await m.operate("remove_package", removeOp(request), inv, request.progress_key)

proc `update_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerUpdatePackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `update_package`; [G502] a reader's `progress_key` has its progress.
  let op = ?updateOp(request)
  await m.operate("update_package", op, inv, request.progress_key)

proc `get_runtime_handoff`*(
    m: PackageManager,
    request: LogosNSPackageManagerGetRuntimeHandoffRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §12; G493, G495, G500] Served to the Runtime's system-service binding on
  ## the first worker, and to a reader as a page job on the read-only worker (Q7 (b),
  ## ruling A); anyone else is refused.
  let c = inv.caller()
  if c.isOk and c.get.kind == ckModule:
    let o = m.readerOf(inv).valueOr:
      return err(m.refuse(inv, "get_runtime_handoff", "not a reader"))
    let a =
      try:
        await m.shell.readerHandoff(o, identityOf(request.package), request.module)
      except CancelledError:
        m.log("package-manager: get_runtime_handoff cancelled by the Runtime")
        return err(cancelled())
    return m.queried(inv, "get_runtime_handoff", a)
  if c.isErr or c.get.kind != ckSystemService:
    return err(m.refuse(inv, "get_runtime_handoff", "not a reader"))
  let a =
    try:
      when defined(lcnTestHooks):
        await handoffHeld()
      await m.shell.handoff(identityOf(request.package), request.module)
    except CancelledError:
      m.log("package-manager: get_runtime_handoff cancelled by the Runtime")
      return err(cancelled())
  answered(a)

proc `list_packages`*(
    m: PackageManager,
    request: LogosNSPackageManagerListPackagesRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15 l.1656-1657; G498, G499, G500] The catalog's listed entries, a page
  ## at a time, for a reader.
  let o = m.readerOf(inv).valueOr:
    return err(m.refuse(inv, "list_packages", "not a reader"))
  let a =
    try:
      await m.shell.listPackages(o, request.package, request.cursor, request.limit)
    except CancelledError:
      return err(cancelled())
  m.queried(inv, "list_packages", a)

proc `list_installed_packages`*(
    m: PackageManager,
    request: LogosNSPackageManagerListInstalledPackagesRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15 l.1659-1660; G498, G499, G500] One internally consistent snapshot of
  ## the installed set, a page at a time, for a reader: each page read on the read-only
  ## worker.
  let o = m.readerOf(inv).valueOr:
    return err(m.refuse(inv, "list_installed_packages", "not a reader"))
  let a =
    try:
      await m.shell.listInstalled(o, request.package, request.cursor, request.limit)
    except CancelledError:
      return err(cancelled())
  m.queried(inv, "list_installed_packages", a)

func watchEnded(): LogosNSPackageManagerWatchInstalledPackagesResponse =
  LogosNSPackageManagerWatchInstalledPackagesResponse(
    kind: LogosNSPackageManagerWatchInstalledPackagesResponseKind.Map
  )

proc observe(
    m: PackageManager, inv: Invocation
): Future[
    Result[LogosNSPackageManagerWatchInstalledPackagesResponse, InvocationFailure]
] {.async: (raises: []).} =
  ## [G501; PKG-0545..0562] The watch's loop. Its cancellation is seen while it waits and
  ## while a hint is in flight (`race`: the hint is not cancelled, the kit answers it).
  const meth = "watch_installed_packages"
  var seen = m.shell.changes
  while true:
    try:
      await m.shell.changedSince(seen)
    except CancelledError:
      m.log("package-manager: " & meth & " cancelled by the Runtime")
      return err(cancelled())
    if m.shell.closing:
      return ok(watchEnded())
    seen = m.shell.changes
    # [PKG-0550] At publication admission the caller is still a reader; then every
    # committed change is observable to it (PKG-0530), a removal included.
    if m.readerOf(inv).isNone:
      return err(m.refuse(inv, meth, "not a reader"))
    let hint = inv.publishScoped(LogosNSPackageManagerInstalledPackagesChangedEvent())
    try:
      discard await race(FutureBase(hint))
    except CancelledError:
      m.log("package-manager: " & meth & " cancelled by the Runtime")
      return err(cancelled())
    let sent = await hint
    if sent.isErr:
      m.log(
        "package-manager: " & meth & " for " & oneLine(describe(inv.caller())) &
          " ended: a hint was not delivered: " & $sent.error.code & " " &
          oneLine(sent.error.message.get(""))
      )
      return ok(watchEnded())

proc `watch_installed_packages`*(
    m: PackageManager,
    request: LogosNSPackageManagerWatchInstalledPackagesRequest,
    inv: Invocation,
): Future[
    Result[LogosNSPackageManagerWatchInstalledPackagesResponse, InvocationFailure]
] {.async: (raises: []).} =
  ## [SPEC PM §15.1; G501] A reader's watch: one hint per landed commit, coalesced while
  ## one is in flight, through this invocation's scope, until the Runtime cancels it, a
  ## hint is not delivered or the Package Manager stops.
  const meth = "watch_installed_packages"
  let o = m.readerOf(inv).valueOr:
    return err(m.refuse(inv, meth, "not a reader"))
  let k = keyOf(o)
  let mine = m.watches.getOrDefault(k)
  if mine >= WatchesPerOrigin:
    return err(
      m.refuse(
        inv,
        meth,
        "at the watch bound: " & $WatchesPerOrigin & " in flight for this caller",
      )
    )
  if m.watching >= WatchesAggregate:
    return err(
      m.refuse(
        inv, meth, "at the watch bound: " & $WatchesAggregate & " in flight in all"
      )
    )
  m.watches[k] = mine + 1
  inc m.watching
  # A watch is long-lived: the operator's log shows each, and what it holds of the bounds.
  m.log(
    "package-manager: " & meth & " admitted for " & oneLine(describe(inv.caller())) &
      ": " & $(mine + 1) & " of " & $WatchesPerOrigin & " for this caller, " &
      $m.watching & " of " & $WatchesAggregate & " in all"
  )
  let ended = await m.observe(inv)
  dec m.watching
  let left = m.watches.getOrDefault(k) - 1
  if left > 0:
    m.watches[k] = left
  else:
    m.watches.del(k)
  ended

exportLogosPackageManager(PackageManager)
