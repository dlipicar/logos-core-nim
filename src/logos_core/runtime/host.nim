## RUNTIME §13: the Host Embedding API. `liblogos_runtime` exports these six
## procs under their C names; a Nim host can call them directly.
##
## The handle (`HostRuntime`) lives on the shared heap and holds plain values
## only: the configuration bytes and the registered symbol tables as copies, a
## lock and condition, the call-order flags, the stored shutdown result and,
## once started, the engine. Everything decoded from them is decoded again on
## the thread that needs it, so no thread frees memory another thread's heap
## made (refc).
##
## Results [SPEC RUNTIME §13.4]. A message and detail live in this thread's
## storage until its next call into this API (RUN-0764), never in the handle,
## so a result of `logos_runtime_destroy` stays readable. `LOGOS_OK` carries
## none. [IMPL] A thread's storage ends when the thread does (reading R4).
##
## Validation order in every function [IMPL, the G171 class]: null pointers,
## then the structure's version and size, then call order, then content.
##
## [IMPL] Readings of §13.4 (DECISIONS I81):
## - R1: a `request_shutdown` that overlaps `start` (which l.4082 forbids) is
##   still accepted, and `start` returns CANCELLED.
## - R2: a `start` that fails before the engine exists is still the one
##   attempt: registration is closed, and `destroy` needs a request first.
## - R3: `wait_for_shutdown` from a Runtime-owned thread or from inside module
##   code is NOT_READY.

{.push raises: [].}

import std/[locks, os, sets]
when defined(posix):
  import std/posix
import results
import ../abi/[host, types]
import ../iface/outcome
import ./[callside, engine, evidence, host_config, native]
from ../crypto/cose import MaxCoseKidBytes
from ../authority/facts import SharedFacts, newSharedFacts, freeSharedFacts
from ../authority/provider import
  AuthorityWiring, caStaticRegistration, unwireAuthority, wireAuthority
from ./authscopes import AuthorityModule
import ../base/testhooks

export host, outcome.ErrorCode

testHooksMarker("host")

const
  MaxConfigurationBytes* = 64 * 1024 * 1024
    ## [IMPL] the largest configuration `create` reads
  MaxSymbols* = 65_536 ## [IMPL] the most entries one binding table may have

when defined(lcnTestHooks):
  type PolicyHook* = proc(): AuthzPolicy {.nimcall, gcsafe, raises: [].}
    ## A test hook (D27 revised; I89): the authority policy `start` gives the
    ## engine in place of the configured one. Neither the C API nor the
    ## configuration can reach it (SECURITY l.532).

type
  SymbolCopy = object
    name: cstring
    address: pointer

  BindingCopy = object
    id: cstring
    symbols: ptr UncheckedArray[SymbolCopy]
    count: int
    next: ptr BindingCopy

  EvidenceKeyBox = object
    ## [SPEC CA l.1272-1276; CAP-0230] The call-evidence key, read at
    ## `create`; overwritten at `destroy`.
    key: SecretKey
    kid: array[MaxCoseKidBytes, byte]
    kidLen: int

  HostRuntime = object
    lock: Lock
    cond: Cond
    config: ptr UncheckedArray[byte]
    configLen: int
    bindings: ptr BindingCopy
    startAttempted: bool
    shutdownRequested: bool
    shutdownDone: bool
    resultCode: ErrorCode
    resultMessage: array[MaxMessageBytes + 1, char]
    engine: Engine
    when defined(lcnTestHooks):
      policyHook: PolicyHook
    facts: SharedFacts
      ## [I85] under `capability-authority`, the attribute source the engine
      ## feeds and the authority reads; freed at `destroy`
    wired: cstring
      ## [I85] the authority's state directory while it is wired; nil otherwise
    evidence: ptr EvidenceKeyBox ## [I85] `call_audit.evidence`; nil: none
    producer: cstring
      ## [I85] the Runtime identity the engine settled: the evidence producer

# Per-thread results ---------------------------------------------------------------

var
  hostMessage {.threadvar.}: array[MaxMessageBytes + 1, char]
  hostDetail {.threadvar.}: array[MaxDetailBytes, uint8]

