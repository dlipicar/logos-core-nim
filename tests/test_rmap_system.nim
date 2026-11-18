## INTERFACE §3.8: core's own contracts survive the reverse mapping. S -> C -> S′ over the system
## contracts, the configuration and state formats, and the fixtures only core's suites use. The
## SDK's contracts and fixtures are in sdk/tests/test_rmap.nim.

import std/sequtils
import unittest2
import logos_sdk/iface/[accept, cinput, cmap, rmap]
import logos_sdk/hash/hashinput
from ./support/genfixtures_core import
  caPrimary, caSupporting, carrierPrimary, cliPrimary, coreNimFixtures, ctlPrimary,
  daemonConfigDocument, evstorePrimary, hostConfigDocument, lcnCallPrimary, ldrPrimary,
  ldrSupporting, logosctlPrimary, orchPrimary, orchStatePrimary, policyPrimary,
  statePrimary, storePrimary, trustPrimary

const deviceTarget = defined(android) or defined(ios)
  ## The contracts are read from the source tree, which a device does not have.

func roots(r: Reconstruction): seq[Digest] =
  if r.primary.isSome:
    result.add(r.primary.get.contract.root)
  for d in r.interfaces:
    result.add(d.contract.root)
  for d in r.supporting:
    result.add(d.contract.root)

proc roundTrip(
    primary: string,
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
    system = false,
): bool =
  ## [SPEC INTERFACE §3.8] S -> C -> S′: the same roots and binding, and `H′`
  ## equal to the header S generated.
  let s = acceptContractSet(primary, ifaces, supp, AcceptOptions(system: system))
  if s.isErr:
    checkpoint s.error
    return false
  let cs = s.get.cSchemaSet
  let h = contractHeader(cs).get
  var o = RmapOptions(system: system)
  if cs.module.isNone:
    o.subject = s.get.primary.model.namespace
  let r = reconstruct(@[HeaderSource(name: "h.h", text: h)], o)
  if r.isErr:
    checkpoint $r.error
    checkpoint h
    return false
  let want =
    @[s.get.primary.root] & s.get.interfaces.mapIt(it.root) &
    s.get.supporting.mapIt(it.root)
  result = r.get.roots == want and r.get.module == cs.module and r.get.header == h
  if not result:
    checkpoint "H:\n" & h & "\nH′:\n" & r.get.header

suite "core.c-reverse: round trips of core's contracts (INTERFACE §3.8; G158)":
  test "T7.1 [IFC-0356] [IFC-0357] [IFC-0368] [IFC-0381] [IFC-0389] [IFC-0393] [IMPL-DECISION G158] S -> C -> S′ over core's system contracts and generated fixtures":
    when deviceTarget:
      skip()
    else:
      proc texts(paths: openArray[string]): seq[string] =
        paths.mapIt(readFile(it))

      let none: seq[string] = @[]
      for (name, primary, supp, system) in [
        ("Capability Authority", caPrimary(), texts(caSupporting), true),
        ("Loader", ldrPrimary(), texts(ldrSupporting), true),
        ("host configuration", hostConfigDocument(), none, false),
        ("daemon configuration", daemonConfigDocument(), none, false),
        ("trust", readFile(trustPrimary), none, false),
        ("evidence store", readFile(evstorePrimary), none, false),
        ("ctl", readFile(ctlPrimary), none, false),
        ("logosctl", readFile(logosctlPrimary), none, false),
        ("cli", readFile(cliPrimary), none, false),
        ("lcn-call", readFile(lcnCallPrimary), none, false),
        ("store", readFile(storePrimary), none, false),
        ("carrier", readFile(carrierPrimary), none, false),
        ("authority policy", readFile(policyPrimary), none, false),
        ("authority state", readFile(statePrimary), none, false),
        ("orchestrator", readFile(orchPrimary), none, false),
        ("orchestrator state", readFile(orchStatePrimary), none, false),
      ]:
        checkpoint name
        check roundTrip(primary, [], supp, system)
      var seen: seq[string]
      for f in coreNimFixtures:
        if f.primary notin seen:
          seen.add(f.primary)
          checkpoint f.primary
          check roundTrip(
            readFile(f.primary), texts(f.interfaces), texts(f.supporting), f.system
          )
        if f.configuration.len > 0 and f.configuration notin seen:
          seen.add(f.configuration)
          checkpoint f.configuration
          check roundTrip(readFile(f.configuration))
