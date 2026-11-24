## The Module Loader's `hosted_dynamic` driver (Tier 4b step 4b-3; DECISIONS
## G264, G268; plan §2.5): what the kit handlers (`provider.nim`) run, on the
## calling thread, where a direct realization would run module code. The
## handler that would call `_MODULE_init` sends lane-0 `init` instead and
## waits on the host's lane-0 mailbox; nothing here runs module code.
##
## - **Start** (`startHosted`): stage the artifact (the verified read-only
##   private copy, LOADER l.212-214), spawn the host through the Runtime's
##   supervision (`hostsup.spawn`), send `init` and wait for `initialized`,
##   `init_failed` or the end of the host. On failure the host is ended and
##   reaped before the error returns, and nothing is retained (l.418-421).
## - **Release** (`releaseHosted`): `release`, then the confirmed end
##   (LDR-0117, LDR-0138; l.590). The host owns the context and destroys it
##   exactly once (LDR-0119).
## - **Apply** (`applyHosted`): `apply` and the hook's status; the host's end
##   while it is outstanding is an indeterminate outcome (L l.497-499).
## - **Ends** (`hostEnded`, `endHosts`): a record whose host ended by itself is
##   `failed` (L l.497-499); the Loader's thread ends and drops every host it
##   still holds when it stops (`closeCore` after a loss, RUNTIME l.3821).

{.push raises: [], gcsafe.}

import results
import logos_sdk/abi/checks
import logos_sdk/iface/outcome
import ../runtime/[hostsup, realizer, sidetable]
import ./core

type HostedOutcome* = object
  outcome*: Result[HostedInit, LoaderError]
  phase*: FailedPhase ## `fpInit`: the failure came from `_MODULE_init`

func failedWith(e: LoaderError, phase = fpNone): HostedOutcome =
  HostedOutcome(outcome: Result[HostedInit, LoaderError].err(e), phase: phase)

func realizationFailed(why: string): LoaderError =
  loaderError(lecRealizationFailed, why)

proc endHost(h: Host, why: string) =
  ## [SPEC LOADER l.418-421] Ended and reaped before the error returns.
  h.terminate(why)
  discard h.awaitEnd()

func codeOf(c: LcnCarrierInitFailedCodeChoice): LoaderErrorCode =
  type K = LcnCarrierInitFailedCodeChoiceKind
  case c.kind
  of K.Abi_invalid: lecAbiInvalid
  of K.Artifact_unavailable: lecArtifactUnavailable
  of K.Realization_failed: lecRealizationFailed

