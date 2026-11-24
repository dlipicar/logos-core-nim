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
## judgment and the cache admits it (5-3c-4, G482: it crosses as it is, nothing is decoded). Both
## sides run on one thread here, each timed apart: the module thread's longest hold and total, and
## the worker's total; then a hit, which spools and digests again and answers from the cache.
##
## `receive <dependencies> <contracts>` (5-5-3, G447; plan §4.4's W3; 5-3c-4, G482) times one
## judgment's hand-over: an eligible inspection with that many dependency entries, the contracts
## (commitments) all listed by the first, built as the worker builds it (`eligibleInspection`), sent
## on a channel as the worker sends it and received as the module thread does, then weighed for the
## cache (`estimatedBytes`, by lengths). It prints the build, the send, the receive and the weighing.
## No turn decodes it (D1's turns before G482).
##
## `unitbytes` (5-3c-4, G482, G447's constants) measures what an inspection holds in the heap, as
## 5-5-3 measured the cache's constants: the heap's growth over many inspections built one by one,
## for shapes of contracts listed and provided, and prints each contract's bytes beyond its encoding.
## Run it under orc and refc with `-d:release`.
##
## `installed <records> <dependencies>` (5-5-4, G449; plan §9's measurements; Fable's 5-5-4 check §4)
## builds a snapshot of that many records at the longest identities (a 128-byte name, PM §4's bound, and a
## 128-byte version), each with that many dependencies and their recorded edges and one artifact, as the
## module thread holds it. It prints the heap the snapshot takes, the resolver's copy of it (`packages`,
## made at each resolution's start) in time and heap, and a commit's new snapshot (`next`, one record
## added, then one dropped).
##
## `module <KiB>` (5-5-4; Fable's check §3) times the hold for one selected module's declaration: its
## encoding, about <KiB> KiB of `implements` commitments, decoded and typed on the module thread
## (`moduleDeclaration`); and the copy of one installed record that holds it, which the resolver's
## `evaluate` makes for each installed record it reads (5-3c's note).
##
## `commit <records> <dir>` (5-5-4; Fable's check §4) times the worker's commit over an index of that
## many records at the longest identities: an installed state in `<dir>` given those entries, one record
## dropped (`commitFiles`: the new set sorted, the index encoded and replaced with `writeAtomic`).
##
## `start <records> <dir>` (5-5-4; G445's note) times the store's start over that many data records
## written directly into `<dir>` (`openStore`: each record read, decoded, checked against its
## manifest and its admission bound; no signature is verified at the start).
##
## `reply` (5-5-4, G447; planning's ruling of 2026-11-23) times a maximal `{installed}` response (the
## 16 MiB body, PM l.824) from the worker's encoding to its frame, each step as the code runs it and
## timed alone, best of five in CPU time: on the worker the value, its encoding and the channel's send;
## on the module thread the receive, the answer through the shell's future to pmtest's bytes, the kit's
## `encode`, the confined runtime's completion block (filled a byte at a time, `confinedrt.nim`), the
## outcome's wipe, the host's copy, its `checkResponse` against pmtest's contract, the block's release
## and `respond`'s channel send; on the I/O thread the receive, `decodeValue`, the transport's
## commitment, the Response's encoding and the frame. Two shapes: 65,536 artifacts whose paths fill the
## body, and one module whose declaration is 4 MiB of `implements` commitments. The completion block,
## the host's copy, the block's release and the frame repeat their code here, which is private.
##
## `reply facade` (5-6a-1, G497; plan §4.9; planning's Q16 and its conditions of 2026-11-24) times the
## same way out through the module `logos_package_manager` as 5-6a-1 built it: on the module thread the
## receive, the facade's answer with its one copy, from the answer's string into the pre-encoded bytes
## (G494; `pm/facade.nim`'s `operate` and `answered`, private, repeated here as pmtest's `run` is), the
## kit route's `takeEncoded` (a move), then the same completion. The host's `checkResponse` and the
## transport's commitment are against PACKAGE MANAGER App A's `install_package` (`pmContractSet`), so
## the record is checked and committed as the structured `{installed}` it is, where pmtest's
## `{response: bstr}` was one byte string. The records carry a manifest commitment with the pinned ids,
## which App A requires and pmtest never checked. For worst-case statements each step prints its five
## samples with their best, median and max, and each thread the same of its per-iteration totals.
##
## Through the driver (5-3c-2, G455) the run is resumed turn by turn: a step ends at each inspection
## and at each spent turn, so the longest step is the longest hold on the module thread. `--budget
## <work>` sets the work of one turn (`ResolverTurnWork` by default; 0: no turns), and the steps line
## gives the turns and the work counted. The release line times the turns that then free the run.
##
## The contract shapes (5-3c-3, G455) take the contracts first: `contracts <c>
## [k]` (k manifests of two entries listing c contracts each, on names whose records provide none),
## `provider <p> [l]` (a record providing p contracts, which a later bind looks l of up, out of order
## so they are sorted) and `versioned <c> [v]` (v versions each listing c contracts, each given up).
## The steps line gives `largest_step`, the most work counted between two turn checks: what one turn
## can overrun its budget by.
##
## Usage: pmbench [--budget <work>] [--sync new|oracle|input] <shape> <size> [k | v | L | l] [names depth candidates attempts]
##   pmbench wide 80000 20 4096 4095 4096 1000
##   pmbench contracts 18000 1 256 32 256 1024
##   pmbench dense 1024
##   pmbench chain 4096
##   pmbench hub 255 1
##   pmbench layered 256 32 256 32 256 1024
##   pmbench lift 255 4
##   pmbench --sync oracle dense 1024
##   pmbench archive 64 /tmp/a64.lgx && pmbench inspect /tmp/a64.lgx
##   pmbench spool /tmp/a64.lgx /tmp/spool
##   pmbench receive 80000 0 && pmbench receive 1 22000
##   pmbench unitbytes
##   pmbench installed 200000 0 && pmbench installed 10000 4
##   pmbench module 4096
##   pmbench commit 10000 /tmp/installed
##   pmbench start 10000 /tmp/installed
##   pmbench reply && pmbench reply facade

