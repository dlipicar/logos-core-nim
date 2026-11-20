## The Module Loader contract (LOADER §3-§10), rule by rule (Tier 4b step 4b-1;
## DECISIONS I89): values built from the accepted model validate and round-trip
## byte for byte through `loader/logos_module_loader_types.nim`; values outside
## a bound are refused (`support/schemasuite`). One test per rule, named by its
## requirement id; the module name and the pinned roots (`loader/contract.nim`)
## are checked against the same mirrored text.

import std/[os, strutils]
import unittest2
import ../src/logos_core/loader/[contract, logos_module_loader_types]
import logos_sdk/iface/accept
import ../src/logos_core/loader/logos_module_loader_kit as kit
import logos_sdk/testing/schemasuite

const Rules = [
  "logos.module_loader.realization_descriptor", "logos.module_loader.hosted_placement",
  "logos.module_loader.artifact", "logos.module_loader.static_binding",
  "logos.module_loader.capabilities", "logos.module_loader.list_capabilities_request",
  "logos.module_loader.list_capabilities_response", "logos.module_loader.state_context",
  "logos.module_loader.configuration_handoff", "logos.module_loader.provider_endpoint",
  "logos.module_loader.realize_request", "logos.module_loader.realize_response",
  "logos.module_loader.realization", "logos.module_loader.active_realization",
  "logos.module_loader.failed_realization", "logos.module_loader.realization_id",
  "logos.module_loader.get_status_request", "logos.module_loader.get_status_response",
  "logos.module_loader.apply_configuration_request",
  "logos.module_loader.apply_configuration_response",
  "logos.module_loader.release_request", "logos.module_loader.release_response",
  "logos.module_loader.error", "logos.module_loader.error_code",
]

let
  model = ruleModel(ldrDocuments())
  codec = codecTable("LogosNS", Rules)

template holds(name: string) =
  let problems = model.checkRule(name, codec)
  for p in problems:
    checkpoint name & ": " & p
  check problems.len == 0

