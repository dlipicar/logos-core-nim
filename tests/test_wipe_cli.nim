## Erasure of marked payloads through the CLI module (Tier 5 step N-2d, W-13;
## DECISIONS G349's N-2d amendment, I92; INTERFACE §1.4.1): `logosctl call`
## of the vault kit module's marked methods (`store`'s request, `fetch`'s
## response, both of `exchange`) through `lcn_call`, in a logosd in this
## process (`test_lcn_call`'s harness, `support/lcncall_live`), with
## `lcn_call` and the providers in audit builds of the Module Host.
##
## The canary is 32 random lowercase letters per run, given as the secret from
## a file or a pipe (`@-` passes the launcher's stdin the same way); its
## lowercase hex is how a response shows it, and how a user would type it.
## Every host is sent both (`setWipeAudit`) and exits 97 at a graceful end
## that released a block holding one. The launcher runs in this process,
## whose scan is armed too: each case ends with no hit here, and the session
## with every host's graceful end. Nothing on stderr, in a failure or in the
## log holds a pattern. A marked response on stdout is the command's purpose
## (INTERFACE l.380-381): the test checks its copy and wipes it.
##
## [DECISIONS G277] A refc build starts no marked provider: the cases skip.
## The scan sees the Nim heap only under orc and arc on malloc
## (`test_wipe_cli.nims`); elsewhere the hit counts are not checked, and every
## other check runs.

