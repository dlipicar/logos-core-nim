## Module Host supervision (Tier 4b step 4b-3; DECISIONS G264, G265, G267,
## G271; plan §2.3, R2, R3) [IMPL]: the protected host supervision of RUNTIME
## l.669 and l.3823. One `HostSupervisor` per engine, made when
## `runtime.module_host` is configured; it outlives a failed Module Loader.
##
## - **Hosts.** The Runtime makes one `Host` per hosted attempt (`newHost`):
##   the carrier's socket pair and the attempt's Runtime Control binding and
##   publish callback. The Loader spawns it (`spawn`), talks to it on lane 0
##   (`sendInit`, `awaitLane0`) and ends it (`terminate`, `awaitEnd`). Nothing
##   restarts a host (LOADER l.105).
## - **The supervision thread** polls every live carrier and a wake pipe, and
##   calls `waitpid(pid, WNOHANG)` for each live host on every tick (at most
##   50 ms apart). No SIGCHLD handler and never `waitpid(-1)`: tests spawn
##   other children.
## - **Ends [R3].** After every end, graceful ones too, the host's process
##   group is killed; the end is confirmed once the host is reaped and the
##   group is gone (`kill(-pgid, 0)` is ESRCH). A malformed or oversize frame,
##   or an end of the carrier without `released`, ends the host at once
##   (RUN-0812). A process that left the group is not covered (CONFORMANCE).
## - **Runtime Control over lane 1 [G267].** Each request runs on a proxy
##   worker (a bounded pool) through the attempt's own direct binding, the
##   same vtable a direct module calls, so values, errors, authority and
##   transitions are the direct ones (RUN-0180). The consumer is the
##   attempt's, never a field of the frame (RUN-0171, RUN-0172).
## - **Events [G271].** The direct handler of a hosted subscription forwards
##   each entry to the host and waits for the host's handler to return
##   (`rc_delivered`), so G178's order, one-at-a-time rule and G225's bound
##   apply unchanged. A handler unsubscribing its own subscription is run
##   beside the waiting delivery, on its thread, so it does not wait for its
##   own frame, as direct.
##
## - **Hosted endpoints [G273] (4b-3.2).** A hosted provider's host serves
##   the listener the Runtime made (fd 4) with its own transport loop and
##   forwards the loop's events on lane 2; they reach the engine through
##   `setIoSink` as its own loop's do, in the Runtime's connection numbers
##   (`hostnum.nim`). The Runtime's orders for those connections come back
##   through `submitHosted`, the transport port's hook, onto the host's
##   sender thread, so no Runtime thread waits for a host to read. A call
##   the Runtime admitted runs in the host (`beginDispatch`); its end and its
##   scoped publication steps come back to the waiting call worker
##   (`hostcall.nim`). No payload crosses (plan §2.7): `hostio.toMessage`
##   refuses the commands that would carry one.
##
## On Windows no supervisor is made (`newSupervisor` gives nil, plan §2.1):
## the procedures below are POSIX and have stand-ins there that no host
## reaches.
##
## Lifetimes: a `Host` is reference counted (the engine's attempt, the Loader's
## realization, the supervision list, queued jobs). Its descriptors close when
## the last reference goes; its state never moves between threads except as
## frame bytes and plain values.

{.push raises: [], gcsafe.}

import std/[atomics, locks]
import results
import logos_sdk/abi/[checks, cstatus, types]
import logos_sdk/base/[perthread, testhooks]
import logos_sdk/iface/[accept, surface]
import ../transport/io/api except decodeMessage
import ./[carrier, callside, events, hostio, subend]
import ./plumbing except Request
from ./plumbing import nil

when defined(posix):
  import std/[os, posix, tables]
  import ../transport/io/sock

export carrier, hostio

testHooksMarker("hostsup")

when defined(posix):
  {.compile: "hostspawn.c".}
  proc lcnHostSpawn(
    path: cstring,
    argv, envp: cstringArray,
    carrier, listener, lock: cint,
    pid: ptr cint,
  ): cint {.importc: "lcn_host_spawn", cdecl.}

const
  TickMs = 50 ## [IMPL; R2] the supervision tick
  MaxProxyWorkers = 64 ## [IMPL] Runtime Control requests in progress at once, per engine
  ProgramName = "logos-module-host"
  MaxTransportWords = 64 ## [IMPL] room for `transportWords`

type
  HostEnd* = object ## [R7 (c)] How a host ended, as supervision saw it.
    exited*: bool ## it exited; otherwise a signal ended it
    status*: int ## the exit status, or the signal number
    terminated*: bool ## supervision ended it before it ended by itself
    reason*: string ## why supervision ended it; empty: it did not
    released*: bool ## it answered `released` first (an orderly end)
    orderly*: bool
      ## [R7 (c)] a terminal lane-0 message came first (`released`,
      ## `init_failed`, `fatal`): the Loader's answer decides
    byRuntime*: bool
      ## [R7 (d)] the Runtime ended it (a deadline, its Loader's loss): the
      ## Runtime's classification stays
    carrierLost*: string ## why the carrier failed; empty: it did not

  ProxySubObj = object
    ## One Runtime Control subscription a host made: its handler forwards.
    host: Host
    local: uint64 ## the host's token for its handler
    sent, acked: uint64
    delivering: bool
    nested: Channel[seq[byte]]
      ## requests the host's handler made beside the delivery in progress
    next: ptr ProxySubObj

  DispatchObj = object ## [G273] One admitted call the host is running.
    host: Host
    call: uint64
    frames: Channel[seq[byte]]
      ## its `dispatched` and `scoped_publish` frames; empty: the host ended
    next: ptr DispatchObj

  HostDispatch* = ptr DispatchObj

  ProxyAsyncObj = object ## One prepared Runtime Control call a host made.
    host: Host
    call: LogosAsyncCall
    hostCall: uint64
    next: ptr ProxyAsyncObj

  HostObj = object
    sup: HostSupervisor
    refs: Atomic[int]
    lock: Lock
    cond: Cond
    daemonFd, hostFd: cint
    writer: CarrierWriter
    pid: cint
    spawned, reaped, groupKilled, confirmed, listed: bool
    waitStatus: cint
    terminating: bool
    termReason: FixedText
    byRuntime: bool ## [R7 (d)] the Runtime asked for the end
    orderly: bool ## [R7 (c)] a terminal lane-0 message was read
    lockFd: cint ## [G275] the restart lock, the daemon's copy until the spawn
    carrierDown: bool
    lostReason: FixedText
    released: bool
    endHandled: bool
      ## [G360] the Runtime thread has handled its end (`noteEnd`); read and
      ## written on the Runtime thread only
    closedOps: bool
    ops: int
    rc: ptr LogosRuntimeControlBinding
    publish: LogosPublishFn
    publishUserData: pointer
    payloadDepth*: int
    lane0: Channel[seq[byte]] ## lane-0 frames for the Loader; empty: the host ended
    subs: ptr ProxySubObj
    asyncs: ptr ProxyAsyncObj
    nextId: Atomic[uint64]
    services: ptr AttemptServices ## freed with the host (`freeWith`)
    index: uint64 ## [G273] its number in hosted connection and endpoint ids
    listenerFd: cint
      ## [RUN-0200] a copy of its endpoint's listener, for the spawn (fd 4)
    endpointPath, runtimeId: cstring ## shared; nil: no endpoint
    transport: array[MaxTransportWords, uint64]
    transportLen: int
    dispatches: ptr DispatchObj ## under `lock`
    outQ: Channel[seq[byte]] ## lane-2 frames for the sender; empty: stop
    sender: Thread[Host]
    senderRunning: bool ## under `lock`
    next: ptr HostObj

  Host* = ptr HostObj

  ProxyJob = object
    host: Host ## nil: the worker stops
    frame: seq[byte]

  SpawnReq = object
    ## [IMPL] A spawn the supervision thread runs: on Linux a host's
    ## `PR_SET_PDEATHSIG` follows the thread that spawned it, and that thread
    ## lives as long as the supervisor.
    h: Host
    listener, lock: cint
    done: bool
    rc: cint
    next: ptr SpawnReq

  EndNotify* = proc(ctx: pointer, h: Host, e: HostEnd) {.nimcall, gcsafe, raises: [].}
    ## Supervision thread: `h` has ended as `e` says. Called before anyone
    ## waiting for the end (`awaitEnd`, `awaitLane0`) is woken, so what the
    ## callee posts precedes anything they report [R27]. A callee that keeps
    ## `h` retains it.

  SupervisorObj = object
    program: cstring
    env: cstringArray ## the allow-listed `NAME=value` entries, nil-terminated
    lock: Lock
    hosts: ptr HostObj
    spawns: ptr SpawnReq ## under `lock`
    spawned: Cond ## with `lock`: a spawn is done
    wake: array[2, cint]
    thread: Thread[HostSupervisor]
    started: bool
    closing: Atomic[bool]
    jobs: Channel[ProxyJob]
    workers: array[MaxProxyWorkers, Thread[HostSupervisor]]
    workerCount, idle: int
    queued: int ## jobs sent and not yet taken, under `lock`
    onEnd: EndNotify
    onEndCtx: pointer
    onIo: IoSink ## [G273] where a host's loop events go
    onIoCtx: pointer
    nextIndex: Atomic[uint64]

  HostSupervisor* = ptr SupervisorObj

