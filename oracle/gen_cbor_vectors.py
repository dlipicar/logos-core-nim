"""Writes tests/vectors/cbor/decode.json from the cases below.

Each case states the expected class. The oracle must classify it the same way,
or nothing is written; the Nim suite then checks the same file. Sources:
RFC 8949 Appendix A (examples) and Appendix F (malformed items), and our own
cases for INTERFACE §4.4 / §4.5 and G38 / G59.

Run from the repository root: python3 oracle/gen_cbor_vectors.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cbor2

sys.path.insert(0, str(Path(__file__).parent))
import dcbor  # noqa: E402

RFC_A_OK = """
00 01 0a 17 1818 1819 1864 1903e8 1a000f4240 1b000000e8d4a51000 1bffffffffffffffff
c249010000000000000000 3bffffffffffffffff c349010000000000000000 20 29 3863 3903e7
f90000 f98000 f93c00 fb3ff199999999999a f93e00 f97bff fa47c35000 fa7f7fffff
fb7e37e43c8800759c f90001 f90400 f9c400 fbc010666666666666 f97c00 f97e00 f9fc00
f4 f5 f6 f7 f0 f8ff
c074323031332d30332d32315432303a30343a30305a c11a514b67b0 c1fb41d452d9ec200000
d74401020304 d818456449455446 d82076687474703a2f2f7777772e6578616d706c652e636f6d
40 4401020304 60 6161 6449455446 62225c 62c3bc 63e6b0b4 64f0908591
80 83010203 8301820203820405 98190102030405060708090a0b0c0d0e0f101112131415161718181819
a0 a201020304 a26161016162820203 826161a161626163
a56161614161626142616361436164614461656145
"""

RFC_A_INDEFINITE = """
fa7f800000 fa7fc00000 faff800000 fb7ff0000000000000 fb7ff8000000000000 fbfff0000000000000
5f42010243030405ff 7f657374726561646d696e67ff 9fff 9f018202039f0405ffff 9f01820203820405ff
83018202039f0405ff 83019f0203ff820405 9f0102030405060708090a0b0c0d0e0f101112131415161718181819ff
bf61610161629f0203ffff 826161bf61626163ff bf6346756ef563416d7421ff
"""

RFC_F_MALFORMED = """
18 1901 1a010203 1b01020304050607 38 58 78 98 9a01ff00 b8 d8 f8 f900 fa0000 fb000000
41 61 5affffffff00 5bffffffffffffffff010203 7affffffff00 7b7fffffffffffffff010203
81 818181818181818181 8200 a1 a20102 a100 a2000000 c0 5f4100 7f6100 9f 9f0102 bf
bf01020102 819f 9f8000 9f9f9f9f9fffffffff 9f819f819f9fffffff
1c 1d 1e 3c 3d 3e 5c 5d 5e 7c 7d 7e 9c 9d 9e bc bd be dc dd de fc fd fe
f800 f801 f818 f81f
5f00ff 5f21ff 5f6100ff 5f80ff 5fa0ff 5fc000ff 5fe0ff 7f4100ff 5f5f4100ffff 7f7f6100ffff
ff 81ff 8200ff a1ff a1ff00 a100ff a20000ff 9f81ff 9f829f819f9fffffffff
bf00ff bf000000ff 1f 3f df
"""

SELF = [
    # INTERFACE §4.4 item 2: shortest arguments (integers, lengths, tags)
    ("1817", "non-deterministic", "uint 23 in a 1-byte argument"),
    ("190017", "non-deterministic", "uint 23 in a 2-byte argument"),
    ("1900ff", "non-deterministic", "uint 255 in a 2-byte argument"),
    ("1a0000ffff", "non-deterministic", "uint 65535 in a 4-byte argument"),
    ("1b00000000ffffffff", "non-deterministic", "uint 2^32-1 in an 8-byte argument"),
    ("3817", "non-deterministic", "-24 in a 1-byte argument"),
    ("5800", "non-deterministic", "empty byte string, 1-byte length"),
    ("7800", "non-deterministic", "empty text string, 1-byte length"),
    ("9800", "non-deterministic", "empty array, 1-byte length"),
    ("b800", "non-deterministic", "empty map, 1-byte length"),
    ("d81701", "non-deterministic", "tag 23 in a 1-byte argument"),
    # item 1: bytewise key order, not length first
    ("a2186400200f", "ok", "keys 100 then -1: bytewise order"),
    ("a2200f186400", "non-deterministic", "keys -1 then 100: length-first order"),
    ("a2616101616202", "ok", "keys \"a\" then \"b\""),
    ("a2616201616102", "non-deterministic", "keys \"b\" then \"a\""),
    # item 4: duplicate keys
    ("a2616101616102", "non-deterministic", "duplicate key \"a\""),
    ("a200010002", "non-deterministic", "duplicate key 0"),
    # item 3: indefinite lengths
    ("5f4100ff", "non-deterministic", "indefinite byte string"),
    ("7fff", "non-deterministic", "empty indefinite text string"),
    ("bfff", "non-deterministic", "empty indefinite map"),
    # floats: never Logos deterministic CBOR (INTERFACE §4.4 item 5); as generic
    # data-model values, only in their shortest width
    ("fa3fc00000", "non-deterministic", "1.5 as single"),
    ("fb3ff8000000000000", "non-deterministic", "1.5 as double"),
    ("fa33800000", "non-deterministic", "2^-24 as single (a half subnormal)"),
    ("fb3e70000000000000", "non-deterministic", "2^-24 as double"),
    ("fa00000001", "ok", "smallest single subnormal"),
    ("fb3ff0000000000001", "ok", "1 + 2^-52"),
    ("fb7ff8000000000001", "ok", "NaN with a payload only a double holds"),
    ("fa7fc00001", "ok", "NaN with a payload only a single holds"),
    ("f97e01", "ok", "half NaN with a payload"),
    ("fa80000000", "non-deterministic", "-0.0 as single"),
    # INTERFACE §4.5: invalid UTF-8 text
    ("61ff", "invalid-utf8", "byte 0xff"),
    ("6180", "invalid-utf8", "lone continuation byte"),
    ("62c0af", "invalid-utf8", "overlong '/'"),
    ("63e08080", "invalid-utf8", "overlong NUL in three bytes"),
    ("63eda080", "invalid-utf8", "surrogate U+D800"),
    ("64f4908080", "invalid-utf8", "above U+10FFFF"),
    ("62e282", "invalid-utf8", "truncated sequence"),
    ("a161ff00", "invalid-utf8", "invalid UTF-8 in a map key"),
    ("63efbfbf", "ok", "U+FFFF"),
    ("64f48fbfbf", "ok", "U+10FFFF"),
    # tags and simple values are data-model values (G38)
    ("d9d9f700", "ok", "self-described CBOR tag"),
    ("f820", "ok", "simple(32)"),
    # well-formedness wins over determinism anywhere in the item
    ("821817ff", "malformed", "non-shortest uint, then a stray break"),
    ("82a2616201616102", "malformed", "unsorted map inside a truncated array"),
    ("0000", "malformed", "two data items"),
    ("", "malformed", "empty input"),
]


def nesting(v) -> int:
    """Arrays, maps and tags on the deepest path (iterative)."""
    deepest, stack = 0, [(v, 0)]
    while stack:
        x, d = stack.pop()
        if isinstance(x, (list, dict, dcbor.Tag)):
            d += 1
            deepest = max(deepest, d)
            kids = x if isinstance(x, list) else [x.content] if isinstance(x, dcbor.Tag) else [y for kv in x.items() for y in kv]
            stack.extend((k, d) for k in kids)
    return deepest


def nested(n: int, inner: str) -> str:
    return "81" * n + inner


SELF += [
    (nested(1023, "80"), "ok", "1024 nested arrays (G59 cap)"),
    (nested(1024, "80"), "too-deep", "1025 nested arrays"),
    (nested(1023, "a0"), "ok", "1023 arrays around an empty map"),
    ("d91770" * 1024 + "00", "ok", "1024 nested tags 6000"),
    ("d91770" * 1025 + "00", "too-deep", "1025 nested tags 6000"),
    # INTERFACE §4.5.1: only arrays and maps count; tags have their own bound
    ("81d91770" * 1023 + "80", "ok", "1024 nested arrays, each under a tag"),
    ("81d91770" * 1024 + "80", "too-deep", "1025 nested arrays, each under a tag"),
    # a float at any depth (INTERFACE §4.4 item 5)
    (nested(3, "a1616181f93e00"), "ok", "a half float three arrays and a map down"),
    ("d903e8f97c00", "ok", "a tagged half infinity"),
]


def main() -> int:
    cases = []
    for h in RFC_A_OK.split():
        cases.append((h, "ok", "RFC 8949 App A"))
    for h in RFC_A_INDEFINITE.split():
        cases.append((h, "non-deterministic", "RFC 8949 App A (not preferred or indefinite)"))
    for h in RFC_F_MALFORMED.split():
        cases.append((h, "malformed", "RFC 8949 App F"))
    cases += SELF

    # `want` is the class in the generic data model, where floats decode;
    # `expect` is the class under Logos deterministic CBOR, where they never do.
    out, bad = [], 0
    for h, want, note in cases:
        data = bytes.fromhex(h)
        got = dcbor.classify(data, allow_floats=True)
        if got != want:
            print(f"oracle says {got}, expected {want}: {h[:40]} ({note})")
            bad += 1
            continue
        logos = dcbor.classify(data)
        rec = {"hex": h, "expect": logos, "note": note}
        if logos != want:
            if logos != "non-deterministic":
                print(f"a float changes {h[:40]} to {logos}, not non-deterministic")
                bad += 1
            rec["data_model"] = want
        if want == "ok":
            v = dcbor.decode(data, allow_floats=True)
            if dcbor.encode(v) != data:
                print(f"oracle re-encoding differs: {h}")
                bad += 1
            # The diagnostic form is a test aid; it is not kept for the
            # deepest items, whose printers would recurse past 1024 levels.
            if nesting(v) <= 1024:
                try:
                    rec["diag"] = dcbor.diag(v)
                except ValueError:
                    pass
            try:
                cbor2.loads(data)
            except Exception as e:  # cbor2 is only a second opinion
                print(f"cbor2 cannot decode ok vector {h[:40]}: {e}")
                bad += 1
        out.append(rec)
    if bad:
        print(f"{bad} disagreements; nothing written")
        return 1
    path = Path("tests/vectors/cbor/decode.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"vectors": out}, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(out)} vectors to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
