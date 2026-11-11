typedef const char* logos_tstr_size_1_64_t;

typedef struct logos_meter_Changed_event_EVENT {
    uint64_t value;
} logos_meter_Changed_event_t;

typedef struct logos_meter_Reading_MAP {
    bool        has_label;
    const char* label;
    uint64_t    value;
} logos_meter_Reading_t;

typedef logos_result_t (*logos_meter_Read_FN_t)(
    logos_module_context_t*    module,
    logos_response_owner_t* response_owner,
    uint32_t                   in_channel,
    logos_tstr_size_1_64_t*   out_label,
    logos_meter_Reading_t*    out_reading
);

logos_result_t logos_meter_module_CALL_meter_Read(
    logos_module_context_t*    module,
    logos_response_owner_t* response_owner,
    uint32_t                   in_channel,
    logos_tstr_size_1_64_t*   out_label,
    logos_meter_Reading_t*    out_reading
);

const char* logos_meter_module_MODULE_name(void);

logos_result_t logos_meter_module_MODULE_init(
    const logos_module_init_input_t* input,
    logos_module_context_t**         out_context
);

void logos_meter_module_MODULE_destroy(logos_module_context_t* module);

const uint8_t* logos_meter_module_MODULE_call_surface(size_t* out_len);
void logos_meter_module_MODULE_free(logos_module_context_t* module, void* ptr);

logos_result_t logos_meter_module_MODULE_dispatch(
    logos_module_context_t* module,
    const char*             method,
    const uint8_t*          params_cbor,
    size_t                  params_len,
    uint8_t**               out_response_cbor,
    size_t*                 out_response_len
);
