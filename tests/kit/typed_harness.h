/* The typed-call harness's C declarations (tests/kit/typed_harness.c). Only
 * the harness's C files include this; the Nim tests mirror th_fns_t and
 * th_report_t (and th_helpers_t) and check their sizes against th_sizes().
 * The call helpers' headers are included for their _fn typedefs only: the
 * harness calls what th_fns_t and th_helpers_t hold. */

#ifndef TYPED_HARNESS_H
#define TYPED_HARNESS_H

#include "../generated/meter_module_types.h"
#include "../generated/sensor_module_types.h"
#include "../generated/shapes_module_types.h"
#include "../generated/meter_module_calls.h"
#include "../generated/sensor_module_calls.h"
#include "../generated/shapes_module_calls.h"

/* The provider functions under test, as the header typedefs type them. */
typedef struct {
    logos_meter_Read_FN_t meter_read;
    logos_sensor_NS_control_Configure_FN_t sensor_configure;
    logos_metrics_provider_Snapshot_FN_t sensor_snapshot;
    logos_shapes_Reflect_FN_t shapes_reflect;
    logos_shapes_Pick_FN_t shapes_pick;
    logos_shapes_Ping_FN_t shapes_ping;
    /* The typed cleanup helpers paired with them (INTERFACE §2.7.2): set only
     * when the slots above hold call helpers (tests/kit/calls_shims.c). */
    lcn_clear_meter_Read_fn meter_read_clear;
    lcn_clear_shapes_Reflect_fn shapes_reflect_clear;
    lcn_clear_shapes_Pick_fn shapes_pick_clear;
    lcn_clear_shapes_Ping_fn shapes_ping_clear;
} th_fns_t;

/* The typed call helpers under test (INTERFACE §2.7.2, App A.5), as their
 * header types them: linked (tests/kit/calls_linked.c) or found by dlsym. */
typedef struct {
    lcn_invoke_meter_Read_fn meter_read;
    lcn_invoke_sensor_NS_control_Configure_fn sensor_configure;
    lcn_invoke_metrics_provider_Snapshot_fn sensor_snapshot;
    lcn_invoke_shapes_Reflect_fn shapes_reflect;
    lcn_invoke_shapes_Pick_fn shapes_pick;
    lcn_invoke_shapes_Ping_fn shapes_ping;
    lcn_clear_meter_Read_fn meter_read_clear;
    lcn_clear_sensor_NS_control_Configure_fn sensor_configure_clear;
    lcn_clear_metrics_provider_Snapshot_fn sensor_snapshot_clear;
    lcn_clear_shapes_Reflect_fn shapes_reflect_clear;
    lcn_clear_shapes_Pick_fn shapes_pick_clear;
    lcn_clear_shapes_Ping_fn shapes_ping_clear;
} th_helpers_t;

#define TH_TEXT 32768

/* What one call left: the result and the owner as returned (the owner is not
 * cleared), and the outputs read as text. */
typedef struct {
    logos_result_t result;
    logos_response_owner_t owner;
    int untouched; /* the owner and every output object are still all zero */
    int complete;  /* every output pointer a success must set is non-null */
    int same;      /* reflect: the outputs read back exactly as the inputs */
    char text[TH_TEXT];
} th_report_t;

