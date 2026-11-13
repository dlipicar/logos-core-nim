## The COSE_Sign1 structure (RFC 9052) both Logos SLH-DSA-SHA2-192s profiles
## use: package signing (PM §4.3, `package/signing.nim`) and call evidence (CA
## §9.1, `runtime/evidence.nim`; DECISIONS I85). A tagged COSE_Sign1 whose
## protected header holds exactly `kid`, whose unprotected header is empty and
## whose payload is embedded. The algorithm is implicit and fixed (RFC 9052
## App. A): pure SLH-DSA-SHA2-192s with the zero-length context over the
## `Sig_structure`, whose `external_aad` each profile supplies from its own
## context. Nothing in the received object selects the algorithm, the profile
## or the context.
##
## The outer structure and the protected header use RFC 8949 §4.2.1 core
## deterministic encoding, which imposes the same bytes as the Logos profile
## here, so the one encoder and strict decoder serve both (I9).

{.push raises: [].}

import results
import ../cbor
import ./slhdsa

export results

const
  CoseSign1Tag* = 18'u64 ## RFC 9052 tagged COSE_Sign1
  CoseHeaderAlg* = 1'u64 ## RFC 9052 `alg`: refused by both profiles
  CoseHeaderKid* = 4'u64 ## RFC 9052 `kid`
  SignatureContext* = "Signature1" ## RFC 9052 §4.4
  MinCoseKidBytes* = 1
  MaxCoseKidBytes* = 128

type
  CoseSign1* = object
    protectedBytes*: seq[byte] ## the serialized protected header map
    kid*: seq[byte]
    payload*: seq[byte] ## the embedded payload bytes
    signature*: seq[byte] ## 16,224 bytes once decoded or signed

  CoseError* = enum
    ## Why bytes are not a COSE_Sign1 of these profiles. Each profile maps
    ## these to its own error and wording.
    ceNotCbor ## not deterministic CBOR
    ceNotTagged ## not tag 18
    ceNotFour ## not an array of four elements
    ceProtectedNotBytes
    ceProtectedNotCbor
    ceProtectedNotMap
    ceAlgPresent ## an explicit `alg`, whatever it names
    ceNotOnlyKid ## the protected header holds more than, or other than, `kid`
    ceKidNotBytes
    ceKidSize ## not 1 to 128 bytes
    ceUnprotectedNotEmpty
    cePayloadDetached ## missing or detached payload
    ceSignatureNotBytes
    ceSignatureSize ## not 16,224 bytes

  CoseFailure* = object
    kind*: CoseError
    detail*: string
      ## the decoder's own message, for `ceNotCbor` and `ceProtectedNotCbor`

func protectedHeader*(kid: openArray[byte]): seq[byte] =
  ## Exactly `kid`, core deterministic.
  encodeCbor(cborMap((cbor(CoseHeaderKid), cbor(@kid))))

func sigStructure*(protectedBytes, payload, externalAad: openArray[byte]): seq[byte] =
  ## RFC 9052 §4.4 `Sig_structure` for `Signature1`: the protected header
  ## bytes, the profile's `external_aad`, the payload bytes. This is the exact
  ## FIPS 205 message; the pure-mode prefix is the signing and verifying
  ## functions' to add.
  encodeCbor(
    cborArray(
      cbor(SignatureContext), cbor(@protectedBytes), cbor(@externalAad), cbor(@payload)
    )
  )

func encodeCoseSign1*(c: CoseSign1): seq[byte] =
  encodeCbor(
    cborTag(
      CoseSign1Tag,
      cborArray(cbor(c.protectedBytes), cborMap(), cbor(c.payload), cbor(c.signature)),
    )
  )

func unsignedCose*(kid, payload, externalAad: openArray[byte]): (CoseSign1, seq[byte]) =
  ## The COSE_Sign1 for `payload` under `kid` before its signature, and the
  ## `Sig_structure` bytes to sign.
  let cose =
    CoseSign1(protectedBytes: protectedHeader(kid), kid: @kid, payload: @payload)
  (cose, sigStructure(cose.protectedBytes, cose.payload, externalAad))

func failure(kind: CoseError, detail = ""): CoseFailure =
  CoseFailure(kind: kind, detail: detail)

func decodeCoseSign1Structure*(data: openArray[byte]): Result[CoseSign1, CoseFailure] =
  ## The structural checks both profiles share: deterministic CBOR, tag 18,
  ## four elements, a protected header of exactly a 1..128-byte `kid` (an
  ## explicit `alg` is refused, whatever it names), an empty unprotected
  ## header, an embedded payload, and a 16,224-byte signature.
  let v = decodeCbor(data).valueOr:
    return err(failure(ceNotCbor, $error))
  if v.kind != ckTag or v.tag != CoseSign1Tag:
    return err(failure(ceNotTagged))
  let a = v.content
  if a.kind != ckArray or a.items.len != 4:
    return err(failure(ceNotFour))
  let protectedBytes = a.items[0].getBytes.valueOr:
    return err(failure(ceProtectedNotBytes))
  let h = decodeCbor(protectedBytes).valueOr:
    return err(failure(ceProtectedNotCbor, $error))
  if h.kind != ckMap:
    return err(failure(ceProtectedNotMap))
  if h.lookup(CoseHeaderAlg).isSome:
    return err(failure(ceAlgPresent))
  let kidValue = h.lookup(CoseHeaderKid)
  if h.entries.len != 1 or kidValue.isNone:
    return err(failure(ceNotOnlyKid))
  let kid = kidValue.get.getBytes.valueOr:
    return err(failure(ceKidNotBytes))
  if kid.len < MinCoseKidBytes or kid.len > MaxCoseKidBytes:
    return err(failure(ceKidSize))
  if a.items[1].kind != ckMap or a.items[1].entries.len != 0:
    return err(failure(ceUnprotectedNotEmpty))
  let payload = a.items[2].getBytes.valueOr:
    return err(failure(cePayloadDetached))
  let sig = a.items[3].getBytes.valueOr:
    return err(failure(ceSignatureNotBytes))
  if sig.len != SignatureBytes:
    return err(failure(ceSignatureSize))
  ok(
    CoseSign1(
      protectedBytes: protectedBytes, kid: kid, payload: payload, signature: sig
    )
  )
