## lcn-gen's module kit [IMPL]: `<module>_kit.nim` for a concrete module
## document, so that a native module written in Nim exports the INTERFACE §2.6
## identity, lifecycle and provider symbols (App A.3, A.4).
##
## The kit imports the module's `<module>_types.nim` (`nimgen`), embeds the
## binding's documents and its provider call-surface descriptor (§2.6), and
## declares:
##
## - `export<Module>(T)`: a template the author instantiates once, at top
##   level, with a `ref object` type `T`. It defines `_MODULE_name`,
##   `_MODULE_init`, `_MODULE_destroy` and, for a provider (§2.6),
##   `_MODULE_call_surface`, `_MODULE_free` and `_MODULE_dispatch`, all with C
##   linkage. They call, by overload resolution in the author's module,
##   `initModule(T, ModuleInit): Result[T, InvocationFailure]`, the optional
##   `destroyModule(T)`, and one handler per exposed method named by its bare
##   method name (dots become underscores):
##   `<bare>(T, <Request>): Result[<Response>, InvocationFailure]`.
## - `publish(ModuleServices, <Event>)` and `publishScoped(ModuleServices,
##   <Event>)` for each event the primary contract or an interface declares.
## - `<module>StaticSymbols()`, defined by the template: every symbol it
##   exports with its address, the table a host registers for static binding
##   (RUNTIME §2.3, §13.3).
## - For a provider, the typed per-method functions
##   `logos_<module-C>_CALL_<namespace>_<Method>` (§2.4). The template defines
##   them over the same handlers. Their C-layout mirrors and converters come
##   from `cmirror`, the common schema's from `codegen/common_mirrors`.
##
## With a configuration (`KitOptions.configuration`; CONFIG §2, §6, §8;
## DECISIONS I87) the kit also imports `<module>_configuration_types.nim`
## (`configurationTypesModule`), embeds the configuration document, its root
## and the commitment recomputed here, and `initModule` takes the checked
## value as a third argument of the root's Nim type:
## `initModule(T, ModuleInit, <Root>)`. A live-reconfigurable kit also exports
## `_MODULE_apply_configuration` over the author's
## `applyConfiguration(T, <Root>): Result[void, InvocationFailure]`.
##
## Not generated yet: `_MODULE_async_api` (optional), and kits for an
## interface-only provider (no primary document). A consumer's typed call
## helpers (App A.5) come from `callsgen`.

{.push raises: [].}

import std/[sequtils, strutils, tables]
import ../commitment
import ../hash
import ../pins
import ../iface/[accept, cmap, names, provider, surface]
import ./[cmirror, nimgen]

type
  KitConfiguration* = object
    ## [SPEC CONFIG §2] A module's configuration binding (DECISIONS I87).
    set*: ContractSet ## the document, accepted as its own supporting schema
    root*: string ## the configuration value's type
    live*: bool ## `live_reconfiguration`: export `_MODULE_apply_configuration`

  KitOptions* = object
    importPrefix*: string ## how the kit imports this library (`NimOptions`)
    configuration*: Opt[KitConfiguration]

proc configurationSet*(document: string): Result[ContractSet, string] =
  ## [SPEC CONFIG §2 l.62-66] A configuration document accepted as the Runtime
  ## accepts it: a supporting schema resolved against itself and the pinned
  ## common schema only.
  let set = acceptContractSet(document, [], [], AcceptOptions()).valueOr:
    return err("the configuration schema is not accepted: " & error)
  if set.primary.model.role != srSupporting:
    return err("the configuration schema is not a supporting schema")
  ok(set)

func configurationTypesName*(s: ContractSet): string =
  ## The configuration types module of the kit for the module set `s`.
  s.cSchemaSet.headerName & "_configuration_types"