import std/[algorithm, monotimes, os, strutils, times]
import logos_sdk/cbor
import ../src/logos_core/package/[manifest, records, resolver, signing, trust]
import ../src/logos_core/pm/[engine, installed, vcache]
when defined(posix):
  import ../src/logos_core/pm/store
import ../tests/support/[lgxbuild, oracle_resolver, pmfixture, pmshapes]
import chronos
import logos_sdk/base/wipe
import logos_sdk/codegen/kitrt
import logos_sdk/iface/[accept, outcome]
import ../src/logos_core/pm/[admission, contractset, jobs, responses]
from logos_sdk/pins import CommitmentModelId, HashProfileId, HashSuiteId
import ../src/logos_core/runtime/callcheck
import ../src/logos_core/transport/envelope
import ../src/logos_core/transport/io/api
import ../tests/generated/pmtest_module_types

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
      oracleResolve(input, s.valueInspector, s.rootOf, c)
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
  var module, piece, work: Clock
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
    module.timedOn:
      # [G482] Admitted on receipt: nothing is decoded.
      var got = resultsCh.recv()
      let estimate = got.opened.inspection.estimatedBytes
      x = c.admit(digest.digest, move got.opened, estimate)
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
    ms(max(piece.longest, module.longest)),
    " total_ms=",
    ms(piece.cpu + module.cpu),
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
  ## [G447; W3; G482] One judgment's hand-over: built, sent, received and weighed.
  var values: seq[PackageDependency]
  for i in 0 ..< deps:
    values.add(
      PackageDependency(
        package: "dependency-" & $i, kind: rkCompatible, version: "1.0.0"
      )
    )
  var root = newSeq[byte](32)
  for i in 0 ..< contracts:
    for k in 0 ..< 4:
      root[k] = byte((i shr (8 * k)) and 0xff)
    values[0].contracts.add(commitmentValue(root))
  var build, send, recv, weigh: Clock
  var x: Inspection
  build.timedOn:
    x = eligibleInspection(
      PackageIdentity(package: "logos.bench", version: "1.0.0"),
      ManifestCommitment(),
      values,
      [],
    )
  values = @[]
  var ch: Channel[WorkerResult]
  ch.open()
  send.timedOn:
    ch.send(WorkerResult(kind: wrOpened, file: 1, opened: Opened(inspection: move x)))
  var r: WorkerResult
  recv.timedOn:
    r = ch.recv()
  var estimate: int
  weigh.timedOn:
    estimate = r.opened.inspection.estimatedBytes
  doAssert r.opened.inspection.dependencies.len == deps
  doAssert r.opened.inspection.contractCount == contracts
  ch.close()
  echo "receive dependencies=",
    deps,
    " contracts=",
    contracts,
    " bytes=",
    r.opened.inspection.contractData.len,
    " build_ms=",
    ms(build.cpu),
    " send_ms=",
    ms(send.cpu),
    " receive_ms=",
    ms(recv.cpu),
    " estimate_ms=",
    ms(weigh.cpu),
    " estimate=",
    estimate,
    " turns=0"

