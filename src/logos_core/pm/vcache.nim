## The verification cache (Tier 5 step 5-3b; DECISIONS G403; C5;
## docs/PACKAGE-MANAGER.md §5; PACKAGE MANAGER l.430-438, PKG-0076, PKG-0077,
## PKG-0079).
##
## - **What is cached** (PKG-0076, a MAY taken): one entry per verified
##   archive, keyed by the BLAKE3-256 of its bytes: the signer (profile, kid
##   and key), the identity, the manifest commitment, the selected variant and
##   the resolver's inspection, so a hit answers the resolver without opening
##   the archive. In memory only, at most `cache_entries`, least recently used
##   first out. The platform, the LGX limits and the path rules are fixed for
##   the cache's life, so they are not part of the key.
## - **Every hit is judged again** against the trust input it is used with
##   (PKG-0077): the entry stands only while that input has an anchor with the
##   same kid, holding the same key, under the same profile, authorizing the
##   exact package name. Otherwise the entry is dropped and the archive is
##   opened again, which then fails `signature-verification-failed`. Removal,
##   revocation, a withdrawn name, a withdrawn development anchor and a new
##   key for the same kid each drop the entries they affect, and only those.
## - **Rotation** (PKG-0079, a MAY taken): two anchors that authorize one name
##   are both in force while the trust input lists both, so an archive signed
##   by either verifies; once the old one is removed, only the new one does.
## - Only an archive that verified is cached: an ineligible one is opened
##   again each time it is reached, so its error is always the current one.
## - **Verified** includes PKG-0060 (step 5-5-1, G451): after `openLgx`, each
##   selected module's configuration declaration must resolve under
##   LOGOS-MODULE-CONFIGURATION (`handoff.checkConfigurations`), else the
##   archive is `invalid-package`.
## - **Where an archive is opened** (step 5-5-3, G447): the worker reads the
##   spool file and judges it (`judge`); the module thread looks the digest up
##   first (`lookup`) and caches the worker's answer (`admit`). `inspect` does
##   both at once over bytes in memory, for tools and tests.
## - **The byte bound** (step 5-5-3, G447; Fable's review of draft 3.2 §1): an
##   inspection whose estimate (`estimatedBytes`) is over
##   `MaxCachedInspectionBytes` answers its call and is not cached (`uncached`),
##   so the cache holds at most `cache_entries` × 256 KiB by the estimate. The
##   estimate is fixed by rule, over the resolver's walk (`inputUnits`, G477): a
##   constant for each unit's kind and the bytes of its variable parts. The
##   same archive is cached, or not, on every machine and under every memory
##   manager. It is weighed once, when it would be inserted.

{.push raises: [].}

import std/tables
import results
import logos_sdk/crypto/blake3
import ../crypto/slhdsa
import ../package/[errors, lgx, manifest, records, resolver, signing, trust]
import ./handoff

export results, blake3, lgx, resolver

const
  MaxCachedInspectionBytes* = 256 * 1024
    ## [IMPL; G447] the largest inspection the cache keeps, by `estimatedBytes`
  RecordUnitBytes* = 2048
    ## [IMPL; G447] a record's fixed part: its entry, signer, commitment and table slot. Measured
    ## (5-5-3, the Mac, `-d:release`): at most about 1.2 KiB under orc and 0.7 KiB under refc,
    ## the cache's table slot at its worst load included
  DependencyUnitBytes* = 192
    ## [IMPL; G447] a dependency entry beyond its two strings; measured about 71 B under orc
    ## and 127 B under refc
  ContractUnitBytes* = 1024
    ## [IMPL; G447] a contract (listed by a dependency entry, or provided) beyond its
    ## deterministic encoding: a tree of nine CBOR values; measured about 655 B under orc and
    ## 848 B under refc

type
  CacheEntry* = object
    profile*: string
    kid*: seq[byte]
    key*: PublicKey
    identity*: PackageIdentity
    commitment*: ManifestCommitment
    variant*: string ## the selected variant's id
    inspection*: Inspection
    used: uint64 ## the tick of its last use

  CacheCounters* = object
    opened*: int ## archives judged (the worker's `judge`, or `openLgx` in `inspect`)
    hits*: int ## answered from the cache
    dropped*: int ## entries a judgement removed
    evicted*: int ## entries the bound removed
    uncached*: int
      ## [G447] verified inspections over `MaxCachedInspectionBytes`: answered, not kept

  Opened* = object
    ## [G447] One archive's judgment, as `judge` gives it: the inspection and, when it
    ## verified, what the cache keys its acceptance on.
    inspection*: Inspection
    profile*: string
    kid*: seq[byte]
    key*: PublicKey
    variant*: string

  VerificationCache* = object
    capacity: int
    platform: Platform
    limits: LgxLimits
    pathRules: PathRules
    entries: Table[Blake3Digest, CacheEntry]
    tick: uint64
    counters*: CacheCounters

func initVerificationCache*(
    capacity: int,
    platform = hostPlatform(),
    limits = DefaultLgxLimits,
    pathRules = hostPathRules(),
): VerificationCache =
  doAssert capacity >= 1
  VerificationCache(
    capacity: capacity, platform: platform, limits: limits, pathRules: pathRules
  )

func len*(c: VerificationCache): int =
  c.entries.len

func contains*(c: VerificationCache, digest: Blake3Digest): bool =
  digest in c.entries

