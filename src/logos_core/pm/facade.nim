## The Package Manager module (Tier 5 step 5-6a-1; DECISIONS G490, G491, G494, G495;
## docs/PACKAGE-MANAGER.md §6): `logos_package_manager`'s handlers over the shell
## (`shell.nim`, G405), exported through its kit (`logos_package_manager_kit.nim`:
## PM App A, confined, the asynchronous provider API, G338). `logosd` composes it as
## the reserved `hosted_dynamic` instance `package_manager` (G491, C1), and the host
## configuration's top-level `package_manager` mark lets the Module Host accept its
## reserved name (G490).
##
## - **The four operations** (`inspect_package`, `install_package`, `remove_package`,
##   `update_package`) map onto the engine's requests in `requests.nim`, as
##   `pmtest_module` mapped them (G449).
## - **The answers** (G494): the worker's encoded response (`oaEncoded`) passes through
##   as pre-encoded bytes, which the boundary checks against the method's schema; an
##   engine response (`{error}` or `{}`) is encoded here; a full queue or an admission
##   bound (`oaModuleError`) is the invocation error MODULE_ERROR (PM l.1516-1517).
## - **A cancellation** the Runtime sends reaches the handler as `CancelledError`: the
##   shell cancels the operation in the engine, the handler logs one line and ends
##   CANCELLED (G338, G449). What the caller sees is the boundary's code.
## - **`get_runtime_handoff`** is served to a SYSTEM_SERVICE caller, the Runtime's own
##   binding (5-6a-2, G493). An ordinary caller is refused (Q7 (b): readers only, from
##   5-6b).
## - **The observation methods** (`list_packages`, `list_installed_packages`,
##   `watch_installed_packages`) and an ordinary caller's `get_runtime_handoff` are
##   refused in 5-6a with MODULE_ERROR and no message or detail: a provider cannot
##   answer NOT_AUTHORISED (INTERFACE l.3308-3311; G495, Q6 (b)). The operator's log
##   gets one line naming the caller, the method and why.
## - **The stop**: the Runtime cancels the calls in flight first; `destroyModule` then
##   runs `closeShell`, which stops the engine and the worker (§4.1 of the plan).

{.push raises: [], gcsafe.}
{.used.}

import results
import logos_sdk/cbor
from logos_sdk/base/logtext import oneLine
import ../package/records
import ./[logos_package_manager_kit, requests, shell]

export logos_package_manager_kit

type PackageManager* = ref object
  shell: Shell
  log: ShellLog

when defined(lcnTestHooks):
  import std/os
  from chronos import sleepAsync, milliseconds

  proc handoffHeld() {.async: (raises: [CancelledError]).} =
    ## [IMPL; plan §10.2, ruling 1] `test_system_binding`'s hold: while the file named
    ## by `LCN_TEST_HANDOFF_GATE` exists, a system-service `get_runtime_handoff` waits
    ## before the shell answers it, and appends a line to `<file>.held` as it begins to
    ## wait. A cancellation ends the wait. Test builds only.
    let gate = getEnv("LCN_TEST_HANDOFF_GATE")
    if gate.len == 0 or not fileExists(gate):
      return
    try:
      let f = open(gate & ".held", fmAppend)
      f.write("held\n")
      f.close()
    except CatchableError:
      discard
    while fileExists(gate):
      await sleepAsync(5.milliseconds)

# Answers ----------------------------------------------------------------------------------

func cancelled(): InvocationFailure =
  ## [G338; G449] A handler the kit cancelled (the Runtime's cancel, a stop): its
  ## operation was cancelled in the engine, and the call ends CANCELLED.
  failure(ecCancelled, "the operation was cancelled")

func refused(): InvocationFailure =
  ## [G495; Q6 (b)] A refused observation: MODULE_ERROR with no message and no detail,
  ## the only refusal a provider may answer (INTERFACE l.3308-3311). The reason is the
  ## operator's (`refuse`).
  InvocationFailure(code: ecModule)

proc answered(a: OperationAnswer): Result[PreEncoded, InvocationFailure] =
  ## [G494] An engine answer as the handler's response.
  case a.kind
  of oaResponse:
    ok(preEncoded(encodeCbor(a.response)))
  of oaModuleError:
    err(moduleError(a.reason))
  of oaEncoded:
    # The one copy (§4.2 of the plan): `OperationAnswer.encoded` is a string until 5-6b.
    var b = newSeq[byte](a.encoded.len)
    if b.len > 0:
      copyMem(addr b[0], unsafeAddr a.encoded[0], b.len)
    ok(preEncoded(move b))

