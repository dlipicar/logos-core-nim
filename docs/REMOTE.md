# Remote Runtimes: identity, trust, listeners and Runtime Control

This page is for an operator who connects two logosd Runtimes with `logos.remote.tls-tcp` (RUNTIME
§9.3.7; TRANSPORT §8.4.1). It covers what Tier 5 steps 5-7a-1 and 5-7a-2 built: the Runtime's identity,
the remote trust input, the TLS credential and who signs with it; the listener processes and how they
end with logosd; listener and export records; and Runtime Control served to another Runtime's
consumers. Remote routes (provider sessions to another Runtime) and this Runtime as a source come with
steps 5-7a-3 and 5-7a-4, and so do their sections here.

The decisions are DECISIONS G407 to G413 and G415. The files and commands are in
[DAEMON.md](DAEMON.md) §3 (the `remote` section), §6a (the remote trust input), §6b (the TLS
credential), §6c (durable disables) and §10 (remote surfaces).

## The model

- **One identity per session.** `logosctl init` gives the session a Runtime id, a lowercase UUID version
  4, kept for the session's life. With `remote.enabled` a start is refused unless the configured id has
  that form (RUNTIME l.2592-2593). The id is not derived from the key, so a key rotation keeps it. A new id
  means a new session, and every peer then needs a new enrollment (l.2597).
- **One credential.** A P-256 key and a self-signed certificate, made offline by `logosctl remote
  credential new`. Each peer holds the certificate as a *direct anchor*: the exact DER certificate this
  Runtime presents (owner decision B2; DECISIONS G324). No certificate authority is involved, and no
  certificate that is not itself an anchor is accepted.
- **One trust input.** `<session>/remote/trust.cbor` holds the anchors of the peers this Runtime trusts
  and their enrollment records, under one revision with its own continuity mark. It is apart from the
  package trust file, and its records are RUNTIME's published `logos.runtime_enrollment` schema
  unchanged.
- **Changes are offline and apply at the next start** (owner decision B3). Every `logosctl remote …`
  command that writes holds the session lock and is refused while logosd runs. A start reads the input
  once; nothing changes while logosd runs. A revocation therefore takes effect by the restart, which
  also ends every connection of the run.

## Enrolling two Runtimes

On each Runtime, A and B:

1. Set `remote: {enabled: true}` in the daemon configuration (`logosctl daemon config set @FILE` with
   logosd stopped; DAEMON.md §3), then `logosctl remote trust init`, which writes an empty input at
   revision 1 and its mark.
2. `logosctl remote credential new`. It writes `remote/credential/peer.cbor`: this Runtime's anchor
   and its enrollment record at revision 1, naming that anchor with the one key.

Then give each Runtime the other's peer file over a channel you trust for its integrity (the file is
public, but whoever can change it in transit chooses whom you trust), and on each:

3. `logosctl remote trust import @peer.cbor`: the anchor and the record as one change, at revision + 1.
4. Start logosd. It logs `remote trust: revision …` and `remote credential: certificate sha-256 …`.

