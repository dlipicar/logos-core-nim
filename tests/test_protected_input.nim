## The protected realization input (Tier 5 step 5-3b-2; DECISIONS G400; docs/HOST-CONFIG.md,
## `protected_inputs` and "The Module Loader"): an engine whose configuration carries an
## instance's bytes, the Module Loader writing them to `<state_dir>/.lcn-protected-input` before
## each realization attempt's `_MODULE_init` and removing them after, with the probe module
## (`tests/kit/probe_impl.nim`, command `protected`) recording what the file holds while it
## initializes, `direct_dynamic` and `hosted_dynamic`.
##
## Every case leaves no Module Host of this build behind.

when defined(posix):
  import std/[atomics, monotimes, os, sequtils, strutils, tables, times, typedthreads]
  import unittest2
  import ../src/logos_core/runtime/engine
  import ../src/logos_core/runtime/[host_config, host_config_types]
  import logos_sdk/abi/[checks, types]
  import logos_sdk/cbor
  import logos_sdk/crypto/blake3
  import logos_sdk/iface/outcome
  import logos_sdk/codegen/common_types
  import logos_sdk/pins
  from logos_sdk/abi/host import AppConfigFormat
  import ./support/[modulehostbuild, shortdir], logos_sdk/testing/[kitbuild, kitruntime]
  import logos_sdk/testing/fixtures/meter_impl
  import logos_sdk/testing/generated/meter_module_calls
  from ../src/logos_core/runtime/hostsup import traceMarkers, traced
  from ../src/logos_core/runtime/protinput import
    ProtectedInputName, writeProtectedInput, readProtectedInput
  from ../src/logos_core/runtime/statexfer import copyTree

  let
    repo = currentSourcePath().parentDir.parentDir
    work = repo / "build" / "protected-input" / kitVariant
  removeDir(work)
  createDir(work)

  include ./support/routefixture

  proc target(e: Engine, id: string): LogosNSRuntimeModuleInstanceAddress =
    LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: e.runtimeInstanceId(), module_instance_id: id
    )

  let shortBase = makeShortBase("lcnpi", "/e999/12345678/logos_meter_module.sock")

  const
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    Marker = "lcn-protected-input-marker-7d41c09e"
      ## the bytes every case hands over: found in no frame, log line or diagnostic

  let
    hostProgram = moduleHostProgram()
    probeLib = buildKitLibrary("probe_impl.nim", "probe")

  proc digestOf(path: string): array[32, byte] =
    let bytes = readFile(path)
    blake3(bytes.toOpenArrayByte(0, bytes.high))

  let probeDigest = digestOf(probeLib)

  func bytesOf(s: string): seq[byte] =
    @(s.toOpenArrayByte(0, s.high))

  func hex(s: string): string =
    for c in s:
      result.add(toHex(ord(c), 2).toLowerAscii)

  proc probe(hosted: bool, state = "p"): ModuleRecord =
    ModuleRecord(
      module: "probe_module",
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: "process" else: ""),
      artifact: ArtifactRecord(
        id: "probe", localPath: probeLib, hash: probeDigest, hashSuite: HashSuiteId
      ),
      stateAssignment: Opt.some(state),
    )

  proc piConfig(hosted: bool, input = Opt.some(Marker)): EngineConfig =
    ## The fixture's configuration with a state root, the Module Host for `hosted`, and
    ## `input` as instance `pi`'s protected realization input.
    result = config()
    result.stateRoot = Opt.some(result.workDir / "state")
    result.endpointDir = shortBase / ("e" & $engines)
    if hosted:
      result.moduleHost = Opt.some(hostProgram)
      result.moduleHostEnv = @SanitizerEnv
    if input.isSome:
      result.protectedInputs = @[("pi", bytesOf(input.get))]

  proc prepare(cfg: EngineConfig, commands: varargs[string]): string =
    result = cfg.stateRoot.get / "p"
    createDir(result)
    writeFile(result / "probe.cmd", commands.join("\n") & "\n")

  proc lines(dir, file: string): seq[string] =
    try:
      readFile(dir / file).splitLines.filterIt(it.len > 0)
    except IOError:
      @[]

  proc reservedLeft(dir: string): seq[string] =
    ## The reserved name and its temporary names still in `dir`.
    for kind, path in walkDir(dir, relative = true):
      if path == ProtectedInputName or path.startsWith(ProtectedInputName & "."):
        result.add(path)

  proc noHostLeft(): bool =
    waitUntil(
      proc(): bool =
        hostPids(hostProgram).len == 0
    )

  proc failed(e: Engine, instance: string): string =
    let v = e.view(instance).tryGet
    if v.failure.isSome: v.failure.get.reason else: ""

  suite "the protected realization input (G400)":
    for hosted in [false, true]:
      let placement = (if hosted: "hosted" else: "direct")
      test "[IMPL-DECISION G400] " & placement &
        ": the module reads the bytes during _MODULE_init, and the file is gone after it":
        let cfg = piConfig(hosted)
        let dir = cfg.prepare("protected")
        if hosted:
          traceMarkers([bytesOf(Marker)])
        let e = fixtureEngine(cfg)
        discard e.started(probe(hosted), "pi")
        check lines(dir, "protected") == @["file " & hex(Marker)]
        check reservedLeft(dir).len == 0
        # Stopped and started again: a new attempt writes it again.
        check e.stop("pi").tryGet.state == msUnloaded
        check e.start("pi").tryGet.state == msReady
        check lines(dir, "protected") == @["file " & hex(Marker), "file " & hex(Marker)]
        check reservedLeft(dir).len == 0
        for d in e.diagnostics():
          check Marker notin d
        e.finish()
        if hosted:
          # No carrier frame held the bytes: the Loader writes the file before the host
          # starts, and the host never sends it.
          let (frames, hits) = traced()
          check frames > 0
          check hits == 0
          traceMarkers([])
          check noHostLeft()

    test "[IMPL-DECISION G400] an attempt without input removes a leftover first":
      let cfg = piConfig(false, input = Opt.none(string))
      let dir = cfg.prepare("protected")
      writeFile(dir / ProtectedInputName, "left by an earlier run")
      let e = fixtureEngine(cfg)
      discard e.started(probe(false), "pi")
      check lines(dir, "protected") == @["absent"]
      check reservedLeft(dir).len == 0
      e.finish()

    test "[IMPL-DECISION G400] a planted file is replaced by the configured bytes":
      let cfg = piConfig(false)
      let dir = cfg.prepare("protected")
      writeFile(dir / ProtectedInputName, "planted")
      let e = fixtureEngine(cfg)
      discard e.started(probe(false), "pi")
      check lines(dir, "protected") == @["file " & hex(Marker)]
      e.finish()

    test "[IMPL-DECISION G400] a link at the reserved name or at a temporary name is removed, never followed":
      let cfg = piConfig(false)
      let dir = cfg.prepare("protected")
      let target = work / "outside-target"
      writeFile(target, "outside")
      createSymlink(target, dir / ProtectedInputName)
      let temp = ProtectedInputName & "." & "0".repeat(32)
      createSymlink(target, dir / temp)
      let e = fixtureEngine(cfg)
      discard e.started(probe(false), "pi")
      check lines(dir, "protected") == @["file " & hex(Marker)]
      check readFile(target) == "outside"
      check reservedLeft(dir).len == 0
      e.finish()

    test "[IMPL-DECISION G400] a directory at the reserved name fails the realization":
      let cfg = piConfig(false)
      let dir = cfg.prepare("protected")
      createDir(dir / ProtectedInputName)
      let e = fixtureEngine(cfg)
      let v = e.create(probe(false), "pi").tryGet
      let s = e.start(v.instance)
      check s.isErr or s.get.state != msReady
      check "the protected realization input cannot be written" in e.failed("pi")
      check Marker notin e.failed("pi")
      check lines(dir, "inits").len == 0 # `_MODULE_init` never ran
      check dirExists(dir / ProtectedInputName)
      e.finish()

    test "[IMPL-DECISION G400] retirement removes a leftover file and keeps the directory":
      let cfg = piConfig(false)
      let dir = cfg.prepare("protected")
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient()
      discard e.started(probe(false), "pi")
      check e.stop("pi").tryGet.state == msUnloaded
      writeProtectedInput(dir, bytesOf("as if a removal had failed")).tryGet
      let v = e.view("pi").tryGet
      let r = rcCall(
        rc,
        "retire_module",
        encode(
          LogosNSRuntimeControlRetireModuleRequest(
            target: e.target("pi"), expected_execution_revision: v.execution.revision
          )
        ).tryGet,
      )
      check r.code == ecOk
      check reservedLeft(dir).len == 0
      check dirExists(dir)
      check fileExists(dir / "inits")
      e.finish()

    test "[IMPL-DECISION G400] create_module cannot carry it: an extra field is refused":
      let e = fixtureEngine(piConfig(false))
      let (_, rc) = e.startClient()
      var req = decodeCbor(
        encode(
          LogosNSRuntimeControlCreateModuleRequest(
            module: "probe_module", request_key: "k-1"
          )
        ).tryGet
      ).tryGet
      req.entries.add((cbor("protected_input"), cbor(bytesOf(Marker))))
      let r = rcCall(rc, "create_module", encodeCbor(req))
      check r.code == ecInvalidParams
      e.finish()

    test "[IMPL-DECISION G400] a state copy skips the reserved name and its temporary names":
      let src = work / "copy-src"
      removeDir(src)
      createDir(src)
      writeFile(src / "kept", "state")
      writeProtectedInput(src, bytesOf(Marker)).tryGet
      writeFile(src / (ProtectedInputName & "." & "a".repeat(32)), Marker)
      let dst = work / "copy-dst"
      removeDir(dst)
      discard copyTree(src, dst, 1 shl 20).tryGet
      check readFile(dst / "kept") == "state"
      check reservedLeft(dst).len == 0
      check readProtectedInput(src).tryGet.isSome # the source is not changed

    test "[IMPL-DECISION G400] the host configuration's protected_inputs: each refusal names the instance, never the bytes":
      proc module(instance: string, state = true): LcnAppModule =
        result = LcnAppModule(
          instance: instance,
          module: "probe_module",
          implementation: LcnAppImplementation(
            kind: LcnAppImplementationKind.Direct_static,
            arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: "probe"),
          ),
        )
        if state:
          result.state_assignment = Opt.some(instance)

      proc refusal(
          inputs: seq[LcnAppProtectedInput], modules: seq[LcnAppModule]
      ): string =
        let c = LcnAppConfig(
          runtime:
            LcnAppRuntime(work_dir: work / "hc-w", state_root: Opt.some(work / "hc-s")),
          policy: LcnAppPolicy(),
          orchestration: "a",
          modules: modules,
          protected_inputs: Opt.some(inputs),
        )
        let r = parseHostConfig(AppConfigFormat, encodeCbor(toCbor(c)))
        if r.isOk: "" else: r.error.message

      let input = LcnAppProtectedInput(instance: "a", input: bytesOf(Marker))
      check refusal(@[input], @[module("a")]) == ""
      check refusal(@[], @[module("a")]) == "protected_inputs is present but empty"
      check refusal(
        @[LcnAppProtectedInput(instance: "b", input: bytesOf(Marker))], @[module("a")]
      ) == "protected_inputs: b is not listed in modules"
      check refusal(@[input], @[module("a", state = false)]) ==
        "protected_inputs: a has no state_assignment"
      check refusal(@[input, input], @[module("a")]) ==
        "protected_inputs: a has two entries"
