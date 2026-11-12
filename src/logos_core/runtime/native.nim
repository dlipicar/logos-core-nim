## RUNTIME §1.2, §2.2-§2.4, §13.3; LOADER §6: native module implementation
## bindings.
##
## A binding is the module code one realization strategy supplies: a protected
## static registration (a symbol table the host registers before startup,
## §13.3) or a verified dynamic library (`artifact.nim`). `bindNative` resolves
## its symbols for an expected module name, calls `_MODULE_name()` and, for a
## provider, `_MODULE_call_surface()`, validates the descriptor and requires
## every schema-derived per-method function, then probes the optional
## `_MODULE_async_api`. It creates no module instance (§2.2).
##
## [IMPL] Whether provider symbols apply is read from the code: all three of
## `_MODULE_call_surface`, `_MODULE_free` and `_MODULE_dispatch`, or none of
## them. The Runtime then compares the validated surface with the contracts the
## resolved record expects (§1.2, §3.3), so a record that declares a provider
## contract never accepts code without one.

{.push raises: [].}

import std/[dynlib, sets, strutils, tables]
import results
import ../abi/[checks, types]
import ../cbor/utf8
import ../iface/[accept, cmap, names, provider]

export results

const
  MaxBindingIdBytes* = 128 ## [SPEC LOADER §3] `static_binding.binding`
  ModuleSymbolSuffixes* = [
    "name", "init", "apply_configuration", "destroy", "call_surface", "free",
    "dispatch", "async_api",
  ] ## [SPEC INTERFACE §2.6, §2.9] `logos_<module-C>_MODULE_<suffix>`
  RequiredSuffixes* = ["name", "init", "destroy"]
    ## [SPEC INTERFACE §2.6] every native module's identity and lifecycle symbols
  ProviderSuffixes* = ["call_surface", "free", "dispatch"]
    ## [SPEC INTERFACE §2.6] a provider's symbols

type
  SymbolKind* = enum
    symModule ## `logos_<module-C>_MODULE_<suffix>`
    symCall ## `logos_<module-C>_CALL_<namespace-C>_<Method>`

  ParsedSymbol* = object
    moduleC*: string ## the `<module-C>` component
    module*: string ## the runtime module name it projects
    kind*: SymbolKind
    suffix*: string ## a `ModuleSymbolSuffixes` member, or the call component

  StaticRegistration* = object
    ## [SPEC RUNTIME §13.3] One host-registered symbol table, copied.
    binding*: string ## the deployment-local `static_binding.binding`
    module*: string ## the one module whose symbol family the table holds
    symbols*: Table[string, pointer]
    system*: bool
      ## [SPEC INTERFACE §1.3; BCP §5] [IMPL] A Logos-defined system module
      ## linked into this host (the Capability Authority): its call surface
      ## may use the reserved `logos` names. Set only by this repository's
      ## system providers (`caStaticRegistration`), never by
      ## `checkStaticRegistration`.

  CodeKind* = enum
    codeStatic
    codeDynamic

  ModuleCode* = object ## Where `bindNative` looks symbols up.
    case kind*: CodeKind
    of codeStatic:
      table*: Table[string, pointer]
    of codeDynamic:
      library*: LibHandle

  NativeProbe* = object
    ## What binding read from module code, as plain values (`probeNative`).
    module*: string
    moduleC*: string
    name*: ModuleNameFn
    init*: ModuleInitFn
    destroy*: ModuleDestroyFn
    applyConfiguration*: ModuleApplyConfigurationFn
    provider*: bool
    free*: ModuleFreeFn
    dispatch*: ModuleDispatchFn
    callSurface*: seq[byte]
    asyncExported*: bool
    asyncApi*: ptr LogosAsyncProviderApi

  NativeBinding* = object
    ## [SPEC RUNTIME §2.2] One accepted implementation binding: resolved once,
    ## shared by every instance initialized from it, never unloaded.
    module*: string
    moduleC*: string
    name*: ModuleNameFn
    init*: ModuleInitFn
    destroy*: ModuleDestroyFn
    applyConfiguration*: ModuleApplyConfigurationFn ## nil when not exported
    provider*: bool
    callSurface*: seq[byte] ## the exact `_MODULE_call_surface()` bytes
    contracts*: ModuleBinding ## the validated surface (a provider only)
    declaresEvents*: bool ## an exposed contract declares an event
    free*: ModuleFreeFn
    dispatch*: ModuleDispatchFn
    asyncApi*: ptr LogosAsyncProviderApi ## nil: the synchronous provider ABI
    calls*: Table[string, pointer]
      ## the schema-derived per-method functions (§2.4), by symbol name

