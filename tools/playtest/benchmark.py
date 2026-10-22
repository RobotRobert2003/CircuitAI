#!/usr/bin/env python
"""Benchmark tracker: turn a playtest run into a row of doc/benchmarks/tech-rush.md.

    python tools/playtest/benchmark.py record <run dir> --objective afus [--note "..."]
    python tools/playtest/benchmark.py show

A run dir is C:\\bardev\\barb-playtest\\runs\\<stamp>\\ (infolog.txt + report.md).
Milestones come from the camera widget's "[Playtest] finished <def> team 0 at
<min> min" lines, income from its "[Playtest] eco team 0 at <min> min" lines,
the objective from the AI's "[TECH][Chain] objective" line unless given.
Targets: the low end of the realistic range in the knowledge base's rush
table (77-eco-tech-player.md); floors are the simulator's.
"""
import argparse
import json
import os
import re
import sys
import uuid
from pathlib import Path

from benchmark_store import EVIDENCE_ROOT, require_checkout

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DOC = EVIDENCE_ROOT / "tech-rush.md"

# milestone -> (def names, target minutes, floor minutes)
MILESTONES = [
    ("T1 lab",      "armlab|corlab|leglab",                       2.5,  1.5),
    ("T2 lab",      "armalab|coralab|legalab",                    6.5,  5.4),
    ("T2 mex",      "armmoho|cormoho|legmoho",                    9.0,  7.6),
    ("fusion",      "armfus|corfus|legfus",                       11.5, 9.9),
    ("AFUS",        "armafus|corafus|legafus",                    18.0, 15.7),
    ("nuke silo",   "armsilo|corsilo|legsilo",                    16.5, 14.3),
    ("gantry",      "armshltx|corgant|leggant",                   16.0, 14.0),
    ("first T3",    "armbanth|corkorg|legkeres|armvang|corjugg|armthor|corshiva|armraz|corkarg|legpede|legeheatraymech|armmar|armlun|corcat|legjav", 26.0, 22.9),
]
OBJECTIVE_MILESTONE = {"t2": "T2 lab", "fusion": "fusion", "afus": "AFUS", "nuke": "nuke silo", "gantry": "gantry", "titan": "first T3"}

FIN_RE = re.compile(r"\[Playtest\] finished (\w+) team 0 at ([\d.]+) min")
ECO_RE = re.compile(r"\[Playtest\] eco team 0 at ([\d.]+) min: metal \+([\d.]+) bank (\d+)/(\d+), energy \+([\d.]+) bank (\d+)/(\d+), units (\d+)")
OBJ_RE = re.compile(r"\[TECH\]\[Chain\] objective (\w+)")
CHAIN_RE = re.compile(r"S:0:T:0:F:(\d+):L::\[TECH\]\[Chain\] (step \d+/\d+ \w+ \d+/\d+: \w[^|]*?) by ")
DLL_RE = re.compile(r"- DLL: .*?\((\w+)\)")


