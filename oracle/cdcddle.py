"""Independent cdCDDLe schema-as-data checker (G17).

Written from cdCDDLe §8 and §10 without reusing the Nim code. `check(data)`
returns the decoded document or raises CdeError; every failure is the `decode`
error class of G16. Source-text canonicalization is not covered here: the
expected models of source vectors are written by hand in gen_cddl_vectors.py.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import dcbor  # noqa: E402

IDENTIFIER = re.compile(r"[A-Za-z@_$](?:[-.]*[A-Za-z@_$0-9])*")
PRIMITIVES = ("uint", "bool", "tstr", "bstr")


class CdeError(ValueError):
    pass


def _int(x: object) -> bool:
    return type(x) is int


def _fields(v: object, kind: int, required: set[int], optional: set[int] = frozenset()) -> dict:
    if type(v) is not dict:
        raise CdeError(f"expected node {kind}, got {type(v).__name__}")
    if not _int(v.get(0)) or v[0] != kind:
        raise CdeError(f"expected node kind {kind}, got {v.get(0)!r}")
    for k in v:
        if not _int(k) or k not in required | optional:
            raise CdeError(f"unknown field {k!r} in node {kind}")
    for k in required:
        if k not in v:
            raise CdeError(f"missing field {k} in node {kind}")
    return v


def _name(x: object) -> str:
    if type(x) is not str or not IDENTIFIER.fullmatch(x) or x in PRIMITIVES:
        raise CdeError(f"invalid rule or reference name {x!r}")
    return x


def _literal(v: object) -> tuple[str, object]:
    v = _fields(v, 6, {0, 1, 2})
    kind, x = v[1], v[2]
    ok = {
        "uint": _int(x) and x >= 0,
        "nint": _int(x) and x < 0,
        "bool": type(x) is bool,
        "tstr": type(x) is str,
        "bstr": type(x) is bytes,
    }
    if kind not in ok or not ok[kind]:
        raise CdeError(f"literal kind {kind!r} with value {x!r}")
    return kind, x


def _range(v: object, non_negative: bool = False) -> None:
    v = _fields(v, 13, {0, 1, 2, 3, 4})
    lo, hi = _literal(v[1]), _literal(v[2])
    if lo[0] not in ("uint", "nint") or hi[0] not in ("uint", "nint"):
        raise CdeError("range bounds must be integer literals")
    if v[3] is not True or v[4] is not True:
        raise CdeError("range bounds must be inclusive")
    if not lo[1] < hi[1]:
        raise CdeError("range lower bound must be below the upper bound")
    if non_negative and lo[1] < 0:
        raise CdeError(".size range bounds must be non-negative")


def _primitive(v: object) -> str:
    v = _fields(v, 5, {0, 1})
    if v[1] not in PRIMITIVES:
        raise CdeError(f"unknown primitive {v[1]!r}")
    return v[1]


def _members(v: object, is_map: bool) -> None:
    v = _fields(v, 9, {0, 1})
    if type(v[1]) is not list:
        raise CdeError("group members must be an array")
    keys: list[str] = []
    occurrences: list[object] = []
    for m in v[1]:
        m = _fields(m, 10, {0, 2}, {1, 3})
        _type(m[2])
        if 1 in m:
            key = _fields(m[1], 21, {0, 1})
            kind, text = _literal(key[1])
            if kind != "tstr":
                raise CdeError("member keys are tstr literals")
            keys.append(text)
        occ = None
        if 3 in m:
            o = _fields(m[3], 11, {0, 1, 2})
            if not (_int(o[1]) and o[1] == 0) or not ((_int(o[2]) and o[2] == 1) or o[2] == "unbounded"):
                raise CdeError(f"invalid occurrence {o!r}")
            occ = "?" if o[2] == 1 else "*"
        occurrences.append(occ)
        if is_map and 1 not in m:
            raise CdeError("map members need a key")
        if not is_map and 1 in m:
            raise CdeError("array members have no key")
    if is_map:
        if "*" in occurrences:
            raise CdeError("map members may only be optional")
        if any(not a < b for a, b in zip(keys, keys[1:])):
            raise CdeError("map members must be sorted by key without duplicates")
    elif any(o is not None for o in occurrences) and occurrences != ["*"]:
        raise CdeError("an array is fixed-length or [* T]")


def _type(v: object) -> None:
    if type(v) is not dict or not _int(v.get(0)):
        raise CdeError(f"not a node: {v!r}")
    kind = v[0]
    if kind == 3:
        _name(_fields(v, 3, {0, 1})[1])
    elif kind == 5:
        _primitive(v)
    elif kind == 6:
        _literal(v)
    elif kind in (7, 8):
        _members(_fields(v, kind, {0, 1})[1], kind == 8)
    elif kind == 12:
        alts = _fields(v, 12, {0, 1})[1]
        if type(alts) is not list or len(alts) < 2:
            raise CdeError("a choice needs two alternatives")
        for a in alts:
            if type(a) is dict and a.get(0) == 12:
                raise CdeError("nested choice (G13)")
            _type(a)
    elif kind == 13:
        _range(v)
    elif kind == 14:
        v = _fields(v, 14, {0, 1, 2, 3})
        if v[1] != "size":
            raise CdeError(f"control {v[1]!r}")
        if _primitive(v[2]) not in ("uint", "tstr", "bstr"):
            raise CdeError(".size target")
        c = v[3]
        if type(c) is dict and c.get(0) == 13:
            _range(c, non_negative=True)
        elif _literal(c)[0] != "uint":
            raise CdeError(".size controller")
    else:
        raise CdeError(f"node kind {kind} in type position")


def check_document(v: object) -> None:
    v = _fields(v, 0, {0, 1, 2})
    if type(v[2]) is not str or v[2] != "cdcddle":
        raise CdeError(f"unknown canonical-model identifier {v[2]!r}")
    if type(v[1]) is not list or not v[1]:
        raise CdeError("a document needs at least one rule")
    names = []
    for r in v[1]:
        r = _fields(r, 1, {0, 1, 3})
        names.append(_name(r[1]))
        _type(r[3])
    if any(not a < b for a, b in zip(names, names[1:])):
        raise CdeError("rules must be sorted by name without duplicates")


def check(data: bytes) -> object:
    try:
        v = dcbor.decode(data)
    except dcbor.DcborError as e:
        raise CdeError(f"not deterministic CBOR: {e}") from e
    check_document(v)
    return v