proc benchContract(i: int): CborValue =
  ## A commitment, decoded from its bytes, as a manifest's reader holds one.
  var root = newSeq[byte](32)
  for k in 0 ..< 4:
    root[k] = byte((i shr (8 * k)) and 0xff)
  decodeCbor(encodeCbor(commitmentValue(root))).get

proc unitBytes() =
  ## [G447, G482] The heap an inspection holds, per contract beyond its encoding: the growth over
  ## `copies` inspections built one by one, less the same shape with no contract, over the
  ## contracts, less each one's encoded length.
  proc shaped(deps, perDep, provided, salt: int): Inspection =
    var values: seq[PackageDependency]
    for d in 0 ..< deps:
      var dep = PackageDependency(
        package: "logos.d" & align($d, 9, '0'), kind: rkCompatible, version: "1.0.0"
      )
      for c in 0 ..< perDep:
        dep.contracts.add(benchContract(salt * 7919 + d * 131 + c))
      values.add(dep)
    var provides: seq[CborValue]
    for c in 0 ..< provided:
      provides.add(benchContract(salt * 104_729 + c))
    eligibleInspection(
      PackageIdentity(package: "logos.shape", version: "1.0." & $salt),
      ManifestCommitment(),
      values,
      provides,
    )

  proc held(deps, perDep, provided, copies: int): float {.noinline.} =
    # Each measurement frees what it built and collects before the next starts: under refc a
    # previous one's garbage collected during this one would count against it.
    GC_fullCollect()
    GC_fullCollect()
    var all = newSeq[Inspection](copies)
    let before = getOccupiedMem()
    for i in 0 ..< copies:
      all[i] = shaped(deps, perDep, provided, i + 1)
    GC_fullCollect()
    result = float(getOccupiedMem() - before) / float(copies)
    doAssert all.len == copies
    all = @[]
    GC_fullCollect()
    GC_fullCollect()

  let enc = encodedSize(benchContract(1))
  echo "unitbytes mm=",
    (when defined(gcOrc): "orc" elif defined(gcRefc): "refc" else: "other"),
    " release=",
    defined(release),
    " encoding=",
    enc
  discard held(10, 1, 10, 256) # the allocator's first growth, counted against nothing
  # Every count of provided contracts up to 160 (a buffer's rounding to its size class or to
  # pages weighs most on a few contracts), then larger ones; a dependency entry listing them;
  # many entries listing one each.
  var shapes: seq[(string, int, int, int)]
  for n in 1 .. 160:
    shapes.add(("provided " & $n, 0, 0, n))
  for n in [192, 256, 384, 512, 1000, 2048, 4096, 22000]:
    shapes.add(("provided " & $n, 0, 0, n))
  for n in [1, 2, 3, 10, 11, 21, 22, 100, 1000, 22000]:
    shapes.add(("listed 1 x " & $n, 1, n, 0))
  for n in [10, 100, 1000]:
    shapes.add(("listed " & $n & " x 1", n, 1, 0))
  var worst = 0.0
  var worstName = ""
  for (name, deps, perDep, provided) in shapes:
    let n = deps * perDep + provided
    let copies = max(8, min(4096, 1_048_576 div (n * enc)))
    let without = held(deps, 0, 0, copies)
    let with = held(deps, perDep, provided, copies)
    let beyond = (with - without) / float(n) - float(enc)
    if beyond > worst:
      worst = beyond
      worstName = name
    echo "  ",
      name,
      ": copies=",
      copies,
      " held=",
      formatFloat(with, ffDecimal, 1),
      " without_contracts=",
      formatFloat(without, ffDecimal, 1),
      " per_contract_beyond_encoding=",
      formatFloat(beyond, ffDecimal, 1)
  echo "  worst=", formatFloat(worst, ffDecimal, 1), " (", worstName, ")"

