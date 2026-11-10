typedef const char* logos_tstr_size_1_64_t;

typedef struct logos_event_meter_changed_event {
    uint64_t value;
} logos_meter_changed_event_t;

typedef struct logos_map_meter_reading {
    bool        has_label;
    const char* label;
    uint64_t    value;
} logos_meter_reading_t;

typedef logos_result_t (*logos_meter_call_read_fn)(
    logos_module_context_t*    module,
    uint32_t                   in_channel,
    logos_tstr_size_1_64_t*   out_label,
    logos_meter_reading_t*    out_reading
);

logos_result_t logos_meter_module_call_meter_read(
    logos_module_context_t*    module,
    uint32_t                   in_channel,
    logos_tstr_size_1_64_t*   out_label,
    logos_meter_reading_t*    out_reading
);

const char* logos_meter_module_name(void);

logos_result_t logos_meter_module_init(
    const logos_module_init_input_t* input,
    logos_module_context_t**         out_context
);

void logos_meter_module_destroy(logos_module_context_t* module);

const uint8_t* logos_meter_module_call_surface(size_t* out_len);
void logos_meter_module_free(logos_module_context_t* module, void* ptr);

logos_result_t logos_meter_module_dispatch(
    logos_module_context_t* module,
    const char*             method,
    const uint8_t*          params_cbor,
    size_t                  params_len,
    uint8_t**               out_response_cbor,
    size_t*                 out_response_len
);
