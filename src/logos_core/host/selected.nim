## The contracts a hosted provider's sessions may select, as its Module Host
## checks payloads under them (Tier 4b step 4b-3, part 4b-3.2; plan §2.7
## [Rev R14]; RUN-0815) [IMPL].
##
## Each is built from the module's own call surface, filtered to one selected
## root (`schemaResponse`), with the payload depth `init` carried, the same
## construction input and the same checks (`runtime/callcheck.nim`) as the
## Runtime's for a direct provider. The inputs are kept once, on the shared
## heap, when the endpoint starts; each thread rebuilds a contract from them on
## first use and drops it with its other tables (`releasePerThread`).

{.push raises: [], gcsafe.}

import std/tables
import results
import logos_sdk/abi/cstatus
import logos_sdk/cbor
import logos_sdk/base/perthread
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, outcome, payload, surface]
import ../runtime/callcheck

export callcheck

type
  Input = object
    root: Digest
    schema: ptr UncheckedArray[byte] ## the construction input
    schemaLen: int
    answer: ptr UncheckedArray[byte]
      ## `logos.schema`'s answer, as the host's loop builds it (TRANSPORT §8.1)
    answerLen: int

  Inputs = object
    depth: int
    count: int
    items: ptr UncheckedArray[Input]

var inputs: ptr Inputs ## written once, before the endpoint serves

var
  cache {.threadvar.}: Table[Digest, Selected]
  hooked {.threadvar.}: bool

proc dropCache() {.nimcall, gcsafe, raises: [].} =
  cache = default(Table[Digest, Selected])
  hooked = false

proc copyShared(b: openArray[byte]): ptr UncheckedArray[byte] =
  result = cast[ptr UncheckedArray[byte]](allocShared(max(b.len, 1)))
  for i, x in b:
    result[i] = x

proc keepContracts*(
    binding: ModuleBinding, roots: openArray[Digest], served: ContractSet, depth: int
): Result[void, string] =
  ## Lifecycle thread, before the loop serves: every contract a session may
  ## select (`roots`), and the answer the loop gives to `logos.schema` under
  ## each from the set it serves (`served`).
  let p = createShared(Inputs)
  p.depth = depth
  p.items =
    cast[ptr UncheckedArray[Input]](allocShared0(max(roots.len, 1) * sizeof(Input)))
  for i, root in roots:
    let schema = encodeCbor(?schemaResponse(binding, root))
    let answer = encodeCbor(?schemaResponse(served, root))
    discard ?buildSelected(schema, root, depth) # checked once here
    p.items[i] = Input(
      root: root,
      schema: copyShared(schema),
      schemaLen: schema.len,
      answer: copyShared(answer),
      answerLen: answer.len,
    )
    p.count = i + 1
  inputs = p
  ok()

proc inputOf(root: Digest): ptr Input =
  if inputs == nil:
    return nil
  for i in 0 ..< inputs.count:
    if inputs.items[i].root == root:
      return addr inputs.items[i]
  nil

proc selectedFor*(root: Digest): Result[Selected, string] =
  ## This thread's copy of the contract `root`; an error for one the module
  ## does not provide.
  if not hooked:
    hooked = true
    onThreadRelease(dropCache)
  if root in cache:
    try:
      return ok(cache[root])
    except KeyError:
      discard
  let x = inputOf(root)
  if x == nil:
    return err("the module provides no contract with the selected root")
  let s = ?buildSelected(x.schema.toOpenArray(0, x.schemaLen - 1), root, inputs.depth)
  cache[root] = s
  ok(s)

proc keepProvider*(c: ModuleBinding, system: bool, depth: int): Result[void, string] =
  ## [SPEC INTERFACE l.3351; DECISIONS I106] Lifecycle thread, before
  ## `_MODULE_init`: the provider's contracts (its primary, then each
  ## implemented interface), for its publications and, once it serves, its
  ## sessions; `logos.schema` answers from the set built from the first.
  var roots: seq[Digest]
  if c.primary.isSome:
    roots.add(c.primary.get.root)
  for i in c.interfaces:
    roots.add(i.root)
  if roots.len == 0:
    return err("the provider has no contract")
  let input = encodeCbor(?schemaResponse(c, roots[0]))
  let served = ?acceptSchemaResponse(input, roots[0], AcceptOptions(system: system))
  keepContracts(c, roots, served, depth)

proc publishedBy*(
    name: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE l.3351, l.1712-1717; DECISIONS I106] As
  ## `callside.publishedBy`, under the contracts `keepProvider` kept: a
  ## module that kept none declares no event.
  if inputs != nil:
    for i in 0 ..< inputs.count:
      let sel = selectedFor(inputs.items[i].root).valueOr:
        return
          err(failure(ecInvalidParams, "the publisher's contract cannot be loaded"))
      if sel.boundary.knowsEvent(name):
        discard sel.validator.checkEvent(name, data).valueOr:
          let f = toFailure(error)
          return
            err(failure(ecInvalidParams, f.message.get("the event data is invalid")))
        return ok()
  err(failure(ecInvalidParams, name & " is not declared by the publisher's contracts"))

proc schemaAnswer*(root: Digest): seq[byte] =
  ## `logos.schema`'s answer under `root`; empty for an unknown root.
  let x = inputOf(root)
  if x == nil:
    return
  result = newSeq[byte](x.answerLen)
  for i in 0 ..< x.answerLen:
    result[i] = x.answer[i]
