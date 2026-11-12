typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    const char* configuration_format;
    const uint8_t* configuration;
    size_t configuration_len;
} logos_runtime_config_t;

typedef void (*logos_runtime_symbol_address_t)(void);

typedef struct {
    const char* name;
    logos_runtime_symbol_address_t address;
} logos_runtime_native_symbol_t;

typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    const char* binding;
    const logos_runtime_native_symbol_t* symbols;
    size_t symbol_count;
} logos_runtime_native_binding_t;

logos_result_t logos_runtime_create(
    const logos_runtime_config_t* config,
    logos_runtime_t** out_runtime
);
logos_result_t logos_runtime_register_binding(
    logos_runtime_t* runtime,
    const logos_runtime_native_binding_t* binding
);
logos_result_t logos_runtime_start(logos_runtime_t* runtime);
logos_result_t logos_runtime_request_shutdown(logos_runtime_t* runtime);
logos_result_t logos_runtime_wait_for_shutdown(logos_runtime_t* runtime);
logos_result_t logos_runtime_destroy(logos_runtime_t* runtime);
