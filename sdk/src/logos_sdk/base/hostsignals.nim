## [DECISIONS G340] A library leaves its host's signal dispositions as it found
## them.
##
## Nim's own handlers are left out at build time (`-d:noSignalHandler`), but
## chronos sets `SIGPIPE` to ignored, process-wide, in its module initializer
## (`asyncengine.globalInit`), whether or not the library ever polls. A library
## that imports chronos imports this module before anything that imports
## chronos, so this initializer records `SIGPIPE`'s disposition first, and calls
## `restoreHostSignals` last in its own initializer, which puts it back. The
## library's own writes never depend on it: its sockets are written with
## `MSG_NOSIGNAL` or carry `SO_NOSIGPIPE` (`transport/io/sock.c`).
##
## Windows has no `SIGPIPE`, and chronos changes nothing there.

when defined(posix):
  import std/posix

  proc sigactionOf(
    sig: cint, act: ptr Sigaction, old: ptr Sigaction
  ): cint {.importc: "sigaction", header: "<signal.h>".}

  var hostPipe = Sigaction()
  let hostPipeKnown = sigactionOf(SIGPIPE, nil, addr hostPipe) == 0

proc restoreHostSignals*() =
  ## Puts back the dispositions this module recorded when it was initialized.
  when defined(posix):
    if hostPipeKnown:
      discard sigactionOf(SIGPIPE, addr hostPipe, nil)
