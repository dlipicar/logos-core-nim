"""Independent SLH-DSA-SHA2-192s reference (G17, FIPS 205).

Written from FIPS 205 (Algorithms 1-24 and §11.2.2, the SHA2 functions for
security categories 3 and 5) without reusing slhdsa-c or the Nim wrapper. Only
the parameter set of the PM §4.3 package-signing profile is defined: n = 24,
h = 63, d = 7, h' = 9, a = 14, k = 17, lg_w = 4, m = 39.

Pure functions (`sign`, `verify`) take a context; the internal ones
(`sign_internal`, `verify_internal`, `keygen_internal`) are what the NIST ACVP
files test. `addrnd=None` is the deterministic variant (opt_rand = PK.seed).

Speed comes from hashing the 64- or 128-byte padded PK.seed block once per key
and copying that state (the same padding FIPS 205 defines, just not rehashed).
"""

from __future__ import annotations

import hashlib
import hmac

NAME = "SLH-DSA-SHA2-192s"
N, H, D, HP, A, K, LG_W, M = 24, 63, 7, 9, 14, 17, 4, 39
W = 1 << LG_W
LEN1 = (8 * N + LG_W - 1) // LG_W  # Equation 5.2
LEN2 = ((LEN1 * (W - 1)).bit_length() - 1) // LG_W + 1  # Equation 5.3
LEN = LEN1 + LEN2
PK_BYTES = 2 * N
SK_BYTES = 4 * N
SIG_BYTES = (1 + K * (1 + A) + H + D * LEN) * N

# ADRS types (FIPS 205 §4.2)
WOTS_HASH, WOTS_PK, TREE, FORS_TREE, FORS_ROOTS, WOTS_PRF, FORS_PRF = range(7)

assert (LEN1, LEN2, SIG_BYTES) == (48, 3, 16224)


class Adrs:
    """The 32-byte address with the setters of FIPS 205 §4.3."""

    def __init__(self) -> None:
        self.b = bytearray(32)

    def copy(self) -> "Adrs":
        c = Adrs()
        c.b[:] = self.b
        return c

    def _put(self, at: int, size: int, v: int) -> None:
        self.b[at : at + size] = v.to_bytes(size, "big")

    def set_layer(self, v: int) -> None:
        self._put(0, 4, v)

    def set_tree(self, v: int) -> None:
        self._put(4, 12, v)

    def set_type_and_clear(self, v: int) -> None:
        self._put(16, 4, v)
        self.b[20:32] = bytes(12)

    def set_key_pair(self, v: int) -> None:
        self._put(20, 4, v)

    def key_pair(self) -> int:
        return int.from_bytes(self.b[20:24], "big")

    def set_chain(self, v: int) -> None:  # also the tree height
        self._put(24, 4, v)

    set_tree_height = set_chain

    def set_hash(self, v: int) -> None:  # also the tree index
        self._put(28, 4, v)

    set_tree_index = set_hash

    def tree_index(self) -> int:
        return int.from_bytes(self.b[28:32], "big")

    def compressed(self) -> bytes:
        """ADRS^c (§11.2): layer byte, 8 tree bytes, type byte, last 12 bytes."""
        b = self.b
        return bytes(b[3:4] + b[8:16] + b[19:20] + b[20:32])


class Ctx:
    """The SHA2 functions of §11.2.2 for one PK.seed."""

    def __init__(self, pk_seed: bytes) -> None:
        self.pk_seed = pk_seed
        self.s256 = hashlib.sha256(pk_seed + bytes(64 - N))
        self.s512 = hashlib.sha512(pk_seed + bytes(128 - N))

    def f(self, adrs: Adrs, m: bytes) -> bytes:
        h = self.s256.copy()
        h.update(adrs.compressed() + m)
        return h.digest()[:N]

    prf_ = f  # PRF(PK.seed, SK.seed, ADRS) has F's shape with SK.seed as the message

    def h(self, adrs: Adrs, m: bytes) -> bytes:  # H and T_l
        h = self.s512.copy()
        h.update(adrs.compressed() + m)
        return h.digest()[:N]

    def chain(self, x: bytes, i: int, s: int, adrs: Adrs) -> bytes:
        """Algorithm 5, with the 18 fixed bytes of ADRS^c computed once."""
        prefix = adrs.compressed()[:18]
        tmp = x
        for j in range(i, i + s):
            h = self.s256.copy()
            h.update(prefix + j.to_bytes(4, "big") + tmp)
            tmp = h.digest()[:N]
        if s > 0:
            adrs.set_hash(i + s - 1)
        return tmp


