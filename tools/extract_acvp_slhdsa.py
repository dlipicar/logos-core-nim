#!/usr/bin/env python3
"""Extract the SLH-DSA-SHA2-192s cases this repository uses from NIST ACVP files.

Usage: extract_acvp_slhdsa.py ACVP_DIR OUT_JSON

ACVP_DIR holds the three `internalProjection.json` files of the ACVP-Server
release named below, saved as `SLH-DSA-<mode>-FIPS205.internalProjection.json`
(`tools/update-slhdsa.sh` fetches them). Only the parameter set the package
signing profile fixes is kept, and only the pure and internal signature
interfaces: HashSLH-DSA is not implemented (PM §4.3 forbids it). Every case of
those groups is kept, so each sigVer failure reason stays covered.
"""

import hashlib
import json
import os
import sys

RELEASE = "v1.1.0.43"
PARAMETER_SET = "SLH-DSA-SHA2-192s"
MODES = ("keyGen", "sigGen", "sigVer")


def git_blob_sha1(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def main() -> None:
    src, out = sys.argv[1], sys.argv[2]
    result = {
        "source": "https://github.com/usnistgov/ACVP-Server/tree/%s/gen-val/json-files"
        % RELEASE,
        "release": RELEASE,
        "parameterSet": PARAMETER_SET,
        "files": {},
    }
    for mode in MODES:
        name = "SLH-DSA-%s-FIPS205.internalProjection.json" % mode
        data = open(os.path.join(src, name), "rb").read()
        result["files"][mode] = {
            "path": "SLH-DSA-%s-FIPS205/internalProjection.json" % mode,
            "gitBlobSha1": git_blob_sha1(data),
        }
        doc = json.loads(data)
        cases = []
        for g in doc["testGroups"]:
            if g.get("parameterSet") != PARAMETER_SET:
                continue
            if mode != "keyGen" and g.get("preHash") not in ("pure", "none"):
                continue
            for t in g["tests"]:
                if mode == "keyGen":
                    c = {k: t[k] for k in ("tcId", "skSeed", "skPrf", "pkSeed", "sk", "pk")}
                else:
                    c = {
                        "tgId": g["tgId"],
                        "tcId": t["tcId"],
                        "interface": g["signatureInterface"],
                        "message": t["message"],
                        "signature": t["signature"],
                    }
                    if g["signatureInterface"] == "external":
                        c["context"] = t["context"]
                    if mode == "sigGen":
                        c["sk"] = t["sk"]
                        c["deterministic"] = g["deterministic"]
                        if not g["deterministic"]:
                            c["additionalRandomness"] = t["additionalRandomness"]
                    else:
                        c["pk"] = t["pk"]
                        c["testPassed"] = t["testPassed"]
                        c["reason"] = t.get("reason", "")
                cases.append(c)
        result[mode] = cases
    with open(out, "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
        f.write("\n")
    print(
        "%s: keyGen %d, sigGen %d, sigVer %d"
        % (out, len(result["keyGen"]), len(result["sigGen"]), len(result["sigVer"]))
    )


if __name__ == "__main__":
    main()