proc startHosted*(
    host: pointer, call: HostedCall, maxPayloadDepth: int
): HostedOutcome =
  ## [plan §2.5 steps 3-9] Steps 3, 6 and 7 here; the state directory (step 4)
  ## was established by the Loader's thread.
  let h = cast[Host](host)
  if h == nil:
    return failedWith(realizationFailed("no Module Host handoff came for the instance"))
  let spec = call.spec
  let path = stageArtifact(spec.artifact, spec.dir, spec.name).valueOr:
    return failedWith(error)
  h.spawn().isOkOr:
    # [SPEC LOADER l.625] Module Host creation failed.
    return failedWith(realizationFailed("the Module Host was not created: " & error))
  var init = LcnCarrierInit(
    id: h.nextRequest(),
    module: spec.module,
    artifact_path: path,
    state_dir: spec.stateDir,
    live: call.live,
    max_payload_depth: uint64(maxPayloadDepth),
  )
  let words = h.transportInit()
  if words.len > 0:
    # [plan §2.8; part 4b-3.3] The Transport limits of the host's own loop,
    # which connects its consumer's handles and serves a provider's endpoint.
    init.transport = Opt.some(words)
  let ep = h.endpointInit()
  if ep.isSome:
    # [SPEC LOADER §5.3; RUN-0200] The Runtime-created listener is the host's
    # fd 4; `init` names its address and the Transport limits it serves with.
    init.endpoint = Opt.some(ep.get.path)
    init.transport = Opt.some(ep.get.transport)
    init.runtime_id = Opt.some(ep.get.runtimeId)
  if h.systemInit():
    # [G490] The marked Package Manager: its host accepts the reserved name.
    init.system = Opt.some(true)
  let sysEp = h.systemEndpointInit()
  if sysEp.isSome:
    # [G492; TRN-0330] Its system-service listener is the host's fd 6.
    init.system_endpoint = sysEp
  when defined(lcnTestHooks):
    # [DECISIONS I92] A test armed the audit hosts (`setWipeAuditForTests`).
    let audit = wipeAuditInit()
    if audit.len > 0:
      init.wipe_audit = Opt.some(audit)
  if call.configuration != nil:
    var b = newSeq[byte](call.configurationLen)
    for i in 0 ..< b.len:
      b[i] = call.configuration[i]
    init.configuration = Opt.some(b)
  h.sendMsg(toMessage(init)).isOkOr:
    h.endHost("the init message was not sent")
    return
      failedWith(realizationFailed("the Module Host ended before it was initialized"))
  type K = LcnCarrierMessageKind
  let m = h.awaitLane0().valueOr:
    discard h.awaitEnd()
    return
      failedWith(realizationFailed("the Module Host ended before it was initialized"))
  case m.kind
  of K.lcn_Carrier_initialized:
    retain(h) # the realization's
    HostedOutcome(
      outcome: Result[HostedInit, LoaderError].ok(
        HostedInit(
          surface: m.arm_lcn_Carrier_initialized.call_surface,
          endpoint:
            if ep.isSome:
              Opt.some(ep.get.path)
            else:
              Opt.none(string),
        )
      )
    )
  of K.lcn_Carrier_init_failed:
    let f = m.arm_lcn_Carrier_init_failed
    h.endHost("its initialization failed")
    var e = loaderError(codeOf(f.code), f.message)
    if f.cause.isSome:
      e.cause = Opt.some(toAbi(f.cause.get))
    let phase =
      if f.phase.kind == LcnCarrierInitFailedPhaseChoiceKind.Init: fpInit else: fpNone
    failedWith(e, phase)
  of K.lcn_Carrier_fatal:
    h.endHost("it failed")
    failedWith(
      realizationFailed("the Module Host failed: " & m.arm_lcn_Carrier_fatal.message)
    )
  else:
    h.endHost("an unexpected lane-0 message")
    failedWith(realizationFailed("the Module Host answered init with " & $m.kind))

proc releaseHosted*(host: pointer) =
  ## [SPEC LOADER §9; plan §2.9 step 4] `release`, then the confirmed end;
  ## drops the realization's reference. A host already ended is only reaped.
  let h = cast[Host](host)
  if h == nil:
    return
  if h.sendMsg(toMessage(LcnCarrierRelease(id: h.nextRequest()))).isOk:
    type K = LcnCarrierMessageKind
    while true:
      let m = h.awaitLane0()
      if m.isNone or m.get.kind == K.lcn_Carrier_released:
        break
      if m.get.kind == K.lcn_Carrier_fatal:
        h.terminate("it failed during release")
  discard h.awaitEnd()
  dropHost(h)

proc applyHosted*(host: pointer, configuration: openArray[byte]): AbiCheck =
  ## [SPEC LOADER §8, l.497-499; plan §2.10; G270] The hook's status as the
  ## host read it. The host's end while it is outstanding leaves the outcome
  ## indeterminate (the record becomes `failed`), reported only once the end
  ## is confirmed, so the Runtime has handled the end first [R27].
  let h = cast[Host](host)
  template lost(): AbiCheck =
    discard h.awaitEnd()
    AbiCheck.err(
      AbiFailure(code: ecModule, reason: "the Module Host ended during the application")
    )

  h.sendMsg(
    toMessage(LcnCarrierApply(id: h.nextRequest(), configuration: @configuration))
  ).isOkOr:
    return lost()
  type K = LcnCarrierMessageKind
  let m = h.awaitLane0().valueOr:
    return lost()
  if m.kind != K.lcn_Carrier_applied:
    h.terminate("an unexpected lane-0 message")
    return lost()
  let f = m.arm_lcn_Carrier_applied.failure
  if f.isSome:
    return AbiCheck.err(toAbi(f.get))
  AbiCheck.ok()

proc hostEnded*(host: pointer): bool {.nimcall.} =
  ## [SPEC LOADER l.497-499] The host's end is confirmed.
  cast[Host](host).ended

proc endHosts*(hosts: openArray[pointer]) =
  ## [SPEC RUNTIME l.3821; plan §2.9] Hosts of realizations the Loader still
  ## held when its thread stopped: ended, reaped and dropped.
  for p in hosts:
    let h = cast[Host](p)
    h.terminate("its Module Loader stopped")
    discard h.awaitEnd()
    dropHost(h)
