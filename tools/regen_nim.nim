## Rewrites the committed lcn-gen outputs: `nimble regen`.

import results
import ../tests/support/genfixtures

proc main() =
  writeFile(commonTypesPath, generatedCommon().get)
  echo commonTypesPath
  writeFile(commonMirrorsPath, generatedCommonMirrors().get)
  echo commonMirrorsPath
  for f in nimFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath
  for f in headerFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath

main()
