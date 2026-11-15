## `logosctl init`'s library part (Tier 4b step 4b-6; DECISIONS G293, G297,
## G299, G303; batch E items 19 and E3). docs/DAEMON.md §2.
##
## `initSession` makes a new session: the layout, the Runtime id (a lowercase
## UUID version 4, RUNTIME l.2665), the evidence key and its binding to that id
## (G149), the trust file at revision 1 (revision 2 with the development
## switch) and its mark, and the daemon-config, checked as logosd checks it.
## The Runtime id is fixed for the session's life: a new id needs a new
## session, and with it a new key and kid (CA l.1265, l.1290).
##
## The default daemon-config is `capability-authority` with source
## `logosd-default`, `recovery: true` (U8) and no operator rule, so only the
## system instances can act; no operator module, no call audit (G115).

{.push raises: [].}

import std/[os, sysrand]
import results
import ../base/hex
import ../cbor
import ../durable
import ./[compose, config, evkey, session, trustfile]

export results

type
  InitOptions* = object
    config*: Opt[LcnDaemonConfig] ## `--config`: the operator's value
    rules*: seq[LcnApRule] ## `--policy`: rules added to the policy
    moduleConfigs*: seq[(string, seq[byte])]
      ## `--module-config INSTANCE=@FILE`: provisioned values (G141)
    development*: bool ## `--development`: the switch on, at revision 2
    exe*: string ## logosd's executable, for the default `module_host`

  InitResult* = object
    runtimeId*: string
    key*: EvidenceKeyInfo
    trust*: TrustInput

proc newRuntimeId*(): Result[string, string] =
  ## [batch E 19] A lowercase UUID version 4 from the operating-system CSPRNG.
  var b: array[16, byte]
  if not urandom(b):
    return err("no randomness could be obtained")
  b[6] = (b[6] and 0x0F) or 0x40
  b[8] = (b[8] and 0x3F) or 0x80
  let h = b.toHex
  ok(
    h[0 ..< 8] & "-" & h[8 ..< 12] & "-" & h[12 ..< 16] & "-" & h[16 ..< 20] & "-" &
      h[20 ..< 32]
  )

func defaultDaemonConfig*(runtimeId: string): LcnDaemonConfig =
  ## [G295; U8] The value `logosctl init` writes without `--config`.
  LcnDaemonConfig(
    runtime: LcnDcRuntime(runtime_instance_id: runtimeId),
    policy: LcnDcPolicy(
      kind: LcnDcPolicyKind.Capability_authority,
      arm_Capability_authority: LcnDcPolicyARCapabilityAuthorityMap(
        source: DefaultPolicySource, recovery: Opt.some(true)
      ),
    ),
  )

proc fill(
    dc: var LcnDaemonConfig, opts: InitOptions, runtimeId: string
): Result[void, string] =
  # [batch E 19] init assigns the id; one in `--config` is replaced.
  dc.runtime.runtime_instance_id = runtimeId
  if opts.rules.len > 0:
    if dc.policy.kind != LcnDcPolicyKind.Capability_authority:
      return err("--policy needs a capability-authority policy")
    for r in opts.rules:
      dc.policy.arm_Capability_authority.rules.add(r)
  for (instance, value) in opts.moduleConfigs:
    var found = false
    if dc.modules.isSome:
      for m in dc.modules.get.mitems:
        if m.instance == instance:
          m.provisioned_configuration = Opt.some(value)
          found = true
    if not found:
      return err("--module-config names no operator instance " & instance)
  ok()

proc makeSession(s: Session, opts: InitOptions): Result[InitResult, string] =
  let runtimeId = ?newRuntimeId()
  let key = ?createEvidenceKey(s.keysDir, runtimeId)
  var dc = opts.config.get(defaultDaemonConfig(runtimeId))
  ?fill(dc, opts, runtimeId)
  let trust = ?initTrust(s, opts.development)
  let bytes = ?dc.encode
  discard ?prepareDaemon(s, bytes, trust, exe = opts.exe)
  ?writeAtomic(s.dir, DaemonConfigName, bytes)
  ok(InitResult(runtimeId: runtimeId, key: key, trust: trust))

proc initSession*(s: Session, opts: InitOptions): Result[InitResult, string] =
  ## [G303] A new session in `s.dir`, which must be absent, or empty and
  ## owner-only. On a failure nothing is left behind.
  let existed = dirExists(s.dir)
  if existed:
    var empty = true
    try:
      for _ in walkDir(s.dir):
        empty = false
        break
    except OSError as e:
      return err("the session directory cannot be read: " & e.msg)
    if not empty:
      return err(s.dir & " exists and is not empty; a session is made only once")
  ?createLayout(s)
  var lock = lockSession(s).valueOr:
    return err(error)
  let r = makeSession(s, opts)
  lock.release()
  if r.isErr:
    # An operator's own empty directory is emptied again, not removed.
    try:
      if existed:
        for kind, p in walkDir(s.dir):
          if kind == pcDir:
            removeDir(p)
          else:
            removeFile(p)
      else:
        removeDir(s.dir)
    except CatchableError:
      discard
  r

{.pop.}
