## TRANSPORT §8.4.1 l.1240-1267; owner decision B2; G324, G325, I99: the
## tls-tcp verifier. It checks the certificates a peer presented against a
## trust snapshot (`trust.nim`) and gives the engine its `PeerCheck`:
## `expectRuntime` for a client, which knows the Runtime it must reach, and
## `anyEnrolled` for a server, which learns who called from the key.
##
## The checks run in a fixed order and the first that fails is the reason:
##
## 1. accepted current time exists (G325; T l.1267);
## 2. exactly one certificate: a direct anchor (G324; B2);
## 3. the enrollment: no two current records hold the leaf's key, for a client
##    as for a server (G324; T l.1253); as client, the expected Runtime's current
##    record is `active` (T l.1245-1247); as server, one current record holds
##    the key, and it is `active` (T l.1251-1254);
## 4. the leaf's DER SPKI is one of that record's keys (T l.1248-1250);
## 5. the leaf's DER equals the record's anchor certificate (T l.1258, l.1260);
## 6. notBefore <= now <= notAfter (T l.1259);
## 7. Key Usage, if present, permits digital signatures (T l.1261);
## 8. Extended Key Usage, if present, names the peer's role; any other purpose
##    alone, `anyExtendedKeyUsage` included, fails (T l.1262-1263);
## 9. no critical extension path validation would not process (RFC 5280 §4.2).
##
## Proof of possession is TLS's CertificateVerify, which BoringSSL checks with
## the leaf's key (T l.1264).

{.push raises: [].}

import std/times
import results
import ./[engine, signing, trust, x509]

export results, trust

const TimeFloor* = 1794873600'i64
  ## [IMPL] G325: 2026-11-17T00:00:00Z. A system clock that reads earlier is
  ## not accepted current time; later steps raise the floor.

type Clock* = proc(): Result[int64, string] {.gcsafe, raises: [].}
  ## Accepted current time in POSIX seconds, or why there is none.

proc systemClock*(): Clock =
  ## G325: the system clock, refused below `TimeFloor`.
  result = proc(): Result[int64, string] {.gcsafe, raises: [].} =
    let now = getTime().toUnix()
    if now < TimeFloor:
      return err("the system clock reads before " & $TimeFloor & ", the accepted floor")
    ok(now)

proc checkPeer*(
    t: TrustSnapshot,
    chain: seq[seq[byte]],
    peerRole: TlsRole,
    expected: string,
    now: Result[int64, string],
): Result[PeerIdentity, string] =
  ## The checks above for a peer acting as `peerRole`. `expected` is the
  ## Runtime a client must reach, "" for a server's inbound caller.
  if t == nil:
    return err("no trust snapshot")
  if now.isErr:
    return err("1 time: " & now.error)
  let at = now.get
  if chain.len != 1:
    return err(
      "2 chain: " & $chain.len &
        " certificates; only one, a directly provisioned anchor, is accepted"
    )
  let leaf = chain[0]
  let info = readCertificate(leaf)
  if info.isErr:
    return err("2 chain: " & info.error)
  let cert = info.get
  let holders = t.holdersOf(cert.spki)
  if holders.len > 1:
    return err("3 enrollment: " & $holders.len & " Runtimes hold this key")
  var rec = EnrollmentRecord()
  if expected.len > 0:
    let r = t.record(expected)
    if r.isNone:
      return err("3 enrollment: no record for Runtime " & expected)
    rec = r.get
  else:
    if holders.len == 0:
      return err("3 enrollment: no Runtime is enrolled with this key")
    rec = holders[0]
  case rec.status
  of rsRevoked:
    return err("3 enrollment: Runtime " & rec.runtime & " is revoked")
  of rsConflicting:
    return err("3 enrollment: Runtime " & rec.runtime & " has conflicting records")
  of rsActive:
    discard
  if cert.spki notin rec.spkis:
    return err("4 key: not one of Runtime " & rec.runtime & "'s enrolled keys")
  let anchor = t.anchor(rec.anchor)
  if anchor.isNone or anchor.get != leaf:
    return err("5 anchor: not trust anchor " & rec.anchor & " (complete DER)")
  if at < cert.notBefore or at > cert.notAfter:
    return err("6 validity: outside notBefore and notAfter at " & $at)
  if cert.hasKeyUsage and not cert.digitalSignature:
    return err("7 key usage: digitalSignature not permitted")
  if cert.hasExtKeyUsage:
    let allowed =
      case peerRole
      of tlsClient: cert.clientAuth
      of tlsServer: cert.serverAuth
    if not allowed:
      return err("8 extended key usage: no " & $peerRole & " purpose")
  if cert.unhandledCritical:
    return err("9 extensions: a critical extension validation does not process")
  ok(PeerIdentity(runtime: rec.runtime, revision: rec.revision, anchor: rec.anchor))

proc expectRuntime*(
    t: TrustSnapshot, expected: string, clock: Clock = systemClock()
): PeerCheck =
  ## [SPEC TRANSPORT §8.4.1] l.1242-1247: a client's check: the server must be
  ## `expected`, under its current active enrollment.
  result = proc(
      chain: seq[seq[byte]], peerRole: TlsRole
  ): Result[PeerIdentity, string] {.gcsafe, raises: [].} =
    if expected.len == 0:
      return err("no expected Runtime")
    checkPeer(t, chain, peerRole, expected, clock())

proc anyEnrolled*(t: TrustSnapshot, clock: Clock = systemClock()): PeerCheck =
  ## [SPEC TRANSPORT §8.4.1] l.1251-1254: a server's check: the caller's key
  ## matches exactly one active enrollment.
  result = proc(
      chain: seq[seq[byte]], peerRole: TlsRole
  ): Result[PeerIdentity, string] {.gcsafe, raises: [].} =
    checkPeer(t, chain, peerRole, "", clock())

{.pop.}
