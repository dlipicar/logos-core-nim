#!/usr/bin/env bash
# Vendors slhdsa-c (FIPS 205 SLH-DSA, portable C90) into src/logos_core/crypto/slhdsa/
# and extracts the NIST ACVP SLH-DSA-SHA2-192s cases into tests/vectors/slhdsa/.
# Only the files the SHA2-192s pure and internal functions need are copied: no
# SHAKE, no HashSLH-DSA (PM §4.3 forbids it), no build files or scripts.
# Usage: tools/update-slhdsa.sh [<commit> [<acvp-release>]]
set -euo pipefail
cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

COMMIT="${1:-47451432bb04faf8217ffe8a961a75b542bf88e8}"
ACVP="${2:-v1.1.0.43}"
DEST=src/logos_core/crypto/slhdsa
RAW="https://raw.githubusercontent.com/pq-code-package/slhdsa-c/$COMMIT"
ACVP_RAW="https://raw.githubusercontent.com/usnistgov/ACVP-Server/$ACVP/gen-val/json-files"

FILES=(
  sha2_256.c sha2_512.c sha2_api.h slh_sha2.c slh_dsa.c slh_dsa.h
  slh_adrs.h slh_var.h slh_sys.h slh_param.h plat_local.h cbmc.h LICENSE
)
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
  curl -sfL "$RAW/$f" -o "$DEST/$f"
done
printf 'slhdsa-c\ncommit %s\nhttps://github.com/pq-code-package/slhdsa-c/tree/%s\n' \
  "$COMMIT" "$COMMIT" > "$DEST/VERSION"

work=$(mktemp -d build/acvp.XXXXXX)
trap 'rm -rf "$work"' EXIT
for mode in keyGen sigGen sigVer; do
  curl -sfL "$ACVP_RAW/SLH-DSA-$mode-FIPS205/internalProjection.json" \
    -o "$work/SLH-DSA-$mode-FIPS205.internalProjection.json"
done
mkdir -p tests/vectors/slhdsa
python3 -I tools/extract_acvp_slhdsa.py "$work" tests/vectors/slhdsa/acvp-sha2-192s.json
echo "vendored slhdsa-c $COMMIT into $DEST; ACVP $ACVP SHA2-192s cases in tests/vectors/slhdsa/"
