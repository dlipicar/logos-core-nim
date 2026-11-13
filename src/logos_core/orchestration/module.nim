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

proc initModule(
    _: type OrchestratorInstance, init: ModuleInit, config: LcnOrchestratorConfig
): Result[OrchestratorInstance, InvocationFailure] =
  let s = settingsOf(config).valueOr:
    return
      err(failure(ecModule, "the orchestration configuration is invalid: " & error))
  checkBinding(init.services.runtimeControl).isOkOr:
    return err(failure(ecModule, "the Runtime Control binding: " & $error))
  let bytes = encode(config).valueOr:
    return err(failure(ecModule, "the orchestration configuration: " & error))
  var (acc, lock) = openAccounting(init.stateDir, s).valueOr:
    return err(failure(ecModule, error))
  let sh = newShared(init.services.runtimeControl, bytes, acc.dir)
  startWorker(sh).isOkOr:
    freeShared(sh)
    lock.release()
    return err(failure(ecModule, error))
  ok(OrchestratorInstance(sh: sh, lock: lock))

proc destroyModule(m: OrchestratorInstance) =
  stopWorker(m.sh)
  freeShared(m.sh)
  m.sh = nil
  m.lock.release()

exportLcnOrchestrator(OrchestratorInstance)

{.pop.}
