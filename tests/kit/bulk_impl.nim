## A native module written with the lcn-gen kit for `bulk_module`
## (`tests/kit/bulk_module.cddl`): `send` publishes `bulk.carried_event` with
## `size` zero bytes, then answers with the size (step 4b-2c; DECISIONS G165).

{.used.} # imported by the tests for the C symbols it exports
import ../generated/bulk_module_kit

type Bulk* = ref object
  services*: ModuleServices

proc initModule(_: type Bulk, init: ModuleInit): Result[Bulk, InvocationFailure] =
  ok(Bulk(services: init.services))

proc send(
    b: Bulk, request: BulkSendRequest
): Result[BulkSendResponse, InvocationFailure] =
  ?b.services.publish(BulkCarriedEvent(data: newSeq[byte](int(request.size))))
  ok(BulkSendResponse(size: request.size))

exportBulkModule(Bulk)
