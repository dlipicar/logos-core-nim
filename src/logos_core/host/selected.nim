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
import ../cbor
import ../base/perthread
import ../hash/hashinput
import ../iface/[accept, surface]
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

proc schemaAnswer*(root: Digest): seq[byte] =
  ## `logos.schema`'s answer under `root`; empty for an unknown root.
  let x = inputOf(root)
  if x == nil:
    return
  result = newSeq[byte](x.answerLen)
  for i in 0 ..< x.answerLen:
    result[i] = x.answer[i]
