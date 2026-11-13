#!/usr/bin/env python3
"""Requirement traceability for the Logos Core specs.

Extracts every normative unit of the twelve spec documents into a ledger with
stable IDs, keeps those IDs across spec revisions, mirrors the CDDL the code is
built from, checks pinned values, and gates test coverage per claimed section.

Ledger: conformance/requirements/<PFX>.jsonl, one JSON object per unit:
  id, kind, section, heading, line, fingerprint, text[, rule][, lang][, retired]
kind is one of:
  kw       a sentence, list item or table row with an uppercase BCP 14 keyword
  lc       one with a lowercase must/shall/should; informative, so not gated
           (every spec: lowercase forms keep their ordinary meaning; G117, B1)
  cddl     one CDDL rule, keyed by rule name
  block    any other fenced block (vectors, C declarations, examples)
  heading  a section heading (used for section coverage)
"""

from __future__ import annotations

import argparse
import difflib
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


# Ledger -------------------------------------------------------------------------


def ledger_path(root: Path, prefix: str) -> Path:
    return root / "conformance" / "requirements" / f"{prefix}.jsonl"


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


PINS_NIM = Path("src/logos_core/pins.nim")


def pins_nim(pins: dict, root: Path) -> str:
    """The Nim module holding the pins that carry a `code` name. A pin with a
    `mirror` is that mirror's whole text (a pinned document)."""
    out = [
        "## Generated by `spectrace pins --write` from spec/pins.toml. Do not edit: the",
        "## values are the spec's pinned identifiers and documents that code uses.",
        "",
        "#!fmt: off",
        "const",
    ]
    # The revision every ledger was synced to: generated headers carry it.
    revs = {json.loads(f.read_text(encoding="utf-8").split("\n", 1)[0])["rev"]
            for f in (root / "conformance" / "requirements").glob("*.jsonl")}
    if len(revs) != 1:
        raise SystemExit(f"the ledgers name {len(revs)} spec revisions; run `spectrace sync`")
    out.append("  # conformance/requirements/*.jsonl: the spec revision")
    out.append(f'  SpecRevision* = "{revs.pop()}"')
    for p in pins.values():
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
    if common:
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
    """Every pinned value must still appear in the section it is pinned from, and
    src/logos_core/pins.nim must be generated from the current pins."""
    root, specs = Path(args.root), Path(args.specs)
    pins = load_toml(root / "spec" / "pins.toml")
    bad = 0
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
    generated = pins_nim(pins, root)
    target = root / PINS_NIM
    if args.write:
        target.write_text(generated, encoding="utf-8")
    elif not target.exists() or target.read_text(encoding="utf-8") != generated:
        print(f"{PINS_NIM} is stale: run `spectrace pins --write`")
        bad += 1
    if bad:
        return 1
    print(f"checked {len(pins)} pins and {PINS_NIM}")
    return 0


# Coverage gate -------------------------------------------------------------------

TEST_ID_RE = re.compile(r"\[([A-Z]{3}-\d{4})\]")
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
    referenced: set[str] = set()
    for test in (root / "tests").rglob("*.nim"):
        referenced.update(TEST_ID_RE.findall(test.read_text(encoding="utf-8")))
    failures = 0
    inspected: dict[str, str] = {}
    for extra in sorted((root / "conformance" / "inspection").glob("*.toml")):
        for item in load_toml(extra).get("item", []):
            if not str(item.get("reason", "")).strip():
                print(f"{extra.name}: inspection item {item.get('ids')} has no reason")
                failures += 1
            referenced.update(item.get("ids", []))
            for i in item.get("ids", []):
                inspected.setdefault(i, extra.name)
    closed = {f"deferred:tier-{t}" for t in args.closed_tier}
    live_ids: set[str] = set()
    for fname, prefix in SPECS.items():
        claims = load_toml(root / "conformance" / "claims" / f"{prefix}.toml")
        bad_status = [
            s
            for s in [claims.get("default", "")]
            + list(claims.get("sections", {}).values())
            + list(claims.get("units", {}).values())
            if not STATUS_RE.fullmatch(s)
        ]
        if not claims or bad_status:
            print(f"{prefix}: missing claims file or invalid status {bad_status}")
            failures += 1
        # [W1] A closed tier has nothing deferred to it.
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
        for uid in sorted(set(claims.get("units", {})) - gated_ids):
            print(f"{prefix}: [units] names {uid}, which is not a live gated requirement")
            failures += 1
        by_status: dict[str, int] = {}
        by_label: dict[str, int] = {}
        for u in live:
            full = unit_status(claims, u)
            st = full.split(":")[0]
            by_status[st] = by_status.get(st, 0) + 1
            if st == "deferred":
                by_label[full] = by_label.get(full, 0) + 1
            # [W1] Inspection stands for a test, so it covers claimed units only.
            if u.id in inspected and full != "claimed":
                print(f"{prefix}: {u.id} is inspected ({inspected[u.id]}) but not claimed ({full})")
                failures += 1
        claimed = [u for u in live if unit_status(claims, u) == "claimed"]
        missing = [u for u in claimed if u.id not in referenced]
        summary = ", ".join(f"{v} {k}" for k, v in sorted(by_status.items()))
        print(f"{prefix}: {len(claimed) - len(missing)}/{len(claimed)} claimed units tested ({summary})")
        if by_label:
            print("  " + ", ".join(f"{k} {v}" for k, v in sorted(by_label.items())))
        for u in missing[: args.show]:
            print(f"  untested {u.id} ({u.section} l.{u.line}): {u.text[:100]!r}")
        failures += len(missing)
    stale = sorted(i for i in referenced if i[:3] in PREFIX_FILE and i not in live_ids)
    for i in stale:
        print(f"a test references unknown or retired requirement {i}")
    return 1 if failures or stale else 0


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
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
