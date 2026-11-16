## The CLI's pieces that need no Runtime (Tier 5 step N-2a; DECISIONS G344,
## G345, G347, G349; D26 (a); docs/DAEMON.md §7a): the launcher socket's
## frames with descriptors, the request checks, the typing of arguments from a
## request rule, the `--json` reader, and the output written to the
## launcher's descriptors. `test_lcn_call` runs the module itself.

when defined(posix):
  import std/[json, os, strutils, tempfiles]
  import unittest2
  import ../src/logos_core/cbor
  import ../src/logos_core/iface/[accept, surface]
  import ../src/logos_core/daemon/render
  import ../src/logos_core/transport/io/sock
  import ../src/logos_core/cli/[args, present, wire]
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
      check sockSendFds(s[0], unsafeAddr header[0], 4, addr ten[0], 10) == 4
      let body = [7'u8, 7]
      check sockSendFds(s[0], unsafeAddr body[0], 2, addr ten[0], 10) == 2
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
        check sockSendFds(s[0], unsafeAddr partial[0], 5, unsafeAddr a[1], 1) == 5
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
      check p.isErr and "--json" in p.error
      let u = typed(text("zzz", "1"))
      check u.isErr and "no field" in u.error and
        "point?: cliargs.point (map) (--json)" in u.error
      let d = typed(text("n", "6"))
      check d.isErr and "twice" in d.error
      let m = shapeOf("go").fromArgs(@[text("n", "1")])
      check m.isErr and "needs t" in m.error

    test "a request rule that is a choice takes --json only":
      let r = shapeOf("multi").fromArgs(@[text("kind", "a")])
      check r.isErr and "--json" in r.error

    test "@FILE: text must be UTF-8, byte strings are raw, other kinds take key=value":
      let ok1 =
        shapeOf("go").fromArgs(@[text("n", "1"), file("t", @[0x68'u8, 0xC3, 0xA9])])
      check ok1.isOk and ok1.get.field("t") == cbor("hé")
      check shapeOf("go").fromArgs(@[text("n", "1"), file("t", @[0xFF'u8])]).isErr
      let raw = typed(file("b", @[0'u8, 1, 2]))
      check raw.isOk and raw.get.field("b") == cbor(@[0'u8, 1, 2])
      check shapeOf("go").fromArgs(@[file("n", @[0x31'u8]), text("t", "x")]).isErr
      # tstr / bstr: UTF-8 bytes read both ways; other bytes only as bstr
      check typed(file("raw", @[0x61'u8])).isErr
      let only = typed(file("raw", @[0xFF'u8]))
      check only.isOk and only.get.field("raw") == cbor(@[0xFF'u8])

  suite "cli.json: --json as G89 writes values (D26 (a), G349)":
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
