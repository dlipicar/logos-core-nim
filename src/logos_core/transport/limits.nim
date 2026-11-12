## TRANSPORT §2.1, §2.3, §3.4, §5.1, §8.6 and INTERFACE §4.5.1: the finite,
## configurable limits of one stream connection. A value is checked when it is
## made, so a connection never runs under limits the spec forbids.
##
## Scope and behaviour on exhaustion [SPEC TRANSPORT §8.6] (documented here and in
## `session.nim`):
## - `frameLimit`: per connection, the largest frame body read. A larger length
##   prefix: ProtocolError INVALID_PARAMS, close (§2.1). The reader holds at
##   most `frameLimit + 4` bytes.
## - `peerFrameLimit`: per connection, the largest body sent. An oversized
##   Request fails locally with MODULE_ERROR, an oversized success Response
##   becomes response-err MODULE_ERROR, an oversized Event is not committed and
##   its publication fails (§2.1).
## - `payloadDepth` P: arrays and maps in `params`, `result` or `data`; the whole
##   message may nest P + 1. Deeper: ProtocolError INVALID_PARAMS without
##   detail, close (§2.3). Sending deeper fails locally.
## - `maxInFlight` (callee): execution slots, each held from dispatch until
##   the provider's work ends (`workEnded`), even after its Response or
##   CANCELLED is committed or the connection closed (I52 as revised by A21).
##   At the cap reading continues, so Cancel and Unsubscribe are processed
##   (§6): a further Request waits in the delayed-admission queue, where it is
##   in flight and a Cancel commits CANCELLED without dispatch.
## - `maxDelayedRequests`, `maxDelayedBytes` (callee): that queue. Full:
##   ProtocolError TRANSPORT_ERROR, close; a queued Request is never answered
##   with an error for capacity (there is no overload code).
## - `maxPastCapFrames`, `maxPastCapBytes` (callee): every frame read while the
##   connection is at its cap, in number and in bytes, until a slot frees.
##   Exhausted: ProtocolError TRANSPORT_ERROR, close.
## - `maxCalls` (caller): Requests transmitted with no terminal Response
##   received, abandoned ones included. At the cap a new call fails locally with
##   MODULE_ERROR and nothing is sent; no correlation state is dropped (§3.4).
## - `maxSubscriptionIds` (both sides): subscription ids used on the connection,
##   which also bounds its subscriptions. At the cap the caller refuses a new
##   Subscribe locally (MODULE_ERROR); the callee closes the connection with
##   ProtocolError TRANSPORT_ERROR before it would forget an id (§5.1).
## Aggregate limits across the connections of one transport I/O thread are in
## `io/aggregate.nim`.

{.push raises: [].}

import results
import ../cbor
import ./framing

export results

const
  MaxPayloadDepth* = DefaultMaxDepth
    ## [IMPL] The largest configurable P (DECISIONS I59): validation,
    ## normalization and hashing count maps and arrays, not schema or value-tree
    ## nodes, and walk with heap stacks, so they support every depth up to
    ## `DefaultMaxDepth` on any common thread stack (I51) and no internal
    ## structure reduces a P within this bound (INTERFACE §4.5.1).
  DefaultMaxInFlight* = 1024 ## [IMPL]
  DefaultMaxCalls* = 1024 ## [IMPL]
  DefaultMaxSubscriptionIds* = 4096 ## [IMPL]
  DefaultMaxDelayedRequests* = 64 ## [IMPL]
  DefaultMaxDelayedBytes* = 32 * 1024 * 1024 ## [IMPL]
  DefaultMaxPastCapFrames* = 4096 ## [IMPL]
  DefaultMaxPastCapBytes* = 64 * 1024 * 1024 ## [IMPL]

type TransportLimits* = object
  frameLimit, peerFrameLimit: uint32
  payloadDepth, maxInFlight, maxCalls, maxSubscriptionIds: int
  maxDelayedRequests, maxDelayedBytes, maxPastCapFrames, maxPastCapBytes: int

