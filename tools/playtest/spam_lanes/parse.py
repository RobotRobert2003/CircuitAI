"""Prints and writes <out>/RESULTS.md: every spam lane the AIs planned (edge lanes, pump
lanes, gantry routes) and the paths their units actually walked (lane_trail_watch.lua).

A unit reaches waypoint k when its trail comes within --radius of it after reaching
waypoint k-1 (per-unit lane offsets are up to ~320 elmos). Units are tied to lanes by the
AI's [SpamJoin] lines; gantry units (no join line) go to their team's gantry route.

Usage: parse.py --out DIR [--radius 450]"""
import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path

AI = re.compile(r":::AI LOG:S:\d+:T:(\d+):F:(-?\d+):L::(.*)")
PT = re.compile(r"\((-?\d+),(-?\d+)\)")
EDGE = re.compile(r"\[EdgeLanes\] (left|right) lane (?:lab site .*?; rally|route from .*?; rally)(.*)")
ROUTE = re.compile(r"\[Spam\] Route created for factory (\d+) lane (-?\d+) .*?; waypoints(.*)")
SPREAD = re.compile(r"\[Spam\] factory (\d+) runs spread lane .*?; waypoints(.*)")
GANTRY = re.compile(r"\[GantryFallback\] gantry (\d+) waypoints: the (left|right) edge lane, \d+ points(.*)")
EDGELAB = re.compile(r"\[EdgeLanes\] repeat factory=(\d+) ")
RIM = re.compile(r"\[Spam\] lane (\S+) ends at .*")
JOIN = re.compile(r"\[SpamJoin\] unit=(\d+) def=(\S+) lane=(\S+)")
RELEASE = re.compile(r"\[SpamRelease\] unit=(\d+) def=(\S+) lane=(\S+) pos=\((-?\d+),(-?\d+)\)")
TRAIL = re.compile(r"\[LaneTrail\] unit=(\d+) team=(\d+) def=(\S+) born=(\d+) last=(\d+) why=(\w+) n=\d+ pts=(\S+)")
SPAM = {"armpw", "corak", "leggob", "armflash", "corgator", "leghades"}


