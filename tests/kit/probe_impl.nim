## `probe_module`: a consumer-only native module written against the module ABI
## directly (no kit: every kit module is a provider), built as a shared library
## for the Module Host suites (Tier 4b step 4b-3; plan §4.2). The same library
## is realized `direct_dynamic` and `hosted_dynamic`, so a suite can compare
## what the module sees in each placement.
##
## What it does is read at `_MODULE_init` from `<state_dir>/probe.cmd`, one
## command per line (no state directory: nothing). What it observes goes to
## files in the state directory, appended a line at a time:
##
## - `inits`, `destroyed`: one line per `_MODULE_init` and `_MODULE_destroy`;
## - `env`: with `env`, the names of its environment, sorted;
## - `rc`: with `rc <method> <hex params>`, `<code> <hex value or message>`;
## - `events`: with `subscribe <event>`, `<name> <hex data>` per delivery,
##   the code of one `get_readiness` call made from the first handler, and
##   `overlap` if a handler began while another was running;
## - `applied`: one line per `_MODULE_apply_configuration`, its bytes in hex.
##
## `serve` starts a command thread (part 4b-3.3: the probe as a route's
## consumer, in either placement): it runs `<state_dir>/cmd-<n>` (n from 1, one
## command each, written whole by the case) on the probe's own binding and
## route handles, and writes its result to `out-<n>`, `<code> <hex value or
## message>`, with ` detail=<hex>` after a failure's message when it has a
## validation detail:
##
## - `rc <method> <hex params>`;
## - `connect-remote <hex endpoint>`, `connect_remote`'s status (` acquired`
##   after it if a binding came back);
## - `materialize <slot> <route> <hex root> <hex schema>`, the handle in
##   `slot` (0-15);
## - `call <slot> <method> <hex params>`; `call-quiet` the same, except that a
##   failure is answered `<code> message=<length> detail=<length>`, its text
##   never copied (the erasure tests: a provider's failure may quote a
##   marked payload);
## - `subscribe <slot> <event> <tag>` (its id as the value), each delivery
##   appended to `deliveries` as `<tag> <name> <hex data>`;
##   `unsubscribe <slot> <id>`;
## - `observe-end <slot> <tag>`, the end appended to `ends` as
##   `<tag> <code>`;
## - `sub-end <slot or rc> <tag or null>`: `observe_subscription_end` on that
##   route handle or the probe's binding, with a null handler for `null`; a
##   reported end would be appended to `subends` as `<tag> <id> <code>`;
## - `prepare <slot or rc> <call> <method> <hex params> <timeout ms or ->`, on
##   that route handle or the probe's binding, its completion appended to
##   `done` as `<call> <code> <hex value or message>`;
##   `submit <call>`, `cancel <call>`, `release-call <call>`;
## - `release <slot>`.
##
## The thread keeps serving while `_MODULE_destroy` blocks, and is joined
## after.
##
## Other commands: `fail-init` (MODULE_ERROR), `fail-init-context` (a failure
## with a context: no destroy may follow), `ok-null` (LOGOS_OK without a
## context), `block-init` and `block-destroy` (wait until `<state_dir>/go`
## exists), `sub-end-rc <tag>` (`observe_subscription_end` on the binding
## during `_MODULE_init`, reports appended to `subends` as for `sub-end`; its
## result appended to `inits`), `block-handler` (each handler, a route's Event handler included,
## waits until `<state_dir>/go-handler` exists), `block-subend` (each
## subscription-end handler, after its line, waits until `<state_dir>/go-subend`
## exists), `quit-init <n>` (exit from
## module code), `quit-handler` (exit from the first event handler),
## `rc-destroy <method> <hex params>` (a Runtime Control call from
## `_MODULE_destroy`, its result in `rc-destroy`). The four flags
## (`block-destroy`, `block-handler`, `block-subend`, `quit-handler`) take
## effect before every other command, wherever they are in the file.
## `_MODULE_apply_configuration` answers by what its input contains: `reject`
## (a failure status), `bad` (an invalid status), `block` (waits until
## `<state_dir>/go-apply` exists, then OK), `quit` (exits); anything else OK.

{.push raises: [].}

import std/[algorithm, atomics, os, strutils]
import logos_sdk/abi/types
import logos_sdk/codegen/kitrt

