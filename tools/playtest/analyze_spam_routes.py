"""Check that spam units keep their lane until 150 elmos of their final move order.

python tools/playtest/analyze_spam_routes.py <infolog.txt> [--radius 150] [--json out.json]

Joins the AI's per-unit hand-backs ([SpamRelease], systems/combat/spam.as) with the
queue the unit was actually carrying, read independently by the test widget
(tools/playtest/widgets/spam_route_watch.lua, [SpamWatch]). For every hand-back:
the distance from the unit to the LAST MOVE of its route queue must be within the
radius. Also counts units that left a route queue with no hand-back (another task
took them), walk-backs (a queue restarted behind the unit), AI adoptions of units
found off their lane ([SpamAdopt], by the task that held them) and INV-043.
Only units the AI put on a lane ([SpamJoin]) are judged. Exit 1 when any hand-back
is further out than the radius, a lane unit left its route queue for non-MOVE
orders without a hand-back, or a lane unit was sent back more than 300 elmos to a
waypoint it had passed.
"""
import argparse, json, math, re, sys
from collections import Counter, defaultdict

ai_line = re.compile(r":::AI LOG:S:\d+:T:(\d+):F:(\d+):L::(.*)")
release = re.compile(r"\[SpamRelease\] unit=(\d+) def=(\S+) lane=(\S+) pos=\((-?\d+),(-?\d+)\)")
adopt = re.compile(r"\[SpamAdopt\] unit=(\d+) def=(\S+) from task (\S+) pos=\((-?\d+),(-?\d+)\)")
watch = re.compile(r"\[SpamWatch\] f=(\d+) unit=(\d+) team=(\d+) def=(\S+) kind=(\w+) n=(\d+) pos=\((-?\d+),(-?\d+)\) goal=\((-?\d+),(-?\d+)\) dist=(-?\d+)")
regress = re.compile(r"\[SpamWatch\] regress f=(\d+) unit=(\d+) team=(\d+) def=(\S+) pos=\((-?\d+),(-?\d+)\) goal=\((-?\d+),(-?\d+)\) first=\((-?\d+),(-?\d+)\)")
join = re.compile(r"\[SpamJoin\] unit=(\d+) def=(\S+) lane=(\S+)")
census = re.compile(r"\[SpamWatch\] census f=(\d+) route=(\d+) other=(\d+) empty=(\d+)")
lane_end = re.compile(r"\[Spam\] lane (\S+) ends at \((-?\d+),(-?\d+)\); enemy corner \((-?\d+),(-?\d+)\)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--radius", type=float, default=150.0)
    ap.add_argument("--json")
    a = ap.parse_args()

    releases, adopts, regresses, censuses, invs, corners = [], [], [], [], [], defaultdict(list)
    joined = {}   # unit -> (frame it joined a spam lane, lane)
    history = defaultdict(list)   # unit -> [(frame, kind, gx, gz, x, z)]
    installed = False
    with open(a.log, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "[SpamWatch] installed" in line:
                installed = True
            m = ai_line.search(line)
            if m:
                team, frame, msg = int(m.group(1)), int(m.group(2)), m.group(3)
                r = release.search(msg)
                if r:
                    releases.append(dict(team=team, frame=frame, unit=int(r.group(1)), def_=r.group(2), lane=r.group(3),
                                         x=int(r.group(4)), z=int(r.group(5))))
                    continue
                r = join.search(msg)
                if r:
                    joined.setdefault(int(r.group(1)), (frame, r.group(3)))
                    continue
                r = adopt.search(msg)
                if r:
                    adopts.append(dict(team=team, frame=frame, unit=int(r.group(1)), source=r.group(3)))
                    continue
                if "INV-043" in msg:
                    invs.append((team, frame, msg.strip()))
                    continue
                r = lane_end.search(msg)
                if r:
                    corners[team].append((int(r.group(4)), int(r.group(5))))
                continue
            r = regress.search(line)
            if r:
                regresses.append(dict(frame=int(r.group(1)), unit=int(r.group(2)), team=int(r.group(3)), def_=r.group(4),
                                      pos=(int(r.group(5)), int(r.group(6))), first=(int(r.group(9)), int(r.group(10)))))
                continue
            r = watch.search(line)
            if r:
                history[int(r.group(2))].append((int(r.group(1)), r.group(5), int(r.group(9)), int(r.group(10)),
                                                 int(r.group(7)), int(r.group(8))))
                continue
            r = census.search(line)
            if r:
                censuses.append(tuple(int(g) for g in r.groups()))

    if not installed:
        print("FAIL: the spam_route_watch widget never reported (not staged or not loaded)")
        return 1

    # every hand-back against the final move order the widget last saw on that unit
    released_at = defaultdict(list)
    rows, far, unseen = [], [], 0
    for rel in releases:
        released_at[rel["unit"]].append(rel["frame"])
        goal = None
        for frame, kind, gx, gz, x, z in history.get(rel["unit"], []):
            if frame > rel["frame"]:
                break
            if kind == "route" and gx >= 0:
                goal = (gx, gz)
        if goal is None:
            unseen += 1
            continue
        d = math.hypot(rel["x"] - goal[0], rel["z"] - goal[1])
        corner = min((math.hypot(goal[0] - cx, goal[1] - cz) for cx, cz in corners.get(rel["team"], [])), default=-1)
        row = dict(rel, goal=goal, dist=round(d), goal_to_enemy_corner=round(corner))
        rows.append(row)
        if d > a.radius + 1.0:
            far.append(row)

    # a lane unit's route queue -> non-MOVE orders, between joining its lane and its
    # hand-back (2 s slack): another task took it off the lane
    taken, retargets = [], 0
    for unit, h in history.items():
        if unit not in joined:
            continue   # never on a spam lane (an opener raider, a unit before spam started)
        start = joined[unit][0]
        rel = released_at.get(unit, [])
        for i in range(1, len(h)):
            pf, pk, pgx, pgz, _, _ = h[i - 1]
            f, k, gx, gz, x, z = h[i]
            if pf < start:
                continue
            near_release = any(abs(f - rf) <= 60 or (rf <= f) for rf in rel)
            if pk == "route" and k == "other" and not near_release:
                taken.append(dict(unit=unit, frame=f, pos=(x, z), goal=(pgx, pgz)))
            elif pk == "route" and k == "route" and not near_release and f > start + 150:
                retargets += 1   # (the first 5 s: factory exit move, then the lane's own queue)

    # walk-backs while the unit was on its lane: how far behind it the restarted queue began
    lane_walk_backs = []
    for r in regresses:
        if r["unit"] not in joined or r["frame"] < joined[r["unit"]][0]:
            continue
        if any(rf <= r["frame"] for rf in released_at.get(r["unit"], [])):
            continue
        r["back"] = round(math.hypot(r["pos"][0] - r["first"][0], r["pos"][1] - r["first"][1]))
        lane_walk_backs.append(r)
    long_walk_backs = [r for r in lane_walk_backs if r["back"] > 300]
    backs = sorted(r["back"] for r in lane_walk_backs)

    lanes = Counter(r["lane"] == "edge" for r in rows)
    dists = sorted(r["dist"] for r in rows)
    out = dict(
        hand_backs=len(releases), checked=len(rows), unseen=unseen,
        hand_backs_edge=lanes.get(True, 0), hand_backs_pump=lanes.get(False, 0),
        max_dist=dists[-1] if dists else None, median_dist=dists[len(dists) // 2] if dists else None,
        beyond_radius=len(far), taken_off_route=len(taken), final_goal_changes=retargets,
        lane_units=len(joined), lane_units_edge=sum(1 for v in joined.values() if v[1] == "edge"),
        walk_backs=len(lane_walk_backs), walk_backs_over_300=len(long_walk_backs),
        walk_back_median=backs[len(backs) // 2] if backs else None, walk_back_max=backs[-1] if backs else None, adoptions=len(adopts), adopted_from=dict(Counter(x["source"] for x in adopts)),
        inv_043=len(invs), watched_units=len(history),
        at_enemy_corner=sum(1 for r in rows if 0 <= r["goal_to_enemy_corner"] <= 300),
        last_census=censuses[-1] if censuses else None,
    )
    print(json.dumps(out, indent=1))
    for r in far[:10]:
        print("BEYOND", r)
    for t in taken[:10]:
        print("TAKEN", t)
    for r in long_walk_backs[:10]:
        print("WALKBACK", r)
    for t in invs[:5]:
        print("INV", t)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(dict(summary=out, beyond=far, taken=taken, walk_backs=lane_walk_backs), f, indent=1)
    return 1 if (far or taken or long_walk_backs) else 0


if __name__ == "__main__":
    sys.exit(main())