def clock(f):
    s = int(f) // 30
    return "%d:%02d" % (s // 60, s % 60)


def pts(text):
    return [(int(x), int(z)) for x, z in PT.findall(text)]


def infolog(d):
    runs = sorted((d / "runs").glob("*/infolog.txt"), key=lambda p: p.stat().st_mtime)
    return runs[-1] if runs else None


def progress(trail, plan, radius):
    """Waypoints reached in order, and the trail index where each was reached."""
    r2, i, at = radius * radius, 0, []
    for k, (x, z) in enumerate(trail):
        while i < len(plan) and (x - plan[i][0]) ** 2 + (z - plan[i][1]) ** 2 <= r2:
            at.append(k)
            i += 1
        if i == len(plan):
            break
    return i, at


def thin(trail, n=24):
    if len(trail) <= n:
        return trail
    step = (len(trail) - 1) / (n - 1)
    return [trail[round(i * step)] for i in range(n)]


def text(ps):
    return " ".join("(%d,%d)" % p for p in ps)


def load(d):
    """Everything one game's infolog says about its lanes; None without a log."""
    log = infolog(d)
    if log is None:
        return None
    roles = {}
    tj = d / "teams.json"
    if tj.exists():
        roles = {t["team"]: "%s/%s" % (t["role"], t["side"]) for t in json.loads(tj.read_text())["teams"]}
    plans = {}            # (team, key) -> {"kind", "pts", "frame", "side"}
    rimnotes = defaultdict(list)
    edgelabs = set()      # (team, factory id) of edge lane labs
    joins = {}            # unit -> (team, key)
    released = {}         # unit -> (lane, x, z, frame)
    trails = {}           # unit -> dict
    mapname = d.name
    end_frame = 0
    for line in log.open(encoding="utf-8", errors="replace"):
        if "MapName" in line and mapname == d.name:
            m = re.search(r"MapName=([^;]+);", line)
            if m:
                mapname = m.group(1)
        t = TRAIL.search(line)
        if t:
            trails[int(t.group(1))] = dict(team=int(t.group(2)), def_=t.group(3), born=int(t.group(4)), last=int(t.group(5)),
                                           why=t.group(6), pts=[tuple(map(int, p.split(","))) for p in t.group(7).split(";")])
            end_frame = max(end_frame, int(t.group(5)))
            continue
        a = AI.search(line)
        if not a:
            continue
        team, frame, msg = int(a.group(1)), int(a.group(2)), a.group(3)
        m = EDGE.search(msg)
        if m:
            plans[(team, "edge")] = dict(kind="edge " + m.group(1), pts=pts(m.group(2)), frame=frame)
            continue
        m = ROUTE.search(msg) or SPREAD.search(msg)
        if m:
            plans[(team, m.group(1))] = dict(kind="pump", pts=pts(m.groups()[-1]), frame=frame)
            continue
        m = EDGELAB.search(msg)
        if m:
            edgelabs.add((team, m.group(1)))
            continue
        m = GANTRY.search(msg)
        if m:
            plans[(team, "gantry " + m.group(1))] = dict(kind="gantry (%s edge lane)" % m.group(2), pts=pts(m.group(3)), frame=frame)
            continue
        m = RIM.search(msg)
        if m:
            rimnotes[(team, m.group(1))].append(msg)
            continue
        m = JOIN.search(msg)
        if m:
            joins.setdefault(int(m.group(1)), (team, m.group(3)))
            continue
        m = RELEASE.search(msg)
        if m:
            released[int(m.group(1))] = (m.group(3), int(m.group(4)), int(m.group(5)), frame)
    # an edge lab's units join lane=edge; its "Route created" line (factory id) is the same route
    for k in edgelabs:
        plans.pop(k, None)
    units = defaultdict(list)
    for u, (team, key) in joins.items():
        units[(team, key)].append(u)
    for u, tr in trails.items():
        if tr["def_"] in SPAM or u in joins:
            continue
        g = [k for k in plans if k[0] == tr["team"] and k[1].startswith("gantry")]
        if g:
            units[g[0]].append(u)
    return dict(log=log, roles=roles, plans=plans, rimnotes=rimnotes, units=units, trails=trails, released=released,
                mapname=mapname, end_frame=end_frame)


def parse(d, radius):
    g = load(d)
    if g is None:
        return None
    log, roles, plans, rimnotes, units, trails, released, mapname, end_frame = (
        g["log"], g["roles"], g["plans"], g["rimnotes"], g["units"], g["trails"], g["released"], g["mapname"], g["end_frame"])
    out = ["## %s" % mapname, "", "Log: `%s`; trails to %s." % (log, clock(end_frame)), ""]
    summary = []
    for (team, key) in sorted(plans, key=lambda k: (k[0], k[1])):
        p = plans[(team, key)]
        plan = p["pts"]
        us = units.get((team, key), [])
        walked = [(u, trails[u]) for u in us if u in trails]
        reach = [0] * (len(plan) + 1)
        best, bestk = None, -1
        for u, tr in walked:
            k, _ = progress(tr["pts"], plan, radius)
            for i in range(k + 1):
                reach[i] += 1
            if k > bestk or (k == bestk and best and len(tr["pts"]) > len(best[1]["pts"])):
                best, bestk = (u, tr), k
        rel = sum(1 for u in us if u in released)
        out.append("### team %d %s, %s lane %s (planned %s)" % (team, roles.get(team, "?"), p["kind"], key, clock(max(0, p["frame"]))))
        out.append("")
        out.append("- planned %d waypoints: %s" % (len(plan), text(plan)))
        if len(plan) >= 2 and p["kind"] != "gantry":
            out.append("- return leg (last two): %s" % text(plan[-2:]))
        out.append("- units joined %d, with a trail %d, released at the lane end %d" % (len(us), len(walked), rel))
        out.append("- reached waypoint 1..%d in order: %s" % (len(plan), ", ".join(str(reach[i]) for i in range(1, len(plan) + 1))))
        if best:
            u, tr = best
            out.append("- furthest unit %d (%s, %s, born %s, %s at %s) reached %d of %d; walked: %s"
                       % (u, tr["def_"], "released" if u in released else "not released", clock(tr["born"]), tr["why"],
                          clock(tr["last"]), bestk, len(plan), text(thin(tr["pts"]))))
        for n in rimnotes.get((team, "edge" if key == "edge" else key), [])[-1:]:
            out.append("- AI: `%s`" % n)
        out.append("")
        summary.append((mapname, team, key, p["kind"], len(plan), len(walked), reach[len(plan)] if plan else 0,
                        reach[len(plan) - 1] if len(plan) > 1 else 0))
    return out, summary


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--radius", type=float, default=450)
    a = ap.parse_args()
    body, rows = [], []
    for d in sorted(p for p in a.out.iterdir() if p.is_dir()):
        r = parse(d, a.radius)
        if r:
            body += r[0]
            rows += r[1]
    head = ["# Spam lane test", "", "Reach radius %d elmos. Per lane: waypoints planned, units with a trail, units that reached "
            "the penultimate and the final waypoint in order." % a.radius, "",
            "| Map | Team | Lane | Kind | Waypoints | Units | Reached penultimate | Reached final |", "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    head += ["| %s | %d | %s | %s | %d | %d | %d | %d |" % (m, t, k, kind, n, w, pen, fin) for m, t, k, kind, n, w, fin, pen in rows]
    text_ = "\n".join(head + [""] + body) + "\n"
    (a.out / "RESULTS.md").write_text(text_, encoding="utf-8")
    print(text_)


if __name__ == "__main__":
    main()
