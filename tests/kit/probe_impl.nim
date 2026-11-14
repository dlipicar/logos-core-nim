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
## Other commands: `fail-init` (MODULE_ERROR), `fail-init-context` (a failure
## with a context: no destroy may follow), `ok-null` (LOGOS_OK without a
## context), `block-init` and `block-destroy` (wait until `<state_dir>/go`
## exists), `block-handler` (each handler waits until `<state_dir>/go-handler`
## exists), `quit-init <n>` (exit from module code). `_MODULE_apply_configuration`
## answers its input: `ok`, `reject` (a failure status) or `bad` (an invalid
## status).

{.push raises: [].}

import std/[algorithm, atomics, os, strutils]
import ../../src/logos_core/abi/types
import ../../src/logos_core/codegen/kitrt

type Probe = object ## Plain data in shared memory: entries run on any thread (refc).
  dirBuf: array[1024, char] ## the state directory; empty: none
  dirLen: int
  rc: ptr LogosRuntimeControlBinding
  blockDestroy, blockHandler: bool
  handled, inside: Atomic[int]

var failedContext: int ## a failing init's context: never destroyed

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
  var i = 0
  while i + 1 < s.len:
    try:
      result.add(byte(parseHexInt(s[i .. i + 1])))
    except ValueError:
      discard
    i += 2

proc waitGo(dir: string, name = "go") =
  while not fileExists(dir / name):
    sleep(5)

proc resultLine(r: LogosResult): string =
  $int64(r.code) & " " & (if r.message == nil: "" else: $r.message)

proc rcCall(p: ptr Probe, meth, params: string) =
  let bytes = unhex(params)
  var outBuf: ptr UncheckedArray[uint8]
  var outLen: csize_t
  let r = p.rc.vtable.call(
    p.rc,
    cstring(meth),
    (if bytes.len == 0: nil
    else: cast[ptr UncheckedArray[uint8]](unsafeAddr bytes[0])),
    csize_t(bytes.len),
    addr outBuf,
    addr outLen,
  )
  if int64(r.code) == 0:
    p.note("rc", "0 " & hex(outBuf, outLen))
    p.rc.vtable.releaseResponse(p.rc, outBuf, outLen)
  else:
    p.note("rc", resultLine(r))

proc onEvent(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl.} =
  kitEnter()
  let p = cast[ptr Probe](userData)
  if p.inside.fetchAdd(1) != 0:
    p.note("events", "overlap")
  p.note("events", $name & " " & hex(data, len))
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
    of "block-destroy":
      p.blockDestroy = true
    of "block-handler":
      p.blockHandler = true
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
  p.note("destroyed", "destroyed")
  # The probe's memory stays: a handler of a subscription may still be ending.

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
  case text
  of "reject":
    result.code = CErrorCode(ord(ecInvalidParams))
    result.message = "the probe rejects it"
  of "bad":
    result.code = CErrorCode(0)
    result.message = "an OK status with a message"
  else:
    discard
