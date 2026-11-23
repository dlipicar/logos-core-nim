## Signing with the Runtime's TLS key (Tier 5 step 5-7a-1; DECISIONS G410;
## owner decision B1; 5-7a plan §3.6). docs/REMOTE.md, "Who signs".
##
## The TLS processes hold no key. Each sends the CertificateVerify input of its
## handshake over its control channel (`remote/carrier.nim`, lane 1) and waits
## for the signature:
##
## - **logosd** (`remote.signing` absent or "logosd", the default): logosd's
##   signing service holds the key it loaded from `remote/credential/key.p8`
##   at its start and answers itself (`answer`).
## - **key-holder**: logosd never opens `key.p8`. `logos_keyholder` loads it
##   and answers; logosd relays each request to it unchanged over one socket
##   pair, under logosd's own request id and with the role logosd fixed for
##   the process (`HolderRelay`), and relays the answer back. Both ends run
##   the same checks: `checkSignInput` for the process's role, and a rate
##   limit, logosd's per process and the holder's its own, with its own count
##   (`logos_keyholder.nim`).
## - **process-copy** (tests only, a logosd built with `-d:logosTestSigning`):
##   each TLS process gets the key on its channel at spawn (`testKeyMessage`).
##
## A process may only sign for its own handshakes: the role is the one logosd
## fixed for it, never one a request names. A refused request is the
## handshake's failure at that process.

{.push raises: [].}

import std/[monotimes, os, strutils, tables]
import results
import logos_sdk/base/wipe
import ../durable
import ../remote/carrier
import ../transport/tls/[p256, signing]
import ./[credential, session]

export carrier, signing

const
  HolderRate* = 100 ## [IMPL] the key holder's signatures a second
  HolderBurst* = 200 ## [IMPL] and its burst
  ProcessRate* = 100 ## [IMPL] logosd's limit for one TLS process, a second
  ProcessBurst* = 200 ## [IMPL] and its burst

type
  RateLimit* = object
    ## [IMPL] A token bucket: `burst` tokens at most, `rate` more a second.
    rate: float64
    burst: float64
    tokens: float64
    last: int64 ## monotonic nanoseconds of the last refill

  SignCount* = object
    signed*: uint64
    refused*: uint64

  ProcessSigning* = object
    ## logosd's view of one TLS process's signing: its role, fixed at spawn,
    ## and its limit.
    role*: TlsRole
    limit*: RateLimit

  SignService* = ref object
    ## logosd's signing service in the default mode: the key, loaded once.
    key: P256Key
    count*: SignCount

  Relayed = object
    origin: uint64 ## logosd's tag for the process that asked
    id: uint64 ## that process's own request id

  HolderRelay* = object
    ## logosd's side of the key holder's channel: its own request ids, each
    ## mapped back to the process and the id it came from.
    next: uint64
    waiting: Table[uint64, Relayed]

func newRateLimit*(rate, burst: int): RateLimit =
  RateLimit(
    rate: float64(rate), burst: float64(burst), tokens: float64(burst), last: -1
  )

proc monoNs*(): int64 =
  getMonoTime().ticks

proc take*(r: var RateLimit, now: int64): bool =
  ## One token, if the bucket holds one at `now` (monotonic nanoseconds).
  if r.last >= 0 and now > r.last:
    r.tokens = min(r.burst, r.tokens + float64(now - r.last) * r.rate / 1e9)
  r.last = max(r.last, now)
  if r.tokens < 1.0:
    return false
  r.tokens -= 1.0
  true

func newProcessSigning*(role: TlsRole): ProcessSigning =
  ProcessSigning(role: role, limit: newRateLimit(ProcessRate, ProcessBurst))

proc signWith*(
    key: P256Key,
    role: TlsRole,
    alg: uint16,
    input: openArray[byte],
    limit: var RateLimit,
    count: var SignCount,
    now: int64,
): SignResult =
  ## [G410] What either signer answers: refused over the limit or when
  ## `checkSignInput` refuses the input for `role`; otherwise the signature.
  if not limit.take(now) or checkSignInput(role, alg, input).isErr:
    inc count.refused
    return refused()
  let sig = signP256(key, input).valueOr:
    return unavailable()
  inc count.signed
  signed(sig)

proc newSignService*(credentialDir: string): Result[SignService, string] =
  ## The default mode's service, with the key of the credential in
  ## `credentialDir` (`credential.loadCredentialKey`).
  let key = ?loadCredentialKey(credentialDir)
  ok(SignService(key: key))

