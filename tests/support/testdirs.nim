## Where the SDK's test data lives, as paths from the repository root [IMPL]. Every suite runs from
## the root, so a lookup may use these as they are; `repoDir` makes them absolute for one that must
## not depend on the working directory. Move a directory by changing its value here.

import std/os

const
  repoDir* = currentSourcePath().parentDir.parentDir.parentDir
  fixtureDir* = "tests/kit" ## fixture sources and contracts that core's suites also use
  generatedDir* = "tests/generated"
    ## the generated kits, headers and export lists of those fixtures
  sdkKitDir* = "tests/kit" ## fixture sources only the SDK's suites use
  sdkGeneratedDir* = "tests/generated" ## generated files only the SDK's suites use
  vectorDir* = "tests/vectors" ## the SDK's test vectors
