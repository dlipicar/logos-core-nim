"""Independent deterministic-CBOR reference (G17).

Written from RFC 8949 (§3, §4.2.1, Appendix C) and INTERFACE §4.4-4.5 without
reusing the Nim code. Errors are classified like the Nim decoder:

  malformed          not one well-formed data item (checked over the whole input first)
  non-deterministic  well-formed, but not the deterministic encoding (§4.4; G38 for floats)
  invalid-utf8       a text string that is not UTF-8 (§4.5 reports it as schema-mismatch)
  too-deep           containers nested deeper than the cap (G59)

Tags, floats and simple values decode (G38). Values: int, bytes, str, list,
dict (insertion order = encoded order), Tag, Simple, Float.
"""

from __future__ import annotations

import struct
import sys
from dataclasses import dataclass

sys.setrecursionlimit(20000)
MAX_DEPTH = 1024


class DcborError(ValueError):
    def __init__(self, kind: str, msg: str) -> None:
        super().__init__(f"{kind}: {msg}")
        self.kind = kind


@dataclass(frozen=True)
class Tag:
    tag: int
    content: object


@dataclass(frozen=True)
class Simple:
    value: int  # 20 false and 21 true decode as bool, 22 null as None


@dataclass(frozen=True)
class Float:
    width: int  # 2, 4 or 8 bytes
    bits: int


UNDEFINED = Simple(23)


# Encoding ------------------------------------------------------------------------


def _head(major: int, n: int) -> bytes:
    if n < 24:
        return bytes([major << 5 | n])
    for ai, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if n < 1 << (8 * size):
            return bytes([major << 5 | ai]) + n.to_bytes(size, "big")
    raise ValueError("argument does not fit in 64 bits")


def encode(v) -> bytes:
    if v is False:
        return b"\xf4"
    if v is True:
        return b"\xf5"
    if v is None:
        return b"\xf6"
    if isinstance(v, int):
        return _head(0, v) if v >= 0 else _head(1, -1 - v)
    if isinstance(v, (bytes, bytearray)):
        return _head(2, len(v)) + bytes(v)
    if isinstance(v, str):
        b = v.encode("utf-8", "surrogateescape")
        return _head(3, len(b)) + b
    if isinstance(v, (list, tuple)):
        return _head(4, len(v)) + b"".join(encode(x) for x in v)
    if isinstance(v, dict):
        items = sorted((encode(k), encode(x)) for k, x in v.items())
        if len({k for k, _ in items}) != len(items):
            raise ValueError("duplicate map key")
        return _head(5, len(items)) + b"".join(k + x for k, x in items)
    if isinstance(v, Tag):
        return _head(6, v.tag) + encode(v.content)
    if isinstance(v, Simple):
        return bytes([0xE0 | v.value]) if v.value < 24 else bytes([0xF8, v.value])
    if isinstance(v, Float):
        return bytes([0xE0 | {2: 25, 4: 26, 8: 27}[v.width]]) + v.bits.to_bytes(v.width, "big")
    raise ValueError(f"cannot encode {type(v).__name__}")


# Well-formedness (RFC 8949 Appendix C) ---------------------------------------------


def _well_formed(data: bytes, max_depth: int) -> None:
    pos = 0

    def take(n: int) -> bytes:
        nonlocal pos
        if pos + n > len(data):
            raise DcborError("malformed", "truncated")
        out = data[pos : pos + n]
        pos += n
        return out

    def item(depth: int, breakable: bool) -> int:
        """Returns the major type, or -1 for a break."""
        ib = take(1)[0]
        major, ai = ib >> 5, ib & 31
        val = ai
        if ai == 24:
            val = take(1)[0]
        elif ai == 25:
            val = int.from_bytes(take(2), "big")
        elif ai == 26:
            val = int.from_bytes(take(4), "big")
        elif ai == 27:
            val = int.from_bytes(take(8), "big")
        elif ai in (28, 29, 30):
            raise DcborError("malformed", "reserved additional information")
        elif ai == 31:
            return indefinite(major, depth, breakable)
        if major == 7 and ai == 24 and val < 32:
            raise DcborError("malformed", "two-byte simple value below 32")
        if major in (2, 3):
            take(val)
        elif major in (4, 5, 6):
            if depth + 1 > max_depth:
                raise DcborError("too-deep", "nesting too deep")
            count = 1 if major == 6 else val * (2 if major == 5 else 1)
            for _ in range(count):
                if item(depth + 1, False) == -1:
                    raise DcborError("malformed", "break inside a definite container")
        return major

    def indefinite(major: int, depth: int, breakable: bool) -> int:
        if major in (2, 3):
            if depth + 1 > max_depth:
                raise DcborError("too-deep", "nesting too deep")
            while True:
                if pos >= len(data):
                    raise DcborError("malformed", "truncated")
                ib = data[pos]
                if ib == 0xFF:
                    take(1)
                    return major
                if ib >> 5 != major or ib & 31 == 31:
                    raise DcborError("malformed", "invalid chunk")
                item(depth + 1, False)
        if major in (4, 5):
            if depth + 1 > max_depth:
                raise DcborError("too-deep", "nesting too deep")
            n = 0
            while item(depth + 1, True) != -1:
                n += 1
            if major == 5 and n % 2:
                raise DcborError("malformed", "odd indefinite map")
            return major
        if major == 7:
            if not breakable:
                raise DcborError("malformed", "unexpected break")
            return -1
        raise DcborError("malformed", "indefinite length on major type %d" % major)

    if item(0, False) == -1:
        raise DcborError("malformed", "unexpected break")
    if pos != len(data):
        raise DcborError("malformed", "trailing bytes")