proc close*(s: SignService) =
  if s != nil and s.key != nil:
    s.key.free()

proc answer*(
    s: SignService, p: var ProcessSigning, m: LcnRchSign, now = monoNs()
): LcnRchMessage =
  ## logosd's answer to one process's sign request.
  signAnswer(m.id, signWith(s.key, p.role, m.alg, m.input, p.limit, s.count, now))

# The relay to the key holder ---------------------------------------------------------------

proc relay*(
    r: var HolderRelay,
    origin: uint64,
    p: var ProcessSigning,
    m: LcnRchSign,
    now = monoNs(),
): Result[LcnRchMessage, LcnRchMessage] =
  ## The request for the key holder, or logosd's own refusal to relay it (the
  ## same checks the holder runs, with logosd's limit for the process): ok is
  ## a `holder_sign` for the holder, err the answer for the process.
  if not p.limit.take(now) or checkSignInput(p.role, m.alg, m.input).isErr:
    return err(signAnswer(m.id, refused()))
  inc r.next
  r.waiting[r.next] = Relayed(origin: origin, id: m.id)
  ok(holderRequest(r.next, p.role, m.alg, m.input))

proc returned*(
    r: var HolderRelay, m: LcnRchMessage
): Result[(uint64, LcnRchMessage), string] =
  ## The key holder's answer, renamed for the process that asked: its origin
  ## and the answer under its own id. An answer to no relayed request is the
  ## holder's fault, which ends its channel; one for a process that ended
  ## meanwhile is dropped (origin 0).
  if not m.isAnswer:
    return err("the key holder sent a message that is not an answer")
  let id = m.answerId
  var w: Relayed
  if not r.waiting.pop(id, w):
    if id >= 1 and id <= r.next:
      return ok((0'u64, m))
    return err("the key holder answered request " & $id & ", which logosd never sent")
  ok((w.origin, m.withId(w.id)))

proc forget*(r: var HolderRelay, origin: uint64) =
  ## A process ended: its relayed requests' answers will be dropped.
  var gone: seq[uint64]
  for id, w in r.waiting.pairs:
    if w.origin == origin:
      gone.add(id)
  for id in gone:
    r.waiting.del(id)

func waiting*(r: HolderRelay): int =
  r.waiting.len

# The key holder's count -------------------------------------------------------------------

const
  HolderCountName* = "keyholder.count"
    ## [IMPL] under `remote/`: two lines, `signed N` and `refused N`, written
    ## by the key holder only
  HolderCountEveryMs* = 60_000 ## [IMPL] and at its exit

func holderCountText*(c: SignCount): string =
  "signed " & $c.signed & "\nrefused " & $c.refused & "\n"

proc parseHolderCount*(text: string): Result[SignCount, string] =
  ## The count file's two lines.
  var c: SignCount
  var seen = 0
  for line in text.splitLines:
    if line.len == 0:
      continue
    let parts = line.split(' ')
    if parts.len != 2:
      return err("not a key holder count: " & line.escape)
    let n =
      try:
        parseBiggestUInt(parts[1])
      except ValueError:
        return err("not a key holder count: " & line.escape)
    case parts[0]
    of "signed":
      c.signed = uint64(n)
    of "refused":
      c.refused = uint64(n)
    else:
      return err("not a key holder count: " & line.escape)
    inc seen
  if seen != 2:
    return err("not a key holder count")
  ok(c)

proc readHolderCount*(s: Session): Result[Opt[SignCount], string] =
  ## The key holder's count file; none before the holder first wrote it.
  let bytes = (?readSessionFile(s.remoteDir / HolderCountName, 4096)).valueOr:
    return ok(Opt.none(SignCount))
  var text = newString(bytes.len)
  for i, b in bytes:
    text[i] = char(b)
  ok(Opt.some(?parseHolderCount(text)))

proc writeHolderCount*(s: Session, c: SignCount): Result[void, string] =
  let text = holderCountText(c)
  writeAtomic(s.remoteDir, HolderCountName, text.toOpenArrayByte(0, text.high))

# Process copy (tests only) -----------------------------------------------------------------

when defined(logosTestSigning):
  proc testKeyMessage*(credentialDir: string): Result[LcnRchMessage, string] =
    ## [B1: tests only] The key for one TLS process to sign with itself.
    let key = ?loadCredentialKey(credentialDir)
    defer:
      key.free()
    var der = ?toPkcs8(key)
    let m = toMessage(LcnRchTestKey(pkcs8: der))
    wipe(der)
    ok(m)

{.pop.}
