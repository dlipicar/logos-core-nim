## The reference orchestration module's kit glue (DECISIONS I94): what
## `_MODULE_init` and `_MODULE_destroy` do.
##
## `initModule` checks the value (`settings.settingsOf`), locks the state
## directory and loads the accounting (failing closed), then starts the worker
## as its last step, after everything that can fail. It makes no Runtime
## Control call: the orchestration start answers at `ready` (G190) and never
## waits for the module. `destroyModule` ends the worker, which leaves nothing
## armed and makes no call afterwards, then releases the lock (RUNTIME l.3806).

{.push raises: [], gcsafe.}

import results
import ../durable
import ../kit/rcclient
import ./[accounting, lcn_orchestrator_kit, settings, worker]

type OrchestratorInstance* = ref object
  sh: ptr Shared
  lock: DurableLock

proc fail(message: string): Result[OrchestratorInstance, InvocationFailure] =
  ## [I94] A failed start is also a diagnostic: the Runtime does not disclose
  ## the module's failure text (RUNTIME l.1901-1904), and the operator needs
  ## it, a broken state file's name above all.
  diag("cannot start: " & message)
  err(failure(ecModule, message))

proc initModule(
    _: type OrchestratorInstance, init: ModuleInit, config: LcnOrchestratorConfig
): Result[OrchestratorInstance, InvocationFailure] =
  let s = settingsOf(config).valueOr:
    return fail("the orchestration configuration is invalid: " & error)
  checkBinding(init.services.runtimeControl).isOkOr:
    return fail("the Runtime Control binding: " & $error)
  let bytes = encode(config).valueOr:
    return fail("the orchestration configuration: " & error)
  var (acc, lock) = openAccounting(init.stateDir, s).valueOr:
    return fail(error)
  let sh = newShared(init.services.runtimeControl, bytes, acc.dir)
  startWorker(sh).isOkOr:
    freeShared(sh)
    lock.release()
    return fail(error)
  ok(OrchestratorInstance(sh: sh, lock: lock))

proc destroyModule(m: OrchestratorInstance) =
  stopWorker(m.sh)
  freeShared(m.sh)
  m.sh = nil
  m.lock.release()

exportLcnOrchestrator(OrchestratorInstance)

{.pop.}