proc longestIdentity(i: int): PackageIdentity =
  ## A name at PM §4's 128-byte bound and a version as long, distinct for each `i`.
  let tag = align($i, 8, '0')
  PackageIdentity(
    package: repeat('n', MaxPackageNameBytes - tag.len) & tag,
    version: "1.0.0-" & repeat('p', 128 - 6 - tag.len) & tag,
  )

proc ridOf(i: int): string =
  toHex(i, RidChars).toLowerAscii

proc benchRecord(i, deps: int): SnapRecord =
  ## One record as a snapshot holds it.
  var p = InstalledPackage(identity: longestIdentity(i))
  p.commitment.commitmentModel = "logos.commitment.bench"
  p.signer = PackageSigner(profile: "logos.package-signing.bench")
  p.source = lgxSource("main", "fetch-fake/state/" & $i)
  for d in 0 ..< deps:
    let dep = longestIdentity(i + d + 1)
    p.dependencies.add(
      PackageDependency(package: dep.package, kind: rkCompatible, version: "1.0.0")
    )
    p.resolvedDependencies.add(ResolvedDependency(identity: dep))
  let rid = ridOf(i)
  SnapRecord(
    package: p,
    rid: rid,
    generation: 1,
    base: "/var/lib/logos/session/modules/pm-1/install/r/" & rid & "/a/",
    artifacts: @[InstalledArtifact(id: "data", kind: akData, path: "data/payload.bin")],
  )

proc mib(bytes: int): string =
  formatFloat(bytes.float / 1048576.0, ffDecimal, 1)

proc installedBench(records, deps: int) =
  ## [G449] A snapshot of `records` records, the resolver's copy of it, and a commit's next one.
  let before = getOccupiedMem()
  var snap = Snapshot(sequence: 1)
  for i in 0 ..< records:
    snap.records.add(benchRecord(i, deps))
  let held = getOccupiedMem() - before
  var copy: Clock
  var installed: seq[InstalledPackage]
  let beforeCopy = getOccupiedMem()
  copy.timedOn:
    installed = snap.packages()
  let copied = getOccupiedMem() - beforeCopy
  doAssert installed.len == records
  var added, dropped: Clock
  var after: Snapshot
  added.timedOn:
    after = snap.next(2, Opt.some(benchRecord(records, deps)), [])
  dropped.timedOn:
    after = after.next(3, Opt.none(SnapRecord), [ridOf(records div 2)])
  doAssert after.records.len == records
  echo "installed records=",
    records,
    " dependencies=",
    deps,
    " snapshot_mib=",
    mib(held),
    " bytes_per_record=",
    held div max(records, 1),
    " packages_ms=",
    ms(copy.cpu),
    " packages_mib=",
    mib(copied),
    " next_add_ms=",
    ms(added.cpu),
    " next_drop_ms=",
    ms(dropped.cpu)

proc moduleBench(kib: int) =
  ## [Fable's check §3] One module declaration's decode and typing, and a record's copy.
  var implements: seq[CborValue]
  var root = newSeq[byte](32)
  var total = 0
  while total < kib * 1024:
    let i = implements.len
    for k in 0 ..< 4:
      root[k] = byte((i shr (8 * k)) and 0xff)
    let c = commitmentValue(root)
    total += encodeCbor(c).len
    implements.add(c)
  let declaration = cborMap(
    (cbor("module"), cbor("bench_module")),
    (cbor("artifact"), cbor("bench")),
    (cbor("implements"), cborArray(implements)),
  )
  let bytes = encodeCbor(declaration)
  var decode: Clock
  var typed: ModuleDeclaration
  decode.timedOn:
    typed = moduleDeclaration(decodeCbor(bytes).get)
  doAssert typed.implements.len == implements.len
  let p = InstalledPackage(identity: longestIdentity(0), modules: @[typed])
  var copy: Clock
  var copied: InstalledPackage
  copy.timedOn:
    copied = p
  doAssert copied.modules[0].implements.len == implements.len
  doAssert p.modules[0].implements.len == implements.len # a copy, not a move
  echo "module bytes=",
    bytes.len,
    " implements=",
    implements.len,
    " decode_ms=",
    ms(decode.cpu),
    " record_copy_ms=",
    ms(copy.cpu)

