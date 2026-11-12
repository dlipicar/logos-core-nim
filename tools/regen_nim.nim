## Rewrites the committed lcn-gen outputs: `nimble regen`.

import results
import ../tests/support/genfixtures

proc main() =
  writeFile(commonTypesPath, generatedCommon().get)
  echo commonTypesPath
  writeFile(commonMirrorsPath, generatedCommonMirrors().get)
  echo commonMirrorsPath
  writeFile(rcTypesPath, generatedRcTypes().get)
  echo rcTypesPath
  writeFile(hostConfigTypesPath, generatedHostConfigTypes().get)
  echo hostConfigTypesPath
  writeFile(storeTypesPath, generatedStoreTypes().get)
  echo storeTypesPath
  writeFile(caTypesPath, generatedCaTypes().get)
  echo caTypesPath
  writeFile(caKitPath, generatedCaKit().get)
  echo caKitPath
  writeFile(policyTypesPath, generatedPolicyTypes().get)
  echo policyTypesPath
  writeFile(stateTypesPath, generatedStateTypes().get)
  echo stateTypesPath
  for f in nimFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath
  for f in headerFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath

main()
