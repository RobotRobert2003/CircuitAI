"""Repeat no-bonus, non-ending TECH games; measure actual nuclear launch.

Definitions live here; unique raw games and compact reports live in the sibling
benchmark checkout. A missed deadline is retained, never overwritten by a retry.
"""
from script_settings import role_script_path
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

from benchmark_store import EVIDENCE_ROOT, SOURCE_ROOT, require_checkout
from storage import allocate, run_id


def analyze(text):
    def first(pattern):
        hit = re.search(pattern, text)
        return int(hit.group(1)) / 30 if hit else None

    result = {
        "silo_seconds": first(r"\[NukeRush\] silo-finished team=0 id=\d+ frame=(\d+)"),
        "launch_seconds": first(r"\[NukeRush\] launch team=0 silo=\d+ projectile=\d+ frame=(\d+)"),
        "ready_seconds": first(r"\[f=0*(\d+)\].*\[NukeRush\] stock team=0 .*count=[1-9]"),
        "errors": len(re.findall(r": ERR\s+:|SCRIPT CRASH|Error in.*Nuke rush", text)),
        "invariants": sorted(set(re.findall(r"S:0:T:0:.*\[INVARIANT\] (INV-\d+)", text))),
        "handoff": bool(re.search(r"S:0:T:0:.*\[TECH\]\[NukeRush\] silo complete; normal economy resumes", text)),
    }
    result["timing_pass"] = result["launch_seconds"] is not None and result["launch_seconds"] <= 900
    handoff = re.search(r"S:0:T:0:F:(\d+):.*\[TECH\]\[NukeRush\] silo complete; normal economy resumes", text)
    result["handoff_seconds"] = int(handoff[1]) / 30 if handoff else None
    violations = re.findall(r"S:0:T:0:F:(\d+):.*\[INVARIANT\] (INV-\d+)", text)
    result["opening_invariants"] = sorted({code for frame, code in violations
        if not handoff or int(frame) <= int(handoff[1])})
    result["recovery_invariants"] = sorted({code for frame, code in violations
        if handoff and int(frame) > int(handoff[1])})
    refund = re.search(r"S:0:T:0:F:(\d+):.*\[TECH\]\[NukeRush\] refund storage (\d+) ", text)
    result["storage_refund_started_seconds"] = int(refund[1]) / 30 if refund else None
    result["storage_removed_seconds"] = first(
        rf"\[NukeRush\] storage-removed team=0 id={refund[2]} frame=(\d+)") if refund else None
    result["ideal"] = result["launch_seconds"] is not None and result["launch_seconds"] <= 840
    result["pass"] = result["timing_pass"] and not result["errors"] and not result["invariants"] and result["handoff"]
    return result


def record(directory):
    info = Path(directory) / "infolog.txt"
    result = analyze(info.read_text(encoding="utf-8", errors="replace"))
    result.update(directory=str(Path(directory).resolve()), log_sha256=hashlib.sha256(info.read_bytes()).hexdigest())
    return result


