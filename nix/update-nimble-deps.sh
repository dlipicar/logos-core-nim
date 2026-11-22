# Regenerates nix/nimble-deps.json from nimble.lock. Entries whose url and rev
# did not change keep their hash; the rest are prefetched.
lock="${1:-nimble.lock}"
out="${2:-nix/nimble-deps.json}"

# nix-prefetch-git clones under TMPDIR and the hash covers what that file system
# kept: on exFAT, AppleDouble `._*` files and an executable bit on every file.
TMPDIR=$(mktemp -d /tmp/update-nimble-deps.XXXXXX)
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

[ -f "$lock" ] || { echo "error: $lock not found; run \`nimble lock\` first" >&2; exit 1; }
existing='{}'
[ -f "$out" ] && existing=$(cat "$out")

result='{}'
while IFS=$'\t' read -r name url rev method; do
  if [ "$method" != git ]; then
    echo "error: $name uses downloadMethod '$method'; only git is supported" >&2
    exit 1
  fi
  # [G436] nix/nimble-deps.nix refuses these too; failing here saves a prefetch.
  if [ "$name" = nim ]; then
    echo "error: $lock has a nim entry; lock again with --useSystemNim" >&2
    exit 1
  fi
  if [ -z "$url" ] || [ -z "$rev" ]; then
    echo "error: $name has an empty url or vcsRevision in $lock; lock again" >&2
    exit 1
  fi
  hash=$(jq -r --arg n "$name" --arg u "$url" --arg r "$rev" \
    '.[$n] // {} | select(.url == $u and .rev == $r) | .hash // empty' <<<"$existing")
  if [ -z "$hash" ]; then
    echo "prefetching $name @ $rev" >&2
    prefetched=$(nix-prefetch-git --quiet --url "$url" --rev "$rev" --fetch-submodules)
    hash=$(jq -r '.hash // empty' <<<"$prefetched")
    if [ -z "$hash" ]; then
      hash=$(nix hash convert --hash-algo sha256 --to sri "$(jq -r .sha256 <<<"$prefetched")")
    fi
  fi
  result=$(jq --arg n "$name" --arg u "$url" --arg r "$rev" --arg h "$hash" \
    '. + {($n): {url: $u, rev: $r, hash: $h}}' <<<"$result")
done < <(jq -r '.packages | to_entries[]
  | [.key, .value.url, .value.vcsRevision, .value.downloadMethod] | @tsv' "$lock")

jq -S . <<<"$result" >"$out"
echo "wrote $out ($(jq length "$out") packages)" >&2
