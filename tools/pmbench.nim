## The resolver limits' measurement (Tier 5 step 5-3b-2; planning's rulings of 2026-11-22, M1 to
## M6 and 7.1 to 7.2; DECISIONS G399, G443): one shape of `tests/support/pmshapes.nim`, resolved
## through the Package Manager's driver one step at a time.
##
## For each run it prints the outcome, the counters, the longest step (what the module thread is
## held for, M2) and the total of the steps, in wall time and in the process's CPU time (one
## thread: the CPU time is what the step costs on an idle core, whatever else the machine runs).
## CI never runs it and asserts no time (M6); `test_pm_driver` asserts the shapes' counts.
##
## With `--sync new` or `--sync oracle` (Tier 5 step 5-3c; DECISIONS G454) it instead runs one
## synchronous resolution of the shape, by the resolver or by the frozen oracle
## (`tests/support/oracle_resolver.nim`, the resolver as 5-3b-2 built it), and prints its outcome,
## counters, wall and CPU time and, for the resolver, the work units counted. One resolver per
## process, so `time -l` (macOS) or `time -v` (Linux) gives each one's peak memory. `--sync input`
## builds the shape and its input and resolves nothing: the peak memory the two others start from.
##
## `archive <MiB> <file>` and `inspect <file>` (5-3c's plan §5, for 5-5) measure the other hold on the
## module thread: the verification cache's inspection of one archive (`pm/vcache.nim` `inspect`: BLAKE3
## of the archive, then `openLgx` with the reader in memory). `archive` writes a signed archive for
## the host's platform whose one data artifact is <MiB> MiB of pseudo-random, so incompressible,
## bytes. `inspect` reads it, then times a miss (BLAKE3 and the open), a hit (BLAKE3 and the cached
## answer) and BLAKE3 alone. Writing the file first keeps the archive's construction out of the
## inspecting process's peak memory.
##
## `spool <file> <dir>` (5-5-3, G447) measures the same archive's inspection as the Package Manager
## now runs it: the module thread hands each 1 MiB `read_object` answer to the worker (the fetcher's
## spooled mode, a job, a channel), the worker appends it to a spool file in `<dir>` with its digest,
## then judges the file (`vcache.judge` over `fileSource`), and the module thread receives the
## encoded judgment and decodes it `DecodeTurnUnits` at a time before the cache admits it. Both
## sides run on one thread here, each timed apart: the module thread's longest hold and total, and
## the worker's total; then a hit, which spools and digests again and answers from the cache.
##
## `receive <dependencies> <contracts>` (5-5-3, G447; plan §4.4's W3) times one judgment's hand-over:
## an eligible inspection with that many dependency entries, the contracts (commitments) all listed by
## the first, sent on a channel as the worker sends it and received as the module thread does, then
## decoded a budget at a time. It prints the send, the receive, the turns and the longest.
##
## Through the driver (5-3c-2, G455) the run is resumed turn by turn: a step ends at each inspection
## and at each spent turn, so the longest step is the longest hold on the module thread. `--budget
## <work>` sets the work of one turn (`ResolverTurnWork` by default; 0: no turns), and the steps line
## gives the turns and the work counted. The release line times the turns that then free the run.
##
## Usage: pmbench [--budget <work>] [--sync new|oracle|input] <shape> <size> [k | v | L] [names depth candidates attempts]
##   pmbench wide 80000 20 4096 4095 4096 1000
##   pmbench dense 1024
##   pmbench chain 4096
##   pmbench hub 255 1
##   pmbench layered 256 32 256 32 256 1024
##   pmbench lift 255 4
##   pmbench --sync oracle dense 1024
##   pmbench archive 64 /tmp/a64.lgx && pmbench inspect /tmp/a64.lgx
##   pmbench spool /tmp/a64.lgx /tmp/spool
##   pmbench receive 80000 0 && pmbench receive 1 22000

import std/[monotimes, os, strutils, times]
import ../src/logos_core/pm/[engine, vcache]
import ../tests/support/[lgxbuild, oracle_resolver, pmfixture, pmshapes]

proc sync(which: string, s: Shape, limits: ResolverLimits) =
  ## One synchronous resolution by the resolver (`new`) or the oracle.
  var c: ResolverCounters
  var work = 0'i64
  let input = s.inputOf(limits)
  if which == "input":
    echo "  input built, nothing resolved"
    return
  let start = getMonoTime()
  let cpu0 = cpuTime()
  let outcome =
    if which == "oracle":
      oracleResolve(input, s.rootOf, c)
    else:
      resolve(input, s.rootOf, c, work)
  let cpu = cpuTime() - cpu0
  let took = getMonoTime() - start
  echo "  ",
    which,
    " outcome=",
    (
      if outcome.isOk: "ok (" & $outcome.get.packages.len & " packages)"
      else: $outcome.error
    )
  echo "  counters: names=",
    c.names,
    " depth=",
    c.depth,
    " candidates=",
    c.mostConsidered,
    " attempts=",
    c.attempts,
    " limit=",
    (if c.limit.len > 0: c.limit else: "none"),
    " entries=",
    c.entries
  echo "  ms=",
    took.inMicroseconds.float / 1000.0,
    " cpu_ms=",
    formatFloat(cpu * 1000.0, ffDecimal, 3),
    (if which == "oracle": "" else: " work=" & $work)