# Text in shared memory -----------------------------------------------------------------

func clipText(s: string): FixedText =
  fixed(
    if s.len > TextCapacity:
      s[0 ..< TextCapacity]
    else:
      s
  )

proc sharedCString(s: string): cstring =
  let p = cast[cstring](allocShared0(s.len + 1))
  if s.len > 0:
    copyMem(p, unsafeAddr s[0], s.len)
  p

when defined(posix):
  # The supervisor --------------------------------------------------------------------------

  proc newSupervisor*(program: string, envNames: openArray[string]): HostSupervisor =
    ## [R4] `envNames`: the variables every host gets, copied from this
    ## process's environment when set; nothing else reaches a host.
    result = createShared(SupervisorObj)
    result.program = sharedCString(program)
    var entries: seq[string]
    for n in envNames:
      if existsEnv(n):
        entries.add(n & "=" & getEnv(n))
    result.env = cast[cstringArray](allocShared0(sizeof(cstring) * (entries.len + 1)))
    for i, e in entries:
      result.env[i] = sharedCString(e)
    initLock(result.lock)
    initCond(result.spawned)
    result.wake = [cint(-1), cint(-1)]
    result.jobs.open()

  proc setEndNotify*(s: HostSupervisor, fn: EndNotify, ctx: pointer) =
    ## Before the first spawn.
    s.onEnd = fn
    s.onEndCtx = ctx

  proc setIoSink*(s: HostSupervisor, fn: IoSink, ctx: pointer) =
    ## [G273] Before the first spawn: the engine's sink for the events of
    ## every host's loop, which it handles as its own loop's.
    s.onIo = fn
    s.onIoCtx = ctx

  proc wakeUp(s: HostSupervisor) =
    if s.wake[1] >= 0:
      var b = 1'u8
      discard posix.write(s.wake[1], addr b, 1)

  # Hosts -----------------------------------------------------------------------------------

  proc newHost*(
      s: HostSupervisor,
      rc: ptr LogosRuntimeControlBinding,
      publish: LogosPublishFn,
      publishUserData: pointer,
      payloadDepth: int,
      lockFd: cint = -1,
  ): Result[Host, string] =
    ## [plan §2.4] The carrier of one hosted attempt and its launch state: the
    ## attempt's Runtime Control binding and publish callback, from which every
    ## lane-1 frame takes its consumer. One reference, the caller's. `lockFd`
    ## [G275]: the instance's restart lock, held; the host takes it as fd 5 and
    ## this copy is closed once the host is spawned (or with the host). On an
    ## error the caller still owns it.
    let index = s.nextIndex.fetchAdd(1) + 1
    if index > MaxHostIndex:
      return err("no Module Host number is left")
    var fds: array[2, cint]
    let r = socketPair(addr fds)
    if r < 0:
      return err("the carrier cannot be made (" & $(-r) & ")")
    if setNonblock(fds[0]) < 0:
      discard fdClose(fds[0])
      discard fdClose(fds[1])
      return err("the carrier cannot be made non-blocking")
    let h = createShared(HostObj)
    h.sup = s
    h.refs.store(1)
    initLock(h.lock)
    initCond(h.cond)
    h.daemonFd = fds[0]
    h.hostFd = fds[1]
    h.writer.initWriter(fds[0])
    h.pid = -1
    h.index = index
    h.listenerFd = -1
    h.lockFd = lockFd
    h.rc = rc
    h.publish = publish
    h.publishUserData = publishUserData
    h.payloadDepth = payloadDepth
    h.lane0.open()
    h.outQ.open()
    ok(h)

  proc retain*(h: Host) =
    discard h.refs.fetchAdd(1)

  proc drainClose[T](ch: var Channel[T]) =
    while true:
      try:
        let (got, _) = ch.tryRecv()
        if not got:
          break
      except Exception:
        break
    ch.close()

  proc freeWith*(h: Host, services: ptr AttemptServices) =
    ## [plan §2.6] `services` (whose binding the host's requests use) are freed
    ## with the host, after its last request.
    withLock h.lock:
      h.services = services

  proc freeHost(h: Host) =
    if h.services != nil:
      freeShared(h.services)
    if h.listenerFd >= 0:
      discard fdClose(h.listenerFd)
    if h.endpointPath != nil:
      deallocShared(h.endpointPath)
    if h.runtimeId != nil:
      deallocShared(h.runtimeId)
    var d = h.dispatches
    while d != nil:
      let n = d.next
      d.frames.drainClose()
      freeShared(d)
      d = n
    h.outQ.drainClose()
    if h.lockFd >= 0:
      discard fdClose(h.lockFd)
    if h.daemonFd >= 0:
      discard fdClose(h.daemonFd)
    if h.hostFd >= 0:
      discard fdClose(h.hostFd)
    var p = h.subs
    while p != nil:
      let n = p.next
      p.nested.drainClose()
      freeShared(p)
      p = n
    var a = h.asyncs
    while a != nil:
      let n = a.next
      freeShared(a)
      a = n
    h.lane0.drainClose()
    h.writer.deinitWriter()
    deinitCond(h.cond)
    deinitLock(h.lock)
    freeShared(h)

  proc dropHost*(h: Host) =
    ## Gives up one reference; the last frees the host's descriptors.
    if h != nil and h.refs.fetchSub(1) == 1:
      freeHost(h)

  proc nextRequest*(h: Host): uint64 =
    h.nextId.fetchAdd(1) + 1

  func index*(h: Host): uint64 =
    ## [G273] Its number in hosted connection and endpoint ids.
    h.index

  proc noteEnd*(h: Host) =
    ## [P5 §0.4 item 2; G360] Runtime thread: the end of `h` reached the
    ## Runtime (`engine.hostEnded`). Kept on the host, so a new host of the
    ## same instance is never taken as ended.
    h.endHandled = true

  func endHandled*(h: Host): bool =
    ## Runtime thread: `noteEnd` was called for `h`.
    h.endHandled

  proc setTransport*(h: Host, transport: TransportConfig): Result[void, string] =
    ## [plan §2.8; part 4b-3.3] Before the spawn: the Transport limits the
    ## host's own I/O loop runs with, for a hosted consumer's connections and a
    ## hosted provider's endpoint alike (`transportInit`).
    let words = transportWords(transport)
    if words.len > MaxTransportWords:
      return err("the transport limits do not fit")
    for i, w in words:
      h.transport[i] = w
    h.transportLen = words.len
    ok()

  proc transportInit*(h: Host): seq[uint64] =
    ## What `init` carries as `transport`; empty when none was set.
    for i in 0 ..< h.transportLen:
      result.add(h.transport[i])

  proc setEndpoint*(
      h: Host, listener: cint, path, runtimeId: string, transport: TransportConfig
  ): Result[void, string] =
    ## [SPEC LOADER §5.3; RUN-0200; G273] Before the spawn: the endpoint the
    ## Runtime made for this hosted provider. The host gets a copy of
    ## `listener` as its fd 4, which is closed here once it is spawned; the
    ## caller keeps its own. `path`, `runtimeId` and `transport` go into
    ## `init` (`endpointInit`).
    ?h.setTransport(transport)
    let fd = dupFd(listener)
    if fd < 0:
      return err("the listener cannot be duplicated")
    h.listenerFd = fd
    h.endpointPath = sharedCString(path)
    h.runtimeId = sharedCString(runtimeId)
    ok()

  proc endpointInit*(
      h: Host
  ): Opt[tuple[path, runtimeId: string, transport: seq[uint64]]] =
    ## [SPEC LOADER §5.3] What `init` carries for a hosted provider; none for
    ## a consumer-only host.
    if h.endpointPath == nil:
      return Opt.none(tuple[path, runtimeId: string, transport: seq[uint64]])
    var words: seq[uint64]
    for i in 0 ..< h.transportLen:
      words.add(h.transport[i])
    Opt.some((path: $h.endpointPath, runtimeId: $h.runtimeId, transport: words))

  proc alive(ctx: pointer): bool {.nimcall.} =
    let h = cast[Host](ctx)
    withLock h.lock:
      result = not h.confirmed and not h.carrierDown

  proc ended*(h: Host): bool =
    ## Its end is confirmed.
    withLock h.lock:
      result = h.confirmed

  when defined(lcnTestHooks):
    # [plan §2.7] The carrier trace: every frame, both ways, is counted, and
    # so is each one holding any of the markers a test set, so a test shows
    # that no payload crosses.
    const MaxMarkers = 8
    var traceLock: Lock
    var markers: array[MaxMarkers, array[64, byte]]
    var markerLens: array[MaxMarkers, int]
    var markerCount: int
    var tracedFrames, tracedHits: Atomic[int]
    initLock(traceLock)

    proc traceMarkers*(marks: openArray[seq[byte]]) =
      ## Starts counting afresh with `marks` (at most 8, each at most 64
      ## bytes); none stops.
      withLock traceLock:
        markerCount = 0
        for m in marks:
          if markerCount < MaxMarkers and m.len > 0 and m.len <= 64:
            for i, b in m:
              markers[markerCount][i] = b
            markerLens[markerCount] = m.len
            inc markerCount
        tracedFrames.store(0)
        tracedHits.store(0)

    proc traced*(): tuple[frames, hits: int] =
      (tracedFrames.load, tracedHits.load)

    # [DECISIONS I92] The patterns an audit build of the host scans released
    # blocks for, sent in `init` to every host spawned while they are set.
    var auditPatterns: seq[seq[byte]] ## under `traceLock`

    proc setWipeAudit*(patterns: openArray[seq[byte]]) =
      ## None: hosts spawned from now on are not armed. The patterns set
      ## before are zeroed: a test's armed scan would find them released.
      withLock traceLock:
        {.cast(gcsafe).}:
          for p in auditPatterns.mitems:
            if p.len > 0:
              zeroMem(addr p[0], p.len)
          auditPatterns = @patterns

    proc wipeAuditInit*(): seq[seq[byte]] =
      withLock traceLock:
        {.cast(gcsafe).}:
          result = auditPatterns

    proc holds(f: openArray[byte], m: openArray[byte]): bool =
      if m.len == 0 or m.len > f.len:
        return false
      for i in 0 .. f.len - m.len:
        var same = true
        for j in 0 ..< m.len:
          if f[i + j] != m[j]:
            same = false
            break
        if same:
          return true
      false

    proc trace(f: openArray[byte]) =
      var hit = false
      withLock traceLock:
        if markerCount == 0:
          return
        for i in 0 ..< markerCount:
          if f.holds(markers[i].toOpenArray(0, markerLens[i] - 1)):
            hit = true
      discard tracedFrames.fetchAdd(1)
      if hit:
        discard tracedHits.fetchAdd(1)

  proc sendMsg*(h: Host, m: LcnCarrierMessage): Result[void, string] =
    ## One message to the host; an error once its carrier is down.
    if not alive(h):
      return err("the Module Host has ended")
    when defined(lcnTestHooks):
      if m.kind == LcnCarrierMessageKind.lcn_Carrier_init and
          m.arm_lcn_Carrier_init.wipe_audit.isSome:
        # [DECISIONS I92] The trace exempts exactly `init.wipe_audit`, the
        # patterns an audit host is armed with: the rest of the init is
        # traced. The copy's patterns are zeroed before it is dropped.
        var t = m.arm_lcn_Carrier_init
        for p in t.wipe_audit.get.mitems:
          if p.len > 0:
            zeroMem(addr p[0], p.len)
        t.wipe_audit = Opt.none(seq[seq[byte]])
        let f = frameOf(toMessage(t))
        if f.isOk:
          trace(f.get)
      else:
        let f = frameOf(m)
        if f.isOk:
          trace(f.get)
    h.writer.send(m, alive, h)

  # Test hooks ------------------------------------------------------------------------------

  when defined(lcnTestHooks):
    const MaxEndRecords = 512

    type EndRecord = object ## plain values: written by the supervision thread
      exited, terminated, released, orderly, byRuntime: bool
      status: int
      reason, lost: FixedText

    var ordersGiven, ordersWritten: Atomic[int]
      ## [P3 §12.2] lane-2 orders given to the hosts' senders, and written

    proc hostOrdersWrittenForTests*(): bool =
      ## Every lane-2 order given to a host's sender so far is written to its
      ## carrier (or dropped with its host).
      ordersWritten.load == ordersGiven.load

    var hookLock: Lock
    var heldHosts, brokenHosts: array[64, uint] ## [plan §2.3] under `hookLock`
    var holdingAll: bool ## [plan §2.3] under `hookLock`: every host's end is held
    var endRecords: ptr UncheckedArray[EndRecord]
    var endCount: int
    initLock(hookLock)
    endRecords = cast[ptr UncheckedArray[EndRecord]](allocShared0(
      sizeof(EndRecord) * MaxEndRecords
    ))

    proc mark(list: var array[64, uint], h: Host, on: bool) =
      let k = cast[uint](h)
      for x in list.mitems:
        if on and x == 0:
          x = k
          return
        if not on and x == k:
          x = 0
          return

    proc marked(list: array[64, uint], h: Host): bool =
      let k = cast[uint](h)
      for x in list:
        if x == k:
          return true
      false

    proc testHeld(h: Host): bool =
      withLock hookLock:
        result = (holdingAll or heldHosts.marked(h)) and not h.sup.closing.load

    proc testBreak(h: Host): bool =
      withLock hookLock:
        result = brokenHosts.marked(h)
        if result:
          brokenHosts.mark(h, false)

    proc recordEnd(e: HostEnd) =
      withLock hookLock:
        if endCount < MaxEndRecords:
          endRecords[endCount] = EndRecord(
            exited: e.exited,
            terminated: e.terminated,
            released: e.released,
            orderly: e.orderly,
            byRuntime: e.byRuntime,
            status: e.status,
            reason: clipText(e.reason),
            lost: clipText(e.carrierLost),
          )
          inc endCount

    proc holdEnd*(h: Host, hold: bool) =
      ## [plan §2.3] Delays (or releases) the confirmation of `h`'s end.
      withLock hookLock:
        heldHosts.mark(h, hold)
      h.sup.wakeUp()

    proc holdEnds*(hold: bool) =
      ## [plan §2.3] Delays (or releases) the confirmation of every host's end,
      ## those not yet spawned included; `holdEnd` on one of them wakes its
      ## supervision.
      withLock hookLock:
        holdingAll = hold

    proc breakCarrier*(h: Host) =
      ## [plan §2.3] The next frame from `h` is treated as malformed.
      withLock hookLock:
        brokenHosts.mark(h, true)

    var killHeld: array[64, uint] ## [G360] under `hookLock`

    proc testKillHeld(h: Host): bool =
      withLock hookLock:
        result = killHeld.marked(h)

    proc holdKill*(h: Host, hold: bool) =
      ## [P5 §3.1 item 4; IMPL-DECISION G360] Defers the kill `terminate`
      ## sends `h`, so its carrier outlives a termination the Runtime ordered;
      ## released, a deferred kill is sent.
      withLock hookLock:
        killHeld.mark(h, hold)
      if not hold:
        var pid: cint = -1
        withLock h.lock:
          if h.terminating and h.spawned and not h.confirmed:
            pid = h.pid
        if pid > 0:
          discard kill(Pid(-pid), SIGKILL)
        h.sup.wakeUp()

    var dropListener: Atomic[bool]

    proc dropNextListener*() =
      ## [plan §4.3 P-4] The next host spawned with a listener gets none on
      ## fd 4, as if the transfer were lost.
      dropListener.store(true)

    proc hostEnds*(): seq[HostEnd] =
      ## [plan §2.3] Every end confirmed in this process, in order.
      withLock hookLock:
        for i in 0 ..< endCount:
          let r = endRecords[i]
          result.add(
            HostEnd(
              exited: r.exited,
              status: r.status,
              terminated: r.terminated,
              released: r.released,
              orderly: r.orderly,
              byRuntime: r.byRuntime,
              reason: $r.reason,
              carrierLost: $r.lost,
            )
          )

    proc pidOf*(h: Host): int =
      withLock h.lock:
        result = int(h.pid)

  # Spawning --------------------------------------------------------------------------------

  proc spawnProcess*(
      program: string,
      env: openArray[string],
      carrier: cint,
      listener: cint = -1,
      lock: cint = -1,
  ): Result[int, string] =
    ## [IMPL] One process started as a host is (`hostspawn.c`): the carrier on
    ## fd 3, `env` its whole environment. The caller reaps it. The supervision
    ## thread spawns hosts with it; the host suites, their own children.
    when defined(posix):
      var argv = [cstring(ProgramName), nil]
      var envp = newSeq[cstring](env.len + 1)
      for i, e in env:
        envp[i] = cstring(e)
      var pid: cint
      let r = lcnHostSpawn(
        cstring(program),
        cast[cstringArray](addr argv[0]),
        cast[cstringArray](addr envp[0]),
        carrier,
        listener,
        lock,
        addr pid,
      )
      if r != 0:
        return err($strerror(-r))
      ok(int(pid))
    else:
      err("hosted placement is not supported on this platform")

  proc startThreads(s: HostSupervisor): Result[void, string]

  proc spawn*(h: Host, listener: cint = -1, lock: cint = -1): Result[void, string] =
    ## [plan §2.3; R5] The host process, with the carrier on fd 3 and, when
    ## given, the listener on fd 4 and the restart lock on fd 5. The host's end
    ## of the carrier is closed here, so the host holds the only copy.
    let s = h.sup
    if s.closing.load:
      return err("the Runtime is closing")
    withLock h.lock:
      if h.terminating:
        return err("the Module Host was ended before it started")
    ?s.startThreads()
    var req = SpawnReq(
      h: h,
      listener: (if listener >= 0: listener else: h.listenerFd),
      lock: (if lock >= 0: lock else: h.lockFd),
    )
    when defined(lcnTestHooks):
      if req.listener >= 0 and dropListener.exchange(false):
        req.listener = -1
    withLock s.lock:
      if s.closing.load:
        return err("the Runtime is closing")
      req.next = s.spawns
      s.spawns = addr req
    s.wakeUp()
    withLock s.lock:
      while not req.done:
        wait(s.spawned, s.lock)
    discard fdClose(h.hostFd)
    h.hostFd = -1
    if h.lockFd >= 0:
      # [G275] The host's fd 5 holds the lock now.
      discard fdClose(h.lockFd)
      h.lockFd = -1
    if h.listenerFd >= 0:
      # [RUN-0200] The host's fd 4 is its copy; the Runtime keeps its own.
      discard fdClose(h.listenerFd)
      h.listenerFd = -1
    if req.rc != 0:
      return err("the Module Host cannot be started: " & $strerror(-req.rc))
    ok()

  proc terminate*(h: Host, reason: string, byRuntime = false): bool {.discardable.} =
    ## [SPEC RUNTIME l.669; G61] Ends the host's process group; idempotent,
    ## returns at once. `awaitEnd` waits for the confirmation. `byRuntime`
    ## [R7 (d)]: the Runtime ends it at a deadline or after its Loader's loss,
    ## also when the host is already ending for another reason.
    ##
    ## [P5 §0.4 item 2; G360] True when `h` was not spawned yet: none of its
    ## module code ever runs, since a spawn asked for later is refused and one
    ## already under way kills the process before `spawn` returns (before the
    ## Loader sends `init`); only such a spawn's end is still confirmed.
    var pid: cint = -1
    withLock h.lock:
      if h.confirmed:
        return false
      if byRuntime and not h.carrierDown:
        h.byRuntime = true
      result = not h.spawned
      if h.terminating:
        return
      h.terminating = true
      h.termReason = clipText(reason)
      if h.spawned:
        pid = h.pid
    when defined(lcnTestHooks):
      if testKillHeld(h):
        pid = -1 # `holdKill` sends it
    if pid > 0:
      discard kill(Pid(-pid), SIGKILL)
    h.sup.wakeUp()

  proc endOf(h: Host): HostEnd =
    ## Under `h.lock`, once confirmed.
    let st = h.waitStatus
    if WIFEXITED(st):
      result.exited = true
      result.status = int(WEXITSTATUS(st))
    elif WIFSIGNALED(st):
      result.status = int(WTERMSIG(st))
    result.terminated = h.terminating
    result.reason = $h.termReason
    result.released = h.released
    result.orderly = h.orderly
    result.byRuntime = h.byRuntime
    result.carrierLost = $h.lostReason

  proc awaitEnd*(h: Host): HostEnd =
    ## Blocks until the end is confirmed and no Runtime Control request of the
    ## host is still running; none is admitted after. A host never spawned has
    ## nothing to end.
    withLock h.lock:
      if not h.spawned:
        h.confirmed = true
        h.closedOps = true
        return HostEnd()
      while not h.confirmed or h.ops > 0:
        wait(h.cond, h.lock)
      h.closedOps = true
      result = h.endOf()

  proc endIfConfirmed*(h: Host): Opt[HostEnd] =
    withLock h.lock:
      if h.confirmed:
        return Opt.some(h.endOf())
    Opt.none(HostEnd)

  proc awaitLane0*(h: Host): Opt[LcnCarrierMessage] =
    ## The next lane-0 message from the host; none once it has ended.
    var f: seq[byte]
    try:
      f = h.lane0.recv()
    except Exception:
      return Opt.none(LcnCarrierMessage)
    if f.len == 0:
      try:
        h.lane0.send(f) # the marker stays for any later wait
      except Exception:
        discard
      return Opt.none(LcnCarrierMessage)
    let m = decodeMessage(f).valueOr:
      return Opt.none(LcnCarrierMessage)
    Opt.some(m)

  # Hosted endpoints [G273] ------------------------------------------------------------------

  proc senderMain(h: Host) {.thread.} =
    ## The host's lane-2 orders, written in the order they were given; a write
    ## waits for the host to read, never a Runtime thread.
    while true:
      var f: seq[byte]
      try:
        f = h.outQ.recv()
      except Exception:
        break
      if f.len == 0:
        break
      if alive(h):
        discard h.writer.sendFrame(f, alive, h)
      when defined(lcnTestHooks):
        ordersWritten += 1
    releasePerThread()

  proc queueOut(h: Host, f: sink seq[byte]): SubmitResult =
    ## [G273 interim (K38)] One lane-2 order for the sender. None carries a
    ## payload or a success (`hostio.toMessage`), so none is charged against
    ## an output budget: the host's loop charges what it commits itself.
    when defined(lcnTestHooks):
      trace(f)
    withLock h.lock:
      if h.confirmed or h.carrierDown:
        return sbStopped
      if not h.senderRunning:
        try:
          createThread(h.sender, senderMain, h)
        except Exception:
          return sbStopped
        h.senderRunning = true
      try:
        h.outQ.send(f)
      except Exception:
        return sbStopped
      when defined(lcnTestHooks):
        ordersGiven += 1
    sbOk

  proc notify*(h: Host, m: LcnCarrierMessage) =
    ## [plan §2.8; part 4b-3.3] A notice from the Runtime thread
    ## (`route_ended`) or a call worker (`call_cancel`): queued for the sender
    ## behind the lane-2 orders already given, so its writer never waits for a
    ## host to read. Nothing once the host has ended.
    let f = frameOf(m)
    if f.isOk:
      discard h.queueOut(f.get)

  proc forwardSubscriptionEnd*(h: Host, id: uint64, reason: ErrorCode) =
    ## [DECISIONS G225] A Runtime Control subscription the Runtime ended, from
    ## the Runtime thread: the end goes to the host, queued behind what was
    ## already sent and never a write from this thread, and the host reports
    ## it when its module's registration is installed as it reads it (P3
    ## reading against INTERFACE l.1481), during `_MODULE_init` too.
    notify(
      h, toMessage(LcnCarrierRcSubscriptionEnded(sub: id, code: uint8(ord(reason))))
    )

  proc forwardSubEnd(
      id: LogosSubscriptionId, reason: CErrorCode, userData: pointer
  ) {.cdecl.} =
    ## The registration `forwardSubscriptionEnds` keeps: the engine sends a
    ## hosted binding's ends itself (`engine.endRc`), so no report job runs
    ## this; it forwards as the engine would.
    bindingEnter()
    cast[Host](userData).forwardSubscriptionEnd(uint64(id), ErrorCode(int64(reason)))

  proc forwardSubscriptionEnds*(h: Host) =
    ## [G225] At the launch: the attempt's binding has a registration
    ## installed until release or destroy suppresses it, so an end is owed to
    ## the host while the binding is live (`engine.endRc`), whatever its module
    ## registers there; the module's registration is the host's
    ## (`host/rcbinding`).
    discard cast[ptr AttemptServices](h.rc.state).subEnd.register(forwardSubEnd, h)

  proc stopSender(h: Host) =
    ## Supervision thread, once the carrier is down: the sender's write ends
    ## within one step and it is joined.
    var running: bool
    withLock h.lock:
      running = h.senderRunning
      h.senderRunning = false
    if running:
      try:
        h.outQ.send(@[])
      except Exception:
        discard
      try:
        joinThread(h.sender)
      except Exception:
        discard

  proc findIndex(s: HostSupervisor, index: uint64): Host =
    ## The live host numbered `index`, retained; nil when there is none.
    withLock s.lock:
      var p = s.hosts
      while p != nil:
        if p.index == index:
          retain(p)
          return p
        p = p.next
    nil

  proc findHost*(s: HostSupervisor, conn: uint64): Host =
    ## The live host serving hosted connection `conn`, retained; nil when
    ## there is none.
    if s == nil or not conn.isHostedConn:
      return nil
    s.findIndex(hostOfConn(conn))

  proc submitHosted*(
      ctx: pointer, cmd: var IoCommand
  ): SubmitResult {.nimcall, gcsafe, raises: [].} =
    ## [G273] The transport port's hook (`setHosted`): an order for a hosted
    ## connection or endpoint goes to its host's sender. `sbStopped` once the
    ## host has ended, as for a connection the loop no longer has.
    let s = cast[HostSupervisor](ctx)
    let index =
      if cmd.kind == IoCommandKind.cmdStopServing:
        hostOfEndpoint(cmd.stopEndpoint)
      else:
        hostOfConn(cmd.conn)
    let h = s.findIndex(index)
    if h == nil:
      return sbStopped
    let m = hostio.toMessage(cmd)
    result =
      if m.isNone:
        sbStopped
      else:
        let f = frameOf(m.get)
        if f.isErr:
          sbStopped
        else:
          h.queueOut(f.get)
    dropHost(h)

  proc beginDispatch*(h: Host, call: uint64): HostDispatch =
    ## [G273] Waits for call `call`'s frames from the host; nil once it has
    ## ended. The caller sends `admit_verdict` next and ends with
    ## `endDispatch`.
    let d = createShared(DispatchObj)
    d.host = h
    d.call = call
    d.frames.open()
    withLock h.lock:
      if h.confirmed or h.carrierDown:
        d.frames.close()
        freeShared(d)
        return nil
      d.next = h.dispatches
      h.dispatches = d
    retain(h)
    d

  proc nextFrame*(d: HostDispatch): Opt[seq[byte]] =
    ## The call's next frame, without waiting; an empty frame once the host
    ## has ended.
    try:
      let (got, f) = d.frames.tryRecv()
      if got:
        if f.len == 0:
          d.frames.send(f) # the marker stays
        return Opt.some(f)
    except Exception:
      return Opt.some(newSeq[byte]())
    Opt.none(seq[byte])

  proc endDispatch*(d: HostDispatch) =
    if d == nil:
      return
    let h = d.host
    withLock h.lock:
      var p = addr h.dispatches
      while p[] != nil:
        if p[] == d:
          p[] = d.next
          break
        p = addr p[].next
    d.frames.drainClose()
    freeShared(d)
    dropHost(h)

  proc toDispatch(h: Host, call: uint64, f: seq[byte]) =
    ## Supervision thread: a frame for the waiting call; a frame for a call no
    ## one waits for any more (it was given up) is dropped.
    withLock h.lock:
      var p = h.dispatches
      while p != nil:
        if p.call == call:
          try:
            p.frames.send(f)
          except Exception:
            discard
          return
        p = p.next

  proc endDispatches(h: Host) =
    ## Supervision thread, at the confirmed end: every waiting call is told.
    withLock h.lock:
      var p = h.dispatches
      while p != nil:
        try:
          p.frames.send(@[])
        except Exception:
          discard
        p = p.next

  # Proxy operations ------------------------------------------------------------------------

  proc enterOp(h: Host): bool =
    withLock h.lock:
      if h.closedOps or h.confirmed:
        return false
      inc h.ops
    true

  proc leaveOp(h: Host) =
    withLock h.lock:
      dec h.ops
      broadcast(h.cond)

  proc reply(h: Host, r: sink LcnCarrierRcReply) =
    discard h.sendMsg(toMessage(r))

  func bytesPtr(b: openArray[byte]): ptr UncheckedArray[uint8] =
    if b.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr b[0])

  proc textOf(b: openArray[byte]): string =
    result = newString(b.len)
    for i, c in b:
      result[i] = char(c)

  proc failed(res: LogosResult): Opt[LcnCarrierFailure] =
    let st = readStatus(res)
    if st.isErr:
      return Opt.some(toCarrier(st.error))
    Opt.none(LcnCarrierFailure)

  proc findSub(h: Host, local: uint64): ptr ProxySubObj =
    withLock h.lock:
      var p = h.subs
      while p != nil:
        if p.local == local:
          return p
        p = p.next
    nil

  proc findAsync(h: Host, call: uint64): ptr ProxyAsyncObj =
    withLock h.lock:
      var p = h.asyncs
      while p != nil:
        if p.hostCall == call:
          return p
        p = p.next
    nil

  proc hostedRequest(h: Host, kind: RequestKind): plumbing.Request =
    ## [plan §2.8] A request about a hosted consumer's handle, made through the
    ## attempt's own binding: the consumer and attempt are never the frame's
    ## (RUN-0171, RUN-0172).
    let s = cast[ptr AttemptServices](h.rc.state)
    plumbing.Request(
      kind: kind, origin: moduleOrigin($s.instance), attempt: $s.attempt, hosted: true
    )

  proc hostedReply(h: Host, id: uint64, q: sink plumbing.Request): LcnCarrierRcReply =
    let s = cast[ptr AttemptServices](h.rc.state)
    let reply = s.engine.call(q)
    result = LcnCarrierRcReply(id: id)
    if reply.error.isSome:
      result.failure = Opt.some(
        LcnCarrierFailure(
          code: uint8(ord(reply.error.get.code)),
          message: Opt.some(clip(reply.error.get.message)),
        )
      )
      return
    case q.kind
    of rqMaterialize:
      result.link = Opt.some(reply.conn)
      result.uid = Opt.some(reply.uid)
      result.module = Opt.some(reply.module)
    of rqHostedClosed:
      result.code = Opt.some(uint8(ord(reply.first)))
    else:
      discard

  proc unsubscribe(h: Host, u: LcnCarrierRcUnsubscribe) =
    let res = h.rc.vtable.unsubscribe(h.rc, LogosSubscriptionId(u.sub))
    h.reply(LcnCarrierRcReply(id: u.id, failure: failed(res)))

  proc forwardEvent(
      eventName: cstring,
      cborData: ptr UncheckedArray[uint8],
      cborDataLen: csize_t,
      userData: pointer,
  ) {.cdecl.} =
    ## [G271] The direct handler of a hosted subscription, on a Runtime event
    ## worker: the entry goes to the host, and this returns once the host's
    ## handler has (or the host has ended).
    bindingEnter()
    let p = cast[ptr ProxySubObj](userData)
    let h = p.host
    var data = newSeq[byte](int(cborDataLen))
    for i in 0 ..< data.len:
      data[i] = cborData[i]
    var seqNo: uint64
    withLock h.lock:
      inc p.sent
      seqNo = p.sent
      p.delivering = true
    let sent = h.sendMsg(
      toMessage(
        LcnCarrierRcDelivery(local: p.local, seq: seqNo, name: $eventName, data: data)
      )
    )
    acquire(h.lock)
    if sent.isOk:
      while p.acked < seqNo and not h.confirmed and not h.carrierDown:
        var got = false
        var f: seq[byte]
        try:
          (got, f) = p.nested.tryRecv()
        except Exception:
          got = false
        if got:
          release(h.lock)
          let m = decodeMessage(f)
          if m.isOk and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_rc_unsubscribe:
            if h.enterOp():
              h.unsubscribe(m.get.arm_lcn_Carrier_rc_unsubscribe)
              h.leaveOp()
          acquire(h.lock)
          continue
        wait(h.cond, h.lock)
    p.delivering = false
    release(h.lock)

  proc asyncDone(
      userData: pointer,
      res: LogosResult,
      responseCbor: ptr UncheckedArray[uint8],
      responseCborLen: csize_t,
      owner: LogosResponseOwner,
  ) {.cdecl.} =
    ## The completion of a host's prepared call: it goes to the host.
    bindingEnter()
    let p = cast[ptr ProxyAsyncObj](userData)
    var done = LcnCarrierAsyncDone(call: p.hostCall, failure: failed(res))
    if done.failure.isNone:
      var v = newSeq[byte](int(responseCborLen))
      for i in 0 ..< v.len:
        v[i] = responseCbor[i]
      done.value = Opt.some(v)
    if owner.release != nil:
      owner.release(owner.state)
    discard p.host.sendMsg(toMessage(done))

  proc runJob(h: Host, frame: seq[byte]) =
    ## One lane-1 request, through the attempt's own binding.
    let m = decodeMessage(frame).valueOr:
      return
    type K = LcnCarrierMessageKind
    case m.kind
    of K.lcn_Carrier_rc_call:
      let c = m.arm_lcn_Carrier_rc_call
      let name = textOf(c.`method`)
      var outBuf: ptr UncheckedArray[uint8]
      var outLen: csize_t
      setRuntimeOwned(c.runtime_thread)
      let res = h.rc.vtable.call(
        h.rc,
        cstring(name),
        bytesPtr(c.params),
        csize_t(c.params.len),
        addr outBuf,
        addr outLen,
      )
      setRuntimeOwned(false)
      var r = LcnCarrierRcReply(id: c.id, failure: failed(res))
      if r.failure.isNone:
        var v = newSeq[byte](int(outLen))
        for i in 0 ..< v.len:
          v[i] = outBuf[i]
        r.value = Opt.some(v)
      if outBuf != nil:
        h.rc.vtable.releaseResponse(h.rc, outBuf, outLen)
      h.reply(r)
    of K.lcn_Carrier_rc_subscribe:
      let c = m.arm_lcn_Carrier_rc_subscribe
      # [SPEC INTERFACE §1.5; I106] Every byte of the host's name, before the
      # C string below could cut it at a NUL.
      let name = checkEventName(c.event)
      if name.isErr:
        h.reply(LcnCarrierRcReply(id: c.id, failure: Opt.some(toCarrier(name.error))))
        return
      let p = createShared(ProxySubObj)
      p.host = h
      p.local = c.local
      p.nested.open()
      withLock h.lock:
        p.next = h.subs
        h.subs = p
      var id: LogosSubscriptionId
      let res = h.rc.vtable.subscribe(h.rc, cstring(name.get), forwardEvent, p, addr id)
      var r = LcnCarrierRcReply(id: c.id, failure: failed(res))
      if r.failure.isNone:
        r.sub = Opt.some(uint64(id))
      h.reply(r)
    of K.lcn_Carrier_rc_unsubscribe:
      h.unsubscribe(m.arm_lcn_Carrier_rc_unsubscribe)
    of K.lcn_Carrier_rc_connect_remote:
      let c = m.arm_lcn_Carrier_rc_connect_remote
      var root: ContractRoot
      for i in 0 ..< min(root.len, c.expected_root.len):
        root[i] = c.expected_root[i]
      var b: LogosRuntimeControlBinding
      let res = h.rc.vtable.connectRemote(
        h.rc, bytesPtr(c.endpoint), csize_t(c.endpoint.len), addr root, addr b
      )
      var r = LcnCarrierRcReply(id: c.id, failure: failed(res))
      if r.failure.isNone:
        # [IMPL] A remote binding cannot cross the carrier; this Runtime makes
        # none (it has no enrollments), so this is never reached.
        if b.vtable != nil:
          b.vtable.release(addr b)
        r.failure = Opt.some(
          LcnCarrierFailure(
            code: uint8(ord(ecNotAuthorised)), message: Opt.some("not authorised")
          )
        )
      h.reply(r)
    of K.lcn_Carrier_rc_publish:
      # [SPEC RUNTIME §7.3; plan §2.7] The subscriber sessions of an ordinary
      # publication, in the host's numbers; its payload stays in the host.
      let c = m.arm_lcn_Carrier_rc_publish
      var r = LcnCarrierRcReply(id: c.id, targets: Opt.some(newSeq[LcnCarrierTarget]()))
      let name = checkEventName(c.event)
      if name.isErr:
        r.targets.reset()
        r.failure = Opt.some(toCarrier(name.error))
      elif h.publishUserData != nil:
        let a = cast[ptr AttemptServices](h.publishUserData)
        for t in hostedTargets(a, name.get):
          if t.conn.isHostedConn and hostOfConn(t.conn) == h.index:
            r.targets.get.add(
              LcnCarrierTarget(conn: hostConnOf(t.conn), contract: @(t.root))
            )
      h.reply(r)
    of K.lcn_Carrier_rc_deliver:
      # [SPEC RUNTIME l.1225-1231; G175] Each delivery admitted afresh; the
      # sessions whose contract did not take the payload are diagnostics.
      let c = m.arm_lcn_Carrier_rc_deliver
      var conns: seq[uint64]
      var dropped: seq[(uint64, ErrorCode)]
      for x in c.conns:
        let n = hostedConn(h.index, x)
        if n.isSome:
          conns.add(n.get)
      for x in c.dropped:
        let n = hostedConn(h.index, x.conn)
        if n.isSome:
          dropped.add((n.get, errorCodeOf(x.code).get(ecInvalidParams)))
      # [SPEC INTERFACE §1.5; I106] The host's name, checked as given.
      let name = checkEventName(c.event)
      if name.isErr:
        h.reply(LcnCarrierRcReply(id: c.id, failure: Opt.some(toCarrier(name.error))))
        return
      var admitted: seq[uint64]
      if h.publishUserData != nil:
        for conn in hostedDeliver(
          cast[ptr AttemptServices](h.publishUserData), name.get, conns, dropped
        ):
          admitted.add(hostConnOf(conn))
      h.reply(LcnCarrierRcReply(id: c.id, admitted: Opt.some(admitted)))
    of K.lcn_Carrier_rc_prepare:
      let c = m.arm_lcn_Carrier_rc_prepare
      let p = createShared(ProxyAsyncObj)
      p.host = h
      p.hostCall = c.call
      var opts = LogosAsyncOptions(
        abiVersion: AsyncCallAbiVersion,
        structSize: csize_t(sizeof(LogosAsyncOptions)),
        hasTimeout: c.timeout_ms.isSome,
        timeoutMs: c.timeout_ms.get(0),
      )
      var cbs = LogosAsyncCallbacks(
        abiVersion: AsyncCallAbiVersion,
        structSize: csize_t(sizeof(LogosAsyncCallbacks)),
        complete: asyncDone,
        userData: p,
      )
      let name = textOf(c.`method`)
      let res = h.rc.vtable.prepareCall(
        h.rc,
        cstring(name),
        bytesPtr(c.params),
        csize_t(c.params.len),
        addr opts,
        addr cbs,
        addr p.call,
      )
      let f = failed(res)
      if f.isNone:
        withLock h.lock:
          p.next = h.asyncs
          h.asyncs = p
      else:
        freeShared(p)
      h.reply(LcnCarrierRcReply(id: c.id, failure: f))
    of K.lcn_Carrier_rc_async_release:
      let c = m.arm_lcn_Carrier_rc_async_release
      let p = h.findAsync(c.call)
      if p != nil and p.call.vtable != nil:
        p.call.vtable.release(addr p.call)
        p.call.vtable = nil
      h.reply(LcnCarrierRcReply(id: c.id))
    of K.lcn_Carrier_rc_materialize:
      # [plan §2.8; part 4b-3.3] The Runtime's §4.1 checks against its current
      # state; the host connects itself with what it retained.
      let c = m.arm_lcn_Carrier_rc_materialize
      # [SPEC RUNTIME l.965 (RUN-0177); INTERFACE §5.2 l.3904-3906] The
      # construction input as the module gave it: the Runtime rebuilds the
      # contract itself, as the direct binding does, and never takes the
      # host's word for it (RUNTIME l.954).
      let set = acceptSchemaResponse(c.schema, AcceptOptions(system: true)).valueOr:
        h.reply(
          LcnCarrierRcReply(
            id: c.id,
            failure: Opt.some(
              LcnCarrierFailure(
                code: uint8(ord(ecInvalidParams)),
                message: Opt.some("invalid construction input"),
              )
            ),
          )
        )
        return
      var q = h.hostedRequest(rqMaterialize)
      q.route = c.route
      for i in 0 ..< min(q.root.len, c.expected_root.len):
        q.root[i] = c.expected_root[i]
      q.rebuilt = c.expected_root.len == q.root.len and set.primary.root == q.root
      q.material = c.material
      var r = h.hostedReply(c.id, q)
      h.reply(r)
    of K.lcn_Carrier_rc_link_result:
      let c = m.arm_lcn_Carrier_rc_link_result
      var q = h.hostedRequest(rqHostedResult)
      q.conn = c.link
      q.connectFailed = c.cause.isSome
      q.failCause = c.cause.get(0)
      q.code = errorCodeOf(c.code.get(0)).get(ecTransport)
      h.reply(h.hostedReply(c.id, q))
    of K.lcn_Carrier_rc_link_admit:
      let c = m.arm_lcn_Carrier_rc_link_admit
      var q = h.hostedRequest(rqHostedAdmit)
      q.conn = c.link
      q.op = c.op
      if c.closed.isSome:
        q.closed = Opt.some(errorCodeOf(c.closed.get).get(ecTransport))
      if c.op == 1:
        # [SPEC INTERFACE §1.5] The module's bytes, checked as given.
        let name = checkEventName(c.name.get(@[]))
        if name.isErr:
          h.reply(LcnCarrierRcReply(id: c.id, failure: Opt.some(toCarrier(name.error))))
          return
        q.bare = name.get
      else:
        q.bare = textOf(c.name.get(@[]))
      h.reply(h.hostedReply(c.id, q))
    of K.lcn_Carrier_rc_link_closed:
      let c = m.arm_lcn_Carrier_rc_link_closed
      var q = h.hostedRequest(rqHostedClosed)
      q.conn = c.link
      q.code = errorCodeOf(c.code).get(ecTransport)
      h.reply(h.hostedReply(c.id, q))
    of K.lcn_Carrier_rc_link_released:
      let c = m.arm_lcn_Carrier_rc_link_released
      var q = h.hostedRequest(rqHostedReleased)
      q.conn = c.link
      h.reply(h.hostedReply(c.id, q))
    else:
      discard

  proc workerLoop(s: HostSupervisor) =
    setRuntimeOwned(false)
    while true:
      var j: ProxyJob
      try:
        j = s.jobs.recv()
      except Exception:
        return
      if j.host == nil:
        return
      withLock s.lock:
        dec s.idle
        dec s.queued
      if j.host.enterOp():
        runJob(j.host, j.frame)
        j.host.leaveOp()
      dropHost(j.host)
      withLock s.lock:
        inc s.idle

  proc workerMain(s: HostSupervisor) {.thread.} =
    workerLoop(s)
    releasePerThread()

  proc enqueue(s: HostSupervisor, h: Host, f: seq[byte]) =
    ## Supervision thread: a request for a proxy worker; the pool grows while
    ## every worker is busy, up to its bound.
    retain(h)
    var grow = false
    withLock s.lock:
      inc s.queued
      if s.idle == 0 and s.workerCount < MaxProxyWorkers:
        grow = true
        inc s.workerCount
        inc s.idle
    if grow:
      try:
        createThread(s.workers[s.workerCount - 1], workerMain, s)
      except Exception:
        withLock s.lock:
          dec s.workerCount
          dec s.idle
    try:
      s.jobs.send(ProxyJob(host: h, frame: f))
    except Exception:
      withLock s.lock:
        dec s.queued
      dropHost(h)

  proc asyncOp(h: Host, m: LcnCarrierMessage) =
    ## Supervision thread: submit and cancel never block, and keep the order the
    ## host sent them in.
    type K = LcnCarrierMessageKind
    if not h.enterOp():
      return
    let call =
      if m.kind == K.lcn_Carrier_rc_async_submit:
        m.arm_lcn_Carrier_rc_async_submit.call
      else:
        m.arm_lcn_Carrier_rc_async_cancel.call
    let p = h.findAsync(call)
    if p != nil and p.call.vtable != nil:
      if m.kind == K.lcn_Carrier_rc_async_submit:
        p.call.vtable.submit(addr p.call)
      else:
        p.call.vtable.cancel(addr p.call)
    h.leaveOp()

  # The supervision thread ------------------------------------------------------------------

  proc carrierLost(h: Host, why: string) =
    ## [SPEC RUNTIME RUN-0812] Terminal: the host is ended. A plain end of the
    ## carrier after `released` is the orderly exit, which is waited for.
    var ending = false
    withLock h.lock:
      if not h.carrierDown:
        h.carrierDown = true
        if why.len > 0:
          h.lostReason = clipText(why)
        ending = why.len > 0 or not h.released
      broadcast(h.cond)
    if ending:
      h.terminate(if why.len > 0: why else: "the carrier was closed")

  proc route(s: HostSupervisor, h: Host, f: seq[byte]): bool =
    ## One frame from the host; false once its carrier is lost.
    type K = LcnCarrierMessageKind
    when defined(lcnTestHooks):
      if testBreak(h):
        h.carrierLost("the carrier to the Module Host failed: a malformed frame")
        return false
    when defined(lcnTestHooks):
      trace(f)
    let m = decodeMessage(f).valueOr:
      h.carrierLost("the carrier to the Module Host failed: a frame does not decode")
      return false
    case m.kind
    of K.lcn_Carrier_initialized, K.lcn_Carrier_applied:
      try:
        h.lane0.send(f)
      except Exception:
        discard
    of K.lcn_Carrier_init_failed, K.lcn_Carrier_fatal:
      withLock h.lock:
        h.orderly = true # [R7 (c)]
      try:
        h.lane0.send(f)
      except Exception:
        discard
    of K.lcn_Carrier_released:
      withLock h.lock:
        h.released = true
        h.orderly = true
      try:
        h.lane0.send(f)
      except Exception:
        discard
    of K.lcn_Carrier_rc_call, K.lcn_Carrier_rc_subscribe,
        K.lcn_Carrier_rc_connect_remote, K.lcn_Carrier_rc_publish,
        K.lcn_Carrier_rc_deliver, K.lcn_Carrier_rc_prepare,
        K.lcn_Carrier_rc_async_release, K.lcn_Carrier_rc_materialize,
        K.lcn_Carrier_rc_link_result, K.lcn_Carrier_rc_link_admit,
        K.lcn_Carrier_rc_link_closed, K.lcn_Carrier_rc_link_released:
      s.enqueue(h, f)
    of K.lcn_Carrier_rc_unsubscribe:
      let u = m.arm_lcn_Carrier_rc_unsubscribe
      if u.in_handler.isSome:
        let p = h.findSub(u.in_handler.get)
        var beside = false
        if p != nil:
          withLock h.lock:
            if p.delivering:
              beside = true
              try:
                p.nested.send(f)
              except Exception:
                beside = false
              broadcast(h.cond)
        if beside:
          return true
      s.enqueue(h, f)
    of K.lcn_Carrier_rc_delivered:
      let d = m.arm_lcn_Carrier_rc_delivered
      let p = h.findSub(d.local)
      if p != nil:
        var ahead = false
        withLock h.lock:
          # [SPEC RUNTIME l.954, l.956; G267] The host's frames are untrusted
          # input: an acknowledgement of an entry not yet sent would let later
          # entries pass before its handler returned (G178).
          if d.seq > p.sent:
            ahead = true
          elif d.seq > p.acked:
            p.acked = d.seq
          broadcast(h.cond)
        if ahead:
          h.carrierLost(
            "the carrier to the Module Host failed: an acknowledgement of an entry not sent"
          )
          return false
    of K.lcn_Carrier_rc_async_submit, K.lcn_Carrier_rc_async_cancel:
      h.asyncOp(m)
    of K.lcn_Carrier_call_ended:
      h.toDispatch(m.arm_lcn_Carrier_call_ended.call, f)
    of K.lcn_Carrier_scoped_check:
      h.toDispatch(m.arm_lcn_Carrier_scoped_check.call, f)
    of K.lcn_Carrier_scoped_admit:
      h.toDispatch(m.arm_lcn_Carrier_scoped_admit.call, f)
    of K.lcn_Carrier_scoped_done:
      h.toDispatch(m.arm_lcn_Carrier_scoped_done.call, f)
    of K.lcn_Carrier_io_hello, K.lcn_Carrier_io_established, K.lcn_Carrier_io_dispatch,
        K.lcn_Carrier_io_stop, K.lcn_Carrier_io_closed, K.lcn_Carrier_io_subscribe,
        K.lcn_Carrier_io_unsubscribe, K.lcn_Carrier_io_publish_failed,
        K.lcn_Carrier_io_publish_result, K.lcn_Carrier_io_local_failure:
      # [G273] An event of the host's loop, as the Runtime's own loop reports
      # it. A host without an endpoint has no loop to report from.
      var served: bool
      withLock h.lock:
        served = h.endpointPath != nil
      let ev = toEvent(m, h.index)
      if not served or ev.isErr:
        h.carrierLost(
          "the carrier to the Module Host failed: " &
            (if served: ev.error else: "an endpoint event from a host with no endpoint")
        )
        return false
      if ev.get.isSome and s.onIo != nil:
        s.onIo(ev.get.get, s.onIoCtx)
    else:
      h.carrierLost(
        "the carrier to the Module Host failed: an unexpected " & $m.kind & " message"
      )
      return false
    true

  proc readHost(s: HostSupervisor, h: Host, r: var FrameReader) =
    var frames: seq[seq[byte]]
    let (o, why) = readFrames(h.daemonFd, r, frames)
    for f in frames:
      if not s.route(h, f):
        return
    case o
    of roFrames:
      discard
    of roClosed:
      h.carrierLost("")
    of roFailed:
      h.carrierLost("the carrier to the Module Host failed: " & why)

  proc confirm(s: HostSupervisor, h: Host, r: var FrameReader) =
    ## [R3] The host is reaped and its group is gone: what it wrote last is
    ## read, then the end is final.
    for _ in 0 ..< 64:
      var down: bool
      withLock h.lock:
        down = h.carrierDown
      if down:
        break
      var p = TPollfd(fd: h.daemonFd, events: POLLIN)
      if posix.poll(addr p, 1, 0) <= 0:
        break
      s.readHost(h, r)
    var e: HostEnd
    withLock h.lock:
      h.carrierDown = true
      e = h.endOf()
    h.stopSender()
    when defined(lcnTestHooks):
      recordEnd(e)
    # [R27] The Runtime hears of the end before the Loader's waits return, so
    # the end is handled before any answer the Loader gives because of it.
    if s.onEnd != nil:
      s.onEnd(s.onEndCtx, h, e)
    withLock h.lock:
      h.confirmed = true
      broadcast(h.cond)
    h.endDispatches()
    discard posix.shutdown(SocketHandle(h.daemonFd), SHUT_RDWR)
    try:
      h.lane0.send(@[])
    except Exception:
      discard

  proc reapStep(s: HostSupervisor, h: Host, r: var FrameReader): bool =
    ## One supervision step for a live host; true once its end is confirmed.
    var pid: cint
    var reaped: bool
    withLock h.lock:
      pid = h.pid
      reaped = h.reaped
    if not reaped:
      var st: cint
      let w = waitpid(Pid(pid), st, WNOHANG)
      if w == Pid(pid):
        withLock h.lock:
          h.reaped = true
          h.waitStatus = st
        reaped = true
      elif w < 0 and errno == ECHILD:
        withLock h.lock:
          h.reaped = true
        reaped = true
    if not reaped:
      return false
    var killed: bool
    withLock h.lock:
      killed = h.groupKilled
      h.groupKilled = true
    if not killed:
      discard kill(Pid(-pid), SIGKILL)
    when defined(lcnTestHooks):
      if testHeld(h):
        return false
    if kill(Pid(-pid), 0) < 0 and errno == ESRCH:
      s.confirm(h, r)
      return true
    false

  proc runSpawns(s: HostSupervisor) =
    ## Supervision thread: the spawns waiting; refused once the Runtime closes.
    var p: ptr SpawnReq
    withLock s.lock:
      p = s.spawns
      s.spawns = nil
    while p != nil:
      let n = p.next
      var pid: cint = -1
      let r =
        if s.closing.load:
          cint(-ECANCELED)
        else:
          when defined(posix):
            var argv = [cstring(ProgramName), nil]
            lcnHostSpawn(
              s.program,
              cast[cstringArray](addr argv[0]),
              s.env,
              p.h.hostFd,
              p.listener,
              p.lock,
              addr pid,
            )
          else:
            cint(-38)
      if r == 0:
        let h = p.h
        retain(h) # the supervision list's
        var late = false
        withLock h.lock:
          h.pid = pid
          h.spawned = true
          late = h.terminating
        if late:
          discard kill(Pid(-pid), SIGKILL)
        withLock s.lock:
          h.listed = true
          h.next = s.hosts
          s.hosts = h
        if s.closing.load:
          # [IMPL] Listed after the close collected the live hosts.
          h.terminate("the Runtime is closing")
      withLock s.lock:
        p.rc = r
        p.done = true
        broadcast(s.spawned)
      p = n

  proc superviseLoop(s: HostSupervisor) =
    var readers: Table[uint, FrameReader]
    var buf: array[64, byte]
    while true:
      s.runSpawns()
      var live, watched: seq[Host]
      var stop: bool
      withLock s.lock:
        var p = s.hosts
        while p != nil:
          live.add(p)
          p = p.next
        # Under the lock: a spawn admitted before the close is run (refused).
        stop = s.closing.load and live.len == 0 and s.spawns == nil
      for h in live:
        if cast[uint](h) notin readers:
          readers[cast[uint](h)] = newCarrierReader()
        var down: bool
        withLock h.lock:
          down = h.carrierDown
        if not down:
          watched.add(h)
      if stop:
        break
      var fds = newSeq[TPollfd](watched.len + 1)
      fds[0] = TPollfd(fd: s.wake[0], events: POLLIN)
      for i, h in watched:
        fds[i + 1] = TPollfd(fd: h.daemonFd, events: POLLIN)
      discard posix.poll(addr fds[0], Tnfds(fds.len), TickMs)
      if (fds[0].revents and POLLIN) != 0:
        while posix.read(s.wake[0], addr buf[0], buf.len) > 0:
          discard
      for i, h in watched:
        if fds[i + 1].revents != 0:
          try:
            s.readHost(h, readers[cast[uint](h)])
          except KeyError:
            discard
      for h in live:
        var done = false
        try:
          done = s.reapStep(h, readers[cast[uint](h)])
        except KeyError:
          discard
        if done:
          readers.del(cast[uint](h))
          withLock s.lock:
            var p = addr s.hosts
            while p[] != nil:
              if p[] == h:
                p[] = h.next
                break
              p = addr p[].next
            h.listed = false
          dropHost(h) # the supervision list's

  proc superviseMain(s: HostSupervisor) {.thread.} =
    superviseLoop(s)
    releasePerThread()

  proc startThreads(s: HostSupervisor): Result[void, string] =
    withLock s.lock:
      if s.started:
        return ok()
      var p: array[2, cint]
      if posix.pipe(p) != 0:
        return err("the supervision wake pipe cannot be made")
      for fd in p:
        discard fcntl(fd, F_SETFD, FD_CLOEXEC)
        discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
      s.wake = p
      try:
        createThread(s.thread, superviseMain, s)
      except Exception as e:
        return err("the supervision thread cannot start: " & e.msg)
      s.started = true
    ok()

  proc busy*(s: HostSupervisor): bool =
    ## A host is still supervised, being spawned, or has a Runtime Control
    ## request queued or running: the Runtime thread is still needed.
    if s == nil:
      return false
    withLock s.lock:
      result =
        s.hosts != nil or s.spawns != nil or s.queued > 0 or s.idle < s.workerCount

  proc closeSupervisor*(s: HostSupervisor) =
    ## [plan §2.3] At engine close: every live host is ended and reaped, then
    ## the threads are joined and everything is freed.
    if s == nil:
      return
    s.closing.store(true)
    var live: seq[Host]
    withLock s.lock:
      var p = s.hosts
      while p != nil:
        live.add(p)
        p = p.next
    for h in live:
      h.terminate("the Runtime is closing")
    var started: bool
    withLock s.lock:
      started = s.started
    if started:
      s.wakeUp()
      try:
        joinThread(s.thread)
      except Exception:
        discard
      var n: int
      withLock s.lock:
        n = s.workerCount
      for _ in 0 ..< n:
        try:
          s.jobs.send(ProxyJob())
        except Exception:
          discard
      for i in 0 ..< n:
        try:
          joinThread(s.workers[i])
        except Exception:
          discard
      for fd in s.wake:
        discard posix.close(fd)
    s.jobs.drainClose()
    var i = 0
    while s.env[i] != nil:
      deallocShared(s.env[i])
      inc i
    deallocShared(s.env)
    deallocShared(s.program)
    deinitCond(s.spawned)
    deinitLock(s.lock)
    freeShared(s)

