## TRANSPORT §8.6: the aggregate limits of one transport I/O thread, as
## sans-I/O pools, and their documentation.
##
## Scope: "loop" is one I/O thread, which is one process; "conn" is one
## connection. Every value is in `TransportConfig` (`api.nim`), validated
## before the loop starts: finite and positive, every input pool at least
## `frameLimit`, and `connOutputBytes` at least `peerFrameLimit` plus
## `controlReserve` [SPEC TRANSPORT §2.1, §8.6].
##
## | Limit | Scope | Default [IMPL] | On exhaustion |
## |---|---|---|---|
## | `maxInbound` (accepted connections, pending Hellos included) | loop | 1024 | accept, ProtocolError MODULE_ERROR without reading, close |
## | `maxPendingHellos` | loop | 64 | same |
## | `helloTimeout` | conn | 10 s (G61) | callee: close without ProtocolError; caller: TRANSPORT_ERROR |
## | `maxHelloInputBytes` (frame bodies read before establishment) | loop | 32 MiB | the frame waits, bounded by `helloTimeout` |
## | `maxOutbound` | loop | 1024 | caller: local MODULE_ERROR, nothing opened |
## | `maxInputBytes` (frame bodies held after establishment: being read, in a delayed-admission queue, or Events not yet released by the caller's owner) | loop | 256 MiB | reading pauses up to `admissionTimeout` (10 s), then ProtocolError TRANSPORT_ERROR, close |
## | `maxOutputBytes` (committed Responses and Events, and control frames while they fit) | loop | 256 MiB | as `connOutputBytes` |
## | `connOutputBytes` | conn | 2 × `peerFrameLimit` + `controlReserve` | Event: overflow, ProtocolError TRANSPORT_ERROR from the final slot, flush up to `closeLinger`, close; ok-Response: waits, not committed; control: the reserve, then ProtocolError TRANSPORT_ERROR and close |
## | `controlReserve` (error Responses, SubscriptionResults, the Hello response) | conn | 64 KiB | ProtocolError TRANSPORT_ERROR from the final slot, close |
## | `writeStallTimeout` | conn | 30 s | close without ProtocolError (not writable) |
## | `closeLinger` | conn | 1 s | close without finishing the flush |
## | `terminationDrain` (in-flight work after the session's authorization ends) | conn | 0 s: termination finishes at once | — |
## | `maxInFlight` (execution slots) | conn | 1024 (I52) | the Request waits in the delayed-admission queue |
## | `maxDelayedRequests` / `maxDelayedBytes` | conn | 64 / 32 MiB | ProtocolError TRANSPORT_ERROR, close (A21) |
## | `maxPastCapFrames` / `maxPastCapBytes` (every frame read while at the cap) | conn | 4096 / 64 MiB | same |
## | `maxTotalExecuting` (execution slots) | loop | 4096 | the Request waits in its connection's delayed-admission queue; freed slots go round-robin |
## | `maxCalls` | conn | 1024 (I52) | caller: local MODULE_ERROR, nothing sent |
## | `maxTotalCalls` | loop | 16384 | same |
## | `maxSubscriptionIds` (id history, which bounds subscriptions) | conn | 4096 (I52) | caller: local MODULE_ERROR; callee: ProtocolError TRANSPORT_ERROR, close |
## | `maxTotalSubscriptions` (active, callee side) | loop | 16384 | SubscriptionResult error MODULE_ERROR, the session stays |
## | `maxTotalSubscriptionIds` (id history, both sides) | loop | 65536 | caller: local MODULE_ERROR; callee: ProtocolError TRANSPORT_ERROR, close |
## | `callerUndeliveredBytes` (Event frames handed to the caller's owner and not released) | conn | 32 MiB | reading pauses until `cmdRelease`, with no finite bound; a callee of this implementation closes the connection after its `writeStallTimeout` |
## | `maxPendingOutputBytes` (Response and Event payloads submitted and not yet committed) | loop | 64 MiB | `submit`: `sbBusy`; `submitWait`: waits, up to its deadline or with no finite bound |
##
## Fixed statements: closing a connection ends every subscription on it;
## Responses are never dropped for capacity; no limit promises that a Cancel
## overtakes a frame already committed to the same stream (TRANSPORT §8.6
## l.1357); there is no common overload response.
##
## Bytes outside the pools, each bounded: the 4-byte prefix being read, one
## final ProtocolError slot per connection (under 64 bytes), and the control
## reserve, so committed output across the loop is at most `maxOutputBytes`
## plus `(maxInbound + maxOutbound) × controlReserve`.

{.push raises: [].}

type BytePool* = object ## A loop-wide byte budget, used only on the I/O thread.
  cap*, used*: int

func bytePool*(cap: int): BytePool =
  BytePool(cap: cap)

func available*(p: BytePool): int =
  p.cap - p.used

func tryReserve*(p: var BytePool, n: int): bool =
  ## [SPEC TRANSPORT §8.6] Admission before the bytes are allocated.
  if n < 0 or n > p.cap - p.used:
    return false
  p.used += n
  true

func release*(p: var BytePool, n: int) =
  p.used = max(0, p.used - n)
