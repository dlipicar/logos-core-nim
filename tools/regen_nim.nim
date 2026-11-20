## Rewrites the committed lcn-gen outputs: `nimble regen`.

import results
import logos_sdk/codegen/kitgen
import ../sdk/tests/support/genfixtures, ../tests/support/genfixtures_core

proc main() =
  writeFile(commonTypesPath, generatedCommon().get)
  echo commonTypesPath
  writeFile(commonMirrorsPath, generatedCommonMirrors().get)
  echo commonMirrorsPath
  writeFile(rcTypesPath, generatedRcTypes().get)
  echo rcTypesPath
  writeFile(hostConfigTypesPath, generatedHostConfigTypes().get)
  echo hostConfigTypesPath
  writeFile(daemonConfigTypesPath, generatedDaemonConfigTypes().get)
  echo daemonConfigTypesPath
  writeFile(trustTypesPath, generatedTrustTypes().get)
  echo trustTypesPath
  writeFile(evstoreTypesPath, generatedEvstoreTypes().get)
  echo evstoreTypesPath
  writeFile(ctlTypesPath, generatedCtlTypes().get)
  echo ctlTypesPath
  writeFile(logosctlTypesPath, generatedLogosctlTypes().get)
  echo logosctlTypesPath
  writeFile(logosctlKitPath, generatedLogosctlKit().get)
  echo logosctlKitPath
  writeFile(cliTypesPath, generatedCliTypes().get)
  echo cliTypesPath
  writeFile(lcnCallTypesPath, generatedLcnCallTypes().get)
  echo lcnCallTypesPath
  writeFile(lcnCallConfigTypesPath, generatedLcnCallConfigTypes().get)
  echo lcnCallConfigTypesPath
  writeFile(lcnCallKitPath, generatedLcnCallKit().get)
  echo lcnCallKitPath
  for kind in ExportListKind:
    writeFile(lcnCallExportsPath(kind), generatedLcnCallExports(kind).get)
    echo lcnCallExportsPath(kind)
  writeFile(storeTypesPath, generatedStoreTypes().get)
  echo storeTypesPath
  writeFile(carrierTypesPath, generatedCarrierTypes().get)
  echo carrierTypesPath
  writeFile(caTypesPath, generatedCaTypes().get)
  echo caTypesPath
  writeFile(caKitPath, generatedCaKit().get)
  echo caKitPath
  writeFile(ldrTypesPath, generatedLdrTypes().get)
  echo ldrTypesPath
  writeFile(ldrKitPath, generatedLdrKit().get)
  echo ldrKitPath
  writeFile(policyTypesPath, generatedPolicyTypes().get)
  echo policyTypesPath
  writeFile(stateTypesPath, generatedStateTypes().get)
  echo stateTypesPath
  writeFile(orchTypesPath, generatedOrchTypes().get)
  echo orchTypesPath
  writeFile(orchConfigTypesPath, generatedOrchConfigTypes().get)
  echo orchConfigTypesPath
  writeFile(orchKitPath, generatedOrchKit().get)
  echo orchKitPath
  writeFile(orchStateTypesPath, generatedOrchStateTypes().get)
  echo orchStateTypesPath
  for f in nimFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath
  for f in coreNimFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath
  for f in headerFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath
  for f in coreHeaderFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath
  for f in exportFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath
  writeFile(storageFetchRootPath, generatedStorageFetchRoot().get)
  echo storageFetchRootPath

main()