suite "ldr.schema: the Module Loader contract (LOADER §3-§10)":
  test "every rule of the contract has its test here":
    for r in model.names:
      checkpoint r
      check r in Rules
    # The codec half is exercised: every map or choice rule declared by this
    # contract has a generated type that round-trips.
    var objects = 0
    for r in Rules:
      if r in model.names and model.composite(r):
        checkpoint r
        check codec(r, model.samples(r)[0]).isSome
        inc objects
    check objects > 0

  test "[LDR-0167] [LDR-0168] [LDR-0169] [LDR-0170] [LDR-0171] [LDR-0172] [LDR-0173] [LDR-0174] [LDR-0175] [LDR-0176] [LDR-0177] [LDR-0178] [LDR-0179] [LDR-0180] [LDR-0181] [LDR-0182] [LDR-0183] [LDR-0184] [LDR-0185] [LDR-0186] [LDR-0187] [LDR-0188] [LDR-0189] [LDR-0190] [LDR-0191] [TXT-0576] [TXT-0432] [TXT-0439] [TXT-0440] [TXT-0441] Appendix A is the Abstract's and §3-§10's blocks, rule for rule and in order, with the same root":
    # [SPEC LOADER l.737-739] The appendix governs; the eleven blocks the types
    # are generated from are its excerpts in the same order.
    let mirrors = currentSourcePath().parentDir.parentDir / "spec" / "mirrors" / "LDR"
    proc lines(text: string): seq[string] =
      for l in text.splitLines:
        if l.strip.len > 0:
          result.add l.strip

    let appendix = readFile(mirrors / "app-a.contract.cddl")
    var body: seq[string]
    for part in [
      "0.module", "3.descriptors", "4.capabilities", "5.1.state", "5.2.configuration",
      "5.3.endpoint", "6.realize", "7.records", "8.live", "9.release", "10.errors",
    ]:
      body.add lines(readFile(mirrors / (part & ".cddl")))
    check lines(appendix) == body
    let (primary, interfaces, supporting) = ldrDocuments()
    let generated = acceptContractSet(
      primary, interfaces, supporting, AcceptOptions(system: true)
    ).get
    let app = acceptContractSet(
      appendix, interfaces, supporting, AcceptOptions(system: true)
    ).get
    check app.primary.root == generated.primary.root
    check @(app.primary.root) == @(loaderRoots().contract)
    var a, g: seq[string]
    for d in app.primary.model.declarations:
      a.add d.name
    for d in generated.primary.model.declarations:
      g.add d.name
    check a == g and a.len > 0

  test "[LDR-0007] the contract is the logos_module_loader module (Abstract l.42)":
    check model.moduleName == "logos_module_loader"
    check kit.moduleName == LoaderModuleName
    check LoaderInstanceId == LoaderModuleName and LoaderBindingId == LoaderModuleName

  test "[LDR-0007] the pinned roots are recomputed from the mirrored contract (§13)":
    let r = loaderRoots()
    check r.contract.len == 32
    for m in LoaderMethod:
      checkpoint $m
      check r.methods[m].len == 32
      for n in LoaderMethod:
        if n != m:
          check r.methods[m] != r.methods[n]
    check loaderContract().schema_root == r.contract

  test "[LDR-0014] logos.module_loader.realization_descriptor (§3 l.147)":
    holds "logos.module_loader.realization_descriptor"

  test "[LDR-0015] logos.module_loader.hosted_placement (§3 l.165)":
    holds "logos.module_loader.hosted_placement"

  test "[LDR-0016] logos.module_loader.artifact (§3 l.170)":
    holds "logos.module_loader.artifact"

  test "[LDR-0017] logos.module_loader.static_binding (§3 l.177)":
    holds "logos.module_loader.static_binding"

  test "[LDR-0030] logos.module_loader.capabilities (§4 l.234)":
    holds "logos.module_loader.capabilities"

  test "[LDR-0031] logos.module_loader.list_capabilities_request (§4 l.245)":
    holds "logos.module_loader.list_capabilities_request"

  test "[LDR-0032] logos.module_loader.list_capabilities_response (§4 l.247)":
    holds "logos.module_loader.list_capabilities_response"

  test "[LDR-0038] logos.module_loader.state_context (§5.1 l.270)":
    holds "logos.module_loader.state_context"

  test "[LDR-0044] logos.module_loader.configuration_handoff (§5.2 l.294)":
    holds "logos.module_loader.configuration_handoff"

  test "[LDR-0047] logos.module_loader.provider_endpoint (§5.3 l.312)":
    holds "logos.module_loader.provider_endpoint"

  test "[LDR-0059] logos.module_loader.realize_request (§6 l.340)":
    holds "logos.module_loader.realize_request"

  test "[LDR-0060] logos.module_loader.realize_response (§6 l.347)":
    holds "logos.module_loader.realize_response"

  test "[LDR-0091] logos.module_loader.realization (§7 l.433)":
    holds "logos.module_loader.realization"

  test "[LDR-0092] logos.module_loader.active_realization (§7 l.437)":
    holds "logos.module_loader.active_realization"

  test "[LDR-0093] logos.module_loader.failed_realization (§7 l.445)":
    holds "logos.module_loader.failed_realization"

  test "[LDR-0094] logos.module_loader.realization_id (§7 l.452)":
    holds "logos.module_loader.realization_id"

  test "[LDR-0095] logos.module_loader.get_status_request (§7 l.454)":
    holds "logos.module_loader.get_status_request"

  test "[LDR-0096] logos.module_loader.get_status_response (§7 l.459)":
    holds "logos.module_loader.get_status_response"

  test "[LDR-0111] logos.module_loader.apply_configuration_request (§8 l.511)":
    holds "logos.module_loader.apply_configuration_request"

  test "[LDR-0112] logos.module_loader.apply_configuration_response (§8 l.517)":
    holds "logos.module_loader.apply_configuration_response"

  test "[LDR-0115] logos.module_loader.release_request (§9 l.548)":
    holds "logos.module_loader.release_request"

  test "[LDR-0116] logos.module_loader.release_response (§9 l.554)":
    holds "logos.module_loader.release_response"

  test "[LDR-0127] logos.module_loader.error (§10 l.599)":
    holds "logos.module_loader.error"

  test "[LDR-0128] logos.module_loader.error_code (§10 l.604)":
    holds "logos.module_loader.error_code"

  test "[LDR-0129] a response arm is chosen by its keys: success with an error, or a failure with both, is refused (§10 l.616-620)":
    let errorValue = cborMap([(cbor("code"), cbor("invalid-request"))])
    let active = cborMap(
      [
        (cbor("realization"), cbor("r-1")),
        (cbor("module_instance"), cbor("a")),
        (cbor("status"), cbor("active")),
      ]
    )
    check model.g.check(
      "logos.module_loader.realize_response",
      cborMap([(cbor("status"), cbor("succeeded")), (cbor("error"), errorValue)]),
    ).isErr
    check model.g.check(
      "logos.module_loader.realize_response",
      cborMap(
        [
          (cbor("status"), cbor("failed")),
          (cbor("error"), errorValue),
          (cbor("realization"), active),
        ]
      ),
    ).isErr
    check model.g.check(
      "logos.module_loader.realize_response",
      cborMap([(cbor("status"), cbor("succeeded")), (cbor("realization"), active)]),
    ).isOk
    check model.g.check(
      "logos.module_loader.release_response",
      cborMap([(cbor("status"), cbor("succeeded")), (cbor("error"), errorValue)]),
    ).isErr

  test "[LDR-0030] a hosted_dynamic capability is a map of true literals; force_release only true (§4 l.234-243)":
    let caps = "logos.module_loader.capabilities"
    check model.g.check(caps, cborMap([(cbor("direct_static"), cbor(true))])).isOk
    check model.g.check(caps, cborMap([(cbor("direct_static"), cbor(false))])).isErr
    check model.g.check(
      caps,
      cborMap([(cbor("hosted_dynamic"), cborMap([(cbor("process"), cbor(true))]))]),
    ).isOk
    check model.g.check(
      caps, cborMap([(cbor("hosted_dynamic"), cborMap([(cbor("vm"), cbor(true))]))])
    ).isErr
    check model.g.check(caps, cborMap([(cbor("force_release"), cbor(false))])).isErr

  test "[LDR-0014] a descriptor's arm is chosen by its strategy literal and keys (§3 l.147-163)":
    let d = "logos.module_loader.realization_descriptor"
    let binding = cborMap([(cbor("binding"), cbor("b"))])
    check model.g.check(
      d,
      cborMap(
        [
          (cbor("strategy"), cbor("direct_static")),
          (cbor("module"), cbor("meter_module")),
          (cbor("static_binding"), binding),
        ]
      ),
    ).isOk
    # direct_dynamic with a static binding: no arm has that key set.
    check model.g.check(
      d,
      cborMap(
        [
          (cbor("strategy"), cbor("direct_dynamic")),
          (cbor("module"), cbor("meter_module")),
          (cbor("static_binding"), binding),
        ]
      ),
    ).isErr
