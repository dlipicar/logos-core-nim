## logosd's start, steps 4 to 10 (Tier 4b step 4b-6; DECISIONS G294, G302;
## C28): what `src/logosd.nim`'s `main`, `test_ctl_module` and 4b-8's
## deployment suite call in-process. `logosd.nim` holds the process part:
## the session, its lock, the signal mask and thread, the wait, the exit.
## docs/DAEMON.md §4.
##
## `assembleDaemon` runs steps 4 to 9: the daemon-config and its five checks,
## the trust file's rules and decision (G396), the evidence key's binding
## (check 4), `run/` and the socket path, then `runtimeCreate` with the
## derived app-config, the two static bindings, the termination hook, the
## call-evidence store as the call record sink (G301), the presentation
## handoff, the orchestrator's diagnostics and the selected test hooks.
## Nothing has started when it returns. `startDaemon` is step 10;
## `finishDaemon` the destroy after the wait.

{.push raises: [].}

import std/[monotimes, os, strutils, times]
import results
import logos_sdk/abi/host as abihost
import logos_sdk/abi/types
import logos_sdk/iface/outcome
import ../orchestration
import ../runtime/host
from ../runtime/plumbing import DefaultShutdownGrace
from ../runtime/store import SnapshotName
from ../transport/io/sock import fitsSunPath, sunPathMax
from ../durable import ensurePrivateDir
import
  ./[compose, ctlmodule, diagdrain, evstore, logging, session, supervise, trustfile]

when defined(posix):
  import std/posix

when defined(lcnTestHooks):
  from ../runtime/plumbing import LoaderFaults
  from ../runtime/engine import setLoaderFaultsForTests, diagnoseForTests

export results, compose, diagdrain, supervise

const
  DestroyExtraMs* = 5_000 ## [IMPL] destroy is retried for the grace plus this
  ExitClean* = 0
  ExitRefused* = 1 ## usage, session, configuration, trust or key binding
  ExitStartFailed* = 2 ## create, register or start
  ExitShutdownError* = 3 ## the shutdown or destroy reported an error
  ExitLoaderLost* = 4 ## [G302] the Module Loader failed after start

type
  StartError* = object
    exit*: int
    message*: string

  AssembleOptions* = object
    exe*: string ## logosd's executable, for the default `module_host`
    version*: string
    hooksBuild*: bool = HooksBuild
    notify*: NotifyFn ## the supervisor's notification; nil: SIGUSR1

  Daemon* = object ## An assembled logosd: a created Runtime, not started.
    session*: Session
    prepared*: Prepared
    trust*: TrustFileState
    signing*: TrustInput
      ## [G396] the package-signing trust input the start accepted, for the
      ## Package Manager (step 5-3b); nothing reads it before then
    rt*: ptr LogosRuntimeHandle
    supervisor*: Supervisor
    store*: EvidenceStore ## [G301] nil: no `call_audit.store`
    socketPath*: string
    startedAtMs*: uint64
    graceMs*: int
    diagnostics*: Drain ## [I95 amended 2026-11-16] the Runtime's, into the log

func startError(exit: int, message: string): StartError =
  StartError(exit: exit, message: message)

func production*(d: Daemon): bool =
  not d.trust.file.development

func designation*(d: Daemon): string =
  if d.production: "production" else: "NON-PRODUCTION"

proc text(r: LogosResult): string =
  let code = errorCode(int64(r.code)).get(ecModule)
  result = $code
  if r.message != nil and r.message[0] != '\0':
    result.add(": " & $r.message)

proc ok(r: LogosResult): bool =
  int64(r.code) == 0

proc orchestratorSink(line: string) {.nimcall, gcsafe, raises: [].} =
  logInfo("orchestrator: " & line)

proc storeLog(line: string) {.nimcall, gcsafe, raises: [].} =
  logWarn(line)

proc startEvidenceKeys(
    s: Session, c: DaemonConfig, seen: TrustFileState
): Result[seq[seq[byte]], string] =
  ## [G397] The session's evidence keys, the configured one included, when
  ## the trust file names an anchor.
  if c.value.call_audit.isSome and c.value.call_audit.get.evidence.isSome:
    let e = c.value.call_audit.get.evidence.get
    return startEvidenceKeys(s, seen, e.secret_key_file, e.kid)
  startEvidenceKeys(s, seen)

