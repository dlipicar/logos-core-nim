## RUNTIME §13: the host embedding ABI as Nim types, field for field and in the
## same order as `logos_runtime.h`, so each has the C layout (checked against the
## generated header by `tests/test_abi.nim`). Nothing here allocates or calls
## through a pointer; the Host Embedding API itself is `runtime/host.nim`.

{.push raises: [].}

const
  RuntimeHostAbiVersion* = 1'u32 ## `LOGOS_RUNTIME_HOST_ABI_VERSION`
  AppConfigFormat* = "logos-core-nim.app-config.v1"
    ## [G76] `LCN_RUNTIME_CONFIG_FORMAT_APP_V1`: the one configuration format
    ## identifier this implementation accepts (docs/HOST-CONFIG.md).

type
  LogosRuntimeHandle* {.incompleteStruct.} = object
    ## `struct logos_runtime`: opaque to the host.

  LogosRuntimeConfig* {.bycopy.} = object ## `logos_runtime_config_t`
    abiVersion*: uint32
    structSize*: csize_t
    configurationFormat*: cstring
    configuration*: ptr UncheckedArray[uint8]
    configurationLen*: csize_t

  LogosRuntimeSymbolAddress* = proc() {.cdecl, gcsafe, raises: [].}
    ## `logos_runtime_symbol_address_t`: converted to the symbol's own signature
    ## before any call [SPEC RUNTIME §13.3].

  LogosRuntimeNativeSymbol* {.bycopy.} = object ## `logos_runtime_native_symbol_t`
    name*: cstring
    address*: LogosRuntimeSymbolAddress

  LogosRuntimeNativeBinding* {.bycopy.} = object ## `logos_runtime_native_binding_t`
    abiVersion*: uint32
    structSize*: csize_t
    binding*: cstring
    symbols*: ptr UncheckedArray[LogosRuntimeNativeSymbol]
    symbolCount*: csize_t

const
  RuntimeConfigV1Extent* = sizeof(LogosRuntimeConfig)
    ## [SPEC RUNTIME §13.1] The smallest `struct_size` version 1 accepts: the
    ## end of its last field.
  NativeBindingV1Extent* = sizeof(LogosRuntimeNativeBinding)
    ## [SPEC RUNTIME §13.1] As `RuntimeConfigV1Extent`, for the binding.
