## A confined provider whose `reply` answers pre-encoded bytes (Tier 5 step 5-6a-1;
## DECISIONS G494): the request's `bytes` as they are, unchecked by the module, so
## `test_pm_module` sends what reaches the Module Host's boundary.

{.used.} # imported by the tests for the C symbols it exports
import ../generated/rawreply_module_kit

type RawReply* = ref object

proc initModule(
    _: type RawReply, init: ModuleInit
): Result[RawReply, InvocationFailure] =
  ok(RawReply())

proc destroyModule(m: RawReply) {.async: (raises: []).} =
  discard

proc `reply`(
    m: RawReply, request: RawreplyReplyRequest, inv: Invocation
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ok(preEncoded(request.bytes))

exportRawreplyModule(RawReply)