proc variantId(p: Platform): string =
  p.os & "-" & p.architecture

proc archive(mib: int, path: string) =
  ## A signed archive whose one data artifact is `mib` MiB of xorshift bytes.
  var payload = newSeq[byte](mib * 1_048_576)
  var x = 0x9E3779B97F4A7C15'u64
  var i = 0
  while i + 8 <= payload.len:
    x = x xor (x shl 13)
    x = x xor (x shr 7)
    x = x xor (x shl 17)
    copyMem(addr payload[i], addr x, 8)
    i += 8
  let host = hostPlatform()
  let artifact = cborMap(
    (cbor("id"), cbor("data")),
    (cbor("kind"), cbor("data")),
    (cbor("path"), cbor("data/payload.bin")),
    (cbor("hash"), cbor(@(blake3(payload)))),
  )
  let variant = cborMap(
    (cbor("id"), cbor(host.variantId)),
    (
      cbor("platform"),
      cborMap(
        (cbor("os"), cbor(host.os)), (cbor("architecture"), cbor(host.architecture))
      ),
    ),
    (cbor("artifacts"), cborArray(artifact)),
  )
  let v = cborMap(
    (cbor("package"), cbor("logos.bench")),
    (cbor("version"), cbor("1.0.0")),
    (cbor("modules"), cborArray()),
    (cbor("variants"), cborArray(variant)),
  )
  let m = decodeManifest(encodeCbor(v)).get
  let (key, _) = testKey(7)
  let cose = signManifest(m, bytesOf("bench"), key).get
  let lgx =
    writeLgx(m.encoded, cose, @[(host.variantId, @[("data/payload.bin", payload)])]).get
  writeFile(path, lgx)
  echo "archive ", path, " bytes=", lgx.len, " payload_mib=", mib

proc inspectFile(path: string) =
  ## The verification cache's inspection of the archive at `path`, as the Package
  ## Manager runs it on its module thread.
  let data = readFile(path)
  let (_, pub) = testKey(7)
  let trust = trustInputOf([("bench", pub, @["logos.bench"])])
  var c = initVerificationCache(4)
  echo "inspect ", path, " bytes=", data.len
  template timed(label: string, body: untyped) =
    let start = getMonoTime()
    let cpu0 = cpuTime()
    body
    echo "  ",
      label,
      " ms=",
      (getMonoTime() - start).inMicroseconds.float / 1000.0,
      " cpu_ms=",
      formatFloat((cpuTime() - cpu0) * 1000.0, ffDecimal, 3)

  timed("miss"):
    let first = c.inspect(data.toOpenArrayByte(0, data.high), trust)
  echo "  miss kind=",
    first.kind,
    (if first.kind == ikIneligible: " error=" & $first.error
    else: ""),
    " opened=",
    c.counters.opened
  timed("hit"):
    let again = c.inspect(data.toOpenArrayByte(0, data.high), trust)
  echo "  hit kind=", again.kind, " hits=", c.counters.hits
  timed("blake3"):
    let d = blake3(data.toOpenArrayByte(0, data.high))
  doAssert d.len > 0

type Clock = object
  cpu: float
  longest: float
  count: int

template timedOn(c: var Clock, body: untyped) =
  let cpu0 = cpuTime()
  body
  let spent = cpuTime() - cpu0
  c.cpu += spent
  c.longest = max(c.longest, spent)
  inc c.count

func ms(seconds: float): string =
  formatFloat(seconds * 1000.0, ffDecimal, 3)

