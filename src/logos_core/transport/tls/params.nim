## TRANSPORT §8.4.1; G326, I99: the `logos.remote.tls-tcp` carrier's fixed
## parameters, its `tls-tcp` address and its limits. No BoringSSL here.

{.push raises: [].}

import std/strutils
import results
import ../framing

export results

const
  ExporterLabel* = "EXPORTER-Channel-Binding"
    ## [SPEC TRANSPORT §8.4.1] RFC 9266's registered label (l.1281).
  ChannelBindingLen* = 32 ## [SPEC TRANSPORT §8.4.1] the output length (l.1282)
  SigAlgEcdsaP256Sha256* = 0x0403'u16
    ## `ecdsa_secp256r1_sha256`, the only signature algorithm offered or accepted
    ## (T l.1238-1239; G326).
  GroupsList* = "X25519MLKEM768:X25519:P-256"
    ## [IMPL] G326: the pinned default first, then RFC 8446 §9.1's recommended
    ## X25519 and mandatory secp256r1, for other peers.
  MaxServerNameLen* = 253 ## a DNS name's longest text form, without the final dot

type
  TlsTcpAddress* = object
    ## RUNTIME l.1978-1984: `host`, `port`, an optional `server_name`; `tls-tcp`
    ## has no `alpn`.
    host*: string
    port*: uint16
    serverName*: string ## "" when the address has none

  TlsConfig* = object
    ## [IMPL] I99: the carrier's limits, checked by `check` before use.
    handshakeTimeoutMs*: int ## each handshake's deadline, connect included
    maxHandshakes*: int ## a listener's handshakes at once; more are closed unread
    maxConnections*: int
      ## a listener's connections at once, handshaking or open (TRANSPORT §8.6);
      ## more are closed unread
    readBound*: int ## ciphertext taken from the socket but not yet consumed
    writeBound*: int
      ## ciphertext sealed and not yet sent (TRANSPORT §8.6): a frame that would
      ## pass it while output waits is refused; a frame alone always fits
    frameLimit*: uint32 ## the largest frame body accepted (TRANSPORT §2.1)
    peerFrameLimit*: uint32 ## the largest frame body sent (TRANSPORT §2.1)
    closeWaitMs*: int ## how long teardown waits for the reader to end
    carriesMarked*: bool
      ## [DECISIONS G277, G327] the streams are to carry marked payloads
      ## (INTERFACE §1.4.1): `connect` and `serve` refuse unless the carrier
      ## erases (`stream.carrierErases`)

func defaultTlsConfig*(): TlsConfig =
  TlsConfig(
    handshakeTimeoutMs: 10_000,
    maxHandshakes: 64,
    maxConnections: 1024,
    readBound: 64 * 1024,
    writeBound: MinFrameLimit.int,
    frameLimit: MinFrameLimit,
    peerFrameLimit: MinFrameLimit,
    closeWaitMs: 2_000,
  )

func check*(c: TlsConfig): Result[void, string] =
  ## The bounds each limit must keep.
  if c.handshakeTimeoutMs < 1 or c.handshakeTimeoutMs > 600_000:
    return err("handshakeTimeoutMs must be 1 to 600000")
  if c.maxHandshakes < 1 or c.maxHandshakes > 4096:
    return err("maxHandshakes must be 1 to 4096")
  if c.maxConnections < c.maxHandshakes or c.maxConnections > 65_536:
    return err("maxConnections must be maxHandshakes to 65536")
  if c.readBound < 16 * 1024 + 256 or c.readBound > 16 * 1024 * 1024:
    return err("readBound must hold one TLS record and be at most 16 MiB")
  if c.writeBound < 16 * 1024 + 256 or c.writeBound > 1024 * 1024 * 1024:
    return err("writeBound must hold one TLS record and be at most 1 GiB")
  if c.frameLimit < MinFrameLimit:
    return err("frameLimit below 16 MiB does not conform (TRANSPORT §2.1)")
  if c.peerFrameLimit < MinFrameLimit:
    return err("peerFrameLimit below 16 MiB does not conform (TRANSPORT §2.1)")
  if c.closeWaitMs < 0 or c.closeWaitMs > 60_000:
    return err("closeWaitMs must be 0 to 60000")
  ok()

func isLdhLabel(s: string): bool =
  if s.len < 1 or s.len > 63 or s[0] == '-' or s[^1] == '-':
    return false
  for c in s:
    if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}:
      return false
  true

func checkServerName*(name: string): Result[void, string] =
  ## [SPEC TRANSPORT §8.4.1] l.1271: a `server_name` is sent as RFC 6066
  ## `host_name` SNI, so it must be a DNS name valid for that extension: ASCII
  ## LDH labels of 1 to 63 octets, at most 253 octets, no trailing dot, and not
  ## an IP literal. A last label of digits only is refused as an IPv4 literal
  ## (no top-level domain is all digits); IPv6 literals hold `:` and fail the
  ## label rule [IMPL].
  if name.len == 0:
    return err("server_name is empty")
  if name.len > MaxServerNameLen:
    return err("server_name is longer than 253 octets")
  let labels = name.split('.')
  for label in labels:
    if not isLdhLabel(label):
      return err("server_name is not a DNS name of LDH labels: " & name)
  if labels[^1].allCharsInSet(Digits):
    return err("server_name is an IP literal: " & name)
  ok()

func check*(a: TlsTcpAddress): Result[void, string] =
  if a.host.len == 0 or a.host.len > 255:
    return err("host must be 1 to 255 octets")
  if a.port == 0:
    return err("port 0 names no listener")
  if a.serverName.len > 0:
    ?checkServerName(a.serverName)
  ok()

{.pop.}
