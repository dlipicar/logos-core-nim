#define LOGOS_SENSOR_MODULE_PRIMARY_NAMESPACE "sensor.control"
#define LOGOS_SENSOR_MODULE_IMPLEMENTS_0 "metrics_provider"
#define LOGOS_METRICS_PROVIDER_INTERFACE_NAMESPACE "metrics_provider"
#define LOGOS_METRICS_TYPES_SUPPORTING_NAMESPACE "metrics_types"
#define LOGOS_SENSOR_CONTROL_SETTINGS_KIND_LITERAL "sensor"

typedef uint64_t logos_metrics_types_counter_t;

typedef struct logos_map_sensor_control_settings {
    const char*                  kind;
    logos_metrics_types_counter_t limit;
} logos_sensor_control_settings_t;

typedef logos_result_t (*logos_metrics_provider_call_snapshot_fn)(
    logos_module_context_t* module,
    uint64_t*               out_count
);

logos_result_t logos_sensor_module_call_metrics_provider_snapshot(
    logos_module_context_t* module,
    uint64_t*               out_count
);

typedef logos_result_t (*logos_sensor_control_call_configure_fn)(
    logos_module_context_t*                module,
    const logos_sensor_control_settings_t* in_settings
);

logos_result_t logos_sensor_module_call_sensor_control_configure(
    logos_module_context_t*                module,
    const logos_sensor_control_settings_t* in_settings
);

const char* logos_sensor_module_name(void);

logos_result_t logos_sensor_module_init(
    const logos_module_init_input_t* input,
    logos_module_context_t**         out_context
);

void logos_sensor_module_destroy(logos_module_context_t* module);

const uint8_t* logos_sensor_module_call_surface(size_t* out_len);
void logos_sensor_module_free(logos_module_context_t* module, void* ptr);

logos_result_t logos_sensor_module_dispatch(
    logos_module_context_t* module,
    const char*             method,
    const uint8_t*          params_cbor,
    size_t                  params_len,
    uint8_t**               out_response_cbor,
    size_t*                 out_response_len
);
