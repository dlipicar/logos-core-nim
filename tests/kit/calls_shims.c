/* The typed call helpers (INTERFACE §2.7.2, App A.5) in the typed harness's
 * slots, for tests/test_calls.nim (linked helpers) and tests/test_kit_dylib.nim
 * (helpers found by dlsym). Each shim has the provider function's type, takes
 * the route handle where the harness passes a module context, and calls the
 * helper the table holds: the harness then drives a helper exactly as it
 * drives a provider function. */

#include <string.h>

#include "typed_harness.h"

static th_helpers_t helpers; /* set once, before any call */

static logos_route_handle_t* route_of(logos_module_context_t* m)
{
    return (logos_route_handle_t*)(void*)m;
}

static logos_result_t via_meter_read(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    uint32_t in_channel,
    logos_tstr_size_1_64_t* out_label,
    logos_meter_Reading_t* out_reading)
{
    return helpers.meter_read(route_of(module), response_owner, in_channel, out_label, out_reading);
}

static logos_result_t via_sensor_configure(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    const logos_sensor_NS_control_Settings_t* in_settings)
{
    return helpers.sensor_configure(route_of(module), response_owner, in_settings);
}

static logos_result_t via_sensor_snapshot(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    uint64_t* out_count)
{
    return helpers.sensor_snapshot(route_of(module), response_owner, out_count);
}

static logos_result_t via_shapes_reflect(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    uint64_t in_a,
    int64_t in_b,
    const char* in_c,
    const uint8_t (*in_d)[32],
    const logos_shapes_Reflect_request_E_LI_t* in_e,
    size_t in_e_count,
    const logos_shapes_Reflect_request_F_LI_t* in_f,
    size_t in_f_count,
    const logos_shapes_Reflect_request_G_t* in_g,
    bool in_has_h,
    uint64_t in_h_0,
    const logos_shapes_Reflect_request_H_TU1_t* in_h_1,
    const logos_schema_commitment_t* in_i,
    const logos_tuple_size_0_t* in_j,
    const logos_bstr_size_0_t* in_l,
    int8_t in_m,
    uint16_t in_n,
    logos_shapes_Counter_t in_o,
    logos_error_code_t in_p,
    bool in_has_q,
    const logos_error_detail_t* in_q,
    const logos_shapes_Names_t* in_r,
    const uint8_t* in_s,
    size_t in_s_len,
    const logos_shapes_Entry_t* in_t,
    size_t in_t_count,
    const logos_shapes_Tree_t* in_u,
    const logos_shapes_Reflect_request_V_t* in_v,
    const logos_shapes_Blob_t* in_y,
    const logos_shapes_Digest_t* in_z,
    uint64_t* out_a,
    int64_t* out_b,
    const char** out_c,
    uint8_t (*out_d)[32],
    logos_shapes_Reflect_response_E_LI_t** out_e,
    size_t* out_e_count,
    logos_shapes_Reflect_response_F_LI_t** out_f,
    size_t* out_f_count,
    logos_shapes_Reflect_response_G_t* out_g,
    bool* out_has_h,
    uint64_t* out_h_0,
    logos_shapes_Reflect_response_H_TU1_t* out_h_1,
    logos_schema_commitment_t* out_i,
    logos_tuple_size_0_t* out_j,
    logos_bstr_size_0_t* out_l,
    int8_t* out_m,
    uint16_t* out_n,
    logos_shapes_Counter_t* out_o,
    logos_error_code_t* out_p,
    bool* out_has_q,
    logos_error_detail_t* out_q,
    logos_shapes_Names_t* out_r,
    const uint8_t** out_s,
    size_t* out_s_len,
    logos_shapes_Entry_t** out_t,
    size_t* out_t_count,
    logos_shapes_Tree_t* out_u,
    logos_shapes_Reflect_response_V_t* out_v,
    logos_shapes_Blob_t* out_y,
    logos_shapes_Digest_t* out_z)
{
    return helpers.shapes_reflect(route_of(module), response_owner, in_a, in_b, in_c, in_d, in_e, in_e_count, in_f, in_f_count, in_g, in_has_h, in_h_0, in_h_1, in_i, in_j, in_l, in_m, in_n, in_o, in_p, in_has_q, in_q, in_r, in_s, in_s_len, in_t, in_t_count, in_u, in_v, in_y, in_z, out_a, out_b, out_c, out_d, out_e, out_e_count, out_f, out_f_count, out_g, out_has_h, out_h_0, out_h_1, out_i, out_j, out_l, out_m, out_n, out_o, out_p, out_has_q, out_q, out_r, out_s, out_s_len, out_t, out_t_count, out_u, out_v, out_y, out_z);
}

static logos_result_t via_shapes_pick(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    const logos_shapes_Pick_request_t* in_request,
    logos_shapes_Pick_response_t* out_response)
{
    return helpers.shapes_pick(route_of(module), response_owner, in_request, out_response);
}

static logos_result_t via_shapes_ping(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner)
{
    return helpers.shapes_ping(route_of(module), response_owner);
}

void th_use_helpers(const th_helpers_t* h, th_fns_t* out)
{
    helpers = *h;
    memset(out, 0, sizeof *out);
    out->meter_read = via_meter_read;
    out->sensor_configure = via_sensor_configure;
    out->sensor_snapshot = via_sensor_snapshot;
    out->shapes_reflect = via_shapes_reflect;
    out->shapes_pick = via_shapes_pick;
    out->shapes_ping = via_shapes_ping;
    out->meter_read_clear = h->meter_read_clear;
    out->shapes_reflect_clear = h->shapes_reflect_clear;
    out->shapes_pick_clear = h->shapes_pick_clear;
    out->shapes_ping_clear = h->shapes_ping_clear;
}