proc answer(code: ErrorCode, message = "", detail = Opt.none(seq[byte])): LogosResult =
  ## [SPEC RUNTIME §13.4] A result whose message and detail live in this
  ## thread's storage.
  result = LogosResult(code: CErrorCode(ord(code)))
  if code == ecOk:
    return
  if message.len > 0:
    let m = clip(message)
    for i, c in m:
      hostMessage[i] = c
    hostMessage[m.len] = '\0'
    result.message = cast[cstring](addr hostMessage[0])
  if code == ecInvalidParams and detail.isSome and detail.get.len in 1 .. MaxDetailBytes:
    let d = detail.get
    for i, b in d:
      hostDetail[i] = b
    result.detail = cast[ptr UncheckedArray[uint8]](addr hostDetail[0])
    result.detailLen = csize_t(d.len)

template entry() =
  ## Every function: the thread is registered with this library's runtime,
  ## and its previous result ends here.
  bindingEnter()
  hostMessage[0] = '\0'

# Shared-heap copies ---------------------------------------------------------------

proc copyText(s: string): cstring =
  let p = cast[ptr UncheckedArray[char]](allocShared(s.len + 1))
  for i, c in s:
    p[i] = c
  p[s.len] = '\0'
  cast[cstring](p)

proc freeBindings(b: ptr BindingCopy) =
  var b = b
  while b != nil:
    let next = b.next
    for i in 0 ..< b.count:
      deallocShared(b.symbols[i].name)
    if b.symbols != nil:
      deallocShared(b.symbols)
    deallocShared(b.id)
    deallocShared(b)
    b = next

proc entries(b: ptr BindingCopy): seq[(string, pointer)] =
  for i in 0 ..< b.count:
    result.add(($b.symbols[i].name, b.symbols[i].address))

proc hostOf(rt: ptr LogosRuntimeHandle): ptr HostRuntime =
  cast[ptr HostRuntime](rt)

proc storeResult(h: ptr HostRuntime, code: ErrorCode, message: string) =
  ## Under `h.lock`.
  h.resultCode = code
  let m = clip(message)
  for i, c in m:
    h.resultMessage[i] = c
  h.resultMessage[m.len] = '\0'

proc storedResult(h: ptr HostRuntime): LogosResult =
  ## Under `h.lock`: the stored result in this thread's storage.
  answer(h.resultCode, $cast[cstring](addr h.resultMessage[0]))

# Construction -----------------------------------------------------------------------

proc runtimeCreate*(
    config: ptr LogosRuntimeConfig, outRuntime: ptr ptr LogosRuntimeHandle
): LogosResult =
  ## [SPEC RUNTIME §13.2, §13.3] Validates the configuration and makes a handle;
  ## starts no thread and runs no module code. [I85] The one file it opens is
  ## `call_audit.evidence`'s key, whose checks are part of the configuration's.
  entry()
  if outRuntime == nil:
    return answer(ecInvalidParams, "out_runtime is null")
  outRuntime[] = nil # [SPEC RUNTIME §13.4] before anything else (RUN-0755)
  if config == nil:
    return answer(ecInvalidParams, "config is null")
  # [SPEC RUNTIME §13.1] The version and size before any other field
  # (RUN-0719); nothing past version 1's fields is read (RUN-0720, RUN-0721).
  if config.abiVersion != RuntimeHostAbiVersion:
    return answer(ecVersionMismatch, "unsupported logos_runtime_config_t abi_version")
  if config.structSize < csize_t(RuntimeConfigV1Extent):
    return answer(
      ecVersionMismatch, "logos_runtime_config_t struct_size is below version 1's"
    )
  if config.configurationFormat == nil:
    return answer(ecInvalidParams, "configuration_format is null")
  let format = $config.configurationFormat
  if format.len == 0:
    return answer(ecInvalidParams, "configuration_format is empty")
  if config.configuration == nil and config.configurationLen != 0:
    return
      answer(ecInvalidParams, "configuration is null and configuration_len is not 0")
  if config.configurationLen > csize_t(MaxConfigurationBytes):
    return answer(ecInvalidParams, "the configuration is larger than 64 MiB")
  let n = int(config.configurationLen)
  var bytes = newSeq[byte](n)
  for i in 0 ..< n:
    bytes[i] = config.configuration[i]
  let c = parseHostConfig(format, bytes).valueOr:
    return answer(ecInvalidParams, error.message, error.detail)
  var box: ptr EvidenceKeyBox = nil
  if c.evidence.isSome:
    let setting = c.evidence.get
    var key = loadEvidenceKey(setting.secretKeyFile).valueOr:
      return answer(ecInvalidParams, "call_audit.evidence: " & error)
    box = createShared(EvidenceKeyBox)
    box.key = key
    clear(key)
    for i, b in setting.kid:
      box.kid[i] = b
    box.kidLen = setting.kid.len
  let h = createShared(HostRuntime)
  h.evidence = box
  initLock(h.lock)
  initCond(h.cond)
  if n > 0:
    h.config = cast[ptr UncheckedArray[byte]](allocShared(n))
    copyMem(h.config, addr bytes[0], n)
  h.configLen = n
  outRuntime[] = cast[ptr LogosRuntimeHandle](h)
  answer(ecOk)

