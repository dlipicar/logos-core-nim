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
      file.startsWith("quiet_module") or file.startsWith("recursive_types") or
      file.startsWith("metrics_only_module") or file.startsWith("gauge_module") or
      file.startsWith("tally_module") or file.startsWith("idle_module"):
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
  primary*: string ## none: an interface-only binding (`binding`)
  interfaces*, supporting*: seq[string]
  binding*: string
    ## the runtime module name of an explicit module binding (INTERFACE §2):
    ## without `primary`, an interface-only one (DECISIONS G339)
  extends*: seq[string]
    ## the binding's earlier contracts, for its kit's descriptor (§2.6)
  system*: bool
  kit*: bool ## the module kit (`kitgen`) rather than the types
  calls*: bool ## the typed call helpers (`callsgen`) rather than the types
  configuration*: string ## the kit's configuration schema (DECISIONS I87)
  configurationRoot*: string
  live*: bool ## the kit declares live reconfiguration
  configurationTypes*: bool
    ## the kit's configuration types (`configurationTypesModule`) rather than
    ## the kit
  confined*: bool ## a thread-confined kit (DECISIONS G335)
  asyncApi*: bool ## that also exports `_MODULE_async_api` (DECISIONS G338)

proc kitOptionsOf(f: NimFixture): Result[KitOptions, string] =
  try:
    var opts = KitOptions(
      importPrefix: fixturePrefix, confined: f.confined, asyncApi: f.asyncApi
    )
    if f.configuration.len > 0:
      let cfgSet = ?configurationSet(readFile(f.configuration))
      opts.configuration =
        Opt.some(KitConfiguration(set: cfgSet, root: f.configurationRoot, live: f.live))
    ok(opts)
  except IOError as e:
    err(e.msg)

proc fixtureSet*(f: NimFixture): Result[(ContractSet, KitOptions), string] =
  ## The construction input set of a fixture with a primary document.
  if f.primary.len == 0:
    return err(f.module & " has no primary document")
  try:
    let set = ?acceptContractSet(
      readFile(f.primary),
      f.interfaces.mapIt(readFile(it)),
      f.supporting.mapIt(readFile(it)),
      AcceptOptions(system: f.system),
    )
    let opts = ?kitOptionsOf(f)
    ok((set, opts))
  except IOError as e:
    err(e.msg)

proc fixtureBinding*(f: NimFixture): Result[(ModuleBinding, KitOptions), string] =
  ## The module binding of `f`: its set's, or with `binding` or `extends` the
  ## explicit one (DECISIONS G339).
  if f.binding.len == 0 and f.extends.len == 0:
    let (set, opts) = ?fixtureSet(f)
    return ok((?set.binding, opts))
  let name =
    if f.binding.len > 0:
      f.binding
    else:
      (?(?fixtureSet(f))[0].binding).module
  try:
    let b = ?acceptBinding(
      name,
      if f.primary.len > 0:
        Opt.some(readFile(f.primary))
      else:
        Opt.none(string),
      f.interfaces.mapIt(readFile(it)),
      f.supporting.mapIt(readFile(it)),
      AcceptOptions(system: f.system),
      f.extends.mapIt(readFile(it)),
    )
    let opts = ?kitOptionsOf(f)
    ok((b, opts))
  except IOError as e:
    err(e.msg)

proc generated*(f: NimFixture): Result[string, string] =
  ## The module lcn-gen makes for `f` now.
  if f.configurationTypes:
    let (b, opts) = ?fixtureBinding(f)
    configurationTypesModule(b, opts.configuration.get, opts)
  elif f.kit:
    let (b, opts) = ?fixtureBinding(f)
    kitModule(b, opts, f.system)
  elif f.primary.len == 0:
    let (b, _) = ?fixtureBinding(f)
    nimModule(b, NimOptions(importPrefix: fixturePrefix), f.system)
  elif f.calls:
    let (set, _) = ?fixtureSet(f)
    callsModule(set, CallsOptions(importPrefix: fixturePrefix), f.system)
  else:
    let (set, _) = ?fixtureSet(f)
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
