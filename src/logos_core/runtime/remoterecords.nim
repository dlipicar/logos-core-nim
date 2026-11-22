## Remote listener and provider export records (Tier 5 step 5-7a-2;
## DECISIONS G412, G298 re-decided; RUNTIME §9.3.9 l.2721-2738, l.3289-3322).
## Runtime thread only; pure data, no I/O.
##
## - **A record for every valid address** [G412]: a listener record exists
##   once the deployment configuration names its address or Runtime Control
##   assigns it, whatever its profile. Only *enabling* can fail for want of
##   remote transport: a `quic` address (no QUIC profile in this build), or a
##   Runtime without `runtime.remote_program` (the library host), is
##   MODULE_ERROR "remote transport is not supported by this Runtime"
##   (`enableRefusal`), with the state unchanged (R l.3293).
## - **Keys** (R l.2723-2727, l.3412): a listener is its complete address,
##   kept as its deterministic-CBOR bytes; an export is its listener's
##   address and its provider, normalized to this Runtime. Lists order
##   listeners by those bytes and exports by them, then by the provider's
##   Runtime and id (`listenerOrder`, `exportOrder`).
## - **Origin** (R l.3156-3158): beside each record, not in the wire value,
##   where its current state came from, the deployment configuration or
##   Runtime Control, and for Runtime Control the consumer that set it.

{.push raises: [].}

import std/[algorithm, tables]
import results
import logos_sdk/cbor
import logos_sdk/kit/rc_types
from ./rcaddress import mismatching

export rc_types

const NoRemoteTransport* = "remote transport is not supported by this Runtime"
  ## [G298, G412] the MODULE_ERROR message of an enable that cannot be served

type
  RecordOrigin* = enum
    roConfig = "the deployment configuration"
    roRc = "Runtime Control"

  ListenerEntry* = object
    record*: LogosNSRuntimeControlRemoteListenerRecord
    key*: seq[byte] ## the address's deterministic-CBOR bytes
    origin*: RecordOrigin
    consumer*: string ## roRc: the consumer that set it, as an address text

  ExportEntry* = object
    record*: LogosNSRuntimeControlProviderExportRecord
      ## the provider normalized: its Runtime always present (this one)
    listener*: seq[byte] ## its listener's key
    provider*: string ## the provider id
    module*, instance*: string
      ## the provider's module and instance when the record was set: the facts
      ## its disclosure is judged by (RUNTIME l.3237-3238); empty for a
      ## configuration record until its provider is known
    origin*: RecordOrigin
    consumer*: string

  RemoteRecords* = object
    runtimeId*: string
    listeners*: Table[seq[byte], ListenerEntry]
    exports*: Table[(seq[byte], string), ExportEntry]

proc addressKey*(a: LogosNSRuntimeControlRemoteListenerAddress): seq[byte] =
  ## [SPEC RUNTIME l.2723-2724, l.3412] The complete address, as its
  ## deterministic-CBOR bytes.
  encode(a).get(newSeq[byte]())

func isQuic*(a: LogosNSRuntimeControlRemoteListenerAddress): bool =
  a.kind ==
    LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Quic_runtime_address

func tlsTcp*(
    a: LogosNSRuntimeControlRemoteListenerAddress
): LogosNSRuntimeControlTlsTcpRuntimeAddress =
  a.arm_logos_NS_runtime_control_Tls_tcp_runtime_address

func addressText*(a: LogosNSRuntimeControlRemoteListenerAddress): string =
  ## For diagnostics: `tls-tcp host:port` or `quic host:port`.
  if a.isQuic:
    let q = a.arm_logos_NS_runtime_control_Quic_runtime_address
    "quic " & q.host & ":" & $q.port
  else:
    let t = a.tlsTcp
    "tls-tcp " & t.host & ":" & $t.port

func stateText*(r: LogosNSRuntimeControlRemoteListenerRecord): string =
  "enabled " & $r.enabled & ", runtime_control_enabled " & $r.runtime_control_enabled

func defaultListener*(
    a: LogosNSRuntimeControlRemoteListenerAddress
): LogosNSRuntimeControlRemoteListenerRecord =
  ## [SPEC RUNTIME l.2768] Disabled by default.
  LogosNSRuntimeControlRemoteListenerRecord(
    address: a, enabled: false, runtime_control_enabled: false
  )

func sameListener*(a, b: LogosNSRuntimeControlRemoteListenerRecord): bool =
  a.enabled == b.enabled and a.runtime_control_enabled == b.runtime_control_enabled

func enableRefusal*(
    a: LogosNSRuntimeControlRemoteListenerAddress, available: bool
): Opt[string] =
  ## [G298, G412] Why enabling a listener at `a` cannot be served here.
  if not available or a.isQuic:
    return Opt.some(NoRemoteTransport)
  Opt.none(string)

