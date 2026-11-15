## TRANSPORT §8.2, §8.6; DECISIONS I90: the engine's port to the transport I/O
## thread (`IoPort` of the 4b-2 plan §2.1, §2.3).
##
## One per engine, made at open; the loop itself starts only when needed
## (`ensureStarted`, on the Runtime thread): at open when a routing rule selects
## local transport, and in 4b-3 when Module Hosts are possible. An engine
## without such a rule never starts an I/O thread.
##
## The guard. `stopTransport` frees the loop, so a late `submit` from a module
## thread (a publisher) would read freed memory. Every port call counts itself
## in `users` and checks `stopping` before it touches the loop; `closeTransport`
## sets `stopping`, waits until no call is inside, and only then stops the loop.
## Events the I/O thread reports after that are dropped by the sink.
##
## Hosted endpoints (4b-3.2; G273). A command for a hosted connection or
## endpoint (`hostnum.nim`) goes to its Module Host through `hosted`, the
## hook the host supervisor sets, before the loop is looked at: a host's
## endpoint is served by the host's own loop.
##
## [IMPL] The Runtime thread submits only uncharged commands, so it never sees
## `sbBusy` (`submitOwner` asserts it); charged ones (a successful Response, an
## Event) come from call workers and publishing threads, which may wait.

{.push raises: [], gcsafe.}

import std/[atomics, os]
import results
import ../transport/io/[api, loop, sock]
import ./hostnum

export api

type
  HostedSubmit* =
    proc(ctx: pointer, cmd: var IoCommand): SubmitResult {.nimcall, gcsafe, raises: [].}
    ## takes `cmd` unless it answers `sbBusy`

  TransportPortsObj = object
    loop: Loop ## nil until `ensureStarted`
    hosted: Atomic[pointer] ## a `HostedSubmit`, set before the first host
    hostedCtx: Atomic[pointer]
    stopping: Atomic[bool]
    users: Atomic[int]
    nextConn: Atomic[uint64]
    euid*: uint32 ## [SPEC TRANSPORT §8.2; TRN-0187] the Runtime's effective uid
    config*: TransportConfig ## validated at open

  TransportPorts* = ptr TransportPortsObj

var onOwner {.threadvar.}: bool ## the Runtime thread of some engine

proc newTransportPorts*(config: TransportConfig): Result[TransportPorts, string] =
  ## Validates `config`; starts nothing.
  ?config.validate()
  let p = createShared(TransportPortsObj)
  p.config = config
  when unixStream:
    p.euid = geteuid()
  ok(p)

proc freeTransportPorts*(p: TransportPorts) =
  ## After `closeTransport`.
  if p != nil:
    freeShared(p)

func started*(p: TransportPorts): bool =
  p != nil and p.loop != nil

proc ensureStarted*(
    p: TransportPorts, sink: IoSink, ctx: pointer
): Result[void, string] =
  ## [Rev R12] Starts the I/O thread once; idempotent. On the Runtime thread,
  ## which becomes the loop's registered owner (`submitWait` refuses there).
  if p.loop != nil:
    return ok()
  if p.stopping.load:
    return err("the transport is closing")
  let lp = ?startTransport(p.config, sink, ctx)
  p.loop = lp
  lp.registerOwnerThread()
  onOwner = true
  ok()

proc setHosted*(p: TransportPorts, fn: HostedSubmit, ctx: pointer) =
  ## The host supervisor's route for hosted commands; once, on the Runtime
  ## thread, before the first host is spawned.
  p.hostedCtx.store(ctx, moRelease)
  p.hosted.store(cast[pointer](fn), moRelease)

proc hostedContext*(p: TransportPorts): pointer =
  ## The host supervisor `setHosted` gave; nil before the first host.
  if p == nil:
    return nil
  p.hostedCtx.load(moAcquire)

proc enter(p: TransportPorts): bool =
  discard p.users.fetchAdd(1)
  if p.stopping.load or p.loop == nil:
    discard p.users.fetchSub(1)
    return false
  true

proc leave(p: TransportPorts) =
  discard p.users.fetchSub(1)

proc trySubmit*(p: TransportPorts, cmd: var IoCommand): SubmitResult =
  ## `submit` that takes `cmd` only when it is queued (`sbOk`): a busy command
  ## stays with the caller, to be offered again without a copy.
  if p == nil:
    return sbStopped
  if cmd.isHostedCommand:
    let fn = cast[HostedSubmit](p.hosted.load(moAcquire))
    if fn == nil or p.stopping.load:
      return sbStopped
    return fn(p.hostedCtx.load(moAcquire), cmd)
  if not p.enter():
    return sbStopped
  result = p.loop.trySubmit(cmd)
  p.leave()

proc submit*(p: TransportPorts, cmd: sink IoCommand): SubmitResult =
  ## Never blocks. `sbStopped` once the port is closing or was never started.
  var cmd = cmd
  p.trySubmit(cmd)

proc submitOwner*(p: TransportPorts, cmd: sink IoCommand): SubmitResult =
  ## The Runtime thread's submit: an uncharged command, which is never busy.
  result = p.submit(cmd)
  doAssert result != sbBusy, "the Runtime thread submitted a charged command"

proc submitWait*(
    p: TransportPorts, cmd: sink IoCommand, timeout = Opt.none(int64)
): SubmitResult =
  ## [SPEC TRANSPORT §5.2 l.806-807] `submit`, waiting while the shared output
  ## budget is full, up to `timeout` nanoseconds (none: no finite bound), and
  ## ending early once the port closes. `sbRefused` on the I/O thread or a
  ## Runtime thread, whose waiting could keep the budget from draining.
  if isIoThread() or onOwner:
    return sbRefused
  var cmd = cmd
  var waited = 0'i64
  while true:
    let r = p.trySubmit(cmd)
    if r != sbBusy:
      return r
    if timeout.isSome and waited >= timeout.get:
      return sbBusy
    sleep(1) # [IMPL] 1 ms between attempts
    waited += 1_000_000

proc newConnId*(p: TransportPorts): ConnId =
  ## [SPEC TRANSPORT §8.2] A fresh id for an outbound connection, below
  ## `AcceptedConnBase`; never reused by this engine.
  let id = p.nextConn.fetchAdd(1) + 1
  doAssert id < AcceptedConnBase
  id

proc closing*(p: TransportPorts): bool =
  p != nil and p.stopping.load

proc closeTransport*(p: TransportPorts) =
  ## Stops the I/O thread once no port call is inside; later calls get
  ## `sbStopped`. Not from the sink or the I/O thread.
  if p == nil:
    return
  if p.stopping.exchange(true):
    return
  while p.users.load > 0:
    sleep(1)
  if p.loop != nil:
    p.loop.stopTransport()
    p.loop = nil

proc releaseOwner*() =
  ## The Runtime thread is leaving.
  if onOwner:
    unregisterOwnerThread()
    onOwner = false
