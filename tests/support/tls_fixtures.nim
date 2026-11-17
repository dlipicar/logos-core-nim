## Fixtures for `test_remote_tls.nim` (step 5-2): parties with a P-256 key and a
## self-signed certificate, the in-process test signer, and a fixture
## `PeerCheck` that pins one SPKI per Runtime id. The enrollment checks
## (TRANSPORT §8.4.1 l.1245-1267) are 5-2a's `verify.nim`; this check only lets
## the carrier be shown before them.

import std/[tables, times]
import results
import ../../src/logos_core/transport/tls
import ../../src/logos_core/transport/tls/testsigner

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