func describe(c: Result[Caller, InvocationFailure]): string =
  ## The caller for the operator's log: its Runtime and module instance.
  if c.isErr:
    return "an unknown caller"
  let k = c.get
  case k.kind
  of ckModule:
    "module instance " & k.moduleInstance.get("?") & " of Runtime " & k.runtimeInstance
  of ckSystemService:
    "the system service of Runtime " & k.runtimeInstance

proc refuse(m: PackageManager, inv: Invocation, meth, why: string): InvocationFailure =
  ## [G495] One operator log line naming the caller, the method and why; the caller
  ## gets MODULE_ERROR with nothing more.
  m.log(
    "package-manager: " & meth & " refused for " & oneLine(describe(inv.caller())) & ": " &
      why
  )
  refused()

proc operate(
    m: PackageManager, meth: string, op: OperationRequest
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  let a =
    try:
      await m.shell.operate(op)
    except CancelledError:
      m.log("package-manager: " & meth & " cancelled by the Runtime")
      return err(cancelled())
  answered(a)

# The kit's hooks --------------------------------------------------------------------------

proc initModule*(
    _: type PackageManager, init: ModuleInit
): Result[PackageManager, InvocationFailure] =
  ## [G405] The shell, from the protected input (G400); the engine starts once
  ## `_MODULE_init` returned.
  let s = ?openShell(init, log = stderrLog)
  ok(PackageManager(shell: s, log: stderrLog))

proc destroyModule*(m: PackageManager) {.async: (raises: []).} =
  ## [G437] After the Runtime ended the calls in flight: the engine and the worker stop.
  await m.shell.closeShell()

proc `inspect_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerInspectPackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `inspect_package`, through the engine's slots (G449).
  let op = ?inspectOp(request)
  await m.operate("inspect_package", op)

proc `install_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerInstallPackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `install_package`; its `progress_key` publishes nothing in 5-6a.
  let op = ?installOp(request)
  await m.operate("install_package", op)

proc `remove_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerRemovePackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `remove_package`.
  await m.operate("remove_package", removeOp(request))

proc `update_package`*(
    m: PackageManager,
    request: LogosNSPackageManagerUpdatePackageRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §15] `update_package`.
  let op = ?updateOp(request)
  await m.operate("update_package", op)

proc `get_runtime_handoff`*(
    m: PackageManager,
    request: LogosNSPackageManagerGetRuntimeHandoffRequest,
    inv: Invocation,
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC PM §12; G493, G495] Served to the Runtime's system-service binding; an
  ## ordinary caller is refused until 5-6b serves readers (Q7 (b)).
  let c = inv.caller()
  if c.isErr or c.get.kind != ckSystemService:
    return err(m.refuse(inv, "get_runtime_handoff", "not a reader"))
  let a =
    try:
      when defined(lcnTestHooks):
        await handoffHeld()
      await m.shell.handoff(identityOf(request.package), request.module)
    except CancelledError:
      m.log("package-manager: get_runtime_handoff cancelled by the Runtime")
      return err(cancelled())
  answered(a)

proc `list_packages`*(
    m: PackageManager,
    request: LogosNSPackageManagerListPackagesRequest,
    inv: Invocation,
): Future[Result[LogosNSPackageManagerListPackagesResponse, InvocationFailure]] {.
    async: (raises: [])
.} =
  ## [G495] Refused in 5-6a: 5-6b serves readers (C4).
  err(m.refuse(inv, "list_packages", "not a reader"))

proc `list_installed_packages`*(
    m: PackageManager,
    request: LogosNSPackageManagerListInstalledPackagesRequest,
    inv: Invocation,
): Future[Result[LogosNSPackageManagerListInstalledPackagesResponse, InvocationFailure]] {.
    async: (raises: [])
.} =
  ## [G495] Refused in 5-6a: 5-6b serves readers (C4).
  err(m.refuse(inv, "list_installed_packages", "not a reader"))

proc `watch_installed_packages`*(
    m: PackageManager,
    request: LogosNSPackageManagerWatchInstalledPackagesRequest,
    inv: Invocation,
): Future[
    Result[LogosNSPackageManagerWatchInstalledPackagesResponse, InvocationFailure]
] {.async: (raises: []).} =
  ## [G495] Refused in 5-6a: 5-6b serves readers (C4, PKG-0544).
  err(m.refuse(inv, "watch_installed_packages", "not a reader"))

exportLogosPackageManager(PackageManager)