def mmss(minutes):
    if minutes is None:
        return "-"
    s = int(round(minutes * 60))
    return "%d:%02d" % (s // 60, s % 60)


def parse(run_dir):
    info = Path(run_dir) / "infolog.txt"
    text = info.read_text(encoding="utf-8", errors="replace")
    first = {}
    for m in FIN_RE.finditer(text):
        name, minute = m.group(1), float(m.group(2))
        for label, defs, target, floor in MILESTONES:
            if re.fullmatch(defs, name) and label not in first:
                first[label] = minute
    eco = [(float(m.group(1)), float(m.group(2)), float(m.group(5)), int(m.group(8))) for m in ECO_RE.finditer(text)]
    om = OBJ_RE.search(text)
    objective = om.group(1) if om else None
    steps = []
    for m in CHAIN_RE.finditer(text):
        s = "%s %s" % (mmss(int(m.group(1)) / 1800.0), m.group(2))
        if not steps or steps[-1][6:] != s[6:]:
            steps.append(s)
    last_frame = 0
    for m in re.finditer(r"\[f=(\d+)\]", text):
        last_frame = max(last_frame, int(m.group(1)))
    rep = Path(run_dir) / "report.md"
    dll = None
    if rep.exists():
        dm = DLL_RE.search(rep.read_text(encoding="utf-8", errors="replace"))
        dll = dm.group(1) if dm else None
    return dict(first=first, eco=eco, objective=objective, steps=steps, minutes=last_frame / 1800.0, dll=dll)


HEADER = """# TECH rush benchmarks

Goal: the TECH role reaches every rush milestone at or under the low end of
the realistic range (the knowledge base's rush table,
`rjm.bar.docs/knowledge/70-strategy/77-eco-tech-player.md`), on Supreme
Isthmus v1.7, zero bonus, tech versus tech, the rush chain (D-070) set to
the objective. Floors are the simulator's; a run is recorded by
`tools/playtest/benchmark.py record <run dir>` from a playtest.

| Milestone | Target | Floor |
| --- | ---: | ---: |
%s

Status per objective: the best run so far, updated by the tracker.

## Best so far

| Objective | Best time | Target | Met | Run |
| --- | ---: | ---: | --- | --- |
BEST_TABLE

## Runs

| Run | Objective | Game min | T1 lab | T2 lab | T2 mex | fusion | AFUS | nuke silo | gantry | first T3 | Metal at 5/10/15 | DLL | Note |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
""" % "\n".join("| %s | %s | %s |" % (l, mmss(t), mmss(f)) for l, d, t, f in MILESTONES)


def load_rows():
    if not DOC.exists():
        return []
    rows = []
    in_runs = False
    for line in DOC.read_text(encoding="utf-8").splitlines():
        if line.startswith("## Runs"):
            in_runs = True
            continue
        if in_runs and line.startswith("| ") and not line.startswith("| Run") and not line.startswith("| ---"):
            rows.append(line)
    return rows


def best_table(rows):
    best = {}
    for line in rows:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 12:
            continue
        run, objective = cells[0], cells[1]
        label = OBJECTIVE_MILESTONE.get(objective)
        if not label:
            continue
        idx = 3 + [l for l, _, _, _ in MILESTONES].index(label)
        val = cells[idx]
        if val == "-":
            continue
        mm, ss = val.split(":")
        minutes = int(mm) + int(ss) / 60.0
        if objective not in best or minutes < best[objective][0]:
            best[objective] = (minutes, run)
    out = []
    for objective, label in OBJECTIVE_MILESTONE.items():
        target = [t for l, _, t, _ in MILESTONES if l == label][0]
        if objective in best:
            minutes, run = best[objective]
            out.append("| %s | %s | %s | %s | %s |" % (objective, mmss(minutes), mmss(target), "yes" if minutes <= target else "no", run))
        else:
            out.append("| %s | - | %s | no run | |" % (objective, mmss(target)))
    return "\n".join(out)


def write(rows):
    DOC.parent.mkdir(parents=True, exist_ok=True)
    body = HEADER.replace("BEST_TABLE", best_table(rows)) + "\n".join(rows) + "\n"
    temporary = DOC.with_name(DOC.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(body, encoding="utf-8")
    os.replace(temporary, DOC)


def append_row(identifier, new_row):
    if DOC == EVIDENCE_ROOT / "tech-rush.md":
        require_checkout()
    DOC.parent.mkdir(parents=True, exist_ok=True)
    lock = DOC.with_name(DOC.name + '.lock')
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        raise RuntimeError('Rush ledger is being written; retry after its owner finishes: ' + str(lock)) from exc
    os.close(descriptor)
    try:
        rows = load_rows()
        previous = [r for r in rows if r.startswith("| %s |" % identifier)]
        if previous and previous != [new_row]:
            raise ValueError('Conflicting benchmark run ID; refusing to replace historical rows: ' + identifier)
        if not previous:
            rows.append(new_row)
            write(rows)
    finally:
        lock.unlink()


def record(args):
    run_dir = Path(args.run_dir)
    d = parse(run_dir)
    objective = args.objective or d["objective"] or "?"
    first = d["first"]
    eco_at = {}
    for minute, mi, ei, units in d["eco"]:
        eco_at[int(round(minute))] = mi
    metal = "/".join(str(int(eco_at.get(m, 0))) if m in eco_at else "-" for m in (5, 10, 15))
    cells = [run_dir.name, objective, "%.1f" % d["minutes"]]
    cells += [mmss(first.get(l)) for l, _, _, _ in MILESTONES]
    cells += [metal, d["dll"] or "-", args.note or ""]
    new_row = "| " + " | ".join(cells) + " |"
    append_row(run_dir.name, new_row)
    label = OBJECTIVE_MILESTONE.get(objective)
    target = next((t for l, _, t, _ in MILESTONES if l == label), None)
    got = first.get(label) if label else None
    verdict = "no milestone" if got is None else ("MET" if got <= target else "missed by %s" % mmss(got - target))
    print("run %s objective %s: %s at %s (target %s) -> %s" % (run_dir.name, objective, label, mmss(got), mmss(target), verdict))
    for l, _, _, _ in MILESTONES:
        if l in first:
            print("  %-10s %s" % (l, mmss(first[l])))
    if args.steps:
        for s in d["steps"]:
            print("  chain: " + s)
    return 0 if (got is not None and got <= target) else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("record"); p.add_argument("run_dir"); p.add_argument("--objective"); p.add_argument("--note"); p.add_argument("--steps", action="store_true")
    sub.add_parser("show")
    args = ap.parse_args()
    if args.cmd == "record":
        return record(args)
    print(DOC.read_text(encoding="utf-8") if DOC.exists() else "no benchmarks yet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
