#!/usr/bin/env bash
# Vendors the official BLAKE3 C implementation into src/logos_core/crypto/blake3/.
# Usage: tools/update-blake3.sh [<tag> <commit>]
set -euo pipefail
cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

TAG="${1:-1.8.7}"
COMMIT="${2:-f3149ec5bb5449af877ba20377a11008ff499fa2}"
DEST=src/logos_core/crypto/blake3
RAW="https://raw.githubusercontent.com/BLAKE3-team/BLAKE3/$COMMIT/c"

actual=$(git ls-remote https://github.com/BLAKE3-team/BLAKE3 "refs/tags/$TAG^{}" "refs/tags/$TAG" |
  sort -r | head -1 | cut -f1)
[ "$actual" = "$COMMIT" ] || { echo "tag $TAG is $actual, not $COMMIT" >&2; exit 1; }

FILES=(
  blake3.c blake3.h blake3_dispatch.c blake3_impl.h blake3_portable.c blake3_neon.c
  blake3_sse2_x86-64_unix.S blake3_sse41_x86-64_unix.S
  blake3_avx2_x86-64_unix.S blake3_avx512_x86-64_unix.S
  blake3_sse2_x86-64_windows_gnu.S blake3_sse41_x86-64_windows_gnu.S
  blake3_avx2_x86-64_windows_gnu.S blake3_avx512_x86-64_windows_gnu.S
)
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
  curl -sfL "$RAW/$f" -o "$DEST/$f"
done
curl -sfL "https://raw.githubusercontent.com/BLAKE3-team/BLAKE3/$COMMIT/LICENSE_A2" -o "$DEST/LICENSE_A2"
curl -sfL "https://raw.githubusercontent.com/BLAKE3-team/BLAKE3/$COMMIT/LICENSE_CC0" -o "$DEST/LICENSE_CC0"
curl -sfL "https://raw.githubusercontent.com/BLAKE3-team/BLAKE3/$COMMIT/test_vectors/test_vectors.json" \
  -o tests/vectors/blake3_test_vectors.json
printf 'BLAKE3 %s\ncommit %s\nhttps://github.com/BLAKE3-team/BLAKE3/tree/%s/c\n' "$TAG" "$COMMIT" "$COMMIT" > "$DEST/VERSION"
echo "vendored BLAKE3 $TAG ($COMMIT) into $DEST"
