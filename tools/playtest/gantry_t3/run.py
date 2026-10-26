"""t3rush gantry test: 8v8 SMRTBARb (all 16 slots, experimental_balanced), headless,
random +50..+70 bonus per team, one game per map. Each game stops once every TECH
has its first T3 unit out, or at --minutes.

Usage: run.py --dll SkirmishAI.dll --out DIR [--maps glitters,hotlips,...] [--game NAME]

Queues behind other headless test engines (up to 20 min). Games the owner's BAR
client joins or spectates do not hold the runs; while that client is in a game the
headless engine drops to Idle priority, otherwise Normal."""
import argparse
import json
import random
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import playtest  # noqa: E402

REPO = playtest.REPO
BAR = playtest.BAR_DATA
MAPS = {"glitters": "All That Glitters v3.0", "hotlips": "Hotlips Remake v3.2",
        "proving": "Proving Grounds v1.0", "saltreef": "Salt Reef 1.1"}
PT = [sys.executable, str(HERE.parent / "playtest.py")]


def other_headless(out):
    """Another headless test engine (not one of ours) is running."""
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='spring-headless.exe'\" | "
          "Where-Object { $_.CommandLine -notlike '*%s*' } | Measure-Object | %% Count") % out
    count = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.strip()
    return count not in ("", "0")


def wait_free(out):
    deadline = time.time() + 20 * 60
    while other_headless(out) and time.time() < deadline:
        print(time.strftime("%H:%M:%S"), "another headless test engine running, waiting", flush=True)
        time.sleep(30)


def client_in_game():
    """The owner's BAR client (spring.exe) is in a game: its newest replay is still 0 bytes and its
    infolog was written in the last 60 s (the lobby itself writes no replay)."""
    demos = sorted((BAR / "demos").glob("*.sdfz"), key=lambda p: p.stat().st_mtime)
    if not demos or demos[-1].stat().st_size != 0:
        return False
    log = BAR / "infolog.txt"
    return log.exists() and time.time() - log.stat().st_mtime < 60


PRIORITY_PS = ("Get-CimInstance Win32_Process -Filter \"Name='spring-headless.exe'\" | "
               "Where-Object { $_.CommandLine -like '*%s*' } | ForEach-Object { try { "
               "$p = Get-Process -Id $_.ProcessId; if ($p.PriorityClass -ne '%s') { $p.PriorityClass = '%s' } } catch {} }")


def manage_priority(out, stop):
    last = None
    while not stop.is_set():
        want = "Idle" if client_in_game() else "Normal"
        if want != last:
            print(time.strftime("%H:%M:%S"), "headless priority", want, flush=True)
            last = want
        subprocess.run(["powershell", "-NoProfile", "-Command", PRIORITY_PS % (out, want, want)], capture_output=True)
        stop.wait(10)


def run(args, key):
    d = args.out / key
    common = ["--dir", str(d), "--headless"]
    subprocess.run(PT + ["stage"] + common + ["--dll", str(args.dll), "--map", MAPS[key], "--role", "TECH",
                   "--roles", "all", "--others", "test", "--ai-option", "profile=experimental_balanced",
                   "--game", args.game, "--speed", str(args.speed), "--minutes", str(args.minutes), "--bonus-all", "60",
                   "--extra-widget", str(HERE / "gantry_t3_watch.lua")], cwd=REPO, check=True)
    teams = json.loads((d / "teams.json").read_text())["teams"]
    tech = [t["team"] for t in teams if t["role"] == "TECH"]
    w = d / "LuaUI/Widgets/gantry_t3_watch.lua"
    w.write_text(w.read_text().replace("__TECH_TEAMS__", ",".join(map(str, tech))))
    # per-team bonus roll, +50..+70
    rng = random.Random()
    bonus = {}
    script = (d / "script.txt").read_text()

    def repl(m):
        t = int(m.group(1))
        if t >= len(teams):
            return m.group(0)
        bonus[t] = rng.randint(50, 70)
        return re.sub(r"Handicap=\d+;", "Handicap=%d;" % bonus[t], m.group(0))
    script = re.sub(r"\[TEAM(\d+)\]\s*\{[^}]*\}", repl, script)
    (d / "script.txt").write_text(script)
    (d / "bonus.json").write_text(json.dumps({"bonus": bonus, "tech_teams": tech, "teams": teams}, indent=2))
    checks = d / "gtest-checks.json"
    checks.write_text(json.dumps({"stop_minute": args.minutes, "expect": [
        {"key": "all tech T3 out", "pattern": r"\[GTest\] ALL_T3_DONE", "by_minute": args.minutes, "scope": "any"}],
        "forbid": [{"key": "script failure", "pattern": r"SCRIPT CRASH|Lib exception", "scope": "any"}]}, indent=2))
    wait_free(str(args.out))
    stop = threading.Event()
    threading.Thread(target=manage_priority, args=(str(args.out), stop), daemon=True).start()
    subprocess.run(PT + ["launch"] + common, cwd=REPO, check=True)
    r = subprocess.run(PT + ["watch", "--dir", str(d), "--role", "TECH", "--minutes", str(args.minutes),
                        "--wall-minutes", "60", "--keep-going", "--stop-when-met", "--checks", str(checks)], cwd=REPO)
    stop.set()
    with open(args.out / "summary.txt", "a") as f:
        f.write("%s %s: watch exit %d\n" % (time.strftime("%H:%M:%S"), MAPS[key], r.returncode))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dll", type=Path, required=True, help="SkirmishAI.dll to test (a copy without its .dbg)")
    ap.add_argument("--out", type=Path, required=True, help="output directory, one subdirectory per map")
    ap.add_argument("--maps", default=",".join(MAPS), help="comma-separated keys of " + ", ".join(MAPS))
    ap.add_argument("--game", default=playtest.latest_game_version(),
                    help="game archive the lobby plays (default: the newest byar:test)")
    ap.add_argument("--speed", type=float, default=10)
    ap.add_argument("--minutes", type=float, default=30)
    args = ap.parse_args()
    if not args.game:
        playtest.die("no game version: pass --game 'Beyond All Reason test-...'")
    args.out = args.out.resolve()
    for key in args.maps.split(","):
        run(args, key.strip())


if __name__ == "__main__":
    main()
