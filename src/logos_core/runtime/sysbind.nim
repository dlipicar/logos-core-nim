## RUNTIME §9 l.1561-1588, l.3675; TRANSPORT §8.1.2; DECISIONS G492, G493
## (Tier 5 step 5-6a-2): the Runtime-owned system-service binding of the
## marked Package Manager, on the Runtime thread.
##
## The binding names one local provider realization, its system-service
## endpoint, the pinned contract and the one method `get_runtime_handoff`
## (C4: no event). Bootstrap policy authorizes it: the host configuration's
## `package_manager` mark (G490), never active policy [IMPL]. Its checks run
## at the instance's readiness (RUN-0313..0317), and the first Hello is the
## last of them (RUN-0318, RUN-0319): until it succeeds the binding is
## `bsPending`. `logos_runtime_start` does not wait for it (G493).
##
## This module keeps what has no engine state in it: the record, the
## engine's request queue (one Request in flight, at most `MaxParked`
## waiting, each with its own end) and the retry's timing. `engine.nim`
## wires it to the instance, the ticket store and the transport.

{.push raises: [], gcsafe.}

import std/deques
import results
import logos_sdk/hash/hashinput
import ../transport/io/api

export results, deques

const
  HandoffMethod* = "get_runtime_handoff" ## [SPEC PM §12; C4] the binding's one method
  MaxParked* = 64 ## [G492, ruling 1] handoff requests waiting behind the one in flight
  PendingWaitNs* = 10_000_000_000'i64
    ## [IMPL; G492] how long a request waits for a pending binding at most
  RetryFirstNs* = 1_000_000_000'i64 ## [IMPL; G492] the first retry's delay
  RetryMaxNs* = 30_000_000_000'i64 ## [IMPL; G492] the retry's longest delay

type
  BindState* = enum
    bsPending ## checked; its first Hello has not succeeded yet
    bsReady ## its first Hello succeeded
    bsInvalid ## ended: no ticket, admission or retry any more

  HandoffResume* = proc(outcome: CallOutcome) {.closure, gcsafe, raises: [].}
    ## [G492] The requester's continuation, called once on the Runtime thread
    ## with the call's outcome: the response map checked against the method's
    ## schema and commitment by the I/O thread, or a failure.

  HandoffRequest* = ref object
    id*: uint64 ## its handle (`withdraw`)
    params*: seq[byte] ## the encoded `get_runtime_handoff` request map
    deadline*: int64 ## the requester's own end, on the engine's monotonic clock
    parkedAt*: int64 ## when it was queued, on the same clock
    resume*: HandoffResume
    tag*: uint64 ## its call tag on the session, once sent; 0: not sent

  SysBinding* = ref object
    ## [SPEC RUNTIME l.1568-1575; TRN-0334] One system-service binding.
    id*: uint64
    responsibility*: string ## what it serves: the runtime handoff (RUNTIME l.1310)
    instance*: string
    attempt*: string ## the realization's attempt token
    endpoint*: EndpointId ## the system-service endpoint
    path*: string ## its exact path (TRANSPORT l.1098)
    provider*: string ## the module name the Hello selects
    contract*: Digest ## the pinned Package Manager contract
    schema*: seq[byte] ## its construction input, for the client's checks
    methodRoot*: Digest ## `get_runtime_handoff`'s declaration subtree root
    state*: BindState
    conn*: ConnId ## the engine's session to it; 0: none
    connecting*: bool ## a Hello is in progress on `conn`
    retryAt*: Opt[int64] ## when the next Hello is tried
    delay*: int64 ## the delay after the next failure
    failures*: int ## Hellos that failed, each logged once
    nextTag*: uint64
    inflight*: HandoffRequest ## the one Request sent and not answered; nil: none
    parked*: Deque[HandoffRequest]

func realization*(b: SysBinding): string =
  b.instance & "/" & b.attempt

func live*(b: SysBinding): bool =
  not b.isNil and b.state != bsInvalid

func sendable*(b: SysBinding): bool =
  ## A Request can be sent now: the session is established.
  b.live and b.conn != 0 and not b.connecting

func full*(b: SysBinding): bool =
  ## [G492, ruling 1] One in flight and `MaxParked` waiting, or `MaxParked`
  ## waiting while none can be sent.
  b.parked.len >= MaxParked

proc failed*(b: SysBinding, now: int64): int64 =
  ## After a failed Hello: when the next is tried, 1 s doubling to 30 s.
  inc b.failures
  if b.delay <= 0:
    b.delay = RetryFirstNs
  result = now + b.delay
  b.delay = min(b.delay * 2, RetryMaxNs)
  b.retryAt = Opt.some(result)

proc succeeded*(b: SysBinding) =
  b.connecting = false
  b.retryAt = Opt.none(int64)
  b.delay = 0
  b.state = bsReady

func waitEnd*(b: SysBinding, r: HandoffRequest): int64 =
  ## [G492; Fable §11.1 point 1] While the binding is pending a parked request
  ## waits 10 s at most from when it was parked, or to its own deadline if
  ## sooner; on a ready binding its own deadline alone ends its wait.
  if b.state == bsPending:
    min(r.deadline, r.parkedAt + PendingWaitNs)
  else:
    r.deadline

proc take*(b: SysBinding, id: uint64): HandoffRequest =
  ## Removes request `id` from the queue; nil when it is not parked.
  for i in 0 ..< b.parked.len:
    if b.parked[i].id == id:
      result = b.parked[i]
      var rest = initDeque[HandoffRequest]()
      for j in 0 ..< b.parked.len:
        if j != i:
          rest.addLast(b.parked[j])
      b.parked = move rest
      return

func failedWith*(code: ErrorCode, msg: string): CallOutcome =
  CallOutcome(ok: false, failure: InvocationFailure(code: code, message: Opt.some(msg)))