proc configurationTypesModule*(
    s: ContractSet, c: KitConfiguration, opts = KitOptions(importPrefix: "logos_core/")
): Result[string, string] =
  ## `<module>_configuration_types.nim`: the configuration set's Nim types
  ## (`nimModule`), for the kit of the module set `s`.
  let text = ?nimModule(c.set, NimOptions(importPrefix: opts.importPrefix))
  let generic = c.set.cSchemaSet.headerName & "_types.nim:"
  let first = "## " & generic
  if not text.startsWith(first):
    return err("unexpected nimModule output")
  ok("## " & configurationTypesName(s) & ".nim:" & text[first.len .. ^1])

func pascalModule(name: string): string =
  for part in name.split('_'):
    if part.len > 0:
      result.add(part[0].toUpperAscii & part[1 ..^ 1])

func handlerName(bare: string): string =
  ## The author's handler for a bare method name, quoted (it may be a keyword).
  "`" & bare.replace(".", "_") & "`"

func byteArray(data: openArray[byte]): string =
  var s = "["
  for i, b in data:
    if i > 0:
      s.add(if i mod 16 == 0: ",\n  " else: ", ")
    s.add("0x" & toHex(b, 2) & (if i == 0: "'u8" else: ""))
  s & "]"

func templateName*(module: string): string =
  ## The kit's export template for a runtime module name.
  "export" & pascalModule(module)

