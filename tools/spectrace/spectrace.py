#!/usr/bin/env python3
"""Requirement traceability for the Logos Core specs.

Extracts every normative unit of the twelve spec documents into a ledger with
stable IDs, keeps those IDs across spec revisions, mirrors the CDDL the code is
built from, checks pinned values, and gates test coverage per claimed section.

Each spec's files sit under the conformance tree of the package that owns them: `conformance/`
for core, `sdk/conformance/` for the SDK.

Ledger: <tree>/requirements/<PFX>.jsonl, one JSON object per unit:
  id, kind, section, heading, line, fingerprint, text[, rule][, lang][, retired]
kind is one of:
  kw       a sentence, list item or table row with an uppercase BCP 14 keyword
  lc       one with a lowercase must/shall/should; informative, so not gated
           (every spec: lowercase forms keep their ordinary meaning; G117, B1)
  cddl     one CDDL rule, keyed by rule name
  block    any other fenced block (vectors, C declarations, examples)
  heading  a section heading (used for section coverage)

spec/repin-pending.toml lists what stays deferred past the re-pin to 6cac8335: each unit with the work
item that owns it, and each text entry that rides on one. `pending` checks it, and checks that what left
the re-pin's frozen list (spec/repin-baseline.toml) has its evidence in spec/repin-text-cleared.toml.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from blake3 import blake3

SPECS = {
    "spec-module-transport.md": "TRN",
    "spec-module-interface.md": "IFC",
    "spec-module-runtime.md": "RUN",
    "spec-module-configuration.md": "CFG",
    "spec-module-loader.md": "LDR",
    "spec-module-package-manager.md": "PKG",
    "spec-module-capability-authority.md": "CAP",
    "spec-module-security-considerations.md": "SEC",
    "spec-module-system-bcp.md": "BCP",
    "spec-module-commitment-model.md": "CMT",
    "spec-module-hash-profile.md": "HSH",
    "spec-cdcddle.md": "CDE",
}
PREFIX_FILE = {v: k for k, v in SPECS.items()}

KW_RE = re.compile(
    r"\b(MUST NOT|MUST|REQUIRED|SHALL NOT|SHALL|SHOULD NOT|SHOULD|NOT RECOMMENDED|RECOMMENDED|MAY|OPTIONAL)\b"
)
LC_RE = re.compile(r"\b(must|shall|should)\b")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
FENCE_RE = re.compile(r"^```\s*([A-Za-z0-9_-]*)\s*$")
LIST_RE = re.compile(r"^(\s*)([-*+]|\d+\.)\s+(.*)$")
RULE_RE = re.compile(r"^([A-Za-z@_$][A-Za-z0-9@_$.-]*)\s*(=|/=|//=)")
SECNUM_RE = re.compile(r"^((?:\d+\.)*\d+)\.?\s")
APPENDIX_RE = re.compile(r"^Appendix\s+([A-Z](?:\.\d+)*)\.?\s")
SUBAPPENDIX_RE = re.compile(r"^([A-Z]\.\d+(?:\.\d+)*)\.?\s")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z`(\"])")


@dataclass
class Unit:
    kind: str
    section: str
    heading: str
    line: int
    text: str
    rule: str | None = None
    lang: str | None = None
    id: str | None = None
    fingerprint: str = ""
    retired: bool = False
    extra: dict = field(default_factory=dict)

    def finish(self) -> "Unit":
        norm = " ".join(self.text.split())
        self.fingerprint = blake3(f"{self.kind}\0{norm}".encode()).hexdigest()[:32]
        return self

    def to_json(self) -> dict:
        d = {
            "id": self.id,
            "kind": self.kind,
            "section": self.section,
            "heading": self.heading,
            "line": self.line,
            "fingerprint": self.fingerprint,
            "text": self.text,
        }
        if self.rule:
            d["rule"] = self.rule
        if self.lang:
            d["lang"] = self.lang
        if self.retired:
            d["retired"] = True
        return d

    @staticmethod
    def from_json(d: dict) -> "Unit":
        return Unit(
            kind=d["kind"],
            section=d["section"],
            heading=d["heading"],
            line=d["line"],
            text=d["text"],
            rule=d.get("rule"),
            lang=d.get("lang"),
            id=d["id"],
            fingerprint=d["fingerprint"],
            retired=d.get("retired", False),
        )


def section_key(heading: str) -> str | None:
    """§4.4 for numbered sections, App B.1 for appendices, None otherwise."""
    m = SECNUM_RE.match(heading)
    if m:
        return "§" + m.group(1)
    m = APPENDIX_RE.match(heading) or SUBAPPENDIX_RE.match(heading)
    if m:
        return "App " + m.group(1)
    return None


class Sections:
    """Section keys; an unnumbered subheading nests under its numbered parent."""

    def __init__(self) -> None:
        self.stack: list[tuple[int, str]] = []

    def enter(self, level: int, heading: str) -> str:
        while self.stack and self.stack[-1][0] >= level:
            self.stack.pop()
        key = section_key(heading)
        if key is None:
            parent = self.stack[-1] if self.stack and self.stack[-1][0] >= 2 else None
            key = f"{parent[1]}/{heading}" if parent else heading
        self.stack.append((level, key))
        return key


def within(section: str, key: str) -> bool:
    return section == key or section.startswith((key + ".", key + "/"))


def text_kind(text: str) -> str | None:
    if KW_RE.search(text):
        return "kw"
    if LC_RE.search(text):
        return "lc"
    return None


def extract(path: Path) -> list[Unit]:
    lines = path.read_text(encoding="utf-8").splitlines()
    units: list[Unit] = []
    heading, section = "", "front"
    sections = Sections()
    i = 0
    para: list[tuple[int, str]] = []
    lead_in: str | None = None

    def flush_para() -> None:
        nonlocal para, lead_in
        if not para:
            return
        start = para[0][0]
        text = " ".join(t.strip() for _, t in para)
        lead_in = text if text.rstrip().endswith(":") and text_kind(text) == "kw" else None
        for sentence in SENTENCE_SPLIT_RE.split(text):
            kind = text_kind(sentence)
            if kind:
                units.append(Unit(kind, section, heading, start, sentence.strip()).finish())
        para = []

    while i < len(lines):
        line = lines[i]
        m = HEADING_RE.match(line)
        if m:
            flush_para()
            lead_in = None
            heading = m.group(2)
            section = sections.enter(len(m.group(1)), heading)
            units.append(Unit("heading", section, heading, i + 1, heading).finish())
            i += 1
            continue
        m = FENCE_RE.match(line)
        if m:
            flush_para()
            lang = m.group(1) or None
            start = i + 1
            body: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1  # closing fence
            if lang == "cddl":
                units.extend(cddl_rules(body, start + 1, section, heading))
            else:
                units.append(
                    Unit("block", section, heading, start, "\n".join(body), lang=lang).finish()
                )
            continue
        if line.startswith("|"):
            flush_para()
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not all(re.fullmatch(r":?-+:?", c) for c in cells if c):
                text = " | ".join(cells)
                kind = text_kind(text)
                if kind:
                    units.append(Unit(kind, section, heading, i + 1, text).finish())
            i += 1
            continue
        m = LIST_RE.match(line)
        if m:
            flush_para()
            indent = len(m.group(1))
            start = i + 1
            item = [m.group(3)]
            i += 1
            while (
                i < len(lines)
                and lines[i].strip()
                and not LIST_RE.match(lines[i])
                and not HEADING_RE.match(lines[i])
                and not FENCE_RE.match(lines[i])
                and len(lines[i]) - len(lines[i].lstrip()) > indent
            ):
                item.append(lines[i].strip())
                i += 1
            text = " ".join(item)
            kind = text_kind(text)
            if kind is None and lead_in is not None:
                text = lead_in + " … " + text
                kind = "kw"
            if kind:
                units.append(Unit(kind, section, heading, start, text).finish())
            continue
        if not line.strip():
            flush_para()
            i += 1
            continue
        para.append((i + 1, line))
        i += 1
    flush_para()
    return units


def cddl_rules(body: list[str], first_line: int, section: str, heading: str) -> list[Unit]:
    out: list[Unit] = []
    current: list[str] = []
    name, start = None, first_line
    for offset, line in enumerate(body):
        m = RULE_RE.match(line)
        if m and not line.startswith((" ", "\t")):
            if name is not None:
                out.append(rule_unit(name, current, start, section, heading))
            name, start, current = m.group(1), first_line + offset, [line]
        elif name is not None:
            current.append(line)
    if name is not None:
        out.append(rule_unit(name, current, start, section, heading))
    return out


def rule_unit(name: str, text: list[str], line: int, section: str, heading: str) -> Unit:
    while text and not text[-1].strip():
        text.pop()
    return Unit("cddl", section, heading, line, "\n".join(text), rule=name).finish()


# The re-pin's pending list ---------------------------------------------------------

PENDING_FILE = Path("spec") / "repin-pending.toml"
CLEARED_FILE = Path("spec") / "repin-text-cleared.toml"
BASELINE_FILE = Path("spec") / "repin-baseline.toml"
BASELINE_SHA256 = "3a1e52f94e36f1406d097f1f67f3ff45a0b2693a8a3fe123cb89f579a8d71103"
TEXT_ID_RE = re.compile(r"TXT-\d{4}")
READING_KINDS = {"reword", "removed", "informative", "holds"}
WORK_ITEMS = {"5-3a", "5-5", "5-6a", "5-6b", "5-7a", "5-7b", "5-8", "5-10", "5-12"}  # the work items that may own a unit after the re-pin
SITE_ROOTS = ("src/", "sdk/src/", "tests/", "sdk/tests/", "docs/")
TEST_TEMPLATES = "test|ltTest|peerTest|sceneTest"
# Conditions a test may sit under and still run somewhere: platforms, and the one build switch the suites use.
LIVE_CONDITION = re.compile(r"defined\((?:posix|windows|linux|macosx|android|ios)\)|declared\(caParity\)")


# Ledger -------------------------------------------------------------------------


CONFORMANCE_TREES = (Path("conformance"), Path("sdk") / "conformance")  # core's and the SDK's


def ledger_path(root: Path, prefix: str) -> Path:
    """The spec's ledger, in the tree that holds it; a new ledger starts in core's."""
    for tree in CONFORMANCE_TREES:
        path = root / tree / "requirements" / f"{prefix}.jsonl"
        if path.exists():
            return path
    return root / CONFORMANCE_TREES[0] / "requirements" / f"{prefix}.jsonl"


def visible(paths) -> list[Path]:
    """Paths without a leading dot: AppleDouble `._` files on a non-Apple volume, an editor's swap files."""
    return [p for p in paths if not p.name.startswith(".")]