func symbolName*(moduleC, suffix: string): string =
  "logos_" & moduleC & "_MODULE_" & suffix

func parseSymbol*(name: string): Result[ParsedSymbol, string] =
  ## [SPEC INTERFACE §2.1, §2.4, §2.6; RUNTIME §13.3] A canonical module ABI
  ## symbol name. `<module-C>` holds no capital letter except the `U` of `_U`,
  ## so the first `_MODULE_` or `_CALL_` ends it.
  const prefix = "logos_"
  if not name.startsWith(prefix):
    return err("symbol " & name & " does not begin with logos_")
  let m = name.find("_MODULE_", prefix.len)
  let c = name.find("_CALL_", prefix.len)
  var cut, rest: int
  var kind: SymbolKind
  if m >= 0 and (c < 0 or m < c):
    (cut, rest, kind) = (m, m + "_MODULE_".len, symModule)
  elif c >= 0:
    (cut, rest, kind) = (c, c + "_CALL_".len, symCall)
  else:
    return err("symbol " & name & " is neither a _MODULE_ nor a _CALL_ symbol")
  let moduleC = name[prefix.len ..< cut]
  let module = decodeModule(moduleC).valueOr:
    return err("symbol " & name & ": " & error)
  let suffix = name[rest .. ^1]
  case kind
  of symModule:
    if suffix notin ModuleSymbolSuffixes:
      return err("symbol " & name & " names no module ABI symbol")
  of symCall:
    if suffix.len == 0 or not suffix[0].isLowerAscii or
        not suffix.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}) or
        "_" notin suffix:
      return err("symbol " & name & " has no <namespace>_<Method> component")
  ok(ParsedSymbol(moduleC: moduleC, module: module, kind: kind, suffix: suffix))

func checkStaticRegistration*(
    binding: string, entries: openArray[(string, pointer)]
): Result[StaticRegistration, string] =
  ## [SPEC RUNTIME §13.3] The supplied table's own properties, checked without
  ## invoking module code: a binding identifier of 1 to 128 UTF-8 bytes, a
  ## non-empty table, unique canonical names, non-null addresses, one module
  ## symbol family, and the unconditional symbols. Duplicate binding
  ## identifiers are the registry's check. What depends on the call surface is
  ## checked by `bindNative`.
  if binding.len == 0 or binding.len > MaxBindingIdBytes:
    return err("the binding identifier must have 1 to 128 bytes")
  if not isValidUtf8(binding):
    return err("the binding identifier is not UTF-8")
  if entries.len == 0:
    return err("the symbol table is empty")
  var reg = StaticRegistration(binding: binding)
  var family = ""
  for (name, address) in entries:
    if address == nil:
      return err("symbol " & name & " has a null address")
    if name in reg.symbols:
      return err("symbol " & name & " appears twice")
    let p = ?parseSymbol(name)
    if family.len == 0:
      family = p.moduleC
      reg.module = p.module
    elif p.moduleC != family:
      return err(
        "the table holds symbols of two modules (" & family & ", " & p.moduleC &
          "): an ambiguous module symbol family"
      )
    reg.symbols[name] = address
  for s in RequiredSuffixes:
    if symbolName(family, s) notin reg.symbols:
      return err("the table lacks " & symbolName(family, s))
  ok(reg)

func exposed*(b: NativeBinding): seq[Contract] =
  ## The contracts a provider exposes: its primary, then its interfaces.
  if b.contracts.primary.isSome:
    result.add(b.contracts.primary.get)
  result.add(b.contracts.interfaces)

proc find*(code: ModuleCode, name: string): pointer =
  case code.kind
  of codeStatic:
    code.table.getOrDefault(name)
  of codeDynamic:
    code.library.symAddr(cstring(name))