when defined(lcnTestHooks):
  proc setPolicyForTests*(rt: ptr LogosRuntimeHandle, hook: PolicyHook) =
    ## A test hook: the policy the next `start` installs (`PolicyHook`).
    if rt != nil:
      hostOf(rt).policyHook = hook

proc policyOf(h: ptr HostRuntime, c: HostConfig): AuthzPolicy =
  ## The configured policy, or a test's (`setPolicyForTests`).
  when defined(lcnTestHooks):
    if h.policyHook != nil:
      return h.policyHook()
  c.policy

proc engineOf*(rt: ptr LogosRuntimeHandle): Engine =
  ## In-process hosts and tests: the engine, for observation; nil before
  ## `start` made one.
  if rt == nil:
    return nil
  let h = hostOf(rt)
  withLock h.lock:
    result = h.engine

# Registration -----------------------------------------------------------------------

proc runtimeRegisterBinding*(
    rt: ptr LogosRuntimeHandle, binding: ptr LogosRuntimeNativeBinding
): LogosResult =
  ## [SPEC RUNTIME §13.3] Checks the table's own properties without calling
  ## module code (RUN-1085) and keeps a copy only when every check passed
  ## (RUN-0749, RUN-0756). Creates no instance and grants nothing (RUN-0747).
  entry()
  if rt == nil:
    return answer(ecInvalidParams, "runtime is null")
  if binding == nil:
    return answer(ecInvalidParams, "binding is null")
  if binding.abiVersion != RuntimeHostAbiVersion:
    return answer(
      ecVersionMismatch, "unsupported logos_runtime_native_binding_t abi_version"
    )
  if binding.structSize < csize_t(NativeBindingV1Extent):
    return answer(
      ecVersionMismatch,
      "logos_runtime_native_binding_t struct_size is below version 1's",
    )
  let h = hostOf(rt)
  withLock h.lock:
    if h.startAttempted:
      return answer(ecNotReady, "bindings are registered before start")
    if h.shutdownRequested:
      return answer(ecNotReady, "shutdown has been requested")
  if binding.binding == nil:
    return answer(ecInvalidParams, "the binding identifier is null")
  if binding.symbols == nil and binding.symbolCount != 0:
    return answer(ecInvalidParams, "symbols is null and symbol_count is not 0")
  if binding.symbolCount > csize_t(MaxSymbols):
    return answer(ecInvalidParams, "the symbol table has more than 65536 entries")
  var table: seq[(string, pointer)]
  for i in 0 ..< int(binding.symbolCount):
    let s = binding.symbols[i]
    if s.name == nil:
      return answer(ecInvalidParams, "a symbol name is null")
    table.add(($s.name, cast[pointer](s.address)))
  let id = $binding.binding
  if id == LoaderBindingId:
    # [IMPL-DECISION G246] Only the Runtime's bootstrap holds the Module
    # Loader's registration (BOOTSTRAP l.287, K4; LDR-0006).
    return
      answer(ecInvalidParams, "binding " & id & " is reserved for the Module Loader")
  # [SPEC RUNTIME §13.3] RUN-0748, RUN-1084: checked on the copy.
  discard checkStaticRegistration(id, table).valueOr:
    return answer(ecInvalidParams, error)
  withLock h.lock:
    var b = h.bindings
    while b != nil:
      if $b.id == id:
        return answer(ecInvalidParams, "binding " & id & " is already registered")
      b = b.next
    let c = createShared(BindingCopy)
    c.id = copyText(id)
    c.count = table.len
    c.symbols =
      cast[ptr UncheckedArray[SymbolCopy]](allocShared0(sizeof(SymbolCopy) * table.len))
    for i, (name, address) in table:
      c.symbols[i] = SymbolCopy(name: copyText(name), address: address)
    # Appended, so `start` sees registrations in order.
    if h.bindings == nil:
      h.bindings = c
    else:
      var last = h.bindings
      while last.next != nil:
        last = last.next
      last.next = c
  answer(ecOk)

