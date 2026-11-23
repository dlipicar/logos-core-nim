## A stand-in for `logos-module-host` in `test_module_host` H-14 (Tier 4b step
## 4b-3; plan §4.3, R4, R5): started by the supervision exactly as a host is,
## it reports what it was started with in one lane-0 `fatal` message on fd 3,
## then exits 0. Lines: `arg <argument>` per argument after the program's
## name, `mask <n>` (signals blocked), `<signal> dfl|other`, `env <name>` per
## variable, `fd0 null|other`, `fd5 <dev>:<ino>|closed`, `fd6 open|closed`. Built with `-d:noSignalHandler`, so the Nim runtime
## leaves the dispositions it was started with.

import std/[os, posix]
import ../../src/logos_core/runtime/carrier

proc sigQuery(
  sig: cint, act, old: ptr Sigaction
): cint {.importc: "sigaction", header: "<signal.h>".}

proc disposition(sig: cint): string =
  var old: Sigaction
  discard sigQuery(sig, nil, addr old)
  if old.sa_handler == SIG_DFL: "dfl" else: "other"

proc main() =
  var lines: seq[string]
  for i in 1 .. paramCount():
    lines.add("arg " & paramStr(i))
  var none, mask: Sigset
  discard sigemptyset(none)
  discard pthread_sigmask(SIG_BLOCK, none, mask) # blocks nothing more
  var blocked = 0
  for s in 1 .. 31:
    if sigismember(mask, cint(s)) == 1:
      inc blocked
  lines.add("mask " & $blocked)
  for (name, sig) in [
    ("pipe", SIGPIPE), ("term", SIGTERM), ("int", SIGINT), ("hup", SIGHUP)
  ]:
    lines.add(name & " " & disposition(sig))
  for k, _ in envPairs():
    lines.add("env " & k)
  var st, null: Stat
  discard stat("/dev/null", null)
  lines.add(
    "fd0 " & (if fstat(0, st) == 0 and st.st_rdev == null.st_rdev: "null" else: "other")
  )
  lines.add(
    "fd5 " & (if fstat(5, st) == 0: $st.st_dev & ":" & $st.st_ino
    else: "closed")
  )
  lines.add("fd6 " & (if fcntl(6, F_GETFD) >= 0: "open" else: "closed"))
  var text = ""
  for l in lines:
    text.add(l & "\n")
  let f = frameOf(toMessage(LcnCarrierFatal(message: text))).get
  discard posix.write(3, unsafeAddr f[0], f.len)
  quit(0)

main()
