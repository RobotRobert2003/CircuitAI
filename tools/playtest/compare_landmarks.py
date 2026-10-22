#!/usr/bin/env python3
"""Compare the field's position jobs (landmarks.txt) with two references.

Part B1 validation (rjm.bar.docs/projects/circuitai/field-landmarks-proposal.md,
section 11): for every computed position, the nearest spawn point of

1. BAR's maps-metadata (`map_list.yaml`, the `startPos` roles the game's own
   start-position widget shows: front, tech, air, sea, front/tech), and
2. our hand-authored StartSpot table (`data/script/src/maps/*.as`, AiRole),

within --radius elmos, and whether the job agrees. front/tech agrees with
front, tech and front/tech. Our AiRole is mapped to the game's words
(FRONT front, TECH tech, AIR air, SEA sea, SUPPORT and TACTICAL have no word
and are reported, not scored). No game is needed: the metadata file is
downloaded once from github.com/beyond-all-reason/maps-metadata.

    python tools/playtest/compare_landmarks.py --metadata map_list.yaml landmarks.txt [more landmarks.txt]

Prints one table per file and a total; exit 0 always (a report, not a gate).
PyYAML is not required: the startPos block is read by indentation.
"""
import argparse
import glob
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROLE_WORD = {"FRONT": "front", "TECH": "tech", "AIR": "air", "SEA": "sea"}


def read_landmarks(path):
    out = {"map": None, "positions": []}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            f = line.rstrip("\n").split("|")
            if f[0] == "barbmarks" and len(f) > 2:
                out["map"] = f[2]
            elif f[0] == "position" and len(f) >= 13:
                out["positions"].append({"name": f[2], "ally": int(f[3]), "x": float(f[5]), "z": float(f[6]),
                                         "source": f[7], "label": f[8], "sub": f[9]})
            elif f[0] == "opening" and len(f) >= 3:
                idx = int(f[1])
                if idx < len(out["positions"]):
                    out["positions"][idx]["opening"] = f[2]
    return out