proc openEvidenceStore(s: Session, c: DaemonConfig): Result[EvidenceStore, string] =
  ## [G301] The store `call_audit.store` configures (check 4 made sure the
  ## evidence key is configured too); nil when there is none.
  if c.store.isNone:
    return ok(EvidenceStore(nil))
  let st = c.store.get
  openStore(
    StoreOptions(
      dir: s.evidenceDir,
      producer: c.value.runtime.runtime_instance_id,
      kid: c.value.call_audit.get.evidence.get.kid,
      maxRecords: st.maxRecords,
      maxAgeDays: st.maxAgeDays,
      queue: st.queue,
      log: storeLog,
    )
  )

proc register(
    rt: ptr LogosRuntimeHandle, id: string, table: openArray[(string, pointer)]
): LogosResult =
  var names = newSeq[string](table.len)
  var symbols = newSeq[LogosRuntimeNativeSymbol](table.len)
  for i in 0 ..< table.len:
    names[i] = table[i][0]
  for i in 0 ..< table.len:
    symbols[i] = LogosRuntimeNativeSymbol(
      name: cstring(names[i]), address: cast[LogosRuntimeSymbolAddress](table[i][1])
    )
  var b = LogosRuntimeNativeBinding(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeNativeBinding)),
    binding: cstring(id),
    symbols: cast[ptr UncheckedArray[LogosRuntimeNativeSymbol]](addr symbols[0]),
    symbolCount: csize_t(symbols.len),
  )
  runtimeRegisterBinding(rt, addr b)

proc removeStaleSocket(path: string): Result[void, string] =
  ## [IMPL] A socket a killed logosd left in a moved `ctl.socket_dir` (`run/`
  ## is emptied anyway). Only a socket of this user is removed; anything else
  ## at the path refuses the start.
  when defined(posix):
    var st: Stat
    if lstat(cstring(path), st) != 0:
      return ok()
    if not S_ISSOCK(st.st_mode) or st.st_uid != getuid():
      return err(path & " exists and is not a socket of this user")
    if unlink(cstring(path)) != 0:
      return err(path & ": " & $strerror(errno))
  ok()

proc prepareRunDir(s: Session, socketDir: string): Result[string, string] =
  ## Step 7: `run/` recreated without following links; the socket's
  ## directory owner-only; its path within `sun_path`.
  ?resetRunDir(s)
  if socketDir.len > 0:
    ensurePrivateDir(socketDir).isOkOr:
      return err("ctl.socket_dir: " & error)
  let path = s.socketPath(socketDir)
  if not fitsSunPath(path):
    let what = if socketDir.len > 0: "ctl.socket_dir" else: "the session directory"
    return err(
      "the socket path " & path & " is longer than sun_path (" & $(sunPathMax() - 1) &
        " bytes): choose a shorter " & what & " (ctl.socket_dir)"
    )
  if socketDir.len > 0:
    ?removeStaleSocket(path)
  ok(path)

