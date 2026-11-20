## The contracts a hosted provider's sessions may select, as its Module Host
## checks payloads under them (Tier 4b step 4b-3, part 4b-3.2; plan §2.7
## [Rev R14]; RUN-0815) [IMPL].
##
## Each is built from the module's own call surface, filtered to one selected
## root (`schemaResponse`), with the payload depth `init` carried, the same
## construction input and the same checks (`runtime/callcheck.nim`) as the
## Runtime's for a direct provider. The inputs are kept once, on the shared
## heap, when the endpoint starts; each thread rebuilds a contract from them on
## first use and drops it with its other tables (`releasePerThread`). An
## earlier contract the module extends (re-pin P8b; DECISIONS G394) is built on
## its first use from the kept call surface, then kept.

{.push raises: [], gcsafe.}

import std/[locks, tables]
import results
import logos_sdk/abi/cstatus
import logos_sdk/cbor
import logos_sdk/base/perthread
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, outcome, payload, provider, surface]
import ../runtime/[callcheck, servedroots]
import ../transport/io/api

export callcheck

type
  Input = object
    root: Digest
    schema: ptr UncheckedArray[byte]
      ## the construction input; for an earlier contract, nil until its first
      ## use (`built`)
    schemaLen: int
    answer: ptr UncheckedArray[byte]
      ## `logos.schema`'s answer, as the host's loop builds it (TRANSPORT §8.1)
    answerLen: int
    earlier: bool
      ## [G394] an earlier contract the module extends: its construction input
      ## is its own answer, and it adds no publication contract (r16)
    failed: bool ## an earlier contract whose input could not be built

  Inputs = object
    depth: int
    system: bool
    count: int
    items: ptr UncheckedArray[Input]
    lock: Lock ## held while an earlier contract's input is first built
    surface: ptr UncheckedArray[byte] ## the call surface the binding came from
    surfaceLen: int
    module: ptr UncheckedArray[byte]
    moduleLen: int
    opts: AcceptOptions ## what the binding was accepted with

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
    binding: ModuleBinding,
    roots: openArray[Digest],
    served: ContractSet,
    depth: int,
    system = false,
    surface: openArray[byte] = [],
    opts = AcceptOptions(),
): Result[void, string] =
  ## Lifecycle thread, before the loop serves: every contract a session may
  ## select (`roots`), and the answer the loop gives to `logos.schema` under
  ## each from the set it serves (`served`). [G394; synthesis §3] An earlier
  ## contract's input is not built here: `surface`, the call surface
  ## `binding` was accepted from with `opts`, is kept, and `built` makes the
  ## input on its first use, so the cost follows the views consumers select.
  let p = createShared(Inputs)
  p.depth = depth
  p.system = system
  p.opts = opts
  initLock(p.lock)
  p.surface = copyShared(surface)
  p.surfaceLen = surface.len
  p.module = copyShared(binding.module.toOpenArrayByte(0, binding.module.high))
  p.moduleLen = binding.module.len
  p.items =
    cast[ptr UncheckedArray[Input]](allocShared0(max(roots.len, 1) * sizeof(Input)))
  for i, root in roots:
    if binding.isEarlier(root):
      p.items[i] = Input(root: root, earlier: true)
      p.count = i + 1
      continue
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

proc earlierSchema(root: Digest): Result[seq[byte], string] =
  ## The construction input of earlier contract `root`, from the kept call
  ## surface (`servedroots.earlierInput`, with its 8 MiB check).
  var module = newString(inputs.moduleLen)
  for i in 0 ..< inputs.moduleLen:
    module[i] = char(inputs.module[i])
  let b = ?acceptCallSurfaceDescriptor(
    inputs.surface.toOpenArray(0, inputs.surfaceLen - 1), module, inputs.opts
  )
  let input = ?earlierInput(b, root)
  discard ?buildSelected(input.schema, root, inputs.depth)
  ok(input.schema)

proc built(x: ptr Input): bool =
  ## [G394; INTERFACE l.3243-3244] Whether `x`'s input is there: an earlier
  ## contract's is built on its first use (a session's verdict, a call check,
  ## a `logos.schema` answer) and kept; one that cannot be built, such as one
  ## over 8 MiB, is never served.
  if not x.earlier:
    return true
  withLock inputs.lock:
    if x.schema == nil and not x.failed:
      let schema = earlierSchema(x.root)
      if schema.isErr:
        x.failed = true
      else:
        x.schema = copyShared(schema.get)
        x.schemaLen = schema.get.len
        x.answer = x.schema # its own answer (INTERFACE l.203); never freed
        x.answerLen = x.schemaLen
    result = x.schema != nil

proc inputOf(root: Digest): ptr Input =
  ## The kept input under `root`, built if it is an earlier contract's; nil
  ## for a root the module does not provide or whose input cannot be built.
  if inputs == nil:
    return nil
  for i in 0 ..< inputs.count:
    if inputs.items[i].root == root:
      let x = addr inputs.items[i]
      return (if x.built: x else: nil)
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

proc keepProvider*(
    c: ModuleBinding,
    system: bool,
    depth: int,
    surface: openArray[byte] = [],
    opts = AcceptOptions(),
): Result[void, string] =
  ## [SPEC INTERFACE l.3351; DECISIONS I106] Lifecycle thread, before
  ## `_MODULE_init`: the provider's contracts (its primary, each implemented
  ## interface, then each earlier contract it extends: `servedroots`, as the
  ## Runtime's endpoint takes them, G394), for its publications and, once it
  ## serves, its sessions; `logos.schema` answers from the set built from the
  ## first. `surface` and `opts`: the call surface `c` was accepted from.
  let s = ?servedContracts(c)
  let served = ?acceptSchemaResponse(
    s.primary.schema, s.primary.root, AcceptOptions(system: system)
  )
  keepContracts(c, s.roots, served, depth, system, surface, opts)

proc earlierInputOf*(root: Digest): Opt[ContractInput] =
  ## [G394] The construction input of earlier contract `root`, for the loop
  ## to accept when the first session selects it; none for another root, or
  ## for one whose input cannot be built (the session then fails its Hello).
  if inputs == nil:
    return Opt.none(ContractInput)
  let x = inputOf(root)
  if x == nil or not x.earlier:
    return Opt.none(ContractInput)
  var schema = newSeq[byte](x.schemaLen)
  for i in 0 ..< x.schemaLen:
    schema[i] = x.schema[i]
  Opt.some(ContractInput(root: root, schema: schema, system: inputs.system))

proc publishedBy*(
    name: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE l.3351, l.1712-1717; DECISIONS I106] As
  ## `callside.publishedBy`, under the contracts `keepProvider` kept: a
  ## module that kept none declares no event.
  if inputs != nil:
    for i in 0 ..< inputs.count:
      if inputs.items[i].earlier:
        continue # [G394 r16] adds no publication contract
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