when defined(posix):
  proc commitBench(records: int, dir: string) =
    ## [Fable's check §4] The worker's commit over an index of `records` records.
    removeDir(dir)
    createDir(dir)
    var store = openStore(dir).get
    var f = store.handOver()
    store.close()
    for i in 0 ..< records:
      f.entries.add(
        IndexEntry(rid: ridOf(i), generation: 1, identity: longestIdentity(i))
      )
    var commit: Clock
    var c: Committed
    commit.timedOn:
      c = f.commitFiles([], [ridOf(records div 2)]).get
    let wall0 = getMonoTime()
    discard f.commitFiles([], [ridOf(records div 3)]).get
    let wall = getMonoTime() - wall0
    doAssert c.retired.len == 1
    echo "commit records=",
      records,
      " index_bytes=",
      getFileSize(dir / "install" / "index"),
      " cpu_ms=",
      ms(commit.cpu),
      " wall_ms=",
      wall.inMilliseconds
    f.close()
    removeDir(dir)

  proc startBench(records: int, dir: string) =
    ## [G445's note] The store's start over `records` data records, written directly: each one's
    ## manifest, an empty signature file (the start reads it and verifies nothing) and its record
    ## file, then the index. Times `openStore`, which reads, decodes and cross-checks each record
    ## and checks its admission bound.
    removeDir(dir)
    createDir(dir)
    block:
      var fresh = openStore(dir).get
      fresh.close()
    let root = dir / InstallDir
    let signer =
      PackageSigner(profile: "logos.package-signing.cose-sign1-slh-dsa-sha2-192s")
    var entries: seq[IndexEntry]
    for i in 0 ..< records:
      let name = "bench-" & align($i, 8, '0')
      let bytes = encodeCbor(dataManifest(name, "1.0.0"))
      let m = decodeManifest(bytes).get
      let r = installedRecord(
        m,
        m.commitment.get,
        m.variants[0],
        signer,
        lgxSource("main", name & "@1.0.0"),
        @[],
      )
      let rid = ridOf(i)
      let meta = root / RecordsDir / rid / MetaDir
      createDir(meta)
      createDir(root / RecordsDir / rid / ArtifactsDir)
      writeFile(meta / ManifestFile, bytes)
      writeFile(meta / SignatureFile, "")
      writeFile(
        meta / recordName(1), encodeRecordFile(RecordFile(record: r, generation: 1)).get
      )
      entries.add(IndexEntry(rid: rid, generation: 1, identity: m.identity))
    entries.sort(
      proc(a, b: IndexEntry): int =
        identityOrder(a.identity, b.identity)
    )
    writeFile(
      root / IndexName, encodeIndex(InstalledIndex(sequence: 1, records: entries)).get
    )
    var start: Clock
    var s: InstalledStore
    let wall0 = getMonoTime()
    start.timedOn:
      s = openStore(dir).get
    let wall = getMonoTime() - wall0
    doAssert s.records.len == records
    echo "start records=",
      records,
      " cpu_ms=",
      ms(start.cpu),
      " wall_ms=",
      wall.inMilliseconds,
      " us_per_record=",
      wall.inMicroseconds div max(records, 1)
    s.close()
    removeDir(dir)

const PmtestContract = staticRead("../tests/kit/pmtest_module.cddl")
  ## pmtest's contract, whose `install_response` the host checks
const ReplyBase =
  "/var/lib/logos/session/modules/pm-1/install/r/0123456789abcdef0123456789abcdef/a/"

