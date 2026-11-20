#!/usr/bin/env python3
# The re-pin's citation pass, step 1 of 2 (re-pin P9; procedure in docs/SPEC-STATUS.md "When a spec revision
# lands"). Written for the 6a4dfa28 -> 6cac8335 re-pin and kept as it ran, with two fixes: fenced blocks are
# skipped, and a range that maps with new lines inside it is `widened`. No self-test and no gate: a hand tool.
"""Read-only survey of spec line citations (`<SPEC> l.N`) in a logos-core-nim checkout.

cites.py <repo> <old raw dir> <new raw dir> <pre-repin commit> <out.tsv> <file>...

For each citation: the spec it names (inherited along a line or table row), the cited range, the revision
the line presumably cites (by git blame: a line last changed after <pre-repin commit> is presumed to cite
6cac8335, an older one 6a4dfa28), and what the line map of the 6a4dfa28 -> 6cac8335 diff says:
  same     the old range maps to the same numbers (text unchanged): nothing to do
  shift    the old range maps to other numbers, text unchanged: mechanical rewrite
  widened  both ends map, but new lines sit inside the new range: read by hand
  changed  some cited old line is in a diff hunk: read by hand
  current  presumed 6cac8335 already (checked: the new range exists and is not blank)
  suspect  the presumed revision's line is blank or past the end: read by hand
  unknown  no spec could be attributed: read by hand
A line inside a fenced block is skipped: such blocks are verbatim twins of code (policy.cddl, daemon_config.cddl,
the primaryDocument constants) that tests compare. A line not yet committed is presumed 6cac8335. `col` is the
citation's column on its line, for triage.py --write.
"""
import difflib, re, subprocess, sys
from pathlib import Path

repo, old_dir, new_dir, pre, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], Path(sys.argv[5])
files = sys.argv[6:]

FILES = {
    "RUNTIME": "spec-module-runtime.md", "R": "spec-module-runtime.md",
    "INTERFACE": "spec-module-interface.md", "IF": "spec-module-interface.md",
    "TRANSPORT": "spec-module-transport.md", "T": "spec-module-transport.md",
    "CA": "spec-module-capability-authority.md", "AUTHORITY": "spec-module-capability-authority.md",
    "PM": "spec-module-package-manager.md", "MANAGER": "spec-module-package-manager.md",
    "LOADER": "spec-module-loader.md", "L": "spec-module-loader.md",
    "CONFIG": "spec-module-configuration.md", "CFG": "spec-module-configuration.md",
    "CONFIGURATION": "spec-module-configuration.md",
    "BCP": "spec-module-system-bcp.md", "BOOTSTRAP-COMPOSITION-PROFILES": "spec-module-system-bcp.md",
    "SECURITY": "spec-module-security-considerations.md", "SEC": "spec-module-security-considerations.md",
    "SECURITY-CONSIDERATIONS": "spec-module-security-considerations.md",
    "COMMITMENT": "spec-module-commitment-model.md", "CMT": "spec-module-commitment-model.md",
    "HASH": "spec-module-hash-profile.md", "HSH": "spec-module-hash-profile.md",
    "cdCDDLe": "spec-cdcddle.md", "CDE": "spec-cdcddle.md",
    "CS": "spec-module-credential-store.md",
}
SPEC_RE = r"(?<![\w-])(" + "|".join(sorted(map(re.escape, FILES), key=len, reverse=True)) + r")(?![\w-])"
# A spec name followed by an optional section and parenthesis, then l.N: the name attributes the citation.
NAMED = re.compile(SPEC_RE + r"(?:'s)?(?:\s+§[\w.]+(?:[–-][\w.]+)?)?(?:,)?\s*\(?\s*l\.(\d+)(?:[–-](\d+))?")
BARE = re.compile(r"(?<![\w.])l\.(\d+)(?:[–-](\d+))?")
SPEC_ONLY = re.compile(SPEC_RE)


def lines_of(d: Path, name: str):
    p = d / name
    return p.read_text(encoding="utf-8").splitlines() if p.exists() else None


maps = {}
for name in set(FILES.values()):
    o, n = lines_of(old_dir, name), lines_of(new_dir, name)
    m = {}
    if o is not None and n is not None:
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, o, n, autojunk=False).get_opcodes():
            if tag == "equal":
                for k in range(i2 - i1):
                    m[i1 + k + 1] = j1 + k + 1
    maps[name] = (o, n, m)

