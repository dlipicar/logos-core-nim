## Retrieval over `lcn.storage_fetch` and route upkeep (Tier 5 step 5-3b;
## DECISIONS G402; docs/PACKAGE-MANAGER.md §4). The fetcher's steps on their
## own, then the engine against scripted providers and scripted route answers:
## the engine does no I/O, so every call, route operation and timer it asks
## for is answered here. The hosted fake behind a real route is
## `test_pm_hosted`'s (5-3b-2).

import std/[sequtils, strutils, tables]
import unittest2
import ./support/[pmfixture, pmworld]

# The fetcher ------------------------------------------------------------------------

proc bigObject(n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte((i * 7) mod 251)

proc serveFetch(f: var Retrieval, data: seq[byte]): (FetchStep, seq[Call]) =
  ## Answers every call from `data`; the calls made, in order.
  var calls: seq[Call]
  var step = f.start()
  while step.kind == skCall:
    calls.add(step.call)
    let a =
      case step.call.kind
      of ckStat:
        sized(uint64(data.len))
      of ckRead:
        let o = int(step.call.offset)
        dataOf(data[o ..< o + int(step.call.length)])
    step = f.onAnswer(a)
  (step, calls)

suite "fetcher (G402)":
  test "[PKG-0353] a whole object in 1 MiB steps, its digest computed while reading":
    let data = bigObject(2 * ReadStep + ReadStep div 2)
    var f = initRetrieval(bytesOf("obj"), 1 shl 30, 1000)
    let (step, calls) = serveFetch(f, data)
    check step.kind == skDone
    check step.bytes == data
    check step.digest == blake3(data)
    check calls.mapIt((it.kind, it.offset, it.length)) ==
      @[
        (ckStat, 0'u64, 0'u32),
        (ckRead, 0'u64, uint32(ReadStep)),
        (ckRead, uint64(ReadStep), uint32(ReadStep)),
        (ckRead, uint64(2 * ReadStep), uint32(ReadStep div 2)),
      ]
    check f.finished

  test "an empty object needs no read":
    var f = initRetrieval(bytesOf("obj"), 10, 1000)
    let (step, calls) = serveFetch(f, @[])
    check step.kind == skDone
    check step.bytes.len == 0
    check step.digest == blake3(newSeq[byte]())
    check calls.len == 1

  test "a size over the bound is refused before any read":
    var f = initRetrieval(bytesOf("obj"), 10, 1000)
    let (step, calls) = serveFetch(f, bigObject(11))
    check step.kind == skUnavailable
    check step.reason == "the object is 11 bytes, more than the bound of 10"
    check calls.len == 1
    check calls[0].kind == ckStat

  test "stat_object answering unavailable is not retried":
    var f = initRetrieval(bytesOf("obj"), 10, 1000)
    discard f.start()
    let step = f.onAnswer(failureOf(fcUnavailable))
    check step.kind == skUnavailable
    check step.reason == "stat_object answered unavailable"
    check f.finished

  test "a mid-object unavailable is retried from its offset, at most three times in a row":
    let data = bigObject(ReadStep + 10)
    var f = initRetrieval(bytesOf("obj"), 1 shl 30, 1000)
    discard f.start()
    var step = f.onAnswer(sized(uint64(data.len)))
    step = f.onAnswer(dataOf(data[0 ..< ReadStep]))
    check step.kind == skCall
    check step.call.offset == uint64(ReadStep)
    var waits: seq[uint32]
    for i in 0 ..< MaxReadRetries:
      step = f.onAnswer(failureOf(fcUnavailable))
      check step.kind == skBackoff
      check step.call.offset == uint64(ReadStep)
      waits.add(step.ms)
      step = f.resume()
      check step.kind == skCall
      check step.call.offset == uint64(ReadStep)
    check waits == @ReadRetryBackoffMs
    step = f.onAnswer(dataOf(data[ReadStep ..< data.len]))
    check step.kind == skDone
    check step.bytes == data
    # Four in a row end it.
    var g = initRetrieval(bytesOf("obj"), 1 shl 30, 1000)
    discard g.start()
    step = g.onAnswer(sized(uint64(data.len)))
    for i in 0 ..< MaxReadRetries:
      step = g.onAnswer(failureOf(fcUnavailable))
      check step.kind == skBackoff
      step = g.resume()
    step = g.onAnswer(failureOf(fcUnavailable))
    check step.kind == skUnavailable
    check step.reason == "read_object at offset 0 answered unavailable 4 times in a row"

  test "a successful read resets the retry count":
    let data = bigObject(3 * ReadStep)
    var f = initRetrieval(bytesOf("obj"), 1 shl 30, 1000)
    discard f.start()
    var step = f.onAnswer(sized(uint64(data.len)))
    for k in 0 ..< 3:
      for i in 0 ..< MaxReadRetries:
        step = f.onAnswer(failureOf(fcUnavailable))
        check step.kind == skBackoff
        step = f.resume()
      let o = int(step.call.offset)
      step = f.onAnswer(dataOf(data[o ..< o + ReadStep]))
    check step.kind == skDone

  test "not-ready, or a lost route, waits within the deadline and then makes the same call":
    var f = initRetrieval(bytesOf("obj"), 1 shl 30, 777)
    discard f.start()
    var step = f.onAnswer(failureOf(fcNotReady))
    check step.kind == skWait
    check step.ms == 777
    check step.call.kind == ckStat
    step = f.resume()
    check step.kind == skCall
    check step.call.kind == ckStat
    step = f.onAnswer(sized(5))
    step = f.onAnswer(routeGone())
    check step.kind == skWait
    check step.call.kind == ckRead
    check f.resume().call.offset == 0

  test "every other failure ends the retrieval as unavailable":
    for (a, reason) in [
      (
        failureOf(fcInvalidLocator, "bad\nlocator"),
        "read_object at offset 0 answered invalid-locator: \"bad\\x0Alocator\"",
      ),
      (failureOf(fcOutOfRange), "read_object at offset 0 answered out-of-range"),
      (failureOf(fcInvalidLength), "read_object at offset 0 answered invalid-length"),
      (
        invocationError("NOT_AUTHORISED"),
        "read_object at offset 0 failed: NOT_AUTHORISED",
      ),
      (dataOf(bytesOf("abcd")), "read_object at offset 0 answered 4 bytes, not 5"),
      (dataOf(bytesOf("abcdef")), "read_object at offset 0 answered 6 bytes, not 5"),
    ]:
      var f = initRetrieval(bytesOf("obj"), 100, 1000)
      discard f.start()
      discard f.onAnswer(sized(5))
      let step = f.onAnswer(a)
      check step.kind == skUnavailable
      check step.reason == reason
    var g = initRetrieval(bytesOf("obj"), 100, 1000)
    discard g.start()
    let s = g.onAnswer(failureOf(fcInvalidLocator))
    check s.reason == "stat_object answered invalid-locator"

  test "a call or a wait past its bound ends the retrieval":
    var f = initRetrieval(bytesOf("obj"), 100, 1000)
    discard f.start()
    let a = f.onDeadline()
    check a.kind == skUnavailable
    check a.reason == "stat_object passed its deadline of 1000 ms"
    var g = initRetrieval(bytesOf("obj"), 100, 1000)
    discard g.start()
    discard g.onAnswer(failureOf(fcNotReady))
    let b = g.onWaitExpired()
    check b.kind == skUnavailable
    check b.reason == "stat_object: the binding was not usable within 1000 ms"

suite "engine: the catalog over its binding (G401, G402)":
  test "[PKG-0353] the catalog is read over its binding's route once the provider is ready, then kept":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")], sequence = 3)
    var w = newWorld(doc)
    w.emit(w.e.start())
    check w.e.catalogInUse.isNone
    w.bringUp(ready = false)
    check not w.has({cmStat})
    w.handle(readinessOf("main", rdStarting))
    check not w.has({cmStat})
    w.handle(readinessOf("main", rdReady))
    var calls: seq[Command]
    w.serve({bytesOf("catalog"): doc}.toTable, calls)
    check calls.mapIt(it.kind) == @[cmStat, cmRead]
    check calls.allIt(it.target == "main" and it.locator == bytesOf("catalog"))
    check calls.allIt(it.deadlineMs == DefaultReadDeadlineMs)
    check w.e.catalogInUse.isSome
    check w.e.catalogInUse.get.sequence == 3
    check w.kept.len == 1
    check decodeKept(w.kept[0]).get.catalog.bytes == doc
    # Accepted once, so a later ready reads nothing.
    w.handle(readinessOf("main", rdReady))
    check not w.has({cmStat})

  test "with the kept catalog matching, it is in use before any read, and reading it again writes nothing":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc, kept = keptFor(doc))
    check w.e.catalogInUse.isSome
    check w.logs.anyIt(it.startsWith("the kept catalog is in use"))
    w.emit(w.e.start())
    w.bringUp()
    var calls: seq[Command]
    w.serve({bytesOf("catalog"): doc}.toTable, calls)
    check calls.len == 2
    check w.kept.len == 0

  test "a failed read is retried after a back-off while the binding stays ready, and on the next ready":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    w.bringUp()
    var calls: seq[Command]
    w.serve(initTable[seq[byte], seq[byte]](), calls)
    check calls.len == 1 # stat_object answered unavailable: not retried
    check w.logs.anyIt(
      it == "the configured catalog could not be read: stat_object answered unavailable"
    )
    let t = w.timerFor(AcquireBackoffMs[0])
    w.handle(fired(t))
    calls.setLen(0)
    w.serve(initTable[seq[byte], seq[byte]](), calls)
    check calls.len == 1
    let t2 = w.timerFor(AcquireBackoffMs[1])
    # The next ready reads at once; the pending back-off then does nothing.
    w.handle(readinessOf("main", rdReady))
    calls.setLen(0)
    w.serve({bytesOf("catalog"): doc}.toTable, calls)
    check calls.len == 2
    check w.e.catalogInUse.isSome
    w.handle(fired(t2))
    check not w.has({cmStat})

  test "a catalog over its bound is refused from stat_object, before any read":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(
      doc, limits = Opt.some(LcnPmLimits(catalog_bytes: Opt.some(uint32(doc.len - 1))))
    )
    w.emit(w.e.start())
    w.bringUp()
    var calls: seq[Command]
    w.serve({bytesOf("catalog"): doc}.toTable, calls)
    check calls.mapIt(it.kind) == @[cmStat]
    check w.e.catalogInUse.isNone
    check w.logs.anyIt(it.endsWith("more than the bound of " & $(doc.len - 1)))

  test "a refused document ends acquisition for this start":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    w.bringUp()
    var calls: seq[Command]
    # The provider serves other bytes under the pinned locator.
    w.serve(
      {bytesOf("catalog"): catalogBytes([entryOf("logos.wallet", "1.0.0")])}.toTable,
      calls,
    )
    check w.e.catalogInUse.isNone
    check w.logs.anyIt(
      it == "the configured catalog is refused: its digest is not the pinned one"
    )
    w.handle(readinessOf("main", rdReady))
    check not w.has({cmStat})
    check not w.has({cmTimer}) or
      w.queue.allIt(it.kind != cmTimer or it.ms != AcquireBackoffMs[0])

  test "a call past its deadline ends the retrieval, and its late answer is ignored":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w =
      newWorld(doc, limits = Opt.some(LcnPmLimits(read_deadline_ms: Opt.some(50'u32))))
    w.emit(w.e.start())
    w.bringUp()
    let stat = w.take({cmStat})
    check stat.deadlineMs == 50
    let t = w.timerFor(50)
    w.handle(fired(t))
    check w.logs.anyIt(
      it ==
        "the configured catalog could not be read: stat_object passed its deadline of 50 ms"
    )
    w.handle(answered(stat.call, sized(uint64(doc.len))))
    check not w.has({cmRead})

  test "not-ready, then ready: the same call again on the next ready":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    w.bringUp()
    let stat = w.take({cmStat})
    w.handle(answered(stat.call, sized(uint64(doc.len))))
    let read = w.take({cmRead})
    w.handle(answered(read.call, failureOf(fcNotReady)))
    check not w.has({cmRead})
    check w.e.status[0].readiness.isNone
    w.handle(readinessOf("main", rdOffline))
    check not w.has({cmRead})
    w.handle(readinessOf("main", rdReady))
    let again = w.take({cmRead})
    check again.offset == read.offset
    check again.length == read.length
    w.handle(answered(again.call, dataOf(doc)))
    check w.e.catalogInUse.isSome

  test "a wait for ready past read_deadline_ms ends the retrieval":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w =
      newWorld(doc, limits = Opt.some(LcnPmLimits(read_deadline_ms: Opt.some(70'u32))))
    w.emit(w.e.start())
    w.bringUp()
    let stat = w.take({cmStat})
    discard w.timerFor(70) # the call's deadline
    w.handle(answered(stat.call, failureOf(fcNotReady)))
    let t = w.timerFor(70) # the wait's bound
    w.handle(fired(t))
    check w.logs.anyIt(
      it ==
        "the configured catalog could not be read: stat_object: the binding was not usable within 70 ms"
    )

suite "engine: route upkeep (G402)":
  test "every establishment has a distinct key, never a fixed one":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(
      doc, bindings = [("main", "storage_module"), ("mirror", "storage_mirror")]
    )
    w.emit(w.e.start())
    let a = w.take({cmEstablish})
    let b = w.take({cmEstablish})
    check (a.binding, a.instance) == ("main", "storage_module")
    check (b.binding, b.instance) == ("mirror", "storage_mirror")
    check a.key != b.key
    w.handle(establishRefused("mirror", b.key, "no ready provider"))
    w.handle(fired(w.timerFor(RouteBackoffMs[0])))
    let c = w.take({cmEstablish})
    check c.binding == "mirror"
    check c.key notin [a.key, b.key]
    # A second engine draws its own keys: none is derived from the binding.
    var v = newWorld(doc)
    v.keys.n = 100
    v.emit(v.e.start())
    check v.take({cmEstablish}).key == "key-101"

  test "a lost ready route is renewed under a new key, and its readiness watched again":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc, kept = keptFor(doc))
    w.emit(w.e.start())
    let first = w.take({cmEstablish})
    w.handle(established("main", first.key, "route-1"))
    discard w.take({cmWatch})
    w.handle(routeLost("main", "route-1"))
    let renew = w.take({cmRenew})
    check renew.route == "route-1"
    check renew.key != first.key
    check w.e.status[0].state == rsRenewing
    w.handle(renewed("main", renew.key))
    check w.e.status[0].state == rsReady
    check w.take({cmWatch}).route == "route-1"
    # A route end for a route the binding no longer has changes nothing.
    w.handle(routeLost("main", "route-0"))
    check not w.has({cmRenew})

  test "a renewal refused as closed, failed or revoked releases the route and establishes anew":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    for reason in ["closed", "failed", "revoked", "unknown route"]:
      var w = newWorld(doc)
      w.emit(w.e.start())
      let first = w.take({cmEstablish})
      w.handle(established("main", first.key, "route-1"))
      discard w.take({cmWatch})
      w.handle(routeLost("main", "route-1"))
      let renew = w.take({cmRenew})
      w.handle(renewRefused("main", renew.key, reason))
      check w.take({cmRelease}).route == "route-1"
      let again = w.take({cmEstablish})
      check again.key notin [first.key, renew.key]
      w.handle(established("main", again.key, "route-2"))
      check w.take({cmWatch}).route == "route-2"
      check w.e.status[0].route == "route-2"

  test "a refused establishment backs off, longer each time, then establishes under a new key":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    var keys: seq[string]
    for i in 0 ..< RouteBackoffMs.len + 1:
      let c = w.take({cmEstablish})
      keys.add(c.key)
      w.handle(establishRefused("main", c.key, "NOT_AUTHORISED"))
      check w.e.status[0].state == rsBackoff
      w.handle(fired(w.timerFor(RouteBackoffMs[min(i, RouteBackoffMs.high)])))
    check keys.deduplicate.len == keys.len
    check w.logs.anyIt(it.endsWith("was refused: \"NOT_AUTHORISED\""))
    let c = w.take({cmEstablish})
    w.handle(established("main", c.key, "route-9"))
    check w.e.status[0].state == rsReady

  test "a lost establishment response is retried under the same key, then counts as refused":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    let c = w.take({cmEstablish})
    for i in 0 ..< MaxLostResponses:
      w.handle(establishLost("main", c.key))
      check w.take({cmEstablish}).key == c.key
    w.handle(establishLost("main", c.key))
    check w.e.status[0].state == rsBackoff
    check not w.has({cmEstablish})

  test "a stale answer under an old key changes nothing":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    let c = w.take({cmEstablish})
    w.handle(established("main", "key-0", "route-x"))
    check w.e.status[0].state == rsEstablishing
    w.handle(established("main", c.key, "route-1"))
    check w.e.status[0].route == "route-1"

  test "a call that finds its route lost renews it, and the read resumes from its offset":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    w.bringUp()
    let stat = w.take({cmStat})
    w.handle(answered(stat.call, sized(uint64(doc.len))))
    let read = w.take({cmRead})
    w.handle(answered(read.call, routeGone()))
    let renew = w.take({cmRenew})
    check not w.has({cmRead})
    w.handle(renewed("main", renew.key))
    let again = w.take({cmRead})
    check again.offset == read.offset
    w.handle(answered(again.call, dataOf(doc)))
    check w.e.catalogInUse.isSome

  test "a call that finds its route lost after it was already replaced is issued again at once":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    w.bringUp()
    let stat = w.take({cmStat})
    w.handle(routeLost("main", "route-1"))
    w.handle(renewed("main", w.take({cmRenew}).key))
    w.handle(answered(stat.call, routeGone()))
    check not w.has({cmRenew})
    let again = w.take({cmStat})
    w.handle(answered(again.call, sized(uint64(doc.len))))
    check w.has({cmRead})

  test "a refused establishment fails the binding's waiting retrievals":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    w.bringUp()
    let stat = w.take({cmStat})
    w.handle(answered(stat.call, routeGone()))
    let renew = w.take({cmRenew})
    w.handle(renewRefused("main", renew.key, "revoked"))
    discard w.take({cmRelease})
    let c = w.take({cmEstablish})
    w.handle(establishRefused("main", c.key, "NOT_AUTHORISED"))
    check w.logs.anyIt(
      it ==
        "the configured catalog could not be read: the route to the binding's provider was refused"
    )

  test "after stop nothing is issued, and a route end queued after it is dropped (G437)":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    let c = w.take({cmEstablish})
    w.handle(established("main", c.key, "route-1"))
    discard w.take({cmWatch})
    # [G455] `stop` answers the operations still running; none is.
    let answers = w.e.stop()
    check answers.len == 0
    w.handle(routeLost("main", "route-1"))
    w.handle(readinessOf("main", rdReady))
    w.emit(w.e.resolve(1, RootReference(package: Opt.some("logos.example"))))
    check w.queue.len == 0
    check w.replies.len == 0
    check w.e.status.allIt(it.state == rsStopped)

suite "engine: sources and bindings (G402, G405)":
  test "a source naming no configured binding is unavailable, and the name is logged once":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0", storage = "elsewhere")])
    var w = newWorld(doc, kept = keptFor(doc))
    w.emit(w.e.start())
    w.bringUp()
    var calls: seq[Command]
    w.serve({bytesOf("catalog"): doc}.toTable, calls)
    for id in [1'u64, 2]:
      w.emit(w.e.resolve(id, RootReference(package: Opt.some("logos.example"))))
    check w.replies.len == 2
    for r in w.replies:
      check r.outcome.isErr
      check r.outcome.error.code == pecPackageUnavailable
    check w.logs.countIt(it.contains("\"elsewhere\"")) == 1
    check not w.has({cmStat})

  test "with no catalog in use, resolution fails package-unavailable, not as an empty catalog":
    let doc = catalogBytes([entryOf("logos.example", "1.0.0")])
    var w = newWorld(doc)
    w.emit(w.e.start())
    w.emit(w.e.resolve(1, RootReference(package: Opt.some("logos.example"))))
    check w.replies.len == 1
    check w.replies[0].outcome.error.code == pecPackageUnavailable
    check w.replies[0].outcome.error.msg == "no catalog is in use"

  test "[PKG-0167] provenance_object is never read":
    var e = entryOf("logos.example", "1.0.0")
    e.source.provenanceLocator = Opt.some(bytesOf("provenance"))
    let doc = catalogBytes([e])
    var w = newWorld(doc, kept = keptFor(doc))
    w.emit(w.e.start())
    w.bringUp()
    var calls: seq[Command]
    w.serve({bytesOf("catalog"): doc}.toTable, calls)
    w.emit(w.e.resolve(1, RootReference(package: Opt.some("logos.example"))))
    w.serve(initTable[seq[byte], seq[byte]](), calls)
    check calls.len > 2
    check calls.allIt(it.locator != bytesOf("provenance"))
    check w.replies[0].outcome.error.code == pecPackageUnavailable

  test "one retrieval at a time per binding, in order of request":
    let doc = catalogBytes(
      [entryOf("logos.example", "1.0.0"), entryOf("logos.wallet", "1.0.0")]
    )
    var w = newWorld(doc, kept = keptFor(doc))
    w.emit(w.e.start())
    w.bringUp()
    var calls: seq[Command]
    w.serve({bytesOf("catalog"): doc}.toTable, calls)
    w.emit(w.e.resolve(1, RootReference(package: Opt.some("logos.example"))))
    w.emit(w.e.resolve(2, RootReference(package: Opt.some("logos.wallet"))))
    check w.count({cmStat, cmRead}) == 1
    check w.e.queued("main") == 2
    let first = w.take({cmStat})
    check first.locator == bytesOf("logos.example@1.0.0")
    w.handle(answered(first.call, failureOf(fcUnavailable)))
    check w.replies.len == 1
    check w.replies[0].request == 1
    let second = w.take({cmStat})
    check second.locator == bytesOf("logos.wallet@1.0.0")
    w.handle(answered(second.call, failureOf(fcUnavailable)))
    check w.replies.mapIt(it.request) == @[1'u64, 2]
