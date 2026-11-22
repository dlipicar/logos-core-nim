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

{.push raises: [].}

import std/tables
import results
import logos_sdk/crypto/blake3
import ../crypto/slhdsa
import ../package/[lgx, manifest, records, resolver, signing, trust]
import ./handoff

export results, blake3, lgx, resolver

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
    opened*: int ## archives opened (`openLgx` called)
    hits*: int ## answered from the cache
    dropped*: int ## entries a judgement removed
    evicted*: int ## entries the bound removed

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

proc inspect*(
    c: var VerificationCache, data: openArray[byte], trust: TrustInput
): Inspection =
  ## [G403] The inspection of one archive under `trust`: from the cache when an
  ## entry for these bytes is still accepted, else by `openLgx`, caching it
  ## when it verifies.
  let digest = blake3(data)
  inc c.tick
  if digest in c.entries:
    var e = c.entries.getOrDefault(digest)
    if e.stillAccepted(trust):
      inc c.counters.hits
      e.used = c.tick
      let answer = e.inspection
      c.entries[digest] = move e
      return answer
    c.entries.del(digest)
    inc c.counters.dropped
  inc c.counters.opened
  let p = openLgx(data, trust, c.platform, c.limits, c.pathRules).valueOr:
    return Inspection(kind: ikIneligible, error: error)
  # [SPEC PM §4 l.362-364 (PKG-0060); G451] Last in G29/P7a order: each selected module's
  # configuration declaration resolves, or the archive is `invalid-package`.
  checkConfigurations(p).isOkOr:
    return Inspection(kind: ikIneligible, error: error)
  let answer = inspection(p)
  if c.entries.len >= c.capacity:
    c.evictOne()
  c.entries[digest] = CacheEntry(
    profile: signingProfile(),
    kid: p.verified.signer.kid,
    key: p.verified.signer.key,
    identity: p.verified.manifest.identity,
    commitment: p.verified.commitment,
    variant: p.variant.id,
    inspection: answer,
    used: c.tick,
  )
  answer

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
