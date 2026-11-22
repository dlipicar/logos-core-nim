## RUNTIME §13: `liblogos_runtime`, the Host Embedding API as a C library. Its
## six exports are `logos_runtime.h`'s functions (`lcn-gen logos-runtime`);
## each is `runtime/host.nim`'s procedure of the same meaning.
##
## Built with `--app:lib --nimMainPrefix:liblogos_runtime`, so its Nim runtime
## starts in a load-time constructor, apart from the host's and from any module
## library's (`nimble build_runtime_lib`). Every entry registers a thread this
## runtime did not create (`bindingEnter`), in its own frame and again in the
## procedure it calls (DECISIONS G464), so a host may call from any thread.
##
## [IMPL] Nim's own globals are not exported (`base/libvisibility`): a host
## that links the library at load time puts its exports in the process's global
## scope on ELF systems, where a module library the Runtime maps would
## otherwise bind to this runtime's tables.
##
## [DECISIONS G340] Loading the library leaves the host's signal dispositions
## as they were: it is built with `-d:noSignalHandler`, so its `NimMain` sets
## no handler, and `base/hostsignals` puts back the `SIGPIPE` disposition
## chronos's initializer changes.

when not defined(noSignalHandler):
  {.
    error:
      "liblogos_runtime is built with -d:noSignalHandler (DECISIONS G340): otherwise loading it replaces the host's signal handlers"
  .}

{.push raises: [].}

import logos_sdk/base/libvisibility
import logos_sdk/base/hostsignals # before anything that imports chronos
import logos_sdk/abi/[cstatus, host, types]
import ./logos_core/runtime/host as hostApi

proc logosRuntimeCreate(
    config: ptr LogosRuntimeConfig, outRuntime: ptr ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_create", dynlib, cdecl.} =
  bindingEnter()
  runtimeCreate(config, outRuntime)

proc logosRuntimeRegisterBinding(
    runtime: ptr LogosRuntimeHandle, binding: ptr LogosRuntimeNativeBinding
): LogosResult {.exportc: "logos_runtime_register_binding", dynlib, cdecl.} =
  bindingEnter()
  runtimeRegisterBinding(runtime, binding)

proc logosRuntimeStart(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_start", dynlib, cdecl.} =
  bindingEnter()
  runtimeStart(runtime)

proc logosRuntimeRequestShutdown(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_request_shutdown", dynlib, cdecl.} =
  bindingEnter()
  runtimeRequestShutdown(runtime)

proc logosRuntimeWaitForShutdown(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_wait_for_shutdown", dynlib, cdecl.} =
  bindingEnter()
  runtimeWaitForShutdown(runtime)

proc logosRuntimeDestroy(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_destroy", dynlib, cdecl.} =
  bindingEnter()
  runtimeDestroy(runtime)

# [DECISIONS G340] Last in the library's initializer, after chronos's.
restoreHostSignals()
