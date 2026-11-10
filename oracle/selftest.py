"""Checks the oracle against the normative vectors in spec/mirrors and spec/pins.toml.

Run from the repository root: python3 oracle/selftest.py
"""

from __future__ import annotations

import json
import sys
import tomllib
from pathlib import Path

import cbor2
from blake3 import blake3

sys.path.insert(0, str(Path(__file__).parent))
import cdcddle  # noqa: E402
import dcbor  # noqa: E402
import hashlayout  # noqa: E402

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
PINS = tomllib.loads((ROOT / "spec/pins.toml").read_text(encoding="utf-8"))
failures: list[str] = []


def check(name: str, ok: bool) -> None:
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


def hex_mirror(path: str) -> bytes:
    return bytes.fromhex("".join((ROOT / "spec/mirrors" / path).read_text().split()))


cde = hex_mirror("CDE/app-a.cbor.hex")
check("cdCDDLe App A length equals pin", len(cde) == int(PINS["cde-app-a-length"]["value"]))
check("cdCDDLe App A decodes and re-encodes to the same bytes", dcbor.encode(dcbor.decode(cde)) == cde)
try:
    cdcddle.check(cde)
    check("cdCDDLe App A is a valid canonical model for oracle/cdcddle.py", True)
except cdcddle.CdeError as e:
    check(f"cdCDDLe App A is a valid canonical model for oracle/cdcddle.py ({e})", False)

hsh = hex_mirror("HSH/app-a.hash-input.hex")
check("HASH App A input length equals pin", len(hsh) == int(PINS["hsh-app-a-input-length"]["value"]))
check("HASH App A input re-encodes to the same bytes", dcbor.encode(dcbor.decode(hsh)) == hsh)
check("HASH App A root equals pin", blake3(hsh).hexdigest() == PINS["hsh-app-a-root"]["value"])
check("HASH App A root equals the mirrored text", blake3(hsh).hexdigest() == hex_mirror("HSH/app-a.root.hex").hex())
fields = dcbor.decode(hsh)
check("HASH App A field 1 is the hash-profile pin", fields[1] == PINS["hash-profile-id"]["value"])
check("HASH App A field 2 is the hash-suite pin", fields[2] == PINS["hash-suite-id"]["value"])
check("HASH App A field 3 is the commitment-model pin", fields[3] == PINS["commitment-model-id"]["value"])

# HASH App B: the layout oracle against the pinned digests.
B_ROOT, B_LIST, B_ELEM, B_BSTR = (bytes([b]) * 32 for b in (0x10, 0x11, 0x12, 0x13))


def pinned(name: str) -> bytes:
    return bytes.fromhex(PINS[name]["value"])


elems = [{0: "list-element", 1: i, 2: B_ELEM, 3: {0: "scalar", 1: B_ELEM, 2: "uint16", 3: i}}
         for i in range(257)]
b1_root, b1_list = hashlayout.value_root({0: "value-root", 1: hashlayout.MODEL, 2: B_ROOT, 3: B_LIST, 4: {
    0: "list", 1: B_LIST, 2: 257, 3: elems, 100: B_ELEM, 101: "uint16"}})
check("HASH App B.1 chunks, list and root equal the pins",
      [r[2] for r in b1_list.payload[5]] == [pinned("hsh-b1-first-chunk"), pinned("hsh-b1-final-chunk")]
      and b1_list.digest == pinned("hsh-b1-list") and b1_root == pinned("hsh-b1-value-root"))
b2_root, b2_agg = hashlayout.value_root({0: "value-root", 1: hashlayout.MODEL, 2: B_ROOT, 3: B_BSTR, 4: {
    0: "scalar", 1: B_BSTR, 2: "bstr", 3: bytes(i % 251 for i in range(4097))}})
check("HASH App B.2 chunks, aggregate and root equal the pins",
      [r[2] for r in b2_agg.payload[4]] == [pinned("hsh-b2-first-chunk"), pinned("hsh-b2-final-chunk")]
      and b2_agg.digest == pinned("hsh-b2-aggregate") and b2_root == pinned("hsh-b2-value-root"))
b3 = hashlayout.branch_up(B_ROOT, "list", B_LIST, [
    ({0: "index-range", 1: i * 256, 2: 256},
     hashlayout.Node("packed-scalar-list-chunk", None, B_LIST, bytes(28) + i.to_bytes(4, "big")))
    for i in range(257)])
check("HASH App B.3 branches equal the pins",
      [n.digest for _, n in b3] == [pinned("hsh-b3-branch-0-255"), pinned("hsh-b3-branch-256")])
check("HASH App A root equals the oracle hashing of the COMMITMENT App A schema object",
      hashlayout.digest("logos.schema.root", fields[4]) == pinned("hsh-app-a-root"))

for name, data in (("cde", cde), ("hsh", hsh)):
    check(f"cbor2 agrees with the oracle on {name}", cbor2.dumps(cbor2.loads(data), canonical=True) == data)

vectors = json.loads((ROOT / "tests/vectors/cbor/decode.json").read_text(encoding="utf-8"))["vectors"]
disagree = [v["hex"][:40] for v in vectors if dcbor.classify(bytes.fromhex(v["hex"])) != v["expect"]]
check(f"oracle agrees with all {len(vectors)} CBOR vectors", not disagree)
for h in disagree[:10]:
    print("     disagrees on", h)
check("BLAKE3 of the empty input", blake3(b"").hexdigest()
      == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")

print(f"{len(failures)} failures" if failures else "oracle selftest passed")
sys.exit(1 if failures else 0)
