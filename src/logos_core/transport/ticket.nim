## TRANSPORT §8.1, §8.1.1: the `logos.route-ticket.random-256` profile, as the
## issuing Runtime's ticket store. Sans-I/O: the caller passes the monotonic
## clock reading and, for tests, the random source. The store is not
## thread-safe; a Runtime serializes access, which makes `redeem` atomic.

{.push raises: [].}

import std/[sysrand, tables]
import results
import ../crypto/blake3

export results

const
  RouteTicketProfile* = "logos.route-ticket.random-256"
  TicketBytes* = 32 ## [SPEC TRANSPORT §8.1.1]
  MaxTicketLifetime* = 60_000_000_000'i64
    ## [SPEC TRANSPORT §8.1.1] 60 seconds, in nanoseconds of the issuer's
    ## monotonic clock

type
  RouteTicket* = array[TicketBytes, byte]

  Nanos* = int64 ## a reading of the issuer's monotonic clock

  RandomSource* = proc(dest: var openArray[byte]): bool {.gcsafe, raises: [].}

  TicketFailure* = enum
    ## Why a ticket was refused. For the issuer's own audit only: the wire
    ## outcome is always the same NOT_AUTHORISED (§8.1).
    tfMalformed ## not exactly 32 bytes
    tfUnknown ## no live record: never issued, consumed, revoked or swept
    tfExpired ## past its expiry (the record is deleted)

  TicketRecord[B] = object
    binding: B
    expires: Nanos

  TicketStore*[B] = object
    ## The live tickets, keyed by the `logos.hash-suite.blake3-256` digest of
    ## the ticket. The raw ticket is never stored [SPEC TRANSPORT §8.1.1].
    live: Table[Blake3Digest, TicketRecord[B]]

proc osRandom*(dest: var openArray[byte]): bool =
  ## The operating system's CSPRNG (`std/sysrand`: getrandom, arc4random,
  ## BCryptGenRandom), as RFC 4086 asks [SPEC TRANSPORT §8.1.1].
  urandom(dest)

func len*[B](s: TicketStore[B]): int =
  s.live.len

iterator digests*[B](s: TicketStore[B]): Blake3Digest =
  ## The lookup keys held: digests, never tickets.
  for d in tables.keys(s.live):
    yield d

func earliest*[B](s: TicketStore[B]): Opt[Nanos] =
  ## The earliest expiry of a live record: when `sweep` next deletes one.
  var t = Opt.none(Nanos)
  for r in tables.values(s.live):
    if t.isNone or r.expires < t.get:
      t = Opt.some(r.expires)
  t

proc sweep*[B](s: var TicketStore[B], now: Nanos) =
  ## Deletes every expired record [SPEC TRANSPORT §8.1.1].
  var gone: seq[Blake3Digest]
  for d, r in tables.pairs(s.live):
    if now >= r.expires:
      gone.add(d)
  for d in gone:
    s.live.del(d)

proc issue*[B](
    s: var TicketStore[B],
    binding: B,
    now, routeExpires: Nanos,
    rng: RandomSource = osRandom,
): Result[RouteTicket, string] =
  ## [SPEC TRANSPORT §8.1.1] A fresh ticket for a route whose constraints and
  ## allow decision are fixed in `binding`. It expires with the route and at most
  ## 60 s after `now`. A value that collides with an unexpired ticket is
  ## discarded and another generated.
  let expires = min(routeExpires, now + MaxTicketLifetime)
  if expires <= now:
    return err("the route has already expired")
  s.sweep(now)
  for _ in 0 ..< 16:
    var t: RouteTicket
    if not rng(t):
      return err("the random source failed")
    let d = blake3(t)
    if d in s.live:
      continue
    s.live[d] = TicketRecord[B](binding: binding, expires: expires)
    return ok(t)
  err("the random source keeps repeating live tickets")

proc lookup[B](
    s: var TicketStore[B], token: openArray[byte], now: Nanos
): Result[Blake3Digest, TicketFailure] =
  if token.len != TicketBytes:
    return err(tfMalformed)
  let d = blake3(token)
  var expired = false
  s.live.withValue(d, r):
    expired = now >= r.expires
  do:
    return err(tfUnknown)
  if expired:
    s.live.del(d)
    return err(tfExpired)
  ok(d)

proc validate*[B](
    s: var TicketStore[B], token: openArray[byte], now: Nanos
): Result[B, TicketFailure] =
  ## [SPEC TRANSPORT §8.1, §8.1.1] The binding of a live ticket, without
  ## consuming it. An expired record is deleted.
  let d = ?s.lookup(token, now)
  var b: B
  s.live.withValue(d, r):
    b = r.binding
  ok(b)

proc redeem*[B](
    s: var TicketStore[B], token: openArray[byte], now: Nanos
): Result[B, TicketFailure] =
  ## [SPEC TRANSPORT §8.1, §8.1.1] Consumes a live ticket: its record is
  ## deleted, so only one redemption succeeds and a replay finds nothing.
  let d = ?s.lookup(token, now)
  var r: TicketRecord[B]
  if not s.live.pop(d, r):
    return err(tfUnknown)
  ok(r.binding)

proc revoke*[B](
    s: var TicketStore[B], matches: proc(b: B): bool {.gcsafe, raises: [].}
): int =
  ## Deletes the records whose binding `matches` (a revoked route or decision);
  ## returns how many [SPEC TRANSPORT §8.1.1].
  var gone: seq[Blake3Digest]
  for d, r in tables.pairs(s.live):
    if matches(r.binding):
      gone.add(d)
  for d in gone:
    s.live.del(d)
  gone.len
