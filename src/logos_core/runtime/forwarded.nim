## Forwarded consumers (Tier 5 step 5-7a-2; DECISIONS G413, G415) [IMPL]: how
## the engine names a consumer of another Runtime that an enrolled source
## Runtime forwards over remote Runtime Control (RUNTIME l.1685-1699).
##
## Inside the engine a consumer is one string: a local module instance's id,
## or, for a forwarded consumer, the id `forwardedId` makes from its Runtime
## and its instance id. That id is longer than any local instance id can be
## (`logos.runtime.module_instance_id` is at most 128 bytes, RUNTIME l.1758),
## so no comparison of consumers, origins, route owners or request keys can
## take a forwarded consumer for a local instance with the same instance id
## (an instance id is scoped to the Runtime that owns it, l.2549-2550). Where
## a consumer leaves the engine as a `logos.runtime.module_instance_address`
## (authority requests, audit and route records, `get_self`, the store), it
## is split back into its Runtime and instance id (`consumerAddress`).

{.push raises: [].}

import std/strutils

const
  MaxLocalId* = 128 ## [SPEC RUNTIME l.1758] the bound of a local instance id
  Mark = repeat('\x1F', MaxLocalId + 1)
    ## the start of every forwarded id: alone longer than a local id
  Sep = '\x1F' ## between the Runtime id and the instance id

type ForwardedParts* = tuple[runtime: string, instance: string]

func validRuntime(runtime: string): bool =
  runtime.len in 1 .. MaxLocalId and Sep notin runtime

func forwardedId*(runtime, instance: string): string =
  ## The engine's id of the consumer `instance` of the Runtime `runtime`;
  ## empty for parts no address can carry.
  if not runtime.validRuntime or instance.len notin 1 .. MaxLocalId:
    return ""
  Mark & runtime & $Sep & instance

func isForwarded*(id: string): bool =
  id.len > Mark.len and id.startsWith(Mark)

func forwardedParts*(id: string): ForwardedParts =
  ## A forwarded id's Runtime and instance id; empty for any other id.
  if not id.isForwarded:
    return ("", "")
  let at = id.find(Sep, Mark.len)
  if at < 0:
    return ("", "")
  (id[Mark.len ..< at], id[at + 1 .. ^1])

func consumerParts*(runtimeId, id: string): ForwardedParts =
  ## The Runtime and instance id of the consumer `id` of this Runtime
  ## (`runtimeId`): its own for a forwarded consumer.
  if id.isForwarded:
    id.forwardedParts
  else:
    (runtimeId, id)

func consumerLabel*(runtimeId, id: string): string =
  ## The consumer as text for diagnostics and records that name it: a local
  ## instance's id as it is; a forwarded one as `<instance> of Runtime
  ## <runtime>`.
  if id.isForwarded:
    let p = id.forwardedParts
    p.instance & " of Runtime " & p.runtime
  else:
    id

{.pop.}