proc spoolOnce(
    path, dir: string,
    trustBytes: seq[byte],
    trust: TrustInput,
    c: var VerificationCache,
    label: string,
) =
  ## [G447] One retrieval of the archive at `path` as 5-5-3 runs it.
  var file: File
  doAssert open(file, path)
  let size = getFileSize(file)
  var jobsCh: Channel[WorkerJob]
  var resultsCh: Channel[WorkerResult]
  jobsCh.open()
  resultsCh.open()
  var worker: WorkerState
  discard worker.runJob(
    WorkerJob(
      kind: wjStart,
      config:
        workerConfig(dir, trustBytes, hostPlatform(), DefaultLgxLimits, hostPathRules()),
    ),
    nil,
  )
  var module, piece, decode, work: Clock
  var f = initRetrieval(bytesOf("bench"), int64(size), 1000, spooled = true)
  discard f.start()
  var step = f.onAnswer(sized(uint64(size)))
  var buffer = newSeq[byte](ReadStep)
  var first = true
  while step.kind == skCall:
    let n = file.readBytes(buffer, 0, int(step.call.length))
    doAssert n == int(step.call.length)
    let answer = dataOf(buffer.toOpenArray(0, n - 1))
    piece.timedOn:
      step = f.onAnswer(answer)
      var job = WorkerJob(kind: wjAppend, file: 1, chunk: f.takeChunk())
      if first:
        job.first = true
        job.name = spoolName(1, 1)
        first = false
      jobsCh.send(move job)
    work.timedOn:
      let j = jobsCh.recv()
      let r = worker.runJob(j, nil).get
      doAssert r.failure.len == 0, r.failure
  file.close()
  doAssert step.kind == skDone
  var digest: WorkerResult
  work.timedOn:
    digest = worker.runJob(WorkerJob(kind: wjFinish, file: 1), nil).get
  doAssert digest.failure.len == 0 and digest.size == size
  var x: Inspection
  var found = false
  module.timedOn:
    let hit = c.lookup(digest.digest, trust)
    if hit.isSome:
      x = hit.get
      found = true
  if not found:
    var opened: WorkerResult
    work.timedOn:
      opened = worker.runJob(WorkerJob(kind: wjOpen, file: 1), nil).get
      resultsCh.send(opened)
    var d: Decoding
    var estimate: int
    module.timedOn:
      var got = resultsCh.recv()
      estimate = got.opened.estimatedBytes
      d = initDecoding(move got.opened)
    var turns = 0
    while true:
      var budget = DecodeTurnUnits
      var done = false
      decode.timedOn:
        done = d.decodeSome(budget)
      inc turns
      if done:
        break
    module.timedOn:
      x = c.admit(digest.digest, d.take(), estimate)
    echo "  ", label, " decode turns=", turns, " longest_ms=", ms(decode.longest)
  work.timedOn:
    discard worker.runJob(WorkerJob(kind: wjDrop, file: 1), nil)
  worker.close()
  jobsCh.close()
  resultsCh.close()
  echo "  ",
    label,
    " kind=",
    x.kind,
    (if x.kind == ikIneligible: " error=" & $x.error else: ""),
    " pieces=",
    piece.count,
    " module: piece_mean_ms=",
    ms(piece.cpu / float(max(piece.count, 1))),
    " piece_longest_ms=",
    ms(piece.longest),
    " longest_ms=",
    ms(max(piece.longest, max(module.longest, decode.longest))),
    " total_ms=",
    ms(piece.cpu + module.cpu + decode.cpu),
    " worker: total_ms=",
    ms(work.cpu)

proc spoolFile(path, dir: string) =
  ## [G447] A miss, then a hit, of the archive at `path` through the worker's jobs.
  let (_, pub) = testKey(7)
  let trust = trustInputOf([("bench", pub, @["logos.bench"])])
  let trustBytes = trustOf([anchorOf("bench", ["logos.bench"], pub)]).trustBytes
  createDir(dir)
  var c = initVerificationCache(4)
  echo "spool ", path, " bytes=", getFileSize(path)
  spoolOnce(path, dir, trustBytes, trust, c, "miss")
  spoolOnce(path, dir, trustBytes, trust, c, "hit")
  echo "  opened=", c.counters.opened, " hits=", c.counters.hits

proc receive(deps, contracts: int) =
  ## [G447; W3] One judgment's hand-over and its decoding.
  var w = WireOpened(kind: ikEligible)
  w.identity = PackageIdentity(package: "logos.bench", version: "1.0.0")
  for i in 0 ..< deps:
    w.dependencies.add(
      WireDependency(package: "dependency-" & $i, kind: rkCompatible, version: "1.0.0")
    )
  var root = newSeq[byte](32)
  for i in 0 ..< contracts:
    for k in 0 ..< 4:
      root[k] = byte((i shr (8 * k)) and 0xff)
    w.dependencies[0].contracts.add(textOf(encodeCbor(commitmentValue(root))))
  var ch: Channel[WorkerResult]
  ch.open()
  var send, recv, decode: Clock
  send.timedOn:
    ch.send(WorkerResult(kind: wrOpened, file: 1, opened: move w))
  var r: WorkerResult
  recv.timedOn:
    r = ch.recv()
  var d: Decoding
  recv.timedOn:
    d = initDecoding(move r.opened)
  while true:
    var budget = DecodeTurnUnits
    var done = false
    decode.timedOn:
      done = d.decodeSome(budget)
    if done:
      break
  let o = d.take()
  doAssert o.inspection.dependencies.len == deps
  ch.close()
  echo "receive dependencies=",
    deps,
    " contracts=",
    contracts,
    " send_ms=",
    ms(send.cpu),
    " receive_ms=",
    ms(recv.cpu),
    " turns=",
    decode.count,
    " longest_turn_ms=",
    ms(decode.longest),
    " decode_ms=",
    ms(decode.cpu)

