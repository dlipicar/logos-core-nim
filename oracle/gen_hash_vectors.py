"""Writes tests/vectors/hash/layout.cbor: value trees and their HASH-profile value roots.

Each vector holds a normalized value root in the COMMITMENT §9.3 shape, with the two
list annotations oracle/hashlayout.py documents (keys 100 and 101), and the digests
oracle/hashlayout.py computes for it. Large trees are listed by generator name and
size instead; the Nim suite expands them with the same rules (`generated` below).

  python3 oracle/gen_hash_vectors.py           write the file
  python3 oracle/gen_hash_vectors.py --check   fail if the file is not what this writes
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import dcbor  # noqa: E402
import hashlayout as h  # noqa: E402

OUT = Path("tests/vectors/hash/layout.cbor")


def ident(b: int) -> bytes:
    return bytes([b]) * 32


ROOT = ident(0x10)
LIST = ident(0x11)
ELEM = ident(0x12)
BSTR = ident(0x13)
POS = ident(0x14)
FIELD = ident(0x15)
OTHER_ROOT = ident(0x20)
OTHER_DECL = ident(0x21)


def scalar(schema: bytes, kind: str, data) -> dict:
    return {0: "scalar", 1: schema, 2: kind, 3: data}


def field(name: str, schema: bytes, value: dict) -> dict:
    return {0: "field", 1: name, 2: schema, 3: value}


def absent(name: str, schema: bytes) -> dict:
    return field(name, schema, {0: "absent", 1: schema})


def mapv(schema: bytes, fields: list[dict]) -> dict:
    return {0: "map", 1: schema, 2: sorted(fields, key=lambda f: f[1].encode())}


def listv(schema: bytes, elem: bytes, values: list[dict], pack: str | None = None) -> dict:
    v = {0: "list", 1: schema, 2: len(values),
         3: [{0: "list-element", 1: i, 2: elem, 3: x} for i, x in enumerate(values)], 100: elem}
    if pack is not None:
        v[101] = pack
    return v


def tuplev(schema: bytes, positions: list[tuple[bytes, dict]]) -> dict:
    return {0: "tuple", 1: schema, 2: len(positions),
            3: [{0: "tuple-element", 1: i, 2: s, 3: x} for i, (s, x) in enumerate(positions)]}


def choicev(schema: bytes, arm: int, arm_schema: bytes, value: dict) -> dict:
    return {0: "choice", 1: schema, 2: arm, 3: arm_schema, 4: value}


def refv(schema: bytes, root: bytes, decl: bytes, value: dict) -> dict:
    return {0: "reference-value", 1: schema, 2: root, 3: decl, 4: value}


def root_of(subtree: bytes, node: dict, root: bytes = ROOT) -> dict:
    return {0: "value-root", 1: h.MODEL, 2: root, 3: subtree, 4: node}


# Generated trees: the Nim suite builds these with the same rules ------------------


def generated(name: str, n: int) -> dict:
    if name == "packed-uint8-list":
        return root_of(LIST, listv(LIST, ELEM, [scalar(ELEM, "uint8", i % 256) for i in range(n)], "uint8"))
    if name == "tstr-list":
        return root_of(LIST, listv(LIST, ELEM, [scalar(ELEM, "tstr", f"s{i}") for i in range(n)]))
    if name == "bstr":
        return root_of(BSTR, scalar(BSTR, "bstr", bytes(i % 251 for i in range(n))))
    if name == "uint8-tuple":
        return root_of(LIST, tuplev(LIST, [(POS, scalar(POS, "uint8", i % 256)) for i in range(n)]))
    if name == "uint8-map":
        return root_of(LIST, mapv(LIST, [field(f"f{i:06d}", FIELD, scalar(FIELD, "uint8", i % 256))
                                        for i in range(n)]))
    raise ValueError(name)


GENERATED = [
    ("packed-uint8-list", 65537),  # 257 packed chunks: two branches
    ("tstr-list", 513),  # three ordinary list chunks
    ("tstr-list", 65537),  # 257 ordinary chunks: two branches
    ("bstr", 4096 * 256),  # 256 chunks: no branch
    ("bstr", 4096 * 256 + 1),  # 257 chunks: two branches
    ("uint8-tuple", 257),  # tuple branches
    ("uint8-map", 300),  # map branches
    ("uint8-map", 65537),  # 257 first-level branches under two second-level branches
]


# Explicit trees -------------------------------------------------------------------


def explicit() -> list[tuple[str, dict]]:
    v: list[tuple[str, dict]] = []
    for kind, lo, hi in (("uint8", 0, 255), ("uint16", 0, 65535), ("uint32", 0, 2**32 - 1),
                         ("uint64", 0, 2**64 - 1), ("int8", -128, 127), ("int16", -(2**15), 2**15 - 1),
                         ("int32", -(2**31), 2**31 - 1), ("int64", -(2**63), 2**63 - 1)):
        v.append((f"scalar {kind} min", root_of(FIELD, scalar(FIELD, kind, lo))))
        v.append((f"scalar {kind} max", root_of(FIELD, scalar(FIELD, kind, hi))))
    v.append(("scalar uint8 and uint64 with the same value differ (a)", root_of(FIELD, scalar(FIELD, "uint8", 5))))
    v.append(("scalar uint8 and uint64 with the same value differ (b)", root_of(FIELD, scalar(FIELD, "uint64", 5))))
    v.append(("scalar bool false", root_of(FIELD, scalar(FIELD, "bool", False))))
    v.append(("scalar bool true", root_of(FIELD, scalar(FIELD, "bool", True))))
    v.append(("tstr empty", root_of(FIELD, scalar(FIELD, "tstr", ""))))
    v.append(("tstr non-ASCII", root_of(FIELD, scalar(FIELD, "tstr", "aé€😀"))))
    v.append(("tstr 4096 bytes is direct", root_of(FIELD, scalar(FIELD, "tstr", "x" * 4096))))
    v.append(("tstr 4097 bytes is chunked", root_of(FIELD, scalar(FIELD, "tstr", "x" * 4097))))
    v.append(("tstr chunk boundary inside a UTF-8 sequence",
              root_of(FIELD, scalar(FIELD, "tstr", "y" + "aé€😀" * 410))))
    v.append(("bstr empty", root_of(BSTR, scalar(BSTR, "bstr", b""))))
    v.append(("bstr 4096 bytes is direct", root_of(BSTR, scalar(BSTR, "bstr", bytes(range(256)) * 16))))
    v.append(("bstr 8193 bytes is three chunks", root_of(BSTR, scalar(BSTR, "bstr", bytes(i % 7 for i in range(8193))))))
    v.append(("map empty", root_of(LIST, mapv(LIST, []))))
    v.append(("map present and absent fields", root_of(LIST, mapv(LIST, [
        field("b", FIELD, scalar(FIELD, "bool", True)),
        absent("a", POS),
        field("c", POS, scalar(POS, "tstr", "z")),
    ]))))
    v.append(("map with only absent fields", root_of(LIST, mapv(LIST, [absent("x", FIELD), absent("y", FIELD)]))))
    v.append(("map field order is bytewise UTF-8", root_of(LIST, mapv(LIST, [
        field(n, FIELD, scalar(FIELD, "uint8", i)) for i, n in enumerate(["é", "z", "Z", "a_b", "a-b", "ab"])]))))
    v.append(("map 256 fields is direct", root_of(LIST, mapv(LIST, [
        field(f"k{i:03d}", FIELD, scalar(FIELD, "uint8", i)) for i in range(256)]))))
    v.append(("map 257 fields is branched", root_of(LIST, mapv(LIST, [
        field(f"k{i:03d}", FIELD, scalar(FIELD, "uint8", i % 256)) for i in range(257)]))))
    v.append(("list empty", root_of(LIST, listv(LIST, ELEM, []))))
    v.append(("list empty packable", root_of(LIST, listv(LIST, ELEM, [], "uint16"))))
    v.append(("list 256 packable is direct", root_of(LIST, listv(LIST, ELEM, [
        scalar(ELEM, "uint16", i) for i in range(256)], "uint16"))))
    v.append(("list 257 packable int8 with negatives", root_of(LIST, listv(LIST, ELEM, [
        scalar(ELEM, "int8", (i % 256) - 128) for i in range(257)], "int8"))))
    v.append(("list 300 packable bool", root_of(LIST, listv(LIST, ELEM, [
        scalar(ELEM, "bool", i % 3 == 0) for i in range(300)], "bool"))))
    v.append(("list 257 uint8 not packable (reference element)", root_of(LIST, listv(LIST, ELEM, [
        scalar(FIELD, "uint8", i % 256) for i in range(257)]))))
    v.append(("list 512 tstr is two full chunks", root_of(LIST, listv(LIST, ELEM, [
        scalar(ELEM, "tstr", str(i)) for i in range(512)]))))
    v.append(("list of maps", root_of(LIST, listv(LIST, ELEM, [
        mapv(ELEM, [field("n", FIELD, scalar(FIELD, "uint32", i))]) for i in range(3)]))))
    v.append(("list of lists", root_of(LIST, listv(LIST, ELEM, [
        listv(ELEM, POS, [scalar(POS, "int64", -i) for i in range(i)], "int64") for i in range(4)]))))
    v.append(("tuple equal positions stay distinct", root_of(LIST, tuplev(LIST, [
        (POS, scalar(POS, "uint8", 7)), (POS, scalar(POS, "uint8", 7))]))))
    v.append(("tuple empty", root_of(LIST, tuplev(LIST, []))))
    v.append(("choice arm 0", root_of(LIST, choicev(LIST, 0, POS, scalar(POS, "uint8", 1)))))
    v.append(("choice arm 1 same value", root_of(LIST, choicev(LIST, 1, POS, scalar(POS, "uint8", 1)))))
    v.append(("choice holding a map", root_of(LIST, choicev(LIST, 2, ELEM, mapv(ELEM, [absent("q", FIELD)])))))
    v.append(("reference value below a field [G2]", root_of(LIST, mapv(LIST, [
        field("r", FIELD, refv(FIELD, OTHER_ROOT, OTHER_DECL, mapv(OTHER_DECL, [
            field("code", POS, scalar(POS, "uint32", 3)),
            field("tags", ELEM, listv(ELEM, BSTR, [scalar(BSTR, "bstr", b"\x01")])),
        ]))),
    ]))))
    v.append(("reference value at the root [G2]", root_of(FIELD, refv(FIELD, OTHER_ROOT, OTHER_DECL,
                                                                         scalar(OTHER_DECL, "tstr", "ok")))))
    v.append(("same value under another schema root", root_of(FIELD, scalar(FIELD, "bool", True), OTHER_ROOT)))
    v.append(("same value under another subtree root", root_of(POS, scalar(FIELD, "bool", True))))
    return v


def build() -> bytes:
    vectors = []
    for name, tree in explicit():
        digest, child = h.value_root(tree)
        vectors.append({"name": name, "tree": tree, "root": digest, "child-kind": child.kind,
                        "child-digest": child.digest})
    gens = []
    for name, n in GENERATED:
        digest, child = h.value_root(generated(name, n))
        gens.append({"generator": name, "n": n, "root": digest, "child-kind": child.kind,
                     "child-digest": child.digest})
    return dcbor.encode({"vectors": vectors, "generated": gens})


def main() -> int:
    data = build()
    if "--check" in sys.argv:
        if OUT.read_bytes() != data:
            print(f"{OUT} is stale: run python3 oracle/gen_hash_vectors.py")
            return 1
        print(f"{OUT} is current")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(data)
    print(f"wrote {OUT}: {len(data)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
