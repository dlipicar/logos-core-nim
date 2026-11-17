## TRANSPORT §8.4.1; owner B1 (2026-11-16); G323: the signing seam. A TLS
## process need not hold its TLS key: the engine hands each TLS 1.3
## CertificateVerify input to a `Signer` and waits for the signature without
## blocking the event loop. logosd signs by default and a key-holder process is
## the hardened setup (both are the daemon side's, 5-7a); a key in the TLS
## process is for tests only (`testsigner.nim`). Every signer, at the end that
## holds the key, signs only what `checkSignInput` accepts.

{.push raises: [].}

import std/strutils
import chronos
import results
import ./params

export results, chronos

type
  TlsRole* = enum
    tlsClient = "client"
    tlsServer = "server"

  SignStatus* = enum
    ssSigned ## `signature` holds a DER ECDSA signature
    ssRefused ## the signer refused this input
    ssUnavailable ## no signer could answer (gone, busy)

  SignResult* = object
    status*: SignStatus
    signature*: seq[byte]

  Signer* = proc(role: TlsRole, alg: uint16, input: seq[byte]): Future[SignResult] {.
    async: (raises: [CancelledError]), gcsafe
  .}
    ## Signs one CertificateVerify input for a connection of `role`. A
    ## cancelled call's late answer is dropped.

const
  CertVerifyPad = 64 ## RFC 8446 §4.4.3: 64 octets of 0x20
  ClientContext = "TLS 1.3, client CertificateVerify"
  ServerContext = "TLS 1.3, server CertificateVerify"

func signed*(signature: seq[byte]): SignResult =
  SignResult(status: ssSigned, signature: signature)

func refused*(): SignResult =
  SignResult(status: ssRefused, signature: @[])

func unavailable*(): SignResult =
  SignResult(status: ssUnavailable, signature: @[])

func contextOf(role: TlsRole): string =
  case role
  of tlsClient: ClientContext
  of tlsServer: ServerContext

func checkSignInput*(
    role: TlsRole, alg: uint16, input: openArray[byte]
): Result[void, string] =
  ## [IMPL] G323: what a signer signs. The algorithm is
  ## `ecdsa_secp256r1_sha256`, and the input is a TLS 1.3 CertificateVerify
  ## content for `role` (RFC 8446 §4.4.3): 64 octets of 0x20, the role's context
  ## string, a zero octet, and a SHA-256 or SHA-384 transcript hash. `role` is
  ## the one the signer was set up for (a facade process signs as a client, a
  ## listener process as a server), never one the request names.
  if alg != SigAlgEcdsaP256Sha256:
    return err(
      "signature algorithm 0x" & alg.int.toHex(4) & " is not ecdsa_secp256r1_sha256"
    )
  let ctx = contextOf(role)
  let head = CertVerifyPad + ctx.len + 1
  if input.len != head + 32 and input.len != head + 48:
    return err("not a TLS 1.3 CertificateVerify input (length " & $input.len & ")")
  for i in 0 ..< CertVerifyPad:
    if input[i] != 0x20:
      return err("not a TLS 1.3 CertificateVerify input (padding)")
  for i in 0 ..< ctx.len:
    if input[CertVerifyPad + i] != byte(ctx[i]):
      return err("not a " & $role & " CertificateVerify input")
  if input[head - 1] != 0:
    return err("not a TLS 1.3 CertificateVerify input (separator)")
  ok()

{.pop.}
