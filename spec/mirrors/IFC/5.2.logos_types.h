#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

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

/* -- Result type -- */

#define LOGOS_ERROR_MESSAGE_MAX_LEN 512u
#define LOGOS_ERROR_DETAIL_MAX_LEN 4096u

typedef struct {
    logos_error_code_t  code;
    const char*         message;      /* human-readable; may be NULL */
    const uint8_t*      detail;       /* optional encoded detail; may be NULL */
    size_t              detail_len;
} logos_result_t;

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

#define LOGOS_MODULE_INIT_ABI_VERSION 1u

typedef void (*logos_publish_fn)(
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
} logos_module_init_input_t;

/* -- Runtime Control binding and route handle -- */

#define LOGOS_RUNTIME_CONTROL_VTABLE_ABI_VERSION 1u
#define LOGOS_ROUTE_VTABLE_ABI_VERSION 1u

typedef uint64_t logos_subscription_id_t;

typedef void (*logos_event_handler_t)(
    const char*    event_name,
    const uint8_t* cbor_data,
    size_t         cbor_data_len,
    void*          user_data
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
};

/* -- Memory management -- */

void logos_<module>_free(logos_module_context_t* module, void* ptr);
