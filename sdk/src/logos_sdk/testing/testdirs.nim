## Where the SDK's test data lives [IMPL]. The fixtures and their generated files belong to the
## package, so their directories are absolute, under this file's own directory, in a checkout and in
## an installed package alike (DECISIONS G435). The others belong to the SDK's repository and are
## paths from its root, the working directory of every suite; `absolutePath` makes one absolute
## for a lookup that must not depend on the working directory. Move a directory by changing its
## value here.

import std/os

const
  sdkTestingDir* = currentSourcePath().parentDir
    ## `logos_sdk/testing/`, wherever the package is
  fixtureDir* = sdkTestingDir / "fixtures"
    ## fixture sources and contracts that core's suites and module repositories also use
  generatedDir* = sdkTestingDir / "generated"
    ## the generated kits, headers and export lists of those fixtures
  sdkKitDir* = "sdk/tests/kit" ## fixture sources only the SDK's suites use
  sdkGeneratedDir* = "sdk/tests/generated" ## generated files only the SDK's suites use
  vectorDir* = "sdk/tests/vectors" ## the SDK's test vectors
