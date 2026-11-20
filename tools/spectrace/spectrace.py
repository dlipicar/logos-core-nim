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

While a spec re-pin is in progress, spec/repin-pending.toml lists what still follows the old text:
`mirror`, `pins`, `gate` and `deploydoc` accept a listed difference and fail on a listed item that no
longer differs, so the list can only shrink honestly. `pending` checks the list itself.
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
PENDING_STEP_RE = re.compile(r"P[0-9]")
TEXT_ID_RE = re.compile(r"TXT-\d{4}")
TEXT_CLASSES = {"behaviour", "todo"}
READING_KINDS = {"reword", "removed", "informative", "holds"}
WORK_ITEMS = {"5-3a", "5-5", "5-7a", "5-7b", "5-10", "5-12"}  # the work items that may own a unit after the re-pin
SITE_ROOTS = ("src/", "sdk/src/", "tests/", "sdk/tests/", "docs/")
TEST_TEMPLATES = "test|ltTest|peerTest|sceneTest"
# Conditions a test may sit under and still run somewhere: platforms, and the one build switch the suites use.
LIVE_CONDITION = re.compile(r"defined\((?:posix|windows|linux|macosx|android|ios)\)|declared\(caParity\)")
HELD_STATUS = "deferred:tier-5"


@dataclass
class Pending:
    """What still follows the previous spec revision. Each section maps an item to its sub-step,
    and `deferred` maps a unit, or a text entry that rides on a deferred unit, to the work item
    that owns it after the re-pin."""

    mirror: dict = field(default_factory=dict)
    pin: dict = field(default_factory=dict)
    added: dict = field(default_factory=dict)
    changed: dict = field(default_factory=dict)
    stale: dict = field(default_factory=dict)
    deploydoc: dict = field(default_factory=dict)
    text: list = field(default_factory=list)
    deferred: dict = field(default_factory=dict)

    def holds(self, uid: str) -> bool:
        """The unit is new or changed and its sub-step has not cleared it, or it stays deferred."""
        return uid in self.added or uid in self.changed or uid in self.deferred


def load_pending(root: Path) -> Pending:
    data = load_toml(root / PENDING_FILE)
    units = data.get("units", {})
    return Pending(
        mirror=data.get("mirror", {}),
        pin=data.get("pin", {}),
        added=units.get("added", {}),
        changed=units.get("changed", {}),
        stale=data.get("stale", {}),
        deploydoc=data.get("deploydoc", {}),
        text=data.get("text", []),
        deferred=data.get("deferred", {}),
    )


# Ledger -------------------------------------------------------------------------


CONFORMANCE_TREES = (Path("conformance"), Path("sdk") / "conformance")  # core's and the SDK's


def ledger_path(root: Path, prefix: str) -> Path:
    """The spec's ledger, in the tree that holds it; a new ledger starts in core's."""
    for tree in CONFORMANCE_TREES:
        path = root / tree / "requirements" / f"{prefix}.jsonl"
        if path.exists():
            return path
    return root / CONFORMANCE_TREES[0] / "requirements" / f"{prefix}.jsonl"


def ledger_files(root: Path) -> list[Path]:
    return [f for tree in CONFORMANCE_TREES for f in sorted((root / tree / "requirements").glob("*.jsonl"))]


def inspection_files(root: Path) -> list[Path]:
    """Every inspection file of both packages, by name."""
    files = [f for tree in CONFORMANCE_TREES for f in (root / tree / "inspection").glob("*.toml")]
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
    pending = load_pending(root)
    bad = held = 0
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
        listed = m["out"] in pending.mirror
        if not blocks or ordinal > len(blocks):
            if listed:
                held += 1
                continue
            print(f"{m['out']}: {m['file']} {m['section']} has no block #{ordinal}")
            bad += 1
            continue
        want = "\n".join(blocks) if ordinal == 0 else blocks[ordinal - 1]
        if listed:
            # Its sub-step moves the mirror, the pin and the parser together: `--write` leaves it.
            if out.exists() and out.read_text(encoding="utf-8") == want:
                print(f"{m['out']}: matches the spec but is still listed in {PENDING_FILE}")
                bad += 1
            else:
                held += 1
            continue
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
    note = f", {held} held by {PENDING_FILE}" if held else ""
    print("%s %d mirrors%s" % ("wrote" if args.write else "checked", len(cfg.get("mirror", [])), note))
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
    pending = load_pending(root)
    bad = held = 0
    for name in sorted(set(pending.pin) - set(pins)):
        print(f"pin {name}: listed in {PENDING_FILE} but not in spec/pins.toml")
        bad += 1
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
        if name in pending.pin:
            if found:
                print(f"pin {name}: found in {p['file']} {p['section']} but still listed in {PENDING_FILE}")
                bad += 1
            else:
                held += 1
            continue
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
    note = f", {held} held by {PENDING_FILE}" if held else ""
    print(f"checked {len(pins)} pins and {', '.join(str(p) for p in PINS_NIM.values())}{note}")
    return 0


# Coverage gate -------------------------------------------------------------------

TEST_ID_RE = re.compile(r"\[([A-Z]{3}-\d{4})\]")
TEST_TREES = ("tests", "sdk/tests")  # core's suites and the SDK's
# `lc` units stay in the ledger, so tests may still cite them, but no claim
# needs them covered: lowercase forms keep their ordinary meaning (G117, B1).
GATED_KINDS = {"kw", "cddl", "block"}


