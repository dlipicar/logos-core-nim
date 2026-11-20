/* logos_types.h: copied by lcn-gen from INTERFACE §5.2. Do not edit. */
#ifndef LOGOS_TYPES_H
#define LOGOS_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define LOGOS_C_MAPPING_REVISION 4u

#define LOGOS_C_CONTEXT_MODEL_6c6f676f732e636f6d6d69746d656e742d6d6f64656c2e323032362d3130 1
#define LOGOS_C_CONTEXT_PROFILE_6c6f676f732e686173682d70726f66696c652e323032362d30382e63686f6963652d696e646578 1
#define LOGOS_C_CONTEXT_SUITE_6c6f676f732e686173682d73756974652e626c616b65332d323536 1

#ifdef __cplusplus
extern "C" {
#endif

/* -- Error codes -- */

typedef enum {
    LOGOS_OK                    = 0,
    LOGOS_ERR_METHOD_NOT_FOUND  = 1,
    LOGOS_ERR_INVALID_PARAMS    = 2,
    LOGOS_ERR_MODULE            = 3,
    LOGOS_ERR_NOT_AUTHORISED    = 4,
    LOGOS_ERR_TRANSPORT         = 5,
    LOGOS_ERR_TIMEOUT           = 6,
    LOGOS_ERR_VERSION_MISMATCH  = 7,
    LOGOS_ERR_NOT_READY         = 8,
    LOGOS_ERR_CANCELLED         = 9,
} logos_error_code_t;

#ifdef __cplusplus
static_assert(sizeof(logos_error_code_t) == sizeof(int),
              "logos_error_code_t must have the size of int");
#else
_Static_assert(sizeof(logos_error_code_t) == sizeof(int),
               "logos_error_code_t must have the size of int");
#endif

/* -- Common schema value types -- */

typedef struct logos_bstr_size_0 {
    uint8_t _empty;
} logos_bstr_size_0_t;

typedef struct logos_tuple_size_0 {
    uint8_t _empty;
} logos_tuple_size_0_t;

#define LOGOS_INVALID_PARAMS_REASON_ARM_0_LITERAL "malformed-cbor"
#define LOGOS_INVALID_PARAMS_REASON_ARM_1_LITERAL "schema-mismatch"
#define LOGOS_INVALID_PARAMS_REASON_ARM_2_LITERAL "non-deterministic-cbor"
#define LOGOS_INVALID_PARAMS_REASON_ARM_3_LITERAL "configuration-schema-mismatch"

#define LOGOS_SCHEMA_COMMITMENT_COMMITMENT_MODEL_LITERAL \
    "logos.commitment-model.2026-10"
#define LOGOS_SCHEMA_COMMITMENT_HASH_PROFILE_LITERAL \
    "logos.hash-profile.2026-08.choice-index"
#define LOGOS_SCHEMA_COMMITMENT_HASH_SUITE_LITERAL \
    "logos.hash-suite.blake3-256"

typedef const uint8_t* logos_bstr_size_1_4096_t;

typedef struct logos_bstr_error_detail {
    logos_bstr_size_1_4096_t data;
    size_t len;
} logos_error_detail_t;

typedef uint32_t logos_invalid_params_reason_kind_t;
#define LOGOS_INVALID_PARAMS_REASON_ARM_0 0u
#define LOGOS_INVALID_PARAMS_REASON_ARM_1 1u
#define LOGOS_INVALID_PARAMS_REASON_ARM_2 2u
#define LOGOS_INVALID_PARAMS_REASON_ARM_3 3u

typedef struct logos_choice_invalid_params_reason {
    logos_invalid_params_reason_kind_t kind;
} logos_invalid_params_reason_t;

typedef uint32_t logos_invalid_params_path_segment_kind_t;
#define LOGOS_INVALID_PARAMS_PATH_SEGMENT_ARM_0 0u
#define LOGOS_INVALID_PARAMS_PATH_SEGMENT_ARM_1 1u

typedef struct logos_choice_invalid_params_path_segment {
    logos_invalid_params_path_segment_kind_t kind;
    union {
        const char* arm_0;
        uint64_t arm_1;
    } value;
} logos_invalid_params_path_segment_t;

typedef struct logos_map_invalid_params_detail {
    bool has_path;
    const logos_invalid_params_path_segment_t* path;
    size_t path_count;
    logos_invalid_params_reason_t reason;
} logos_invalid_params_detail_t;

typedef struct logos_map_schema_commitment {
    const char* commitment_model;
    const char* hash_profile;
    const char* hash_suite;
    uint8_t schema_root[32];
} logos_schema_commitment_t;

/* -- Result type -- */

#define LOGOS_ERROR_MESSAGE_MAX_LEN 512u
#define LOGOS_ERROR_DETAIL_MAX_LEN 4096u

typedef struct {
    logos_error_code_t  code;
    const char*         message;      /* human-readable; may be NULL */
    const uint8_t*      detail;       /* optional encoded detail; may be NULL */
    size_t              detail_len;
} logos_result_t;

/* -- Response ownership -- */

typedef struct logos_response_owner {
    void* state;
    void (*release)(void* state);
} logos_response_owner_t;

static inline void logos_response_owner_clear(logos_response_owner_t* owner)
{
    logos_response_owner_t previous = *owner;
    owner->state = 0;
    owner->release = 0;
    if (previous.release != 0) {
        previous.release(previous.state);
    }
}

/* -- Module initialization and per-instance context -- */

/*
 * Module-owned opaque state for one initialized module instance.
 * ABI callers never dereference or free this value.
 */
typedef struct logos_module_context logos_module_context_t;
typedef struct logos_runtime_control_binding logos_runtime_control_binding_t;
typedef struct logos_runtime_control_vtable logos_runtime_control_vtable_t;
typedef struct logos_route_handle logos_route_handle_t;
typedef struct logos_route_vtable logos_route_vtable_t;

#define LOGOS_ASYNC_CALL_ABI_VERSION 1u
#define LOGOS_ASYNC_PROVIDER_ABI_VERSION 1u
#define LOGOS_INVOCATION_CONTEXT_ABI_VERSION 1u
#define LOGOS_CALLER_MODULE 1u
#define LOGOS_CALLER_SYSTEM_SERVICE 2u

typedef struct logos_async_call logos_async_call_t;
typedef struct logos_async_call_vtable logos_async_call_vtable_t;
typedef struct logos_invocation_context logos_invocation_context_t;
typedef struct logos_invocation_context_vtable logos_invocation_context_vtable_t;
typedef struct logos_provider_invocation logos_provider_invocation_t;

typedef struct {
    const uint8_t* data;
    size_t len;
} logos_utf8_view_t;

typedef struct {
    uint32_t kind;
    logos_utf8_view_t runtime_instance_id;
    logos_utf8_view_t module_instance_id;
} logos_caller_view_t;

struct logos_invocation_context {
    const logos_invocation_context_vtable_t* vtable;
    void* state;
};

struct logos_invocation_context_vtable {
    uint32_t abi_version;
    size_t struct_size;
    logos_result_t (*caller)(
        const logos_invocation_context_t* invocation,
        logos_caller_view_t* out_caller
    );
    bool (*is_cancelled)(const logos_invocation_context_t* invocation);
    logos_result_t (*publish)(
        const logos_invocation_context_t* invocation,
        const char* event_name,
        const uint8_t* cbor_data,
        size_t cbor_data_len
    );
};

typedef struct {
    void* state;
    const logos_invocation_context_t* (*current)(void* state);
} logos_invocation_access_t;

typedef void (*logos_async_complete_fn)(
    void* user_data,
    logos_result_t result,
    const uint8_t* response_cbor,
    size_t response_cbor_len,
    logos_response_owner_t owner
);

typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    bool has_timeout;
    uint64_t timeout_ms;
} logos_async_options_t;

typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    logos_async_complete_fn complete;
    void* user_data;
} logos_async_callbacks_t;

struct logos_async_call {
    const logos_async_call_vtable_t* vtable;
    void* state;
};

struct logos_async_call_vtable {
    uint32_t abi_version;
    size_t struct_size;
    void (*submit)(logos_async_call_t* call);
    void (*cancel)(logos_async_call_t* call);
    void (*release)(logos_async_call_t* call);
};

struct logos_provider_invocation {
    uint32_t abi_version;
    size_t struct_size;
    const char* method;
    const uint8_t* params_cbor;
    size_t params_cbor_len;
    const logos_invocation_context_t* context;
    void (*complete)(
        logos_provider_invocation_t* invocation,
        logos_result_t result,
        const uint8_t* response_cbor,
        size_t response_cbor_len,
        logos_response_owner_t owner
    );
    void (*execution_release)(logos_provider_invocation_t* invocation);
};

typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    void (*submit)(
        logos_module_context_t* module,
        logos_provider_invocation_t* invocation
    );
    void (*request_cancel)(
        logos_module_context_t* module,
        logos_provider_invocation_t* invocation
    );
} logos_async_provider_api_t;

#define LOGOS_MODULE_INIT_ABI_VERSION 3u

typedef logos_error_code_t (*logos_publish_fn)(
    void*          user_data,
    const char*    event_name,
    const uint8_t* cbor_data,
    size_t         cbor_data_len
);

typedef struct {
    uint32_t                               abi_version;
    size_t                                 struct_size;
    const logos_runtime_control_binding_t* runtime_control;
    void*                                  publish_user_data;
    logos_publish_fn                       publish;
    const char*                            state_dir;
    const uint8_t*                         configuration_cbor;
    size_t                                 configuration_cbor_len;
    logos_invocation_access_t              invocation_access;
} logos_module_init_input_t;