func stillAccepted*(e: CacheEntry, trust: TrustInput): bool =
  ## [G403; PKG-0077] The entry's signer as `trust` judges it now: the same
  ## profile, an anchor with the same kid holding the same key, authorizing
  ## exactly the entry's package name.
  if e.profile != signingProfile():
    return false
  let a = trust.authorize(e.kid, e.identity.package).valueOr:
    return false
  a.key == e.key

proc evictOne(c: var VerificationCache) =
  var oldest: Blake3Digest
  var at = high(uint64)
  for d, e in c.entries:
    if e.used < at:
      at = e.used
      oldest = d
  c.entries.del(oldest)
  inc c.counters.evicted

func unitBytes*(kind: InputUnitKind): int =
  ## [G447] Each walk unit's constant.
  case kind
  of iuRecord: RecordUnitBytes
  of iuDependency: DependencyUnitBytes
  of iuDependencyContract, iuProvided: ContractUnitBytes

proc estimatedBytes*(x: Inspection): int =
  ## [G447] The bytes the cache counts for `x`: over the resolver's walk (G477), each unit's
  ## kind constant and the bytes of its variable parts. A contract's bytes are its encoded
  ## size, so this walks every contract: call it once per insertion, never on a lookup.
  for u in x.inputUnits:
    result += unitBytes(u.kind) + u.bytes

proc judge*(
    source: LgxSource,
    trust: TrustInput,
    platform: Platform,
    limits: LgxLimits,
    pathRules: PathRules,
    stop: LgxStop = nil,
): Opened =
  ## [G403, G447] One archive judged where its bytes are read (the worker, over a spool
  ## file): the inspection pass (`inspectLgx`), then PKG-0060 last in G29/P7a order. A source
  ## that cannot be read, or a stop, is `ikUnavailable`; a refused archive `ikIneligible`.
  let p = inspectLgx(source, trust, platform, limits, pathRules, stop).valueOr:
    if error.code == pecPackageUnavailable:
      return Opened(inspection: Inspection(kind: ikUnavailable, reason: error.msg))
    return Opened(inspection: Inspection(kind: ikIneligible, error: error))
  # [SPEC PM §4 l.362-364 (PKG-0060); G451] Last in G29/P7a order: each selected module's
  # configuration declaration resolves, or the archive is `invalid-package`.
  checkConfigurations(p).isOkOr:
    return Opened(inspection: Inspection(kind: ikIneligible, error: error))
  Opened(
    inspection: inspection(p),
    profile: signingProfile(),
    kid: p.verified.signer.kid,
    key: p.verified.signer.key,
    variant: p.variant.id,
  )

proc lookup*(
    c: var VerificationCache, digest: Blake3Digest, trust: TrustInput
): Opt[Inspection] =
  ## [G403; PKG-0077] The cached inspection of the archive whose BLAKE3-256 is `digest`, when
  ## its entry is still accepted under `trust`; else none, and an entry no longer accepted is
  ## dropped. The caller then judges the archive and `admit`s the answer.
  inc c.tick
  if digest notin c.entries:
    return Opt.none(Inspection)
  var e = c.entries.getOrDefault(digest)
  if e.stillAccepted(trust):
    inc c.counters.hits
    e.used = c.tick
    let answer = e.inspection
    c.entries[digest] = move e
    return Opt.some(answer)
  c.entries.del(digest)
  inc c.counters.dropped
  Opt.none(Inspection)

proc admit*(
    c: var VerificationCache, digest: Blake3Digest, o: sink Opened
): Inspection =
  ## [G403, G447] The judgment of the archive whose BLAKE3-256 is `digest`, answered; kept when
  ## it verified and its estimate is at most `MaxCachedInspectionBytes`. An ineligible or
  ## unavailable archive is never kept, so its error is always the current one.
  if o.inspection.kind == ikUnavailable:
    return o.inspection
  inc c.counters.opened
  if o.inspection.kind != ikEligible:
    return o.inspection
  if o.inspection.estimatedBytes > MaxCachedInspectionBytes:
    inc c.counters.uncached
    return o.inspection
  if c.entries.len >= c.capacity:
    c.evictOne()
  let answer = o.inspection
  c.entries[digest] = CacheEntry(
    profile: move o.profile,
    kid: move o.kid,
    key: o.key,
    identity: answer.identity,
    commitment: answer.commitment,
    variant: move o.variant,
    inspection: move o.inspection,
    used: c.tick,
  )
  answer

proc inspect*(
    c: var VerificationCache, data: openArray[byte], trust: TrustInput
): Inspection =
  ## [G403] The inspection of one archive in memory under `trust`: from the cache when an
  ## entry for these bytes is still accepted, else judged here and admitted. The worker's
  ## path (`judge` over a spool file, then `admit`) gives the same answers.
  let digest = blake3(data)
  let hit = c.lookup(digest, trust)
  if hit.isSome:
    return hit.get
  c.admit(digest, judge(bytesSource(@data), trust, c.platform, c.limits, c.pathRules))

proc judge*(c: var VerificationCache, trust: TrustInput): int =
  ## Drops every entry `trust` no longer accepts, and says how many. A hit
  ## judges its own entry, so this only bounds what a changed trust input
  ## leaves behind.
  var gone: seq[Blake3Digest]
  for d, e in c.entries:
    if not e.stillAccepted(trust):
      gone.add(d)
  for d in gone:
    c.entries.del(d)
  c.counters.dropped += gone.len
  gone.len

{.pop.}
