/* The typed provider functions of the modules linked into tests/test_kit.nim,
 * taken by the names and prototypes their generated headers declare. Each
 * assignment to its contract typedef (INTERFACE §2.4: the provider symbol has
 * "exactly the typedef's return type and parameters") fails to compile if
 * the two differ. */

#include "typed_harness.h"

void th_linked(th_fns_t* out)
{
    out->meter_read = logos_meter_module_CALL_meter_Read;
    out->sensor_configure = logos_sensor_module_CALL_sensor_NS_control_Configure;
    out->sensor_snapshot = logos_sensor_module_CALL_metrics_provider_Snapshot;
    out->shapes_reflect = logos_shapes_module_CALL_shapes_Reflect;
    out->shapes_pick = logos_shapes_module_CALL_shapes_Pick;
    out->shapes_ping = logos_shapes_module_CALL_shapes_Ping;
}