repin = set(subprocess.run(["git", "-C", str(repo), "rev-list", f"{pre}..HEAD"], capture_output=True, text=True, check=True).stdout.split())
repin.add("0" * 40)  # git blame's id for a line not committed yet


def blame(path: str):
    """The commit that last changed each line."""
    outp = subprocess.run(["git", "-C", str(repo), "blame", "--porcelain", path], capture_output=True, text=True, check=True).stdout
    shas, cur = [], None
    for ln in outp.splitlines():
        m = re.match(r"^([0-9a-f]{40}) \d+ (\d+)", ln)
        if m:
            cur = m.group(1)
        elif ln.startswith("\t"):
            shas.append(cur)
    return shas


def classify(spec_file, a, b, presumed):
    o, n, m = maps[spec_file]
    if n is None:
        return "unknown", ""
    if presumed == "new" or o is None:
        if b > len(n) or a < 1 or all(not n[k - 1].strip() for k in range(a, b + 1)):
            return "suspect", ""
        return "current", ""
    if b > len(o) or a < 1 or all(not o[k - 1].strip() for k in range(a, b + 1)):
        return "suspect", ""
    mapped = [m.get(k) for k in range(a, b + 1)]
    if any(x is None for x in mapped):
        return "changed", ""
    na, nb = mapped[0], mapped[-1]
    rng = f"l.{na}" if na == nb else f"l.{na}-{nb}"
    if nb - na != b - a:
        return "widened", rng
    return ("same" if (na, nb) == (a, b) else "shift"), rng


rows = []
for f in files:
    text = (repo / f).read_text(encoding="utf-8").splitlines()
    shas = blame(f)
    header_spec = {}
    current_header = None
    para_last = None
    fenced = False
    for i, line in enumerate(text):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        if not line.strip() or line.startswith("#"):
            para_last = None
        presumed = "new" if shas[i] in repin else "old"
        # Table context: a header cell naming a spec (DEPLOYMENT's "BCP" column), or a Spec column.
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if i + 1 < len(text) and re.match(r"^\|[\s:|-]+\|?$", text[i + 1]):
                current_header = cells
        else:
            current_header = None
        spec_here = None
        if current_header and line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if "Spec" in current_header and len(cells) == len(current_header):
                v = cells[current_header.index("Spec")]
                if v in FILES:
                    spec_here = v
            if "BCP" in current_header:
                spec_here = spec_here or "BCP"
        last = spec_here if line.startswith("|") else para_last
        pos = 0
        named_spans = {}
        for m in NAMED.finditer(line):
            named_spans[m.start(2) - 2] = m.group(1)
        for m in BARE.finditer(line):
            # the nearest spec name before this citation on the line wins
            before = [s for s in SPEC_ONLY.finditer(line[: m.start()])]
            spec = None
            for s in reversed(before):
                # a spec name counts if it is followed by a citation-like tail somewhere before this l.N
                spec = s.group(1)
                break
            if spec is None:
                spec = last
            a = int(m.group(1)); b = int(m.group(2) or m.group(1))
            if spec is None:
                rows.append((f, i + 1, "?", f"l.{a}" + (f"-{b}" if b != a else ""), presumed, "unknown", "", shas[i][:8], m.start()))
                continue
            status, rng = classify(FILES[spec], a, b, presumed)
            rows.append((f, i + 1, spec, f"l.{a}" + (f"-{b}" if b != a else ""), presumed, status, rng, shas[i][:8], m.start()))
        found = list(SPEC_ONLY.finditer(line))
        if line.startswith("|"):
            para_last = None
        elif found:
            para_last = found[-1].group(1)

with out.open("w", encoding="utf-8") as fh:
    fh.write("file\tline\tspec\tcited\tpresumed\tstatus\tmapped\tcommit\tcol\n")
    for r in rows:
        fh.write("\t".join(map(str, r)) + "\n")

from collections import Counter
by = Counter((r[0], r[5]) for r in rows)
for f in files:
    tot = sum(v for (ff, _), v in by.items() if ff == f)
    parts = ", ".join(f"{s} {by[(f, s)]}" for s in ("current", "same", "shift", "widened", "changed", "suspect", "unknown") if by[(f, s)])
    print(f"{f}: {tot} ({parts})")
print("all:", len(rows), dict(Counter(r[5] for r in rows)))
