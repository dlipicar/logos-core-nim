## A scripted world for the Package Manager's engine (Tier 5 step 5-3b): it
## keeps the commands the engine issues, answers calls from a table of
## objects, and feeds events back. The engine does no I/O, so this is the
## whole of its environment in `test_pm_fetch` and `test_pm_driver`.

import std/[sequtils, tables]
import ../../src/logos_core/package/resolver
import ../../src/logos_core/pm/engine
import ./pmfixture

export engine, tables

type
  KeyCounter* = ref object
    n*: int

  World* = object
    e*: Engine
    queue*: seq[Command] ## issued and not yet taken
    logs*: seq[string]
    kept*: seq[seq[byte]]
    replies*: seq[Command]
    keys*: KeyCounter

proc emit*(w: var World, cmds: seq[Command]) =
  for c in cmds:
    case c.kind
    of cmLog:
      w.logs.add(c.text)
    of cmWriteKept:
      w.kept.add(c.kept)
    of cmReply:
      w.replies.add(c)
    else:
      w.queue.add(c)

proc handle*(w: var World, ev: Event) =
  w.emit(w.e.handle(ev))

proc take*(w: var World, kinds: set[CommandKind]): Command =
  for i, c in w.queue:
    if c.kind in kinds:
      w.queue.delete(i)
      return c
  doAssert false, "no command of " & $kinds & " in " & $w.queue.mapIt(it.kind)

proc has*(w: World, kinds: set[CommandKind]): bool =
  w.queue.anyIt(it.kind in kinds)

proc count*(w: World, kinds: set[CommandKind]): int =
  w.queue.countIt(it.kind in kinds)

proc timerFor*(w: var World, ms: uint32): uint64 =
  ## The newest timer of `ms`, taken.
  for i in countdown(w.queue.high, 0):
    if w.queue[i].kind == cmTimer and w.queue[i].ms == ms:
      let id = w.queue[i].timer
      w.queue.delete(i)
      return id
  doAssert false, "no timer of " & $ms & " ms"

proc newWorld*(
    doc: seq[byte],
    bindings: openArray[(string, string)] = [("main", "storage_module")],
    kept = Opt.none(seq[byte]),
    limits = Opt.none(LcnPmLimits),
    trust = defaultTrust(),
    resolverLimits = MaxResolverLimits,
): World =
  let input =
    decodePmInput(pmValue(trust, doc, bindings, limits = limits).encode.get).get
  let counter = KeyCounter()
  let keys: KeySource = proc(): string {.gcsafe, raises: [].} =
    inc counter.n
    "key-" & $counter.n
  let (e, cmds) =
    initEngine(input, kept, resolverLimits, keys, linuxHost, pathRules = PathRules())
  result = World(e: e, keys: counter)
  result.emit(cmds)

proc bringUp*(w: var World, binding = "main", route = "route-1", ready = true) =
  ## Answers the binding's establishment and its readiness.
  let c = w.take({cmEstablish})
  doAssert c.binding == binding, c.binding
  w.handle(established(binding, c.key, route))
  discard w.take({cmWatch})
  if ready:
    w.handle(readinessOf(binding, rdReady))

proc serve*(
    w: var World, objects: Table[seq[byte], seq[byte]], calls: var seq[Command]
) =
  ## Answers every call the engine makes, from `objects`, until none is left.
  while w.has({cmStat, cmRead}):
    let c = w.take({cmStat, cmRead})
    calls.add(c)
    let data = objects.getOrDefault(c.locator, @[])
    let present = c.locator in objects
    let a =
      if not present:
        failureOf(fcUnavailable)
      elif c.kind == cmStat:
        sized(uint64(data.len))
      else:
        dataOf(data[int(c.offset) ..< int(c.offset) + int(c.length)])
    w.handle(answered(c.call, a))

proc keptFor*(doc: seq[byte]): Opt[seq[byte]] =
  var (s, _) = initCatalogState(pinOf(doc), defaultLimits(), Opt.none(seq[byte]))
  s.offer(doc).get.keptBytes
