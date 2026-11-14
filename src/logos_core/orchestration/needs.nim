## What the reference orchestration module calls, for the grants a host gives
## its instance (DECISIONS I94, P5; RUNTIME l.182-184, l.2553-2560).
##
## The module calls `get_self` (which needs no grant, l.2555), `list_modules`
## and `get_readiness` over the whole scope (TF-09, G161), `recover_module`
## on any instance with requested intent, and subscribes to four Runtime
## Control events. It is the origin of what it starts: the authority and the
## `start` defaults (`start_module`), and the `stop` defaults (`stop_module`).
## Those instances' execution and ambient permissions are what 4b-6 grants
## with them, under the scope names 4b-4 defines.

{.push raises: [], gcsafe.}

import results
import ./settings

const
  EveryInstanceMethods* =
    ["get_self", "list_modules", "get_readiness", "recover_module"]
  SubscribedEvents* = [
    "logos.runtime_control.module_state_changed_event",
    "logos.runtime_control.execution_state_changed_event",
    "logos.runtime_control.inventory_changed_event",
    "logos.runtime_control.configuration_state_changed_event",
  ]

type
  OriginNeed* = object ## One instance the module requests a lifecycle change of.
    module*, instance*: string
    methodName*: string ## `start_module` or `stop_module`

  OrchestratorNeeds* = object
    everyInstance*: seq[string] ## methods called on any instance
    events*: seq[string] ## events subscribed to
    origins*: seq[OriginNeed] ## the authority first, then the defaults

proc orchestratorNeeds*(c: OrchestratorSettings): Result[OrchestratorNeeds, string] =
  ## [I94] P5: what a value makes the module call.
  let s = ?settingsOf(c)
  var n =
    OrchestratorNeeds(everyInstance: @EveryInstanceMethods, events: @SubscribedEvents)
  for d in s.defaults:
    n.origins.add(
      OriginNeed(
        module: d.module,
        instance: d.instance,
        methodName: (if d.kind == defaultStop: "stop_module" else: "start_module"),
      )
    )
  ok(n)

{.pop.}
