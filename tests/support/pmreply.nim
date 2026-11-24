## The Package Manager engine's own answers, for `test_pm_module`'s byte comparisons
## (Tier 5 step 5-6a-1; DECISIONS G494): the engine without I/O (`pmworld`) over the
## same catalog, archives and trust as a hosted case, and the bytes it encoded
## (`oaEncoded`). A module of its own, so a suite's Runtime `Engine` and the Package
## Manager's never meet.

import std/tables
import ../../src/logos_core/package/resolver
import ./[pmfixture, pmworld]

proc inspectedBytes*(
    doc, trust: seq[byte],
    objects: openArray[(string, seq[byte])],
    package, version: string,
    binding = ("main", "hf"),
): seq[byte] =
  ## `inspect_package` of `package` at `version`, answered by the engine over the
  ## catalog `doc` (kept, so nothing fetches it), `trust`, and the archives `objects`
  ## served under their locators: the encoded `{inspection}` it hands the module.
  var served: Table[seq[byte], seq[byte]]
  for (locator, bytes) in objects:
    served[bytesOf(locator)] = bytes
  var w = newWorld(doc, bindings = [binding], kept = keptFor(doc), trust = trust)
  w.emit(w.e.start())
  w.bringUp(binding[0])
  var calls: seq[Command]
  w.serve(served, calls)
  let op = OperationRequest(
    kind: opInspect,
    root: RootReference(package: Opt.some(package), version: Opt.some(version)),
  )
  w.emit(w.e.submit(1, op))
  w.serve(served, calls)
  for c in w.answers:
    if c.answerTo == 1:
      doAssert c.answer.kind == oaEncoded, $c.answer.kind
      result = newSeq[byte](c.answer.encoded.len)
      for i, ch in c.answer.encoded:
        result[i] = byte(ch)
      return
  raiseAssert "the engine did not answer the inspection"