# Startup ----------------------------------------------------------------------------

proc privateDir(path: string): Result[void, string] =
  ## [IMPL] Creates `path` with mode 0700 when it is missing; its parents get
  ## the usual mode.
  try:
    if dirExists(path):
      return ok()
    createDir(path.parentDir)
    when defined(posix):
      if mkdir(cstring(path), 0o700) != 0 and errno != EEXIST:
        return err($strerror(errno))
    else:
      createDir(path)
    ok()
  except CatchableError as e:
    err(e.msg)

proc launch(h: ptr HostRuntime): LogosResult =
  ## `start` after its call-order checks.
  var bytes = newSeq[byte](h.configLen)
  if h.configLen > 0:
    copyMem(addr bytes[0], h.config, h.configLen)
  let c = parseHostConfig(AppConfigFormat, bytes).valueOr:
    return answer(ecModule, "the stored configuration no longer decodes")
  var
    statics: seq[StaticRegistration]
    ids: HashSet[string]
  var b = h.bindings
  while b != nil:
    let reg = checkStaticRegistration($b.id, b.entries).valueOr:
      return answer(ecModule, "a registered binding no longer checks: " & error)
    if c.authority.isSome and reg.binding == AuthorityModule:
      # [IMPL] The authority's binding is the library's own (`parseHostConfig`).
      return answer(
        ecInvalidParams,
        "binding " & AuthorityModule & " is this library's Capability Authority",
      )
    statics.add(reg)
    ids.incl(reg.binding)
    b = b.next
  if c.authority.isSome:
    # [I85; I84] 8a's Capability Authority, linked into this library: the one
    # registration that may use the reserved `logos` names.
    statics.add(caStaticRegistration())
    ids.incl(AuthorityModule)
  # [IMPL-DECISION S4] A static record naming a binding that was never
  # registered: the protected input is inconsistent before anything runs.
  for m in c.modules:
    if m.record.strategy == stDirectStatic and m.record.binding notin ids:
      return answer(
        ecInvalidParams,
        "module instance " & m.instance & " names static binding " & m.record.binding &
          ", which is not registered",
      )
  for d in c.declarations:
    # The same for what `create_module` may create (G55).
    if d.record.strategy == stDirectStatic and d.record.binding notin ids:
      return answer(
        ecInvalidParams,
        "the declaration of " & d.record.module & " names static binding " &
          d.record.binding & ", which is not registered",
      )
  privateDir(c.workDir).isOkOr:
    return answer(ecModule, "cannot create work_dir: " & error)
  if c.stateRoot.isSome:
    privateDir(c.stateRoot.get).isOkOr:
      return answer(ecModule, "cannot create state_root: " & error)
  var cfg = EngineConfig(
    # [IMPL-DECISION G192, interim (TF-27)] Without a store, a fresh UUIDv4
    # per start; with one, the configured identity or the one generated with
    # the store. Choosing this format is the host's acceptance of it
    # (docs/HOST-CONFIG.md).
    runtimeInstanceId:
      (if c.storeDir.isSome: c.runtimeInstanceId
      else: newRuntimeInstanceId()),
    workDir: c.workDir,
    stateRoot: c.stateRoot,
    storeDir: c.storeDir,
    statics: statics,
    policy: h.policyOf(c),
    ordering: c.ordering,
    declarations: c.declarations,
    startupDeadline: c.startupDeadline,
    stopDeadline: c.stopDeadline,
    shutdownGrace: c.shutdownGrace,
    applyDeadline: c.applyDeadline,
    maxPayloadDepth: c.maxPayloadDepth,
    authority: c.authority,
    callRecords: c.callRecords,
    routing: c.routing,
    transport: Opt.some(c.transport),
    endpointDir: c.endpointDir,
  )
  if c.authority.isSome:
    # [I85; G47] The attribute source exists before the engine opens, since
    # restoring the store fills it. Its own copy of the Runtime id is not read
    # (the wiring's is), so a store-generated identity can stay empty here.
    h.facts = newSharedFacts(cfg.runtimeInstanceId)
    cfg.facts = h.facts
  var instances: seq[BootstrapInstance]
  for m in c.modules:
    instances.add(
      BootstrapInstance(
        instance: m.instance, record: m.record, configuration: m.configuration
      )
    )
  var e: Engine
  withLock h.lock:
    if h.shutdownRequested:
      # [IMPL] R1: a request that overlapped `start` before the engine existed.
      return answer(ecCancelled, "shutdown was requested before bootstrap completed")
    # Bootstrap policy is the engine's from its first request (RUN-0305).
    # [IMPL] A store the configuration names another identity for is
    # INVALID_PARAMS; one that cannot be used is MODULE_ERROR (I82).
    e = openEngine(cfg).valueOr:
      return answer(error.code, error.message)
    h.engine = e
    broadcast(h.cond) # a waiter parked before the engine existed
  let runtimeId = e.runtimeInstanceId()
  h.producer = copyText(runtimeId)
  if c.authority.isSome:
    # [C9] Wired before bootstrap initializes the authority, at the directory
    # the realizer gives its state assignment, with the identity the engine
    # settled (the configured one or the store's). The engine exists, so a
    # failure here is a failed start (G190, interim).
    let a = c.authority.get
    var dir = ""
    for m in c.modules:
      if m.instance == a.instance:
        dir = c.stateRoot.get / m.record.stateAssignment.get
    wireAuthority(
      dir,
      AuthorityWiring(policy: c.authorityPolicy, runtimeId: runtimeId, facts: h.facts),
    ).isOkOr:
      return answer(ecModule, "cannot wire the Capability Authority: " & error)
    h.wired = cast[cstring](allocShared0(dir.len + 1))
    copyMem(h.wired, unsafeAddr dir[0], dir.len)
  let r = e.bootstrap(instances, c.orchestration)
  if r.isErr:
    # [IMPL-DECISION G190, interim] A failed start stops and destroys nothing
    # (RUN-0737).
    return answer(r.error.code, r.error.message)
  answer(ecOk)