def metadata_spawns(path, map_name, players):
    """Spawn points {name: (x, z, role)} of the team layout with `players` per team."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "springName: " + map_name:
            start = i
            break
    if start is None:
        return {}
    # the entry spans from the previous top-level key to the next one
    lo = start
    while lo > 0 and not re.match(r"^\S", lines[lo]):
        lo -= 1
    hi = start + 1
    while hi < len(lines) and not re.match(r"^\S", lines[hi]):
        hi += 1
    block = lines[lo:hi]
    pos, roles = {}, {}
    i = 0
    while i < len(block):
        if block[i].strip() == "positions:":
            base = len(block[i]) - len(block[i].lstrip())
            j = i + 1
            while j < len(block) and (len(block[j]) - len(block[j].lstrip())) > base:
                m = re.match(r"^\s+(\S+):\s*$", block[j])
                if m and j + 2 < len(block):
                    mx = re.match(r"^\s+x:\s*(-?[\d.]+)", block[j + 1])
                    my = re.match(r"^\s+y:\s*(-?[\d.]+)", block[j + 2])
                    if mx and my:
                        pos[m.group(1)] = (float(mx.group(1)), float(my.group(1)))
                j += 1
            i = j
            continue
        m = re.match(r"^\s+- playersPerTeam:\s*(\d+)", block[i])
        if m and int(m.group(1)) == players:
            base = len(block[i]) - len(block[i].lstrip())
            j = i + 1
            role = None
            while j < len(block) and (len(block[j]) - len(block[j].lstrip())) > base:
                mr = re.match(r"^\s+-?\s*role:\s*(\S+)", block[j])
                ms = re.match(r"^\s+-?\s*spawnPoint:\s*(\S+)", block[j])
                if mr:
                    role = mr.group(1)
                if ms and role:
                    roles[ms.group(1)] = role
                    role = None
                j += 1
            break
        i += 1
    return {k: (v[0], v[1], roles.get(k)) for k, v in pos.items()}


def our_spawns(map_name):
    """{index: (x, z, word)} from the StartSpot table whose MapConfig name prefixes the map."""
    for path in sorted(glob.glob(os.path.join(ROOT, "data", "script", "src", "maps", "*.as"))):
        text = open(path, encoding="utf-8", errors="replace").read()
        m = re.search(r'MapConfig\("([^"]*)"', text)
        if not m or not m.group(1) or not map_name.startswith(m.group(1)):
            continue
        out = {}
        for k, s in enumerate(re.finditer(r"StartSpot\(AIFloat3\(\s*(-?[\d.]+)\s*,\s*-?[\d.]+\s*,\s*(-?[\d.]+)\s*\)\s*,\s*AiRole::(\w+)", text)):
            out[k] = (float(s.group(1)), float(s.group(2)), ROLE_WORD.get(s.group(3), s.group(3).lower()))
        return out, os.path.basename(path)
    return {}, None


# Build Atlas's finer words for slots the five-word metadata calls front or
# front/tech: scored as "refines", neither agreement nor disagreement
REFINES = {"pond": {"front", "front/tech", "tech"}, "geo": {"front", "front/tech", "tech"}}


def agrees(ours, theirs):
    """True, False, "refines" or None (nothing to compare)."""
    if theirs is None:
        return None
    if ours == theirs:
        return True
    if "front/tech" in (ours, theirs) and {ours, theirs} <= {"front/tech", "front", "tech"}:
        return True
    if theirs in REFINES.get(ours, ()):
        return "refines"
    return False


def nearest(p, spawns, radius):
    best, bd = None, radius
    for key, (x, z, role) in spawns.items():
        d = math.hypot(x - p["x"], z - p["z"])
        if d <= bd:
            best, bd = key, d
    return best, bd


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--metadata", required=True, help="maps-metadata map_list.yaml")
    ap.add_argument("--radius", type=float, default=575.0, help="match radius, elmos (BAR start guesser claim radius)")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    total = {"meta": [0, 0, 0], "ours": [0, 0, 0]}
    for path in a.files:
        lm = read_landmarks(path)
        n = len(lm["positions"])
        sides = {}
        for p in lm["positions"]:
            sides[p["ally"]] = sides.get(p["ally"], 0) + 1
        players = max(sides.values()) if sides else 0
        meta = metadata_spawns(a.metadata, lm["map"], players)
        ours, ours_file = our_spawns(lm["map"])
        print("## %s (%d positions, %d per side)" % (lm["map"], n, players))
        print("metadata spawns: %d with roles; our map file: %s" % (sum(1 for v in meta.values() if v[2]), ours_file or "none"))
        print("| Position | Source | Job (ours) | Opening | maps-metadata | Agrees | Map file | Agrees |")
        print("|---|---|---|---|---|---|---|---|")
        per = {"meta": [0, 0, 0], "ours": [0, 0, 0]}
        for p in lm["positions"]:
            job = p["label"] + ("" if p["sub"] == "-" else " (" + p["sub"] + ")")
            mk, md = nearest(p, meta, a.radius)
            mrole = meta[mk][2] if mk else None
            ma = agrees(p["label"], mrole)
            ok, od = nearest(p, ours, a.radius)
            orole = ours[ok][2] if ok is not None else None
            oa = agrees(p["label"], orole) if orole in ("front", "tech", "air", "sea") else None
            for key, v in (("meta", ma), ("ours", oa)):
                if v is None:
                    continue
                for t in (total, per):
                    t[key][0] += 1 if v is True else 0
                    t[key][2] += 1 if v == "refines" else 0
                    t[key][1] += 1
            fmt = lambda v: "-" if v is None else ("refines" if v == "refines" else ("yes" if v else "**no**"))
            print("| %s | %s | %s | %s | %s | %s | %s | %s |" % (p["name"], p["source"], job, p.get("opening", "-"),
                  "%s %s" % (mk, mrole) if mk else "-", fmt(ma), orole or "-", fmt(oa)))
        for key, label in (("meta", "maps-metadata"), ("ours", "our map file")):
            agree, scored, ref = per[key]
            print("%s: %d of %d agree, %d refine" % (label, agree, scored, ref))
        print()
    for key, label in (("meta", "maps-metadata"), ("ours", "our map files")):
        agree, scored, ref = total[key]
        print("%s: %d of %d jobs agree (%.0f%%), %d refine (pond or geo where the reference says front or front/tech)"
              % (label, agree, scored, 100.0 * agree / scored if scored else 0.0, ref))
    return 0


if __name__ == "__main__":
    sys.exit(main())