proc main() =
  var args = commandLineParams()
  if args.len == 3 and args[0] == "receive":
    receive(parseInt(args[1]), parseInt(args[2]))
    return
  if args.len == 3 and args[0] == "archive":
    archive(parseInt(args[1]), args[2])
    return
  if args.len == 2 and args[0] == "inspect":
    inspectFile(args[1])
    return
  if args.len == 3 and args[0] == "spool":
    spoolFile(args[1], args[2])
    return
  var which = ""
  var budget = ResolverTurnWork
  if args.len >= 2 and args[0] == "--budget":
    # [G455] the work of one turn; 0: none
    budget = parseBiggestInt(args[1])
    if budget <= 0:
      budget = NoTurnBudget
    args = args[2 .. ^1]
  if args.len >= 2 and args[0] == "--sync":
    which = args[1]
    if which notin ["new", "oracle", "input"]:
      quit("--sync takes new, oracle or input", 2)
    args = args[2 .. ^1]
  if args.len < 2:
    quit(
      "usage: pmbench [--budget <work>] [--sync new|oracle|input] <wide|dense|chain|hub|layered|lift> <size> [k | v | L] [names depth candidates attempts]\n" &
        "       pmbench archive <MiB> <file> | pmbench inspect <file> | pmbench spool <file> <dir>",
      2,
    )
  let shapeName = args[0]
  let size = parseInt(args[1])
  var rest = args[2 .. ^1]
  var k = defaultParameter(shapeName)
  if shapeName in ["wide", "hub", "layered", "lift"] and rest.len > 0:
    k = parseInt(rest[0])
    rest = rest[1 .. ^1]
  let m = MaxResolverLimits
  var lim = [m.names, m.depth, m.candidates, m.attempts]
  for i in 0 ..< min(rest.len, 4):
    lim[i] = parseInt(rest[i])
  let limits = resolverLimits(lim[0], lim[1], lim[2], lim[3]).get
  let built = getMonoTime()
  let s = shapeOf(shapeName, size, k).valueOr:
    quit("unknown shape " & shapeName, 2)
  let buildMs = (getMonoTime() - built).inMilliseconds
  echo shapeName,
    " size=",
    size,
    (
      if shapeName == "wide": " k=" & $k
      elif shapeName in ["hub", "lift"]: " v=" & $k
      elif shapeName == "layered": " L=" & $k
      else: ""
    ),
    " limits=",
    lim.join("/"),
    " build_ms=",
    buildMs
  if which.len > 0:
    sync(which, s, limits)
    return
  let r = driveShape(s, limits, budget)
  let c = r.counters
  echo "  outcome=",
    (
      if r.outcome.isOk: "ok (" & $r.outcome.get.packages.len & " packages)"
      else: $r.outcome.error
    )
  echo "  counters: names=",
    c.names,
    " depth=",
    c.depth,
    " candidates=",
    c.mostConsidered,
    " attempts=",
    c.attempts,
    " limit=",
    (if c.limit.len > 0: c.limit else: "none"),
    " entries=",
    c.entries
  echo "  steps=",
    r.steps,
    " longest_ms=",
    r.longest.inMicroseconds.float / 1000.0,
    " total_ms=",
    r.total.inMicroseconds.float / 1000.0,
    " longest_cpu_ms=",
    formatFloat(r.longestCpu * 1000.0, ffDecimal, 3),
    " total_cpu_ms=",
    formatFloat(r.totalCpu * 1000.0, ffDecimal, 3),
    " turns=",
    r.turns,
    " work=",
    r.work
  echo "  setup_ms=",
    r.setup.inMicroseconds.float / 1000.0,
    " setup_cpu_ms=",
    formatFloat(r.setupCpu * 1000.0, ffDecimal, 3)
  echo "  release: turns=",
    r.releases,
    " longest_ms=",
    r.longestRelease.inMicroseconds.float / 1000.0,
    " total_ms=",
    r.releaseTotal.inMicroseconds.float / 1000.0,
    " longest_cpu_ms=",
    formatFloat(r.longestReleaseCpu * 1000.0, ffDecimal, 3),
    " total_cpu_ms=",
    formatFloat(r.releaseTotalCpu * 1000.0, ffDecimal, 3)

when isMainModule:
  main()