proc assembleDaemon*(
    s: Session, opts: AssembleOptions = AssembleOptions()
): Result[Daemon, StartError] =
  ## Steps 4 to 9. The caller holds the session lock.
  let (_, bytes) = readDaemonConfig(s).valueOr:
    return err(startError(ExitRefused, error))
  # [RUNTIME l.2630-2632; I95] `init` made the store; logosd never makes one.
  # A new store under this session's fixed Runtime id would give the old
  # instances' addresses to unrelated ones.
  if not entryExists(s.storeDir / SnapshotName):
    return err(
      startError(
        ExitRefused,
        "the Runtime state store is missing (" & s.storeDir / SnapshotName &
          "): this session's Runtime id cannot name a new one; restore state/ " &
          "from a backup, or make a new session with logosctl init",
      )
    )
  # [G396] Both reads of the trust file apply its rules.
  let seen = checkedTrust(s).valueOr:
    return err(startError(ExitRefused, "the trust file: " & error))
  let prepared = prepareDaemon(
    s, bytes, seen, hooksBuild = opts.hooksBuild, checkKey = true, exe = opts.exe
  ).valueOr:
    return err(startError(ExitRefused, error))
  let evidenceKeys = startEvidenceKeys(s, prepared.config, seen).valueOr:
    return err(startError(ExitRefused, "the evidence keys: " & error))
  # [G299] The mark moves before the revision is used, never created here,
  # and nothing is refused after it moved (a change since the first read
  # included).
  let accepted = establishTrust(s, evidenceKeys, Opt.some(seen.digest)).valueOr:
    return err(startError(ExitRefused, "the trust file: " & error))
  let trust = accepted.state
  if trust.file.development:
    logWarn(
      "NON-PRODUCTION: the development switch is on (trust revision " &
        $trust.file.revision & "); this deployment is not a production one"
    )
  let c = prepared.config
  let path = prepareRunDir(s, c.ctl.socketDir).valueOr:
    return err(startError(ExitRefused, error))
  let cliArt = cliArtifact(c, opts.exe)
  if cliArt.isSome:
    # [G344] lcn_call's socket: its directory owner-only, its path within
    # `sun_path`; lcn_call binds it when the first launcher starts it.
    if c.cli.socketDir.len > 0:
      ensurePrivateDir(c.cli.socketDir).isOkOr:
        return err(startError(ExitRefused, "cli.socket_dir: " & error))
    let cliPath = cliSocketPath(s, c)
    if not fitsSunPath(cliPath):
      return err(
        startError(
          ExitRefused,
          "the CLI socket path " & cliPath & " is longer than sun_path (" &
            $(sunPathMax() - 1) & " bytes): choose a shorter cli.socket_dir",
        )
      )
    logInfo(
      "lcn_call: the CLI module is " & cliArt.get.local_path &
        (if c.cli.artifact.isSome: " (cli.artifact)" else: " (installed with logosd)")
    )
  else:
    logInfo("lcn_call: no CLI module (no cli.artifact and no compiled library hash)")
  if c.pm.isSome:
    # [G399; ruling C3] Which resolver limits this start composed, and where
    # they came from: the operator's log only (PM l.1514).
    logInfo(pmStartLine(c.pm.get))
  # Step 9.
  let comp = prepared.composition
  var cfg = LogosRuntimeConfig(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeConfig)),
    configurationFormat: AppConfigFormat,
    configuration: cast[ptr UncheckedArray[uint8]](unsafeAddr comp.bytes[0]),
    configurationLen: csize_t(comp.bytes.len),
  )
  var rt: ptr LogosRuntimeHandle = nil
  let created = runtimeCreate(addr cfg, addr rt)
  if not created.ok:
    return err(startError(ExitStartFailed, "create: " & created.text))
  template undo(message: string) =
    discard runtimeDestroy(rt)
    return err(startError(ExitStartFailed, message))

  for (id, table) in [
    (OrchestratorBinding, orchestratorStaticSymbols()), (CtlBinding, ctlStaticSymbols())
  ]:
    let r = register(rt, id, table)
    if not r.ok:
      undo("register " & id & ": " & r.text)
  let sv =
    if opts.notify.isNil:
      newSupervisor()
    else:
      newSupervisor(opts.notify)
  let hooked = runtimeSetTerminationHook(rt, terminationHook, sv)
  if not hooked.ok:
    freeSupervisor(sv)
    undo("the termination hook: " & hooked.text)
  let store = openEvidenceStore(s, c).valueOr:
    freeSupervisor(sv)
    discard runtimeDestroy(rt)
    return err(startError(ExitRefused, "the call-evidence store: " & error))
  if store != nil:
    let sunk = runtimeSetCallRecordSink(rt, evidenceSink, store)
    if not sunk.ok:
      closeStore(store)
      freeSupervisor(sv)
      undo("the call record sink: " & sunk.text)
    logInfo(
      "call-evidence store: boot " & $store.boot & ", next seq " & $store.base & " in " &
        s.evidenceDir
    )
  let started = uint64(toUnix(getTime()) * 1000 + getTime().nanosecond div 1_000_000)
  setPresentation(
    Presentation(
      socketPath: path,
      workers: c.ctl.workers,
      idleTimeoutMs: c.ctl.idleTimeoutMs,
      production: not trust.file.development,
      trustRevision: trust.file.revision,
      version: opts.version,
      startedAtMs: started,
    )
  )
  setOrchestratorDiagnostics(orchestratorSink)
  when defined(lcnTestHooks):
    setCommandDelayForTests(int(c.hooks.ctlCommandDelayMs.get(0)))
  let grace = c.value.runtime.shutdown_grace_ms
  ok(
    Daemon(
      session: s,
      prepared: prepared,
      trust: trust,
      signing: accepted.signing,
      rt: rt,
      supervisor: sv,
      store: store,
      socketPath: path,
      startedAtMs: started,
      graceMs:
        if grace.isSome:
          int(grace.get)
        else:
          int(DefaultShutdownGrace.inMilliseconds),
    )
  )

