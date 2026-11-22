## The remote program's listener processes and their end (Tier 5 step 5-7a-2;
## DECISIONS G410, G411; owner decision B3; 5-7a plan §3.1, "Ending with
## logosd"). As processes: logosd with a tls-tcp listener record, whose
## process serves an enrolled peer (a client built on the carrier,
## `support/tls_fixtures`) with logosd's certificate and signer; logosd
## SIGKILLed with a connection open, wedged, or stopped in order; a restart
## lock held; a stopped process (PDEATHSIG on Linux, the lock as the backstop
## on macOS). And `logos_remote` under a harness: fd 3 closed, a parent
## already gone, no descriptors.
##
## The case of a listener enabled through Runtime Control on a worker thread
## that then ends (the spawning thread) needs inbound Runtime Control: it is
## `test_remote_rc`'s.

when defined(posix):
  import std/[os, posix, strutils]
  from std/times import epochTime
  import unittest2
  import logos_sdk/cbor
  import logos_sdk/base/parentwatch
  import
    ../src/logos_core/daemon/[
      config, credential, daemon_config_types, remoteside, remotetrust, session,
      sessioninit,
    ]
  import ../src/logos_core/runtime/host
  from ../src/logos_core/runtime/hostsup import nil # compiles hostspawn.c
  import ./support/[daemonbuild, daemonproc, rchannel, shortdir, slowdown, tls_fixtures]

  var environ {.importc.}: cstringArray

  proc lcnSpawn(
    path: cstring,
    argv, envp: cstringArray,
    carrier, listener, lock: cint,
    pid: ptr cint,
  ): cint {.importc: "lcn_host_spawn", cdecl.}

  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}

  const
    ReadyMs = 120_000 * Slow
    StopMs = 60_000 * Slow
    EndMs = 2_000 * Slow ## [plan §3.1] the peer and the process see the end in 2 s
    ExitLost = 70
    ExitUsage = 2

  let
    dExe = logosdProgram()
    ctlExe = logosctlProgram()
    rExe = remoteProgram()
    a = newParty(IdA) # the enrolled peer

  # Helpers -----------------------------------------------------------------------------------

  proc textOf(b: openArray[byte]): string =
    result = newString(b.len)
    for i, x in b:
      result[i] = char(x)

  proc freePort(): uint16 =
    ## A loopback port nothing listens on now.
    let fd = socket(posix.AF_INET, posix.SOCK_STREAM, 0)
    doAssert fd.cint >= 0
    var sa: Sockaddr_in
    sa.sin_family = TSa_Family(posix.AF_INET)
    sa.sin_addr.s_addr = htonl(0x7f000001'u32)
    doAssert bindSocket(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) == 0
    var len = SockLen(sizeof(sa))
    doAssert getsockname(fd, cast[ptr SockAddr](addr sa), addr len) == 0
    result = ntohs(sa.sin_port)
    discard close(fd)

  proc boundListener(): (cint, uint16) =
    ## A listening loopback socket, close-on-exec, and its port.
    let fd = socket(posix.AF_INET, posix.SOCK_STREAM, 0)
    doAssert fd.cint >= 0
    discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)
    var sa: Sockaddr_in
    sa.sin_family = TSa_Family(posix.AF_INET)
    sa.sin_addr.s_addr = htonl(0x7f000001'u32)
    doAssert bindSocket(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) == 0
    doAssert listen(fd, 16) == 0
    var len = SockLen(sizeof(sa))
    doAssert getsockname(fd, cast[ptr SockAddr](addr sa), addr len) == 0
    (fd.cint, ntohs(sa.sin_port))

  proc gone(pid: Pid, ms: int): bool =
    ## `pid` no longer exists within `ms`. A child of this process is reaped.
    let until = epochTime() + float(ms) / 1000
    while true:
      var status: cint
      discard waitpid(pid, status, WNOHANG)
      if kill(pid, 0) != 0 and errno == ESRCH:
        return true
      if epochTime() > until:
        return false
      sleep(10)

  proc closedWithin(s: TlsStream, ms: int): bool =
    ## The peer sees its connection end within `ms`: the read ends, with no
    ## frame.
    let f = s.readFrame()
    if not waitFor f.withTimeout(milliseconds(ms)):
      f.cancelSoon()
      return false
    let r = f.read()
    r.isErr or r.get.isNone

  # logosd with a listener ---------------------------------------------------------------------

  var cases = 0

  type Case = object
    dir: string
    s: Session
    port: uint16
    rid: string ## logosd's Runtime id
    server: Party ## logosd's credential, as the peer pins it (no key)

  proc ctl(c: Case, args: varargs[string]): Ran =
    runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "--text"] & @args,
      c.dir,
      timeoutMs = 120_000 * Slow,
    )

  proc enroll(c: Case, revision: uint64, active: bool) =
    let anchor = LcnRemoteAnchor(id: anchorIdOf(a.cert), certificate: a.cert)
    let record =
      if active:
        remotetrust.activeRecord(
          a.id, params.TlsTcpProfile, revision, anchorIdOf(a.cert), @[a.spki]
        ).get
      else:
        revokedRecord(a.id, params.TlsTcpProfile, revision).get
    check writeRemoteTrustFile(
      c.s,
      LcnRemoteTrust(revision: revision, anchors: @[anchor], enrollments: @[record]),
    ).isOk

  proc newCase(holder = false): Case =
    ## A session with remote on, one enabled tls-tcp listener on a free
    ## loopback port, a TLS credential and `a` enrolled.
    inc cases
    result.dir = makeShortBase("lrl" & $cases, deepest = "/s/run/logosctl.sock")
    result.s = Session(dir: result.dir / "s")
    result.port = freePort()
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.runtime.remote_program = Opt.some(rExe)
    let address = LcnRcRemoteListenerAddress(
      kind: LcnRcRemoteListenerAddressKind.lcn_Rc_tls_tcp_runtime_address,
      arm_lcn_Rc_tls_tcp_runtime_address:
        LcnRcTlsTcpRuntimeAddress(host: "127.0.0.1", port: result.port),
    )
    var remote = LcnDcRemote(
      enabled: true,
      listeners: Opt.some(
        @[
          LcnRcRemoteListenerRecord(
            address: address, enabled: true, runtime_control_enabled: true
          )
        ]
      ),
    )
    if holder:
      remote.signing =
        Opt.some(LcnDcRemoteSigning(kind: LcnDcRemoteSigningKind.Key_holder))
      remote.key_holder = Opt.some(keyholderProgram())
    dc.remote = Opt.some(remote)
    let path = result.dir / "config.cbor"
    writeFile(path, textOf(dc.encode.expect("an encoding")))
    check result.ctl("init", "--config", "@" & path).code == 0
    check result.ctl("remote", "trust", "init").code == 0
    check result.ctl("remote", "credential", "new").code == 0
    result.enroll(2, active = true)
    let (raw, _) = readDaemonConfig(result.s).expect("the configuration")
    result.rid = raw.runtime.runtime_instance_id
    let cred = currentCredential(result.s).expect("the credential").get
    result.server = Party(id: result.rid, cert: cred.certificate, spki: cred.spki)

  proc start(c: Case, env: openArray[(string, string)] = []): Child =
    spawnChild(dExe, ["--session-dir", c.s.dir], c.dir, "logosd", env)

  proc ready(c: Case, d: Child): bool =
    ## The socket answers `status`, or the daemon ended.
    for _ in 0 ..< ReadyMs div 20:
      if not d.alive:
        return false
      if entryExists(c.s.socketPath) and c.ctl("status").code == 0:
        return true
      sleep(20)
    false

  proc lockPaths(c: Case): seq[string] =
    let dir = remoteLockDir(c.s.workDir)
    if dirExists(dir):
      for kind, path in walkDir(dir):
        if kind == pcFile and path.endsWith(".lock"):
          result.add(path)

  proc listenerPid(c: Case): Pid =
    ## The pid the listener process wrote into its restart lock.
    let paths = c.lockPaths
    if paths.len != 1:
      return Pid(-1)
    try:
      Pid(parseInt(readFile(paths[0]).strip))
    except IOError, ValueError:
      Pid(-1)

  proc dial(c: Case): Result[TlsStream, string] =
    result = waitFor connect(
      TlsTcpAddress(host: "127.0.0.1", port: c.port),
      clientContext(a),
      pinnedCheck([c.server]),
      keySigner(a.key, tlsClient),
      fastConfig(),
    )
    if result.isErr:
      checkpoint("dial: " & result.error)

  proc refused(c: Case): bool =
    ## The listener refuses the peer: in TLS 1.3 the client's handshake ends
    ## before the server checks its certificate, so the refusal is the
    ## connection's end, at once.
    let s = c.dial()
    if s.isErr:
      return true
    result = s.get.closedWithin(EndMs)
    waitFor s.get.close()

  suite "remote: the listener process and its end [plan §3.1; owner decision B3]":
    teardown:
      # As below (ISSUES.md 194).
      killAll()

    test "[IMPL-DECISION G411] [IMPL-DECISION G410] logosd starts an enabled listener's process, which serves an enrolled peer with logosd's certificate and signer; SIGKILL of logosd ends it and the peer's connection within 2 s and frees its lock; a restart with the peer revoked refuses its handshake":
      let c = newCase()
      let d = c.start()
      check c.ready(d)
      let pid = c.listenerPid
      check pid > 0 and kill(pid, 0) == 0
      let s = c.dial()
      check s.isOk
      if s.isOk:
        check s.get.peer.runtime == c.rid
      # [B3] logosd killed: the kernel ends the process, and its connections.
      killChild(d)
      if s.isOk:
        check s.get.closedWithin(EndMs)
      check pid.gone(EndMs)
      check checkRemoteLocks(c.s.workDir).isOk
      # A restart with the peer's enrollment revoked: its handshake fails.
      c.enroll(3, active = false)
      let d2 = c.start()
      check c.ready(d2)
      check c.refused()
      check stopChild(d2, StopMs) == 0
      if s.isOk:
        waitFor s.get.close()

    test "[IMPL-DECISION G410] the key-holder mode: logosd starts logos_keyholder and relays the listener's sign requests to it; the holder ends with logosd":
      let c = newCase(holder = true)
      let d = c.start()
      check c.ready(d)
      let s = c.dial()
      check s.isOk
      if s.isOk:
        check s.get.peer.runtime == c.rid
        waitFor s.get.close()
      check stopChild(d, StopMs) == 0
      let log = d.errText
      check "remote signing: the key holder runs as process" in log
      check "signed by key-holder" in log

    test "[plan §3.1 item 3] [IMPL-DECISION G411] a restart lock another process holds: logosd refuses to start, naming the lock and the pid written in it":
      let c = newCase()
      let dir = remoteLockDir(c.s.workDir)
      createDir(dir)
      let path = dir / "listener-00000000000000000000000000000000.lock"
      writeFile(path, "424242\n")
      let fd = open(cstring(path), O_RDWR or O_CLOEXEC)
      check fd >= 0
      check flock(fd, 2) == 0 # LOCK_EX
      let d = c.start()
      check waitExit(d, ReadyMs) == 1
      let log = d.errText
      check path in log and "by process 424242" in log
      discard close(fd)
      let d2 = c.start()
      check c.ready(d2)
      check stopChild(d2, StopMs) == 0

    test "[plan §3.1 item 2] a wedged event loop (a test hook blocks it after listening): SIGKILL of logosd still ends the process within 2 s, by its watcher thread":
      let c = newCase()
      let d = c.start([("LCN_REMOTE_TEST_WEDGE_MS", "600000")])
      check c.ready(d)
      let pid = c.listenerPid
      check pid > 0
      sleep(500) # the wedge holds the loop from 200 ms after listening
      killChild(d)
      check pid.gone(EndMs)

    test "[plan §3.1 items 1 and 3] a stopped process ends with logosd: on Linux by its parent-death signal, and on both systems as a stopped member of an orphaned process group (SIGHUP, then SIGCONT); the next start succeeds":
      let c = newCase()
      let d = c.start()
      check c.ready(d)
      let pid = c.listenerPid
      check pid > 0
      check kill(pid, SIGSTOP) == 0
      killChild(d)
      check pid.gone(EndMs)
      check checkRemoteLocks(c.s.workDir).isOk
      let d2 = c.start()
      check c.ready(d2)
      check stopChild(d2, StopMs) == 0

    test "[plan §3.1 item 5] an orderly stop: every process is gone and every lock free before logosd exits, and a restart at once succeeds":
      let c = newCase()
      let d = c.start()
      check c.ready(d)
      let pid = c.listenerPid
      check pid > 0
      check stopChild(d, StopMs) == 0
      check kill(pid, 0) != 0 and errno == ESRCH
      check checkRemoteLocks(c.s.workDir).isOk
      let d2 = c.start()
      check c.ready(d2)
      check c.dial().isOk
      check stopChild(d2, StopMs) == 0

  # logos_remote under a harness ---------------------------------------------------------------

  proc spawnRemote(args: openArray[string], carrier, listener, lock: cint): Pid =
    var strs = @["logos_remote"] & @args
    var argv = allocCStringArray(strs)
    defer:
      deallocCStringArray(argv)
    var pid: cint = -1
    doAssert lcnSpawn(cstring(rExe), argv, environ, carrier, listener, lock, addr pid) ==
      0
    Pid(pid)

  proc exitOf(pid: Pid, ms: int): int =
    let until = epochTime() + float(ms) / 1000
    while true:
      var status: cint
      let r = waitpid(pid, status, WNOHANG)
      if r == pid:
        if WIFEXITED(status):
          return int(WEXITSTATUS(status))
        return 128 + int(WTERMSIG(status))
      if epochTime() > until:
        discard kill(pid, SIGKILL)
        discard waitpid(pid, status, 0)
        return -1
      sleep(10)

  suite "remote: logos_remote under a harness [plan §3.1]":
    teardown:
      # Leaves daemonproc's list of children empty before the program ends:
      # under orc its exit procedure would free it a second time
      # (build/scratch/upstream/ISSUES.md 194).
      killAll()

    test "[plan §3.1 item 1] the control channel closed (fd 3): the process exits at once and its peer's connection ends":
      let server = newParty(IdB)
      let (mine, theirs) = socketPair()
      let (lfd, port) = boundListener()
      let work = makeShortBase("lrh")
      let lockFd =
        open(cstring(work / "l.lock"), O_RDWR or O_CREAT or O_CLOEXEC, Mode(0o600))
      let pid = spawnRemote(["listener", ParentFlag & $getpid()], theirs, lfd, lockFd)
      discard close(theirs)
      discard close(lfd)
      discard close(lockFd)
      let e = endOf(mine)
      check waitFor e.send(snapshotMessage(enrolled([a])))
      check waitFor e.send(
        toMessage(
          LcnRchListen(certificate: server.cert, limits: limitsOf(fastConfig()))
        )
      )
      var listening = false
      let pump = proc() {.async: (raises: []).} =
        var p = newProcessSigning(tlsServer)
        var count: SignCount
        while true:
          let m = (await e.receive()).valueOr:
            return
          case m.kind
          of LcnRchMessageKind.lcn_Rch_listening:
            listening = true
          of LcnRchMessageKind.lcn_Rch_sign:
            let q = m.arm_lcn_Rch_sign
            let r =
              signWith(server.key, tlsServer, q.alg, q.input, p.limit, count, monoNs())
            if not await e.send(signAnswer(q.id, r)):
              return
          else:
            discard
      asyncSpawn pump()
      for _ in 0 ..< ReadyMs div 10:
        if listening:
          break
        waitFor sleepAsync(milliseconds(10))
      check listening
      let s = waitFor connect(
        TlsTcpAddress(host: "127.0.0.1", port: port),
        clientContext(a),
        pinnedCheck([server]),
        keySigner(a.key, tlsClient),
        fastConfig(),
      )
      if s.isErr:
        checkpoint(
          "dial: " & s.error & "; the channel read " & $e.got & ", wrote " & $e.sent
        )
      check s.isOk
      check readFile(work / "l.lock").strip == $pid
      waitFor e.close()
      check exitOf(pid, EndMs) == ExitLost
      if s.isOk:
        check s.get.closedWithin(EndMs)
        waitFor s.get.close()

    test "[plan §3.1, the macOS order] a parent already gone when the process starts: it exits at once; started without its descriptors or role, it exits 2":
      let work = makeShortBase("lrg")
      # A pid that existed and ended: a child of this process, reaped.
      let child = spawnChild("/bin/sh", ["-c", "exit 0"], work, "gone")
      check waitExit(child, EndMs) == 0
      let gonePid = child.pid
      let (mine, theirs) = socketPair()
      let (lfd, _) = boundListener()
      let lockFd =
        open(cstring(work / "l.lock"), O_RDWR or O_CREAT or O_CLOEXEC, Mode(0o600))
      let pid = spawnRemote(["listener", ParentFlag & $gonePid], theirs, lfd, lockFd)
      discard close(theirs)
      check exitOf(pid, EndMs) == ExitLost
      # Not as logosd starts it.
      let bare = spawnRemote(["listener"], mine, lfd, lockFd)
      check exitOf(bare, EndMs) == ExitUsage
      let noRole = spawnRemote([ParentFlag & $getpid()], mine, lfd, lockFd)
      check exitOf(noRole, EndMs) == ExitUsage
      discard close(mine)
      discard close(lfd)
      discard close(lockFd)