/* The variants of th_shapes_reflect. */
enum {
    TH_REFLECT_FULL = 0,        /* every member present and nonempty, in_g a text */
    TH_REFLECT_NULL_TEXT,       /* in_c is NULL */
    TH_REFLECT_BAD_KIND,        /* in_g's discriminant names no arm */
    TH_REFLECT_NULL_LIST,       /* in_e is NULL with a count of 2 */
    TH_REFLECT_BAD_UTF8,        /* in_c is not UTF-8 */
    TH_REFLECT_LONG_NAME,       /* an in_r item over its 8-byte bound */
    TH_REFLECT_WRONG_LITERAL,   /* in_a is 8, not the literal 7 */
    TH_REFLECT_CYCLE,           /* in_u lists itself as its own kid */
    TH_REFLECT_FAILS,           /* in_b 13: the handler fails */
    TH_REFLECT_BAD_RESPONSE,    /* in_b 14: the handler's response breaks its schema */
    TH_REFLECT_DEEP,            /* in_u is a chain of 100 left trees, in_g a bool */
    TH_REFLECT_NULL_ARRAY,      /* in_d is NULL */
    TH_REFLECT_NULL_BYTES,      /* in_q's data is NULL with a length of 1 */
    TH_REFLECT_ABSENT,          /* every optional absent, its value pointer NULL; in_g [5] */
    TH_REFLECT_EMPTY,           /* every list and unbounded bstr empty, pointers NULL;
                                   in_g [3, 4] */
    TH_REFLECT_NULL_RECURSIVE,  /* in_u has a twin with a NULL pointer */
    TH_REFLECT_BAD_CODE,        /* in_p is 99, not an error code */
    TH_REFLECT_NULL_OUTPUT,     /* out_u is NULL */
    TH_REFLECT_NULL_STRUCT,     /* in_u is NULL */
    TH_REFLECT_TOO_DEEP,        /* in_u nests one level past the payload depth limit */
    TH_REFLECT_NULL_OWNER,      /* response_owner is NULL */
    TH_REFLECT_NUMBERS,         /* integer bounds, in_g the uint64 arm */
    TH_REFLECT_DEEPEST,         /* in_u nests to exactly the payload depth limit */
    TH_REFLECT_BAD_ENTRY,       /* an in_t entry's discriminant names no arm */
    TH_REFLECT_VARIANTS
};

/* The variants of th_shapes_pick. */
enum {
    TH_PICK_ID = 0,      /* by id 5 */
    TH_PICK_MISSING,     /* by id 0 */
    TH_PICK_NAME,        /* by name "nm" */
    TH_PICK_BAD_KIND,    /* a discriminant that names no arm */
    TH_PICK_NULL,        /* in_request is NULL */
    TH_PICK_WRONG_TAG,   /* the id arm with by = "name" */
    TH_PICK_VARIANTS
};

/* The calls th_typed_clear makes before it cleans up. */
enum {
    TH_CLEAR_READ = 0, /* meter read, channel 4: a text and a struct with a text */
    TH_CLEAR_REFLECT,  /* the full reflect: every shape */
    TH_CLEAR_PICK,     /* pick by name: a choice holding lists */
    TH_CLEAR_PING,     /* ping: the owner only */
    TH_CLEAR_VARIANTS
};

void th_sizes(size_t* fns, size_t* report, size_t* text, size_t* helpers);
void th_use_helpers(const th_helpers_t* helpers, th_fns_t* out);
void th_linked_helpers(th_helpers_t* out);
void th_linked(th_fns_t* out);

void th_meter_read(const th_fns_t* f, logos_module_context_t* m, uint32_t channel,
                   th_report_t* rep);
void th_sensor_configure(const th_fns_t* f, logos_module_context_t* m,
                         const char* kind, uint64_t limit, th_report_t* rep);
void th_sensor_snapshot(const th_fns_t* f, logos_module_context_t* m, th_report_t* rep);
void th_shapes_reflect(const th_fns_t* f, logos_module_context_t* m, int variant,
                       th_report_t* rep);
int th_shapes_reflect_on_stack(const th_fns_t* f, logos_module_context_t* m,
                               int variant, size_t stack, th_report_t* rep);
void th_shapes_reflect_cleared(const th_fns_t* f, logos_module_context_t* m,
                               th_report_t* rep);
void th_shapes_pick(const th_fns_t* f, logos_module_context_t* m, int variant,
                    th_report_t* rep);
void th_shapes_ping(const th_fns_t* f, logos_module_context_t* m, th_report_t* rep);
void th_typed_clear(const th_fns_t* f, logos_module_context_t* m, int which,
                    th_report_t* rep);

#endif