proc destroyRuntime*(d: var Daemon): Result[void, string] =
  ## [RUN-0761] Destroy, retried with backoff while module code is still
  ## running, for at most the grace plus `DestroyExtraMs`.
  if d.rt == nil:
    return ok()
  let until = getMonoTime() + initDuration(milliseconds = d.graceMs + DestroyExtraMs)
  var pause = 1
  var r = runtimeDestroy(d.rt)
  while not r.ok and errorCode(int64(r.code)).get(ecModule) == ecNotReady and
      getMonoTime() < until:
    sleep(pause)
    pause = min(pause * 2, 100)
    r = runtimeDestroy(d.rt)
  if not r.ok:
    return err("destroy: " & r.text)
  d.rt = nil
  ok()

proc release*(d: var Daemon) =
  ## What the daemon holds besides the Runtime: the handoff, the supervisor
  ## and the call-evidence store. After a successful destroy, or at a
  ## Loader-loss exit. With the Runtime not destroyed, its sink may still be
  ## called: the store is only stopped (written out), not freed.
  clearPresentation()
  setOrchestratorDiagnostics(nil)
  if d.rt == nil:
    freeSupervisor(d.supervisor)
    d.supervisor = nil
    closeStore(d.store)
    d.store = nil
  else:
    stop(d.store)

proc startDaemon*(d: var Daemon): Result[void, StartError] =
  ## Step 10: `runtimeStart`, which returns once orchestration is `ready`
  ## (RUNTIME l.3838, l.3939). A failed start runs the host sequence before it
  ## reports: request shutdown, wait, destroy (RUNTIME l.3989, l.3837).
  let r = runtimeStart(d.rt)
  if r.ok:
    logInfo(
      "ready: runtime " & d.prepared.config.value.runtime.runtime_instance_id &
        ", socket " & d.socketPath & ", trust revision " & $d.trust.file.revision & ", " &
        d.designation
    )
    # [I95 amended 2026-11-16] What bootstrap recorded, a state transfer's
    # line among it.
    d.diagnostics.drainNow(d.rt)
    return ok()
  let message = "start: " & r.text
  discard runtimeRequestShutdown(d.rt)
  discard runtimeWaitForShutdown(d.rt)
  d.diagnostics.drainNow(d.rt) # why the start failed, as the Runtime saw it
  discard destroyRuntime(d)
  err(startError(ExitStartFailed, message))

when defined(lcnTestHooks):
  proc failLoaderForTests*(rt: ptr LogosRuntimeHandle): Result[void, string] =
    ## [G300] `test_hooks.loader_failure_after_ms`'s action: the Module Loader
    ## reports its own failure now.
    let e = engineOf(rt)
    if e == nil:
      return err("no engine")
    e.setLoaderFaultsForTests(LoaderFaults(reportFailure: true)).isOkOr:
      return err(error.message)
    ok()

  proc diagnoseForTests*(
      rt: ptr LogosRuntimeHandle, text: string, count: int
  ): Result[void, string] =
    ## [I95 amended 2026-11-16] `test_hooks.diagnostics`'s action: `count`
    ## diagnostics holding `text`, as the Runtime records text it did not
    ## write, attributed to `test_hooks`.
    let e = engineOf(rt)
    if e == nil:
      return err("no engine")
    e.diagnoseForTests(text, "test_hooks", count)
    ok()

{.pop.}
