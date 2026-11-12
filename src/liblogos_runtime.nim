## RUNTIME §13: `liblogos_runtime`, the Host Embedding API as a C library. Its
## six exports are `logos_runtime.h`'s functions (`lcn-gen logos-runtime`);
## each is `runtime/host.nim`'s procedure of the same meaning.
##
## Built with `--app:lib --nimMainPrefix:liblogos_runtime`, so its Nim runtime
## starts in a load-time constructor, apart from the host's and from any module
## library's (`nimble build_runtime_lib`). Every entry registers a thread this
## runtime did not create (`bindingEnter`), so a host may call from any thread.
##
## [IMPL] Nim's own globals are not exported (`base/libvisibility`): a host
## that links the library at load time puts its exports in the process's global
## scope on ELF systems, where a module library the Runtime maps would
## otherwise bind to this runtime's tables.

{.push raises: [].}

import ./logos_core/base/libvisibility
import ./logos_core/abi/[host, types]
import ./logos_core/runtime/host as hostApi

proc logosRuntimeCreate(
    config: ptr LogosRuntimeConfig, outRuntime: ptr ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_create", dynlib, cdecl.} =
  runtimeCreate(config, outRuntime)

proc logosRuntimeRegisterBinding(
    runtime: ptr LogosRuntimeHandle, binding: ptr LogosRuntimeNativeBinding
): LogosResult {.exportc: "logos_runtime_register_binding", dynlib, cdecl.} =
  runtimeRegisterBinding(runtime, binding)

proc logosRuntimeStart(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_start", dynlib, cdecl.} =
  runtimeStart(runtime)

proc logosRuntimeRequestShutdown(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_request_shutdown", dynlib, cdecl.} =
  runtimeRequestShutdown(runtime)

proc logosRuntimeWaitForShutdown(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_wait_for_shutdown", dynlib, cdecl.} =
  runtimeWaitForShutdown(runtime)

proc logosRuntimeDestroy(
    runtime: ptr LogosRuntimeHandle
): LogosResult {.exportc: "logos_runtime_destroy", dynlib, cdecl.} =
  runtimeDestroy(runtime)