when defined(posix):
  const LivePrefix = "lcw" ## the short directories' prefix
  include ./support/lcncall_live
  import std/sysrand
  import logos_sdk/base/wipeaudit
  from logos_sdk/base/wipe import wipe
  from logos_sdk/codegen/nimrt import wipeTyped
  from ../src/logos_core/runtime/hostsup import hostEnds, setWipeAudit

  # The patterns ---------------------------------------------------------------------

  let canary = block:
    var c = urandom(32)
    for b in c.mitems:
      b = byte(ord('a') + int(b) mod 26)
    c

  let canaryText = block:
    var s = newString(canary.len)
    for i, b in canary:
      s[i] = char(b)
    s

  let hexText = block:
    ## The canary as a response shows it: lowercase hex.
    const digits = "0123456789abcdef"
    var s = newString(2 * canary.len)
    for i, b in canary:
      s[2 * i] = digits[int(b shr 4)]
      s[2 * i + 1] = digits[int(b and 15)]
    s

  proc patterns(): seq[seq[byte]] =
    ## Fresh copies: `armWipeAudit` and `setWipeAudit` zero what they are given.
    result.add(canary)
    var h = newSeq[byte](hexText.len)
    for i, c in hexText:
      h[i] = byte(c)
    result.add(h)

  let scans = wipeAuditScans()

  proc finds(s: string): int =
    ## The patterns `s` holds.
    if s.find(canaryText) >= 0:
      inc result
    if s.find(hexText) >= 0:
      inc result

  proc holds(s, before, mid, after: string): bool =
    ## `s` holds `before & mid & after`, found without building it: a copy
    ## of a pattern released here would be a hit.
    var at = s.find(before)
    while at >= 0:
      let m = at + before.len
      if s.continuesWith(mid, m) and s.continuesWith(after, m + mid.len):
        return true
      at = s.find(before, at + 1)
    false

  proc hits(): int =
    ## Blocks released in this process holding a pattern since arming
    ## (backtraces to stderr).
    if not scans:
      return 0
    result = wipeAuditHits()
    if result > 0:
      reportWipeAudit()

  # Commands, with every copy of the message wiped -------------------------------------

  type Out = object
    exit: int
    output, errors, failure: string

  proc wipe(o: var Out) =
    wipe(o.output)
    wipe(o.errors)
    wipe(o.failure)

  proc quiet(o: Out): bool =
    ## No pattern where none belongs: stderr and the launcher's own text.
    finds(o.errors) == 0 and finds(o.failure) == 0

  func messageOf(cmd: sink LcnCliCommand, text = false): LcnCliMessage =
    LcnCliMessage(
      command: cmd,
      output:
        if text:
          LcnCliOutput(kind: LcnCliOutputKind.Text)
        else:
          LcnCliOutput(kind: LcnCliOutputKind.Json),
    )

  func textArg(name, value: string): LcnCliArg =
    LcnCliArg(
      kind: LcnCliArgKind.lcn_Cli_text_arg,
      arm_lcn_Cli_text_arg: LcnCliTextArg(name: name, value: value),
    )

  proc launchOne(
      l: Live,
      msg: var LcnCliMessage,
      files: seq[cint] = @[],
      stdoutFd = cint(-1),
      cancelFd = cint(-1),
  ): Out =
    ## As `run`: the message wiped after, and the launcher's copy of it.
    let (op, ofd) = outFile(l.outDir)
    let (ep, efd) = outFile(l.outDir)
    var la = Launch(
      cliSocket: l.cli,
      ctlSocket: l.d.socketPath,
      message: msg,
      stdoutFd: (if stdoutFd >= 0: stdoutFd else: ofd),
      stderrFd: efd,
      timeoutMs: Timeout,
      cancelFd: cancelFd,
      files: files,
    )
    let r = launch(la)
    wipeTyped(la.message)
    wipeTyped(msg)
    discard posix.close(ofd)
    discard posix.close(efd)
    for f in files:
      discard posix.close(f)
    result.output = readFile(op)
    result.errors = readFile(ep)
    removeFile(op)
    removeFile(ep)
    if r.isOk:
      result.exit = r.get
    else:
      result.exit = r.error.exit
      result.failure = r.error.message

  proc pipeWith(data: string, close = true): (cint, cint) =
    ## A pipe holding `data`: its read end, and its write end or -1 once
    ## closed.
    var p: array[2, cint]
    doAssert pipe(p) == 0
    for f in p:
      discard fcntl(f, F_SETFD, FD_CLOEXEC)
    if data.len > 0:
      doAssert posix.write(p[1], unsafeAddr data[0], data.len) == data.len
    if close:
      discard posix.close(p[1])
      return (p[0], cint(-1))
    (p[0], p[1])

  func store(slot, secret: int, note = -1): LcnCliCommand =
    ## `store` with each field from the file at that descriptor index.
    var args = @[fileArg("slot", slot), fileArg("secret", secret)]
    if note >= 0:
      args.add(fileArg("note", note))
    callWith("vault_module", "store", args)

  func exchange(slot, secret: int): LcnCliCommand =
    callWith(
      "vault_module", "exchange", @[fileArg("slot", slot), fileArg("secret", secret)]
    )

  # A command from a thread of its own, with the launcher's cancel ---------------------

  type Bg = object
    l: ptr Live
    msg: LcnCliMessage
    files: seq[cint]
    cancelFd: cint
    res: Out

  var
    bg: Bg
    bgThread: Thread[ptr Bg]

  proc bgRun(b: ptr Bg) {.thread.} =
    {.cast(gcsafe).}:
      b.res = b.l[].launchOne(b.msg, b.files, cancelFd = b.cancelFd)
    releasePerThread()

  proc cancelPipe(): (cint, cint) =
    var p: array[2, cint]
    doAssert pipe(p) == 0
    for f in p:
      discard fcntl(f, F_SETFD, FD_CLOEXEC)
    (p[0], p[1])

  proc vaultHeld(l: Live): int =
    ## The calls the vault has held on slot 14 (its `held` file's lines).
    try:
      readFile(l.s.modulesDir / "vault-state" / "held").count("held\n")
    except IOError:
      0

  # Cases ---------------------------------------------------------------------------------

  var
    wl: Live
    since: int ## host ends before this session's

  suite "wipe: logosctl call through lcn_call, marked payloads (W-13) [IMPL-DECISION G349]":
    when ChannelsMove:
      test "[IFC-0575] W-13a: a marked request from files and from a pipe, slot from a file too, leaves no copy":
        live = addr wl
        # A temporary lives to the end of its scope, after `arm`: wiped here.
        var given = patterns()
        setWipeAudit(given)
        for p in given.mitems:
          wipe(p)
        since = hostEnds().len
        wl = boot(newSession())
        # lcn_call starts at its first command: its host's `init`, which
        # carries the patterns, is released here before the scan is armed.
        let first = wl.run(callOf("vault_module", "peek", [("slot", "0")]))
        checkpoint first.said
        check first.exit == 0
        if scans:
          armWipeAudit(patterns())
        var m = messageOf(store(2, 3))
        var o = wl.launchOne(m, @[wl.inFile("1\n"), wl.inFile(canaryText)])
        check o.exit == 0
        check """"stored":true""" in o.output
        check o.quiet and finds(o.output) == 0
        o.wipe
        let (r, _) = pipeWith(canaryText)
        m = messageOf(store(2, 3))
        o = wl.launchOne(m, @[wl.inFile("2"), r])
        check o.exit == 0
        check """"stored":true""" in o.output
        check o.quiet
        o.wipe
        check hits() == 0

      test "[IFC-0575] W-13b: a marked response, in JSON and in text, is on stdout only and leaves no copy":
        var m = messageOf(callOf("vault_module", "fetch", [("slot", "1")]))
        var o = wl.launchOne(m)
        check o.exit == 0
        check o.output.holds("\"secret\":\"", hexText, "\"")
        check o.quiet
        o.wipe
        m = messageOf(callOf("vault_module", "fetch", [("slot", "2")]), text = true)
        o = wl.launchOne(m)
        check o.exit == 0
        check o.output.holds("h'", hexText, "'")
        check o.quiet
        o.wipe
        m = messageOf(
          callWith(
            "vault_module", "exchange", @[fileArg("slot", 2), fileArg("secret", 3)]
          )
        )
        o = wl.launchOne(m, @[wl.inFile("1"), wl.inFile(canaryText)])
        check o.exit == 0
        check o.output.holds("\"previous\":\"", hexText, "\"")
        check o.quiet
        o.wipe
        check hits() == 0

      test "[IFC-0575] W-13c: refused requests read no secret, quote none and leave no copy":
        # Inline, as a user would type it: refused before any file is read.
        # `callWith` copies the arguments: the originals are wiped here.
        var inline = @[fileArg("slot", 2), textArg("secret", hexText)]
        var m = messageOf(callWith("vault_module", "store", inline))
        for a in inline.mitems:
          wipeTyped(a)
        var o = wl.launchOne(m, @[wl.inFile("3")])
        check o.exit == 1
        check o.quiet and finds(o.output) == 0
        o.wipe
        # A mistyped field name, here the canary itself, as a file and as an
        # inline argument: refused, and named nowhere (planning, 2026-11-21).
        var typos = @[
          @[fileArg("slot", 2), fileArg(canaryText, 3)],
          @[fileArg("slot", 2), textArg(canaryText, "1")],
        ]
        for args in typos.mitems:
          m = messageOf(callWith("vault_module", "store", args))
          for a in args.mitems:
            wipeTyped(a)
          o = wl.launchOne(m, @[wl.inFile("3"), wl.inFile("x")])
          check o.exit == 1
          check o.quiet and finds(o.output) == 0
          o.wipe
        check finds(logText()) == 0
        # Mixed: the file's secret never enters lcn_call.
        let (r, _) = pipeWith(canaryText)
        let kept = dup(r)
        m = messageOf(
          callWith(
            "vault_module", "store", @[textArg("slot", "3"), fileArg("secret", 2)]
          )
        )
        o = wl.launchOne(m, @[r])
        check o.exit == 1
        check o.quiet and finds(o.output) == 0
        o.wipe
        var left = newSeq[byte](64)
        let n = posix.read(kept, addr left[0], left.len)
        check n == canary.len
        wipe(left)
        discard posix.close(kept)
        # A value the rule rejects: an empty note, after the secret was read.
        m = messageOf(store(2, 3, note = 4))
        o = wl.launchOne(m, @[wl.inFile("4"), wl.inFile(canaryText), wl.inFile("")])
        check o.exit == 1
        check "note" in o.output
        check o.quiet and finds(o.output) == 0
        o.wipe
        # A file past the field's bound: refused at 257 bytes.
        var big = newString(canary.len + 300)
        for i in 0 ..< big.len:
          big[i] = (if i < canary.len: canaryText[i] else: 'x')
        let bigFd = wl.inFile(big)
        wipe(big)
        m = messageOf(store(2, 3))
        o = wl.launchOne(m, @[wl.inFile("4"), bigFd])
        check o.exit == 1
        check "256 bytes" in o.output
        check o.quiet and finds(o.output) == 0
        o.wipe
        check hits() == 0

      test "[IFC-0575] W-13d: a call that fails at the provider after the encode leaves no copy":
        var m = messageOf(store(2, 3))
        var o = wl.launchOne(m, @[wl.inFile("16"), wl.inFile(canaryText)])
        check o.exit == 5
        check o.quiet and finds(o.output) == 0
        o.wipe
        check hits() == 0

      test "[IFC-0575] W-13e: cancelled while @- is half read, and while the call is held, leaves no copy":
        # The pipe holds the secret and stays open: lcn_call is still reading.
        let (r, w) = pipeWith(canaryText, close = false)
        var (cr, cw) = cancelPipe()
        bg = Bg(
          l: addr wl,
          msg: messageOf(store(2, 3)),
          files: @[wl.inFile("5"), r],
          cancelFd: cr,
        )
        createThread(bgThread, bgRun, addr bg)
        sleep(500 * Slow)
        var one = 1'u8
        discard posix.write(cw, addr one, 1)
        joinThread(bgThread)
        check bg.res.exit == 130
        check bg.res.quiet
        bg.res.wipe
        discard posix.close(w)
        discard posix.close(cr)
        discard posix.close(cw)
        # `exchange` on slot 14 waits in the vault until cancelled.
        let before = wl.vaultHeld
        (cr, cw) = cancelPipe()
        bg = Bg(
          l: addr wl,
          msg: messageOf(exchange(2, 3)),
          files: @[wl.inFile("14"), wl.inFile(canaryText)],
          cancelFd: cr,
        )
        createThread(bgThread, bgRun, addr bg)
        let until = getMonoTime() + initDuration(seconds = Patience)
        while wl.vaultHeld == before and getMonoTime() < until:
          sleep(10)
        check wl.vaultHeld > before
        discard posix.write(cw, addr one, 1)
        joinThread(bgThread)
        check bg.res.exit == 130
        check bg.res.quiet
        bg.res.wipe
        discard posix.close(cr)
        discard posix.close(cw)
        check hits() == 0

      test "[IFC-0575] W-13f: a reader that closed stdout before the marked response leaves no copy":
        let (r, w) = cancelPipe()
        discard posix.close(r)
        var m = messageOf(callOf("vault_module", "fetch", [("slot", "1")]))
        var o = wl.launchOne(m, stdoutFd = w)
        discard posix.close(w)
        check o.exit == 0
        check o.quiet and finds(o.output) == 0
        o.wipe
        check hits() == 0

      test "[IFC-0575] W-13g: no pattern in the log, and every host ends gracefully, none with a hit":
        check finds(logText()) == 0
        finish(wl)
        live = nil
        let ends = hostEnds()
        check ends.len > since
        for x in ends[since .. ^1]:
          if not x.exited or x.status != 0:
            checkpoint(
              "a host ended: exited " & $x.exited & ", status " & $x.status & ", " &
                x.reason
            )
          check x.exited and x.status == 0
        setWipeAudit(newSeq[seq[byte]]())
        check hits() == 0
    else:
      test "W-13: skipped":
        skip() # [DECISIONS G277] a refc build starts no marked provider