proc runtimeStart*(rt: ptr LogosRuntimeHandle): LogosResult =
  ## [SPEC RUNTIME §13.2, §13.4; l.1640] Bootstraps the configured deployment
  ## and returns once the orchestration instance is `ready`, or with why it is
  ## not (G190). Attempted once per handle; never after a shutdown request.
  entry()
  if rt == nil:
    return answer(ecInvalidParams, "runtime is null")
  let h = hostOf(rt)
  withLock h.lock:
    if h.startAttempted:
      return answer(ecNotReady, "start was already attempted")
    if h.shutdownRequested:
      return answer(ecNotReady, "shutdown has been requested")
    h.startAttempted = true
  h.launch()

# Shutdown and destruction ---------------------------------------------------------

proc runtimeRequestShutdown*(rt: ptr LogosRuntimeHandle): LogosResult =
  ## [SPEC RUNTIME §13.2, §10.2] Accepts shutdown and returns; the procedure
  ## continues on the Runtime's own threads (RUN-0726). Repeats join it
  ## (RUN-0727). Before `start` made an engine, shutdown completes at once.
  entry()
  if rt == nil:
    return answer(ecInvalidParams, "runtime is null")
  let h = hostOf(rt)
  var e: Engine
  withLock h.lock:
    if h.shutdownRequested:
      return answer(ecOk)
    h.shutdownRequested = true
    if h.engine == nil:
      h.storeResult(ecOk, "")
      h.shutdownDone = true
      broadcast(h.cond)
      return answer(ecOk)
    e = h.engine
  e.requestShutdown()
  answer(ecOk)