def prepare_trial(directory, seed, opponent_objective):
    """Pin both RNGs and force only the measured team into the nuke opening.

    This edits staged inputs only. Economic opponents isolate timing; 'auto'
    retains normal opponent strategy for integration games. No resource gifts,
    target revelation or forced launch commands are used.
    """
    script = directory / "script.txt"
    source = script.read_text(encoding="utf-8")
    source, count = re.subn(r"(\[GAME\]\s*\{)",
                           lambda m: m[1] + f"\n FixedRNGSeed={seed};", source, count=1)
    if count != 1:
        raise ValueError("Missing game block")
    script.write_text(source, encoding="utf-8")
    chain = role_script_path(directory / 'AI/Skirmish/BARbTest/test/script/src', 'tech_chain')
    source = chain.read_text(encoding="utf-8")
    marker = "objective = Global::RoleSettings::Tech::RushObjective;"
    if source.count(marker) != 1:
        raise ValueError("Missing unique rush objective hook")
    source = source.replace(marker, marker + f'\n        if (ai.teamId != 0) objective = "{opponent_objective}";')
    chain.write_text(source, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    read = sub.add_parser("read")
    read.add_argument("directory")
    run = sub.add_parser("run")
    run.add_argument("--dll", required=True)
    run.add_argument("--data", default=str(SOURCE_ROOT / "data"))
    run.add_argument("--map", default="Supreme Isthmus v1.7")
    run.add_argument("--map-file")
    run.add_argument("--side", choices=("armada", "cortex", "legion"), default="armada")
    run.add_argument("--roles", default="TECH", help="TECH isolates the economy; all uses the map's full team roster")
    run.add_argument("--trials", type=int, default=3)
    run.add_argument("--seed", type=int, default=22901, help="first engine/AI seed; incremented per trial")
    run.add_argument("--opponent-objective", choices=("afus", "auto", "nuke"), default="afus")
    run.add_argument("--minutes", type=float, default=20)
    run.add_argument("--set", action="append", default=[])
    run.add_argument("--headless", action="store_true")
    args = parser.parse_args()
    if args.command == "read":
        print(json.dumps(record(args.directory), indent=2))
        return 0
    if args.trials < 1 or args.minutes < 15:
        parser.error("Use at least one trial and fifteen game minutes")
    require_checkout()
    batch = EVIDENCE_ROOT / "records/tech/economy/nuke-launch" / run_id()
    batch.mkdir(parents=True, exist_ok=False)
    results = []
    for trial in range(args.trials):
        directory = allocate("tech", "economy", "nuke-launch", args.map, "benchmark",
                             side=args.side, roles=args.roles, trial=trial+1, bonus=0, batch=str(batch))
        seed = args.seed + trial
        cmd = [sys.executable, str(SOURCE_ROOT / "tools/playtest/playtest.py"), "stage",
               "--dir", str(directory), "--dll", args.dll, "--data", args.data,
               "--roles", args.roles, "--side", args.side, "--map", args.map,
               "--bonus", "0", "--modoption", "ai_incomemultiplier=1",
               "--modoption", "dynamiccheats=0", "--modoption", "deathmode=neverend",
               "--ai-option", f"random_seed={seed}",
               "--set", 'RushObjective="nuke"', "--speed", "20", "--minutes", str(args.minutes),
               "--shots", "" if args.headless else "8@2300,12@2300,15@2300", "--lean-render",
               "--extra-widget", str(SOURCE_ROOT / "tools/playtest/widgets/nuke_rush_watch.lua")]
        if args.headless:
            cmd += ["--headless"]
        if args.map_file:
            cmd += ["--map-file", args.map_file]
        for setting in args.set:
            cmd += ["--set", setting]
        subprocess.run(cmd, cwd=SOURCE_ROOT, check=True)
        prepare_trial(directory, seed, args.opponent_objective)
        launcher = [sys.executable, str(SOURCE_ROOT / "tools/playtest/playtest.py"), "launch", "--dir", str(directory)]
        if args.headless:
            launcher.append("--headless")
        subprocess.run(launcher, cwd=SOURCE_ROOT, check=True)
        watcher = [sys.executable, str(SOURCE_ROOT / "tools/playtest/playtest.py"), "watch", "--dir", str(directory),
                   "--checks", "nuke_launch", "--keep-going", "--minutes", str(args.minutes), "--wall-minutes", "20"]
        code = subprocess.run(watcher, cwd=SOURCE_ROOT).returncode
        result = record(directory) if (directory / "infolog.txt").exists() else {"pass":False,"directory":str(directory)}
        result.update(trial=trial+1, seed=seed, opponent_objective=args.opponent_objective,
                      returncode=code, side=args.side, roles=args.roles, map=args.map, command=cmd)
        results.append(result)
        (batch / "results.json").write_text(json.dumps(results, indent=2)+"\n", encoding="utf-8")
        print(json.dumps(result), flush=True)
    print(f"Benchmark batch: {batch}")
    return 0 if all(r["pass"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
