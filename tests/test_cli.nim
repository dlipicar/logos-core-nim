## The CLI's pieces that need no Runtime (Tier 5 step N-2a; DECISIONS G344,
## G347, G349; D26 (a); docs/DAEMON.md §7a): the launcher socket's
## frames with descriptors, the request checks, the typing of arguments from a
## request rule, the `--request` reader, and the output written to the
## launcher's descriptors; N-2b's pure rules: the continuation rule
## (`hops`), the launcher's activation decisions, the failure classifier and
## retry rule, and the projection of an extended contract view.
## `test_lcn_call` runs the module itself.

when defined(posix):
  import std/[algorithm, json, os, sequtils, strutils, tempfiles]
  import unittest2
  import logos_sdk/cbor
  import logos_sdk/hash
  import logos_sdk/base/hex
  import logos_sdk/iface/[accept, outcome, surface]
  import logos_sdk/kit/rc_types
  import ../src/logos_core/daemon/render
  import ../src/logos_core/transport/io/sock
  import ../src/logos_core/cli/[args, fdpass, markedout, present, wire]
  from ../src/logos_core/cli/commands import
    Stop, classify, retryable, contractViews, projectView
  from ../src/logos_core/cli/rpc import CallResult, Failure
  from ../src/logos_core/cli/launcher import Act, ActKind, Answer, nextAct, answerOf
  import ../src/logos_core/cli/hops
  import std/posix except Stat

  discard signal(SIGPIPE, SIG_IGN) # as the Module Host does

  proc pair(): array[2, cint] =
    var p: array[2, cint]
    doAssert socketPair(addr p) == 0
    doAssert setNonblock(p[0]) == 0
    doAssert setNonblock(p[1]) == 0
    p

  proc mkpipe(): array[2, cint] =
    var p: array[0 .. 1, cint]
    doAssert pipe(p) == 0
    [p[0], p[1]]

  proc closeFds(fds: varargs[cint]) =
    for fd in fds:
      if fd >= 0:
        discard posix.close(fd)

  proc readAvailable(fd: cint, waitMs = 1000): string =
    ## What `fd` has within `waitMs`; "" at EOF or when nothing came.
    var p = TPollfd(fd: fd, events: POLLIN)
    if poll(addr p, 1, cint(waitMs)) <= 0:
      return ""
    var buf: array[65536, char]
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0:
      return ""
    result = newString(n)
    for i in 0 ..< n:
      result[i] = buf[i]

  proc atEof(fd: cint, waitMs = 2000): bool =
    ## True when `fd` reports EOF within `waitMs`.
    var p = TPollfd(fd: fd, events: POLLIN)
    if poll(addr p, 1, cint(waitMs)) <= 0:
      return false
    var c: char
    posix.read(fd, addr c, 1) == 0

  proc cloexec(fd: cint): bool =
    (fcntl(fd, F_GETFD) and FD_CLOEXEC) != 0

  func provider(module: string): LcnCliProvider =
    LcnCliProvider(module: module)

  func callMessage(fds: seq[LcnCliFdRoleKind], args: seq[LcnCliArg]): LcnCliMessage =
    var roles: seq[LcnCliFdRole] = @[]
    for k in fds:
      roles.add(role(k))
    LcnCliMessage(
      output: LcnCliOutput(kind: LcnCliOutputKind.Json),
      fds: roles,
      command: LcnCliCommand(
        kind: LcnCliCommandKind.lcn_Cli_call_command,
        arm_lcn_Cli_call_command: LcnCliCallCommand(
          provider: provider("shapes"),
          `method`: "ping",
          args: (if args.len > 0: Opt.some(args)
          else: Opt.none(seq[LcnCliArg])),
        ),
      ),
    )

  func fileArg(name: string, fd: int): LcnCliArg =
    LcnCliArg(
      kind: LcnCliArgKind.lcn_Cli_file_arg,
      arm_lcn_Cli_file_arg: LcnCliFileArg(name: name, fd: uint8(fd)),
    )

  func textArg(name, value: string): LcnCliArg =
    LcnCliArg(
      kind: LcnCliArgKind.lcn_Cli_text_arg,
      arm_lcn_Cli_text_arg: LcnCliTextArg(name: name, value: value),
    )

  const
    StdRoles = @[LcnCliFdRoleKind.Stdout, LcnCliFdRoleKind.Stderr]
    WithFile =
      @[LcnCliFdRoleKind.Stdout, LcnCliFdRoleKind.Stderr, LcnCliFdRoleKind.File]

  suite "cli.wire: the launcher's frame and its descriptors (G344) [IMPL]":
    test "the descriptors arrive close-on-exec with the frame and reach the same file":
      let s = pair()
      let a = mkpipe()
      let b = mkpipe()
      check writeRequest(s[0], [1'u8, 2, 3], [a[1], b[1]], 2000).isOk
      let r = readRequest(s[1], 2000)
      check r.isOk
      if r.isOk:
        var got = r.get
        check got.bytes == @[1'u8, 2, 3]
        check got.fds.len == 2
        for fd in got.fds:
          check cloexec(fd)
        check posix.write(got.fds[0], cstring("x"), 1) == 1
        check posix.write(got.fds[1], cstring("y"), 1) == 1
        check readAvailable(a[0]) == "x"
        check readAvailable(b[0]) == "y"
        closeAll(got.fds)
        check got.fds.len == 0
      closeFds(s[0], s[1], a[0], a[1], b[0], b[1])

    test "a frame without descriptors reads as one":
      let s = pair()
      check writeRequest(s[0], [9'u8], [], 2000).isOk
      let r = readRequest(s[1], 2000)
      check r.isOk and r.get.fds.len == 0 and r.get.bytes == @[9'u8]
      closeFds(s[0], s[1])

    test "a refused frame closes every descriptor that arrived":
      let s = pair()
      let a = mkpipe()
      check writeRequest(s[0], newSeq[byte](64), [a[1]], 2000).isOk
      let r = readRequest(s[1], 2000, maxBytes = 8)
      check r.isErr and r.error.kind == feTooLarge
      discard posix.close(a[1])
      check atEof(a[0]) # no copy of the write end is left open
      closeFds(s[0], s[1], a[0])

    test "more than 16 descriptors are refused and none is left open":
      let s = pair()
      let a = mkpipe()
      var ten: array[10, cint]
      for i in 0 ..< 10:
        ten[i] = a[1]
      let header = [0'u8, 0, 0, 2]
      check sendFds(s[0], unsafeAddr header[0], 4, addr ten[0], 10) == 4
      let body = [7'u8, 7]
      check sendFds(s[0], unsafeAddr body[0], 2, addr ten[0], 10) == 2
      let r = readRequest(s[1], 2000)
      check r.isErr and r.error.kind == feTooLarge
      discard posix.close(a[1])
      check atEof(a[0])
      closeFds(s[0], s[1], a[0])

    test "the sender refuses more than 16 descriptors":
      let s = pair()
      let fds = newSeq[cint](17)
      check writeRequest(s[0], [1'u8], fds, 2000).isErr
      closeFds(s[0], s[1])

    test "EOF, an idle connection and a partial frame":
      block:
        let s = pair()
        discard shutdownWrite(s[0])
        let r = readRequest(s[1], 2000)
        check r.isErr and r.error.kind == feEof
        closeFds(s[0], s[1])
      block:
        let s = pair()
        let r = readRequest(s[1], 50)
        check r.isErr and r.error.kind == feTimeout
        closeFds(s[0], s[1])
      block:
        let s = pair()
        let a = mkpipe()
        let partial = [0'u8, 0, 0, 9, 1]
        check sendFds(s[0], unsafeAddr partial[0], 5, unsafeAddr a[1], 1) == 5
        discard shutdownWrite(s[0])
        let r = readRequest(s[1], 2000)
        check r.isErr and r.error.kind == fePartial
        discard posix.close(a[1])
        check atEof(a[0])
        closeFds(s[0], s[1], a[0])

    test "replies round-trip, and a refusal's message is clipped on a character":
      let s = pair()
      check writeReply(s[0], acceptedReply(), 2000).isOk
      check writeReply(s[0], doneReply(ExitProvider), 2000).isOk
      let long = repeat("é", 400) # 800 bytes
      check writeReply(
        s[0], refusedReply(LcnCliRefusedReasonChoiceKind.Busy, long), 2000
      ).isOk
      let r1 = readReply(s[1], 2000)
      check r1.isOk and r1.get.outcome.kind == LcnCliOutcomeKind.lcn_Cli_accepted
      let r2 = readReply(s[1], 2000)
      check r2.isOk and r2.get.outcome.kind == LcnCliOutcomeKind.lcn_Cli_done
      check r2.get.outcome.arm_lcn_Cli_done.exit == uint8(ExitProvider)
      let r3 = readReply(s[1], 2000)
      check r3.isOk
      if r3.isOk:
        let m = r3.get.outcome.arm_lcn_Cli_refused.message.get
        check m.len <= 512 and m.len == 512
        check isValidUtf8(m)
      closeFds(s[0], s[1])

  suite "cli.request: the request's checks (G344, G347) [IMPL]":
    test "a request of the protocol decodes; another protocol or a non-map does not":
      let m = callMessage(StdRoles, @[])
      let bytes = m.encode.get
      let d = decodeMessage(bytes)
      check d.isOk and d.get.command.opName == "call"
      check d.get.targetOf == LocalNode
      check decodeMessage(encodeCbor(cbor(5'u64))).isErr
      var other = decodeCbor(bytes).get
      for e in other.entries.mitems:
        if e[0].text == "protocol":
          e[1] = cbor("logos-core-nim.ctl.v1")
      check decodeMessage(encodeCbor(other)).isErr

    test "the descriptor roles must match what arrived":
      check checkMessage(callMessage(StdRoles, @[]), 2).isOk
      check checkMessage(callMessage(StdRoles, @[]), 3).isErr
      check checkMessage(
        callMessage(@[LcnCliFdRoleKind.Stderr, LcnCliFdRoleKind.Stdout], @[]), 2
      ).isErr
      check checkMessage(callMessage(@[LcnCliFdRoleKind.Stdout], @[]), 1).isErr

    test "each file is exactly one argument's":
      check checkMessage(callMessage(WithFile, @[fileArg("t", 2)]), 3).isOk
      check checkMessage(callMessage(WithFile, @[]), 3).isErr # an unnamed file
      check checkMessage(callMessage(WithFile, @[fileArg("t", 1)]), 3).isErr # stderr
      check checkMessage(callMessage(WithFile, @[fileArg("t", 3)]), 3).isErr
      check checkMessage(callMessage(WithFile, @[fileArg("t", 2), fileArg("u", 2)]), 3).isErr

    test "args and json exclude each other":
      var m = callMessage(StdRoles, @[textArg("a", "1")])
      m.command.arm_lcn_Cli_call_command.json = Opt.some("{}")
      check checkMessage(m, 2).isErr

    test "the target is optional and kept as named; the rc op is reserved, with no file":
      var m = callMessage(StdRoles, @[])
      check decodeMessage(m.encode.get).get.target.isNone
      m.target = Opt.some("edge-1")
      check decodeMessage(m.encode.get).get.targetOf == "edge-1"
      var rc = callMessage(StdRoles, @[])
      rc.command = LcnCliCommand(
        kind: LcnCliCommandKind.lcn_Cli_rc_command,
        arm_lcn_Cli_rc_command: LcnCliRcCommand(`method`: "list_modules", params: @[]),
      )
      let d = decodeMessage(rc.encode.get)
      check d.isOk and d.get.command.opName == "rc"
      check checkMessage(rc, 2).isOk
      rc.fds.add(role(LcnCliFdRoleKind.File))
      check checkMessage(rc, 3).isErr

    test "node names":
      check validNodeName("local")
      check validNodeName("node-2_b")
      check not validNodeName("")
      check not validNodeName("2nd")
      check not validNodeName("Local")
      check not validNodeName("a.b")
      check validNodeName("a" & repeat("b", 62))
      check not validNodeName("a" & repeat("b", 63))

  const ArgsDoc = """
; -- metadata --
_module = "cliargs_module"

cliargs.mode = "fast" / "slow"
cliargs.either = uint32 / tstr
cliargs.raw = tstr / bstr
cliargs.point = { x: uint8, ? y: uint8 }

cliargs.go_request = {
  n: uint32,
  t: tstr .size (1..8),
  ? i: int8,
  ? big: uint64,
  ? neg: int64,
  ? b: bstr,
  ? flag: bool,
  ? mode: cliargs.mode,
  ? either: cliargs.either,
  ? raw: cliargs.raw,
  ? lit: 7,
  ? point: cliargs.point,
  ? list: [* uint16],
  ? pair: [uint8, tstr],
}
cliargs.go_response = {}

cliargs.multi_request = { kind: "a", a: uint8 } / { kind: "b", b: tstr }
cliargs.multi_response = {}
"""

  proc shapeOf(name: string): RequestShape =
    let set = acceptContractSet(ArgsDoc).get
    requestShape(set, set.callSurface.findMethod(name).get).get

  proc text(name, value: string): ArgInput =
    ArgInput(name: name, isFile: false, text: value)

  proc file(name: string, data: seq[byte]): ArgInput =
    ArgInput(name: name, isFile: true, data: data)

  proc base(): seq[ArgInput] =
    @[text("n", "5"), text("t", "hi")]

  proc typed(extra: varargs[ArgInput]): Result[CborValue, string] =
    shapeOf("go").fromArgs(base() & @extra)

  proc field(v: CborValue, key: string): CborValue =
    v.lookup(key).get

  suite "cli.args: key=value and key=@FILE typed from the request rule (D26 (a), G349)":
    test "scalars: integers in decimal, booleans, text, hex byte strings":
      let v = typed(
        text("i", "-128"),
        text("big", "18446744073709551615"),
        text("neg", "-9223372036854775808"),
        text("b", "00Ff"),
        text("flag", "true"),
      )
      check v.isOk
      if v.isOk:
        check v.get.field("n") == cbor(5'u64)
        check v.get.field("t") == cbor("hi")
        check v.get.field("i") == cbor(-128'i64)
        check v.get.field("big") == cbor(high(uint64))
        check v.get.field("neg") == cbor(low(int64))
        check v.get.field("b") == cbor(@[0'u8, 0xFF])
        check v.get.field("flag") == cbor(true)
        check shapeOf("go").checkRequest(v.get).isOk

    test "an empty hex text is the empty byte string":
      let v = typed(text("b", ""))
      check v.isOk and v.get.field("b") == cbor(newSeq[byte]())

    test "integers outside their kind, and floats, are refused":
      for (k, x) in [
        ("n", "-1"),
        ("n", "4294967296"),
        ("n", "1.5"),
        ("n", "1e3"),
        ("n", ""),
        ("i", "128"),
        ("i", "-129"),
        ("neg", "-9223372036854775809"),
        ("big", "18446744073709551616"),
        ("n", "+5"),
      ]:
        checkpoint k & "=" & x
        let args =
          @[text("t", "hi"), text(k, x)] & (if k == "n": @[]
          else: @[text("n", "1")])
        check shapeOf("go").fromArgs(args).isErr

    test "text sizes, booleans and hex are checked":
      check typed(text("flag", "yes")).isErr
      check typed(text("b", "0g")).isErr
      check typed(text("b", "abc")).isErr
      check shapeOf("go").fromArgs(@[text("n", "1"), text("t", "123456789")]).isErr
      check shapeOf("go").fromArgs(@[text("n", "1"), text("t", "")]).isErr

    test "a choice reads its one matching alternative":
      let v = typed(text("mode", "slow"), text("either", "abc"), text("raw", "xyz"))
      check v.isOk
      if v.isOk:
        check v.get.field("mode") == cbor("slow")
        check v.get.field("either") == cbor("abc")
        check v.get.field("raw") == cbor("xyz")
      let bad = typed(text("mode", "medium"))
      check bad.isErr and "matches none" in bad.error

    test "a text two alternatives read differently is refused as ambiguous":
      let e = typed(text("either", "5"))
      check e.isErr and "ambiguous" in e.error
      let r = typed(text("raw", "abcd"))
      check r.isErr and "ambiguous" in r.error

    test "a literal field":
      check typed(text("lit", "7")).isOk
      check typed(text("lit", "8")).isErr

    test "structured fields, unknown or repeated keys and missing fields are refused with the field list":
      let p = typed(text("point", "1"))
      check p.isErr and "--request" in p.error
      let u = typed(text("zzz", "1"))
      check u.isErr and "no field" in u.error and
        "point?: cliargs.point (map) (--request)" in u.error
      let d = typed(text("n", "6"))
      check d.isErr and "twice" in d.error
      let m = shapeOf("go").fromArgs(@[text("n", "1")])
      check m.isErr and "needs t" in m.error

    test "a request rule that is a choice takes --request only":
      let r = shapeOf("multi").fromArgs(@[text("kind", "a")])
      check r.isErr and "--request" in r.error

    test "@FILE: text must be UTF-8, byte strings are raw, other kinds read the file's text":
      let ok1 =
        shapeOf("go").fromArgs(@[text("n", "1"), file("t", @[0x68'u8, 0xC3, 0xA9])])
      check ok1.isOk and ok1.get.field("t") == cbor("hé")
      check shapeOf("go").fromArgs(@[text("n", "1"), file("t", @[0xFF'u8])]).isErr
      let raw = typed(file("b", @[0'u8, 1, 2]))
      check raw.isOk and raw.get.field("b") == cbor(@[0'u8, 1, 2])
      # [G349 N-2d] Other kinds: the file's text less one trailing "\n", read as
      # key=value reads it; a text field keeps its newline.
      let n1 = shapeOf("go").fromArgs(@[file("n", @[0x31'u8, 0x0A]), text("t", "x")])
      check n1.isOk and n1.get.field("n") == cbor(1'u64)
      let n2 = shapeOf("go").fromArgs(@[file("n", @[0x31'u8]), text("t", "x")])
      check n2.isOk and n2.get.field("n") == cbor(1'u64)
      check shapeOf("go")
        .fromArgs(@[file("n", @[0x31'u8, 0x0A, 0x0A]), text("t", "x")]).isErr
      check shapeOf("go")
        .fromArgs(@[file("n", @[0x31'u8, 0x0D, 0x0A]), text("t", "x")]).isErr
      let t1 = shapeOf("go").fromArgs(@[text("n", "1"), file("t", @[0x68'u8, 0x0A])])
      check t1.isOk and t1.get.field("t") == cbor("h\n")
      let flag =
        typed(file("flag", @[byte('t'), byte('r'), byte('u'), byte('e'), 0x0A]))
      check flag.isOk and flag.get.field("flag") == cbor(true)
      let lit = typed(file("lit", @[byte('7'), 0x0A]))
      check lit.isOk and lit.get.field("lit") == cbor(7'u64)
      let mode =
        typed(file("mode", @[byte('s'), byte('l'), byte('o'), byte('w'), 0x0A]))
      check mode.isOk and mode.get.field("mode") == cbor("slow")
      # In a choice each alternative reads by its own rule: "12\n" is 12 for
      # uint32 and "12\n" for tstr, two values, so it is ambiguous.
      let amb = typed(file("either", @[byte('1'), byte('2'), 0x0A]))
      check amb.isErr and "ambiguous" in amb.error
      # tstr / bstr: UTF-8 bytes read both ways; other bytes only as bstr
      check typed(file("raw", @[0x61'u8])).isErr
      let only = typed(file("raw", @[0xFF'u8]))
      check only.isOk and only.get.field("raw") == cbor(@[0xFF'u8])

  suite "cli.marked: a marked request's arguments (G349 N-2d; IF §1.4.1) [IMPL]":
    test "no message quotes the input or an argument's name that is not a field":
      let bad = shapeOf("go").fromArgs(
          @[file("n", @[byte('Q'), byte('Z'), byte('X')]), file("t", @[0x68'u8])],
          marked = true,
        )
      check bad.isErr and "QZX" notin bad.error and
        "n: the file does not read as uint32" in bad.error
      let plain = shapeOf("go").fromArgs(
          @[file("n", @[byte('Q'), byte('Z'), byte('X')]), file("t", @[0x68'u8])]
        )
      check plain.isErr and "QZX" in plain.error
      let unknown =
        shapeOf("go").fromArgs(@[file("SECRETNAME", @[0x31'u8])], marked = true)
      check unknown.isErr and "SECRETNAME" notin unknown.error and
        "no field of an argument given" in unknown.error and
        "point?: cliargs.point (map) (structured)" in unknown.error
      let choice = shapeOf("go").fromArgs(
          @[
            file("n", @[0x31'u8]),
            file("t", @[0x68'u8]),
            file("mode", @[byte('Q'), byte('Z')]),
          ],
          marked = true,
        )
      check choice.isErr and "QZ" notin choice.error

    test "a size mismatch states the length only":
      let long = shapeOf("go").fromArgs(
          @[file("n", @[0x31'u8]), file("t", newSeq[byte](9))], marked = true
        )
      check long.isErr and "tstr of 9 bytes, not 1 to 8" in long.error

    test "the names are checked before any file is read":
      let sh = shapeOf("go")
      check sh.checkMarkedNames(["n", "t", "b"]).isOk
      let u = sh.checkMarkedNames(["n", "SECRETNAME"])
      check u.isErr and "SECRETNAME" notin u.error
      let d = sh.checkMarkedNames(["n", "n"])
      check d.isErr and "twice" in d.error
      let p = sh.checkMarkedNames(["point"])
      check p.isErr and "structured" in p.error and "--request" notin p.error
      let multi = shapeOf("multi").checkMarkedNames(["kind"])
      check multi.isErr and "not one map" in multi.error

    test "a file is read up to one byte past its field's .size bound":
      let sh = shapeOf("go")
      check sh.fileLimit("t", 1 shl 24) == 9
      check sh.fileLimit("n", 1 shl 24) == 1 shl 24
      check sh.fileLimit("b", 1 shl 24) == 1 shl 24
      check sh.fileLimit("nope", 1 shl 24) == 1 shl 24

    test "the request check names no path":
      let sh = shapeOf("go")
      let wrong = cborMap((cbor("n"), cbor("x")), (cbor("t"), cbor("hi")))
      let plain = sh.checkRequest(wrong)
      check plain.isErr and "at [" in plain.error
      let marked = sh.checkRequest(wrong, marked = true)
      check marked.isErr and "at [" notin marked.error

    test "the inputs are wiped":
      var inputs = @[file("b", @[1'u8, 2, 3]), text("t", "secret")]
      wipeInputs(inputs)
      check inputs.len == 0

  suite "cli.markedout: a marked response's line equals the usual one (G89; G349 N-2d) [IMPL]":
    proc usualJson(v: CborValue): string =
      terminalSafe(
        $envelope("non-production", "call vault_module.fetch", true).withResult(
          jsonOf(v)
        )
      ) & "\n"

    proc usualText(v: CborValue): string =
      terminalSafe(toDiag(v)) & "\n"

    proc values(): seq[CborValue] =
      result = @[
        cbor(0'u64),
        cbor(9_007_199_254_740_992'u64),
        cbor(9_007_199_254_740_993'u64),
        cbor(high(uint64)),
        cborNint(0),
        cborNint(9_007_199_254_740_991'u64),
        cborNint(9_007_199_254_740_992'u64),
        cborNint(high(uint64)),
        cbor(newSeq[byte]()),
        cbor(@[0'u8, 0xAB, 0xFF]),
        cbor(""),
        cbor("plain"),
        cbor("q\"b\\s/\n\r\t\b\f\v\x00\x07\x0E\x1F end"),
        cbor("del\x7F c1\xC2\x80\xC2\x9F not\xC2\xA0 lone\xC2"),
        cbor("é ü 漢"),
        CborValue(kind: ckText, text: "\xFF\xFE", validUtf8: false),
        cborArray(),
        cborArray(cbor(1'u64), cbor("a"), cborArray(cbor(true))),
        cborMap(),
        cborMap((cbor("secret"), cbor(@[1'u8, 2])), (cbor("note"), cbor("n"))),
        cborMap((cbor(1'u64), cbor("int")), (cbor("1"), cbor("text"))),
        cborMap(
          (cbor("1"), cbor("text")),
          (cbor(1'u64), cbor("int")),
          (cbor("x"), cbor(2'u64)),
        ),
        cborMap((cborArray(cbor("k\x7F")), cbor(1'u64)), (cbor(@[9'u8]), cbor(2'u64))),
        CborValue(kind: ckTag, tag: 24, content: cbor(@[1'u8])),
        CborValue(kind: ckTag, tag: high(uint64), content: cbor("t")),
        CborValue(kind: ckSimple, simple: SimpleFalse),
        CborValue(kind: ckSimple, simple: SimpleTrue),
        CborValue(kind: ckSimple, simple: SimpleNull),
        CborValue(kind: ckSimple, simple: SimpleUndefined),
        CborValue(kind: ckSimple, simple: 16),
      ]

    test "JSON: the envelope, byte for byte":
      for v in values():
        check markedJsonLine("non-production", "call vault_module.fetch", v) ==
          usualJson(v)

    test "text: diagnostic notation, byte for byte":
      for v in values():
        check markedTextLine(v) == usualText(v)

  suite "cli.json: --request as G89 writes values (D26 (a), G349)":
    test "the whole request, as key=value would give it":
      let j =
        shapeOf("go").fromJson("""{"n": 5, "t": "hi", "b": "00ff", "flag": false}""")
      check j.isOk
      let a = typed(text("b", "00ff"), text("flag", "false"))
      check j.isOk and a.isOk and encodeCbor(j.get) == encodeCbor(a.get)

    test "G89's output reads back as the same value":
      let v = typed(
        text("big", "18446744073709551615"),
        text("neg", "-9223372036854775808"),
        text("b", "0102"),
        text("i", "-3"),
      ).get
      let back = shapeOf("go").fromJson($jsonOf(v))
      check back.isOk and encodeCbor(back.get) == encodeCbor(v)

    test "integers within ±2^53 are numbers, beyond it decimal text":
      check shapeOf("go").fromJson("""{"n": 1, "t": "x", "big": "5"}""").isErr
      check shapeOf("go").fromJson("""{"n": "1", "t": "x"}""").isErr
      check shapeOf("go")
        .fromJson("""{"n": 1, "t": "x", "big": 18446744073709551615}""").isOk

    test "structured fields, lists and tuples":
      let v = shapeOf("go").fromJson(
          """{"n": 1, "t": "x", "point": {"x": 1}, "list": [1, 2], "pair": [3, "z"]}"""
        )
      check v.isOk
      if v.isOk:
        check v.get.field("point") == cborMap((cbor("x"), cbor(1'u64)))
        check v.get.field("list") == cborArray(cbor(1'u64), cbor(2'u64))
      check shapeOf("go")
        .fromJson("""{"n": 1, "t": "x", "point": {"x": 1, "z": 2}}""").isErr
      check shapeOf("go").fromJson("""{"n": 1, "t": "x", "point": {}}""").isErr
      check shapeOf("go").fromJson("""{"n": 1, "t": "x", "list": [1, 70000]}""").isErr
      check shapeOf("go").fromJson("""{"n": 1, "t": "x", "pair": [3]}""").isErr

    test "choices: one reading is taken, two different ones are refused":
      let e = shapeOf("go").fromJson("""{"n": 1, "t": "x", "either": 5}""")
      check e.isOk and e.get.field("either") == cbor(5'u64)
      let s = shapeOf("go").fromJson("""{"n": 1, "t": "x", "either": "5"}""")
      check s.isOk and s.get.field("either") == cbor("5")
      let amb = shapeOf("go").fromJson("""{"n": 1, "t": "x", "raw": "abcd"}""")
      check amb.isErr and "ambiguous" in amb.error
      check shapeOf("multi").fromJson("""{"kind": "a", "a": 1}""").isOk
      check shapeOf("multi").fromJson("""{"kind": "b", "b": "q"}""").isOk
      check shapeOf("multi").fromJson("""{"kind": "c"}""").isErr

    test "floats, null, duplicate keys and malformed text are refused":
      let f = shapeOf("go").fromJson("""{"n": 1.0, "t": "x"}""")
      check f.isErr and "float" in f.error
      check shapeOf("go").fromJson("""{"n": 1, "t": null}""").isErr
      let d = shapeOf("go").fromJson("""{"n": 1, "t": "x", "n": 2}""")
      check d.isErr and "twice" in d.error
      for bad in [
        "",
        "{",
        """{"n": 1, "t": "x"} x""",
        """{"n": 1,}""",
        """{n: 1}""",
        """{"n": 01, "t": "x"}""",
        """{"n": 1, "t": "\ud800"}""",
        """{"n": 1, "t": "a""" & "\x01" & """"}""",
        "\xFF",
      ]:
        checkpoint bad
        check shapeOf("go").fromJson(bad).isErr

    test "escapes, surrogate pairs and depth":
      let v = shapeOf("go").fromJson("""{"n": 1, "t": "é😀"}""")
      check v.isOk and v.get.field("t") == cbor("é\u{1F600}")
      let deep = repeat("[", 300) & repeat("]", 300)
      let r = shapeOf("go").fromJson("""{"n": 1, "t": "x", "list": """ & deep & "}")
      check r.isErr

  suite "cli.present: output to the launcher's descriptors (G89, G349) [IMPL]":
    test "DEL and C1 controls are escaped; other text is unchanged":
      check terminalSafe("a\x7Fb\xC2\x9Bc") == "a\\u007fb\\u009bc"
      check terminalSafe("é\xC2\xA0x") == "é\xC2\xA0x"
      check terminalSafe("") == ""

    test "a pipe receives everything":
      let p = mkpipe()
      let s = sinkOf(p[1], -1)
      check s.put("hello").isOk
      check readAvailable(p[0]) == "hello"
      closeFds(p[0], p[1])

    test "the launcher's cancel stops a write":
      let p = mkpipe()
      let c = pair()
      discard posix.close(c[0])
      let s = sinkOf(p[1], c[1])
      let r = s.put("never")
      check r.isErr and r.error == seCancelled
      check readAvailable(p[0], 100) == ""
      closeFds(p[0], p[1], c[1])

    test "a closed reader ends the write":
      let p = mkpipe()
      discard posix.close(p[0])
      let r = sinkOf(p[1], -1).put("x")
      check r.isErr and r.error == seClosed
      closeFds(p[1])

    test "a regular file takes a large write at once":
      let dir = createTempDir("lcn-cli", "")
      let path = dir / "out"
      let fd = posix.open(cstring(path), O_WRONLY or O_CREAT or O_TRUNC, 0o600)
      check fd >= 0
      let big = repeat('z', 200_000)
      check sinkOf(fd, -1).put(big).isOk
      discard posix.close(fd)
      check readFile(path) == big
      removeDir(dir)

    test "JSON: one envelope with the result as G89 renders it":
      let p = mkpipe()
      let e = mkpipe()
      let pr = Presenter(
        json: true,
        deployment: "non-production",
        command: "call shapes ping",
        output: sinkOf(p[1], -1),
        errors: sinkOf(e[1], -1),
      )
      check pr.doneValue(cborMap((cbor("b"), cbor(@[1'u8, 2])))).isOk
      let line = readAvailable(p[0])
      check line.endsWith("\n")
      let j = parseJson(line)
      check j["deployment"].getStr == "non-production"
      check j["command"].getStr == "call shapes ping"
      check j["status"].getStr == "ok"
      check j["result"]["b"].getStr == "0102"
      check readAvailable(e[0], 50) == ""
      closeFds(p[0], p[1], e[0], e[1])

    test "text: the banner first, failures on stderr, declared text labelled and escaped":
      let p = mkpipe()
      let e = mkpipe()
      let pr = Presenter(
        json: false,
        deployment: "non-production",
        command: "call shapes ping",
        output: sinkOf(p[1], -1),
        errors: sinkOf(e[1], -1),
      )
      check pr.doneValue(cbor("ok")).isOk
      check readAvailable(p[0]) == Banner & "\n\"ok\"\n"
      check pr.failed("MODULE_ERROR", "bad\x1B[2Jthing\xC2\x9B", declared = true).isOk
      let err = readAvailable(e[0])
      check err.startsWith(Banner & "\nlogosctl: MODULE_ERROR: ")
      check "(declared)" in err
      check '\x1B' notin err
      check "\xC2\x9B" notin err
      closeFds(p[0], p[1], e[0], e[1])

    test "production: no banner":
      let p = mkpipe()
      let pr = Presenter(
        json: false,
        deployment: "production",
        command: "c",
        output: sinkOf(p[1], -1),
        errors: sinkOf(p[1], -1),
      )
      check pr.doneValue(cbor(1'u64)).isOk
      check readAvailable(p[0]) == "1\n"
      closeFds(p[0], p[1])

  # N-2b's pure rules -------------------------------------------------------------

  proc continuation(
      runtime: Opt[string], provider: Opt[string], facade = "facade"
  ): LogosNSRuntimeControlRouteContinuation =
    LogosNSRuntimeControlRouteContinuation(
      provider: LogosNSRuntimeModuleProviderAddress(
        provider: facade, runtime_instance_id: Opt.some("rt-facade")
      ),
      target: LogosNSRuntimeControlRemoteProviderTarget(
        provider: provider,
        runtime: LogosNSRuntimeControlRuntimeEndpoint(runtime_instance_id: runtime),
      ),
    )

  suite "cli.hops: the continuation rule (G347; R l.3052-3058) [IMPL]":
    let nodes = @[
      ConfiguredNode(name: "east", runtimeId: "rt-east"),
      ConfiguredNode(name: "west", runtimeId: "rt-west"),
    ]
    let first = @[HopStep(runtimeId: "rt-east", provider: "p0")]

    test "a configured node is followed through its binding, selecting the target's provider":
      let h = nextHop(
        nodes, "rt-own", first, continuation(Opt.some("rt-west"), Opt.some("p1"))
      )
      check h.isOk
      check h.get.node == "west" # the configured node, never the continuation's address
      check h.get.provider == "p1" # the target's provider, not the facade's
      check h.get.step == HopStep(runtimeId: "rt-west", provider: "p1")

    test "a target that matches no configured node is refused, naming it (1)":
      let h = nextHop(
        nodes, "rt-own", first, continuation(Opt.some("rt-far"), Opt.some("p1"))
      )
      check h.isErr and h.error.exit == ExitRefused
      check "rt-far" in h.error.message and "p1" in h.error.message

    test "a target on lcn_call's own Runtime is refused (1; IF l.3875)":
      let h = nextHop(
        nodes, "rt-own", first, continuation(Opt.some("rt-own"), Opt.some("p1"))
      )
      check h.isErr and h.error.exit == ExitRefused
      check "without --node" in h.error.message

    test "a target without its Runtime id or provider is a fault (4; R l.3054)":
      for c in [
        continuation(Opt.none(string), Opt.some("p1")),
        continuation(Opt.some("rt-west"), Opt.none(string)),
      ]:
        let h = nextHop(nodes, "rt-own", first, c)
        check h.isErr and h.error.exit == ExitRc and h.error.code == $ecModule

    test "a repeated (Runtime id, provider) pair is a cycle (4), the facade not in the key":
      let back = nextHop(
        nodes, "rt-own", first, continuation(Opt.some("rt-east"), Opt.some("p0"))
      )
      check back.isErr and back.error.exit == ExitRc
      # The same target behind another facade is still the same pair.
      let again = nextHop(
        nodes,
        "rt-own",
        first,
        continuation(Opt.some("rt-east"), Opt.some("p0"), facade = "other"),
      )
      check again.isErr and again.error.exit == ExitRc
      # Another provider on the same Runtime is not a cycle.
      check nextHop(
        nodes, "rt-own", first, continuation(Opt.some("rt-east"), Opt.some("p2"))
      ).isOk

    test "the fifth target is refused (4)":
      var path: seq[HopStep] = @[]
      for i in 0 ..< MaxHops:
        path.add(HopStep(runtimeId: "rt-" & $i, provider: "p" & $i))
      let h = nextHop(
        nodes, "rt-own", path, continuation(Opt.some("rt-west"), Opt.some("p9"))
      )
      check h.isErr and h.error.exit == ExitRc
      check nextHop(
        nodes,
        "rt-own",
        path[0 ..< MaxHops - 1],
        continuation(Opt.some("rt-west"), Opt.some("p9")),
      ).isOk

  proc rec(
      state: LogosNSRuntimeControlStateKind,
      intent = Opt.none(LogosNSRuntimeControlExecutionStateIntentChoiceKind),
      revision = 7'u64,
  ): LogosNSRuntimeControlModuleRecord =
    result = LogosNSRuntimeControlModuleRecord(
      module: "lcn_call",
      instance: Opt.some("lcn_call"),
      state: LogosNSRuntimeControlState(kind: state),
    )
    if intent.isSome:
      result.execution = Opt.some(
        LogosNSRuntimeControlExecutionState(
          intent: LogosNSRuntimeControlExecutionStateIntentChoice(kind: intent.get),
          revision: revision,
        )
      )

  suite "cli.activation: the launcher's decisions (G344; R l.578, l.1819, l.3403, l.3512, l.3634) [IMPL]":
    type S = LogosNSRuntimeControlStateKind
    type I = LogosNSRuntimeControlExecutionStateIntentChoiceKind

    test "unloaded starts, whatever was done before":
      check nextAct(rec(S.Unloaded), Opt.none(uint64)).kind == akStart
      check nextAct(rec(S.Unloaded, Opt.some(I.Stopped)), Opt.some(3'u64)).kind ==
        akStart

    test "error with requested intent recovers at the record's revision":
      let a = nextAct(rec(S.Error, Opt.some(I.Requested), 9), Opt.none(uint64))
      check a.kind == akRecover and a.revision == 9

    test "error with any other intent starts (recovery would be refused)":
      for i in [I.Stopped, I.Uninitialized]:
        check nextAct(rec(S.Error, Opt.some(i)), Opt.none(uint64)).kind == akStart
      check nextAct(rec(S.Error), Opt.none(uint64)).kind == akStart

    test "loaded, stopping and ready wait":
      for st in [S.Loaded, S.Stopping, S.Ready]:
        check nextAct(rec(st, Opt.some(I.Requested)), Opt.none(uint64)).kind == akWait

    test "error at another revision after our accepted request is our failed attempt (4)":
      check nextAct(rec(S.Error, Opt.some(I.Requested), 8), Opt.some(7'u64)).kind ==
        akFailed
      # The same revision: our request has not taken effect; act again.
      check nextAct(rec(S.Error, Opt.some(I.Requested), 7), Opt.some(7'u64)).kind ==
        akRecover

    test "NOT_READY and stale-revision read again; anything else is a fault":
      check answerOf($ecNotReady) == anReread
      check answerOf($ecNotAuthorised) == anFault
      check answerOf(
        LogosNSRuntimeControlError(
          code: LogosNSRuntimeControlErrorCode(
            kind: LogosNSRuntimeControlErrorCodeKind.Stale_revision
          )
        )
      ) == anReread
      for k in [
        LogosNSRuntimeControlErrorCodeKind.Configuration_rejected,
        LogosNSRuntimeControlErrorCodeKind.Declaration_unavailable,
      ]:
        check answerOf(
          LogosNSRuntimeControlError(code: LogosNSRuntimeControlErrorCode(kind: k))
        ) == anFault

  func failed(code: ErrorCode, prepared = true, cancelled = false): CallResult =
    CallResult(
      ok: false,
      failure: Failure(code: code, message: "m"),
      prepared: prepared,
      cancelled: cancelled,
    )

  suite "cli.classify: a call's failure, total over the codes (G348, G349; R l.1259-1272; IF l.3308-3311) [IMPL]":
    test "prepare_call NOT_READY, NOT_AUTHORISED or TRANSPORT_ERROR is retried; nothing else from it":
      for c in [ecNotReady, ecNotAuthorised, ecTransport]:
        check failed(c, prepared = false).retryable
      for c in [ecInvalidParams, ecModule, ecTimeout, ecCancelled]:
        check not failed(c, prepared = false).retryable

    test "a completion is retried only for NOT_READY and NOT_AUTHORISED":
      for c in ErrorCode:
        if c == ecOk:
          continue
        check failed(c).retryable == (c in {ecNotReady, ecNotAuthorised})
      check not failed(ecNotReady, cancelled = true).retryable

    test "every code has an exit":
      for c in ErrorCode:
        if c == ecOk:
          continue
        let s = classify(failed(c))
        let want =
          case c
          of ecTransport, ecTimeout, ecCancelled: ExitUnreachable
          of ecMethodNotFound, ecInvalidParams, ecModule: ExitProvider
          else: ExitRc
        check s.exit == want
        check s.code == $c

    test "outcome unknown is said for TRANSPORT_ERROR, TIMEOUT and a CANCELLED not asked for":
      for c in [ecTransport, ecTimeout, ecCancelled]:
        check "outcome is unknown" in classify(failed(c)).message

    test "a TRANSPORT_ERROR from prepare_call is unreachable, not unknown":
      let s = classify(failed(ecTransport, prepared = false))
      check s.exit == ExitUnreachable and "could not reach" in s.message

    test "a cancel the launcher asked for is 130 and silent":
      let s = classify(failed(ecCancelled, cancelled = true))
      check s.exit == ExitInterrupted and s.silent

    test "the provider's codes are labelled declared":
      check classify(failed(ecModule)).declared
      check not classify(failed(ecNotReady)).declared

  # An extended contract view (R l.90-91), built in process as
  # sdk/tests/test_call_surface.nim does: no fixture carries `extends`.
  const
    unitsDoc = "units.count = uint64\n"
    tagsDoc = "tags.label = tstr\n"
    alphaDoc =
      "_interface = \"alpha\"\n\nalpha.get_request = {}\nalpha.get_response = {\n  n: units.count,\n}\n"

  proc rootOf(doc: string, supp: openArray[string] = []): Digest =
    let r = acceptContractSet(doc, [], supp)
    if r.isErr:
      checkpoint r.error
    r.get.primary.root

  proc implementing(roots: varargs[Digest]): string =
    var rs = @roots
    rs.sort(
      proc(a, b: Digest): int =
        cmpBytes(a, b)
    )
    "_implements = [" & rs.mapIt("h'" & toHex(it) & "'").join(", ") & "]\n"

  suite "cli.views: --contract takes every exact contract view (R l.90-91; IF l.3905) [IMPL]":
    let alphaRoot = rootOf(alphaDoc, [unitsDoc])
    let oldDoc =
      "_module = \"demo_module\"\n" & implementing(alphaRoot) &
      "\ndemo.ping_request = {}\ndemo.ping_response = {\n  label: tags.label,\n}\n"
    let nextDoc = oldDoc & "demo.pong_request = {}\ndemo.pong_response = {}\n"
    let oldRoot =
      acceptContractSet(oldDoc, [alphaDoc], [unitsDoc, tagsDoc]).get.primary.root
    let b = acceptBinding(
      "demo_module",
      Opt.some(nextDoc),
      [alphaDoc],
      [unitsDoc, tagsDoc],
      AcceptOptions(),
      [oldDoc],
    )

    test "the extended view is a contract view and projects":
      check b.isOk
      let views = b.get.contractViews
      check oldRoot in views and alphaRoot in views and b.get.primary.get.root in views
      let p = projectView(b.get, "demo_module", oldRoot)
      check p.isOk
      let (set, _) = p.get
      check set.primary.root == oldRoot
      let names = callSurface(set).methods.mapIt(it.bare)
      check "ping" in names and "pong" notin names

    test "a root that is no view of the provider does not project":
      var other = oldRoot
      other[0] = other[0] xor 0xff
      check projectView(b.get, "demo_module", other).isErr
