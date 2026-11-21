#!/usr/bin/env python3
"""Measure each flake check's minutes in a CI run, for flake.nix's shard balance [IMPL].

    tools/ci_weights.py --run <run id> --checks <names.json> [--repo owner/name] [--cache DIR]
                        [--estimate <check>=<minutes>:<note> ...]

`--checks` is the JSON list of x86_64 Linux check names, from
`nix eval --json <flake>#checks.x86_64-linux --apply builtins.attrNames` (on the Mac through a
throwaway clone as `git+file://`, never `path:.`). Each job's log is fetched once with `gh api`
into `--cache` (build/ci-logs/<run id> by default) and read from there on later runs, so a finished
run's logs are downloaded once. The result goes to nix/ci-weights.json, whose `run` and `commit`
name the run it was measured on. Use a finished run (every job done, so its logs are complete);
a refresh is a new run id and its logs. The checks are those of the commit the shards will run, so a
check the run did not build gets its group's mean in flake.nix, or `--estimate`.

`--estimate` gives a check the run did not build its minutes, with a note on where they come from
(a check split out of one the run built, say); it is recorded in the file's `estimated`, and is an
error for a check the run measured.

A check's minutes are the time from its first to its last `<check>> ` line in the
`nix build -L` output of the x86_64 Linux job that built it. That is its build and test time while
it shared the runner with the job's other parallel builds. In a job cancelled at the time limit, a
check that reached neither its install phase nor a `Cannot build` error was cut: its minutes then
come from the aarch64 job, scaled by the group's x86_64/aarch64 ratio over the checks both finished,
or stay the minutes it ran when the aarch64 time is lower. A check in a failed job may have stopped early, so its minutes
can be low until a run that passes it.
"""

import argparse
import datetime
import json
import os
import re
import statistics
import subprocess
import sys

VARIANTS = ["asan", "tsan", "msan", "refc", "orc-release"]
LINE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z (\S+?)> ")
FAILED = re.compile(r"error: Cannot build '/nix/store/[0-9a-z]{32}-(\S+?)\.drv'")
JOB = re.compile(r"^nix \((ubuntu-latest|ubuntu-24\.04-arm), ([a-z-]+) \d+/\d+\)$")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "nix", "ci-weights.json")
ESTIMATE = re.compile(r"^([A-Za-z0-9_.+-]+)=(\d+(?:\.\d+)?):(.+)$")


def group_of(name):
    """flake.nix's `groupOf`: the variant a check's name ends in, else `orc-spec`."""
    for v in VARIANTS:
        if name.endswith("-" + v):
            return v
    return "orc-spec"


def stamp(text):
    return datetime.datetime.fromisoformat(text[:26])


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def job_log(repo, job, cache):
    path = os.path.join(cache, f"log-{job}.txt") if cache else None
    if path and os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, errors="replace") as f:
            return f.read()
    text = gh("api", f"repos/{repo}/actions/jobs/{job}/logs", "--allow-escape-sequences")
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    if path:
        with open(path, "w") as f:
            f.write(text)
    return text


def measure(text, checks):
    """Each check's minutes in one job log, and the checks that did not finish: no install phase and
    no `Cannot build` error (in a cancelled job, the ones the cancellation cut)."""
    first, last, phased, finished = {}, {}, set(), set()
    for line in text.splitlines():
        failed = FAILED.search(line)
        if failed and failed.group(1) in checks:
            finished.add(failed.group(1))
        m = LINE.match(line)
        if not m:
            continue
        t, drv = m.groups()
        if drv in checks:
            first.setdefault(drv, t)
            last[drv] = t
            if line.endswith("> Running phase: buildPhase"):
                phased.add(drv)
            elif line.endswith("> Running phase: installPhase"):
                finished.add(drv)
    minutes = {d: (stamp(last[d]) - stamp(first[d])).total_seconds() / 60 for d in first}
    # A check without stdenv's phases (a runCommand) cannot be judged; they take seconds.
    return minutes, phased - finished


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--run", required=True)
    ap.add_argument("--checks", required=True)
    ap.add_argument("--repo")
    ap.add_argument("--cache")
    ap.add_argument("--estimate", action="append", default=[])
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    a.cache = a.cache or os.path.join(ROOT, "build", "ci-logs", a.run)
    repo = a.repo or gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner").strip()
    with open(a.checks) as f:
        checks = set(json.load(f))
    os.makedirs(a.cache, exist_ok=True)
    given = {}
    for e in a.estimate:
        m = ESTIMATE.match(e)
        if not m or m.group(1) not in checks:
            sys.exit(f"--estimate {e}: expected <check>=<minutes>:<note> for a check in --checks")
        given[m.group(1)] = (float(m.group(2)), m.group(3))
    run = json.loads(gh("api", f"repos/{repo}/actions/runs/{a.run}"))
    jobs, page = [], 1
    while True:
        part = json.loads(gh("api", f"repos/{repo}/actions/runs/{a.run}/jobs?per_page=100&page={page}"))
        jobs += part["jobs"]
        if len(jobs) >= part["total_count"] or not part["jobs"]:
            break
        page += 1
    x86, arm, cut = {}, {}, set()
    for j in jobs:
        m = JOB.match(j["name"])
        if not m:
            continue
        minutes, unfinished = measure(job_log(repo, j["id"], a.cache), checks)
        if m.group(1) == "ubuntu-latest":
            x86.update(minutes)
            if j["conclusion"] == "cancelled":
                cut |= unfinished
        else:
            arm.update(minutes)
    weights, estimated = {}, {}
    for g in ["orc-spec"] + VARIANTS:
        names = [n for n in checks if group_of(n) == g]
        both = [(x86[n], arm[n]) for n in names if n in x86 and n in arm and n not in cut and arm[n] >= 0.5]
        ratio = sum(x for x, _ in both) / sum(y for _, y in both) if both else 1.0
        for n in names:
            if n in x86 and n not in cut:
                weights[n] = x86[n]
            elif n in arm:
                weights[n] = max(arm[n] * ratio, x86.get(n, 0.0))
                estimated[n] = f"aarch64 {arm[n]:.1f} x {ratio:.2f}" + (f"; cut at {x86[n]:.1f} on x86_64" if n in x86 else "")
            elif n in x86:
                weights[n] = x86[n]
                estimated[n] = "cut on x86_64: a lower bound"
            if n in given:
                if n in weights:
                    sys.exit(f"--estimate {n}: the run measured it ({weights[n]:.1f} minutes)")
                weights[n], estimated[n] = given[n]
    means = {}
    for g in ["orc-spec"] + VARIANTS:
        ws = [w for n, w in weights.items() if group_of(n) == g]
        means[g] = round(statistics.mean(ws), 1) if ws else 6.0
    out = {
        "comment": "Each x86_64 Linux check's minutes in CI run `run` (commit `commit`), for flake.nix's"
        " shard balance. Generated by tools/ci_weights.py (its header says how to refresh it); do not edit.",
        "run": int(a.run),
        "commit": run["head_sha"][:7],
        "minutes": {n: round(w, 1) for n, w in sorted(weights.items())},
        "groupMeans": means,
        "estimated": dict(sorted(estimated.items())),
    }
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    unmeasured = sorted(checks - set(weights))
    print(f"{len(weights)} checks measured, {len(estimated)} estimated, {len(unmeasured)} unmeasured"
          + (f" ({', '.join(unmeasured)})" if unmeasured else "") + f": {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
