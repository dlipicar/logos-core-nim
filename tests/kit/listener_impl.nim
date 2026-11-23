## A consumer written with lcn-gen's typed helpers (DECISIONS G339; N-1
## sub-part 2), built as a shared library for `tests/test_hosted_routes.nim`.
## Its provider side is the beacon kit (`beacon_module`, one event, no method),
## since every kit module is a provider; what it tests is its consumer side.
##
## `initModule` reads `<state_dir>/listen.cmd`: the meter's contract root and
## construction input in hex, one per line, then optional words. It makes a
## `RouteSet` over its Runtime Control binding (`kit/routes`), opens a route to
## the meter, subscribes to `meter.changed_event` with the generated typed
## `subscribe` and reads channel 21 with the typed `invoke`, which makes the
## meter publish 210. With the word `fail` it then closes the set as after a
## failed initialization and fails MODULE_ERROR. `destroyModule` closes the set.
##
## What it observes goes to files in the state directory, a line at a time:
##
## - `opened`: `<code> <route>` of `openRoute`, then `sub <code>`;
## - `read`: `<code> <label>` of the typed read;
## - `heard`: each typed delivery's value, with the thread's id and `entered`
##   or `unentered`: whether that thread registered with this library's
##   runtime (the probe, DECISIONS G466);
## - `closed`: `<code>` of the set's `close`, at destroy or at the failed init.

{.push raises: [].}

import std/[os, strutils, typedthreads]
import logos_sdk/testing/generated/beacon_module_kit
import logos_sdk/testing/generated/meter_module_calls
import logos_sdk/kit/routes
from logos_sdk/base/entry import threadEntered

type
  Shared = object ## Plain data in shared memory: handlers run on any thread (refc).
    dir: array[1024, char]
    dirLen: int
    set: RouteSet

  Listener* = ref object
    services*: ModuleServices
    shared: ptr Shared

proc dirOf(s: ptr Shared): string =
  result = newString(s.dirLen)
  if s.dirLen > 0:
    copyMem(addr result[0], addr s.dir[0], s.dirLen)

proc note(s: ptr Shared, file, line: string) =
  var f: File
  if open(f, s.dirOf / file, fmAppend):
    try:
      f.write(line & "\n")
    except IOError:
      discard
    f.close()

proc codeOf[T](r: Result[T, InvocationFailure]): int =
  if r.isOk:
    0
  else:
    ord(r.error.code)

proc onHeard(ev: MeterChangedEvent, user: pointer) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let probe = if threadEntered(): " entered" else: " unentered"
    cast[ptr Shared](user).note("heard", $ev.value & " " & $getThreadId() & probe)

proc unhex(s: string): Result[seq[byte], string] =
  try:
    let raw = parseHexStr(s.strip)
    ok(@(raw.toOpenArrayByte(0, raw.high)))
  except ValueError as e:
    err(e.msg)

proc initModule(
    _: type Listener, init: ModuleInit
): Result[Listener, InvocationFailure] =
  let dir = init.stateDir.valueOr:
    return err(failure(ecInvalidParams, "no state directory"))
  let words =
    try:
      readFile(dir / "listen.cmd").splitLines()
    except IOError as e:
      return err(failure(ecInvalidParams, "listen.cmd: " & e.msg))
  if words.len < 2 or dir.len > 1024:
    return err(failure(ecInvalidParams, "listen.cmd: a root and a schema"))
  let rootBytes = unhex(words[0]).valueOr:
    return err(failure(ecInvalidParams, "the root: " & error))
  let schema = unhex(words[1]).valueOr:
    return err(failure(ecInvalidParams, "the schema: " & error))
  if rootBytes.len != 32:
    return err(failure(ecInvalidParams, "the root is not 32 bytes"))
  var root: ContractRoot
  copyMem(addr root[0], unsafeAddr rootBytes[0], 32)
  let s = cast[ptr Shared](allocShared0(sizeof(Shared)))
  s.dirLen = dir.len
  if dir.len > 0:
    copyMem(addr s.dir[0], unsafeAddr dir[0], dir.len)
  let set = newRouteSet(init.services.runtimeControl).valueOr:
    deallocShared(s)
    return err(error)
  s.set = set
  let opened = set.openRoute(root, schema)
  if opened.isErr or opened.get.routes.len != 1 or opened.get.routes[0].handle.isErr:
    s.note("opened", $codeOf(opened) & " -")
  else:
    let o = opened.get.routes[0]
    let h = o.handle.get
    s.note("opened", "0 " & o.record.route)
    let sub = h.subscribe(MeterChangedEvent, onHeard, nil, nil, s)
    s.note("opened", "sub " & $codeOf(sub))
    let r = h.invoke(MeterReadRequest(channel: 21))
    s.note("read", $codeOf(r) & " " & (if r.isOk: r.get.label else: "-"))
  if "fail" in words[2 .. ^1]:
    s.note("closed", $codeOf(set.close(initFailed = true)))
    deallocShared(s)
    return err(moduleError("listen.cmd asked the initialization to fail"))
  ok(Listener(services: init.services, shared: s))

proc destroyModule(m: Listener) =
  let s = m.shared
  s.note("closed", $codeOf(s.set.close()))
  deallocShared(s)

exportBeaconModule(Listener)
