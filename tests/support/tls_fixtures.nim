## Fixtures for `test_remote_tls.nim` (step 5-2): parties with a P-256 key and a
## self-signed certificate, the in-process test signer, and a fixture
## `PeerCheck` that pins one SPKI per Runtime id. The enrollment checks
## (TRANSPORT §8.4.1 l.1245-1267) are `verify.nim`'s (5-2a); the pinned check
## shows the carrier on its own. Trust snapshots, clocks and odd certificates
## for the verifier's cases.

import std/[tables, times]
import results
import ../../src/logos_core/transport/tls
import ../../src/logos_core/transport/tls/[boring, testsigner]

export tls, testsigner

type Party* = object
  id*: string ## a Runtime id (lowercase UUIDv4)
  key*: P256Key
  cert*: seq[byte]
  spki*: seq[byte]

const
  IdA* = "0b6f3c3e-9d0f-4c1a-8f43-7a8f2b9b1a01"
  IdB* = "5d2e8c71-3a4b-4e6f-9a1b-2c3d4e5f6a02"
  IdC* = "9e8d7c6b-5a49-4382-b170-6f5e4d3c2b03"
  ServerKu* = "critical,digitalSignature"

proc nowPosix*(): int64 =
  getTime().toUnix()

proc newParty*(
    id: string,
    keyUsage = ServerKu,
    extendedKeyUsage = "",
    notBefore = nowPosix() - 3600,
    notAfter = nowPosix() + 365 * 86400,
): Party =
  let key = newP256Key().get
  let cert = key.selfSignedCertificate(
    CertificateOptions(
      commonName: id,
      notBefore: notBefore,
      notAfter: notAfter,
      keyUsage: keyUsage,
      extendedKeyUsage: extendedKeyUsage,
    )
  ).get
  Party(id: id, key: key, cert: cert, spki: key.spkiDer().get)

proc free*(p: Party) =
  p.key.free()

proc pinnedCheck*(parties: openArray[Party]): PeerCheck =
  ## The fixture check: exactly one certificate, whose SPKI is one party's.
  var pins = initTable[seq[byte], string]()
  for p in parties:
    pins[p.spki] = p.id
  result = proc(
      chain: seq[seq[byte]], peerRole: TlsRole
  ): Result[PeerIdentity, string] {.gcsafe, raises: [].} =
    if chain.len != 1:
      return err("expected one certificate, got " & $chain.len)
    let spki = ?certificateSpki(chain[0])
    let id = pins.getOrDefault(spki, "")
    if id.len == 0:
      return err("the key is not pinned")
    ok(PeerIdentity(runtime: id, revision: 1, anchor: "fixture"))

proc expectCheck*(p: Party): PeerCheck =
  ## A client's fixture check: the server must be `p`.
  pinnedCheck([p])

var contexts: seq[tuple[id: string, role: TlsRole, ctx: TlsContext]] = @[]

proc contextOf(p: Party, role: TlsRole): TlsContext =
  ## One context per party and role, kept until `freeContexts`.
  for c in contexts:
    if c.id == p.id and c.role == role:
      return c.ctx
  result = newTlsContext(role, p.cert).get
  contexts.add((p.id, role, result))

proc clientContext*(p: Party): TlsContext =
  contextOf(p, tlsClient)

proc serverContext*(p: Party): TlsContext =
  contextOf(p, tlsServer)

proc freeContexts*() =
  for c in contexts:
    c.ctx.free()
  contexts.setLen(0)

proc fastConfig*(timeoutMs = 10_000): TlsConfig =
  result = defaultTlsConfig()
  result.handshakeTimeoutMs = timeoutMs

# 5-2a: trust snapshots, clocks and odd certificates -------------------------------------

proc anchorId*(p: Party): string =
  p.id & "-anchor"

proc activeRecord*(
    p: Party, revision = 1'u64, keys: seq[seq[byte]] = @[]
): EnrollmentRecord =
  ## `p` enrolled with its own certificate as direct anchor.
  EnrollmentRecord(
    runtime: p.id,
    revision: revision,
    status: rsActive,
    anchor: p.anchorId,
    spkis: (if keys.len == 0: @[p.spki] else: keys),
  )

proc snapshotOf*(
    anchored: openArray[Party], records: openArray[EnrollmentRecord]
): TrustSnapshot =
  ## Every party of `anchored` as a direct anchor, and `records`.
  var anchors: seq[(string, seq[byte])] = @[]
  for p in anchored:
    anchors.add((p.anchorId, p.cert))
  newTrustSnapshot(7, anchors, records).get

proc enrolled*(parties: openArray[Party]): TrustSnapshot =
  ## Each party anchored and actively enrolled.
  var records: seq[EnrollmentRecord] = @[]
  for p in parties:
    records.add(activeRecord(p))
  snapshotOf(parties, records)

proc fixedClock*(at: int64): Clock =
  result = proc(): Result[int64, string] {.gcsafe, raises: [].} =
    ok(at)

proc noClock*(): Clock =
  result = proc(): Result[int64, string] {.gcsafe, raises: [].} =
    err("no clock")

proc withCriticalExtension*(p: Party): seq[byte] =
  ## `p`'s certificate with a private critical extension added, signed again.
  let x = parseCertificate(p.cert).get
  let obj = OBJ_txt2obj("1.3.6.1.4.1.55555.1".cstring, 1)
  let value = ASN1_OCTET_STRING_new()
  var null = [0x05'u8, 0x00]
  doAssert ASN1_OCTET_STRING_set(value, addr null[0], 2) == 1
  var ext: ptr X509_EXTENSION = nil
  doAssert X509_EXTENSION_create_by_OBJ(addr ext, obj, 1, value) != nil
  doAssert X509_add_ext(x, ext, -1) == 1
  doAssert X509_sign(x, p.key.raw, EVP_sha256()) > 0
  X509_EXTENSION_free(ext)
  ASN1_OCTET_STRING_free(value)
  ASN1_OBJECT_free(obj)
  let n = i2d_X509(x, nil)
  result = newSeq[byte](n)
  var q = addr result[0]
  doAssert i2d_X509(x, addr q) == n
  X509_free(x)