else:
  # [plan §2.1] Stand-ins: hosted placement is not supported here.
  const Unsupported = "hosted placement is not supported on this platform"

  proc newSupervisor*(program: string, envNames: openArray[string]): HostSupervisor =
    nil

  proc setEndNotify*(s: HostSupervisor, fn: EndNotify, ctx: pointer) =
    discard

  proc newHost*(
      s: HostSupervisor,
      rc: ptr LogosRuntimeControlBinding,
      publish: LogosPublishFn,
      publishUserData: pointer,
      payloadDepth: int,
      lockFd: cint = -1,
  ): Result[Host, string] =
    err(Unsupported)

  proc retain*(h: Host) =
    discard

  proc freeWith*(h: Host, services: ptr AttemptServices) =
    freeShared(services)

  proc dropHost*(h: Host) =
    discard

  proc nextRequest*(h: Host): uint64 =
    0

  proc ended*(h: Host): bool =
    true

  proc sendMsg*(h: Host, m: LcnCarrierMessage): Result[void, string] =
    err(Unsupported)

  proc forwardSubscriptionEnds*(h: Host) =
    discard

  proc forwardSubscriptionEnd*(h: Host, id: uint64, reason: ErrorCode) =
    discard

  proc notify*(h: Host, m: LcnCarrierMessage) =
    discard

  proc spawnProcess*(
      program: string,
      env: openArray[string],
      carrier: cint,
      listener: cint = -1,
      lock: cint = -1,
  ): Result[int, string] =
    err(Unsupported)

  proc spawn*(h: Host, listener: cint = -1, lock: cint = -1): Result[void, string] =
    err(Unsupported)

  proc terminate*(h: Host, reason: string, byRuntime = false): bool {.discardable.} =
    true

  proc noteEnd*(h: Host) =
    discard

  func endHandled*(h: Host): bool =
    false

  proc awaitEnd*(h: Host): HostEnd =
    HostEnd()

  proc endIfConfirmed*(h: Host): Opt[HostEnd] =
    Opt.some(HostEnd())

  proc awaitLane0*(h: Host): Opt[LcnCarrierMessage] =
    Opt.none(LcnCarrierMessage)

  proc busy*(s: HostSupervisor): bool =
    false

  proc closeSupervisor*(s: HostSupervisor) =
    discard

  proc setIoSink*(s: HostSupervisor, fn: IoSink, ctx: pointer) =
    discard

  func index*(h: Host): uint64 =
    0

  proc setEndpoint*(
      h: Host, listener: cint, path, runtimeId: string, transport: TransportConfig
  ): Result[void, string] =
    err(Unsupported)

  proc endpointInit*(
      h: Host
  ): Opt[tuple[path, runtimeId: string, transport: seq[uint64]]] =
    Opt.none(tuple[path, runtimeId: string, transport: seq[uint64]])

  proc setTransport*(h: Host, transport: TransportConfig): Result[void, string] =
    err(Unsupported)

  proc transportInit*(h: Host): seq[uint64] =
    @[]

  proc submitHosted*(
      ctx: pointer, cmd: var IoCommand
  ): SubmitResult {.nimcall, gcsafe, raises: [].} =
    sbStopped

  proc findHost*(s: HostSupervisor, conn: uint64): Host =
    nil

  proc beginDispatch*(h: Host, call: uint64): HostDispatch =
    nil

  proc nextFrame*(d: HostDispatch): Opt[seq[byte]] =
    Opt.some(newSeq[byte]())

  proc endDispatch*(d: HostDispatch) =
    discard

  when defined(lcnTestHooks):
    # [DECISIONS I92] No Module Host here, so none to arm.
    proc setWipeAudit*(patterns: openArray[seq[byte]]) =
      discard

    proc wipeAuditInit*(): seq[seq[byte]] =
      @[]
