"""Independent Ed25519 reference (G17) with the verification rules of G42.

Written from RFC 8032 §5.1 (arithmetic, encoding, signing) without reusing the
Nim code or BoringSSL. `verify` follows libsodium's crypto_sign_verify_detached,
which G42 adopts:

  - S must be canonical (S < L);
  - R must not be a small-order encoding (the sign bit is ignored);
  - A must be canonically encoded (y < p) and not a small-order encoding;
  - A must decode to a curve point;
  - the check is cofactorless: encode([S]B - [h]A) must equal R byte for byte.

The small-order encodings are derived here (the 8-torsion of the curve and
their non-canonical aliases), not copied.
"""

from __future__ import annotations

import hashlib

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, P - 2, P)) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _inv(x: int) -> int:
    return pow(x, P - 2, P)


# Points in extended coordinates (X, Y, Z, T), x = X/Z, y = Y/Z, xy = T/Z.


def _add(p: tuple, q: tuple) -> tuple:
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    d = 2 * z1 * z2 % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


IDENTITY = (0, 1, 1, 0)


def _mul(s: int, p: tuple) -> tuple:
    q = IDENTITY
    while s > 0:
        if s & 1:
            q = _add(q, p)
        p = _add(p, p)
        s >>= 1
    return q


def _equal(p: tuple, q: tuple) -> bool:
    x1, y1, z1, _ = p
    x2, y2, z2, _ = q
    return (x1 * z2 - x2 * z1) % P == 0 and (y1 * z2 - y2 * z1) % P == 0


def _recover_x(y: int, sign: int) -> int | None:
    if y >= P:
        return None
    x2 = (y * y - 1) * _inv(D * y * y + 1) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


def _point(x: int, y: int) -> tuple:
    return (x, y, 1, x * y % P)


G_Y = 4 * _inv(5) % P
B = _point(_recover_x(G_Y, 0), G_Y)


def encode_point(p: tuple) -> bytes:
    x, y, z, _ = p
    zi = _inv(z)
    x, y = x * zi % P, y * zi % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def decode_point(s: bytes, canonical: bool = True) -> tuple | None:
    """RFC 8032 §5.1.3. With canonical=False, y may be in [p, 2^255) and is
    reduced, as lenient decoders do."""
    if len(s) != 32:
        return None
    v = int.from_bytes(s, "little")
    sign = v >> 255
    y = v & ((1 << 255) - 1)
    if y >= P:
        if canonical:
            return None
        y -= P
    x = _recover_x(y, sign)
    if x is None:
        return None
    return _point(x, y)


def _sha512_int(*parts: bytes) -> int:
    return int.from_bytes(hashlib.sha512(b"".join(parts)).digest(), "little")


def _expand(seed: bytes) -> tuple[int, bytes]:
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(seed: bytes) -> bytes:
    a, _ = _expand(seed)
    return encode_point(_mul(a, B))


def sign(seed: bytes, msg: bytes) -> bytes:
    a, prefix = _expand(seed)
    pk = encode_point(_mul(a, B))
    r = _sha512_int(prefix, msg) % L
    big_r = encode_point(_mul(r, B))
    h = _sha512_int(big_r, pk, msg) % L
    s = (r + h * a) % L
    return big_r + int.to_bytes(s, 32, "little")


# Small-order encodings -------------------------------------------------------------


def torsion_points() -> list[tuple]:
    """The eight points of order dividing 8: [L]Q for points Q of the full group,
    until all eight are found."""
    found: list[tuple] = []
    y = 2
    while len(found) < 8:
        for sign in (0, 1):
            x = _recover_x(y, sign)
            if x is None:
                continue
            t = _mul(L, _point(x, y))
            if not any(_equal(t, f) for f in found):
                found.append(t)
        y += 1
    return found


def small_order_ys() -> list[int]:
    """Every 255-bit y (sign bit cleared) whose encoding names a small-order
    point: the torsion points' y, and y + p where that still fits in 255 bits."""
    ys = set()
    for t in torsion_points():
        y = int.from_bytes(encode_point(t), "little") & ((1 << 255) - 1)
        ys.add(y)
        if y + P < (1 << 255):
            ys.add(y + P)
    return sorted(ys)


SMALL_ORDER_YS = small_order_ys()


def has_small_order(s: bytes) -> bool:
    y = int.from_bytes(s, "little") & ((1 << 255) - 1)
    return y in SMALL_ORDER_YS


def is_canonical_point(s: bytes) -> bool:
    return (int.from_bytes(s, "little") & ((1 << 255) - 1)) < P


def verify(pk: bytes, msg: bytes, sig: bytes) -> bool:
    """G42: libsodium's crypto_sign_verify_detached."""
    if len(pk) != 32 or len(sig) != 64:
        return False
    r_bytes, s_bytes = sig[:32], sig[32:]
    s = int.from_bytes(s_bytes, "little")
    if s >= L or has_small_order(r_bytes):
        return False
    if not is_canonical_point(pk) or has_small_order(pk):
        return False
    a = decode_point(pk)
    if a is None:
        return False
    h = _sha512_int(r_bytes, pk, msg) % L
    neg_a = (P - a[0], a[1], a[2], (P - a[3]) % P)
    check = _add(_mul(s, B), _mul(h, neg_a))
    return encode_point(check) == r_bytes


def verify_cofactored(pk: bytes, msg: bytes, sig: bytes) -> bool:
    """RFC 8032 §5.1.7 as written ([8][S]B = [8]R + [8][h]A), lenient on
    encodings; used only to label vectors."""
    a = decode_point(pk, canonical=False)
    r = decode_point(sig[:32], canonical=False)
    s = int.from_bytes(sig[32:], "little")
    if a is None or r is None or s >= L:
        return False
    h = _sha512_int(sig[:32], pk, msg) % L
    lhs = _mul(8, _mul(s, B))
    rhs = _mul(8, _add(r, _mul(h, a)))
    return _equal(lhs, rhs)


def add_points(p: tuple, q: tuple) -> tuple:
    return _add(p, q)


def mul_point(s: int, p: tuple) -> tuple:
    return _mul(s, p)


def sha512_mod_l(*parts: bytes) -> int:
    return _sha512_int(*parts) % L