def ledger_files(root: Path) -> list[Path]:
    return [f for tree in CONFORMANCE_TREES for f in sorted(visible((root / tree / "requirements").glob("*.jsonl")))]


def inspection_files(root: Path) -> list[Path]:
    """Every inspection file of both packages, by name."""
    files = [f for tree in CONFORMANCE_TREES for f in visible((root / tree / "inspection").glob("*.toml"))]
    return sorted(files, key=lambda f: (f.name, str(f)))


def claims_of(root: Path, prefix: str) -> list[dict]:
    """The spec's claims, one per package that has a claims file."""
    paths = [root / tree / "claims" / f"{prefix}.toml" for tree in CONFORMANCE_TREES]
    return [tomllib.loads(p.read_text(encoding="utf-8")) for p in paths if p.exists()]


def load_ledger(path: Path) -> tuple[int, list[Unit]]:
    if not path.exists():
        return 1, []
    lines = path.read_text(encoding="utf-8").splitlines()
    meta = json.loads(lines[0])
    return meta["next"], [Unit.from_json(json.loads(l)) for l in lines[1:]]


def save_ledger(path: Path, spec: str, rev: str, next_id: int, units: list[Unit]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        f.write(json.dumps({"spec": spec, "rev": rev, "next": next_id}, ensure_ascii=False) + "\n")
        for u in units:
            f.write(json.dumps(u.to_json(), ensure_ascii=False) + "\n")


def assign(prefix: str, next_id: int, old: list[Unit], new: list[Unit]):
    """Gives each new unit the ID of the old unit it continues, else a fresh one.

    Returns (next_id, units, report) where units includes retired old units.
    """
    live_old = [u for u in old if not u.retired]
    by_fp: dict[tuple[str, str], list[Unit]] = {}
    for u in live_old:
        by_fp.setdefault((u.kind, u.fingerprint), []).append(u)
    used: set[str] = set()
    report = {"added": [], "changed": [], "retired": [], "moved": []}

    unmatched: list[Unit] = []
    for u in new:
        cands = by_fp.get((u.kind, u.fingerprint), [])
        cand = next((c for c in cands if c.id not in used), None)
        if cand:
            u.id = cand.id
            used.add(cand.id)
            if cand.section != u.section:
                report["moved"].append(u.id)
        else:
            unmatched.append(u)

    remaining = [u for u in live_old if u.id not in used]
    for u in unmatched:
        best, best_ratio = None, 0.0
        for c in remaining:
            if c.id in used or c.kind != u.kind or c.section != u.section:
                continue
            if u.kind == "cddl" and c.rule != u.rule:
                continue
            ratio = difflib.SequenceMatcher(None, c.text, u.text).ratio()
            if ratio > best_ratio:
                best, best_ratio = c, ratio
        if best is not None and (best_ratio >= 0.8 or u.kind == "cddl"):
            u.id = best.id
            used.add(best.id)
            report["changed"].append(u.id)
        else:
            u.id = f"{prefix}-{next_id:04d}"
            next_id += 1
            report["added"].append(u.id)

    retired = [u for u in old if u.retired or u.id not in used]
    for u in retired:
        if not u.retired:
            report["retired"].append(u.id)
        u.retired = True
    units = sorted(new + retired, key=lambda u: u.id)
    return next_id, units, report


def spec_rev(specs: Path) -> str:
    rev_file = specs / ".spec-rev"
    return rev_file.read_text().strip() if rev_file.exists() else "unknown"


def cmd_sync(args) -> int:
    root, specs = Path(args.root), Path(args.specs)
    rev = args.rev or spec_rev(specs)
    total = {"added": 0, "changed": 0, "retired": 0, "moved": 0}
    for fname, prefix in SPECS.items():
        path = ledger_path(root, prefix)
        next_id, old = load_ledger(path)
        new = extract(specs / fname)
        next_id, units, report = assign(prefix, next_id, old, new)
        save_ledger(path, fname, rev, next_id, units)
        for k, v in report.items():
            total[k] += len(v)
            if v and not args.quiet:
                print(f"{prefix} {k}: {', '.join(v)}")
    print(
        "ledger synced to %s: %d added, %d changed, %d retired, %d moved"
        % (rev, total["added"], total["changed"], total["retired"], total["moved"])
    )
    return 0


def cmd_check(args) -> int:
    """The ledger must describe exactly the pinned spec text."""
    root, specs = Path(args.root), Path(args.specs)
    bad = 0
    for fname, prefix in SPECS.items():
        next_id, old = load_ledger(ledger_path(root, prefix))
        new = extract(specs / fname)
        _, _, report = assign(prefix, next_id, [Unit.from_json(u.to_json()) for u in old], new)
        drift = report["added"] + report["changed"] + report["retired"]
        if drift:
            bad += 1
            print(f"{prefix}: ledger differs from {fname}: {len(report['added'])} added, "
                  f"{len(report['changed'])} changed, {len(report['retired'])} retired")
    if bad:
        print("run `spectrace sync` against the new spec revision and review the report")
        return 1
    print("ledger matches the pinned specs")
    return 0


# Mirrors ------------------------------------------------------------------------


def fenced_blocks(path: Path) -> list[tuple[str, str, str]]:
    """(section, lang, body) for every fenced block, in order."""
    out = []
    section, sections = "front", Sections()
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        m = HEADING_RE.match(lines[i])
        if m:
            section = sections.enter(len(m.group(1)), m.group(2))
        f = FENCE_RE.match(lines[i])
        if f:
            lang = f.group(1)
            body = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            out.append((section, lang, "\n".join(body) + "\n"))
        i += 1
    return out


def tables(path: Path) -> list[tuple[str, str, str]]:
    """(section, "table", body) for every Markdown table outside fences, in order."""
    out = []
    section, sections, fenced = "front", Sections(), False
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        if lines[i].startswith("```"):
            fenced = not fenced
        m = None if fenced else HEADING_RE.match(lines[i])
        if m:
            section = sections.enter(len(m.group(1)), m.group(2))
        if not fenced and lines[i].startswith("|"):
            body = []
            while i < len(lines) and lines[i].startswith("|"):
                body.append(lines[i])
                i += 1
            out.append((section, "table", "\n".join(body) + "\n"))
            continue
        i += 1
    return out


def load_toml(path: Path) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def cmd_mirror(args) -> int:
    root, specs = Path(args.root), Path(args.specs)
    cfg = load_toml(root / "spec" / "mirrors.toml")
    bad = 0
    for m in cfg.get("mirror", []):
        if m.get("package") not in PINS_NIM:
            print(f"{m['out']}: `package` must be one of {sorted(PINS_NIM)}")
            bad += 1
        lang = m.get("lang", "cddl")
        source = tables if lang == "table" else fenced_blocks
        blocks = [
            body
            for section, kind, body in source(specs / m["file"])
            if section == m["section"] and kind == lang
        ]
        ordinal = m.get("ordinal", 1)
        out = root / "spec" / "mirrors" / m["out"]
        if not blocks or ordinal > len(blocks):
            print(f"{m['out']}: {m['file']} {m['section']} has no block #{ordinal}")
            bad += 1
            continue
        want = "\n".join(blocks) if ordinal == 0 else blocks[ordinal - 1]
        if args.write:
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(want, encoding="utf-8")
        elif not out.exists() or out.read_text(encoding="utf-8") != want:
            print(f"{m['out']}: differs from {m['file']} {m['section']} block #{ordinal}")
            if out.exists():
                sys.stdout.writelines(
                    difflib.unified_diff(
                        out.read_text(encoding="utf-8").splitlines(True),
                        want.splitlines(True),
                        "mirror",
                        "spec",
                    )
                )
            bad += 1
    if bad:
        print("run `spectrace mirror --write`, review the diff, and re-derive spec/pins.toml")
        return 1
    print("%s %d mirrors" % ("wrote" if args.write else "checked", len(cfg.get("mirror", []))))
    return 0


def section_text(path: Path, section: str) -> str:
    out, current, sections, fenced = [], "front", Sections(), False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("```"):
            fenced = not fenced
        m = None if fenced else HEADING_RE.match(line)
        if m:
            current = sections.enter(len(m.group(1)), m.group(2))
        if within(current, section):
            out.append(line)
    return "\n".join(out)


PINS_NIM = {
    "sdk": Path("sdk/src/logos_sdk/pins.nim"),
    "core": Path("src/logos_core/pins.nim"),
}


def pins_nim(pins: dict, root: Path, package: str) -> str:
    """The Nim module of `package` holding its pins that carry a `code` name. A pin
    with a `mirror` is that mirror's whole text (a pinned document)."""
    out = [
        "## Generated by `spectrace pins --write` from spec/pins.toml. Do not edit: the",
        "## values are the spec's pinned identifiers and documents that code uses.",
        "",
        "#!fmt: off",
        "const",
    ]
    if package == "sdk":
        # The revision every ledger was synced to: generated headers carry it.
        revs = {json.loads(f.read_text(encoding="utf-8").split("\n", 1)[0])["rev"]
                for f in ledger_files(root)}
        if len(revs) != 1:
            raise SystemExit(f"the ledgers name {len(revs)} spec revisions; run `spectrace sync`")
        out.append("  # conformance/requirements/*.jsonl: the spec revision")
        out.append(f'  SpecRevision* = "{revs.pop()}"')
    for p in pins.values():
        if "code" in p and p.get("package") != package:
            continue
        if "code" in p and "mirror" in p:
            text = (root / "spec" / "mirrors" / p["mirror"]).read_text(encoding="utf-8")
            if '"""' in text:
                raise SystemExit(f"{p['mirror']} cannot be a Nim triple-quoted string")
            out.append(f"  # {p['file']} {p['section']}, spec/mirrors/{p['mirror']}")
            out.append(f'  {p["code"]}* = """')
            out.extend(text.rstrip("\n").split("\n"))
            out[-1] += '\n"""'
        elif "code" in p:
            out.append(f"  # {p['file']} {p['section']}")
            out.append(f"  {p['code']}* = \"{p['value']}\"")
    common = [p for p in pins.values() if p.get("registry") == "common"]
    if common and package == "sdk":
        out.append(f"  # {common[0]['file']} {common[0]['section']}: (definition, kind, subtree root)")
        out.append("  CommonRegistry* = [")
        for p in common:
            out.append("    (")
            out.append(f"      \"{p['definition']}\", \"{p['declaration']}\",")
            out.append(f"      \"{p['value']}\",")
            out.append("    ),")
        out.append("  ]")
    return "\n".join(out) + "\n"


def cmd_pins(args) -> int:
    """Every pinned value must still appear in the section it is pinned from, every
    pin with a `code` name must say which package consumes it, and both packages'
    pins.nim must be generated from the current pins."""
    root, specs = Path(args.root), Path(args.specs)
    pins = load_toml(root / "spec" / "pins.toml")
    bad = 0
    for name, p in pins.items():
        if "code" in p and p.get("package") not in PINS_NIM:
            print(f"pin {name}: `package` must be one of {sorted(PINS_NIM)}")
            bad += 1
    mirrored = {m["out"] for m in load_toml(root / "spec" / "mirrors.toml").get("mirror", [])}
    for name, p in pins.items():
        if "mirror" in p:
            # A pinned document: `spectrace mirror` checks its text against the spec.
            if p["mirror"] not in mirrored:
                print(f"pin {name}: {p['mirror']} is not a checked mirror")
                bad += 1
            continue
        text = section_text(specs / p["file"], p["section"])
        value = p["value"]
        found = f"`{value}`" in text if p.get("kind") == "length" else value in text
        if "registry" in p:
            # A registry row: definition, kind and root on one table row.
            found = f"| `{p['definition']}` | {p['declaration']} | `{value}` |" in text
        if not found:
            print(f"pin {name}: {value} not found in {p['file']} {p['section']}")
            bad += 1
    for package, path in PINS_NIM.items():
        generated = pins_nim(pins, root, package)
        target = root / path
        if args.write:
            target.write_text(generated, encoding="utf-8")
        elif not target.exists() or target.read_text(encoding="utf-8") != generated:
            print(f"{path} is stale: run `spectrace pins --write`")
            bad += 1
    if bad:
        return 1
    print(f"checked {len(pins)} pins and {', '.join(str(p) for p in PINS_NIM.values())}")
    return 0


# Coverage gate -------------------------------------------------------------------

TEST_ID_RE = re.compile(r"\[([A-Z]{3}-\d{4})\]")
TEST_TREES = ("tests", "sdk/tests")  # core's suites and the SDK's
# `lc` units stay in the ledger, so tests may still cite them, but no claim
# needs them covered: lowercase forms keep their ordinary meaning (G117, B1).
GATED_KINDS = {"kw", "cddl", "block"}
# Each package: its name, its conformance tree and its test tree, in CONFORMANCE_TREES' order.
PACKAGES = (("core", CONFORMANCE_TREES[0], TEST_TREES[0]), ("sdk", CONFORMANCE_TREES[1], TEST_TREES[1]))


STATUS_RE = re.compile(r"claimed|deferred:tier-(?:[1-5]|4b)|informative|out-of-scope:.+")


def package_claims(root: Path, prefix: str) -> list[tuple[str, dict]]:
    """(package, claims) for each package with a claims file for the spec."""
    out = []
    for package, tree, _ in PACKAGES:
        path = root / tree / "claims" / f"{prefix}.toml"
        if path.exists():
            out.append((package, tomllib.loads(path.read_text(encoding="utf-8"))))
    return out


def owner_of(pclaims: list[tuple[str, dict]], unit) -> str | None:
    """The package that claims the unit; the owner lint makes it at most one."""
    return next((package for package, claims in pclaims if unit_status(claims, unit) == "claimed"), None)


def package_evidence(root: Path) -> tuple[dict[str, set[str]], dict[str, dict[str, str]]]:
    """Per package, the units its own tests cite or its own inspection files cover (restructure-in-place
    §3.8: evidence must be the owner's, from R9); and per unit, the package and file of each inspection."""
    evidence: dict[str, set[str]] = {package: set() for package, _, _ in PACKAGES}
    inspected: dict[str, dict[str, str]] = {}
    for package, tree, tests in PACKAGES:
        for test in visible((root / tests).rglob("*.nim")):
            evidence[package].update(TEST_ID_RE.findall(test.read_text(encoding="utf-8")))
        for extra in sorted(visible((root / tree / "inspection").glob("*.toml"))):
            for item in load_toml(extra).get("item", []):
                evidence[package].update(item.get("ids", []))
                for i in item.get("ids", []):
                    inspected.setdefault(i, {}).setdefault(package, f"{tree}/inspection/{extra.name}")
    return evidence, inspected


def section_status(claims: dict, section: str) -> str:
    """Longest matching section key wins; falls back to `default`."""
    best, status = -1, claims.get("default", "unclaimed")
    for key, value in claims.get("sections", {}).items():
        if within(section, key) and len(key) > best:
            best, status = len(key), value
    return status


def unit_status(claims: dict, unit) -> str:
    """A `[units]` entry for the unit's id overrides its section's status."""
    return claims.get("units", {}).get(unit.id) or section_status(claims, unit.section)


def status_across(claim_sets: list[dict], unit) -> str:
    """The unit's status over the packages' claims: `claimed` if one of them claims it."""
    found = [unit_status(claims, unit) for claims in claim_sets]
    return "claimed" if "claimed" in found else found[0]


def statuses(claims: dict):
    """(key, status) for the default, each section and each unit entry."""
    yield "default", claims.get("default", "")
    for key, value in claims.get("sections", {}).items():
        yield key, value
    for key, value in claims.get("units", {}).items():
        yield key, value


def cmd_gate(args) -> int:
    """Every live unit a package claims is referenced by a test or an inspection item in that
    package's own tree (evidence must be the owner's, from R9); an inspected unit is claimed by the
    package whose file inspects it; no status defers to a closed tier."""
    root = Path(args.root)
    evidence, inspected = package_evidence(root)
    referenced = set().union(*evidence.values())
    failures = 0
    for extra in inspection_files(root):
        for item in load_toml(extra).get("item", []):
            if not str(item.get("reason", "")).strip():
                print(f"{extra.name}: inspection item {item.get('ids')} has no reason")
                failures += 1
    # Both packages' ledgers follow one spec revision: `SpecRevision` is derived from them.
    revs = {json.loads(f.read_text(encoding="utf-8").split("\n", 1)[0])["rev"] for f in ledger_files(root)}
    if len(revs) > 1:
        print(f"the ledgers name {len(revs)} spec revisions: {sorted(revs)}")
        failures += 1
    closed = {f"deferred:tier-{t}" for t in args.closed_tier}
    live_ids: set[str] = set()
    for fname, prefix in SPECS.items():
        pclaims = package_claims(root, prefix)
        claim_sets = [claims for _, claims in pclaims]
        bad_status = [
            s
            for claims in claim_sets
            for s in [claims.get("default", "")]
            + list(claims.get("sections", {}).values())
            + list(claims.get("units", {}).values())
            if not STATUS_RE.fullmatch(s)
        ]
        if not claim_sets or not all(claim_sets) or bad_status:
            print(f"{prefix}: missing claims file or invalid status {bad_status}")
            failures += 1
            claim_sets = claim_sets or [{}]
        # [W1] A closed tier has nothing deferred to it.
        for claims in claim_sets:
            for key, value in statuses(claims):
                if value in closed:
                    print(f"{prefix}: {key} is {value}, a closed tier")
                    failures += 1
        _, units = load_ledger(ledger_path(root, prefix))
        if not units:
            print(f"{prefix}: empty ledger; run `spectrace sync`")
            failures += 1
        live = [u for u in units if not u.retired and u.kind in GATED_KINDS]
        live_ids.update(u.id for u in units if not u.retired)
        gated_ids = {u.id for u in live}
        named = {uid for claims in claim_sets for uid in claims.get("units", {})}
        for uid in sorted(named - gated_ids):
            print(f"{prefix}: [units] names {uid}, which is not a live gated requirement")
            failures += 1
        by_status: dict[str, int] = {}
        by_label: dict[str, int] = {}
        for u in live:
            full = status_across(claim_sets, u)
            st = full.split(":")[0]
            by_status[st] = by_status.get(st, 0) + 1
            if st == "deferred":
                by_label[full] = by_label.get(full, 0) + 1
            # [W1] Inspection stands for a test, so it covers claimed units only, and only in the
            # inspecting package's own tree.
            owner = owner_of(pclaims, u)
            for package, where in sorted(inspected.get(u.id, {}).items()):
                if owner != package:
                    claimed_by = f"claimed by {owner}" if owner else f"not claimed ({full})"
                    print(f"{prefix}: {u.id} is inspected ({where}) but {claimed_by}")
                    failures += 1
        owned = [(u, owner_of(pclaims, u)) for u in live]
        claimed = [(u, owner) for u, owner in owned if owner]
        missing = [(u, owner) for u, owner in claimed if u.id not in evidence[owner]]
        summary = ", ".join(f"{v} {k}" for k, v in sorted(by_status.items()))
        print(f"{prefix}: {len(claimed) - len(missing)}/{len(claimed)} claimed units tested ({summary})")
        if len(pclaims) > 1:
            print("  " + ", ".join(f"{package} {sum(o == package for _, o in claimed)}" for package, _ in pclaims))
        if by_label:
            print("  " + ", ".join(f"{k} {v}" for k, v in sorted(by_label.items())))
        for u, owner in missing[: args.show]:
            elsewhere = [p for p, _, _ in PACKAGES if p != owner and u.id in evidence[p]]
            note = f"; evidence only in {', '.join(elsewhere)}'s tree" if elsewhere else ""
            print(f"  untested {u.id} ({u.section} l.{u.line}, claimed by {owner}{note}): {u.text[:100]!r}")
        failures += len(missing)
    stale = sorted(i for i in referenced if i[:3] in PREFIX_FILE and i not in live_ids)
    for i in stale:
        print(f"a test references unknown or retired requirement {i}")
    return 1 if failures or stale else 0


# One owner per unit ------------------------------------------------------------------


def owner_findings(root: Path) -> list[str]:
    """A ledger lives in one package, and each live gated unit of a spec with two claims files
    is claimed by at most one of them; a unit neither claims has the same status in both. From R9,
    a claimed unit's evidence is its owner's: no unit is evidenced only by another package's tests,
    and no package's inspection file covers a unit another package claims (`gate` then counts the
    owner's tree alone)."""
    findings = []
    evidence, inspected = package_evidence(root)
    for prefix in SPECS.values():
        homes = [t for t in CONFORMANCE_TREES if (root / t / "requirements" / f"{prefix}.jsonl").exists()]
        if len(homes) > 1:
            findings.append(f"{prefix}: a ledger in both {homes[0]} and {homes[1]}")
        pclaims = package_claims(root, prefix)
        _, units = load_ledger(ledger_path(root, prefix))
        for u in units:
            if u.retired or u.kind not in GATED_KINDS:
                continue
            found = [unit_status(claims, u) for _, claims in pclaims]
            if len(pclaims) > 1 and found.count("claimed") > 1:
                findings.append(f"{u.id}: claimed by both packages")
                continue
            if len(pclaims) > 1 and "claimed" not in found and len(set(found)) > 1:
                findings.append(f"{u.id}: claimed by neither, with different statuses {found}")
            owner = owner_of(pclaims, u)
            if owner is None:
                continue
            others = [p for p, _, _ in PACKAGES if p != owner and u.id in evidence[p]]
            if u.id not in evidence[owner] and others:
                findings.append(f"{u.id}: claimed by {owner}, evidence only in {', '.join(others)}'s tree")
            for package, where in sorted(inspected.get(u.id, {}).items()):
                if package != owner:
                    findings.append(f"{u.id}: claimed by {owner}, inspected in {where}")
    return findings


def owners_self_test() -> int:
    """The lint passes a clean split and catches each planted violation."""
    import tempfile

    def tree(
        core: str, sdk: str, both_ledgers: bool = False, tested: tuple[str, ...] = (), inspected_in: str = ""
    ) -> list[str]:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            unit = Unit("kw", "1", "One", 1, "A MUST.", id="CDE-0001").finish()
            save_ledger(ledger_path(root, "CDE"), "x.md", "r", 2, [unit])
            if both_ledgers:
                save_ledger(root / CONFORMANCE_TREES[1] / "requirements" / "CDE.jsonl", "x.md", "r", 2, [unit])
            for t, status in zip(CONFORMANCE_TREES, (core, sdk)):
                (root / t / "claims").mkdir(parents=True, exist_ok=True)
                (root / t / "claims" / "CDE.toml").write_text(f'default = "{status}"\n', encoding="utf-8")
            for package, conformance, tests in PACKAGES:
                if package in tested:
                    (root / tests).mkdir(parents=True, exist_ok=True)
                    (root / tests / "test_one.nim").write_text('test "[CDE-0001] one": discard\n', encoding="utf-8")
                if package == inspected_in:
                    (root / conformance / "inspection").mkdir(parents=True, exist_ok=True)
                    (root / conformance / "inspection" / "CDE.toml").write_text(
                        '[[item]]\nids = ["CDE-0001"]\nreason = "read in the code"\n', encoding="utf-8"
                    )
            return owner_findings(root)

    out = "out-of-scope:other"
    cases = [
        ("one package claims it", tree("claimed", out), False),
        ("neither claims it, alike", tree(out, out), False),
        ("both claim it", tree("claimed", "claimed"), True),
        ("neither claims it, differently", tree(out, "informative"), True),
        ("a ledger in both packages", tree("claimed", out, both_ledgers=True), True),
        ("the owner's tree tests it", tree("claimed", out, tested=("core",)), False),
        ("both trees test it", tree(out, "claimed", tested=("core", "sdk")), False),
        ("only the other package's tree tests it", tree("claimed", out, tested=("sdk",)), True),
        ("the owner's file inspects it", tree(out, "claimed", inspected_in="sdk"), False),
        ("the other package's file inspects it", tree(out, "claimed", tested=("sdk",), inspected_in="core"), True),
    ]
    failed = [name for name, found, planted in cases if bool(found) != planted]
    for name in failed:
        print(f"owners self-test: {name} went wrong")
    if not failed:
        print(f"owners self-test: {len(cases)} cases, {sum(c[2] for c in cases)} planted violations caught")
    return 1 if failed else 0


def cmd_owners(args) -> int:
    """Each spec unit has one owning package (the restructure's row 35)."""
    if args.self_test:
        return owners_self_test()
    findings = owner_findings(Path(args.root))
    for f in findings:
        print(f)
    print(f"owners: {len(findings)} findings")
    return 1 if findings else 0


# The BCP §5.4 deployment document (DECISIONS G309, I97) ------------------------------

DEPLOY_DOC = Path("docs") / "DEPLOYMENT.md"
DEPLOY_ITEM_HEADER = ["Item", "BCP", "Part", "Verdict", "Changes in", "Answer", "Section", "Units"]
DEPLOY_DUTY_HEADER = ["Spec", "Line", "Duty", "Answer", "Units"]
DEPLOY_VERDICTS = {"Supported", "None", "Not supported"}
DEPLOY_SPECS = {"R": "RUN", "T": "TRN", "CA": "CAP", "IF": "IFC", "CFG": "CFG", "PM": "PKG", "L": "LDR"}
DEPLOY_LINE_RE = re.compile(r"l\.\d+(?:-\d+)?")
DEPLOY_UNIT_RE = re.compile(r"\b[A-Z]{3}-\d{4}\b")
DEPLOY_TIER_RE = re.compile(r"Tier (?:[1-5]|4b)")
DEPLOY_ANCHOR_RE = re.compile(r"\]\(#([^)]+)\)")
DEPLOY_FACTS_FENCE = "```json deployment-facts"


def md_cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def md_table(lines: list[str], header: list[str]) -> list[tuple[int, list[str]]] | None:
    """The rows (1-based line, cells) of the table whose header is exactly `header`."""
    for i, line in enumerate(lines):
        if line.startswith("|") and md_cells(line) == header:
            rows = []
            j = i + 2  # past the delimiter row
            while j < len(lines) and lines[j].startswith("|"):
                rows.append((j + 1, md_cells(lines[j])))
                j += 1
            return rows
    return None


def gh_anchor(heading: str) -> str:
    """GitHub's anchor for a heading: lowercase, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"[`*_\[\]]", "", heading).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def cmd_deploydoc(args) -> int:
    """G309 on docs/DEPLOYMENT.md: every gated BCP §5.4 unit is answered by an item row, each row's
    units are claimed with evidence, a None or Not supported row's units name its tier in their
    inspection reason, the duty table's units are claimed and its rows are named under BCP-0038,
    every in-page link resolves, and the facts block parses."""
    root = Path(args.root)
    doc_path = root / DEPLOY_DOC
    failures: list[str] = []
    if not doc_path.exists():
        print(f"{DEPLOY_DOC}: missing")
        return 1
    lines = doc_path.read_text(encoding="utf-8").splitlines()

    evidence, _ = package_evidence(root)
    reasons: dict[str, list[str]] = {}
    for extra in inspection_files(root):
        for item in load_toml(extra).get("item", []):
            for i in item.get("ids", []):
                reasons.setdefault(i, []).append(str(item.get("reason", "")))

    claims_cache: dict[str, tuple[list[tuple[str, dict]], dict[str, Unit]]] = {}

    def lookup(uid: str) -> tuple[str | None, Unit | None, str | None]:
        prefix = uid[:3]
        if prefix not in PREFIX_FILE:
            return None, None, None
        if prefix not in claims_cache:
            pclaims = package_claims(root, prefix)
            _, units = load_ledger(ledger_path(root, prefix))
            claims_cache[prefix] = (pclaims, {u.id: u for u in units if not u.retired})
        pclaims, units = claims_cache[prefix]
        unit = units.get(uid)
        if not unit or not pclaims:
            return None, unit, None
        return status_across([c for _, c in pclaims], unit), unit, owner_of(pclaims, unit)

    def check_claimed(where: str, uid: str) -> None:
        status, unit, owner = lookup(uid)
        if unit is None or unit.kind not in GATED_KINDS:
            failures.append(f"{where}: {uid} is not a live gated requirement")
        elif status != "claimed":
            failures.append(f"{where}: {uid} is {status}, not claimed")
        elif uid not in evidence[owner]:
            failures.append(f"{where}: {uid} is claimed by {owner} with no tagged test and no inspection item in its tree")

    anchors: set[str] = set()
    for line in lines:
        m = HEADING_RE.match(line)
        if m:
            anchors.add(gh_anchor(m.group(2)))
    for n, line in enumerate(lines, 1):
        for a in DEPLOY_ANCHOR_RE.findall(line):
            if a not in anchors:
                failures.append(f"l.{n}: the link #{a} names no heading")

    _, bcp_units = load_ledger(ledger_path(root, "BCP"))
    gated = {
        u.id
        for u in bcp_units
        if not u.retired and u.kind in GATED_KINDS and within(u.section, "§5.4")
    }

    items = md_table(lines, DEPLOY_ITEM_HEADER)
    if items is None:
        failures.append("the item table (header " + " | ".join(DEPLOY_ITEM_HEADER) + ") is missing")
        items = []
    answered: set[str] = set()
    for n, cells in items:
        where = f"l.{n} item {cells[0] if cells else '?'}"
        if len(cells) != len(DEPLOY_ITEM_HEADER):
            failures.append(f"{where}: {len(cells)} cells, not {len(DEPLOY_ITEM_HEADER)}")
            continue
        row = dict(zip(DEPLOY_ITEM_HEADER, cells))
        verdict, tier = row["Verdict"], row["Changes in"]
        if verdict not in DEPLOY_VERDICTS:
            failures.append(f"{where}: Verdict {verdict!r} is not one of {sorted(DEPLOY_VERDICTS)}")
        if verdict == "Supported" and tier != "—":
            failures.append(f"{where}: a Supported row has Changes in {tier!r}, not —")
        if tier != "—" and not DEPLOY_TIER_RE.fullmatch(tier):
            failures.append(f"{where}: Changes in {tier!r} is neither — nor a tier")
        if not row["Answer"]:
            failures.append(f"{where}: no Answer")
        if not DEPLOY_ANCHOR_RE.search(row["Section"]):
            failures.append(f"{where}: the Section cell links no section")
        ids = DEPLOY_UNIT_RE.findall(row["Units"])
        if not ids:
            failures.append(f"{where}: no units")
        for uid in ids:
            if uid not in gated:
                failures.append(f"{where}: {uid} is not a gated unit of BCP §5.4")
                continue
            answered.add(uid)
            check_claimed(where, uid)
            if verdict != "Supported":
                rs = reasons.get(uid, [])
                if not rs:
                    failures.append(f"{where}: {uid} answers {verdict} with no inspection item")
                elif tier != "—" and not any(tier in r for r in rs):
                    failures.append(f"{where}: no inspection reason of {uid} names {tier}")
    for uid in sorted(gated - answered):
        failures.append(f"{uid} (BCP §5.4) is in no row of the item table")

    duties = md_table(lines, DEPLOY_DUTY_HEADER)
    if duties is None:
        failures.append("the duty table (header " + " | ".join(DEPLOY_DUTY_HEADER) + ") is missing")
        duties = []
    doc_reasons = reasons.get("BCP-0038", [])
    for n, cells in duties:
        where = f"l.{n} duty"
        if len(cells) != len(DEPLOY_DUTY_HEADER):
            failures.append(f"{where}: {len(cells)} cells, not {len(DEPLOY_DUTY_HEADER)}")
            continue
        row = dict(zip(DEPLOY_DUTY_HEADER, cells))
        spec, line_m = row["Spec"], DEPLOY_LINE_RE.search(row["Line"])
        if spec not in DEPLOY_SPECS:
            failures.append(f"{where}: Spec {spec!r} is not one of {sorted(DEPLOY_SPECS)}")
            continue
        if line_m is None:
            failures.append(f"{where}: Line {row['Line']!r} names no line")
            continue
        cite = f"{spec} {line_m.group(0)}"
        where = f"l.{n} duty {cite}"
        if not row["Answer"]:
            failures.append(f"{where}: no Answer")
        ids = DEPLOY_UNIT_RE.findall(row["Units"])
        if not ids:
            failures.append(f"{where}: no units")
        for uid in ids:
            if uid[:3] != DEPLOY_SPECS[spec]:
                failures.append(f"{where}: {uid} is not a unit of {spec}")
            check_claimed(where, uid)
        if not any(names_cite(r, cite) for r in doc_reasons):
            failures.append(f"{where}: no inspection item of BCP-0038 names {cite}")

    fence = [i for i, line in enumerate(lines) if line.strip() == DEPLOY_FACTS_FENCE]
    if len(fence) != 1:
        failures.append(f"{len(fence)} facts blocks ({DEPLOY_FACTS_FENCE}), not one")
    else:
        body: list[str] = []
        for line in lines[fence[0] + 1 :]:
            if line.startswith("```"):
                break
            body.append(line)
        try:
            if not isinstance(json.loads("\n".join(body)), dict):
                failures.append("the facts block is not a JSON object")
        except json.JSONDecodeError as e:
            failures.append(f"the facts block is not JSON: {e}")

    for f in failures:
        print(f)
    print(
        f"{DEPLOY_DOC}: {len(items)} item rows, {len(duties)} duty rows, "
        f"{len(answered)}/{len(gated)} BCP §5.4 units answered, {len(failures)} failures"
    )
    return 1 if failures else 0


def names_cite(reason: str, cite: str) -> bool:
    """[re-pin P9] Whether `reason` names the duty row's citation whole: "BCP l.36" is not named by
    "BCP l.360" or by the range "BCP l.36-40"."""
    return re.search(rf"(?<!\w){re.escape(cite)}(?![\d-])", reason) is not None


# The pending list's own rules --------------------------------------------------------


def code_lines(lines: list[str]) -> list[bool]:
    """Whether each line of a Nim file starts as code: not inside a long string or a block comment."""
    out, long_string, depth = [], False, 0
    for line in lines:
        out.append(not long_string and depth == 0)
        i = 0
        while i < len(line):
            if long_string:
                if line.startswith('"""', i):
                    long_string, i = False, i + 3
                else:
                    i += 1
            elif depth:
                if line.startswith("]#", i):
                    depth, i = depth - 1, i + 2
                elif line.startswith("#[", i):
                    depth, i = depth + 1, i + 2
                else:
                    i += 1
            elif line.startswith('"""', i):
                long_string, i = True, i + 3
            elif line.startswith(("#[", "##["), i):
                depth, i = 1, i + (3 if line[i + 1] == "#" else 2)
            elif line[i] == "#":
                break
            elif line.startswith("'\"'", i):
                i += 3
            elif line[i] == '"':
                i += 1
                while i < len(line) and line[i] != '"':
                    i += 2 if line[i] == "\\" else 1
                i += 1
            else:
                i += 1
    return out


def real_tests(root: Path):
    """(suite path, test name) of each test that can run: in a suite file, not under `when false:`, and with a
    body that does more than `skip()` or `discard`. Re-pin evidence counts only these."""
    name_re = re.compile(rf'^(\s*)(?:{TEST_TEMPLATES})\s+"([^"]*)"')

    def live(condition: str) -> bool:
        """A `when` on platforms only. Any other `when`, `if`, `elif` or `else` above a test may never run."""
        m = re.fullmatch(r"when\s+(.*):", condition)
        return m is not None and re.fullmatch(r"(?:T|and|or|not|[()\s])*", LIVE_CONDITION.sub("T", m.group(1))) is not None

    for tree in ("tests", "sdk/tests"):
        paths = sorted(visible((root / tree).glob("*.nim"))) if (root / tree).is_dir() else []
        suites = [p for p in paths if p.name.startswith("test_")]
        for path in paths:
            if path not in suites and not (
                path.name.endswith("_body.nim")
                and any(re.search(rf"^\s*include\s+.*\b{path.stem}\b", q.read_text(encoding="utf-8"), re.M) for q in suites)
            ):
                continue  # helpers, and bodies no suite includes
            lines = path.read_text(encoding="utf-8").splitlines()
            code = code_lines(lines)
            for i, line in enumerate(lines):
                m = name_re.match(line)
                if not m or not code[i]:
                    continue
                indent, outer, dead = len(m.group(1)), len(m.group(1)), False
                for before in reversed(lines[:i]):
                    width = len(before) - len(before.lstrip())
                    if before.strip() and width < outer:
                        outer = width
                        above = before.strip()
                        if re.match(r"(?:when|if|elif|else)\b", above) and not live(above):
                            dead = True
                body = []
                for after in lines[i + 1 :]:
                    if after.strip() and len(after) - len(after.lstrip()) <= indent:
                        break
                    if after.strip() and not after.strip().startswith("#"):
                        body.append(after.strip())
                if not dead and body and body[0] not in ("skip()", "skip") and not all(b == "discard" for b in body):
                    yield path.relative_to(root).as_posix(), m.group(2)


def text_tags(root: Path) -> dict[str, set[str]]:
    """Each [TXT-nnnn] tag named by a test that can run, with the suites that name it."""
    found: dict[str, set[str]] = {}
    for suite, name in real_tests(root):
        for tag in TEXT_ID_RE.findall(name):
            found.setdefault(tag, set()).add(suite)
    return found


def unit_evidence(root: Path) -> set[str]:
    """Units named by a test that can run, or by an inspection item with a real reason."""
    found = {uid for _, name in real_tests(root) for uid in TEST_ID_RE.findall(name)}
    for extra in inspection_files(root):
        for item in load_toml(extra).get("item", []):
            if len(str(item.get("reason", "")).strip()) >= 20:
                found.update(item.get("ids", []))
    return found


def claim_state(root: Path, uid: str) -> tuple[str, bool]:
    """The unit's status, and whether a claims file names the unit itself rather than its section."""
    claim_sets = claims_of(root, uid[:3])
    unit = next((u for u in load_ledger(ledger_path(root, uid[:3]))[1] if u.id == uid), None)
    if unit is None:
        return "unknown", False
    return status_across(claim_sets, unit), any(uid in c.get("units", {}) for c in claim_sets)


def decision_rows(root: Path) -> dict[str, str]:
    """Each decision's text by id: a `### G12` section up to the next heading, or a `| I12 |` table row."""
    path = root / "docs" / "DECISIONS.md"
    rows: dict[str, str] = {}
    current = None
    for line in path.read_text(encoding="utf-8").splitlines() if path.is_file() else []:
        heading = re.match(r"#{1,6}\s+([DGI]\d+)\b", line)
        table = re.match(r"\|\s*([DGIR]\d+)\s*\|", line)
        if heading:
            current = heading.group(1)
            rows[current] = line
        elif line.startswith("#"):
            current = None
        elif table:
            rows[table.group(1)] = rows.get(table.group(1), "") + line
        elif current:
            rows[current] += "\n" + line
    return rows


def spec_title(prefix: str) -> str:
    """The name one spec uses for another, such as `LOGOS-MODULE-RUNTIME` for RUN."""
    return "LOGOS-" + PREFIX_FILE.get(prefix, "").removeprefix("spec-").removesuffix(".md").upper()


def rides_within(entry: dict, unit: str, unit_section: str | None) -> bool:
    """[re-pin P6 Q5] Whether a deferred text entry may ride on `unit`: a unit of its own spec and
    section, or a unit of another spec when the entry's own sentence (`what`) names that spec and a
    section the unit belongs to, such as "LOGOS-MODULE-RUNTIME Section 9" for a unit of §9.3.1."""
    spec, prefix = str(entry.get("spec", "")), unit.split("-")[0]
    if prefix == spec:
        return unit_section == entry.get("section")
    if prefix not in PREFIX_FILE or not unit_section:
        return False
    named = re.finditer(re.escape(spec_title(prefix)) + r" Section (\d+(?:\.\d+)*)", str(entry.get("what", "")))
    return any(unit_section == f"§{m.group(1)}" or unit_section.startswith(f"§{m.group(1)}.") for m in named)


LINE_PART_RE = re.compile(r"(\d+)(?:-(\d+))?")


def derived_section(entry: dict, units: list[Unit]) -> str | None:
    """[re-pin P8b Q1] The section of a text entry: its `section`, else, for a new-side entry, the
    section of the last unit of its spec's ledger (`units`) at or before each of its lines, when
    every line gives the same one. A `line` part that is not a line or a range, such as "none",
    gives none, and so does an old-side entry."""
    if entry.get("section"):
        return str(entry["section"])
    if entry.get("side") != "new":
        return None
    lines: list[int] = []
    for part in str(entry.get("line", "")).split(","):
        m = LINE_PART_RE.fullmatch(part.strip())
        if not m:
            return None
        lines += [int(m.group(1)), int(m.group(2) or m.group(1))]
    ordered = sorted((u for u in units if not u.retired), key=lambda u: u.line)
    found = set()
    for n in lines:
        before = [u.section for u in ordered if u.line <= n]
        if not before:
            return None
        found.add(before[-1])
    return found.pop() if len(found) == 1 else None


def baseline_findings(root: Path, deferred: dict, cleared: dict, state) -> list[str]:
    """[re-pin P9] Every unit and text entry of the frozen list is still in [deferred], or left with the
    evidence its kind needs (DECISIONS I104, note at re-pin P9).

    The units are those of the frozen list's [units] and [deferred], and those of a [[units]] record. A
    unit whose claims file still defers it (any `deferred:` status; the gate closes tiers 1 to 4b, so
    only deferred:tier-5 is left) belongs in [deferred]. A unit of the frozen list's [deferred] leaves
    only claimed. Any other leaves claimed, or with another status named in its claims file and a
    decision row that names it, as the [units] rule allowed when it joined [deferred]."""
    base = load_toml(root / BASELINE_FILE)
    findings: list[str] = []
    evidence = unit_evidence(root)
    rows = decision_rows(root)

    def decided(uid: str, record: dict) -> bool:
        """A row of docs/DECISIONS.md that names this unit, not merely any row."""
        return re.search(rf"\b{uid}\b", rows.get(str(record.get("decision", "")).strip(), "")) is not None

    records = {r.get("id"): r for r in cleared.get("units", [])}
    base_units, base_held = base.get("units", {}), set(base.get("deferred", {}))
    tracked = set(base_units.get("added", {})) | set(base_units.get("changed", {})) | base_held | (set(records) - {None})
    for uid in sorted(tracked - set(deferred)):
        status, named = state(uid)
        record = records.get(uid, {})
        if status.startswith("deferred:"):
            findings.append(f"{uid}: its claims file still defers it ({status}), so it belongs in [deferred]")
        elif uid in base_held and status != "claimed":
            findings.append(f"{uid} left [deferred] without being claimed")
        elif status != "claimed" and not (named and decided(uid, record)):
            findings.append(f"{uid} left the list as {status}: claim it, or name it in its claims file with a decision row")
        if status == "claimed" and uid not in evidence:
            findings.append(f"{uid} is claimed with no test that can run and no inspection item with a reason")
        if uid in base_units.get("changed", {}) and not str(record.get("compared", "")).strip():
            findings.append(f"{uid} left [units.changed] with no record of what was compared in {CLEARED_FILE}")
    riders = {r.get("id"): r for r in cleared.get("deferred", [])}
    for uid in sorted(set(deferred) - base_held):
        record = riders.get(uid, {}) if TEXT_ID_RE.fullmatch(uid) else records.get(uid, {})
        if not decided(uid, record):
            findings.append(f"{uid} joined [deferred] with no decision row in {CLEARED_FILE}")
    sections: dict[str, str] = {}

    def section_of(uid: str) -> str | None:
        """The section of a unit in its spec's ledger."""
        if not sections:
            for path in ledger_files(root):
                for u in load_ledger(path)[1]:
                    sections[u.id] = u.section
        return sections.get(uid)

    def entry_section(entry: dict) -> str | None:
        """A text entry's section, derived from its lines when it names none (Q1)."""
        units = [u for path in ledger_files(root) if path.stem == entry.get("spec") for u in load_ledger(path)[1]]
        return derived_section(entry, units)

    done = {e.get("id"): e for e in cleared.get("text", [])}
    lowered = {r.get("id") for r in cleared.get("lowered", []) if decided(r.get("id", ""), r)}
    tests = list(real_tests(root))
    for b in base.get("text", []):
        tid = b["id"]
        rider = riders.get(tid, {})
        unit = str(rider.get("rides", "")).strip()
        if tid in deferred:
            # [re-pin P4a] A text entry defers only riding on a unit deferred to the same work item, of
            # the same spec and section, with a decision row that names the entry. [re-pin P6 Q5] Or of
            # another spec, when the entry's own sentence names that spec and a section the unit is in.
            if not unit:
                findings.append(f"{tid} is in [deferred] with no [[deferred]] record naming the unit it rides on in {CLEARED_FILE}")
            elif deferred.get(unit) != deferred[tid]:
                findings.append(f"{tid} rides on {unit}, which is not deferred to {deferred[tid]}")
            elif not rides_within({**b, "section": entry_section(b)}, unit, section_of(unit)):
                derived = "" if b.get("section") else ", derived from its lines"
                findings.append(
                    f"{tid} ({b.get('spec')} {entry_section(b) or 'no section'}{derived}) rides on {unit},"
                    " of another section, or of another spec its sentence does not name with that section"
                )
        elif tid not in done:
            findings.append(f"{tid} is neither deferred nor cleared")
        else:
            e = done[tid]
            if str(e.get("reading", "")).strip():
                site, kind = str(e.get("site", "")).strip(), e.get("kind")
                path = site.split(":")[0]
                site_ok = path.startswith(SITE_ROOTS) and (root / path).exists()
                if b["class"] == "behaviour" and tid not in lowered:
                    findings.append(f"{tid}: a behaviour entry clears only by a test")
                if not str(e.get("compared", "")).strip():
                    findings.append(f"{tid}: a reading says what was compared")
                if kind not in READING_KINDS:
                    findings.append(f"{tid}: a reading has a kind, one of {sorted(READING_KINDS)}")
                if b.get("guard") and (kind == "informative" or not site_ok):
                    findings.append(f"{tid}: this entry names a code, state or table row: name the test or code site that was read")
                old = next((x for x in base.get("text", []) if x["id"] == e.get("pair")), {})
                paired = old.get("side") == "old" and old.get("spec") == b.get("spec") and e.get("pair") in done and e.get("pair") != tid
                if kind == "reword" and (b.get("side") != "new" or not paired):
                    findings.append(f"{tid}: a reword names the cleared old-side entry of its spec that it replaces, in `pair`")
                if kind == "removed" and b.get("side") != "old":
                    findings.append(f"{tid}: only a removed sentence clears as `removed`")
                wanted = str(e.get("named", "")).strip()
                if kind == "holds" and not (wanted and any(suite == path and wanted in name for suite, name in tests)):
                    findings.append(f"{tid}: `holds` names the suite in `site` and a test of it in `named`")
            if unit:
                # It was deferred: it leaves once its unit is claimed by a test that carries its tag. Its
                # record is id, step (the work item that claimed the unit) and test (the suite).
                suite = str(e.get("test", "")).strip()
                carried = any(s == suite and f"[{tid}]" in n and f"[{unit}]" in n for s, n in tests)
                if not (state(unit)[0] == "claimed" and carried):
                    findings.append(f"{tid} left [deferred] before a test of {unit} that carries [{tid}] claimed it")
    return findings


def pending_findings(root: Path, digest: str | None = None, state=None, gated: set[str] | None = None) -> list[str]:
    """[re-pin P9] The list holds only [deferred], each unit in it is a live gated requirement that its
    claims file defers by name, each owner is a work item, and every entry of the frozen list that left
    has its evidence. `digest` is the frozen list's expected SHA-256; `state` (a unit's status) and
    `gated` (the live gated units) stand in for the claims files and the ledgers in the self-test."""
    data = load_toml(root / PENDING_FILE)
    findings: list[str] = []
    if digest is not None:
        path = root / BASELINE_FILE
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            findings.append(f"{BASELINE_FILE} is missing or was edited")
    for key in sorted(set(data) - {"deferred"}):
        findings.append(f"{PENDING_FILE}: [{key}]: every sub-step has closed, so the list holds only [deferred]")
    deferred = data.get("deferred", {})
    state = state or (lambda uid: claim_state(root, uid))
    if gated is None:
        gated = {u.id for path in ledger_files(root) for u in load_ledger(path)[1] if not u.retired and u.kind in GATED_KINDS}
    for uid, owner in deferred.items():
        if owner not in WORK_ITEMS:
            findings.append(f"[deferred] {uid}: {owner!r} is not one of the work items {sorted(WORK_ITEMS)}")
        if TEXT_ID_RE.fullmatch(uid):
            # A text entry rides on a deferred unit (`baseline_findings` checks which).
            continue
        status, named = state(uid)
        if uid not in gated:
            findings.append(f"[deferred] {uid} is not a live gated requirement")
        elif not (named and status.startswith("deferred:")):
            findings.append(f"[deferred] {uid}: its claims file must defer it by name, in [units]")

    tags = text_tags(root)
    cleared = load_toml(root / CLEARED_FILE)
    findings.extend(baseline_findings(root, deferred, cleared, state))
    seen: set[str] = set()
    for entry in cleared.get("text", []):
        tid = entry.get("id", "")
        if not TEXT_ID_RE.fullmatch(tid) or tid in seen or tid in deferred:
            findings.append(f"{CLEARED_FILE}: {tid!r} is malformed, repeated or still in [deferred]")
        seen.add(tid)
        suite, reading = str(entry.get("test", "")).strip(), str(entry.get("reading", "")).strip()
        if bool(suite) == bool(reading):
            findings.append(f"{CLEARED_FILE}: {tid} needs exactly one of `test` and `reading`")
        elif suite and suite not in tags.get(tid, set()):
            findings.append(f"{CLEARED_FILE}: no test of {suite} names [{tid}]")
    return findings


def pending_self_test() -> int:
    """Each rule of the list passes its clean case and catches its planted violation."""
    import tempfile

    def tree(pending: str, tests: str = "") -> Path:
        root = Path(tempfile.mkdtemp())
        (root / "spec").mkdir()
        (root / PENDING_FILE).write_text(pending, encoding="utf-8")
        (root / "tests").mkdir()
        (root / "tests" / "test_a.nim").write_text(tests, encoding="utf-8")
        return root

    def frozen(open_list: str, base: str, done: str = "", tests: str = "", files: dict | None = None) -> Path:
        root = tree(open_list, tests=tests)
        (root / BASELINE_FILE).write_text(base, encoding="utf-8")
        (root / CLEARED_FILE).write_text(done, encoding="utf-8")
        for name, body in (files or {}).items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(body, encoding="utf-8")
        return root

    live = {"RUN-0001"}
    deferred = ("deferred:tier-5", True)
    out = ("out-of-scope:a recorded reason", True)

    def clean(root: Path, status: tuple[str, bool] = ("claimed", False)) -> bool:
        return not pending_findings(root, state=lambda uid: status, gated=live)

    def says(root: Path, text: str, status: tuple[str, bool] = deferred) -> bool:
        return any(text in f for f in pending_findings(root, state=lambda uid: status, gated=live))

    cleared = '[[text]]\nid = "TXT-0001"\nstep = "P3"\nspec = "RUN"\nline = "1"\nwhat = "x"\ntest = "tests/test_a.nim"\n'
    named = 'test "[TXT-0001] it holds":\n  check true\n'

    def with_cleared(body: str, tests: str) -> Path:
        root = tree("", tests=tests)
        (root / CLEARED_FILE).write_text(body, encoding="utf-8")
        return root

    todo = 'id = "TXT-0001"\nstep = "P3"\nspec = "RUN"\nline = "1"\nwhat = "x"\nclass = "todo"\n'
    must = todo.replace('"todo"', '"behaviour"')
    watch = todo + "guard = true\n"
    read = 'id = "TXT-0001"\nstep = "P3"\nkind = "informative"\nreading = "no change"\ncompared = "old and new text"\n'
    added, changed = '[units.added]\n"RUN-0001" = "P4"\n', '[units.changed]\n"RUN-0001" = "P4"\n'
    held = '[deferred]\n"RUN-0001" = "5-5"\n'
    record = '[[units]]\nid = "RUN-0001"\ncompared = "the test against the new text"\n'
    ruled = '[[units]]\nid = "RUN-0001"\ndecision = "G7"\ncompared = "the claim against the new text"\n'
    rows = {"docs/DECISIONS.md": "### G7 a decision on RUN-0001\n"}
    other = {"docs/DECISIONS.md": "### G7 a decision on something else\n"}
    plain = 'test "the rule holds":\n  check true\n'
    quoted = 'const text = """\ntest "[TXT-0001] x":\n  check true\n"""\n'
    commented = '#[\ntest "[TXT-0001] x":\n  check true\n]#\n'
    cites = 'test "[RUN-0001] it holds":\n  check true\n'
    two = 'test "[TXT-0001] [TXT-0002] both hold":\n  check true\n'
    # A text deferral: TXT-0001 (RUN §1) rides on RUN-0001, deferred to 5-7a.
    rides = '[deferred]\n"RUN-0001" = "5-7a"\n"TXT-0001" = "5-7a"\n'
    behind = '[[text]]\n' + todo + 'section = "§1"\n'
    rider = '[[deferred]]\nid = "TXT-0001"\nrides = "RUN-0001"\ndecision = "G8"\n'
    unit_line = '{"id": "RUN-0001", "kind": "kw", "section": "§1", "heading": "One", "line": 1, "fingerprint": "", "text": "x"}'
    ledger = {
        "conformance/requirements/RUN.jsonl": '{"spec": "s.md", "rev": "x", "next": 2}\n' + unit_line + "\n",
        "docs/DECISIONS.md": "### G7 a decision on RUN-0001\n### G8 TXT-0001 waits for 5-7a\n",
    }
    # A rider that left: its record is id, step (the work item that claimed its unit) and test.
    leaves = 'id = "TXT-0001"\nstep = "5-7a"\ntest = "tests/test_a.nim"\n'

    def abroad(what: str) -> str:
        """`behind` as an entry of CAP whose sentence is `what`: RUN-0001 is then of another spec."""
        return behind.replace('spec = "RUN"', 'spec = "CAP"').replace('what = "x"', f'what = "{what}"')

    both = 'test "[RUN-0001] [TXT-0001] it holds":\n  check true\n'
    # [re-pin P8b Q1] An entry with no section rides by the sections of its lines: RUN-0001 opens §1
    # at l.1 and RUN-0002 opens §2 at l.10.
    opens = '{"id": "RUN-0002", "kind": "kw", "section": "§2", "heading": "Two", "line": 10, "fingerprint": "", "text": "y"}'
    sectioned = {**ledger, "conformance/requirements/RUN.jsonl": ledger["conformance/requirements/RUN.jsonl"] + opens + "\n"}

    def unsectioned(lines: str, side: str = "new") -> str:
        return "[[text]]\n" + todo.replace('line = "1"', f'line = "{lines}"') + f'side = "{side}"\n'

    def derived(lines: str, side: str = "new") -> Path:
        return frozen(rides, unsectioned(lines, side), ruled + rider, files=sectioned)

    edited = tree("")
    (edited / BASELINE_FILE).write_text("# changed\n", encoding="utf-8")
    nine = '[deferred]\n"RUN-0009" = "5-5"\n'
    nine_ruled = {"docs/DECISIONS.md": "### G7 a decision on RUN-0009\n"}
    cases = [
        # The list after the re-pin: [deferred] alone.
        ("[deferred] with a named deferral and a decision passes", clean(frozen(held, "", ruled, files=rows), deferred), True),
        ("a `closed` list fails", says(frozen('closed = ["P1"]\n', ""), "[closed]"), True),
        ("an empty section left in the list fails", says(frozen("[mirror]\n", ""), "[mirror]"), True),
        ("an open text entry fails", says(frozen("[[text]]\n" + todo, "[[text]]\n" + todo), "[text]"), True),
        ("an edited baseline fails", not pending_findings(edited, digest="0" * 64, state=lambda uid: ("claimed", False), gated=live), False),
        # [deferred]: owned by a work item, live, gated and deferred by name.
        ("[deferred] without a named deferral fails", clean(frozen(held, "", ruled, files=rows), ("deferred:tier-5", False)), False),
        ("[deferred] holding a unit its claims file no longer defers fails", says(frozen(held, "", ruled, files=rows), "must defer it by name", ("claimed", True)), True),
        ("[deferred] with a vague owner fails", clean(frozen('[deferred]\n"RUN-0001" = "later"\n', "", ruled, files=rows), deferred), False),
        ("an unknown work item fails", clean(frozen('[deferred]\n"RUN-0001" = "9-9"\n', "", ruled, files=rows), deferred), False),
        ("a deferred unit that is not live fails", says(frozen(nine, "", ruled.replace("0001", "0009"), files=nine_ruled), "RUN-0009 is not a live gated requirement"), True),
        ("a unit joining [deferred] with no decision row fails", says(frozen(held, "", record), "joined [deferred]"), True),
        # A unit that still defers belongs in [deferred] (the gap rule).
        ("a unit still deferred by name fails outside [deferred], even with a decision", says(frozen("", added, ruled, files=rows), "belongs in [deferred]"), True),
        ("a unit still deferred by its section fails outside [deferred]", says(frozen("", added), "belongs in [deferred]", ("deferred:tier-5", False)), True),
        ("a unit known by its [[units]] record alone, still deferred, fails outside [deferred]", says(frozen("", "", ruled, files=rows), "belongs in [deferred]"), True),
        # Leaving: the frozen list's [deferred] only claimed; any other unit claimed, or named with a decision row.
        ("a unit of the frozen [deferred] leaving claimed with a test passes", clean(frozen("", held, tests=cites)), True),
        ("a unit of the frozen [deferred] leaving out of scope fails, even with a decision", says(frozen("", held, ruled, files=rows), "without being claimed", out), True),
        ("a unit leaving out of scope by name with a decision passes", clean(frozen("", added, ruled, files=rows), out), True),
        ("a unit leaving out of scope with no decision fails", says(frozen("", added, record), "left the list as out-of-scope", out), True),
        ("a unit leaving out of scope by its section fails", clean(frozen("", added, ruled, files=rows), (out[0], False)), False),
        ("a unit of a [[units]] record leaving out of scope with no decision fails", clean(frozen("", "", record), out), False),
        ("a decision row that does not exist fails", clean(frozen("", added, ruled), out), False),
        ("a decision row about another matter fails", clean(frozen("", added, ruled, files=other), out), False),
        # A claimed unit's evidence.
        ("a claimed unit with a test passes", clean(frozen("", added, tests=cites)), True),
        ("a claimed unit cited only in a comment fails", clean(frozen("", added, tests="# [RUN-0001]\n")), False),
        ("a test that only skips is no evidence", clean(frozen("", added, tests='test "[RUN-0001] x":\n  skip()\n')), False),
        ("a test that starts by skipping is no evidence", clean(frozen("", added, tests='test "[RUN-0001] x":\n  skip()\n  check true\n')), False),
        ("a test under when false is no evidence", clean(frozen("", added, tests='when false:\n  test "[RUN-0001] x":\n    check true\n')), False),
        ("a test under if false is no evidence", clean(frozen("", added, tests='if false:\n  test "[RUN-0001] x":\n    check true\n')), False),
        ("a test under an unknown define is no evidence", clean(frozen("", added, tests='when defined(neverSet):\n  test "[RUN-0001] x":\n    check true\n')), False),
        ("a test under a platform condition counts", clean(frozen("", added, tests='when defined(posix):\n  test "[RUN-0001] x":\n    check true\n')), True),
        ("a body file no suite includes is no evidence", clean(frozen("", added, files={"tests/zz_body.nim": cites})), False),
        ("a body file a suite includes counts", clean(frozen("", added, tests="include zz_body\n", files={"tests/zz_body.nim": cites})), True),
        ("a changed unit with no record fails", clean(frozen("", changed, tests=cites)), False),
        ("a changed unit with a record passes", clean(frozen("", changed, record, tests=cites)), True),
        ("a test inside a long string is no evidence", bool(text_tags(tree("", tests=quoted))), False),
        ("a test inside a block comment is no evidence", bool(text_tags(tree("", tests=commented))), False),
        ("every tag in a test name counts", text_tags(tree("", tests=two)).keys() == {"TXT-0001", "TXT-0002"}, True),
        ("a tag outside a test name does not count", bool(text_tags(tree("", tests='echo "[TXT-0001]"\n'))), False),
        # A text entry of the frozen list: deferred, or cleared with its evidence.
        ("a deleted text entry fails", says(frozen("", "[[text]]\n" + todo), "neither deferred nor cleared", ("claimed", False)), True),
        ("a todo entry cleared by reading passes", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read)), True),
        ("a behaviour entry cleared by reading fails", clean(frozen("", "[[text]]\n" + must, "[[text]]\n" + read)), False),
        ("a lowered behaviour entry may clear by reading", clean(frozen("", "[[text]]\n" + must, "[[text]]\n" + read + '[[lowered]]\nid = "TXT-0001"\ndecision = "G7"\n', files={"docs/DECISIONS.md": "### G7 on TXT-0001\n"})), True),
        ("a reading without what was compared fails", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read.replace('compared = "old and new text"\n', ""))), False),
        ("a reading with no kind fails", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read.replace('kind = "informative"\n', ""))), False),
        ("a guarded reading without a site fails", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read)), False),
        ("a guarded entry cannot be informative", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read + 'site = "tests/test_a.nim:1"\n')), False),
        ("a guarded reading that holds passes", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read.replace("informative", "holds") + 'site = "tests/test_a.nim:1"\nnamed = "the rule"\n', tests=plain)), True),
        ("`holds` naming no real test fails", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read.replace("informative", "holds") + 'site = "tests/test_a.nim:1"\nnamed = "another rule"\n', tests=plain)), False),
        ("`holds` outside the tests fails", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read.replace("informative", "holds") + 'site = "spec/pins.toml"\n')), False),
        ("a guarded site outside the code fails", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read.replace("informative", "removed") + 'site = "spec/pins.toml"\n')), False),
        ("a reword without its pair fails", clean(frozen("", "[[text]]\n" + todo + 'side = "new"\n', "[[text]]\n" + read.replace("informative", "reword"))), False),
        ("a reword naming itself fails", clean(frozen("", "[[text]]\n" + todo + 'side = "new"\n', "[[text]]\n" + read.replace("informative", "reword") + 'pair = "TXT-0001"\n')), False),
        ("`removed` on a new sentence fails", clean(frozen("", "[[text]]\n" + todo + 'side = "new"\n', "[[text]]\n" + read.replace("informative", "removed"))), False),
        ("a cleared entry names its test", not pending_findings(with_cleared(cleared, named), gated=live), True),
        ("a cleared entry without that test fails", not pending_findings(with_cleared(cleared, ""), gated=live), False),
        ("a cleared entry still in [deferred] fails", says(frozen('[deferred]\n"TXT-0001" = "5-7a"\n', "", cleared, tests=named), "still in [deferred]"), True),
        # A text entry that rides on a deferred unit.
        ("a text entry riding on a unit of its section passes", clean(frozen(rides, behind, ruled + rider, files=ledger), deferred), True),
        ("a text entry deferred with no rider record fails", clean(frozen(rides, behind, ruled, files=ledger), deferred), False),
        ("a text deferral with no decision row fails", clean(frozen(rides, behind, ruled + rider, files={**ledger, "docs/DECISIONS.md": "### G7 a decision on RUN-0001\n"}), deferred), False),
        ("a text entry riding on another section's unit fails", clean(frozen(rides, behind.replace("§1", "§2"), ruled + rider, files=ledger), deferred), False),
        ("a text entry riding on another work item's unit fails", clean(frozen(rides.replace('"TXT-0001" = "5-7a"', '"TXT-0001" = "5-7b"'), behind, ruled + rider, files=ledger), deferred), False),
        ("a text entry riding on a unit of another spec its sentence names, in the section named, passes", clean(frozen(rides, abroad("see LOGOS-MODULE-RUNTIME Section 1."), ruled + rider, files=ledger), deferred), True),
        ("a text entry riding on a unit of another spec its sentence does not name fails", clean(frozen(rides, abroad("x"), ruled + rider, files=ledger), deferred), False),
        ("a text entry riding on a unit of a spec its sentence names, outside the section named, fails", clean(frozen(rides, abroad("see LOGOS-MODULE-RUNTIME Section 2."), ruled + rider, files=ledger), deferred), False),
        ("an entry with no section whose lines are in one section rides on its unit", clean(derived("3, 5"), deferred), True),
        ("an entry with no section whose lines are in two sections fails", clean(derived("3, 12"), deferred), False),
        ("an old-side entry with no section fails", clean(derived("3, 5", "old"), deferred), False),
        ("an entry with no section and the line \"none\" fails", clean(derived("none"), deferred), False),
        ("the finding names the derived section", says(derived("12"), "(RUN §2, derived from its lines)"), True),
        ("a deferred text entry leaving with its unit's test passes", clean(frozen("", behind, ruled + rider + "[[text]]\n" + leaves, tests=both, files=ledger)), True),
        ("a deferred text entry leaving by a test without its unit fails", clean(frozen("", behind, ruled + rider + "[[text]]\n" + leaves, tests=named, files=ledger)), False),
        ("a deferred text entry leaving before its unit is claimed fails", says(frozen("", behind, ruled + rider + "[[text]]\n" + leaves, tests=both, files=ledger), "left [deferred] before", ("out-of-scope:x", True)), True),
        # deploydoc: a duty row's citation is named whole.
        ("a duty citation is named whole", names_cite("(IF l.1473; BCP l.360)", "BCP l.360"), True),
        ("a citation ending a sentence is named", names_cite("as BCP l.360.", "BCP l.360"), True),
        ("a longer line number does not name a shorter one", names_cite("BCP l.3600", "BCP l.360"), False),
        ("a range does not name the line it starts at", names_cite("BCP l.360-410", "BCP l.360"), False),
        ("another spec's citation does not name it", names_cite("RCA l.1", "CA l.1"), False),
    ]
    failed = [name for name, got, want in cases if got != want]
    for name in failed:
        print(f"pending self-test: {name} went wrong")
    if not failed:
        print(f"pending self-test: {len(cases)} cases")
    return 1 if failed else 0


