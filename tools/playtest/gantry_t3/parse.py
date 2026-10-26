"""Builds <out>/RESULTS.md from the [GTest] widget lines and the TECH AIs' gantry log lines.
Also writes <out>/<map>/gantry-waits.txt: each TECH's [TECH][Gantry]/[GantryScale]/[T3Rush]/gantry order lines.
Usage: parse.py --out DIR (the directory run.py wrote)."""
import argparse
import json
import re
from pathlib import Path

FPS = 30


def clock(f):
    s = int(f) // FPS
    return "%d:%02d" % (s // 60, s % 60)


def infolog(d):
    runs = sorted((d / "runs").glob("*/infolog.txt"), key=lambda p: p.stat().st_mtime)
    return runs[-1] if runs else d / "infolog.txt"


def kv(line):
    return dict(re.findall(r"(\w+)=([^\s]+)", line))


def parse(d):
    if not (d / "bonus.json").exists() or not infolog(d).exists():
        return None
    meta = json.loads((d / "bonus.json").read_text())
    bonus = {int(k): v for k, v in meta["bonus"].items()}
    roles = {t["team"]: (t["role"], t["side"]) for t in meta["teams"]}
    log = infolog(d).read_text(encoding="utf-8", errors="replace").splitlines()
    gantries, order, roster, waits = {}, [], {}, {}
    last_frame = 0
    for line in log:
        m = re.search(r"\[f=(\d+)\]", line)
        if m:
            last_frame = max(last_frame, int(m.group(1)))
        r = re.search(r"\[Team\]\[Roster\] Team (\d+) \(AI \d+\): role=(\w+)", line)
        if r:
            roster[int(r.group(1))] = r.group(2)
        a = re.search(r"AI LOG:S:\d+:T:(\d+):F:(-?\d+):L::(\[TECH\]\[(?:Gantry|GantryScale|T3Rush)\].*"
                      r"|\[TECH\]\[Factories\].*gantry.*|\[TECH\]\[Factories\].*(?:corgant|armshltx|leggant).*)", line)
        if a:
            waits.setdefault(int(a.group(1)), []).append("%s f=%s %s" % (clock(max(0, int(a.group(2)))), a.group(2), a.group(3)))
        if "[GTest]" not in line:
            continue
        body = line.split("[GTest] ", 1)[1]
        k = kv(body)
        if body.startswith("PLACED"):
            gid = int(k["id"])
            gantries[gid] = dict(team=int(k["team"]), name=k["gantry"], placed=int(k["frame"]), income=float(k["metal_income"]))
            order.append(gid)
        elif body.startswith("FINISHED") and int(k["id"]) in gantries:
            g = gantries[int(k["id"])]
            g["finished"] = int(k["frame"])
            g["nanos"] = int(k["nanos"])
        elif body.startswith("NANOS14") and int(k["gantry_id"]) in gantries:
            gantries[int(k["gantry_id"])]["n14"] = int(k["after_finish_s"])
        elif body.startswith("NANOS20") and int(k["gantry_id"]) in gantries:
            gantries[int(k["gantry_id"])]["n20"] = int(k["after_finish_s"])
        elif body.startswith("FIRST_T3") and int(k["gantry_id"]) in gantries:
            g = gantries[int(k["gantry_id"])]
            g["first"] = int(k["frame"])
            g["unit"] = k["unit"]
        elif body.startswith("DESTROYED") and int(k["gantry_id"]) in gantries:
            gantries[int(k["gantry_id"])]["destroyed"] = body.split("t=")[1]
    tech = [t for t in sorted(roles) if roster.get(t, roles[t][0]) == "TECH"]
    with open(d / "gantry-waits.txt", "w", encoding="utf-8") as f:
        for t in tech:
            f.write("== team %d (%s, %s, +%s)\n" % (t, roster.get(t, roles[t][0]), roles[t][1], bonus.get(t)))
            for w in waits.get(t, []):
                f.write(w + "\n")
    speed = None
    rep = sorted((d / "runs").glob("*/report.md"), key=lambda p: p.stat().st_mtime)
    if rep:
        m = re.search(r"Game time reached: ([\d.]+) min \(frame \d+\); wall (\d+) s", rep[-1].read_text(encoding="utf-8", errors="replace"))
        if m:
            speed = (float(m.group(1)) * 60 / float(m.group(2)), m.group(1), m.group(2))
    return dict(bonus=bonus, roles=roles, roster=roster, tech=tech, gantries=[gantries[i] for i in order],
                waits=waits, last=last_frame, speed=speed)


def row(mp, g, r):
    team = g["team"]
    role = r["roster"].get(team, r["roles"][team][0])
    fin = clock(g["finished"]) if "finished" in g else "not finished"
    stop = "not by stop %s" % clock(r["last"])
    n14 = ("+%ds" % g["n14"]) if "n14" in g else (stop if "finished" in g else "-")
    n20 = ("+%ds" % g["n20"]) if "n20" in g else (stop if "finished" in g else "-")
    first = ("%s %s" % (clock(g["first"]), g["unit"])) if "first" in g else "none"
    if "destroyed" in g:
        first += " (gantry destroyed %s)" % g["destroyed"]
    return "| %s | %d %s/%s | +%s | %.0f | %s | %s | %s | %s | %s | %s |" % (
        mp, team, role, r["roles"][team][1], r["bonus"].get(team), g["income"], clock(g["placed"]), fin,
        g.get("nanos", "-"), n14, n20, first)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True, help="the directory run.py wrote")
    root = ap.parse_args().out
    out = ["# t3rush gantry test", "",
           "8v8, all 16 SMRTBARb (experimental_balanced), headless, random +50..+70 bonus per team. "
           "Nanos = finished construction turrets of that team within 600 elmos of the gantry. "
           "+14/+20 = seconds after the gantry finished.", "",
           "| Map | Team (role/side) | Bonus | Metal income at placement | Placed | Finished | Nanos at finish | +to 14 nanos | +to 20 nanos | First T3 |",
           "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    notes, late = [], []
    for d in sorted(p.parent for p in root.glob("*/bonus.json")):
        r = parse(d)
        if not r:
            continue
        mp = json.loads((d / "teams.json").read_text())["map"]
        seen = set()
        for g in r["gantries"]:
            out.append(row(mp, g, r))
            seen.add(g["team"])
        for t in r["tech"]:
            if t not in seen:
                out.append("| %s | %d TECH/%s | +%s | - | never | - | - | - | - | none (no gantry by %s) |" % (
                    mp, t, r["roles"][t][1], r["bonus"].get(t), clock(r["last"])))
        if r["speed"]:
            notes.append("- %s: %.1fx achieved (%s game min in %s s wall)" % (mp, *r["speed"]))
        # gantries placed above +175 (or never): their waiting lines
        for t in r["tech"]:
            w = [x for x in r["waits"].get(t, []) if re.search(r"wait|hold|not |cannot|no site|abort|due", x, re.I)]
            placed = [g for g in r["gantries"] if g["team"] == t]
            if not placed or placed[0]["income"] > 175:
                late.append("### %s team %d (+%s)\n\n%s\n\nLast waiting lines:\n\n```\n%s\n```\n" % (
                    mp, t, r["bonus"].get(t),
                    ("placed at income %.0f" % placed[0]["income"]) if placed else "no gantry placed",
                    "\n".join(w[-12:]) or "(none logged)"))
    out += ["", "## Speed", ""] + notes + ["", "## TECH gantries placed above +175 (or never) and their waiting lines", ""] + (late or ["none"])
    out += ["", "Raw logs: <map>/runs/*/infolog.txt; [GTest] lines from gantry_t3_watch.lua; per-TECH gantry lines in <map>/gantry-waits.txt."]
    (root / "RESULTS.md").write_text("\n".join(out) + "\n", encoding="utf-8")
    print("\n".join(out))


if __name__ == "__main__":
    main()