STATUS_RE = re.compile(r"claimed|deferred:tier-(?:[1-5]|4b)|informative|out-of-scope:.+")


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
    """Every live unit in a claimed section is referenced by a test or an inspection
    item; an inspected unit is claimed; no status defers to a closed tier."""
    root = Path(args.root)
    pending = load_pending(root)
    referenced: set[str] = set()
    for tree in TEST_TREES:
        for test in (root / tree).rglob("*.nim"):
            referenced.update(TEST_ID_RE.findall(test.read_text(encoding="utf-8")))
    failures = 0
    inspected: dict[str, str] = {}
    for extra in inspection_files(root):
        for item in load_toml(extra).get("item", []):
            if not str(item.get("reason", "")).strip():
                print(f"{extra.name}: inspection item {item.get('ids')} has no reason")
                failures += 1
            referenced.update(item.get("ids", []))
            for i in item.get("ids", []):
                inspected.setdefault(i, extra.name)
    # Both packages' ledgers follow one spec revision: `SpecRevision` is derived from them.
    revs = {json.loads(f.read_text(encoding="utf-8").split("\n", 1)[0])["rev"] for f in ledger_files(root)}
    if len(revs) > 1:
        print(f"the ledgers name {len(revs)} spec revisions: {sorted(revs)}")
        failures += 1
    closed = {f"deferred:tier-{t}" for t in args.closed_tier}
    live_ids: set[str] = set()
    gated_all: set[str] = set()
    named_all: set[str] = set()

    def status_of(claim_sets: list[dict], unit) -> str:
        return HELD_STATUS if pending.holds(unit.id) else status_across(claim_sets, unit)

    for fname, prefix in SPECS.items():
        claim_sets = claims_of(root, prefix)
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
        gated_all |= gated_ids
        named = {uid for claims in claim_sets for uid in claims.get("units", {})}
        named_all |= named
        for uid in sorted(named - gated_ids - set(pending.stale)):
            print(f"{prefix}: [units] names {uid}, which is not a live gated requirement")
            failures += 1
        by_status: dict[str, int] = {}
        by_label: dict[str, int] = {}
        for u in live:
            full = status_of(claim_sets, u)
            st = full.split(":")[0]
            by_status[st] = by_status.get(st, 0) + 1
            if st == "deferred":
                by_label[full] = by_label.get(full, 0) + 1
            # [W1] Inspection stands for a test, so it covers claimed units only.
            if u.id in inspected and full != "claimed" and not pending.holds(u.id):
                print(f"{prefix}: {u.id} is inspected ({inspected[u.id]}) but not claimed ({full})")
                failures += 1
        claimed = [u for u in live if status_of(claim_sets, u) == "claimed"]
        missing = [u for u in claimed if u.id not in referenced]
        summary = ", ".join(f"{v} {k}" for k, v in sorted(by_status.items()))
        print(f"{prefix}: {len(claimed) - len(missing)}/{len(claimed)} claimed units tested ({summary})")
        if by_label:
            print("  " + ", ".join(f"{k} {v}" for k, v in sorted(by_label.items())))
        for u in missing[: args.show]:
            print(f"  untested {u.id} ({u.section} l.{u.line}): {u.text[:100]!r}")
        failures += len(missing)
    stale = sorted(i for i in referenced if i[:3] in PREFIX_FILE and i not in live_ids and i not in pending.stale)
    for i in stale:
        print(f"a test references unknown or retired requirement {i}")
    for finding in pending_gate_findings(pending, referenced, named_all, live_ids, gated_all):
        print(finding)
        failures += 1
    return 1 if failures or stale else 0


def pending_gate_findings(
    pending: Pending, referenced: set[str], named: set[str], live: set[str], gated: set[str]
) -> list[str]:
    """The list can only shrink honestly: an entry that no longer holds anything back is an error."""
    findings = []
    # [re-pin P4a] A text entry in [deferred] is no unit: `spectrace pending` checks the unit it rides on.
    units = {uid for uid in pending.deferred if not TEXT_ID_RE.fullmatch(uid)}
    for uid in sorted(set(pending.added) | set(pending.changed) | units):
        if uid not in gated:
            findings.append(f"{PENDING_FILE}: {uid} is not a live gated requirement")
    for uid in sorted(pending.added):
        if uid in referenced:
            findings.append(f"{PENDING_FILE}: {uid} is evidenced now; clear its [units] entry")
    for uid in sorted(pending.stale):
        if uid in live:
            findings.append(f"{PENDING_FILE}: {uid} is listed as stale but is live")
        elif uid not in referenced and uid not in named:
            findings.append(f"{PENDING_FILE}: nothing references {uid} any more; clear its [stale] entry")
    return findings


# One owner per unit ------------------------------------------------------------------


def owner_findings(root: Path) -> list[str]:
    """A ledger lives in one package, and each live gated unit of a spec with two claims files
    is claimed by at most one of them; a unit neither claims has the same status in both."""
    findings = []
    for prefix in SPECS.values():
        homes = [t for t in CONFORMANCE_TREES if (root / t / "requirements" / f"{prefix}.jsonl").exists()]
        if len(homes) > 1:
            findings.append(f"{prefix}: a ledger in both {homes[0]} and {homes[1]}")
        claim_sets = claims_of(root, prefix)
        if len(claim_sets) < 2:
            continue
        _, units = load_ledger(ledger_path(root, prefix))
        for u in units:
            if u.retired or u.kind not in GATED_KINDS:
                continue
            found = [unit_status(claims, u) for claims in claim_sets]
            if found.count("claimed") > 1:
                findings.append(f"{u.id}: claimed by both packages")
            elif "claimed" not in found and len(set(found)) > 1:
                findings.append(f"{u.id}: claimed by neither, with different statuses {found}")
    return findings


