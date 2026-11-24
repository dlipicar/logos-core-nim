#!/usr/bin/env bash
# Each x86_64 Linux flake check's derivation path at two commits, evaluated with no build, and the
# checks whose path differs [IMPL]. Usage:
#
#   tools/drvcmp.sh <repo> <base rev> <tip rev> <out dir>
#
# Each rev's tree is a `git archive` copy under <out dir>/src-<rev>, so nothing untracked in the
# checkout reaches the evaluation; the paths are in <out dir>/drv-<rev>.json. It is the evidence for
# a merge that touches flake.nix or what it reads outside the Nim sources (tools/lint/, nix/): a
# check whose path is unchanged builds and runs exactly as before. A change to the Nim sources,
# tests or claims changes the source set nearly every check builds from, so for one of those the
# reach is `tools/affected_suites.py`'s answer, not this one.
#
# On a Linux host with Nix, never on the Mac: under the host's queue lock and a timeout, one job,
# cache.nixos.org as the only substituter, for example
#
#   flock ~/validate/.queue.lock timeout -k 60 3600 tools/drvcmp.sh repo master HEAD out
set -u
if [ $# -ne 4 ]; then
  echo "usage: drvcmp.sh <repo> <base rev> <tip rev> <out dir>" >&2
  exit 2
fi
R=$1
O=$4
A=$(git -C "$R" rev-parse --verify "$2^{commit}") || exit 2
B=$(git -C "$R" rev-parse --verify "$3^{commit}") || exit 2
mkdir -p "$O" || exit 2
status=0
for rev in "$A" "$B"; do
  src="$O/src-${rev:0:7}"
  mkdir -p "$src" && git -C "$R" archive "$rev" | tar -x -C "$src" || exit 2
  t0=$(date +%s)
  nix eval --max-jobs 1 --option cores 4 --option substituters https://cache.nixos.org/ --json \
    "path:$src#checks.x86_64-linux" --apply 'cs: builtins.mapAttrs (n: d: d.drvPath) cs' \
    > "$O/drv-${rev:0:7}.json" 2> "$O/drv-${rev:0:7}.err"
  rc=$?
  echo "eval ${rev:0:7} rc=$rc $(( $(date +%s) - t0 ))s"
  [ $rc -ne 0 ] && status=2
done
[ $status -ne 0 ] && { echo "an evaluation failed: see $O/drv-*.err" >&2; exit 2; }
python3 -I - "$O/drv-${A:0:7}.json" "$O/drv-${B:0:7}.json" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
print(f"attributes: {len(a)} and {len(b)}")
print("only in base:", sorted(set(a) - set(b)))
print("only in tip:", sorted(set(b) - set(a)))
diff = sorted(n for n in set(a) & set(b) if a[n] != b[n])
print(f"differ ({len(diff)}):", diff)
PY
