## G128 (step 5-2c): runs `tlspeer.py`, the independent pyOpenSSL peer, for
## `test_remote_tls.nim`. `LCN_TLS_PEER_PYTHON` names an interpreter that has
## pyOpenSSL; the suite's Nix checks set it, and without it the peer tests skip.

import std/[os, posix, strutils, tables, tempfiles]
import chronos
import ./[peerproc, slowdown]

const PeerScript = currentSourcePath().parentDir / "tlspeer.py"

type
  PeerBench* = object
    ## A directory holding the peer's own key and certificate, and ours.
    dir: string
    ownCert: string ## the path of the certificate the peer must see
    cert*: seq[byte] ## the certificate the peer made for itself (DER)

  PyPeer* = object
    process: Peer
    port*: uint16 ## a server's listening port

proc peerPython*(): string =
  getEnv("LCN_TLS_PEER_PYTHON")

proc start(args: openArray[string]): Peer =
  spawnPeer(
    peerPython(),
    @["-I", "-B", PeerScript] & @args,
    withCtl = false,
    captureStdout = true,
  )

proc newPeerBench*(ownCert: seq[byte]): PeerBench =
  ## The peer makes its key and certificate; ours is left for it to pin.
  result.dir = createTempDir("lcn-tlspeer", "")
  result.ownCert = result.dir / "own.der"
  writeFile(result.ownCert, ownCert)
  var keygen = start(["keygen", result.dir])
  doAssert keygen.waitPeer(30_000 * Slow) == 0, "tlspeer.py keygen failed"
  let der = readFile(result.dir / "cert.der")
  result.cert = @(der.toOpenArrayByte(0, der.high))

proc remove*(b: PeerBench) =
  removeDir(b.dir)

proc startServer*(b: PeerBench, options: openArray[string] = []): PyPeer =
  ## A pyOpenSSL server that listens by the time this returns.
  result.process = start(@["server", b.dir, b.ownCert] & @options)
  let line = result.process.readLine(30_000 * Slow)
  doAssert line.startsWith("port="), "tlspeer.py server said: " & line
  result.port = uint16(parseInt(line[5 .. ^1]))

proc startClient*(b: PeerBench, port: uint16, options: openArray[string] = []): PyPeer =
  ## A pyOpenSSL client that connects to `port`.
  result.process = start(@["client", b.dir, b.ownCert, $port] & @options)

proc finish*(p: var PyPeer): Table[string, string] =
  ## Runs the event loop until the peer ends, and gives its report; `exit` is
  ## its exit status. A peer that outlives the deadline is killed.
  var text = ""
  var chunk: array[4096, char]
  let until = Moment.now() + milliseconds(60_000 * Slow)
  while true:
    var ready = TPollfd(fd: p.process.output, events: POLLIN)
    if posix.poll(addr ready, 1, 0) > 0:
      let n = posix.read(p.process.output, addr chunk[0], chunk.len)
      if n <= 0:
        break
      text.add(chunk.toOpenArray(0, n - 1).join(""))
    elif Moment.now() > until:
      break
    else:
      waitFor sleepAsync(milliseconds(2))
  for line in text.splitLines():
    let at = line.find('=')
    if at > 0:
      result[line[0 ..< at]] = line[at + 1 .. ^1]
  if Moment.now() > until:
    p.process.killPeer()
    result["exit"] = "killed at the deadline"
  else:
    result["exit"] = $p.process.waitPeer(10_000 * Slow)

func hexOf*(bytes: openArray[byte]): string =
  for b in bytes:
    result.add(toHex(b, 2).toLowerAscii)
