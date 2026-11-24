## The numbers of a hosted provider's endpoint (Tier 4b step 4b-3, part
## 4b-3.2; DECISIONS G273) [IMPL]. A Module Host numbers its accepted
## connections as any transport loop does, from `AcceptedConnBase`. The
## Runtime folds the host's index into them (`hostedConn`), so the connections
## of every host and of its own loop are apart, and it finds the host of a
## command from the command alone (`isHostedCommand`, `hostOfConn`). A hosted
## endpoint's id is `HostedEndpointBase` plus the index; a host's loop knows
## its provider endpoint as `HostEndpoint`. [DECISIONS G492] The marked Package
## Manager's host also serves the system-service endpoint (fd 6), which its
## loop knows as `HostSystemEndpoint` and the Runtime as the hosted endpoint's
## id with `HostedSystemBit` set (`hostedSystemEndpoint`).

{.push raises: [], gcsafe.}

import results
import ../transport/io/api

const
  HostedConnBase* = AcceptedConnBase + (1'u64 shl 61)
    ## the Runtime's numbers for hosted connections begin here
  HostedEndpointBase* = 1'u64 shl 62 ## the Runtime's ids for hosted endpoints
  HostEndpoint* = EndpointId(1) ## the provider endpoint a host's loop serves
  HostSystemEndpoint* = EndpointId(2)
    ## [G492] the system-service endpoint the marked Package Manager's loop serves
  HostedSystemBit = 1'u64 shl 61 ## [G492] set in a hosted system endpoint's id
  MaxHostIndex* = (1'u64 shl 29) - 1
  ConnMask = 0xFFFF_FFFF'u64

func isHostedConn*(conn: ConnId): bool =
  conn >= HostedConnBase

func isHostedEndpoint*(id: EndpointId): bool =
  id >= HostedEndpointBase

func hostedEndpoint*(index: uint64): EndpointId =
  HostedEndpointBase + index

func hostedSystemEndpoint*(index: uint64): EndpointId =
  ## [G492] The Runtime's id for the system-service endpoint of host `index`.
  HostedEndpointBase or HostedSystemBit or index

func isSystemEndpoint*(id: EndpointId): bool =
  id.isHostedEndpoint and (id and HostedSystemBit) != 0

func hostOfEndpoint*(id: EndpointId): uint64 =
  (id - HostedEndpointBase) and not HostedSystemBit

func hostedConn*(index: uint64, hostConn: ConnId): Opt[ConnId] =
  ## The Runtime's number for connection `hostConn` of host `index`; none for
  ## one no loop gives.
  if hostConn < AcceptedConnBase or hostConn - AcceptedConnBase > ConnMask or
      index > MaxHostIndex:
    return Opt.none(ConnId)
  Opt.some(HostedConnBase or (index shl 32) or (hostConn - AcceptedConnBase))

func hostOfConn*(conn: ConnId): uint64 =
  (conn - HostedConnBase) shr 32

func hostConnOf*(conn: ConnId): ConnId =
  AcceptedConnBase + (conn and ConnMask)

func isHostedCommand*(cmd: IoCommand): bool =
  ## A command the Runtime routes to a host instead of its own loop.
  if cmd.kind == IoCommandKind.cmdStopServing:
    return cmd.stopEndpoint.isHostedEndpoint
  cmd.conn.isHostedConn
