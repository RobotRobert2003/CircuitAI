"""Spam lane test: 8v8 SMRTBARb (all 16 slots, the map file's roles, experimental_balanced),
headless, every team on --bonus, one game per map. lane_trail_watch.lua records the path
every spam unit and every gantry unit walked; the game stops at --minutes.

Usage: run.py --dll SkirmishAI.dll --out DIR --maps "Thermal Shock v1.1,Forge v2.3" [--game NAME]

Maps are names as the lobby shows them (the script.txt MapName). Queues behind other
headless test engines (up to 20 min); while the owner's BAR client is in a game the
headless engine drops to Idle priority, otherwise Normal."""
import argparse
import json
import re
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import importlib.util  # noqa: E402
import playtest  # noqa: E402
import subprocess  # noqa: E402

# the gantry test's queueing and priority helpers (wait_free, manage_priority)
_spec = importlib.util.spec_from_file_location("gantry_t3_run", HERE.parent / "gantry_t3" / "run.py")
gantry_run = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gantry_run)

REPO = playtest.REPO
PT = [sys.executable, str(HERE.parent / "playtest.py")]


def key_of(name):
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def run(args, name):
    d = args.out / key_of(name)
    common = ["--dir", str(d), "--headless"]
    # map files drop the version, also a "_V2" one (Entrenched_Plains_V2 -> entrenched_plains.as)
    base = re.sub(r"(\s+v?[\d.]+|_v[\d.]+)$", "", name.strip(), flags=re.I).lower().replace(" ", "_")
    mf = REPO / "data" / "script" / "src" / "maps" / (base + ".as")
    extra = ["--map-file", str(mf)] if mf.exists() else []
    subprocess.run(PT + ["stage"] + common + extra + ["--dll", str(args.dll), "--map", name, "--role", "FRONT",
                   "--roles", "all", "--others", "test", "--ai-option", "profile=experimental_balanced",
                   "--game", args.game, "--speed", str(args.speed), "--minutes", str(args.minutes + 0.5),
                   "--bonus-all", str(args.bonus), "--extra-widget", str(HERE / "lane_trail_watch.lua")], cwd=REPO, check=True)
    w = d / "LuaUI/Widgets/lane_trail_watch.lua"
    w.write_text(w.read_text().replace("__END_FRAME__", str(int(args.minutes * 60 * 30))))
    checks = d / "lane-checks.json"
    checks.write_text(json.dumps({"stop_minute": args.minutes + 0.5, "expect": [
        {"key": "trails dumped", "pattern": r"\[LaneTrail\] END", "by_minute": args.minutes + 0.5, "scope": "any"}],
        "forbid": [{"key": "script failure", "pattern": r"SCRIPT CRASH|Lib exception", "scope": "any"}]}, indent=2))
    gantry_run.wait_free(str(args.out))
    stop = threading.Event()
    threading.Thread(target=gantry_run.manage_priority, args=(str(args.out), stop), daemon=True).start()
    subprocess.run(PT + ["launch"] + common, cwd=REPO, check=True)
    r = subprocess.run(PT + ["watch", "--dir", str(d), "--role", "FRONT", "--minutes", str(args.minutes + 0.5),
                        "--wall-minutes", "90", "--keep-going", "--stop-when-met", "--checks", str(checks)], cwd=REPO)
    stop.set()
    with open(args.out / "summary.txt", "a") as f:
        f.write("%s %s: watch exit %d\n" % (time.strftime("%H:%M:%S"), name, r.returncode))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dll", type=Path, required=True, help="SkirmishAI.dll to test (a copy without its .dbg)")
    ap.add_argument("--out", type=Path, required=True, help="output directory, one subdirectory per map")
    ap.add_argument("--maps", required=True, help="comma-separated map names as the lobby shows them")
    ap.add_argument("--game", default=playtest.latest_game_version(),
                    help="game archive the lobby plays (default: the newest byar:test)")
    ap.add_argument("--speed", type=float, default=10)
    ap.add_argument("--minutes", type=float, default=35)
    ap.add_argument("--bonus", type=int, default=60)
    args = ap.parse_args()
    if not args.game:
        playtest.die("no game version: pass --game 'Beyond All Reason test-...'")
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    for name in args.maps.split(","):
        try:
            run(args, name.strip())
        except subprocess.CalledProcessError as e:   # one map failing to stage does not stop the rest
            with open(args.out / "summary.txt", "a") as f:
                f.write("%s %s: %s\n" % (time.strftime("%H:%M:%S"), name.strip(), e))


if __name__ == "__main__":
    main()
