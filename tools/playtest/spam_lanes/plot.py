"""Plots each game's spam lanes over the map: planned waypoints and the paths units walked.

python -I tools/playtest/spam_lanes/plot.py --out DIR

One PNG per map in DIR (<map>_lanes.png), two panels: edge lanes and gantry routes on the
left, pump lanes on the right. Light ground is approximately bot-walkable (above -20,
slope under 0.6, from the map's heightmap, cached in DIR/heightmaps). Each lane has its
own colour: its planned route as a thick dashed line with numbered waypoints (triangle the
jackknife corner, diamond the new mid-edge point, star the new final corner), and up to
TRAILS of its units' walked trails as thin solid lines (furthest along first). Pump lanes
also mark the AI's latest rim end/corner/mid/home with small rings (routes are rebuilt
during the game without a full waypoint line). Squares are starts (blue ally 0, red ally 1).
Needs numpy, matplotlib and py7zr."""
import argparse
import json
import re
import struct
import sys
import tempfile
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import parse  # noqa: E402

MAPS = Path(r"C:\Users\artib\AppData\Local\Programs\Beyond-All-Reason\data\maps")
TRAILS = 25


def heightmap(mapname, cache):
    """Heights (elmos) of the map's .smf, cached as .npy; None when the archive is not found."""
    stem = re.sub(r"[^a-z0-9.]+", "_", mapname.lower()).strip("_")
    npy = cache / (stem + ".npy")
    if npy.exists():
        return np.load(npy)
    cands = [p for p in MAPS.glob("*.sd7") if p.stem.lower().replace("-", "_") == stem.replace(" ", "_")]
    if not cands:
        cands = [p for p in MAPS.glob("*.sd7") if p.stem.lower().startswith(stem.split("_v")[0][:12])]
    if not cands:
        return None
    import py7zr
    with tempfile.TemporaryDirectory() as td:
        with py7zr.SevenZipFile(cands[0]) as z:
            smf = [n for n in z.getnames() if n.lower().endswith(".smf")]
            z.extract(path=td, targets=smf)
        data = (Path(td) / smf[0]).read_bytes()
    mapx, mapy = struct.unpack_from("<ii", data, 24)
    minh, maxh = struct.unpack_from("<ff", data, 44)
    hptr = struct.unpack_from("<i", data, 52)[0]
    hm = np.frombuffer(data, dtype="<u2", count=(mapx + 1) * (mapy + 1), offset=hptr).reshape(mapy + 1, mapx + 1)
    h = minh + hm.astype(np.float32) * (maxh - minh) / 65535.0
    cache.mkdir(parents=True, exist_ok=True)
    np.save(npy, h)
    return h


def plot(d, out, radius):
    g = parse.load(d)
    if g is None:
        return None
    teams = json.loads((d / "teams.json").read_text())["teams"] if (d / "teams.json").exists() else []
    h = heightmap(g["mapname"], out / "heightmaps")
    if h is not None:
        w, hh = (h.shape[1] - 1) * 8, (h.shape[0] - 1) * 8
        gy, gx = np.gradient(h, 8.0)
        walk = (h > -20) & (np.hypot(gx, gy) < 0.6)
    else:
        w = hh = max([p[0] for pl in g["plans"].values() for p in pl["pts"]] + [8192])
        walk = None
    fig, axes = plt.subplots(1, 2, figsize=(20, 10.5))
    cmap = plt.get_cmap("tab20")
    groups = [("Edge lanes and T3 gantry routes", lambda k, p: not p["kind"].startswith("pump")),
              ("Pump lanes (T1 spam labs)", lambda k, p: p["kind"].startswith("pump"))]
    for ax, (title, want) in zip(axes, groups):
        if walk is not None:
            ax.imshow(np.where(walk, 1.0, 0.0), cmap="Greys_r", vmin=-0.6, vmax=1.4, extent=(0, w, hh, 0))
        for t in teams:
            ax.plot(t["x"], t["z"], "s", color="tab:blue" if t["ally"] == 0 else "tab:red", ms=7, mec="k", mew=0.5)
            ax.annotate("%d %s" % (t["team"], t["role"][:2]), (t["x"], t["z"]), fontsize=7, xytext=(3, 3), textcoords="offset points")
        n = 0
        for (team, key), p in sorted(g["plans"].items()):
            if not want((team, key), p) or len(p["pts"]) < 2:
                continue
            c = cmap(n % 20)
            n += 1
            plan = p["pts"]
            walked = [(u, g["trails"][u]) for u in g["units"].get((team, key), []) if u in g["trails"]]
            walked.sort(key=lambda ut: (-parse.progress(ut[1]["pts"], plan, radius)[0], -len(ut[1]["pts"])))
            best = parse.progress(walked[0][1]["pts"], plan, radius)[0] if walked else 0
            for u, tr in walked[:TRAILS]:
                ax.plot([q[0] for q in tr["pts"]], [q[1] for q in tr["pts"]], "-", color=c, lw=0.8, alpha=0.45)
            ax.plot([q[0] for q in plan], [q[1] for q in plan], "--", color=c, lw=2.4, alpha=0.95,
                    label="T%d %s %s: %d pts, %d units, best %d/%d" % (team, p["kind"].replace(" edge lane", ""), key if key != "edge" else "",
                                                                     len(plan), len(walked), best, len(plan)))
            for i, q in enumerate(plan):
                ax.annotate(str(i + 1), q, fontsize=7, color=c, fontweight="bold", xytext=(3, -8), textcoords="offset points")
            if len(plan) >= 4:
                ax.plot(*plan[-3], "^", color=c, ms=9, mec="k", mew=0.6)
            if len(plan) >= 3:
                ax.plot(*plan[-2], "D", color=c, ms=8, mec="k", mew=0.6)
            ax.plot(*plan[-1], "*", color=c, ms=15, mec="k", mew=0.6)
            if p["kind"].startswith("pump"):
                notes = g["rimnotes"].get((team, key), [])
                if notes:
                    for q in parse.pts(notes[-1].split("ends at", 1)[1]):
                        ax.plot(*q, "o", mfc="none", mec=c, ms=10, mew=1.5)
        ax.set_xlim(0, w)
        ax.set_ylim(hh, 0)
        ax.set_aspect("equal")
        ax.set_title(title, fontsize=10)
        if n:
            ax.legend(fontsize=6.5, loc="lower left", framealpha=0.85)
    fig.suptitle("%s - planned lane (dashed, 1..n; triangle = far corner, diamond = new mid-edge, star = new final corner) "
                 "and walked trails (thin); light = approx. bot-walkable; trails to %s"
                 % (g["mapname"], parse.clock(g["end_frame"])), fontsize=10)
    fig.tight_layout()
    png = out / ("%s_lanes.png" % d.name)
    fig.savefig(png, dpi=85)
    plt.close(fig)
    return png


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--radius", type=float, default=450)
    a = ap.parse_args()
    for d in sorted(p for p in a.out.iterdir() if p.is_dir() and (p / "runs").exists()):
        print(plot(d, a.out, a.radius))


if __name__ == "__main__":
    main()