type
  Tag = object ## What a route callback reports under, with its probe.
    probe: ptr Probe
    text: array[32, char]
    len: int

  Probe = object ## Plain data in shared memory: entries run on any thread (refc).
    dirBuf: array[1024, char] ## the state directory; empty: none
    dirLen: int
    rc: ptr LogosRuntimeControlBinding
    blockDestroy, blockHandler, blockSubEnd, quitHandler: bool
    handled, inside: Atomic[int]
    serving: Atomic[bool]
    served: bool
    server: Thread[ptr Probe]
    routes: array[16, LogosRouteHandle]
    calls: array[16, LogosAsyncCall]
    tags: array[64, Tag]
    tagCount: int ## only the command thread makes tags
    keptNext: ptr Probe ## in `kept` after `_MODULE_destroy`

var failedContext: int ## a failing init's context: never destroyed

var kept: Atomic[pointer]
  ## The probes whose memory stays after `_MODULE_destroy`, linked through
  ## `keptNext`. This library is never unloaded (the Runtime maps a module
  ## library for the life of its process), so they stay reachable, and
  ## LeakSanitizer does not count kept memory as leaked.

proc dir(p: ptr Probe): string =
  result = newString(p.dirLen)
  for i in 0 ..< p.dirLen:
    result[i] = p.dirBuf[i]

proc note(p: ptr Probe, file, line: string) =
  if p.dirLen == 0:
    return
  try:
    let f = open(p.dir / file, fmAppend)
    f.writeLine(line)
    f.close()
  except IOError, OSError:
    discard

func hex(p: ptr UncheckedArray[uint8], n: csize_t): string =
  for i in 0 ..< int(n):
    result.add(toHex(p[i], 2).toLowerAscii)

func unhex(s: string): seq[byte] =
  ## Made at its final size: a growing copy would release a partial one.
  result = newSeq[byte](s.len div 2)
  var n = 0
  var i = 0
  while i + 1 < s.len:
    try:
      result[n] = byte(parseHexInt(s[i .. i + 1]))
      inc n
    except ValueError:
      discard
    i += 2
  result.setLen(n)

proc waitGo(dir: string, name = "go") =
  while not fileExists(dir / name):
    sleep(5)

proc resultLine(r: LogosResult): string =
  $int64(r.code) & " " & (if r.message == nil: "" else: $r.message)

proc fullLine(r: LogosResult): string =
  ## `resultLine`, then the validation detail's bytes in hex when there are
  ## some (part 4b-3.4: the invariance suite compares them).
  result = resultLine(r)
  if r.detail != nil and r.detailLen > 0:
    result.add(" detail=" & hex(r.detail, r.detailLen))

func ptrOf(b: seq[byte]): ptr UncheckedArray[uint8] =
  if b.len == 0:
    nil
  else:
    cast[ptr UncheckedArray[uint8]](unsafeAddr b[0])

proc rcLine(p: ptr Probe, meth, params: string): string =
  let bytes = unhex(params)
  var outBuf: ptr UncheckedArray[uint8]
  var outLen: csize_t
  let r = p.rc.vtable.call(
    p.rc, cstring(meth), ptrOf(bytes), csize_t(bytes.len), addr outBuf, addr outLen
  )
  if int64(r.code) == 0:
    result = "0 " & hex(outBuf, outLen)
    p.rc.vtable.releaseResponse(p.rc, outBuf, outLen)
  else:
    result = fullLine(r)

proc rcCall(p: ptr Probe, meth, params: string) =
  p.note("rc", p.rcLine(meth, params))

# The command thread (`serve`) ---------------------------------------------------------

proc newTag(p: ptr Probe, text: string): ptr Tag =
  let i = min(p.tagCount, p.tags.high)
  inc p.tagCount
  result = addr p.tags[i]
  result.probe = p
  result.len = min(text.len, result.text.len)
  for k in 0 ..< result.len:
    result.text[k] = text[k]

proc label(t: ptr Tag): string =
  result = newString(t.len)
  for k in 0 ..< t.len:
    result[k] = t.text[k]

proc onRouteEvent(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl.} =
  kitEnter()
  let t = cast[ptr Tag](userData)
  t.probe.note("deliveries", t.label & " " & $name & " " & hex(data, len))
  if t.probe.blockHandler:
    waitGo(t.probe.dir, "go-handler")

proc onRouteEnd(reason: CErrorCode, userData: pointer) {.cdecl.} =
  kitEnter()
  let t = cast[ptr Tag](userData)
  t.probe.note("ends", t.label & " " & $int64(reason))

proc onSubEnd(
    id: LogosSubscriptionId, reason: CErrorCode, userData: pointer
) {.cdecl.} =
  kitEnter()
  let t = cast[ptr Tag](userData)
  t.probe.note("subends", t.label & " " & $id & " " & $int64(reason))
  if t.probe.blockSubEnd:
    waitGo(t.probe.dir, "go-subend")

