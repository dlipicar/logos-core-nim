"""Independent HASH-profile physical layout (HASH §4, §5, §7) for checking self vectors.

Input: a normalized value root in the COMMITMENT §9.3 shape, as decoded CBOR (dicts with
integer keys), where each list-value also carries two schema-derived annotations the
§9.3 shape does not hold:
  100: the element schema identity (needed for an empty list)
  101: the packable scalar kind, present only for a homogeneous packable scalar list
Written from the spec text alone; it shares no code with src/.
"""

from __future__ import annotations

from blake3 import blake3

import dcbor

PROFILE = "logos.hash-profile.2026-08.choice-index"
SUITE = "logos.hash-suite.blake3-256"
MODEL = "logos.commitment-model.2026-08"

FANOUT = 256
LIST_CHUNK = 256
STRING_CHUNK = 4096
PACKABLE = {"bool", "uint8", "uint16", "uint32", "uint64", "int8", "int16", "int32", "int64"}
RANGES = {
    "uint8": (0, 2**8 - 1), "uint16": (0, 2**16 - 1), "uint32": (0, 2**32 - 1),
    "uint64": (0, 2**64 - 1), "int8": (-(2**7), 2**7 - 1), "int16": (-(2**15), 2**15 - 1),
    "int32": (-(2**31), 2**31 - 1), "int64": (-(2**63), 2**63 - 1),
}


class LayoutError(ValueError):
    pass


def domain(kind: str) -> str:
    return {"reference-value": "logos.value.reference", "value-root": "logos.value.root"}.get(
        kind, "logos.value." + kind)


def digest(dom: str, payload) -> bytes:
    hi = {0: dom, 1: PROFILE, 2: SUITE, 3: MODEL, 4: payload}
    return blake3(dcbor.encode(hi)).digest()


class Node:
    """A physical object: node kind, payload field 2 and digest."""

    def __init__(self, kind: str, payload: dict | None, schema: bytes, dig: bytes | None = None):
        self.kind = kind
        self.payload = payload
        self.schema = schema
        self.digest = dig if dig is not None else digest(domain(kind), payload)


def made(kind: str, payload: dict) -> Node:
    assert payload[0] == kind
    return Node(kind, payload, payload[2])


def root_record(n: Node) -> dict:
    return {0: n.kind, 1: n.digest, 2: n.schema}


def record(label: dict, n: Node) -> dict:
    return {0: label, 1: n.kind, 2: n.digest, 3: n.schema}


def branch_up(root: bytes, parent_kind: str, parent_schema: bytes, recs: list[tuple[dict, Node]]):
    """HASH §5: group into branches of 256 until at most 256 records remain."""
    if len(recs) <= FANOUT:
        return recs
    level = [(lab, n, i, 1) for i, (lab, n) in enumerate(recs)]
    while len(level) > FANOUT:
        nxt = []
        for g in range(0, len(level), FANOUT):
            group = level[g:g + FANOUT]
            start = group[0][2]
            count = sum(x[3] for x in group)
            payload = {0: "branch", 1: root, 2: parent_schema, 3: parent_kind, 4: start, 5: count,
                       6: [record(lab, n) for lab, n, _, _ in group]}
            nxt.append(({0: "branch", 1: start, 2: count}, made("branch", payload), start, count))
        level = nxt
    return [(lab, n) for lab, n, _, _ in level]


def check_scalar(kind: str, data) -> None:
    if kind == "bool":
        ok = isinstance(data, bool)
    elif kind in RANGES:
        lo, hi = RANGES[kind]
        ok = isinstance(data, int) and not isinstance(data, bool) and lo <= data <= hi
    elif kind == "tstr":
        ok = isinstance(data, str) and "\x00" not in data
    elif kind == "bstr":
        ok = isinstance(data, bytes)
    else:
        ok = False
    if not ok:
        raise LayoutError(f"scalar data does not match {kind}")


def string_node(root: bytes, schema: bytes, kind: str, data: bytes) -> Node:
    text = kind == "tstr"
    total = len(data)
    if total <= STRING_CHUNK:
        body = data.decode("utf-8") if text else data
        return made(kind + "-direct", {0: kind + "-direct", 1: root, 2: schema, 3: total, 4: body})
    recs = []
    for off in range(0, total, STRING_CHUNK):
        part = data[off:off + STRING_CHUNK]
        chunk = made(kind + "-chunk", {0: kind + "-chunk", 1: root, 2: schema, 3: total, 4: off,
                                       5: len(part), 6: part})
        recs.append(({0: "byte-range", 1: off, 2: len(part)}, chunk))
    recs = branch_up(root, kind, schema, recs)
    return made(kind, {0: kind, 1: root, 2: schema, 3: total, 4: [record(l, n) for l, n in recs]})


