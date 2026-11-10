## Rewrites the committed lcn-gen Nim outputs: `nimble regen`.

import results
import ../tests/support/genfixtures

proc main() =
  writeFile(commonTypesPath, generatedCommon().get)
  echo commonTypesPath
  for f in nimFixtures:
    writeFile(f.fixturePath, f.generated.get)
    echo f.fixturePath

main()