proc probeNative*(code: ModuleCode, module: string): Result[NativeProbe, string] =
  ## [SPEC RUNTIME §2.2, §2.4; LOADER §6 steps 1-3] The part of binding that
  ## runs module code: resolves the identity, lifecycle and provider symbols
  ## and calls `_MODULE_name()`, then for a provider `_MODULE_call_surface()`
  ## and `_MODULE_async_api()`. The result holds plain values only, so a
  ## worker thread can hand it to the thread that validates it.
  let moduleC = projectModule(module)
  var p = NativeProbe(module: module, moduleC: moduleC)
  template sym(suffix: string): pointer =
    code.find(symbolName(moduleC, suffix))

  for s in RequiredSuffixes:
    if sym(s) == nil:
      return err("the code lacks " & symbolName(moduleC, s))
  p.name = cast[ModuleNameFn](sym("name"))
  p.init = cast[ModuleInitFn](sym("init"))
  p.destroy = cast[ModuleDestroyFn](sym("destroy"))
  p.applyConfiguration = cast[ModuleApplyConfigurationFn](sym("apply_configuration"))
  var present = 0
  for s in ProviderSuffixes:
    if sym(s) != nil:
      inc present
  if present notin [0, ProviderSuffixes.len]:
    return err(
      "the code exports some but not all of _MODULE_call_surface, _MODULE_free and _MODULE_dispatch"
    )
  p.provider = present == ProviderSuffixes.len
  # [SPEC RUNTIME §2.2] `_MODULE_name()` before any other module call.
  let reported = p.name()
  if reported == nil:
    return err("_MODULE_name() returned null")
  if $reported != module:
    return err("_MODULE_name() does not return the expected module name")
  if not p.provider:
    return ok(p)
  p.free = cast[ModuleFreeFn](sym("free"))
  p.dispatch = cast[ModuleDispatchFn](sym("dispatch"))
  # [SPEC RUNTIME §2.4] The complete descriptor, copied before init.
  var len: csize_t = 0
  let d = cast[ModuleCallSurfaceFn](sym("call_surface"))(addr len)
  if d == nil or len == 0:
    return err("_MODULE_call_surface() returned no descriptor")
  if len > csize_t(MaxDescriptorBytes):
    return err("the call-surface descriptor is larger than 8,388,608 bytes")
  p.callSurface = @(cast[ptr UncheckedArray[uint8]](d).toOpenArray(0, int(len) - 1))
  # [SPEC RUNTIME §2.2, §2.3; INTERFACE §2.9.2] The optional async descriptor.
  let asyncSym = sym("async_api")
  if asyncSym != nil:
    p.asyncExported = true
    p.asyncApi = cast[ModuleAsyncApiFn](asyncSym)()
  ok(p)

proc completeNative*(
    code: ModuleCode, p: NativeProbe, opts = AcceptOptions()
): Result[NativeBinding, string] =
  ## [SPEC RUNTIME §2.2, §2.4; INTERFACE §2.6] The part of binding that runs
  ## no module code: validates the descriptor `p` copied and resolves every
  ## per-method function it requires.
  var b = NativeBinding(
    module: p.module,
    moduleC: p.moduleC,
    name: p.name,
    init: p.init,
    destroy: p.destroy,
    applyConfiguration: p.applyConfiguration,
    provider: p.provider,
  )
  var staticCalls = initHashSet[string]()
  if code.kind == codeStatic:
    for name in code.table.keys:
      if parseSymbol(name).get.kind == symCall:
        staticCalls.incl(name)
  if not b.provider:
    if staticCalls.len > 0:
      return err("per-method functions without the provider symbols")
    return ok(b)
  b.free = p.free
  b.dispatch = p.dispatch
  b.callSurface = p.callSurface
  b.contracts = acceptCallSurfaceDescriptor(b.callSurface, b.module, opts).valueOr:
    return err("invalid call surface: " & error)
  if not b.contracts.isProvider:
    return err("the call surface exposes no provider contract")
  for c in b.exposed:
    if c.model.events.len > 0:
      b.declaresEvents = true
  # [SPEC RUNTIME §1.2; INTERFACE §2.4, §2.6] Every per-method function.
  let layout = cLayout(cSchemaSet(b.contracts)).valueOr:
    return err("the call surface has no C mapping: " & error)
  for call in layout.calls:
    let f = code.find(call.symbol)
    if f == nil:
      return err("the code lacks " & call.symbol)
    b.calls[call.symbol] = f
  for name in staticCalls:
    if name notin b.calls:
      return err("the table holds " & name & ", which the call surface does not define")
  if p.asyncExported:
    checkAsyncProviderApi(p.asyncApi).isOkOr:
      return
        err("invalid _MODULE_async_api() descriptor: " & error.message.get($error.code))
    b.asyncApi = p.asyncApi
  ok(b)

proc bindNative*(
    code: ModuleCode, module: string, opts = AcceptOptions()
): Result[NativeBinding, string] =
  ## [SPEC RUNTIME §2.2, §2.4; LOADER §6 steps 1-3] Both binding phases on the
  ## calling thread. Calls `_MODULE_name()`, `_MODULE_call_surface()` and
  ## `_MODULE_async_api()` (module code) but not `_MODULE_init()`. Every error
  ## is the Loader's `abi-invalid`.
  completeNative(code, ?probeNative(code, module), opts)
