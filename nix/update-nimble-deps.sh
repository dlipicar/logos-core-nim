# Regenerates nix/nimble-deps.json from nimble.lock. Entries whose url and rev
# did not change keep their hash; the rest are prefetched.
lock="${1:-nimble.lock}"
out="${2:-nix/nimble-deps.json}"

[ -f "$lock" ] || { echo "error: $lock not found; run \`nimble lock\` first" >&2; exit 1; }
existing='{}'
[ -f "$out" ] && existing=$(cat "$out")

result='{}'
while IFS=$'\t' read -r name url rev method; do
  if [ "$method" != git ]; then
    echo "error: $name uses downloadMethod '$method'; only git is supported" >&2
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
done < <(jq -r '.packages | to_entries[] | select(.key != "nim")
  | [.key, .value.url, .value.vcsRevision, .value.downloadMethod] | @tsv' "$lock")

jq -S . <<<"$result" >"$out"
echo "wrote $out ($(jq length "$out") packages)" >&2