def cmd_pending(args) -> int:
    """[re-pin P9] The list of what stays deferred past the re-pin is well formed, and what left the
    re-pin's frozen list has its evidence."""
    if args.self_test:
        return pending_self_test()
    root = Path(args.root)
    findings = pending_findings(root, digest=BASELINE_SHA256)
    for f in findings:
        print(f)
    deferred = load_toml(root / PENDING_FILE).get("deferred", {})
    riders = sum(1 for uid in deferred if TEXT_ID_RE.fullmatch(uid))
    print(f"{PENDING_FILE}: {len(deferred) - riders} units and {riders} text entries deferred; {len(findings)} findings")
    return 1 if findings else 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="spectrace")
    ap.add_argument("--root", default=".", help="logos-core-nim checkout")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("sync", "check", "mirror", "pins"):
        p = sub.add_parser(name)
        env_specs = os.environ.get("SPECTRACE_SPECS")
        p.add_argument(
            "--specs",
            default=env_specs,
            required=env_specs is None,
            help="docs/logos-core/raw of the spec revision (default: $SPECTRACE_SPECS)",
        )
        if name == "sync":
            p.add_argument(
                "--rev",
                default=os.environ.get("SPECTRACE_REV"),
                help="spec revision recorded in the ledger (default: $SPECTRACE_REV, then <specs>/.spec-rev)",
            )
            p.add_argument("--quiet", action="store_true")
        if name in ("mirror", "pins"):
            p.add_argument("--write", action="store_true")
    sub.add_parser("deploydoc", help="check docs/DEPLOYMENT.md against the claims (DECISIONS G309)")
    o = sub.add_parser("owners", help="each unit has one owning package")
    o.add_argument("--self-test", action="store_true", help="check the lint on planted violations")
    n = sub.add_parser("pending", help="check the list of what stays deferred past the re-pin")
    n.add_argument("--self-test", action="store_true", help="check the list's rules on planted violations")
    g = sub.add_parser("gate")
    g.add_argument("--show", type=int, default=20, help="missing units listed per spec")
    g.add_argument(
        "--closed-tier",
        action="append",
        default=[],
        metavar="N",
        help="fail on any status deferred:tier-N (repeatable)",
    )
    args = ap.parse_args()
    return {
        "sync": cmd_sync,
        "check": cmd_check,
        "mirror": cmd_mirror,
        "pins": cmd_pins,
        "gate": cmd_gate,
        "deploydoc": cmd_deploydoc,
        "owners": cmd_owners,
        "pending": cmd_pending,
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
