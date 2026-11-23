# Remote Runtimes: identity, trust and the TLS key

This page is for an operator who connects two logosd Runtimes with `logos.remote.tls-tcp` (RUNTIME
§9.3.7; TRANSPORT §8.4.1). It covers what Tier 5 step 5-7a-1 built: the Runtime's identity, the remote
trust input, the TLS credential and who signs with it. The remote processes, listeners, exports and
remote routes come with steps 5-7a-2 to 5-7a-4, and so do their sections here. Until then logosd starts
no remote process and nothing is reachable from another host ([DAEMON.md](DAEMON.md) §10).

The decisions are DECISIONS G407 to G411. The files and commands are in [DAEMON.md](DAEMON.md) §3 (the
`remote` section), §6a (the remote trust input) and §6b (the TLS credential).

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
| `key-holder` | `logos_keyholder`, a separate process (`remote.key_holder` names the program; logosd's package installs it at `../libexec/logos-core/logos_keyholder`) | logosd never opens `key.p8` |
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
against code execution as logosd's user. logosd starts the holder from step 5-7a-2, with the remote
processes; the holder exits when logosd is gone.
