## The typed call helpers (INTERFACE §2.7.2, App A.5) of the three kit modules
## in a library of their own, for `tests/test_kit_dylib.nim`: a consumer loads
## it beside the module libraries and calls them through route handles.

{.used.} # built as a library for the C symbols it exports
import ../generated/[meter_module_calls, sensor_module_calls, shapes_module_calls]

exportMeterModuleCalls()
exportSensorModuleCalls()
exportShapesModuleCalls()
