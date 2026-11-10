"""Writes tests/vectors/ed25519/edge.json: Ed25519 edge cases with three verdicts.

  strict      G42: libsodium's crypto_sign_verify_detached (oracle/ed25519.verify)
  lenient     RFC 8032 cofactorless with lenient point decoding: non-canonical y
              reduced, x = 0 with the sign bit set accepted, no small-order checks.
              This is what BoringSSL's ED25519_verify does on its own.
  cofactored  RFC 8032 §5.1.7 as written ([8][S]B = [8]R + [8][h]A); for reference.

The Nim suite checks its verify against `strict` and raw BoringSSL against
`lenient`, which shows what the G42/G135 pre-checks add. Cases with `"signed": true`
are fresh signatures: the suite also checks its key derivation and signing against
them. `small_order` lists the small-order encodings (sign bit cleared) that the
oracle derives from the curve, for the Nim blocklist to match.

  python3 oracle/gen_ed25519_vectors.py           write the file
  python3 oracle/gen_ed25519_vectors.py --check   fail if the file is not what this writes
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ed25519 as ed  # noqa: E402

OUT = Path("tests/vectors/ed25519/edge.json")

# RFC 8032 §7.1 TEST 1 and TEST 2: the oracle must reproduce them before it labels
# anything.
RFC8032 = [
    (
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "",
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ),
    (
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    ),
]

for seed, pk, msg, sig in RFC8032:
    s, m = bytes.fromhex(seed), bytes.fromhex(msg)
    assert ed.public_key(s).hex() == pk, "oracle key derivation disagrees with RFC 8032"
    assert ed.sign(s, m).hex() == sig, "oracle signing disagrees with RFC 8032"
    assert ed.verify(bytes.fromhex(pk), m, bytes.fromhex(sig))

SEED = bytes(range(32))
MSG = b"logos ed25519 edge case"
FULL = (1 << 255) - 1


def scalar_of(seed: bytes) -> int:
    return ed._expand(seed)[0]


def le(n: int) -> bytes:
    return int.to_bytes(n, 32, "little")


def nonce(label: str, i: int) -> int:
    return int.from_bytes(hashlib.sha512(f"{label}/{i}".encode()).digest(), "little") % ed.L


def decode_lenient(s: bytes) -> tuple | None:
    """BoringSSL's x25519_ge_frombytes_vartime: y taken mod p, x = 0 accepted
    whatever the sign bit."""
    v = int.from_bytes(s, "little")
    sign, y = v >> 255, (v & FULL) % ed.P
    x = ed._recover_x(y, 0)
    if x is None:
        return None
    if x != 0 and (x & 1) != sign:
        x = ed.P - x
    return ed._point(x, y)


def verify_lenient(pk: bytes, msg: bytes, sig: bytes) -> bool:
    if len(pk) != 32 or len(sig) != 64:
        return False
    s = int.from_bytes(sig[32:], "little")
    a = decode_lenient(pk)
    if s >= ed.L or a is None:
        return False
    h = ed.sha512_mod_l(sig[:32], pk, msg)
    neg_a = ((ed.P - a[0]) % ed.P, a[1], a[2], (ed.P - a[3]) % ed.P)
    return ed.encode_point(ed.add_points(ed.mul_point(s, ed.B), ed.mul_point(h, neg_a))) == sig[:32]


def verify_cofactored(pk: bytes, msg: bytes, sig: bytes) -> bool:
    if len(pk) != 32 or len(sig) != 64:
        return False
    a, r = decode_lenient(pk), decode_lenient(sig[:32])
    s = int.from_bytes(sig[32:], "little")
    if a is None or r is None or s >= ed.L:
        return False
    h = ed.sha512_mod_l(sig[:32], pk, msg)
    lhs = ed.mul_point(8, ed.mul_point(s, ed.B))
    rhs = ed.mul_point(8, ed.add_points(r, ed.mul_point(h, a)))
    return ed._equal(lhs, rhs)


cases: list[dict] = []


def case(name: str, why: str, pk: bytes, msg: bytes, sig: bytes, signed: bool = False) -> None:
    c = {
        "name": name,
        "why": why,
        "pk": pk.hex(),
        "msg": msg.hex(),
        "sig": sig.hex(),
        "strict": ed.verify(pk, msg, sig),
        "lenient": verify_lenient(pk, msg, sig),
        "cofactored": verify_cofactored(pk, msg, sig),
    }
    if signed:
        c["seed"] = SEED.hex()
    cases.append(c)


a = scalar_of(SEED)
PK = ed.public_key(SEED)
A = ed.decode_point(PK)


def order_of(t: tuple) -> int:
    for k in (1, 2, 4, 8):
        if ed._equal(ed.mul_point(k, t), ed.IDENTITY):
            return k
    raise AssertionError("not a torsion point")


TORSION = ed.torsion_points()
T8 = next(t for t in TORSION if order_of(t) == 8)

# Ordinary signatures --------------------------------------------------------------

for name, msg in [("empty", b""), ("short", b"abc"), ("long", bytes(range(256)) * 4)]:
    case(f"valid-{name}", "an ordinary signature", PK, msg, ed.sign(SEED, msg), signed=True)

good = ed.sign(SEED, MSG)
r_bytes, s_int = good[:32], int.from_bytes(good[32:], "little")
case("valid", "an ordinary signature", PK, MSG, good, signed=True)
case("s-plus-l", "S + L: a non-canonical scalar (malleability)", PK, MSG, r_bytes + le(s_int + ed.L))
case("s-equals-l", "S = L", PK, MSG, r_bytes + le(ed.L))
case("s-high-bits", "the top three bits of S set", PK, MSG, good[:63] + bytes([good[63] | 0xE0]))
case("msg-bit-flip", "the message changed", PK, MSG[:-1] + bytes([MSG[-1] ^ 1]), good)
case("r-bit-flip", "a bit of R changed", PK, MSG, bytes([good[0] ^ 1]) + good[1:])
case("s-bit-flip", "a bit of S changed", PK, MSG, good[:32] + bytes([good[32] ^ 1]) + good[33:])
case("key-sign-flip", "the public key's sign bit flipped", PK[:31] + bytes([PK[31] ^ 0x80]), MSG, good)

# Small-order public keys: [S]B - [h]T = R holds whenever [h]T is the identity, so
# R = [r]B, S = r verifies under cofactorless arithmetic for every message once
# h is a multiple of the order of T.

small = sorted({int.from_bytes(le(y), "little") for y in ed.SMALL_ORDER_YS})
for y in small:
    for sign in (0, 1):
        enc = le(y | (sign << 255))
        t = decode_lenient(enc)
        if t is None:
            continue
        k = order_of(t)
        i = 0
        while True:
            r = nonce(f"small-a/{enc.hex()}", i)
            big_r = ed.encode_point(ed.mul_point(r, ed.B))
            h = ed.sha512_mod_l(big_r, enc, MSG)
            if h % k == 0:
                break
            i += 1
        canon = "canonical" if y < ed.P else "non-canonical"
        case(
            f"small-order-key-{y:064x}-{sign}",
            f"a small-order public key (order {k}, {canon} y, sign bit {sign}), forged signature",
            enc,
            MSG,
            big_r + le(r),
        )

# Small-order R: with a real key, [S]B - [h]A lies in the prime-order subgroup, so
# only the identity can match; S = h·a makes it match.

for name, enc in [("identity", le(1)), ("identity-non-canonical", le(ed.P + 1)), ("order-2", le(ed.P - 1))]:
    h = ed.sha512_mod_l(enc, PK, MSG)
    case(f"small-order-r-{name}", f"R is a small-order encoding ({name}), S = h·a", PK, MSG, enc + le(h * a % ed.L))

# Mixed-order key A + T (T of order 8): accepted by cofactorless verification when
# 8 divides h, since the torsion part then vanishes; G42 does not check subgroups.

MIXED = ed.encode_point(ed.add_points(A, T8))
for want_zero in (True, False):
    i = 0
    while True:
        r = nonce(f"mixed-a/{want_zero}", i)
        big_r = ed.encode_point(ed.mul_point(r, ed.B))
        h = ed.sha512_mod_l(big_r, MIXED, MSG)
        if (h % 8 == 0) == want_zero:
            break
        i += 1
    label = "h-multiple-of-8" if want_zero else "h-not-multiple-of-8"
    case(f"mixed-order-key-{label}", f"key A + T8 with {label.replace('-', ' ')}", MIXED, MSG, big_r + le((r + h * a) % ed.L))

# Mixed-order R = [r]B + T: cofactored verification accepts, cofactorless does not.

r = nonce("mixed-r", 0)
big_r = ed.encode_point(ed.add_points(ed.mul_point(r, ed.B), T8))
h = ed.sha512_mod_l(big_r, PK, MSG)
case("mixed-order-r", "R = [r]B + T8", PK, MSG, big_r + le((r + h * a) % ed.L))

# Non-canonical public keys that are not small-order: y + p for an on-curve y < 19.
# Nobody knows their discrete logarithm, so no signature verifies; listed so the
# encoding check runs on them.

for y in range(2, 19):
    if ed._recover_x(y, 0) is not None:
        enc = le(y + ed.P)
        r = nonce("non-canonical-key", y)
        case(f"non-canonical-key-{y}", f"public key y = {y} + p", enc, MSG, ed.sign(SEED, MSG)[:32] + le(r))

# Lengths ---------------------------------------------------------------------------

case("sig-short", "a 63-byte signature", PK, MSG, good[:63])
case("sig-long", "a 65-byte signature", PK, MSG, good + b"\x00")
case("key-short", "a 31-byte public key", PK[:31], MSG, good)

doc = {
    "source": "oracle/gen_ed25519_vectors.py",
    "small_order": [le(y).hex() for y in small],
    "cases": cases,
}
text = json.dumps(doc, indent=1) + "\n"

if "--check" in sys.argv[1:]:
    if not OUT.exists() or OUT.read_text() != text:
        sys.exit(f"{OUT} is stale: run python3 oracle/gen_ed25519_vectors.py")
    print(f"ok   {OUT} matches the oracle")
else:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"wrote {OUT}: {len(cases)} cases")