# Deterministic decoding ----------------------------------------------------------


def _double_of(width: int, bits: int) -> float:
    fmt = {2: ">e", 4: ">f", 8: ">d"}[width]
    return struct.unpack(fmt, bits.to_bytes(width, "big"))[0]


def _float_shortest(width: int, bits: int) -> bool:
    """True when no narrower width holds the same value (bit-exact for NaN payloads)."""
    if width == 2:
        return True
    raw = bits.to_bytes(width, "big")
    if width == 4:
        sign, exp, mant = bits >> 31, (bits >> 23) & 0xFF, bits & 0x7FFFFF
        exp_all, mant_bits = 0xFF, 23
    else:
        sign, exp, mant = bits >> 63, (bits >> 52) & 0x7FF, bits & ((1 << 52) - 1)
        exp_all, mant_bits = 0x7FF, 52
    if exp == exp_all:  # infinity or NaN: payload must fit the narrower mantissa
        narrower = [(10, 2)] if width == 4 else [(23, 4), (10, 2)]
        return not any(mant & ((1 << (mant_bits - m)) - 1) == 0 for m, _ in narrower)
    value = struct.unpack(">f" if width == 4 else ">d", raw)[0]
    want = struct.pack(">d", value)
    for w, fmt in ((2, ">e"), (4, ">f")):
        if w >= width:
            continue
        try:
            back = struct.unpack(fmt, struct.pack(fmt, value))[0]
        except OverflowError:
            continue
        if struct.pack(">d", back) == want:
            return False
    return True


def _valid_utf8(b: bytes) -> bool:
    try:
        b.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return False
    return True


def _decode(data: bytes, allow_invalid_utf8: bool):
    pos = 0

    def head():
        nonlocal pos
        ib = data[pos]
        pos += 1
        major, ai = ib >> 5, ib & 31
        if ai == 31:
            raise DcborError("non-deterministic", "indefinite-length item")
        if ai < 24:
            return major, ai, ai
        size = 1 << (ai - 24)
        val = int.from_bytes(data[pos : pos + size], "big")
        pos += size
        if major != 7 and val < (24 if size == 1 else 1 << (4 * size)):
            raise DcborError("non-deterministic", "argument not in shortest form")
        return major, ai, val

    def item():
        nonlocal pos
        major, ai, val = head()
        if major == 0:
            return val
        if major == 1:
            return -1 - val
        if major == 2:
            out = data[pos : pos + val]
            pos += val
            return bytes(out)
        if major == 3:
            raw = data[pos : pos + val]
            pos += val
            if not _valid_utf8(raw):
                if not allow_invalid_utf8:
                    raise DcborError("invalid-utf8", "text string is not UTF-8")
                return raw.decode("utf-8", "surrogateescape")
            return raw.decode("utf-8")
        if major == 4:
            return [item() for _ in range(val)]
        if major == 5:
            out, prev = {}, None
            for _ in range(val):
                start = pos
                k = item()
                kb = data[start:pos]
                if prev is not None and kb <= prev:
                    raise DcborError("non-deterministic", "duplicate or unsorted map key")
                prev = kb
                out[_hashable(k)] = item()
            return out
        if major == 6:
            return Tag(val, item())
        if ai in (25, 26, 27):
            width = {25: 2, 26: 4, 27: 8}[ai]
            if not _float_shortest(width, val):
                raise DcborError("non-deterministic", "float not in shortest form")
            return Float(width, val)
        if val == 20:
            return False
        if val == 21:
            return True
        if val == 22:
            return None
        return Simple(val)

    return item()


def _hashable(k):
    if isinstance(k, list):
        return tuple(_hashable(x) for x in k)
    if isinstance(k, dict):
        return tuple((a, _hashable(b)) for a, b in k.items())
    return k


def decode(data: bytes, max_depth: int = MAX_DEPTH, allow_invalid_utf8: bool = False):
    _well_formed(bytes(data), max_depth)
    return _decode(bytes(data), allow_invalid_utf8)


def classify(data: bytes, max_depth: int = MAX_DEPTH) -> str:
    try:
        decode(data, max_depth)
    except DcborError as e:
        return e.kind
    return "ok"


# Diagnostic notation, same one-line form as the Nim printer ------------------------


def _text(s: str) -> str:
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def diag(v) -> str:
    if v is False:
        return "false"
    if v is True:
        return "true"
    if v is None:
        return "null"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, bytes):
        return "h'" + v.hex() + "'"
    if isinstance(v, str):
        return _text(v)
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(diag(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(diag(k) + ": " + diag(x) for k, x in v.items()) + "}"
    if isinstance(v, Tag):
        return f"{v.tag}({diag(v.content)})"
    if isinstance(v, Simple):
        return "undefined" if v.value == 23 else f"simple({v.value})"
    raise ValueError("no diagnostic form for floats in vectors")
