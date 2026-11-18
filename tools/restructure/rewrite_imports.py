#!/usr/bin/env python3
"""Rewrites Nim imports and inspection citations after files move.

[IMPL] `tools/restructure/pathmap.toml` lists what moved. For every `.nim` file, a module path
that no longer resolves is resolved again from where the importing file used to be, and is spelled
for the file's place now. A path that crosses into the SDK from outside it becomes a package path,
inside the SDK it stays relative. The path citations of `conformance/inspection/*.toml` follow the
same map. Running it again changes nothing, so a branch that is in flight when a move lands can
run it after its rebase.

  python3 tools/restructure/rewrite_imports.py [--check] [--root DIR]

`--check` prints what it would change and exits 1 if there is anything.
"""

import argparse
import os
import re
import sys
import tomllib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lint"))
import layers  # noqa: E402


class PathMap:
    def __init__(self, data):
        self.moves = [(m["from"], m["to"]) for m in data.get("move", [])]
        self.package = data.get("package", {})

    def _map(self, path, pairs):
        best = None
        for old, new in pairs:
            hit = path == old or (old.endswith("/") and path.startswith(old))
            if hit and (best is None or len(old) > len(best[0])):
                best = (old, new)
        return path if best is None else best[1] + path[len(best[0]) :]

    def forward(self, path):
        """Where `path` is now, following every later move."""
        for _ in range(8):
            moved = self._map(path, self.moves)
            if moved == path:
                break
            path = moved
        return path

    def history(self, path):
        """`path`, and every place it was before."""
        places = [path]
        pairs = [(new, old) for old, new in self.moves]
        for _ in range(8):
            before = self._map(places[-1], pairs)
            if before == places[-1]:
                break
            places.append(before)
        return places


def in_sdk_sources(path, package):
    root = package.get("root")
    return bool(root) and path.startswith(root + "/")


def spelled(root, importer, module, target, written, package):
    """How `importer` names `target` now."""
    suffix = ".nim" if module.endswith(".nim") else ""
    name = package.get("name")
    if name and in_sdk_sources(target, package) and not in_sdk_sources(importer, package):
        return os.path.relpath(target, package["root"])[: -len(".nim")] + suffix
    if not written:
        return module
    relative = os.path.relpath(target, os.path.dirname(importer))[: -len(".nim")] + suffix
    return relative if relative.startswith("..") else "./" + relative


def respell(root, importer, module, paths):
    """The module path `importer` should write for `module`, which may be unchanged."""
    if module.startswith(("std/", "pkg/")):
        return module
    current = layers.resolve(root, importer, module)
    if current not in (None, "?"):
        return spelled(root, importer, module, current, False, paths.package)
    name = module if module.endswith(".nim") else module + ".nim"
    bases = [os.path.dirname(place) for place in paths.history(importer)]
    if not module.startswith("."):
        bases += list(layers.SEARCH_PATHS)
    for base in bases:
        target = paths.forward(os.path.normpath(os.path.join(base, name)))
        if os.path.isfile(os.path.join(root, target)):
            return spelled(root, importer, module, target, True, paths.package)
    if module.startswith("."):
        raise SystemExit(f"{importer}: {module} resolves neither now nor before the move")
    return module


def split_group(entry, news):
    """The members of a bracket group that no longer share a directory, one item per directory."""
    groups = {}
    for new, member in zip(news, entry["members"]):
        prefix, _, leaf = new.rpartition("/")
        groups.setdefault(prefix, []).append(leaf if new.endswith("/" + member[0]) else new)
    items = []
    for prefix, leaves in groups.items():
        if len(leaves) == 1:
            items.append(f"{prefix}/{leaves[0]}")
        else:
            items.append(f"{prefix}/[{', '.join(leaves)}]")
    return ", ".join(items)


def rewritten_source(root, importer, text, paths):
    edits = []
    for statement in layers.statements(text):
        for entry in statement["items"]:
            if "members" not in entry:
                new = respell(root, importer, entry["path"], paths)
                if new != entry["path"]:
                    edits.append((entry["start"], entry["end"], new))
                continue
            news = [respell(root, importer, entry["path"] + m[0], paths) for m in entry["members"]]
            if all(new == entry["path"] + m[0] for new, m in zip(news, entry["members"])):
                continue
            prefixes = [
                new[: -len(m[0])] if new.endswith("/" + m[0]) else None
                for new, m in zip(news, entry["members"])
            ]
            if None not in prefixes and len(set(prefixes)) == 1:
                edits.append((entry["start"], entry["prefix_end"], prefixes[0]))
            elif statement["kind"] == "from" or any(m[3] for m in entry["members"]):
                raise SystemExit(f"{importer}:{entry['line']}: split this group by hand")
            else:
                edits.append((entry["start"], entry["end"], split_group(entry, news)))
    for start, end, new in sorted(edits, reverse=True):
        text = text[:start] + new + text[end:]
    return text


def rewritten_citations(text, paths):
    """`text` with each moved path spelled for where it is now. A path is matched only where it
    starts, so one that moved under a longer prefix is not moved again."""
    for old, new in sorted(paths.moves, key=lambda m: -len(m[0])):
        text = re.sub(r"(?<![\w./-])" + re.escape(old), lambda _: new, text)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--root", default=".")
    here = os.path.dirname(os.path.abspath(__file__))
    parser.add_argument("--map", default=os.path.join(here, "pathmap.toml"))
    args = parser.parse_args()
    with open(args.map, "rb") as f:
        paths = PathMap(tomllib.load(f))
    changed = []
    for path in layers.nim_files(args.root):
        full = os.path.join(args.root, path)
        with open(full, encoding="utf-8") as f:
            text = f.read()
        new = rewritten_source(args.root, path, text, paths)
        if new != text:
            changed.append(path)
            if not args.check:
                with open(full, "w", encoding="utf-8") as f:
                    f.write(new)
    inspection = os.path.join(args.root, "conformance", "inspection")
    if os.path.isdir(inspection):
        for name in sorted(os.listdir(inspection)):
            full = os.path.join(inspection, name)
            if not name.endswith(".toml"):
                continue
            with open(full, encoding="utf-8") as f:
                text = f.read()
            new = rewritten_citations(text, paths)
            if new != text:
                changed.append(os.path.relpath(full, args.root))
                if not args.check:
                    with open(full, "w", encoding="utf-8") as f:
                        f.write(new)
    for path in changed:
        print(path)
    print(f"rewrite_imports: {len(changed)} files {'would change' if args.check else 'changed'}")
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    sys.exit(main())
