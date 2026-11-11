"""Writes tests/vectors/package/cose.json: PM §4.3 COSE_Sign1 objects built by the
oracle (oracle/dcbor.py for the CBOR, oracle/slhdsa.py for the signature).

Each vector gives the three FIPS 205 key-generation seeds, a kid and a claim
payload, and the bytes the profile derives from them: the protected header
(exactly `kid`), the RFC 9052 Sig_structure ("Signature1", protected, the
profile identifier as external_aad, payload), the deterministic pure
SLH-DSA-SHA2-192s signature with the empty context, and the tagged COSE_Sign1.
The profile identifier is read from the mirrored PM §4.3 CDDL and the
commitment identifiers from spec/pins.toml. The claims' roots are arbitrary:
this checks the container, not the manifest commitment.

  python3 oracle/gen_cose_vectors.py           write the file
  python3 oracle/gen_cose_vectors.py --check   fail if the file is not what this writes
"""

from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import dcbor  # noqa: E402
import slhdsa  # noqa: E402

OUT = Path("tests/vectors/package/cose.json")
PINS = tomllib.loads(Path("spec/pins.toml").read_text(encoding="utf-8"))
PROFILE_CDDL = Path("spec/mirrors/PKG/4.3.signing-profile.cddl").read_text(encoding="utf-8")
PROFILE = re.search(r'package_signing_profile\s*=\s*"([^"]+)"', PROFILE_CDDL).group(1)


def claim(fill: int) -> dict:
    return {
        "profile": PROFILE,
        "manifest_commitment": {
            "commitment_model": PINS["commitment-model-id"]["value"],
            "schema_root": bytes([fill]) * 32,
            "schema_subtree_root": bytes([fill + 1]) * 32,
            "value_root": bytes([fill + 2]) * 32,
            "hash_profile": PINS["hash-profile-id"]["value"],
            "hash_suite": PINS["hash-suite-id"]["value"],
        },
    }


def seeds(fill: int) -> tuple[bytes, bytes, bytes]:
    n = slhdsa.N
    return (bytes([fill]) * n, bytes(range(fill, fill + n)), bytes([fill ^ 0xFF]) * n)


def vector(name: str, fill: int, kid: bytes, payload: bytes) -> dict:
    sk_seed, sk_prf, pk_seed = seeds(fill)
    sk, pk = slhdsa.keygen_internal(sk_seed, sk_prf, pk_seed)
    protected = dcbor.encode({4: kid})
    tbs = dcbor.encode(["Signature1", protected, PROFILE.encode(), payload])
    sig = slhdsa.sign(tbs, b"", sk, None)
    assert len(sig) == 16224 and slhdsa.verify(tbs, sig, b"", pk)
    cose = dcbor.encode(dcbor.Tag(18, [protected, {}, payload, sig]))
    return {
        "name": name,
        "sk_seed": sk_seed.hex(),
        "sk_prf": sk_prf.hex(),
        "pk_seed": pk_seed.hex(),
        "public_key": pk.hex(),
        "kid": kid.hex(),
        "payload": payload.hex(),
        "protected": protected.hex(),
        "tbs": tbs.hex(),
        "signature": sig.hex(),
        "cose": cose.hex(),
    }


vectors = [
    vector("short-kid", 0x42, b"k", dcbor.encode(claim(0x10))),
    vector("text-kid", 0x07, b"logos-dev-2026", dcbor.encode(claim(0x20))),
    vector("max-kid", 0xA5, bytes(range(128)), dcbor.encode(claim(0x30))),
]

doc = {
    "source": "oracle/gen_cose_vectors.py",
    "profile": PROFILE,
    "algorithm": slhdsa.NAME,
    "vectors": vectors,
}
text = json.dumps(doc, indent=1) + "\n"

if "--check" in sys.argv[1:]:
    if not OUT.exists() or OUT.read_text() != text:
        sys.exit(f"{OUT} is stale: run python3 oracle/gen_cose_vectors.py")
    print(f"ok   {OUT} matches the oracle")
else:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"wrote {OUT}: {len(vectors)} vectors")
