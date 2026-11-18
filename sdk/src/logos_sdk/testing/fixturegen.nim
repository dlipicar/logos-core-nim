## How a committed lcn-gen test output is described and made [IMPL]: the machinery `genfixtures`
## (the SDK's fixtures) and `genfixtures_core` (core's) share. The C headers are there for the
## kit's C harness (typed_harness.c), which the kit tests compile.

import std/[os, sequtils, strutils]
import results
import logos_sdk/iface/[accept, cmap]
import logos_sdk/codegen/[callsgen, hostgen, kitgen, nimgen, sdkroot]
import ./testdirs

export testdirs

proc generatedHome(file: string): string =
  ## The directory a generated file of the SDK's belongs to.
  if file.startsWith("demo") or file.startsWith("metrics_provider") or
      file.startsWith("quiet_module") or file.startsWith("recursive_types"):
    sdkGeneratedDir
  else:
    generatedDir

proc homeOf*(home, file: string): string =
  ## `home` when the fixture names one, else where the SDK keeps `file`.
  if home.len > 0:
    home
  else:
    generatedHome(file)

const fixturePrefix* = SdkImportRoot

type NimFixture* = object
  module*: string ## the file's name
  home*: string ## its directory; none: the SDK's (`homeOf`)
  primary*: string
  interfaces*, supporting*: seq[string]
  system*: bool
  kit*: bool ## the module kit (`kitgen`) rather than the types
  calls*: bool ## the typed call helpers (`callsgen`) rather than the types
  configuration*: string ## the kit's configuration schema (DECISIONS I87)
  configurationRoot*: string
  live*: bool ## the kit declares live reconfiguration
  configurationTypes*: bool
    ## the kit's configuration types (`configurationTypesModule`) rather than
    ## the kit

proc fixtureSet*(f: NimFixture): Result[(ContractSet, KitOptions), string] =
  try:
    let set = ?acceptContractSet(
      readFile(f.primary),
      f.interfaces.mapIt(readFile(it)),
      f.supporting.mapIt(readFile(it)),
      AcceptOptions(system: f.system),
    )
    var opts = KitOptions(importPrefix: fixturePrefix)
    if f.configuration.len > 0:
      let cfgSet = ?configurationSet(readFile(f.configuration))
      opts.configuration =
        Opt.some(KitConfiguration(set: cfgSet, root: f.configurationRoot, live: f.live))
    ok((set, opts))
  except IOError as e:
    err(e.msg)

proc generated*(f: NimFixture): Result[string, string] =
  ## The module lcn-gen makes for `f` now.
  let (set, opts) = ?fixtureSet(f)
  if f.configurationTypes:
    configurationTypesModule(set, opts.configuration.get, opts)
  elif f.kit:
    kitModule(set, opts, f.system)
  elif f.calls:
    callsModule(set, CallsOptions(importPrefix: fixturePrefix), f.system)
  else:
    nimModule(set, NimOptions(importPrefix: fixturePrefix), f.system)

type HeaderFixture* = object
  header*: string ## the file's name
  home*: string ## its directory; none: the SDK's (`homeOf`)
  primary*: string ## none: `logos_types.h`
  interfaces*, supporting*: seq[string]
  calls*: bool ## the call helpers' header (`callsHeader`)
  runtime*: bool ## `logos_runtime.h` (RUNTIME §13)

proc generated*(f: HeaderFixture): Result[string, string] =
  ## The header lcn-gen makes for `f` now.
  if f.runtime:
    return ok(logosRuntimeHeader())
  if f.primary.len == 0:
    return ok(logosTypesHeader())
  try:
    let set = ?acceptContractSet(
      readFile(f.primary),
      f.interfaces.mapIt(readFile(it)),
      f.supporting.mapIt(readFile(it)),
      AcceptOptions(),
    )
    if f.calls:
      callsHeader(set.cSchemaSet)
    else:
      contractHeader(set.cSchemaSet)
  except IOError as e:
    err(e.msg)

proc fixturePath*(f: HeaderFixture): string =
  homeOf(f.home, f.header) / f.header

proc fixturePath*(f: NimFixture): string =
  homeOf(f.home, f.module) / f.module