func normalized*(
    rr: RemoteRecords, p: LogosNSRuntimeModuleProviderAddress
): LogosNSRuntimeModuleProviderAddress =
  LogosNSRuntimeModuleProviderAddress(
    provider: p.provider, runtime_instance_id: Opt.some(rr.runtimeId)
  )

func foreign*(rr: RemoteRecords, p: LogosNSRuntimeModuleProviderAddress): bool =
  ## [SPEC RUNTIME l.2735, l.3309-3310] A provider another Runtime owns.
  p.runtime_instance_id.isSome and p.runtime_instance_id.get != rr.runtimeId

func listener*(rr: RemoteRecords, key: openArray[byte]): Opt[ListenerEntry] =
  let k = @key
  if k in rr.listeners:
    Opt.some(rr.listeners.getOrDefault(k))
  else:
    Opt.none(ListenerEntry)

func exportOf*(
    rr: RemoteRecords, key: openArray[byte], provider: string
): Opt[ExportEntry] =
  let k = (@key, provider)
  if k in rr.exports:
    Opt.some(rr.exports.getOrDefault(k))
  else:
    Opt.none(ExportEntry)

proc putListener*(
    rr: var RemoteRecords,
    r: LogosNSRuntimeControlRemoteListenerRecord,
    origin: RecordOrigin,
    consumer = "",
) =
  let key = addressKey(r.address)
  rr.listeners[key] =
    ListenerEntry(record: r, key: key, origin: origin, consumer: consumer)

proc putExport*(
    rr: var RemoteRecords,
    r: LogosNSRuntimeControlProviderExportRecord,
    origin: RecordOrigin,
    consumer = "",
    module = "",
    instance = "",
) =
  var x = r
  x.provider = rr.normalized(r.provider)
  let key = addressKey(r.listener)
  rr.exports[(key, r.provider.provider)] = ExportEntry(
    record: x,
    listener: key,
    provider: r.provider.provider,
    module: module,
    instance: instance,
    origin: origin,
    consumer: consumer,
  )

func cmpBytes(a, b: openArray[byte]): int =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return cmp(a[i], b[i])
  cmp(a.len, b.len)

func listenerOrder*(rr: RemoteRecords): seq[ListenerEntry] =
  ## [SPEC RUNTIME l.3412] By the address's deterministic-CBOR bytes.
  for e in rr.listeners.values:
    result.add(e)
  result.sort(
    proc(a, b: ListenerEntry): int =
      cmpBytes(a.key, b.key)
  )

func exportOrder*(rr: RemoteRecords): seq[ExportEntry] =
  ## [SPEC RUNTIME l.3412] By the listener address's bytes, then the
  ## normalized provider Runtime, then the provider id (every provider here
  ## is this Runtime's).
  for e in rr.exports.values:
    result.add(e)
  result.sort(
    proc(a, b: ExportEntry): int =
      result = cmpBytes(a.listener, b.listener)
      if result == 0:
        result = cmp(a.provider, b.provider)
  )

func enabledListener*(rr: RemoteRecords, key: openArray[byte]): bool =
  let e = rr.listener(key)
  e.isSome and e.get.record.enabled

func usableExport*(rr: RemoteRecords, key: openArray[byte], provider: string): bool =
  ## [SPEC RUNTIME l.2733-2734, l.3311-3312] Enabled, through an enabled
  ## listener.
  let x = rr.exportOf(key, provider)
  x.isSome and x.get.record.enabled and rr.enabledListener(key)

func exportedThroughEnabled*(rr: RemoteRecords, provider: string): bool =
  ## [SPEC RUNTIME l.2765-2766] Whether any enabled export through an enabled
  ## listener names `provider`: forwarded discovery shows only those.
  for e in rr.exports.values:
    if e.provider == provider and e.record.enabled and rr.enabledListener(e.listener):
      return true
  false

proc configRecords*(
    runtimeId: string,
    listeners: openArray[LogosNSRuntimeControlRemoteListenerRecord],
    exports: openArray[LogosNSRuntimeControlProviderExportRecord],
): RemoteRecords =
  ## [SPEC RUNTIME l.3319-3321] The deployment configuration's records, as
  ## the host configuration checked them (`host_config.checkRemote`).
  result.runtimeId = runtimeId
  for l in listeners:
    result.putListener(l, roConfig)
  for e in exports:
    result.putExport(e, roConfig)

func badAddress*(a: LogosNSRuntimeControlRemoteListenerAddress): bool =
  ## [SPEC RUNTIME l.2704-2705] An address whose profile its transport does
  ## not select.
  a.mismatching
