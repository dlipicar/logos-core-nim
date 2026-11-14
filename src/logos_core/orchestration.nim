## The reference orchestration module (DECISIONS I94; RUNTIME §10.1): what a
## host uses to run it, P1-P6.
##
## - P1 `OrchestratorModule`, `OrchestratorBinding`: the module's name and the
##   `direct_static` binding the host registers.
## - P2 `orchestratorStaticSymbols()`: the binding's symbols, for
##   `runtimeRegisterBinding`.
## - P3 `orchestratorDeclaration()`: the `configuration_declaration`, with the
##   package default.
## - P4 `OrchestratorSettings`, `validateSettings`, `encodeSettings`: the
##   value a host provisions (`provisioned_configuration`, G141).
## - P5 `orchestratorNeeds(s)`: what the module calls, for the grants a host
##   gives the orchestration instance.
## - P6 `setOrchestratorDiagnostics(sink)`: where its diagnostic lines go.
##
## The host's `orchestration` field gives the instance the role; the module's
## name confers nothing (RUNTIME l.187-192, G53).

{.push raises: [], gcsafe.}

import results
import ./orchestration/[module, needs, settings, worker]

export results, settings, needs
export setOrchestratorDiagnostics, DiagnosticsSink, OrchestratorInstance

proc orchestratorStaticSymbols*(): seq[(string, pointer)] =
  ## [I94] P2: the exported symbols of the `lcn_orchestrator` binding.
  lcnOrchestratorStaticSymbols()

{.pop.}
