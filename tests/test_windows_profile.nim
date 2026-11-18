## TRANSPORT §8.2.1 l.1152 (TRN-0352) where `logos.local.unix-stream` is not
## supported: Windows, until step 5-9 (DECISIONS G107; step 5-4, I100). "An
## unsupported placement MUST fail without an unprotected fallback or isolation
## downgrade." Here, hosted placement is the Loader's (LOADER l.238-240), and it
## is all or nothing (l.255): on Windows the Module Loader a Runtime wires
## advertises no hosted placement, refuses every hosted request with
## `unsupported-strategy` before any artifact code is loaded (l.377-378), and
## the Runtime never realizes the module direct instead; the unix-stream entry
## points fail and leave nothing behind, and a local-transport rule is refused.
## Host configuration's refusal of `module_host` on Windows is `test_host`'s.
##
## The evidence runs on the Windows CI leg only (G334). Elsewhere the profile is
## supported and the suite compiles and skips; after 5-9 these cases move to the
## builds and placements that stay unsupported.

when defined(windows):
  import std/[os, sequtils, strutils, times]
  import unittest2
  import ../src/logos_core/runtime/engine
  import ../src/logos_core/runtime/hostsup
  import logos_sdk/crypto/blake3
  import ../src/logos_core/loader/logos_module_loader_types
  import logos_sdk/pins
  import ../src/logos_core/transport/io/[endpoint, sock]
  from ../src/logos_core/runtime/artifact import ArtifactRecord
  from ../src/logos_core/runtime/routing import RoutingRule, rmLocalTransport
  import logos_sdk/testing/kitbuild, ./support/loaderharness

  let work =
    currentSourcePath().parentDir.parentDir / "build" / "winprofile" / kitVariant
  removeDir(work)
  createDir(work)

  let markerLib = buildKitLibrary("load_marker.nim", "wpmarker")

  proc digestOfFile(path: string): array[32, byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    h.finish()

  proc hosted(placement: string): ModuleRecord =
    ## The marker library (its load-time code writes `LCN_LOAD_MARKER`) as a
    ## `hosted_dynamic` record with its true digest.
    ModuleRecord(
      module: "marker_module",
      strategy: stHostedDynamic,
      placement: placement,
      artifact: ArtifactRecord(
        id: "marker",
        localPath: markerLib,
        hash: digestOfFile(markerLib),
        hashSuite: HashSuiteId,
      ),
    )

  proc filesUnder(dir: string): seq[string] =
    for f in walkDirRec(dir):
      result.add(f)

  suite "trn.windows: an unsupported placement fails closed (TRANSPORT §8.2.1 l.1152; G107)":
    test "[TRN-0352] [LDR-0033] the Module Loader is wired without a hosted placement: no Module Host supervisor exists on Windows, so it advertises the direct strategies only":
      # The engine wires the Loader with `hosted` exactly when it holds a
      # Module Host supervisor (`engine.nim`, `hosts != nil`); on Windows the
      # supervisor is a stand-in that never exists.
      check newSupervisor(getAppFilename(), []).isNil
      var h = openHarness(@[], work / "harness", hosted = false).expect("the Loader")
      defer:
        h.close()
      let c = h.at.typed(
        "list_capabilities",
        LogosNSModuleLoaderListCapabilitiesRequest(),
        LogosNSModuleLoaderListCapabilitiesResponse,
      ).get.capabilities
      check c.direct_static == Opt.some(true) and c.direct_dynamic == Opt.some(true)
      check c.hosted_dynamic.isNone and c.force_release.isNone

    test "[TRN-0352] a hosted request, with a Module Host program configured in code, is refused unsupported-strategy before any artifact code is loaded, and the module is never realized direct instead":
      let marker = work / "marker"
      removeFile(marker)
      putEnv("LCN_LOAD_MARKER", marker)
      defer:
        delEnv("LCN_LOAD_MARKER")
      var cfg = defaultConfig(work / "engine")
      cfg.moduleHost = Opt.some(getAppFilename())
      let e = newEngine(cfg)
      defer:
        e.shutdown()
        check e.close(initDuration(seconds = 30))
      for placement in ["process", "sandbox", "container"]:
        let id = "h-" & placement
        check e.create(hosted(placement), id).isOk
        let s = e.start(id)
        check s.isOk
        if s.isOk:
          check s.get.state != msReady
          check s.get.failure.isSome
          if s.get.failure.isSome:
            check s.get.failure.get.classification == "loader-unsupported-strategy"
        let realized =
          e.loaderJournalForTests().filterIt(it.meth == "realize" and it.instance == id)
        check realized.len >= 1
        check realized.allIt(it.strategy == "hosted_dynamic")
      # No artifact code ran, and no copy of the artifact was staged.
      check not fileExists(marker)
      check filesUnder(cfg.workDir).filterIt(it.toLowerAscii.endsWith(".dll")).len == 0

    test "[TRN-0352] the unix-stream entry points fail and leave nothing behind; a local-transport rule is refused":
      let base = work / "endpoints"
      createDir(base)
      check not unixStream
      let checked = checkEndpointBase(base)
      check checked.isErr and checked.error.kind == eeUnsupported
      let made = makeEndpointDir(base)
      check made.isErr and made.error.kind == eeUnsupported
      check filesUnder(base).len == 0
      check toSeq(walkDirs(base / "*")).len == 0
      var cfg = defaultConfig(work / "routed")
      cfg.endpointDir = base
      cfg.routing = @[RoutingRule(callee: "meter_module", mode: rmLocalTransport)]
      let opened = openEngine(cfg)
      check opened.isErr
      if opened.isErr:
        check opened.error.code == ecInvalidParams
        check "not supported on this platform" in opened.error.message
      check filesUnder(base).len == 0
else:
  import unittest2

  suite "trn.windows: an unsupported placement fails closed (TRANSPORT §8.2.1 l.1152; G107)":
    test "[IMPL] unix-stream is supported on this platform: the Windows cases do not apply":
      skip()
