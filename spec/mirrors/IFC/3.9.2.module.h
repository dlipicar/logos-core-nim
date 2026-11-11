#define LOGOS_PRIMARY_NAMESPACE_sensor_module "sensor.control"
#define LOGOS_IMPLEMENTS_sensor_module_INDEX0 "metrics_provider"
#define LOGOS_INTERFACE_NAMESPACE_metrics_provider "metrics_provider"
#define LOGOS_SUPPORTING_NAMESPACE_metrics_types "metrics_types"
#define LOGOS_LITERAL_sensor_NS_control_Settings_Kind "sensor"

typedef uint64_t logos_metrics_types_Counter_t;

typedef struct logos_sensor_NS_control_Settings_MAP {
    const char*                  kind;
    logos_metrics_types_Counter_t limit;
} logos_sensor_NS_control_Settings_t;

typedef logos_result_t (*logos_metrics_provider_Snapshot_FN_t)(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    uint64_t*               out_count
);

logos_result_t logos_sensor_module_CALL_metrics_provider_Snapshot(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    uint64_t*               out_count
);

typedef logos_result_t (*logos_sensor_NS_control_Configure_FN_t)(
    logos_module_context_t*                module,
    logos_response_owner_t* response_owner,
    const logos_sensor_NS_control_Settings_t* in_settings
);

logos_result_t logos_sensor_module_CALL_sensor_NS_control_Configure(
    logos_module_context_t*                module,
    logos_response_owner_t* response_owner,
    const logos_sensor_NS_control_Settings_t* in_settings
);

const char* logos_sensor_module_MODULE_name(void);

logos_result_t logos_sensor_module_MODULE_init(
    const logos_module_init_input_t* input,
    logos_module_context_t**         out_context
);

void logos_sensor_module_MODULE_destroy(logos_module_context_t* module);

const uint8_t* logos_sensor_module_MODULE_call_surface(size_t* out_len);
void logos_sensor_module_MODULE_free(logos_module_context_t* module, void* ptr);

logos_result_t logos_sensor_module_MODULE_dispatch(
    logos_module_context_t* module,
    const char*             method,
    const uint8_t*          params_cbor,
    size_t                  params_len,
    uint8_t**               out_response_cbor,
    size_t*                 out_response_len
);