def owners_self_test() -> int:
    """The lint passes a clean split and catches each planted violation."""
    import tempfile

    def tree(core: str, sdk: str, both_ledgers: bool = False) -> list[str]:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            unit = Unit("kw", "1", "One", 1, "A MUST.", id="CDE-0001").finish()
            save_ledger(ledger_path(root, "CDE"), "x.md", "r", 2, [unit])
            if both_ledgers:
                save_ledger(root / CONFORMANCE_TREES[1] / "requirements" / "CDE.jsonl", "x.md", "r", 2, [unit])
            for t, status in zip(CONFORMANCE_TREES, (core, sdk)):
                (root / t / "claims").mkdir(parents=True, exist_ok=True)
                (root / t / "claims" / "CDE.toml").write_text(f'default = "{status}"\n', encoding="utf-8")
            return owner_findings(root)

    out = "out-of-scope:other"
    cases = [
        ("one package claims it", tree("claimed", out), False),
        ("neither claims it, alike", tree(out, out), False),
        ("both claim it", tree("claimed", "claimed"), True),
        ("neither claims it, differently", tree(out, "informative"), True),
        ("a ledger in both packages", tree("claimed", out, both_ledgers=True), True),
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

    referenced: set[str] = set()
    for tree in TEST_TREES:
        for test in (root / tree).rglob("*.nim"):
            referenced.update(TEST_ID_RE.findall(test.read_text(encoding="utf-8")))
    reasons: dict[str, list[str]] = {}
    for extra in inspection_files(root):
        for item in load_toml(extra).get("item", []):
            for i in item.get("ids", []):
                reasons.setdefault(i, []).append(str(item.get("reason", "")))

    claims_cache: dict[str, tuple[list[dict], dict[str, Unit]]] = {}

    def lookup(uid: str) -> tuple[str | None, Unit | None]:
        prefix = uid[:3]
        if prefix not in PREFIX_FILE:
            return None, None
        if prefix not in claims_cache:
            claim_sets = claims_of(root, prefix)
            _, units = load_ledger(ledger_path(root, prefix))
            claims_cache[prefix] = (claim_sets, {u.id: u for u in units if not u.retired})
        claim_sets, units = claims_cache[prefix]
        unit = units.get(uid)
        return (status_across(claim_sets, unit) if unit and claim_sets else None), unit

    def check_claimed(where: str, uid: str) -> None:
        status, unit = lookup(uid)
        if unit is None or unit.kind not in GATED_KINDS:
            failures.append(f"{where}: {uid} is not a live gated requirement")
        elif status != "claimed":
            failures.append(f"{where}: {uid} is {status}, not claimed")
        elif uid not in referenced and uid not in reasons:
            failures.append(f"{where}: {uid} is claimed with no tagged test and no inspection item")

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
        if not any(cite in r for r in doc_reasons):
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

    failures, held = split_deploydoc_failures(failures, load_pending(root))
    for f in failures:
        print(f)
    note = f", {held} held by {PENDING_FILE}" if held else ""
    print(
        f"{DEPLOY_DOC}: {len(items)} item rows, {len(duties)} duty rows, "
        f"{len(answered)}/{len(gated)} BCP §5.4 units answered, {len(failures)} failures{note}"
    )
    return 1 if failures else 0


DEPLOY_HELD_RE = re.compile(r"is in no row|is not a gated unit of")


def split_deploydoc_failures(failures: list[str], pending: Pending) -> tuple[list[str], int]:
    """(what still fails, how many the pending list holds). A listed unit must still fail, and only the
    failure the list expects is held: a row that is missing or names a unit not yet gated."""
    mentions = lambda uid, f: re.search(rf"\b{uid}\b", f) is not None and DEPLOY_HELD_RE.search(f) is not None
    rest = [f for f in failures if not any(mentions(uid, f) for uid in pending.deploydoc)]
    for uid in sorted(pending.deploydoc):
        if not any(mentions(uid, f) for f in failures):
            rest.append(f"{PENDING_FILE}: {uid} no longer fails; clear its [deploydoc] entry")
    return rest, len(failures) - len([f for f in rest if f in failures])


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
        paths = [p for p in sorted((root / tree).glob("*.nim")) if not p.name.startswith(".")] if (root / tree).is_dir() else []
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


def baseline_findings(root: Path, pending: Pending, cleared: dict, state) -> list[str]:
    """Every entry of the frozen list is still open on its sub-step, or left with the evidence its kind needs."""
    base = load_toml(root / BASELINE_FILE)
    findings: list[str] = []
    moved = {m.get("id"): m for m in cleared.get("moved", [])}

    def same_step(item: str, was: str, now: str) -> None:
        m = moved.get(item, {})
        if now != was and not (m.get("from") == was and m.get("to") == now and str(m.get("reason", "")).strip()):
            findings.append(f"{item}: sub-step {was} became {now} with no [[moved]] record in {CLEARED_FILE}")

    for name, now in (("mirror", pending.mirror), ("pin", pending.pin), ("stale", pending.stale), ("deploydoc", pending.deploydoc)):
        # An entry that left is checked by that section's own command, which must still know the item.
        for item, was in base.get(name, {}).items():
            if item in now:
                same_step(item, was, now[item])
    mirrors = {m.get("out") for m in load_toml(root / "spec" / "mirrors.toml").get("mirror", [])}
    gone = {r.get("id"): r for r in cleared.get("stale", [])}
    for item in set(base.get("stale", {})) - set(pending.stale):
        if not str(gone.get(item, {}).get("compared", "")).strip():
            findings.append(f"{item} left [stale] with no record of what replaced the rule, or what became of its code, in {CLEARED_FILE}")
    for item in set(base.get("mirror", {})) - mirrors:
        findings.append(f"{item}: a baseline mirror is no longer configured in spec/mirrors.toml")
    for item in set(base.get("pin", {})) - set(load_toml(root / "spec" / "pins.toml")):
        findings.append(f"{item}: a baseline pin is no longer in spec/pins.toml")

    evidence = unit_evidence(root)
    rows = decision_rows(root)

    def decided(uid: str, record: dict) -> bool:
        """A row of docs/DECISIONS.md that names this unit, not merely any row."""
        return re.search(rf"\b{uid}\b", rows.get(str(record.get("decision", "")).strip(), "")) is not None

    records = {r.get("id"): r for r in cleared.get("units", [])}
    for kind, now in (("added", pending.added), ("changed", pending.changed)):
        for uid, was in base.get("units", {}).get(kind, {}).items():
            if uid in now:
                same_step(uid, was, now[uid])
                continue
            status, named = state(uid)
            record = records.get(uid, {})
            if status != "claimed" and not (named and decided(uid, record)):
                findings.append(f"{uid} left [units.{kind}] as {status}: claim it, or name it in its claims file with a decision row")
            if status == "claimed" and uid not in evidence:
                findings.append(f"{uid} left [units.{kind}] with no test that can run and no inspection item with a reason")
            if kind == "changed" and not str(record.get("compared", "")).strip():
                findings.append(f"{uid} left [units.changed] with no record of what was compared in {CLEARED_FILE}")
    for uid in base.get("deferred", {}):
        if uid not in pending.deferred and state(uid)[0] != "claimed":
            findings.append(f"{uid} left [deferred] without being claimed")
    riders = {r.get("id"): r for r in cleared.get("deferred", [])}
    for uid in set(pending.deferred) - set(base.get("deferred", {})):
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

    open_text = {e.get("id"): e for e in pending.text}
    done = {e.get("id"): e for e in cleared.get("text", [])}
    lowered = {r.get("id") for r in cleared.get("lowered", []) if decided(r.get("id", ""), r)}
    tests = list(real_tests(root))
    for b in base.get("text", []):
        tid = b["id"]
        rider = riders.get(tid, {})
        unit = str(rider.get("rides", "")).strip()
        if tid in open_text:
            same_step(tid, b["step"], open_text[tid].get("step", ""))
            if b["class"] == "behaviour" and open_text[tid].get("class") != "behaviour" and tid not in lowered:
                findings.append(f"{tid}: a behaviour entry is lowered only with a [[lowered]] record and a decision row that names it")
        elif tid in pending.deferred:
            # [re-pin P4a] A text entry defers only riding on a unit deferred to the same work item, of
            # the same spec and section, with a decision row that names the entry.
            if not unit:
                findings.append(f"{tid} is in [deferred] with no [[deferred]] record naming the unit it rides on in {CLEARED_FILE}")
            elif pending.deferred.get(unit) != pending.deferred[tid]:
                findings.append(f"{tid} rides on {unit}, which is not deferred to {pending.deferred[tid]}")
            elif not unit.startswith(str(b.get("spec", "")) + "-") or section_of(unit) != b.get("section"):
                findings.append(f"{tid} ({b.get('spec')} {b.get('section')}) rides on {unit}, of another spec or section")
        elif tid not in done:
            findings.append(f"{tid} is neither open nor cleared")
        else:
            e = done[tid]
            same_step(tid, b["step"], e.get("step", ""))
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
                # It was deferred: it leaves once its unit is claimed by a test that carries its tag.
                suite = str(e.get("test", "")).strip()
                carried = any(s == suite and f"[{tid}]" in n and f"[{unit}]" in n for s, n in tests)
                if not (state(unit)[0] == "claimed" and carried):
                    findings.append(f"{tid} left [deferred] before a test of {unit} that carries [{tid}] claimed it")
    return findings


def pending_findings(root: Path, step: str | None = None, digest: str | None = None, state=None) -> list[str]:
    """The structure of the list, the evidence of each entry that left it and, with `step`, what that
    sub-step has not cleared yet. `digest` is the frozen list's expected SHA-256."""
    data = load_toml(root / PENDING_FILE)
    findings: list[str] = []
    if digest is not None:
        path = root / BASELINE_FILE
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            findings.append(f"{BASELINE_FILE} is missing or was edited")
    known = {"closed", "mirror", "pin", "units", "stale", "deploydoc", "text", "deferred"}
    for key in sorted(set(data) - known):
        findings.append(f"{PENDING_FILE}: unknown section [{key}]")
    pending = load_pending(root)
    closed = set(data.get("closed", []))  # sub-steps that have merged: they own nothing any more
    # P6 and P7 may merge in either order; otherwise a sub-step closes only after every earlier one.
    rank = {f"P{n}": n if n < 7 else n - 1 for n in range(1, 10)}
    for name in sorted(closed):
        if name not in rank:
            findings.append(f"closed: {name!r} is not a sub-step")
        elif any(rank[other] < rank[name] and other not in closed for other in rank):
            findings.append(f"closed: {name} is closed while an earlier sub-step is open")
    sections = {
        "mirror": pending.mirror,
        "pin": pending.pin,
        "units.added": pending.added,
        "units.changed": pending.changed,
        "stale": pending.stale,
        "deploydoc": pending.deploydoc,
    }
    for name, entries in sections.items():
        for item, value in entries.items():
            if not (isinstance(value, str) and PENDING_STEP_RE.fullmatch(value)):
                findings.append(f"[{name}] {item}: {value!r} is not a sub-step")
            elif value == step or value in closed:
                findings.append(f"[{name}] {item} still belongs to {value}")
    state = state or (lambda uid: claim_state(root, uid))
    for uid, owner in pending.deferred.items():
        if owner not in WORK_ITEMS:
            findings.append(f"[deferred] {uid}: {owner!r} is not one of the work items {sorted(WORK_ITEMS)}")
        if TEXT_ID_RE.fullmatch(uid):
            # A text entry rides on a deferred unit (`baseline_findings` checks which).
            continue
        status, named = state(uid)
        if not (named and status.startswith("deferred:")):
            findings.append(f"[deferred] {uid}: its claims file must defer it by name, in [units]")
    both = set(pending.added) & set(pending.changed)
    for uid in sorted(both):
        findings.append(f"[units] {uid} is both added and changed")
    for uid in sorted((set(pending.added) | set(pending.changed)) & set(pending.deferred)):
        findings.append(f"{uid} is in both [units] and [deferred]")

    tags = text_tags(root)
    seen: set[str] = set()
    for entry in pending.text:
        tid = entry.get("id", "")
        if not TEXT_ID_RE.fullmatch(tid) or tid in seen:
            findings.append(f"[[text]] {tid!r}: a missing, malformed or repeated id")
        seen.add(tid)
        if not all(str(entry.get(k, "")).strip() for k in ("step", "spec", "line", "what")):
            findings.append(f"[[text]] {tid}: step, spec, line and what are required")
        if not PENDING_STEP_RE.fullmatch(str(entry.get("step", ""))):
            findings.append(f"[[text]] {tid}: {entry.get('step')!r} is not a sub-step")
        if entry.get("class") not in TEXT_CLASSES:
            findings.append(f"[[text]] {tid}: class {entry.get('class')!r} is not one of {sorted(TEXT_CLASSES)}")
        if entry.get("step") == step or entry.get("step") in closed:
            findings.append(f"[[text]] {tid} still belongs to {entry.get('step')}")
        if tid in tags:
            findings.append(f"[[text]] {tid} is named by {sorted(tags[tid])}; move it to {CLEARED_FILE}")
        if tid in pending.deferred:
            findings.append(f"[[text]] {tid} is also in [deferred]")

    cleared = load_toml(root / CLEARED_FILE)
    findings.extend(baseline_findings(root, pending, cleared, state))
    for entry in cleared.get("text", []):
        tid = entry.get("id", "")
        if not TEXT_ID_RE.fullmatch(tid) or tid in seen:
            findings.append(f"{CLEARED_FILE}: {tid!r} is malformed, repeated or still pending")
        seen.add(tid)
        suite, reading = str(entry.get("test", "")).strip(), str(entry.get("reading", "")).strip()
        if bool(suite) == bool(reading):
            findings.append(f"{CLEARED_FILE}: {tid} needs exactly one of `test` and `reading`")
        elif suite and suite not in tags.get(tid, set()):
            findings.append(f"{CLEARED_FILE}: no test of {suite} names [{tid}]")
    return findings


def pending_self_test() -> int:
    """Each rule of the list passes its clean case and catches its planted violation."""
    import contextlib
    import io
    import tempfile

    spec_text = "# 1. One\n\n```cddl\na = 1\n```\n\nThe value abc is pinned.\n"

    def tree(pending: str, mirror: str = "a = 1\n", pin: str = "abc", tests: str = "") -> Path:
        root = Path(tempfile.mkdtemp())
        (root / "spec" / "mirrors").mkdir(parents=True)
        (root / "specs").mkdir()
        (root / "specs" / "s.md").write_text(spec_text, encoding="utf-8")
        (root / "spec" / "mirrors" / "m.cddl").write_text(mirror, encoding="utf-8")
        (root / "spec" / "mirrors.toml").write_text(
            '[[mirror]]\nfile = "s.md"\nsection = "§1"\nout = "m.cddl"\npackage = "core"\n', encoding="utf-8"
        )
        (root / "spec" / "pins.toml").write_text(
            f'[p]\nfile = "s.md"\nsection = "§1"\nvalue = "{pin}"\n', encoding="utf-8"
        )
        (root / PENDING_FILE).write_text(pending, encoding="utf-8")
        (root / "tests").mkdir()
        (root / "tests" / "test_a.nim").write_text(tests, encoding="utf-8")
        for path in PINS_NIM.values():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text("", encoding="utf-8")
        return root

    def ok(fn, root: Path, **kw) -> bool:
        args = argparse.Namespace(root=str(root), specs=str(root / "specs"), write=False, **kw)
        with contextlib.redirect_stdout(io.StringIO()):
            return fn(args) == 0

    def pins_ok(root: Path) -> bool:
        # Only the pin rules: the generated modules are not part of this tree's story.
        save = dict(PINS_NIM)
        PINS_NIM.clear()
        try:
            return ok(cmd_pins, root)
        finally:
            PINS_NIM.update(save)

    entry = '[[text]]\nid = "TXT-0001"\nstep = "P3"\nspec = "RUN"\nline = "1"\nwhat = "x"\nclass = "todo"\n'
    cleared = '[[text]]\nid = "TXT-0001"\nstep = "P3"\nspec = "RUN"\nline = "1"\nwhat = "x"\ntest = "tests/test_a.nim"\n'
    named = 'test "[TXT-0001] it holds":\n  check true\n'

    def with_cleared(body: str, tests: str) -> Path:
        root = tree("", tests=tests)
        (root / CLEARED_FILE).write_text(body, encoding="utf-8")
        return root

    gate = lambda p, refd, named_ids=frozenset(), live=frozenset({"RUN-0001"}): pending_gate_findings(
        p, set(refd), set(named_ids), set(live), set(live)
    )
    fails = ["l.1: BCP-0001 is in no row"]


    def frozen(open_list: str, base: str, done: str = "", tests: str = "", files: dict | None = None) -> Path:
        root = tree(open_list, tests=tests)
        (root / BASELINE_FILE).write_text(base, encoding="utf-8")
        (root / CLEARED_FILE).write_text(done, encoding="utf-8")
        for name, body in (files or {}).items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(body, encoding="utf-8")
        return root

    def clean(root: Path, status: tuple[str, bool] = ("claimed", False), step: str | None = None) -> bool:
        return not pending_findings(root, step, state=lambda uid: status)

    todo = 'id = "TXT-0001"\nstep = "P3"\nspec = "RUN"\nline = "1"\nwhat = "x"\nclass = "todo"\n'
    must = todo.replace('"todo"', '"behaviour"')
    watch = todo + "guard = true\n"
    read = 'id = "TXT-0001"\nstep = "P3"\nkind = "informative"\nreading = "no change"\ncompared = "old and new text"\n'
    moved = '[[moved]]\nid = "TXT-0001"\nfrom = "P3"\nto = "P4"\nreason = "belongs to P4"\n'
    added, changed = '[units.added]\n"RUN-0001" = "P4"\n', '[units.changed]\n"RUN-0001" = "P4"\n'
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
    leaves = 'id = "TXT-0001"\nstep = "P3"\ntest = "tests/test_a.nim"\n'
    both = 'test "[RUN-0001] [TXT-0001] it holds":\n  check true\n'
    edited = tree("")
    (edited / BASELINE_FILE).write_text("# changed\n", encoding="utf-8")
    cases = [
        ("a deleted text entry fails", clean(frozen("", "[[text]]\n" + todo)), False),
        ("an entry on another sub-step fails", clean(frozen("[[text]]\n" + todo.replace("P3", "P4"), "[[text]]\n" + todo)), False),
        ("a recorded move passes", clean(frozen("[[text]]\n" + todo.replace("P3", "P4"), "[[text]]\n" + todo, moved)), True),
        ("a move away does not pass --step", clean(frozen("[[text]]\n" + todo.replace("P3", "P4"), "[[text]]\n" + todo), step="P3"), False),
        ("a behaviour entry cleared by reading fails", clean(frozen("", "[[text]]\n" + must, "[[text]]\n" + read)), False),
        ("a behaviour entry cannot be lowered", clean(frozen("[[text]]\n" + todo, "[[text]]\n" + must)), False),
        ("a todo entry cleared by reading passes", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read)), True),
        ("a reading without what was compared fails", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read.replace('compared = "old and new text"\n', ""))), False),
        ("a guarded reading without a site fails", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read)), False),
        ("a guarded entry cannot be informative", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read + 'site = "tests/test_a.nim:1"\n')), False),
        ("a guarded reading that holds passes", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read.replace("informative", "holds") + 'site = "tests/test_a.nim:1"\nnamed = "the rule"\n', tests=plain)), True),
        ("`holds` naming no real test fails", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read.replace("informative", "holds") + 'site = "tests/test_a.nim:1"\nnamed = "another rule"\n', tests=plain)), False),
        ("a guarded site outside the code fails", clean(frozen("", "[[text]]\n" + watch, "[[text]]\n" + read.replace("informative", "removed") + 'site = "spec/pins.toml"\n')), False),
        ("a stale id leaving with no record fails", clean(frozen("", '[stale]\n"RUN-0002" = "P4"\n')), False),
        ("a stale id leaving with a record passes", clean(frozen("", '[stale]\n"RUN-0002" = "P4"\n', '[[stale]]\nid = "RUN-0002"\ncompared = "replaced by RUN-0003"\n')), True),
        ("lowering with a decision row passes", clean(frozen("[[text]]\n" + todo, "[[text]]\n" + must, '[[lowered]]\nid = "TXT-0001"\ndecision = "G7"\n', files={"docs/DECISIONS.md": "### G7 on TXT-0001\n"})), True),
        ("a test under if false is no evidence", clean(frozen("", added, tests='if false:\n  test "[RUN-0001] x":\n    check true\n')), False),
        ("a test under an unknown define is no evidence", clean(frozen("", added, tests='when defined(neverSet):\n  test "[RUN-0001] x":\n    check true\n')), False),
        ("a test under a platform condition counts", clean(frozen("", added, tests='when defined(posix):\n  test "[RUN-0001] x":\n    check true\n')), True),
        ("a test that starts by skipping is no evidence", clean(frozen("", added, tests='test "[RUN-0001] x":\n  skip()\n  check true\n')), False),
        ("a body file no suite includes is no evidence", clean(frozen("", added, files={"tests/zz_body.nim": cites})), False),
        ("a body file a suite includes counts", clean(frozen("", added, tests="include zz_body\n", files={"tests/zz_body.nim": cites})), True),
        ("an unknown work item fails", clean(frozen('[deferred]\n"RUN-0001" = "9-9"\n', "", ruled, files=rows), ("deferred:tier-5", True)), False),
        ("a reading with no kind fails", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read.replace('kind = "informative"\n', ""))), False),
        ("`holds` outside the tests fails", clean(frozen("", "[[text]]\n" + todo, "[[text]]\n" + read.replace("informative", "holds") + 'site = "spec/pins.toml"\n')), False),
        ("a reword without its pair fails", clean(frozen("", "[[text]]\n" + todo + 'side = "new"\n', "[[text]]\n" + read.replace("informative", "reword"))), False),
        ("`removed` on a new sentence fails", clean(frozen("", "[[text]]\n" + todo + 'side = "new"\n', "[[text]]\n" + read.replace("informative", "removed"))), False),
        ("a unit leaving by its deferred section fails", clean(frozen("", added), ("deferred:tier-5", False)), False),
        ("a unit deferred by name with no decision fails", clean(frozen("", added), ("deferred:tier-5", True)), False),
        ("a unit deferred by name with a decision passes", clean(frozen("", added, ruled, files=rows), ("deferred:tier-5", True)), True),
        ("a decision row that does not exist fails", clean(frozen("", added, ruled), ("deferred:tier-5", True)), False),
        ("a decision row about another matter fails", clean(frozen("", added, ruled, files=other), ("deferred:tier-5", True)), False),
        ("a test inside a long string is no evidence", bool(text_tags(tree("", tests=quoted))), False),
        ("a test inside a block comment is no evidence", bool(text_tags(tree("", tests=commented))), False),
        ("a reword naming itself fails", clean(frozen("", "[[text]]\n" + todo + 'side = "new"\n', "[[text]]\n" + read.replace("informative", "reword") + 'pair = "TXT-0001"\n')), False),
        ("closing a sub-step before an earlier one fails", clean(frozen('closed = ["P2"]\n', "")), False),
        ("P7 may close before P6", clean(frozen('closed = ["P1", "P2", "P3", "P4", "P5", "P7"]\n', "")), True),
        ("a claimed unit with a test passes", clean(frozen("", added, tests=cites)), True),
        ("a claimed unit cited only in a comment fails", clean(frozen("", added, tests="# [RUN-0001]\n")), False),
        ("a test that only skips is no evidence", clean(frozen("", added, tests='test "[RUN-0001] x":\n  skip()\n')), False),
        ("a test under when false is no evidence", clean(frozen("", added, tests='when false:\n  test "[RUN-0001] x":\n    check true\n')), False),
        ("a changed unit with no record fails", clean(frozen("", changed, tests=cites)), False),
        ("a changed unit with a record passes", clean(frozen("", changed, record, tests=cites)), True),
        ("[deferred] without a named deferral fails", clean(frozen('[deferred]\n"RUN-0001" = "5-5"\n', ""), ("deferred:tier-5", False)), False),
        ("[deferred] with a named deferral and a decision passes", clean(frozen('[deferred]\n"RUN-0001" = "5-5"\n', "", ruled, files=rows), ("deferred:tier-5", True)), True),
        ("[deferred] with a vague owner fails", clean(frozen('[deferred]\n"RUN-0001" = "later"\n', "", ruled, files=rows), ("deferred:tier-5", True)), False),
        ("a text entry riding on a unit of its section passes", clean(frozen(rides, behind, ruled + rider, files=ledger), ("deferred:tier-5", True)), True),
        ("a text entry deferred with no rider record fails", clean(frozen(rides, behind, ruled, files=ledger), ("deferred:tier-5", True)), False),
        ("a text deferral with no decision row fails", clean(frozen(rides, behind, ruled + rider, files={**ledger, "docs/DECISIONS.md": "### G7 a decision on RUN-0001\n"}), ("deferred:tier-5", True)), False),
        ("a text entry riding on another section's unit fails", clean(frozen(rides, behind.replace("§1", "§2"), ruled + rider, files=ledger), ("deferred:tier-5", True)), False),
        ("a text entry riding on another work item's unit fails", clean(frozen(rides.replace('"TXT-0001" = "5-7a"', '"TXT-0001" = "5-7b"'), behind, ruled + rider, files=ledger), ("deferred:tier-5", True)), False),
        ("a deferred text entry leaving with its unit's test passes", clean(frozen("", behind, ruled + rider + "[[text]]\n" + leaves, tests=both, files=ledger)), True),
        ("a deferred text entry leaving by a test without its unit fails", clean(frozen("", behind, ruled + rider + "[[text]]\n" + leaves, tests=named, files=ledger)), False),
        ("a closed sub-step that owns an entry fails", clean(frozen('closed = ["P3"]\n[[text]]\n' + todo, "[[text]]\n" + todo)), False),
        ("a baseline mirror dropped from the configuration fails", clean(frozen("", '[mirror]\n"gone.cddl" = "P2"\n')), False),
        ("a baseline pin dropped from the pins fails", clean(frozen("", '[pin]\ngone = "P7"\n')), False),
        ("an edited baseline fails", not pending_findings(edited, digest="0" * 64, state=lambda uid: ("claimed", False)), False),
        ("every tag in a test name counts", text_tags(tree("", tests=two)).keys() == {"TXT-0001", "TXT-0002"}, True),
        ("a tag outside a test name does not count", bool(text_tags(tree("", tests='echo "[TXT-0001]"\n'))), False),
        ("another failure of a listed unit is not held", not split_deploydoc_failures(["l.1: BCP-0001 has no Answer"], Pending(deploydoc={"BCP-0001": "P9"}))[0], False),
        ("a listed mirror that differs is held", ok(cmd_mirror, tree('[mirror]\n"m.cddl" = "P2"\n', "a = 2\n")), True),
        ("an unlisted mirror that differs fails", ok(cmd_mirror, tree("", "a = 2\n")), False),
        ("a listed mirror that matches fails", ok(cmd_mirror, tree('[mirror]\n"m.cddl" = "P2"\n')), False),
        ("a listed pin that is gone is held", pins_ok(tree('[pin]\np = "P7"\n', pin="zzz")), True),
        ("an unlisted pin that is gone fails", pins_ok(tree("", pin="zzz")), False),
        ("a listed pin that is found fails", pins_ok(tree('[pin]\np = "P7"\n')), False),
        ("an untested added unit is held", not gate(Pending(added={"RUN-0001": "P4"}), []), True),
        ("an added unit with evidence fails", not gate(Pending(added={"RUN-0001": "P4"}), ["RUN-0001"]), False),
        ("a retired unit still cited is held", not gate(Pending(stale={"RUN-0002": "P4"}), ["RUN-0002"]), True),
        ("a stale entry nothing cites fails", not gate(Pending(stale={"RUN-0002": "P4"}), []), False),
        ("a stale entry for a live unit fails", not gate(Pending(stale={"RUN-0001": "P4"}), ["RUN-0001"]), False),
        ("a deferred unit that is not live fails", not gate(Pending(deferred={"RUN-0009": "5-7a"}), []), False),
        ("a deferred text entry is no unit of the gate", not gate(Pending(deferred={"TXT-0001": "5-7a"}), []), True),
        ("a listed deploydoc failure is held", not split_deploydoc_failures(fails, Pending(deploydoc={"BCP-0001": "P9"}))[0], True),
        ("a deploydoc entry that passes fails", not split_deploydoc_failures([], Pending(deploydoc={"BCP-0001": "P9"}))[0], False),
        ("an open text entry is well formed", not pending_findings(tree(entry)), True),
        ("a named test must move its entry", not pending_findings(tree(entry, tests=named)), False),
        ("--step reports what it still owns", not pending_findings(tree(entry), "P3"), False),
        ("a cleared entry names its test", not pending_findings(with_cleared(cleared, named)), True),
        ("a cleared entry without that test fails", not pending_findings(with_cleared(cleared, "")), False),
    ]
    failed = [name for name, got, want in cases if got != want]
    for name in failed:
        print(f"pending self-test: {name} went wrong")
    if not failed:
        print(f"pending self-test: {len(cases)} cases")
    return 1 if failed else 0


