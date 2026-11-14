## RUNTIME §4.2 l.895-946: routing selection, the input that decides whether a
## route between two modules of this Runtime is direct or uses local transport
## [IMPL-DECISION G254; DECISIONS I90].
##
## The host supplies the rules (`lcn.app_config.routing`, R l.910-911 allows a
## host-supplied input). A rule names a callee (the provider's module name), a
## mode, and optionally a caller (the consumer's module name); a rule naming the
## caller beats a rule for any caller, and nothing else orders them (the
## R l.901-905 table). With no matching rule a route is direct, so every
## configuration without rules behaves as before. The mode is fixed per route
## at `establish_route`; renewal never changes it (R l.940).
##
## [Rev R12] `RouteEnds` is everything selection may look at. In 4b-2 only the
## rules decide; 4b-3 adds the hosted ends (a hosted end with no rule selects
## local transport, R l.3007) in `selectMode` alone.

{.push raises: [].}

import results
from ../loader/contract import LoaderModuleName
from ./authscopes import AuthorityModule

export results

const RuntimeControlModule* = "logos_runtime_control"
  ## [SPEC RUNTIME l.168-173] the Runtime Control binding's name: it is no
  ## provider, so no rule may route to it

type
  RouteMode* = enum
    rmDirect = "direct"
    rmLocalTransport = "local-transport"

  RoutingRule* = object
    caller*: Opt[string] ## the consumer's module name; none: any consumer
    callee*: string ## the provider's module name
    mode*: RouteMode

  RouteEnds* = object
    ## [Rev R12] What selection may look at: the two module names, and whether
    ## each end runs in a Module Host (always false in 4b-2).
    consumerModule*, providerModule*: string
    consumerHosted*, providerHosted*: bool

func selectMode*(rules: openArray[RoutingRule], ends: RouteEnds): RouteMode =
  ## [IMPL-DECISION G254] The mode of a route from `ends.consumerModule`
  ## to `ends.providerModule`: the rule naming both wins, then the rule for any
  ## caller, else direct.
  var any = Opt.none(RouteMode)
  for r in rules:
    if r.callee != ends.providerModule:
      continue
    if r.caller.isSome:
      if r.caller.get == ends.consumerModule:
        return r.mode
    else:
      any = Opt.some(r.mode)
  any.get(rmDirect)

func anyTransported*(rules: openArray[RoutingRule]): bool =
  ## Whether some rule selects local transport: the I/O thread is started at
  ## open only then.
  for r in rules:
    if r.mode == rmLocalTransport:
      return true
  false

func checkRules*(
    rules: openArray[RoutingRule], unixStream: bool
): Result[void, string] =
  ## [IMPL-DECISION G254] The checks at host-configuration decode and at
  ## `newEngine` for a configuration built in code:
  ## - one rule per (caller, callee) pair;
  ## - [G251; Rev R8] no rule names the Module Loader, as caller or callee:
  ##   every route to it is refused, and the Loader calls nothing;
  ## - the Runtime Control binding is no provider;
  ## - [SPEC TRANSPORT §8.2.1] no local-transport rule where this platform has
  ##   no `logos.local.unix-stream` profile (Windows).
  ## A local-transport rule whose callee is the Capability Authority is
  ## allowed: an ordinary consumer's route to it is served like any other
  ## provider's, while the engine's own `evaluate` calls stay direct (G48(a)).
  for i, r in rules:
    if r.callee.len == 0 or (r.caller.isSome and r.caller.get.len == 0):
      return err("a routing rule names an empty module")
    if r.callee == LoaderModuleName or r.caller == Opt.some(LoaderModuleName):
      return err("a routing rule names the reserved Module Loader")
    if r.callee == RuntimeControlModule:
      return err("a routing rule names " & RuntimeControlModule & " as a callee")
    for j in 0 ..< i:
      if rules[j].callee == r.callee and rules[j].caller == r.caller:
        return err(
          "two routing rules name the same caller and callee (" & r.caller.get("any") &
            " -> " & r.callee & ")"
        )
    if r.mode == rmLocalTransport and not unixStream:
      return
        err("local-transport is not supported on this platform (TRANSPORT §8.2.1)")
  ok()

func authorityCallee*(r: RoutingRule): bool =
  ## The rule routes ordinary consumers to the Capability Authority.
  r.callee == AuthorityModule