/* -- Runtime Control binding and route handle -- */

#define LOGOS_RUNTIME_CONTROL_VTABLE_ABI_VERSION 3u
#define LOGOS_ROUTE_VTABLE_ABI_VERSION 3u

typedef uint64_t logos_subscription_id_t;

typedef void (*logos_event_handler_t)(
    const char*    event_name,
    const uint8_t* cbor_data,
    size_t         cbor_data_len,
    void*          user_data
);

typedef void (*logos_route_end_handler_t)(
    logos_error_code_t reason,
    void* user_data
);

typedef void (*logos_subscription_end_handler_t)(
    logos_subscription_id_t subscription_id,
    logos_error_code_t      reason,
    void*                   user_data
);

struct logos_runtime_control_binding {
    const logos_runtime_control_vtable_t* vtable;
    void*                                 state;
};

struct logos_route_handle {
    const logos_route_vtable_t* vtable;
    void*                       state;
};

struct logos_runtime_control_vtable {
    uint32_t abi_version;
    size_t   struct_size;

    logos_result_t (*call)(
        const logos_runtime_control_binding_t* binding,
        const char*                            method,
        const uint8_t*                         params_cbor,
        size_t                                 params_cbor_len,
        uint8_t**                              out_response_cbor,
        size_t*                                out_response_cbor_len
    );

    void (*release_response)(
        const logos_runtime_control_binding_t* binding,
        uint8_t*                               response_cbor,
        size_t                                 response_cbor_len
    );

    logos_result_t (*subscribe)(
        const logos_runtime_control_binding_t* binding,
        const char*                            event_name,
        logos_event_handler_t                  handler,
        void*                                  user_data,
        logos_subscription_id_t*               out_subscription_id
    );

    logos_result_t (*unsubscribe)(
        const logos_runtime_control_binding_t* binding,
        logos_subscription_id_t                subscription_id
    );

    logos_result_t (*materialize_route)(
        const logos_runtime_control_binding_t* binding,
        const char*                            route_id,
        const uint8_t                          expected_contract_root[32],
        const uint8_t*                         schema_cbor,
        size_t                                 schema_cbor_len,
        logos_route_handle_t*                  out_route
    );

    logos_result_t (*connect_remote)(
        const logos_runtime_control_binding_t* binding,
        const uint8_t*                         endpoint_cbor,
        size_t                                 endpoint_cbor_len,
        const uint8_t                          expected_contract_root[32],
        logos_runtime_control_binding_t*       out_binding
    );

    void (*release)(
        logos_runtime_control_binding_t* binding
    );

    logos_result_t (*prepare_call)(
        const logos_runtime_control_binding_t* binding,
        const char* method,
        const uint8_t* params_cbor,
        size_t params_cbor_len,
        const logos_async_options_t* options,
        const logos_async_callbacks_t* callbacks,
        logos_async_call_t* out_call
    );

    logos_result_t (*observe_subscription_end)(
        const logos_runtime_control_binding_t* binding,
        logos_subscription_end_handler_t       handler,
        void*                                  user_data
    );
};

struct logos_route_vtable {
    uint32_t abi_version;
    size_t   struct_size;

    logos_result_t (*call)(
        logos_route_handle_t* route,
        const char*           method,
        const uint8_t*        params_cbor,
        size_t                params_cbor_len,
        uint8_t**             out_response_cbor,
        size_t*               out_response_cbor_len
    );

    void (*release_response)(
        logos_route_handle_t* route,
        uint8_t*              response_cbor,
        size_t                response_cbor_len
    );

    logos_result_t (*subscribe)(
        logos_route_handle_t*    route,
        const char*              event_name,
        logos_event_handler_t    handler,
        void*                    user_data,
        logos_subscription_id_t* out_subscription_id
    );

    logos_result_t (*unsubscribe)(
        logos_route_handle_t*   route,
        logos_subscription_id_t subscription_id
    );

    void (*release)(logos_route_handle_t* route);

    logos_result_t (*prepare_call)(
        logos_route_handle_t* route,
        const char* method,
        const uint8_t* params_cbor,
        size_t params_cbor_len,
        const logos_async_options_t* options,
        const logos_async_callbacks_t* callbacks,
        logos_async_call_t* out_call
    );

    logos_result_t (*observe_end)(
        logos_route_handle_t* route,
        logos_route_end_handler_t handler,
        void* user_data
    );

    logos_result_t (*observe_subscription_end)(
        logos_route_handle_t*            route,
        logos_subscription_end_handler_t handler,
        void*                            user_data
    );
};

#ifdef __cplusplus
}
#endif

#endif /* LOGOS_TYPES_H */