def cmd_pending(args) -> int:
    """The re-pin's pending list is well formed; with --step, that sub-step has cleared its entries."""
    if args.self_test:
        return pending_self_test()
    root = Path(args.root)
    findings = pending_findings(root, args.step, digest=BASELINE_SHA256)
    for f in findings:
        print(f)
    pending = load_pending(root)
    if args.step:
        # What the sub-step's review reads in one place.
        cleared = load_toml(root / CLEARED_FILE)
        for e in cleared.get("text", []):
            if e.get("step") == args.step and e.get("reading"):
                carrier = f" [carried by {e['carrier']}]" if e.get("carrier") else ""
                print(f"reading {e['id']}: compared {e.get('compared')}: {e['reading']}{carrier}")
        for m in cleared.get("moved", []):
            if args.step in (m.get("from"), m.get("to")):
                print(f"moved {m['id']}: {m.get('from')} to {m.get('to')}: {m.get('reason')}")
        records = {r.get("id"): r for r in cleared.get("units", [])}
        tests = list(real_tests(root))
        base = load_toml(root / BASELINE_FILE)
        reasons: dict[str, list[str]] = {}
        for extra in inspection_files(root):
            for item in load_toml(extra).get("item", []):
                for uid in item.get("ids", []):
                    reasons.setdefault(uid, []).append(str(item.get("reason", "")))
        for kind, now in (("added", pending.added), ("changed", pending.changed)):
            for uid, was in sorted(base.get("units", {}).get(kind, {}).items()):
                if was != args.step or uid in now:
                    continue
                record = records.get(uid, {})
                print(f"unit {uid} ({kind}): compared {record.get('compared', 'nothing recorded')}; decision {record.get('decision', 'none')}")
                for suite, name in tests:
                    if re.search(rf"\[{uid}\]", name):
                        print(f"  test {suite}: {name}")
                for reason in reasons.get(uid, []):
                    print(f"  inspection: {reason}")
        for r in cleared.get("stale", []):
            if base.get("stale", {}).get(r.get("id")) == args.step:
                print(f"stale {r.get('id')}: {r.get('compared')}")
        for e in cleared.get("text", []):
            if e.get("step") == args.step and e.get("test"):
                for suite, name in tests:
                    if suite == e["test"] and f"[{e['id']}]" in name:
                        print(f"text {e['id']}: {suite}: {name}")
    counts: dict[str, int] = {}
    for section in (pending.mirror, pending.pin, pending.added, pending.changed, pending.stale, pending.deploydoc):
        for step in section.values():
            counts[step] = counts.get(step, 0) + 1
    for entry in pending.text:
        counts[str(entry.get("step"))] = counts.get(str(entry.get("step")), 0) + 1
    by_step = ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) or "nothing open"
    print(f"{PENDING_FILE}: {by_step}; {len(pending.deferred)} deferred; {len(findings)} findings")
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
    n = sub.add_parser("pending", help="check the re-pin's pending list")
    n.add_argument("--step", help="fail if this sub-step still owns an entry")
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
