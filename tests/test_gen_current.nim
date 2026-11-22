## lcn-gen's output for core's own contracts and formats [D29]: the committed modules are current,
## and the schemas that repeat another schema's rules still agree with it.

import std/strutils
import unittest2
import logos_sdk/[cbor, hash, pins]
from logos_sdk/codegen/kitgen import ExportListKind
import ../src/logos_core/authority/[policy_types, logos_capability_authority_types]
import ./support/genfixtures_core

proc diag(s: string): seq[byte] =
  let v = parseDiag(s)
  if v.isErr:
    checkpoint v.error
  encodeCbor(v.get)

suite "core.nim-types: core's generated modules (D29)":
  test "the committed lcn-gen output is current (run `nimble regen` if not)":
    check generatedHostConfigTypes().get == readFile(hostConfigTypesPath)
    check generatedDaemonConfigTypes().get == readFile(daemonConfigTypesPath)
    check generatedTrustTypes().get == readFile(trustTypesPath)
    check generatedRemoteTrustTypes().get == readFile(remoteTrustTypesPath)
    check generatedTrustdocTypes().get == readFile(trustdocTypesPath)
    check generatedEvstoreTypes().get == readFile(evstoreTypesPath)
    check generatedCtlTypes().get == readFile(ctlTypesPath)
    check generatedLogosctlTypes().get == readFile(logosctlTypesPath)
    check generatedLogosctlKit().get == readFile(logosctlKitPath)
    check generatedCliTypes().get == readFile(cliTypesPath)
    check generatedLcnCallTypes().get == readFile(lcnCallTypesPath)
    check generatedLcnCallConfigTypes().get == readFile(lcnCallConfigTypesPath)
    check generatedLcnCallKit().get == readFile(lcnCallKitPath)
    for kind in ExportListKind:
      checkpoint lcnCallExportsPath(kind)
      check generatedLcnCallExports(kind).get == readFile(lcnCallExportsPath(kind))
    check generatedStoreTypes().get == readFile(storeTypesPath)
    check generatedCarrierTypes().get == readFile(carrierTypesPath)
    check generatedCaTypes().get == readFile(caTypesPath)
    check generatedCaKit().get == readFile(caKitPath)
    check generatedLdrTypes().get == readFile(ldrTypesPath)
    check generatedLdrKit().get == readFile(ldrKitPath)
    check generatedPolicyTypes().get == readFile(policyTypesPath)
    check generatedStateTypes().get == readFile(stateTypesPath)
    check generatedOrchTypes().get == readFile(orchTypesPath)
    check generatedOrchConfigTypes().get == readFile(orchConfigTypesPath)
    check generatedOrchKit().get == readFile(orchKitPath)
    check generatedOrchStateTypes().get == readFile(orchStateTypesPath)
    for f in coreNimFixtures:
      checkpoint f.module
      check f.generated.get == readFile(f.fixturePath)
    for f in coreHeaderFixtures:
      checkpoint f.header
      check f.generated.get == readFile(f.fixturePath)

  test "every generated module carries the provisional stamp of the pinned spec":
    let stamp = "PROVISIONAL (spec " & SpecRevision[0 .. 7] & ")"
    check stamp in readFile(hostConfigTypesPath)
    check stamp in readFile(storeTypesPath)
    check stamp in readFile(carrierTypesPath)
    for path in [
      caTypesPath, caKitPath, ldrTypesPath, ldrKitPath, policyTypesPath, stateTypesPath,
      orchTypesPath, orchConfigTypesPath, orchKitPath, orchStateTypesPath,
      daemonConfigTypesPath, trustTypesPath, remoteTrustTypesPath, trustdocTypesPath,
      evstoreTypesPath, ctlTypesPath, logosctlTypesPath, logosctlKitPath, cliTypesPath,
      lcnCallTypesPath, lcnCallConfigTypesPath, lcnCallKitPath,
    ]:
      checkpoint path
      check stamp in readFile(path)
    for f in coreNimFixtures:
      check stamp in readFile(f.fixturePath)

  test "[IMPL] the policy's lcn.ap_commitment repeats logos.capability_authority.commitment_requirements":
    # policy.cddl names no CA type (DECISIONS I84): its commitment map is a
    # copy, and both must take and make the same bytes.
    check "logos.capability_authority.commitment_retention = \"retain-root\"" in
      readFile("spec/mirrors/CAP/4.commitments.cddl")
    for value in [
      "{}", "{\"request\": \"retain-root\"}", "{\"response\": \"retain-root\"}",
      "{\"request\": \"retain-root\", \"response\": \"retain-root\"}",
      "{\"request\": \"keep\"}", "{\"other\": 1}",
    ]:
      checkpoint value
      let bytes = diag(value)
      let a = decode(LcnApCommitment, bytes)
      let b = decode(LogosNSCapabilityAuthorityCommitmentRequirements, bytes)
      check a.isOk == b.isOk
      if a.isOk and b.isOk:
        check encode(a.get).get == bytes
        check encode(b.get).get == bytes

  test "[IMPL] the stored module record repeats the host configuration's rules":
    # store.cddl's lcn.rs_record is lcn.app_module without `instance`, plus
    # the configuration commitment CONFIG will need (DECISIONS I82).
    proc rules(path: string): seq[(string, string)] =
      var name, body: string
      for line in readFile(path).splitLines & @[""]:
        if line.startsWith(";"):
          continue
        if line.len == 0:
          if name.len > 0:
            result.add((name, body))
          name = ""
          body = ""
        elif name.len == 0 and " =" in line:
          name = line.split(" =")[0]
          body = line.split(" =", 1)[1] & "\n"
        else:
          body.add(line & "\n")

    proc normal(body: string): string =
      for line in body.splitLines:
        let t = line.strip
        # The record keeps the accepted binding's digest; the host config
        # carries the declaration and the instance's provisioned value.
        if t.startsWith("instance:") or t.startsWith("? configuration_commitment:") or
            t.startsWith("? configuration:") or
            t.startsWith("? provisioned_configuration:"):
          continue
        result.add(t.replace("lcn.app_", "lcn.rs_") & "\n")

    var app, rs: seq[(string, string)]
    for (n, b) in rules(hostConfigPrimary):
      app.add(
        (n.replace("lcn.app_module", "lcn.rs_record").replace("lcn.app_", "lcn.rs_"), b)
      )
    rs = rules(storePrimary)
    for name in [
      "lcn.rs_record", "lcn.rs_path", "lcn.rs_implementation", "lcn.rs_artifact",
      "lcn.rs_requirement", "lcn.rs_permission",
    ]:
      checkpoint name
      var a, r: string
      for (n, b) in app:
        if n == name:
          a = normal(b)
      for (n, b) in rs:
        if n == name:
          r = normal(b)
      check a.len > 0
      check a == r