Before you rely on the enrollment, compare by a second channel the anchor id that each side's `remote
credential show` prints with the one the other side's `remote trust show` lists (the BLAKE3-256 of the
certificate's DER).

**Interoperation** (TRANSPORT l.1245). This implementation accepts only direct anchors, so a peer of
another implementation must support the direct-anchor case to enroll this Runtime's certificate, and
must itself present a certificate DER-equal to an anchor held here. Two Runtimes of this implementation
interoperate.

## The two stricter rules, and their cost

RUNTIME l.2650-2656 judges each enrollment key on its own. Two rules here are stricter than the text
(DECISIONS G408):

| Rule | What the text allows | What this implementation does | The cost |
|---|---|---|---|
| A **stale record**: a lower revision than the one accepted for its key | ignore that record | refuse the whole start | one stale record, for example from restoring an old `trust.cbor`, stops logosd until the file is fixed; nothing starts on a file older than what this node accepted |
| A **key the mark holds that the file omits** | not stated: the text has revocation, not deletion | refuse the whole start | a record can never be removed, only revoked; the input grows with every Runtime ever enrolled |

Both rules make a file that went backwards fail loudly instead of quietly re-trusting a peer that was
revoked. `logosctl remote trust show` names what a start would refuse, and every writer refuses to write
a file a start would refuse, so neither case can come from the commands; it takes a file copied in by
hand or restored from a backup. After a lost mark, `logosctl remote trust reestablish --revision N`
writes a new one from the current file (l.2680-2682).

A **conflict** (two different records at the same revision for one key) is not one of these: logosd
starts, that Runtime is rejected, and the start logs `remote-trust-report: Runtime … has 2 conflicting
records`, until a later file carries a higher revision for it.

## Rotating the key

An enrollment names one anchor and a direct anchor has one key, so the old and the new key cannot both
be accepted at once: a rotation is a **cutover** (DECISIONS G324 limit 1, G409). On the Runtime that
rotates, A:

1. With logosd stopped (the command is refused while it runs), `logosctl remote credential rotate`. It
   writes the next credential to `remote/credential-next/` and its peer file, the record at the
   current revision + 1 with the new key alone. A keeps using the old credential until its next start.
2. On every peer: stop logosd, `logosctl remote trust import @peer.cbor` with A's new peer file, start
   logosd. From now on the peer accepts only A's new key: connections between A and that peer fail.
3. On A: restart logosd. The start takes the rotation up (logged as `remote credential: the rotation is
   taken up`): the old key is overwritten and removed, and A presents the new certificate. Connections
   work again.

Between the first of these restarts and the last, A and the peers on the other side of the cutover
cannot connect, whichever order you take, so do them one after the other. A start interrupted during
the take-up finishes it at the next start. Renewing the certificate with the same key is not offered: the
new certificate would be a new anchor at every peer all the same (G324 limit 2).

## Who signs

The processes that run TLS hold no key. Each sends the CertificateVerify input of its handshake over its
control channel and waits for the signature (owner decision B1; DECISIONS G410). Daemon configuration
`remote.signing` chooses who holds the key:

| `remote.signing` | Who holds the key | |
|---|---|---|
| absent or `logosd` | logosd's signing service | the default |
| `key-holder` | `logos_keyholder`, a separate process (`remote.key_holder` names the program) | logosd never opens `key.p8` |
| `process-copy` | each TLS process | tests only: a packaged logosd refuses it |

Either signer checks every request before it signs: a TLS 1.3 CertificateVerify input for the role
logosd fixed for that process (a request cannot name another), ECDSA P-256 with SHA-256 only, and a rate
limit of 100 signatures a second with bursts of 200 [IMPL]. A refused request fails that handshake.

### What the key-holder mode gives, and what it does not

In key-holder mode logosd relays each request to the holder after the same checks, under its own
request id, and relays the answer back. The holder runs the checks again with its own rate limit, and
keeps its own count of signatures and refusals in `remote/keyholder.count`, which logosd neither writes
nor reads (`logosctl remote credential show` prints it). The key is not in logosd's memory. logosd
decodes what remote peers send, so this matters in two different cases:

- **A fault that makes logosd ask for signatures** (a peer steering logosd's signing requests, say):
  logosd can obtain signatures only while the fault lasts, at the holder's rate at most, each counted
  where logosd does not write, and the key never leaves the holder. Nothing has to be rotated afterwards.
  A fault that discloses logosd's memory discloses no key.
- **Code running as logosd's user:** the holder runs as that user, so such code can read the key from
  the holder's memory or from `key.p8`. The mode gives no protection here: rotate the credential.

So the mode guards against faults that disclose logosd's memory or misuse its signing requests, not
against code execution as logosd's user. logosd starts the holder at its start, before any listener
process; the holder exits when logosd is gone.

## The listener process and its end

Each enabled listener record is one `logos_remote` process (DECISIONS G411). logosd's supervision
thread binds the address, takes the restart lock `<session>/work/remote/listener-<hash>.lock`, spawns
the program (`runtime.remote_program`) with the socket and a control channel, and reports the listener
enabled once the process listens. The process authenticates each peer against this start's trust
snapshot and relays to logosd only what Runtime Control needs; no module payload passes through logosd.
A process that ends while its record is enabled is started again after 1 s, doubling to 30 s.

The process ends with logosd however logosd ends (owner decision B3), and its connections with it:

| logosd | How the process ends |
|---|---|
| stops in order | logosd stops each process, waits, kills what is left after 2 s, and reaps them all before it exits, so every lock is free |
| is killed (SIGKILL) | the process's control channel ends, and its parent watch fires: `PR_SET_PDEATHSIG` on Linux, a kqueue `NOTE_EXIT` watch on macOS, on a watcher thread that needs no event loop, so a wedged loop does not delay it |
| was already gone when the process started | the process compares its parent with the pid it was given, after registering the watch, and exits at once (code 70) |

**A stopped process** (SIGSTOP, say, by a debugger) cannot run its watch. When logosd is killed, the
process's group becomes an orphaned process group with a stopped member, and the system sends it SIGHUP
then SIGCONT, which ends it; on Linux the parent-death signal ends it too. Should a process still hold
its lock, the next start is refused, naming the lock and the pid written in it, and never takes over a
process it did not start. Kill that process to start again.

## Listeners and exports

A listener record names an address and whether it is `enabled` and whether it serves Runtime Control
(`runtime_control_enabled`); an export record names a provider of this Runtime and the listener it is
exported through (RUNTIME §9.3.9; DECISIONS G412). Both are disabled by default, and a listener alone
exports nothing: a provider is reachable remotely only through an enabled export through an enabled
listener, and only for a consumer the policy allows.

- **Where they come from:** `remote.listeners` and `remote.exports` in the daemon configuration (only
  with `remote.enabled`), validated as Runtime Control validates the same records, a bad one refusing
  the start; and `set_remote_listener` and `set_provider_export` through Runtime Control, by a consumer
  the policy allows. Package installation and module realization never create one.
- **What fails:** an address whose `profile` contradicts its transport is INVALID_PARAMS; enabling a
  `quic` listener (step 5-12), or any listener on a logosd without `runtime.remote_program`, is
  MODULE_ERROR with the state unchanged; an address that cannot be bound is TRANSPORT_ERROR and the
  listener is not reported enabled. An export naming no listener record, or another Runtime's
  provider, is INVALID_PARAMS.
- **Disabling** a listener stops new connections at its address. Turning its Runtime Control off ends
  its Runtime Control sessions (the answer to that call may come first) and refuses new ones.
- **Which changes last** (Q4): a disable through Runtime Control stays across restarts and crashes, an
  enable through Runtime Control lasts for the run. An operator who shuts a listener through Runtime
  Control during an incident does not get it back, enabled, at the next start. The disables are kept in
  `state/remote-exposure.cbor`; `logosctl remote exposure list` shows them, `logosctl remote exposure
  reset` removes them at the next start, and changing the listener's or export's configuration entry
  drops its disable ([DAEMON.md](DAEMON.md) §6c). A disable whose record cannot be written stays in
  force for the run and its call fails, saying so.

## Runtime Control for another Runtime's consumers

A listener with `runtime_control_enabled` serves the `logos_runtime_control` endpoint (RUNTIME
l.2741-2747; DECISIONS G413). An enrolled source Runtime opens one TLS connection per consumer it
authenticated, and its Transport Hello names that consumer: the `token` is the exact deterministic CBOR
of the consumer's `logos.runtime.module_instance_address`, whose `runtime_instance_id` must be the
source Runtime's own (l.1694-1699). Any other token (missing, empty, malformed, non-deterministic,
with trailing bytes, or naming a consumer of another Runtime) is refused with ProtocolError
NOT_AUTHORISED before any method runs, and the answer's token is empty.

Every call on the connection is made as that **forwarded consumer**, which logosd's policy must allow:

- Only a capability-authority rule whose subject names the source Runtime in `runtimes` matches it
  ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md), "Subjects and facts"; G415). An empty subject, or one
  naming only instances or modules, never does, so enabling remote gives another Runtime nothing until
  the policy says so. `policy: allow-all` with `remote.enabled` refuses the start.
- The method is authorized before its payload is decoded or validated (RUNTIME l.1835): a method the
  consumer may not call is NOT_AUTHORISED whatever it sends.
- `get_self` names the consumer with its own Runtime. `get_execution_permissions` and `report_failure`
  are NOT_AUTHORISED: the consumer has no realization here.
- **Discovery** (`describe_provider`, `list_modules`) shows only providers with an enabled export
  through an enabled listener, and then only as the consumer's `discover` rules allow (l.2765-2767).
- Audit records, decisions and grants name the consumer by its own address, its Runtime included.

Until step 5-7a-3, `establish_route` from a forwarded consumer is authorized and then answered
MODULE_ERROR (no remote route is established yet). Until step 5-7b, which delivers Runtime Control
events to another Runtime with its reflected state, a subscription to a Runtime Control event is
refused with MODULE_ERROR.

An example rule letting the consumers of Runtime `0b6f3c3e-…` list and change this Runtime's listeners:

```text
{
  "kind": "allow",
  "subject": {"runtimes": ["0b6f3c3e-9d0f-4c1a-8f43-7a8f2b9b1a01"]},
  "scopes": [{
    "kind": "runtime-control",
    "methods": ["list_remote_listeners", "set_remote_listener"]
  }]
}
```