def base_2b(x: bytes, b: int, out_len: int) -> list[int]:
    """Algorithm 4."""
    i = bits = total = 0
    out = []
    for _ in range(out_len):
        while bits < b:
            total = (total << 8) | x[i]
            i += 1
            bits += 8
        bits -= b
        out.append((total >> bits) & ((1 << b) - 1))
    return out


def _msg_digits(m: bytes) -> list[int]:
    msg = base_2b(m, LG_W, LEN1)
    csum = sum(W - 1 - v for v in msg)
    csum <<= (8 - (LEN2 * LG_W) % 8) % 8
    return msg + base_2b(csum.to_bytes((LEN2 * LG_W + 7) // 8, "big"), LG_W, LEN2)


def _wots_sk_adrs(adrs: Adrs) -> Adrs:
    sk = adrs.copy()
    sk.set_type_and_clear(WOTS_PRF)
    sk.set_key_pair(adrs.key_pair())
    return sk


def _wots_pk_adrs(adrs: Adrs) -> Adrs:
    pk = adrs.copy()
    pk.set_type_and_clear(WOTS_PK)
    pk.set_key_pair(adrs.key_pair())
    return pk


def wots_pkgen(c: Ctx, sk_seed: bytes, adrs: Adrs) -> bytes:
    """Algorithm 6."""
    sk_adrs = _wots_sk_adrs(adrs)
    tmp = []
    for i in range(LEN):
        sk_adrs.set_chain(i)
        sk = c.prf_(sk_adrs, sk_seed)
        adrs.set_chain(i)
        tmp.append(c.chain(sk, 0, W - 1, adrs))
    return c.h(_wots_pk_adrs(adrs), b"".join(tmp))


def wots_sign(c: Ctx, m: bytes, sk_seed: bytes, adrs: Adrs) -> bytes:
    """Algorithm 7."""
    msg = _msg_digits(m)
    sk_adrs = _wots_sk_adrs(adrs)
    sig = []
    for i in range(LEN):
        sk_adrs.set_chain(i)
        sk = c.prf_(sk_adrs, sk_seed)
        adrs.set_chain(i)
        sig.append(c.chain(sk, 0, msg[i], adrs))
    return b"".join(sig)


def wots_pk_from_sig(c: Ctx, sig: bytes, m: bytes, adrs: Adrs) -> bytes:
    """Algorithm 8."""
    msg = _msg_digits(m)
    tmp = []
    for i in range(LEN):
        adrs.set_chain(i)
        tmp.append(c.chain(sig[i * N : (i + 1) * N], msg[i], W - 1 - msg[i], adrs))
    return c.h(_wots_pk_adrs(adrs), b"".join(tmp))


def xmss_node(c: Ctx, sk_seed: bytes, i: int, z: int, adrs: Adrs) -> bytes:
    """Algorithm 9."""
    if z == 0:
        adrs.set_type_and_clear(WOTS_HASH)
        adrs.set_key_pair(i)
        return wots_pkgen(c, sk_seed, adrs)
    left = xmss_node(c, sk_seed, 2 * i, z - 1, adrs)
    right = xmss_node(c, sk_seed, 2 * i + 1, z - 1, adrs)
    adrs.set_type_and_clear(TREE)
    adrs.set_tree_height(z)
    adrs.set_tree_index(i)
    return c.h(adrs, left + right)


def _xmss_levels(c: Ctx, sk_seed: bytes, adrs: Adrs) -> list[list[bytes]]:
    """Every node of one XMSS tree, bottom up: the values Algorithm 9 returns,
    computed once instead of once per authentication-path level."""
    a = adrs.copy()
    level = []
    for i in range(1 << HP):
        a.set_type_and_clear(WOTS_HASH)
        a.set_key_pair(i)
        level.append(wots_pkgen(c, sk_seed, a))
    levels = [level]
    for z in range(1, HP + 1):
        prev, level = levels[-1], []
        for i in range(len(prev) // 2):
            a.set_type_and_clear(TREE)
            a.set_tree_height(z)
            a.set_tree_index(i)
            level.append(c.h(a, prev[2 * i] + prev[2 * i + 1]))
        levels.append(level)
    return levels


def xmss_sign(c: Ctx, m: bytes, sk_seed: bytes, idx: int, adrs: Adrs) -> bytes:
    """Algorithm 10."""
    levels = _xmss_levels(c, sk_seed, adrs)
    auth = b"".join(levels[j][(idx >> j) ^ 1] for j in range(HP))
    adrs.set_type_and_clear(WOTS_HASH)
    adrs.set_key_pair(idx)
    return wots_sign(c, m, sk_seed, adrs) + auth


def xmss_pk_from_sig(c: Ctx, idx: int, sig: bytes, m: bytes, adrs: Adrs) -> bytes:
    """Algorithm 11."""
    adrs.set_type_and_clear(WOTS_HASH)
    adrs.set_key_pair(idx)
    node = wots_pk_from_sig(c, sig[: LEN * N], m, adrs)
    auth = sig[LEN * N :]
    adrs.set_type_and_clear(TREE)
    adrs.set_tree_index(idx)
    for k in range(HP):
        adrs.set_tree_height(k + 1)
        a = auth[k * N : (k + 1) * N]
        if (idx >> k) & 1 == 0:
            adrs.set_tree_index(adrs.tree_index() // 2)
            node = c.h(adrs, node + a)
        else:
            adrs.set_tree_index((adrs.tree_index() - 1) // 2)
            node = c.h(adrs, a + node)
    return node


XMSS_BYTES = (LEN + HP) * N


def ht_sign(c: Ctx, m: bytes, sk_seed: bytes, idx_tree: int, idx_leaf: int) -> bytes:
    """Algorithm 12."""
    adrs = Adrs()
    adrs.set_tree(idx_tree)
    sig = xmss_sign(c, m, sk_seed, idx_leaf, adrs.copy())
    out = [sig]
    root = xmss_pk_from_sig(c, idx_leaf, sig, m, adrs.copy())
    for j in range(1, D):
        idx_leaf = idx_tree % (1 << HP)
        idx_tree >>= HP
        adrs.set_layer(j)
        adrs.set_tree(idx_tree)
        sig = xmss_sign(c, root, sk_seed, idx_leaf, adrs.copy())
        out.append(sig)
        if j < D - 1:
            root = xmss_pk_from_sig(c, idx_leaf, sig, root, adrs.copy())
    return b"".join(out)


def ht_verify(c: Ctx, m: bytes, sig: bytes, idx_tree: int, idx_leaf: int, pk_root: bytes) -> bool:
    """Algorithm 13."""
    adrs = Adrs()
    adrs.set_tree(idx_tree)
    node = xmss_pk_from_sig(c, idx_leaf, sig[:XMSS_BYTES], m, adrs.copy())
    for j in range(1, D):
        idx_leaf = idx_tree % (1 << HP)
        idx_tree >>= HP
        adrs.set_layer(j)
        adrs.set_tree(idx_tree)
        node = xmss_pk_from_sig(
            c, idx_leaf, sig[j * XMSS_BYTES : (j + 1) * XMSS_BYTES], node, adrs.copy()
        )
    return node == pk_root


def fors_skgen(c: Ctx, sk_seed: bytes, adrs: Adrs, idx: int) -> bytes:
    """Algorithm 14."""
    sk = adrs.copy()
    sk.set_type_and_clear(FORS_PRF)
    sk.set_key_pair(adrs.key_pair())
    sk.set_tree_index(idx)
    return c.prf_(sk, sk_seed)


def _fors_levels(c: Ctx, sk_seed: bytes, t: int, adrs: Adrs) -> list[list[bytes]]:
    """Every node of FORS tree t, bottom up, as Algorithm 15 defines them."""
    a = adrs.copy()
    base = t << A
    level = []
    for i in range(1 << A):
        sk = fors_skgen(c, sk_seed, a, base + i)
        a.set_tree_height(0)
        a.set_tree_index(base + i)
        level.append(c.f(a, sk))
    levels = [level]
    for z in range(1, A + 1):
        prev, level = levels[-1], []
        for i in range(len(prev) // 2):
            a.set_tree_height(z)
            a.set_tree_index((t << (A - z)) + i)
            level.append(c.h(a, prev[2 * i] + prev[2 * i + 1]))
        levels.append(level)
    return levels


def fors_sign(c: Ctx, md: bytes, sk_seed: bytes, adrs: Adrs) -> bytes:
    """Algorithm 16."""
    indices = base_2b(md, A, K)
    out = []
    for t in range(K):
        out.append(fors_skgen(c, sk_seed, adrs, (t << A) + indices[t]))
        levels = _fors_levels(c, sk_seed, t, adrs)
        out.extend(levels[j][(indices[t] >> j) ^ 1] for j in range(A))
    return b"".join(out)


def fors_pk_from_sig(c: Ctx, sig: bytes, md: bytes, adrs: Adrs) -> bytes:
    """Algorithm 17."""
    indices = base_2b(md, A, K)
    roots = []
    step = (A + 1) * N
    for t in range(K):
        part = sig[t * step : (t + 1) * step]
        adrs.set_tree_height(0)
        adrs.set_tree_index((t << A) + indices[t])
        node = c.f(adrs, part[:N])
        for j in range(A):
            a = part[(j + 1) * N : (j + 2) * N]
            adrs.set_tree_height(j + 1)
            if (indices[t] >> j) & 1 == 0:
                adrs.set_tree_index(adrs.tree_index() // 2)
                node = c.h(adrs, node + a)
            else:
                adrs.set_tree_index((adrs.tree_index() - 1) // 2)
                node = c.h(adrs, a + node)
        roots.append(node)
    pk = adrs.copy()
    pk.set_type_and_clear(FORS_ROOTS)
    pk.set_key_pair(adrs.key_pair())
    return c.h(pk, b"".join(roots))


FORS_BYTES = K * (1 + A) * N


def keygen_internal(sk_seed: bytes, sk_prf: bytes, pk_seed: bytes) -> tuple[bytes, bytes]:
    """Algorithm 18: (SK, PK)."""
    assert len(sk_seed) == len(sk_prf) == len(pk_seed) == N
    adrs = Adrs()
    adrs.set_layer(D - 1)
    root = _xmss_levels(Ctx(pk_seed), sk_seed, adrs)[HP][0]
    return sk_seed + sk_prf + pk_seed + root, pk_seed + root


def _h_msg(r: bytes, pk_seed: bytes, pk_root: bytes, m: bytes) -> bytes:
    """MGF1-SHA-512(R || PK.seed || SHA-512(R || PK.seed || PK.root || M), m)."""
    seed = r + pk_seed + hashlib.sha512(r + pk_seed + pk_root + m).digest()
    out = b""
    counter = 0
    while len(out) < M:
        out += hashlib.sha512(seed + counter.to_bytes(4, "big")).digest()
        counter += 1
    return out[:M]


def _split(digest: bytes) -> tuple[bytes, int, int]:
    md_len = (K * A + 7) // 8
    tree_len = (H - H // D + 7) // 8
    leaf_len = (H // D + 7) // 8
    md = digest[:md_len]
    idx_tree = int.from_bytes(digest[md_len : md_len + tree_len], "big") % (1 << (H - H // D))
    idx_leaf = int.from_bytes(
        digest[md_len + tree_len : md_len + tree_len + leaf_len], "big"
    ) % (1 << (H // D))
    return md, idx_tree, idx_leaf


def sign_internal(m: bytes, sk: bytes, addrnd: bytes | None) -> bytes:
    """Algorithm 19. `addrnd=None` signs deterministically."""
    assert len(sk) == SK_BYTES
    sk_seed, sk_prf, pk_seed, pk_root = (sk[i * N : (i + 1) * N] for i in range(4))
    c = Ctx(pk_seed)
    opt_rand = pk_seed if addrnd is None else addrnd
    assert len(opt_rand) == N
    r = hmac.new(sk_prf, opt_rand + m, hashlib.sha512).digest()[:N]
    md, idx_tree, idx_leaf = _split(_h_msg(r, pk_seed, pk_root, m))
    adrs = Adrs()
    adrs.set_tree(idx_tree)
    adrs.set_type_and_clear(FORS_TREE)
    adrs.set_key_pair(idx_leaf)
    sig_fors = fors_sign(c, md, sk_seed, adrs.copy())
    pk_fors = fors_pk_from_sig(c, sig_fors, md, adrs.copy())
    return r + sig_fors + ht_sign(c, pk_fors, sk_seed, idx_tree, idx_leaf)


def verify_internal(m: bytes, sig: bytes, pk: bytes) -> bool:
    """Algorithm 20."""
    if len(sig) != SIG_BYTES or len(pk) != PK_BYTES:
        return False
    pk_seed, pk_root = pk[:N], pk[N:]
    c = Ctx(pk_seed)
    r = sig[:N]
    md, idx_tree, idx_leaf = _split(_h_msg(r, pk_seed, pk_root, m))
    adrs = Adrs()
    adrs.set_tree(idx_tree)
    adrs.set_type_and_clear(FORS_TREE)
    adrs.set_key_pair(idx_leaf)
    pk_fors = fors_pk_from_sig(c, sig[N : N + FORS_BYTES], md, adrs)
    return ht_verify(c, pk_fors, sig[N + FORS_BYTES :], idx_tree, idx_leaf, pk_root)


def _pure(m: bytes, ctx: bytes) -> bytes:
    if len(ctx) > 255:
        raise ValueError("a context is at most 255 bytes")
    return bytes([0, len(ctx)]) + ctx + m


def sign(m: bytes, ctx: bytes, sk: bytes, addrnd: bytes | None) -> bytes:
    """Algorithm 22 (pure SLH-DSA)."""
    return sign_internal(_pure(m, ctx), sk, addrnd)


def verify(m: bytes, sig: bytes, ctx: bytes, pk: bytes) -> bool:
    """Algorithm 24 (pure SLH-DSA)."""
    if len(ctx) > 255:
        return False
    return verify_internal(_pure(m, ctx), sig, pk)
