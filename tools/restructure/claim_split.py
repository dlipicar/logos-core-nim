#!/usr/bin/env python3
"""Where each claimed unit's evidence is, by package (the restructure's R9, row 35).

For every live gated unit that a package claims, this lists the suites that cite it in each test
tree and the inspection files that cover it in each conformance tree, and which package claims it.
Its TSV output is the split's record (`claim_split.tsv`, committed beside it):

  python3 tools/restructure/claim_split.py [--root .] [--spec IFC ...] > tools/restructure/claim_split.tsv
  python3 tools/restructure/claim_split.py --summary            the table of restructure-in-place §3.8
  python3 tools/restructure/claim_split.py --compare FILE       the union of claimed units is FILE's, unit for unit

`--compare` is R9's check that the split moves claims and never adds or drops one. Reads only; the
claims themselves are in `conformance/claims/` and `sdk/conformance/claims/`.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "spectrace"))
import spectrace as st  # noqa: E402

# (package, its conformance tree, its test tree), in spectrace's order.
PACKAGES = (("core", st.CONFORMANCE_TREES[0], Path(st.TEST_TREES[0])), ("sdk", st.CONFORMANCE_TREES[1], Path(st.TEST_TREES[1])))
HEADER = ["unit", "spec", "section", "owner", "sdk_tests", "core_tests", "sdk_inspection", "core_inspection", "class"]


def citations(root: Path) -> dict[str, dict[str, set[str]]]:
    """unit id -> package -> the suites (paths from the test tree) that cite it."""
    out: dict[str, dict[str, set[str]]] = {}
    for package, _, tests in PACKAGES:
        for f in st.visible((root / tests).rglob("*.nim")):
            for uid in set(st.TEST_ID_RE.findall(f.read_text(encoding="utf-8"))):
                out.setdefault(uid, {}).setdefault(package, set()).add(str(f.relative_to(root / tests)))
    return out


def inspections(root: Path) -> dict[str, dict[str, set[str]]]:
    """unit id -> package -> the inspection files that list it."""
    out: dict[str, dict[str, set[str]]] = {}
    for package, tree, _ in PACKAGES:
        for f in st.visible((root / tree / "inspection").glob("*.toml")):
            for item in st.load_toml(f).get("item", []):
                for uid in item.get("ids", []):
                    out.setdefault(uid, {}).setdefault(package, set()).add(f.name)
    return out


def claimers(root: Path, prefix: str, unit) -> list[str]:
    """The packages whose claims file for the spec claims the unit."""
    found = []
    for package, tree, _ in PACKAGES:
        path = root / tree / "claims" / f"{prefix}.toml"
        if path.exists() and st.unit_status(st.tomllib.loads(path.read_text(encoding="utf-8")), unit) == "claimed":
            found.append(package)
    return found


def evidence_class(tests: dict[str, set[str]], insp: dict[str, set[str]]) -> str:
    sdk, core, inspected = "sdk" in tests, "core" in tests, bool(insp)
    parts = [p for p, on in (("sdk", sdk), ("core", core)) if on]
    name = "+".join(parts) + "-tests" if parts else ""
    if inspected:
        where = "+".join(sorted(insp))
        name = f"{name}+{where}-inspection" if name else f"{where}-inspection-only"
    return name or "none"


def rows(root: Path, specs: list[str]):
    cites, insps = citations(root), inspections(root)
    for fname, prefix in st.SPECS.items():
        if specs and prefix not in specs:
            continue
        _, units = st.load_ledger(st.ledger_path(root, prefix))
        for u in units:
            if u.retired or u.kind not in st.GATED_KINDS:
                continue
            owners = claimers(root, prefix, u)
            if not owners:
                continue
            tests, insp = cites.get(u.id, {}), insps.get(u.id, {})
            yield [
                u.id,
                prefix,
                u.section,
                "+".join(owners),
                ",".join(sorted(tests.get("sdk", ()))),
                ",".join(sorted(tests.get("core", ()))),
                ",".join(sorted(insp.get("sdk", ()))),
                ",".join(sorted(insp.get("core", ()))),
                evidence_class(tests, insp),
            ]


def load_tsv(path: Path) -> list[dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    head = lines[0].split("\t")
    return [dict(zip(head, line.split("\t"))) for line in lines[1:] if line]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".")
    ap.add_argument("--spec", action="append", default=[], help="limit to these prefixes (repeatable)")
    ap.add_argument("--summary", action="store_true", help="counts per spec and evidence class")
    ap.add_argument("--compare", type=Path, help="a committed record: the claimed units must be the same set")
    args = ap.parse_args()
    root = Path(args.root)
    found = list(rows(root, args.spec))
    if args.compare:
        before = {r["unit"] for r in load_tsv(args.compare) if not args.spec or r["spec"] in args.spec}
        now = {r[0] for r in found}
        for uid in sorted(before - now):
            print(f"{uid}: claimed in {args.compare}, claimed by no package now")
        for uid in sorted(now - before):
            print(f"{uid}: claimed now, not in {args.compare}")
        both = [r[0] for r in found if "+" in r[3]]
        for uid in both:
            print(f"{uid}: claimed by both packages")
        print(f"claim_split --compare: {len(now)} claimed now, {len(before)} before, "
              f"{len(before ^ now)} differ, {len(both)} claimed twice")
        return 1 if before != now or both else 0
    if args.summary:
        table: dict[str, dict[str, int]] = {}
        for r in found:
            table.setdefault(r[1], {}).setdefault(r[8], 0)
            table[r[1]][r[8]] += 1
        for prefix, counts in table.items():
            total = sum(counts.values())
            print(f"{prefix} {total}: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
        return 0
    print("\t".join(HEADER))
    for r in found:
        print("\t".join(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