func transportLimits*(
    frameLimit: uint32 = MinFrameLimit,
    peerFrameLimit: uint32 = MinFrameLimit,
    payloadDepth = DefaultMaxDepth,
    maxInFlight = DefaultMaxInFlight,
    maxCalls = DefaultMaxCalls,
    maxSubscriptionIds = DefaultMaxSubscriptionIds,
    maxDelayedRequests = DefaultMaxDelayedRequests,
    maxDelayedBytes = DefaultMaxDelayedBytes,
    maxPastCapFrames = DefaultMaxPastCapFrames,
    maxPastCapBytes = DefaultMaxPastCapBytes,
): Result[TransportLimits, string] =
  ## [SPEC TRANSPORT §2.1, §2.3, §8.6; INTERFACE §4.5.1] Both frame maxima at
  ## least 16 MiB (`peerFrameLimit` above it only when the peer separately
  ## established support), P from 128 to `MaxPayloadDepth`, every cap finite and
  ## positive, and the delayed and past-cap byte budgets at least `frameLimit`,
  ## so a maximal Request can always wait (A21).
  if frameLimit < MinFrameLimit:
    return err("the active frame maximum is below 16 MiB (TRANSPORT §2.1)")
  if peerFrameLimit < MinFrameLimit:
    return err("the peer frame maximum is below 16 MiB (TRANSPORT §2.1)")
  if payloadDepth < MinMaxDepth or payloadDepth > MaxPayloadDepth:
    return err(
      "the payload depth is outside " & $MinMaxDepth & ".." & $MaxPayloadDepth &
        " (INTERFACE §4.5.1)"
    )
  if maxInFlight < 1 or maxCalls < 1 or maxSubscriptionIds < 1 or maxDelayedRequests < 1 or
      maxPastCapFrames < 1:
    return err("a per-connection cap is not positive (TRANSPORT §8.6)")
  if int64(maxDelayedBytes) < int64(frameLimit) or
      int64(maxPastCapBytes) < int64(frameLimit):
    return err("a delayed or past-cap byte budget is below the frame maximum")
  ok(
    TransportLimits(
      frameLimit: frameLimit,
      peerFrameLimit: peerFrameLimit,
      payloadDepth: payloadDepth,
      maxInFlight: maxInFlight,
      maxCalls: maxCalls,
      maxSubscriptionIds: maxSubscriptionIds,
      maxDelayedRequests: maxDelayedRequests,
      maxDelayedBytes: maxDelayedBytes,
      maxPastCapFrames: maxPastCapFrames,
      maxPastCapBytes: maxPastCapBytes,
    )
  )

func defaultLimits*(): TransportLimits =
  ## 16 MiB both ways, P = 1024 [IMPL-DECISION G59], the default caps.
  TransportLimits(
    frameLimit: MinFrameLimit,
    peerFrameLimit: MinFrameLimit,
    payloadDepth: DefaultMaxDepth,
    maxInFlight: DefaultMaxInFlight,
    maxCalls: DefaultMaxCalls,
    maxSubscriptionIds: DefaultMaxSubscriptionIds,
    maxDelayedRequests: DefaultMaxDelayedRequests,
    maxDelayedBytes: DefaultMaxDelayedBytes,
    maxPastCapFrames: DefaultMaxPastCapFrames,
    maxPastCapBytes: DefaultMaxPastCapBytes,
  )

func frameLimit*(l: TransportLimits): uint32 =
  l.frameLimit

func peerFrameLimit*(l: TransportLimits): uint32 =
  l.peerFrameLimit

func payloadDepth*(l: TransportLimits): int =
  l.payloadDepth

func maxInFlight*(l: TransportLimits): int =
  l.maxInFlight

func maxCalls*(l: TransportLimits): int =
  l.maxCalls

func maxSubscriptionIds*(l: TransportLimits): int =
  l.maxSubscriptionIds

func maxDelayedRequests*(l: TransportLimits): int =
  l.maxDelayedRequests

func maxDelayedBytes*(l: TransportLimits): int =
  l.maxDelayedBytes

func maxPastCapFrames*(l: TransportLimits): int =
  l.maxPastCapFrames

func maxPastCapBytes*(l: TransportLimits): int =
  l.maxPastCapBytes

func frameReader*(l: TransportLimits): FrameReader =
  ## The reader for `frameLimit`, already known to be at least 16 MiB.
  newFrameReader(l.frameLimit).valueOr:
    newFrameReader()
