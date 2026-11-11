/* The typed call helpers this program links, by their header names, for
 * tests/test_calls.nim. Assigning each to its _fn member checks the generated
 * typedef against the helper's prototype. */

#include "typed_harness.h"

void th_linked_helpers(th_helpers_t* out)
{
    out->meter_read = lcn_invoke_meter_Read;
    out->sensor_configure = lcn_invoke_sensor_NS_control_Configure;
    out->sensor_snapshot = lcn_invoke_metrics_provider_Snapshot;
    out->shapes_reflect = lcn_invoke_shapes_Reflect;
    out->shapes_pick = lcn_invoke_shapes_Pick;
    out->shapes_ping = lcn_invoke_shapes_Ping;
    out->meter_read_clear = lcn_clear_meter_Read;
    out->sensor_configure_clear = lcn_clear_sensor_NS_control_Configure;
    out->sensor_snapshot_clear = lcn_clear_metrics_provider_Snapshot;
    out->shapes_reflect_clear = lcn_clear_shapes_Reflect;
    out->shapes_pick_clear = lcn_clear_shapes_Pick;
    out->shapes_ping_clear = lcn_clear_shapes_Ping;
}