proc kitModule*(
    s: ContractSet, opts = KitOptions(importPrefix: "logos_core/"), system = false
): Result[string, string] =
  ## The kit of the module binding `s` establishes, beside the
  ## `<header>_types.nim` that `nimModule` writes for the same set.
  let b = ?s.binding
  let header = s.cSchemaSet.headerName
  let names = nimTypeNames(s)
  let surface = callSurface(s)
  let provider = b.isProvider
  let moduleC = projectModule(b.module)
  let tmpl = templateName(b.module)
  let prefix = block:
    let p = pascalModule(b.module)
    p[0].toLowerAscii & p[1 ..^ 1]
  template sym(suffix: string): string =
    "logos_" & moduleC & "_MODULE_" & suffix

  let configured = opts.configuration.isSome
  var
    rootType, convert = ""
    roots: (Digest, Digest)
    live = false
  if configured:
    let c = opts.configuration.get
    live = c.live
    let model = c.set.primary.model
    let d = model.find(c.root)
    if d.isNone or d.get.kind != dkType:
      # [SPEC CONFIG §2 l.77]
      return err("the configuration root " & c.root & " is not a type of its schema")
    roots = (schemaRoot(model), declarationRoot(model, d.get))
    let configNames = nimTypeNames(c.set)
    rootType = configNames.getOrDefault(c.root)
    # [IMPL] The kit imports both type modules unqualified.
    var taken = initTable[string, string]()
    for q, n in names:
      taken[n.toLowerAscii.replace("_", "")] = q
    for q, n in configNames:
      let k = n.toLowerAscii.replace("_", "")
      if k in taken:
        return err(
          "the configuration type " & q & " and the module type " & taken.getOrDefault(
            k
          ) & " have one Nim name, " & n
        )
    convert =
      if d.get.body.isObject:
        "fromChecked(" & rootType & ", config)"
      else:
        "dec" & rootType & "(config)"

  var o = ""
  o.add(
    "## " & header & "_kit.nim: generated by lcn-gen. PROVISIONAL (spec " &
      SpecRevision[0 .. 7] & ").\n" & "## The module kit of `" & b.module &
      "` (INTERFACE §2.6, App A.3, A.4). Do not edit.\n##\n" & "## Instantiate `" & tmpl &
      "(T)` once, at top level, where these are defined\n" &
      "## for a `ref object` type `T` (each must be gcsafe and raise nothing; any of\n" &
      "## them may run on any thread, concurrently with the others, INTERFACE §2.8):\n##\n" &
    (
      if configured:
        "##   proc initModule(_: type T, init: ModuleInit, config: " & rootType &
          "): Result[T, InvocationFailure]\n"
      else:
        "##   proc initModule(_: type T, init: ModuleInit): Result[T, InvocationFailure]\n"
    ) & "##   proc destroyModule(m: T) # optional\n"
  )
  if live:
    o.add(
      "##   proc applyConfiguration(m: T, config: " & rootType &
        "): Result[void, InvocationFailure]\n" &
        "##     # [SPEC CONFIG §8 l.258-266] succeed only once the new value\n" &
        "##     # governs; on failure leave the previous value in force\n"
    )
  for m in surface.methods:
    o.add(
      "##   proc " & handlerName(m.bare) & "(m: T, request: " &
        names.getOrDefault(m.request) & "): Result[" & names.getOrDefault(m.response) &
        ", InvocationFailure]\n"
    )
  var mirrors = KitMirrors()
  if provider:
    var methods: seq[KitMethod]
    for m in surface.methods:
      methods.add(
        KitMethod(
          request: m.request,
          response: m.response,
          bare: m.bare,
          handler: handlerName(m.bare),
          requestType: names.getOrDefault(m.request),
        )
      )
    mirrors = ?kitMirrors(s, prefix, methods)
  if mirrors.exports.len > 0:
    o.add(
      "##\n## The template also exports the typed provider functions (INTERFACE §2.4),\n" &
        "## which call the same handlers.\n"
    )
  let typeModules =
    if configured:
      header & "_types, " & configurationTypesName(s)
    else:
      header & "_types"
  o.add(
    "\n#!fmt: off\n{.push raises: [], gcsafe.}\n\n" & "import " & opts.importPrefix &
      "codegen/[kitrt, common_mirrors]\nimport ./" &
      (if configured: "[" & typeModules & "]" else: typeModules) &
      "\n\nexport kitrt, common_mirrors, " & typeModules & "\n\n"
  )
  let descriptor =
    if provider:
      ?callSurfaceDescriptor(b)
    else:
      @[]
  o.add(
    "const\n  moduleName* = " & escape(b.module) & "\n  primaryDocument = " &
      escape(s.primary.source) & "\n  interfaceDocuments: array[" & $s.interfaces.len &
      ", string] = [" & s.interfaces.mapIt(escape(it.source)).join(", ") &
      "]\n  supportingDocuments: array[" & $s.supporting.len & ", string] = [" &
      s.supporting.mapIt(escape(it.source)).join(", ") & "]\n  declaresEvents = " &
      $(surface.events.len > 0) & "\n"
  )
  if provider:
    o.add(
      "  callSurfaceBytes: array[" & $descriptor.len & ", uint8] = " &
        byteArray(descriptor) & "\n\n" &
        "let callSurfaceData = callSurfaceBytes ## [SPEC INTERFACE §2.6] static bytes\n"
    )
  if configured:
    let c = opts.configuration.get
    o.add(
      "\nconst\n  configurationDocument = " & escape(c.set.primary.source) &
        "\n  configurationRoot* = " & escape(c.root) &
        " ## [SPEC CONFIG §2] the configuration value's type\n" &
        "  configurationRoots* = ConfigurationRoots(\n    schemaRoot: " &
        byteArray(roots[0]) & ",\n    subtreeRoot: " & byteArray(roots[1]) &
        ",\n  ) ## recomputed by lcn-gen from the document\n" &
        "  liveReconfiguration* = " & $live & "\n  noDocuments: array[0, string] = []\n" &
        "\nperThread(\n  kitConfigurationSchema,\n  GeneratedSchema,\n" &
        "  loadSchema(configurationDocument, noDocuments, noDocuments),\n)\n"
    )
  o.add(
    "\nperThread(\n  kitValidator,\n  ContractValidator,\n" &
      "  loadValidator(primaryDocument, interfaceDocuments, supportingDocuments, " &
      $system & "),\n)\n"
  )
  if "kitSchema()" in mirrors.procs:
    o.add(
      "\nperThread(\n  kitSchema,\n  GeneratedSchema,\n" &
        "  loadSchema(primaryDocument, interfaceDocuments, supportingDocuments, " &
        $system & "),\n)\n"
    )
  # Events (App A.4).
  for e in surface.events:
    let t = names.getOrDefault(e.id)
    o.add(
      "\nproc publish*(s: ModuleServices, event: " & t &
        "): Result[void, InvocationFailure] =\n" & "  ## Publishes `" & e.id &
        "` through the instance's publish callback.\n" &
        "  let data = encode(event).valueOr:\n" &
        "    return err(moduleError(\"the event does not match its schema: \" & error))\n" &
        "  s.publishEncoded(" & escape(e.id) & ", data)\n"
    )
    o.add(
      "\nproc publishScoped*(s: ModuleServices, event: " & t &
        "): Result[void, InvocationFailure] =\n" & "  ## Publishes `" & e.id &
        "` through the active provider entry (INTERFACE §2.9.3).\n" &
        "  let data = encode(event).valueOr:\n" &
        "    return err(moduleError(\"the event does not match its schema: \" & error))\n" &
        "  s.publishScopedEncoded(" & escape(e.id) & ", data)\n"
    )
  # The dispatch table (App A.3).
  if provider:
    o.add(
      "\nproc route" & pascalModule(b.module) &
        "[T](instance: T, bare: string, params: openArray[byte]): Result[seq[byte], InvocationFailure] =\n"
    )
    if surface.methods.len > 0:
      o.add("  mixin " & surface.methods.mapIt(handlerName(it.bare)).join(", ") & "\n")
    o.add("  let request = ?kitValidator().checkedRequest(bare, params)\n")
    for m in surface.methods:
      o.add(
        "  if bare == " & escape(m.bare) & ":\n" & "    let response = ?" &
          handlerName(m.bare) & "(instance, fromChecked(" & names.getOrDefault(
          m.request
        ) & ", request))\n" & "    return encodedResponse(encode(response))\n"
      )
    o.add(
      "  discard request\n  err(failure(ecMethodNotFound, \"unknown method \" & bare))\n"
    )
  # The typed provider functions (§2.4).
  if mirrors.types.len > 0:
    o.add("\n" & mirrors.types & "\n")
  if mirrors.procs.len > 0:
    o.add("\n" & mirrors.procs & "\n")
  if provider:
    o.add("\n" & mirrors.layout & "\n")
  # The export template.
  o.add(
    "\ntemplate " & tmpl & "*(T: typedesc) =\n" & "  ## Defines `" & b.module &
      "`'s exported symbols over the handlers of `T`.\n" & "  proc " & prefix &
      "KitCreate(init: ModuleInit): Result[pointer, InvocationFailure] {.nimcall, gcsafe, raises: [].} =\n" &
    (
      if configured:
        "    var init = init\n" &
          "    let config = ?kitConfiguration(init, configurationRoots, kitConfigurationSchema(), configurationRoot)\n" &
          "    let r = initModule(T, init, " & convert & ")\n"
      else:
        "    ?kitNoConfiguration(init)\n    let r = initModule(T, init)\n"
    ) & "    if r.isErr:\n      return err(r.error)\n" & "    let instance = r.get\n" &
      "    if instance.isNil:\n      return err(moduleError(\"initModule returned nil\"))\n" &
      "    GC_ref(instance)\n    ok(cast[pointer](instance))\n\n" & "  proc " & prefix &
      "KitDispose(p: pointer) {.nimcall, gcsafe, raises: [].} =\n" &
      "    let instance {.cursor.} = cast[T](p)\n" &
      "    when compiles(destroyModule(instance)):\n      destroyModule(instance)\n" &
      "    GC_unref(instance)\n\n" & "  proc " & prefix &
      "KitName(): cstring {.exportc: \"" & sym("name") &
      "\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
      "    system.cstring(moduleName)\n\n" & "  proc " & prefix &
      "KitInit(input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext): LogosResult {.exportc: \"" &
      sym("init") & "\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
      "    kitEnter()\n    kitInit(input, outContext, declaresEvents, " & prefix &
      "KitCreate)\n\n" & "  proc " & prefix &
      "KitDestroy(module: ptr LogosModuleContext) {.exportc: \"" & sym("destroy") &
      "\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
      "    kitEnter()\n    kitDestroy(module, " & prefix & "KitDispose)\n"
  )
  if live:
    o.add(
      "\n  proc " & prefix &
        "KitApply(p: pointer, input: openArray[byte]): Result[void, InvocationFailure] {.nimcall, gcsafe, raises: [].} =\n" &
        "    let instance {.cursor.} = cast[T](p)\n" &
        "    let (config, _) = ?checkConfigurationInput(input, configurationRoots, kitConfigurationSchema(), configurationRoot)\n" &
        "    applyConfiguration(instance, " & convert & ")\n\n" & "  proc " & prefix &
        "KitApplyConfiguration(module: ptr LogosModuleContext, configurationCbor: ptr UncheckedArray[uint8], configurationCborLen: csize_t): LogosResult {.exportc: \"" &
        sym("apply_configuration") & "\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
        "    kitEnter()\n    kitApply(module, configurationCbor, configurationCborLen, " &
        prefix & "KitApply)\n"
    )
  if provider:
    o.add(
      "\n  proc " & prefix &
        "KitRoute(p: pointer, bare: string, params: openArray[byte]): Result[seq[byte], InvocationFailure] {.nimcall, gcsafe, raises: [].} =\n" &
        "    let instance {.cursor.} = cast[T](p)\n" & "    route" &
        pascalModule(b.module) & "(instance, bare, params)\n\n" & "  proc " & prefix &
        "KitCallSurface(outLen: ptr csize_t): ptr uint8 {.exportc: \"" &
        sym("call_surface") & "\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
        "    if outLen != nil:\n      outLen[] = csize_t(callSurfaceData.len)\n" &
        "    addr callSurfaceData[0]\n\n" & "  proc " & prefix &
        "KitFree(module: ptr LogosModuleContext, p: pointer) {.exportc: \"" & sym(
        "free"
      ) & "\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
        "    kitEnter()\n    kitFree(module, p)\n\n" & "  proc " & prefix &
        "KitDispatch(module: ptr LogosModuleContext, methodName: cstring, paramsCbor: ptr UncheckedArray[uint8], paramsLen: csize_t, outResponseCbor: ptr ptr UncheckedArray[uint8], outResponseLen: ptr csize_t): LogosResult {.exportc: \"" &
        sym("dispatch") & "\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
        "    kitEnter()\n    kitDispatch(module, methodName, paramsCbor, paramsLen, outResponseCbor, outResponseLen, " &
        prefix & "KitRoute)\n"
    )
    for e in mirrors.exports:
      o.add("\n" & e & "\n")
  # [SPEC RUNTIME §2.3, §13.3] A generated registration table: every symbol the
  # template exports, for a host that binds the module statically.
  var table = @[
    (sym("name"), prefix & "KitName"),
    (sym("init"), prefix & "KitInit"),
    (sym("destroy"), prefix & "KitDestroy"),
  ]
  if live:
    table.add((sym("apply_configuration"), prefix & "KitApplyConfiguration"))
  if provider:
    table.add(
      [
        (sym("call_surface"), prefix & "KitCallSurface"),
        (sym("free"), prefix & "KitFree"),
        (sym("dispatch"), prefix & "KitDispatch"),
      ]
    )
    table.add(mirrors.symbols)
  o.add(
    "\n  proc " & prefix & "StaticSymbols*(): seq[(string, pointer)] =\n" &
      "    ## [SPEC RUNTIME §13.3] `" & b.module &
      "`'s symbol table for static registration.\n" & "    @[\n" &
      table.mapIt("      (\"" & it[0] & "\", cast[pointer](" & it[1] & ")),\n").join &
      "    ]\n"
  )
  ok(o)