def layout(root: bytes, v: dict) -> Node:
    k = v[0]
    schema = v[1]
    if k == "map":
        names = [f[1] for f in v[2]]
        if names != sorted(names) or len(set(names)) != len(names):
            raise LayoutError("map fields are not in canonical order")
        recs = []
        for f in v[2]:
            if f[0] != "field":
                raise LayoutError("map member is not a field")
            inner = f[3]
            if inner[0] == "absent":
                if inner[1] != f[2]:
                    raise LayoutError("absent identity differs from the field identity")
                n = made("absent", {0: "absent", 1: root, 2: f[2], 3: f[1]})
            else:
                n = made("field", {0: "field", 1: root, 2: f[2], 3: f[1], 4: root_record(layout(root, inner))})
            recs.append(({0: "field", 1: f[1]}, n))
        recs = branch_up(root, "map", schema, recs)
        return made("map", {0: "map", 1: root, 2: schema, 3: len(v[2]), 4: [record(l, n) for l, n in recs]})
    if k == "list":
        length, elems, elem_schema, pack = v[2], v[3], v[100], v.get(101)
        if length != len(elems) or [e[1] for e in elems] != list(range(length)):
            raise LayoutError("list elements do not cover 0..length-1")
        for e in elems:
            if e[0] != "list-element" or e[2] != elem_schema:
                raise LayoutError("list element identity differs from the element schema")
        if pack is not None:
            if pack not in PACKABLE:
                raise LayoutError("not a packable kind")
            for e in elems:
                s = e[3]
                if s[0] != "scalar" or s[2] != pack or s[1] != elem_schema:
                    raise LayoutError("packed list element is not a scalar of the packed kind")
        if length <= LIST_CHUNK:
            recs = [({0: "index", 1: e[1]}, layout(root, e[3])) for e in elems]
        else:
            recs = []
            for start in range(0, length, LIST_CHUNK):
                part = elems[start:start + LIST_CHUNK]
                if pack is not None:
                    for e in part:
                        check_scalar(pack, e[3][3])
                    n = made("packed-scalar-list-chunk", {
                        0: "packed-scalar-list-chunk", 1: root, 2: schema, 3: elem_schema, 4: pack,
                        5: start, 6: len(part), 7: [e[3][3] for e in part]})
                else:
                    n = made("list-chunk", {
                        0: "list-chunk", 1: root, 2: schema, 3: elem_schema, 4: start, 5: len(part),
                        6: [record({0: "index", 1: e[1]}, layout(root, e[3])) for e in part]})
                recs.append(({0: "index-range", 1: start, 2: len(part)}, n))
            recs = branch_up(root, "list", schema, recs)
        return made("list", {0: "list", 1: root, 2: schema, 3: elem_schema, 4: length,
                             5: [record(l, n) for l, n in recs]})
    if k == "tuple":
        arity, elems = v[2], v[3]
        if arity != len(elems) or [e[1] for e in elems] != list(range(arity)):
            raise LayoutError("tuple elements do not cover 0..arity-1")
        recs = []
        for e in elems:
            n = made("tuple-element", {0: "tuple-element", 1: root, 2: e[2], 3: e[1],
                                       4: root_record(layout(root, e[3]))})
            recs.append(({0: "tuple-position", 1: e[1]}, n))
        recs = branch_up(root, "tuple", schema, recs)
        return made("tuple", {0: "tuple", 1: root, 2: schema, 3: arity, 4: [record(l, n) for l, n in recs]})
    if k == "choice":
        child = layout(root, v[4])
        return made("choice", {0: "choice", 1: root, 2: schema, 3: v[2], 4: v[3],
                               5: record({0: "choice-arm", 1: v[2]}, child)})
    if k == "scalar":
        kind, data = v[2], v[3]
        check_scalar(kind, data)
        if kind == "bstr":
            return string_node(root, schema, "bstr", data)
        if kind == "tstr":
            return string_node(root, schema, "tstr", data.encode("utf-8"))
        return made("scalar", {0: "scalar", 1: root, 2: schema, 3: kind, 4: data})
    if k == "reference-value":
        # [G2] payloads below an imported reference carry the referenced schema root.
        child = layout(v[2], v[4])
        return made("reference-value", {0: "reference-value", 1: root, 2: schema, 3: v[2], 4: v[3],
                                        5: root_record(child)})
    raise LayoutError(f"unexpected value node {k!r}")


def value_root(v: dict) -> tuple[bytes, Node]:
    """The value-root digest of a normalized value root (§9.3) and its child node."""
    if v[0] != "value-root" or v[1] != MODEL:
        raise LayoutError("not a value root of this commitment model")
    child = layout(v[2], v[4])
    payload = {0: "value-root", 1: v[2], 2: v[3], 3: root_record(child)}
    return digest("logos.value.root", payload), child