proc c_calloc(n, s: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc replyRecord(facade: bool): InstalledRecord =
  ## The record both shapes start from. For the facade it carries a manifest commitment with the
  ## pinned ids (its roots zero, each `bstr .size 32`), which App A's `installed_package_record`
  ## requires and pmtest's `{response: bstr}` never checked.
  result = InstalledRecord(
    signer: PackageSigner(profile: "logos.package-signing.cose-sign1-slh-dsa-sha2-192s"),
    identity: PackageIdentity(package: "bench", version: "1.0.0"),
    source: lgxSource("main", "bench@1.0.0"),
    variant: "linux-x86_64",
  )
  if facade:
    result.commitment = ManifestCommitment(
      commitmentModel: CommitmentModelId,
      hashProfile: HashProfileId,
      hashSuite: HashSuiteId,
    )

proc artifactsReply(target: int, facade: bool): InstalledRecord =
  ## 65,536 artifacts, the most an archive holds, each path lengthened until the response's body
  ## is about `target` bytes.
  result = replyRecord(facade)
  let n = 65_536
  for i in 0 ..< n:
    result.artifacts.add(
      InstalledArtifact(id: "a" & align($i, 6, '0'), kind: akData, path: "p/" & $i)
    )
  let first = envelopeBytes(installedResult(result, ReplyBase)).get
  let per = max(0, (target - first) div n)
  for a in result.artifacts.mitems:
    a.path.add(repeat('x', per))

proc moduleReply(kib: int, facade: bool): InstalledRecord =
  ## One module whose declaration holds about `kib` KiB of `implements` commitments.
  result = replyRecord(facade)
  var implements: seq[CborValue]
  var root = newSeq[byte](32)
  var total = 0
  while total < kib * 1024:
    let i = implements.len
    for k in 0 ..< 4:
      root[k] = byte((i shr (8 * k)) and 0xff)
    let c = commitmentValue(root)
    total += encodeCbor(c).len
    implements.add(c)
  let declaration = cborMap(
    (cbor("module"), cbor("bench_module")),
    (cbor("artifact"), cbor("bench")),
    (cbor("implements"), cborArray(implements)),
  )
  result.modules = @[moduleDeclaration(declaration)]
  result.artifacts =
    @[InstalledArtifact(id: "bench", kind: akModuleBinary, path: "lib/libbench.so")]

proc pmtestRun(
    f: Future[OperationAnswer]
): Future[Result[seq[byte], InvocationFailure]] {.async: (raises: []).} =
  ## `tests/kit/pmtest_impl.nim`'s `run` for an encoded answer.
  let a =
    try:
      await f
    except CatchableError:
      return err(failure(ecModule, "bench"))
  var b = newSeq[byte](a.encoded.len)
  if b.len > 0:
    copyMem(addr b[0], unsafeAddr a.encoded[0], b.len)
  ok(b)

proc facadeRun(
    f: Future[OperationAnswer]
): Future[Result[PreEncoded, InvocationFailure]] {.async: (raises: []).} =
  ## `src/logos_core/pm/facade.nim`'s `operate` once the shell answered, and `answered` for an
  ## encoded answer: the one copy, into the pre-encoded bytes (G494).
  let a =
    try:
      await f
    except CatchableError:
      return err(failure(ecModule, "bench"))
  var b = newSeq[byte](a.encoded.len)
  if b.len > 0:
    copyMem(addr b[0], unsafeAddr a.encoded[0], b.len)
  ok(preEncoded(move b))

const ReplySteps = [
  "worker: the value", "worker: its encoding", "worker: the channel's send",
  "module: the channel's receive", "module: the answer to pmtest's bytes",
  "module: the kit's encode", "module: the completion block",
  "module: the outcome's wipe", "module: the host's copy",
  "module: the host's checkResponse", "module: the block's release",
  "module: respond's channel send", "io: the channel's receive", "io: decodeValue",
  "io: the commitment", "io: the Response's encoding", "io: the frame",
]

const FacadeSteps = [
  "worker: the value", "worker: its encoding", "worker: the channel's send",
  "module: the channel's receive", "module: the facade's one copy (answered)",
  "module: the route's takeEncoded", "module: the completion block",
  "module: the outcome's wipe", "module: the host's copy",
  "module: the host's checkResponse", "module: the block's release",
  "module: respond's channel send", "io: the channel's receive", "io: decodeValue",
  "io: the commitment", "io: the Response's encoding", "io: the frame",
]

const ReplyRuns = 5

proc replyOnce(
    r: InstalledRecord,
    sel: Selected,
    facade: bool,
    spent: var array[ReplySteps.len, float],
): int =
  ## One response's way, each step's CPU time in `spent`; the body's length. `facade`: through
  ## the Package Manager module's answer and route and App A's `install_package`; else pmtest's.
  let meth = (if facade: "install_package" else: "install")
  var t = cpuTime()
  template lap(i: int) =
    let now = cpuTime()
    spent[i] = now - t
    t = now

  # The worker.
  let v = installedResult(r, ReplyBase)
  lap(0)
  let enc = encodeCbor(v)
  var reply = newString(enc.len)
  copyMem(addr reply[0], unsafeAddr enc[0], enc.len)
  lap(1)
  result = reply.len
  var wch: Channel[WorkerResult]
  wch.open()
  t = cpuTime()
  wch.send(WorkerResult(kind: wrReply, reply: move reply))
  lap(2)
  # The module thread.
  var got = wch.recv()
  lap(3)
  wch.close()
  t = cpuTime()
  let fut = newFuture[OperationAnswer]("pmbench")
  fut.complete(OperationAnswer(kind: oaEncoded, encoded: move got.reply))
  var outcome: Result[seq[byte], InvocationFailure]
  if facade:
    let rf = facadeRun(fut)
    var pre = move(rf.internalValue)
    lap(4)
    doAssert pre.isOk
    outcome = takeEncoded(pre.get)
    lap(5)
  else:
    let rf = pmtestRun(fut)
    var pmBytes = move(rf.internalValue)
    lap(4)
    outcome = encodedResponse(encode(PmtestInstallResponse(response: move pmBytes.get)))
    lap(5)
  doAssert outcome.isOk
  let n = outcome.get.len
  let blk = cast[ptr UncheckedArray[uint8]](c_calloc(1, csize_t(16 + n)))
  let d = cast[ptr UncheckedArray[uint8]](cast[uint](blk) + 16)
  for i in 0 ..< n:
    d[i] = outcome.get[i]
  lap(6)
  wipe(outcome)
  lap(7)
  var hostBytes = newSeq[byte](n)
  copyMem(addr hostBytes[0], d, n)
  lap(8)
  var trail: CallTrail
  let checked = sel.checkResponse(meth, hostBytes, trail)
  lap(9)
  if checked.isErr:
    raiseAssert "the response does not check: " & $checked.error
  secureZero(blk, 16 + n)
  c_free(blk)
  lap(10)
  var ich: Channel[IoCommand]
  ich.open()
  var cmd = IoCommand(
    kind: IoCommandKind.cmdRespond,
    requestId: 7,
    outcome: CallOutcome(ok: true, result: move hostBytes),
    workEnded: true,
  )
  t = cpuTime()
  ich.send(move cmd)
  lap(11)
  # The I/O thread.
  var io = ich.recv()
  lap(12)
  ich.close()
  t = cpuTime()
  let dv = decodeValue(io.outcome.result, 128)
  lap(13)
  doAssert dv.isOk
  let commitment = sel.boundary.commitResponse(meth, dv.get)
  lap(14)
  doAssert commitment.isOk
  let body = encodeCbor(
    toCbor(
      Message(
        kind: mkResponse,
        response:
          Response(id: 7, ok: true, resultMap: dv.get, commitment: commitment.get),
      )
    )
  )
  lap(15)
  var frame = newSeqUninit[byte](body.len + 4)
  copyMem(addr frame[4], unsafeAddr body[0], body.len)
  lap(16)
  doAssert frame.len > n

proc spread(samples: openArray[float]): string =
  ## [G497; planning, 2026-11-24] Best, median and max of `samples`, in ms, then each sample.
  var s = @samples
  s.sort()
  let med =
    if s.len mod 2 == 1:
      s[s.len div 2]
    else:
      (s[s.len div 2 - 1] + s[s.len div 2]) / 2
  result =
    "best_ms=" & ms(s[0]) & " median_ms=" & ms(med) & " max_ms=" & ms(s[^1]) &
    " runs_ms="
  for i, x in samples:
    result.add((if i > 0: "," else: "") & ms(x))

proc replyBench(facade: bool) =
  ## [G447; planning's ruling of 2026-11-23] A maximal response's way out, step by step; with
  ## `facade` (G497) through the Package Manager module and App A.
  let set =
    if facade:
      pmContractSet().get
    else:
      acceptContractSet(PmtestContract).get
  let sel = buildSelected(set, set.primary.root, 128).get
  let names = (if facade: FacadeSteps else: ReplySteps)
  for (name, r) in [
    ("artifacts-65536", artifactsReply(AdmissionLimit - 4096, facade)),
    ("module-4MiB", moduleReply(4096, facade)),
  ]:
    var samples: array[ReplySteps.len, array[ReplyRuns, float]]
    var totals: array[3, array[ReplyRuns, float]]
      # worker, module, I/O: each iteration's sum
    var bytes = 0
    for run in 0 ..< ReplyRuns:
      var spent: array[ReplySteps.len, float]
      bytes = replyOnce(r, sel, facade, spent)
      for i in 0 ..< spent.len:
        samples[i][run] = spent[i]
        let k =
          if names[i].startsWith("worker"):
            0
          elif names[i].startsWith("module"):
            1
          else:
            2
        totals[k][run] += spent[i]
    var worker, module, io: float
    for i, s in names:
      let best = min(samples[i])
      if s.startsWith("worker"):
        worker += best
      elif s.startsWith("module"):
        module += best
      else:
        io += best
    echo "reply mode=",
      (if facade: "facade" else: "pmtest"),
      " shape=",
      name,
      " body=",
      bytes,
      " admission=",
      AdmissionLimit
    for i, s in names:
      echo "  ",
        alignLeft(s, 42), " cpu_ms=", ms(min(samples[i])), " ", spread(samples[i])
    echo "  worker_cpu_ms=",
      ms(worker), " module_cpu_ms=", ms(module), " io_cpu_ms=", ms(io)
    echo "  worker_total ", spread(totals[0])
    echo "  module_total ", spread(totals[1])
    echo "  io_total ", spread(totals[2])

proc main() =
  var args = commandLineParams()
  if args.len == 1 and args[0] == "reply":
    replyBench(facade = false)
    return
  if args.len == 2 and args[0] == "reply" and args[1] == "facade":
    replyBench(facade = true)
    return
  if args.len == 3 and args[0] == "installed":
    installedBench(parseInt(args[1]), parseInt(args[2]))
    return
  if args.len == 2 and args[0] == "module":
    moduleBench(parseInt(args[1]))
    return
  when defined(posix):
    if args.len == 3 and args[0] == "commit":
      commitBench(parseInt(args[1]), args[2])
      return
    if args.len == 3 and args[0] == "start":
      startBench(parseInt(args[1]), args[2])
      return
  if args.len == 3 and args[0] == "receive":
    receive(parseInt(args[1]), parseInt(args[2]))
    return
  if args.len == 1 and args[0] == "unitbytes":
    unitBytes()
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
      "usage: pmbench [--budget <work>] [--sync new|oracle|input] <wide|dense|chain|hub|layered|lift|contracts|provider|versioned> <size> [k | v | L | l] [names depth candidates attempts]\n" &
        "       pmbench archive <MiB> <file> | pmbench inspect <file> | pmbench spool <file> <dir>",
      2,
    )
  let shapeName = args[0]
  let size = parseInt(args[1])
  var rest = args[2 .. ^1]
  var k = defaultParameter(shapeName)
  if shapeName in
      ["wide", "hub", "layered", "lift", "contracts", "provider", "versioned"] and
      rest.len > 0:
    k = parseInt(rest[0])
    rest = rest[1 .. ^1]
  let m = MaxResolverLimits
  var lim = [m.names, m.depth, m.candidates, m.attempts]
  for i in 0 ..< min(rest.len, 4):
    lim[i] = parseInt(rest[i])
  let limits = resolverLimits(lim[0], lim[1], lim[2], lim[3]).get
  let built = getMonoTime()
  var s = shapeOf(shapeName, size, k).valueOr:
    quit("unknown shape " & shapeName, 2)
  s.unchecked = true # [G482] each answer is held as the worker would send it, unchecked
  let buildMs = (getMonoTime() - built).inMilliseconds
  echo shapeName,
    " size=",
    size,
    (
      if shapeName in ["wide", "contracts"]: " k=" & $k
      elif shapeName in ["hub", "lift", "versioned"]: " v=" & $k
      elif shapeName == "layered": " L=" & $k
      elif shapeName == "provider": " l=" & $k
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
    r.work,
    " largest_step=",
    r.largestStep
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
