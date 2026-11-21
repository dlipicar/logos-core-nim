## A native module written with the lcn-gen kit for `gauge_module` (DECISIONS
## G339): an interface that declares only events, implemented with no primary
## document (INTERFACE l.2839), whose descriptor carries the earlier `gauge`
## contract it extends (§2.6 l.1693-1696). It has no method; `measure`
## publishes the level, and an alarm when it passes the bound.

{.used.} # imported by the tests for the C symbols it exports
import ../generated/gauge_module_kit

type Gauge* = ref object
  services*: ModuleServices
  bound*: uint64

proc initModule(_: type Gauge, init: ModuleInit): Result[Gauge, InvocationFailure] =
  ok(Gauge(services: init.services, bound: 100))

proc measure*(g: Gauge, level: uint64): Result[void, InvocationFailure] =
  ## Publishes `gauge.level_event`, then `gauge.alarm_event` past the bound.
  ?g.services.publish(GaugeLevelEvent(level: level))
  if level > g.bound:
    ?g.services.publish(GaugeAlarmEvent(level: level, bound: g.bound))
  ok()

exportGaugeModule(Gauge)
