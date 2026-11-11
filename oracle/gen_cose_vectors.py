"""Writes tests/vectors/package/cose.json: PM §4.3 COSE_Sign1 objects built by the
oracle (oracle/dcbor.py for the CBOR, oracle/ed25519.py for the signature).

Each vector gives a signing seed, a kid and a claim payload, and the bytes the
profile derives from them: the protected header, the RFC 9052 Sig_structure
("Signature1", protected, empty external_aad, payload), the signature, and the
tagged COSE_Sign1. The profile identifier is read from the mirrored PM §4.3
CDDL and the commitment identifiers from spec/pins.toml. The claims' roots are
arbitrary: this checks the container, not the manifest commitment.

Since spec 6a4dfa28 the mirrored profile is SLH-DSA-SHA2-192s (PM-06) while the
signature is still Ed25519: the interim of DECISIONS I50 until R4 picks an
SLH-DSA implementation.

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
import ed25519 as ed  # noqa: E402

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


def vector(name: str, seed: bytes, kid: bytes, payload: bytes) -> dict:
    protected = dcbor.encode({1: -19, 4: kid})
    tbs = dcbor.encode(["Signature1", protected, b"", payload])
    sig = ed.sign(seed, tbs)
    cose = dcbor.encode(dcbor.Tag(18, [protected, {}, payload, sig]))
    assert ed.verify(ed.public_key(seed), tbs, sig)
    return {
        "name": name,
        "seed": seed.hex(),
        "public_key": ed.public_key(seed).hex(),
        "kid": kid.hex(),
        "payload": payload.hex(),
        "protected": protected.hex(),
        "tbs": tbs.hex(),
        "signature": sig.hex(),
        "cose": cose.hex(),
    }


vectors = [
    vector("short-kid", bytes([0x42]) * 32, b"k", dcbor.encode(claim(0x10))),
    vector("text-kid", bytes(range(32)), b"logos-dev-2026", dcbor.encode(claim(0x20))),
    vector("max-kid", bytes(range(32, 64)), bytes(range(128)), dcbor.encode(claim(0x30))),
]

doc = {"source": "oracle/gen_cose_vectors.py", "profile": PROFILE, "vectors": vectors}
text = json.dumps(doc, indent=1) + "\n"

if "--check" in sys.argv[1:]:
    if not OUT.exists() or OUT.read_text() != text:
        sys.exit(f"{OUT} is stale: run python3 oracle/gen_cose_vectors.py")
    print(f"ok   {OUT} matches the oracle")
else:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"wrote {OUT}: {len(vectors)} vectors")