proc onDone(
    userData: pointer,
    res: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl.} =
  kitEnter()
  let t = cast[ptr Tag](userData)
  let line =
    if int64(res.code) == 0:
      "0 " & hex(response, len)
    else:
      fullLine(res)
  t.probe.note("done", t.label & " " & line)
  if owner.release != nil:
    owner.release(owner.state)

proc command(p: ptr Probe, line: string): string =
  let w = line.splitWhitespace
  if w.len == 0:
    return "bad"
  try:
    case w[0]
    of "rc":
      return p.rcLine(w[1], (if w.len > 2: w[2] else: ""))
    of "connect-remote":
      # [IFC-0939, IFC-0940] The status of `connect_remote` for the endpoint
      # `w[1]`, its validation detail included.
      let endpoint = unhex(w[1])
      var root: ContractRoot
      var acquired = LogosRuntimeControlBinding()
      let r = p.rc.vtable.connectRemote(
        p.rc, ptrOf(endpoint), csize_t(endpoint.len), addr root, addr acquired
      )
      return fullLine(r) & (if acquired.vtable == nil: "" else: " acquired")
    of "materialize":
      let root = unhex(w[3])
      let schema = unhex(w[4])
      var r: ContractRoot
      for i in 0 ..< min(r.len, root.len):
        r[i] = root[i]
      return resultLine(
        p.rc.vtable.materializeRoute(
          p.rc,
          cstring(w[2]),
          addr r,
          ptrOf(schema),
          csize_t(schema.len),
          addr p.routes[parseInt(w[1])],
        )
      )
    of "call", "call-quiet":
      let h = addr p.routes[parseInt(w[1])]
      if h.vtable == nil:
        return "no route" # not materialized: an answer, not a crash
      var params = unhex(
        if w.len > 3:
          w[3]
        else:
          ""
      )
      var outBuf: ptr UncheckedArray[uint8]
      var outLen: csize_t
      let r = h.vtable.call(
        h, cstring(w[2]), ptrOf(params), csize_t(params.len), addr outBuf, addr outLen
      )
      # [DECISIONS I92] The probe's own copy of the request, wiped: the
      # erasure tests scan what a host releases (`test_wipe_routes` W-7).
      wipe(params)
      if int64(r.code) == 0:
        result = "0 " & hex(outBuf, outLen)
        h.vtable.releaseResponse(h, outBuf, outLen)
      elif w[0] == "call-quiet":
        # [DECISIONS G276] A failure whose text may quote a marked payload:
        # only the lengths, read in place, so the probe keeps no copy.
        let n = (if r.message == nil: 0 else: len(r.message))
        result = $int64(r.code) & " message=" & $n & " detail=" & $int(r.detailLen)
      else:
        result = fullLine(r)
      return
    of "subscribe":
      let h = addr p.routes[parseInt(w[1])]
      if h.vtable == nil:
        return "no route"
      var id: LogosSubscriptionId
      let r =
        h.vtable.subscribe(h, cstring(w[2]), onRouteEvent, p.newTag(w[3]), addr id)
      return (if int64(r.code) == 0: "0 " & $id else: fullLine(r))
    of "unsubscribe":
      let h = addr p.routes[parseInt(w[1])]
      if h.vtable == nil:
        return "no route"
      return
        resultLine(h.vtable.unsubscribe(h, LogosSubscriptionId(parseBiggestUInt(w[2]))))
    of "observe-end":
      let h = addr p.routes[parseInt(w[1])]
      if h.vtable == nil:
        return "no route"
      return resultLine(h.vtable.observeEnd(h, onRouteEnd, p.newTag(w[2])))
    of "sub-end":
      let handler: LogosSubscriptionEndHandler = (if w[2] == "null": nil else: onSubEnd)
      if w[1] == "rc":
        return
          resultLine(p.rc.vtable.observeSubscriptionEnd(p.rc, handler, p.newTag(w[2])))
      let h = addr p.routes[parseInt(w[1])]
      if h.vtable == nil:
        return "no route"
      return resultLine(h.vtable.observeSubscriptionEnd(h, handler, p.newTag(w[2])))
    of "prepare":
      var h: ptr LogosRouteHandle = nil
      if w[1] != "rc":
        h = addr p.routes[parseInt(w[1])]
        if h.vtable == nil:
          return "no route"
      var params = unhex(w[4])
      var opts = LogosAsyncOptions(
        abiVersion: AsyncCallAbiVersion,
        structSize: csize_t(sizeof(LogosAsyncOptions)),
        hasTimeout: w[5] != "-",
        timeoutMs: (if w[5] == "-": 0'u64 else: uint64(parseBiggestUInt(w[5]))),
      )
      var cbs = LogosAsyncCallbacks(
        abiVersion: AsyncCallAbiVersion,
        structSize: csize_t(sizeof(LogosAsyncCallbacks)),
        complete: onDone,
        userData: p.newTag(w[2]),
      )
      let r =
        if h == nil:
          p.rc.vtable.prepareCall(
            p.rc,
            cstring(w[3]),
            ptrOf(params),
            csize_t(params.len),
            addr opts,
            addr cbs,
            addr p.calls[parseInt(w[2])],
          )
        else:
          h.vtable.prepareCall(
            h,
            cstring(w[3]),
            ptrOf(params),
            csize_t(params.len),
            addr opts,
            addr cbs,
            addr p.calls[parseInt(w[2])],
          )
      wipe(params) # [DECISIONS I92] the call keeps its own copy
      return resultLine(r)
    of "submit", "cancel", "release-call":
      let c = addr p.calls[parseInt(w[1])]
      if c.vtable == nil:
        return "no call"
      case w[0]
      of "submit":
        c.vtable.submit(c)
      of "cancel":
        c.vtable.cancel(c)
      else:
        c.vtable.release(c)
        c[] = LogosAsyncCall()
      return "0 "
    of "release":
      let h = addr p.routes[parseInt(w[1])]
      if h.vtable == nil:
        return "no route"
      h.vtable.release(h)
      return "0 "
    else:
      return "bad"
  except ValueError, IndexDefect:
    return "bad"

proc serveMain(p: ptr Probe) {.thread.} =
  var n = 1
  while p.serving.load:
    let f = p.dir / ("cmd-" & $n)
    if not fileExists(f):
      sleep(1)
      continue
    var line = ""
    try:
      line = readFile(f).strip
    except IOError, OSError:
      discard
    let res = p.command(line)
    try:
      writeFile(p.dir / ("out-" & $n & ".tmp"), res)
      moveFile(p.dir / ("out-" & $n & ".tmp"), p.dir / ("out-" & $n))
    except Exception:
      discard
    inc n

proc onEvent(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl.} =
  kitEnter()
  let p = cast[ptr Probe](userData)
  if p.inside.fetchAdd(1) != 0:
    p.note("events", "overlap")
  p.note("events", $name & " " & hex(data, len))
  if p.quitHandler:
    quit(3) # [plan S-7] module code ends its host
  if p.handled.fetchAdd(1) == 0:
    # [G178] A handler may call Runtime Control.
    var outBuf: ptr UncheckedArray[uint8]
    var outLen: csize_t
    let empty = [0xA0'u8] # {}
    let r = p.rc.vtable.call(
      p.rc,
      "get_readiness",
      cast[ptr UncheckedArray[uint8]](unsafeAddr empty[0]),
      1,
      addr outBuf,
      addr outLen,
    )
    p.note("events", "rc " & $int64(r.code))
    if int64(r.code) == 0:
      p.rc.vtable.releaseResponse(p.rc, outBuf, outLen)
  if p.blockHandler:
    waitGo(p.dir, "go-handler")
  discard p.inside.fetchSub(1)

proc probeName(): cstring {.exportc: "logos_probe_module_MODULE_name", dynlib, cdecl.} =
  "probe_module"

proc probeInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.exportc: "logos_probe_module_MODULE_init", dynlib, cdecl.} =
  kitEnter()
  let p = cast[ptr Probe](allocShared0(sizeof(Probe)))
  if input.stateDir != nil:
    let d = $input.stateDir
    p.dirLen = min(d.len, p.dirBuf.len)
    for i in 0 ..< p.dirLen:
      p.dirBuf[i] = d[i]
  p.rc = input.runtimeControl
  p.note("inits", "init")
  var commands: seq[string]
  if p.dir.len > 0:
    try:
      commands = readFile(p.dir / "probe.cmd").splitLines
    except IOError, OSError:
      discard
  # [SPEC INTERFACE l.1397-1398] The flags the handlers and destroy read are set
  # before any other command: once a subscription is active another thread may
  # run its handler, even before `subscribe` returns and while this init still
  # runs (a data race under ThreadSanitizer, CI run 44991040073 on fef0991).
  for c in commands:
    let w = c.splitWhitespace
    if w.len == 0:
      continue
    case w[0]
    of "block-destroy":
      p.blockDestroy = true
    of "block-handler":
      p.blockHandler = true
    of "block-subend":
      p.blockSubEnd = true
    of "quit-handler":
      p.quitHandler = true
    else:
      discard
  for c in commands:
    let w = c.splitWhitespace
    if w.len == 0:
      continue
    case w[0]
    of "fail-init":
      result.code = CErrorCode(ord(ecModule))
      result.message = "the probe refused to start"
      return
    of "fail-init-context":
      outContext[] = cast[ptr LogosModuleContext](addr failedContext)
      result.code = CErrorCode(ord(ecModule))
      result.message = "the probe refused to start"
      return
    of "ok-null":
      return
    of "block-init":
      waitGo(p.dir)
    of "block-destroy", "block-handler", "block-subend", "quit-handler":
      discard # set above
    of "quit-init":
      quit(
        if w.len > 1:
          (
            try:
              parseInt(w[1])
            except ValueError:
              3
          )
        else:
          3
      )
    of "env":
      var names: seq[string]
      for k, _ in envPairs():
        names.add(k)
      names.sort()
      for n in names:
        p.note("env", n)
    of "rc":
      p.rcCall(w[1], (if w.len > 2: w[2] else: ""))
    of "subscribe":
      var id: LogosSubscriptionId
      let r = p.rc.vtable.subscribe(p.rc, cstring(w[1]), onEvent, p, addr id)
      p.note("events", "subscribed " & resultLine(r))
    of "sub-end-rc":
      # Before `serve`, so the command thread is not making tags yet.
      let r = p.rc.vtable.observeSubscriptionEnd(p.rc, onSubEnd, p.newTag(w[1]))
      p.note("inits", "sub-end-rc " & resultLine(r))
    of "serve":
      p.serving.store(true)
      try:
        createThread(p.server, serveMain, p)
        p.served = true
      except ResourceExhaustedError:
        p.serving.store(false)
    else:
      discard
  outContext[] = cast[ptr LogosModuleContext](p)

proc probeDestroy(
    module: ptr LogosModuleContext
) {.exportc: "logos_probe_module_MODULE_destroy", dynlib, cdecl.} =
  kitEnter()
  if module == cast[ptr LogosModuleContext](addr failedContext):
    return
  let p = cast[ptr Probe](module)
  if p.blockDestroy:
    waitGo(p.dir)
  if p.served:
    p.serving.store(false)
    joinThread(p.server)
    p.served = false
  var commands: seq[string]
  try:
    commands = readFile(p.dir / "probe.cmd").splitLines
  except IOError, OSError:
    discard
  for c in commands:
    let w = c.splitWhitespace
    if w.len > 1 and w[0] == "rc-destroy":
      let before = p.dir / "rc"
      p.rcCall(w[1], (if w.len > 2: w[2] else: ""))
      # The result went to `rc`; it is moved to `rc-destroy`.
      try:
        let all = readFile(before).splitLines
        var last = ""
        for l in all:
          if l.len > 0:
            last = l
        p.note("rc-destroy", last)
      except IOError, OSError:
        discard
  p.note("destroyed", "destroyed")
  # Freed when nothing can reach it any more: no handler of a subscription is
  # inside (the Runtime destroys a context only once its handlers have
  # returned, INTERFACE l.1465, l.1999) and no route callback holds one of its
  # tags. A probe that made tags keeps its memory, in `kept`: its commands
  # need not release the handles their callbacks were registered on before
  # this returns (INTERFACE l.3860 asks a module to), so the Runtime may still
  # hold pointers into it. A direct probe's memory is the test process's.
  if p.inside.load == 0 and p.tagCount == 0:
    deallocShared(p)
  else:
    var head = kept.load
    while true:
      p.keptNext = cast[ptr Probe](head)
      if kept.compareExchangeWeak(head, p):
        break

proc probeApply(
    module: ptr LogosModuleContext, cbor: ptr UncheckedArray[uint8], len: csize_t
): LogosResult {.
    exportc: "logos_probe_module_MODULE_apply_configuration", dynlib, cdecl
.} =
  kitEnter()
  let p = cast[ptr Probe](module)
  p.note("applied", hex(cbor, len))
  var text = newString(int(len))
  for i in 0 ..< int(len):
    text[i] = char(cbor[i])
  if "reject" in text:
    result.code = CErrorCode(ord(ecInvalidParams))
    result.message = "the probe rejects it"
  elif "bad" in text:
    result.code = CErrorCode(0)
    result.message = "an OK status with a message"
  elif "block" in text:
    waitGo(p.dir, "go-apply")
  elif "quit" in text:
    quit(3) # [plan S-13] module code ends its host in its hook
