## lcn_call's continuation rule (Tier 5 step N-2b; DECISIONS G347; plan §3.4;
## re-pin Q3, owner row 38): which continuation of an `establish_route` answer
## it follows, and where. docs/DAEMON.md §7a.
##
## Only a `connect_remote` binding passes continuations through (row 37); the
## answer is then an inter-Runtime response a module may follow (R l.3031).
## On `lcn_call`'s own binding the Runtime resolves them itself and answers
## none (R l.3019-3020): `routes.nim` treats one there as a fault. Nothing
## calls `nextHop` until Tier 5 step 5-7a supplies node bindings; 5-7a wires
## it and tests it end to end.
##
## The contract of `nextHop`, in the order it checks:
## 1. A target without `runtime.runtime_instance_id` or without `provider` is a
##    fault, exit 4: the text requires both (R l.3054), though the schema makes
##    them optional.
## 2. A path of `MaxHops` targets already is exit 4 (R l.3058 leaves the bound
##    to the implementation; Q3's "small fixed number") [IMPL].
## 3. The cycle key is the pair (target's Runtime id, target's provider id); a
##    pair already on the path is exit 4. The continuation's own `provider` is
##    the facade's address (R l.3052), not part of the key.
## 4. A target on `lcn_call`'s own Runtime (the id `get_self` gives) is refused,
##    exit 1: `local` is built in, not a configured node, and IF l.3875 forbids
##    `connect_remote` to it.
## 5. A target whose Runtime id is a configured node's is followed through that
##    node's binding, at the configured address, never the address in the
##    continuation; the next request is a new `single` request selecting the
##    target's provider, with the same contract and access and a fresh `lcall-`
##    request key (R l.3056), which the caller makes (`routes.requestKey`).
## 6. Any other target is exit 1, naming it.
##
## The caller seeds the path with the first target it called (its node's
## Runtime id and the selected provider), so a continuation back to it is a
## cycle.
##
## [G349 N-2d; SPEC INTERFACE l.373] `nextHop` is never asked for a marked
## method: `commands.runCall` calls one on the local Runtime only, whose
## binding answers no continuation. A remote path for a marked payload stays
## prohibited, so 5-7a's wiring must keep that refusal before any hop.

{.push raises: [], gcsafe.}

import results
import logos_sdk/iface/outcome
import logos_sdk/kit/rc_types
import ./wire

export results

const MaxHops* = 4 ## [IMPL] targets on one path, the first included

type
  ConfiguredNode* = object ## One node of the protected node list (5-7a).
    name*: string
    runtimeId*: string ## its endpoint's `runtime_instance_id` (IF l.3874)

  HopStep* = object ## One target on the path: the cycle key.
    runtimeId*: string
    provider*: string

  NextHop* = object ## Where the next request goes.
    node*: string ## the configured node whose binding carries it
    provider*: string ## the provider it selects (`target.provider`)
    step*: HopStep ## to append to the path

  HopRefusal* = object ## Why the continuation is not followed.
    exit*: int ## `ExitRefused` or `ExitRc`
    code*: string ## the error channel's code for a fault, or ""
    message*: string

func fault(message: string): HopRefusal =
  HopRefusal(exit: ExitRc, code: $ecModule, message: message)

func refusal(message: string): HopRefusal =
  HopRefusal(exit: ExitRefused, message: message)

func nextHop*(
    nodes: openArray[ConfiguredNode],
    ownRuntime: string,
    path: openArray[HopStep],
    c: LogosNSRuntimeControlRouteContinuation,
): Result[NextHop, HopRefusal] =
  ## [G347; plan §3.4] The next hop for continuation `c`, or why not.
  let t = c.target
  if t.runtime.runtime_instance_id.isNone or t.provider.isNone:
    return err(fault("a continuation's target names no Runtime id or no provider"))
  let step =
    HopStep(runtimeId: t.runtime.runtime_instance_id.get, provider: t.provider.get)
  if path.len >= MaxHops:
    return err(fault("more than " & $MaxHops & " continuations on one call"))
  for s in path:
    if s == step:
      return err(
        fault(
          "a continuation cycle: provider " & step.provider & " through Runtime " &
            step.runtimeId & " again"
        )
      )
  if step.runtimeId == ownRuntime:
    return err(refusal("the provider is on this node; call it without --node"))
  for n in nodes:
    if n.runtimeId == step.runtimeId:
      return ok(NextHop(node: n.name, provider: step.provider, step: step))
  err(
    refusal(
      "the provider is reached through Runtime " & step.runtimeId & " (provider " &
        step.provider & "); add that Runtime as a node to call it"
    )
  )

{.pop.}
