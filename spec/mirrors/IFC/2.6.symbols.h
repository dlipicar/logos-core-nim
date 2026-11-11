/* Module name (static string, valid for implementation-binding lifetime) */
const char* logos_<module-C>_MODULE_name(void);

/* Create one module instance from one structured initialization input. */
logos_result_t logos_<module-C>_MODULE_init(
    const logos_module_init_input_t* input,
    logos_module_context_t**         out_context
);

/* Apply one complete configuration to a live-reconfigurable module instance. */
logos_result_t logos_<module-C>_MODULE_apply_configuration(
    logos_module_context_t* module,
    const uint8_t*          configuration_cbor,
    size_t                  configuration_cbor_len
);

/* Destroy one successfully initialized module instance. */
void logos_<module-C>_MODULE_destroy(logos_module_context_t* module);

/* Provider-only call-surface metadata and memory-management symbols. */
const uint8_t* logos_<module-C>_MODULE_call_surface(size_t* out_len);
void logos_<module-C>_MODULE_free(logos_module_context_t* module, void* ptr);

/* Provider-only deterministic-CBOR dispatch entrypoint. */
logos_result_t logos_<module-C>_MODULE_dispatch(
    logos_module_context_t* module,
    const char*             method,
    const uint8_t*          params_cbor,
    size_t                  params_len,
    uint8_t**               out_response_cbor,
    size_t*                 out_response_len
);
