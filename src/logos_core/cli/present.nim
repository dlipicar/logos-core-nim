## The CLI's output (Tier 5 step N-2; DECISIONS G89, G349; BOOTSTRAP
## l.517-519): what lcn_call writes to the launcher's descriptors.
## docs/DAEMON.md §7a.
##
## As logosctl's own commands: JSON is one envelope per command on stdout,
## `{"deployment", "command", "status": "ok"|"error", ? "code", ? "message",
## ? "detail", ? "result"}`, with values rendered as G89 says (`render.jsonOf`);
## a stream writes one JSON object per line. Text is the response in
## diagnostic notation on stdout, a failure on stderr, each after the
## NON-PRODUCTION line when the development switch is on. Text a provider
## supplied is quoted and labelled "(declared)" (BOOTSTRAP l.381). DEL and the
## C1 controls, which diagnostic notation and JSON leave raw, are escaped too,
## so nothing a provider sent reaches a terminal as a control sequence.
##
## The descriptors are the launcher's own (its terminal, a pipe or a file), so
## their flags are never changed: a write waits with poll(2) for room or for
## the launcher's cancel (its connection becoming readable), or, for a stream,
## for the stream's end (`abortFd`), or at most `waitMs`, and writes at most
## PIPE_BUF bytes at a time where poll's promise covers no more.

{.push raises: [], gcsafe.}

import std/[json, strutils]
import results
import logos_sdk/cbor
import ../daemon/render

export results, json

when defined(posix):
  import std/posix

const
  Banner* = "NON-PRODUCTION deployment: the development switch is on"
  PipeChunk = 512 ## [IMPL] PIPE_BUF on macOS, the room POLLOUT promises

type
  SinkError* = enum
    seCancelled = "the launcher cancelled"
    seAborted = "the stream ended"
    seClosed = "the reader closed the output"
    seStalled = "the reader took nothing in time"
    seIo = "an output error"

  Sink* = object ## One of the launcher's descriptors.
    fd*: cint
    cancelFd*: cint ## the launcher's connection: readable means cancel; -1: none
    abortFd*: cint ## a stream's end: readable means stop writing; -1: none
    waitMs*: int ## the longest wait for room; -1: no limit
    regular: bool ## a regular file: writes never wait

  Presenter* = object ## One command's output.
    json*: bool
    deployment*: string ## "production" or "non-production"
    command*: string ## the command line, for the envelope
    output*, errors*: Sink

proc sinkOf*(fd, cancelFd: cint): Sink =
  var regular = false
  when defined(posix):
    var st: Stat
    if fstat(fd, st) == 0:
      regular = S_ISREG(st.st_mode)
  Sink(fd: fd, cancelFd: cancelFd, abortFd: -1, waitMs: -1, regular: regular)

func terminalSafe*(s: string): string =
  ## DEL and the C1 controls (U+0080 to U+009F) as `\u` escapes. They occur in
  ## JSON and diagnostic notation only inside strings, where the escape means
  ## the same character.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\x7F':
      result.add("\\u007f")
      inc i
    elif c == '\xC2' and i + 1 < s.len and s[i + 1] in {'\x80' .. '\x9F'}:
      result.add("\\u" & toHex(ord(s[i + 1]), 4).toLowerAscii)
      i += 2
    else:
      result.add(c)
      inc i

proc put*(s: Sink, data: string): Result[void, SinkError] =
  ## Writes all of `data`, or stops at the launcher's cancel or a closed reader.
  when defined(posix):
    var off = 0
    while off < data.len:
      if not s.regular:
        # A negative fd is ignored by poll(2).
        var p: array[3, TPollfd]
        p[0] = TPollfd(fd: s.fd, events: POLLOUT)
        p[1] = TPollfd(fd: s.cancelFd, events: POLLIN)
        p[2] = TPollfd(fd: s.abortFd, events: POLLIN)
        let n = poll(addr p[0], 3, cint(s.waitMs))
        if n < 0:
          if errno == EINTR:
            continue
          return err(seIo)
        if n == 0:
          return err(seStalled)
        if s.cancelFd >= 0 and (p[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
          return err(seCancelled)
        if s.abortFd >= 0 and p[2].revents != 0:
          return err(seAborted)
        if (p[0].revents and (POLLERR or POLLNVAL)) != 0:
          return err(seClosed)
        if (p[0].revents and POLLOUT) == 0 and (p[0].revents and POLLHUP) != 0:
          return err(seClosed)
      let chunk =
        if s.regular:
          data.len - off
        else:
          min(PipeChunk, data.len - off)
      let w = write(s.fd, unsafeAddr data[off], chunk)
      if w < 0:
        if errno == EINTR or errno == EAGAIN or errno == EWOULDBLOCK:
          continue
        if errno == EPIPE:
          return err(seClosed)
        return err(seIo)
      off += w
    ok()
  else:
    err(seIo)

proc line(s: Sink, text: string): Result[void, SinkError] =
  s.put(terminalSafe(text) & "\n")

func nonProduction*(p: Presenter): bool =
  p.deployment == "non-production"

proc done*(p: Presenter, value: JsonNode, text: string): Result[void, SinkError] =
  ## [G89] The command's result: the envelope, or the banner and `text`.
  if p.json:
    return p.output.line($envelope(p.deployment, p.command, true).withResult(value))
  if p.nonProduction:
    ?p.output.line(Banner)
  if text.len > 0:
    ?p.output.line(text)
  ok()

proc doneValue*(p: Presenter, v: CborValue): Result[void, SinkError] =
  ## A response value: G89's JSON, or diagnostic notation.
  p.done(jsonOf(v), toDiag(v))

proc failed*(
    p: Presenter, code, message: string, detail = Opt.none(seq[byte]), declared = false
): Result[void, SinkError] =
  ## [G349] A failure: the envelope on stdout, or the banner and
  ## `logosctl: CODE: message` on stderr. `declared` marks text a provider or
  ## a Runtime forwarded.
  let msg =
    if declared and message.len > 0:
      declaredText(message)
    else:
      message
  if p.json:
    var env = envelope(p.deployment, p.command, false, code, msg)
    if detail.isSome:
      env["detail"] = jsonOfBytes(detail.get)
    return p.output.line($env)
  if p.nonProduction:
    ?p.errors.line(Banner)
  var t = "logosctl: " & (if code.len > 0: code & ": " else: "") & msg
  if detail.isSome:
    t.add("\n  detail: " & diagOf(detail.get))
  p.errors.line(t)

proc streamLine*(p: Presenter, v: JsonNode, text: string): Result[void, SinkError] =
  ## [G349] One stream item: a JSON line, or a text line.
  if p.json:
    return p.output.line($v)
  p.output.line(text)

proc streamStart*(p: Presenter): Result[void, SinkError] =
  ## The banner before a text stream's first line.
  if not p.json and p.nonProduction:
    return p.output.line(Banner)
  ok()

{.pop.}