proc runtimeWaitForShutdown*(rt: ptr LogosRuntimeHandle): LogosResult =
  ## [SPEC RUNTIME §13.2, §13.4] Blocks until shutdown, however it was
  ## initiated, completes; never initiates it (RUN-0728). Every wait reports the
  ## one stored result (RUN-0760): OK, or MODULE_ERROR when cleanup was left
  ## unresolved or failed (G60).
  entry()
  if rt == nil:
    return answer(ecInvalidParams, "runtime is null")
  if inRuntimeCallback():
    # [IMPL] R3: RUN-0763 is the host's duty; what can be seen is refused.
    return answer(ecNotReady, "wait_for_shutdown was called from Runtime-owned code")
  let h = hostOf(rt)
  var e: Engine
  acquire(h.lock)
  while not h.shutdownDone and h.engine == nil:
    wait(h.cond, h.lock)
  if h.shutdownDone:
    result = h.storedResult()
    release(h.lock)
    return
  e = h.engine
  release(h.lock)
  let r = e.awaitShutdown()
  withLock h.lock:
    if not h.shutdownDone:
      if r.isOk:
        h.storeResult(ecOk, "")
      else:
        h.storeResult(r.error.code, r.error.message)
      h.shutdownDone = true
      broadcast(h.cond)
    result = h.storedResult()

proc runtimeDestroy*(rt: ptr LogosRuntimeHandle): LogosResult =
  ## [SPEC RUNTIME §13.2, §13.4] Before the first start attempt, or once
  ## shutdown completed and no module code can still use what the handle
  ## holds; otherwise NOT_READY with the handle still valid (RUN-0733,
  ## RUN-0734, RUN-0761).
  entry()
  if rt == nil:
    return answer(ecInvalidParams, "runtime is null")
  let h = hostOf(rt)
  withLock h.lock:
    if h.startAttempted:
      if h.engine == nil:
        if not h.shutdownDone:
          # [IMPL] R2: a start that failed before the engine existed.
          return answer(ecNotReady, "the Runtime has not shut down")
      else:
        h.engine.tryClose().isOkOr:
          return answer(ecNotReady, error.message)
        h.engine = nil
  # [C9] Every instance is destroyed: no thread reads the wiring or the facts.
  if h.wired != nil:
    unwireAuthority($h.wired)
    deallocShared(h.wired)
  freeSharedFacts(h.facts)
  if h.evidence != nil:
    clear(h.evidence.key)
    freeShared(h.evidence)
  if h.producer != nil:
    deallocShared(h.producer)
  freeBindings(h.bindings)
  if h.config != nil:
    deallocShared(h.config)
  deinitCond(h.cond)
  deinitLock(h.lock)
  deallocShared(h)
  answer(ecOk)

# Call audit (in-process hosts) ----------------------------------------------------------

proc auditRecords*(rt: ptr LogosRuntimeHandle): seq[RetainedRecord] =
  ## [SPEC CA l.1169, l.1330; I85] The retained call records, oldest first,
  ## each with its index; none before `start`. In-process only: Tier 4 has no
  ## C export.
  let e = engineOf(rt)
  if e == nil:
    return
  e.audit.records

proc exportCallEvidence*(
    rt: ptr LogosRuntimeHandle, recordIndex: uint64
): Result[seq[byte], string] =
  ## [SPEC CA l.1316-1328; CAP-0415 to CAP-0418; I85] The protected export
  ## integration (docs/HOST-CONFIG.md): a container for the retained record
  ## `recordIndex`, complete and with no proofs, signed with the configured
  ## evidence key; its producer is this Runtime's identity. Calling it is the
  ## host's authorization to disclose the complete record; a record no longer
  ## retained cannot be exported. The container never authorizes anything
  ## (CAP-0256).
  if rt == nil:
    return err("runtime is null")
  let h = hostOf(rt)
  if h.evidence == nil:
    return err("call_audit.evidence is not configured")
  let e = engineOf(rt)
  if e == nil or h.producer == nil:
    return err("the Runtime has not started")
  let bytes = e.audit.recordAt(recordIndex).valueOr:
    return err("no retained call record has index " & $recordIndex)
  var signer = newEvidenceSigner(
    h.evidence.kid.toOpenArray(0, h.evidence.kidLen - 1), $h.producer, h.evidence.key
  ).valueOr:
    return err(error)
  result = signer.exportRecord(bytes)
  clear(signer)
