"""Run natural AIR/TECH games on the five standard AIR regression maps.

Resources, constructors and production policy are never overridden. Missing
land roles are assigned explicitly in the staged fixture. Maps with AIR but
no TECH starts use an AIR duel instead of putting TECH on a naval start.
"""
import argparse
import hashlib
import json
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys
import playtest
import storage
from prepare_air_operations_cases import MAPS


def run(args, entry):
    key, name, side, _, _ = entry
    side = args.side or side
    base = args.dir.resolve()/key
    base.mkdir(parents=True, exist_ok=True)
    # This runner nests maps below --dir; carry an allocated cohort's category
    # into each actual engine write directory before its immutable archive.
    if (args.dir/'run-plan.json').is_file():
        plan = json.loads((args.dir/'run-plan.json').read_text())
        plan['category']['map'] = key
        storage.write_json(base/'run-plan.json', plan)
    map_source = args.data/"script/src/maps"/playtest.map_file_for(name).name if args.data else None
    spots = playtest.map_spots(name, map_source)
    selected = []
    ally_count = 0
    override = False
    for region in (spots[:len(spots)//2], spots[len(spots)//2:]):
        air = next((p for p in region if p[2] == "AIR"), None)
        tech = next((p for p in region if p[2] == "TECH"), None)
        if air is None:
            if tech is None:
                raise ValueError("Map region has neither AIR nor TECH land start")
            air = tech
            tech = next((p for p in region if p[2] in ("FRONT", "TACTICAL")), None)
            override = True
        selected.append((air[0], air[1], "AIR"))
        if tech is not None:
            selected.append((tech[0], tech[1], "TECH"))
        if not ally_count:
            ally_count = len(selected)
    starts = base/"starts.as"
    starts.write_text("\n".join(f"StartSpot(AIFloat3({x},0,{z}), AiRole::{role}, false)," for x,z,role in selected))
    call = [sys.executable, str(playtest.HERE/"playtest.py")]
    stage = call+["stage", "--dir", str(base), "--dll", str(args.dll), "--map", name,
        "--map-file", str(starts), "--game", "Beyond All Reason test-31479-433a460", "--engine", "recoil_2026.07.04",
        "--role", "AIR", "--roles", "all", "--ally-spots", ",".join(str(i+1) for i in range(ally_count)), "--side", side, "--bonus", "0",
        "--speed", str(args.speed), "--minutes", str(args.minutes), "--shots", "" if args.headless else "5,15,20,30,40",
        "--width", "1280", "--height", "720", "--lean-render", "--ai-option", "profile=experimental_hard",
        "--ai-option", f"random_seed={args.seed}", "--extra-widget", str(playtest.HERE/"widgets/air_command_watch.lua"),
        "--extra-widget", str(playtest.HERE/"widgets/air_watch.lua"),
        "--extra-widget", str(playtest.HERE/"widgets/air_opening_watch.lua")]
    stage += ["--extra-widget", str(playtest.HERE/"widgets/air_workforce_watch.lua")]
    for widget in args.extra_widget:
        stage += ["--extra-widget", str(widget)]
    if args.headless:
        stage.append("--headless")
    if args.data:
        stage += ["--data", str(args.data)]
    subprocess.run(stage, check=True)
    subprocess.run([sys.executable, str(playtest.HERE/"prepare_air_check.py"),
        "--dir", str(base), "--scenario", "natural", "--seed", str(args.seed)], check=True)
    source = base/"AI/Skirmish/BARbTest/test/script/src/setup.as"
    if override:
        text = source.read_text()
        needle = "Global::AISettings::Role = derivedRole;"
        assert text.count(needle) == 1
        teams = json.loads((base/"teams.json").read_text())["teams"]
        condition = " || ".join("ai.teamId == "+str(team["team"]) for team in teams if team["role"] == "AIR")
        source.write_text(text.replace(needle, "derivedRole = ("+condition+") ? AiRole::AIR : AiRole::TECH;\n"+needle))
    (base/"natural-fixture.json").write_text(json.dumps({"map": name, "supplied_assets": bool(args.extra_widget),
        "extra_widgets": [str(w) for w in args.extra_widget],
        "production_overrides": False, "role_override": override, "selected_starts": selected,
        "seed": args.seed, "side": side,
        "minutes_requested": args.minutes, "rendered": not args.headless,
        "dll_sha256": hashlib.sha256(args.dll.read_bytes()).hexdigest(),
        "staged_script_sha256": {str(p.relative_to(source.parents[1])): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in source.parents[1].rglob('*.as')}}, indent=2))
    subprocess.run([sys.executable, str(playtest.REPO/"tools/knowledge/check_script_api.py"),
        "--dll", str(args.dll), "--scripts", str(source.parents[1])], check=True)
    launch = call+["launch", "--dir", str(base), "--engine", "recoil_2026.07.04"]
    if args.headless:
        launch.append("--headless")
    subprocess.run(launch, check=True)
    return subprocess.run(call+["watch", "--dir", str(base), "--role", "AIR", "--checks", "air_compile",
        "--minutes", str(args.minutes), "--wall-minutes", str(args.wall_minutes), "--keep-going"]).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, required=True)
    parser.add_argument("--dll", type=Path, required=True)
    parser.add_argument("--data", type=Path, help="Pinned data snapshot for a reproducible fixture")
    parser.add_argument("--extra-widget", type=Path, action="append", default=[])
    parser.add_argument("--maps", default=",".join(m[0] for m in MAPS))
    parser.add_argument("--seed", type=int, default=1711002)
    parser.add_argument("--side", choices=("armada", "cortex", "legion"))
    parser.add_argument("--minutes", type=float, default=45)
    parser.add_argument("--speed", type=float, default=20)
    parser.add_argument("--wall-minutes", type=float, default=25)
    parser.add_argument("--headless", action="store_true")
    args = parser.parse_args()
    if not args.dir.resolve().is_relative_to(RAW_ROOT):
        parser.error("Use an isolated build-theatres output directory")
    chosen = args.maps.split(",")
    if set(chosen)-{m[0] for m in MAPS}:
        parser.error("Unknown map key")
    results = []
    for entry in MAPS:
        if entry[0] not in chosen:
            continue
        results.append({"map": entry[1], "exit": run(args, entry)})
        (args.dir/"matrix.json").write_text(json.dumps(results, indent=2))
    sys.exit(any(r["exit"] for r in results))


if __name__ == "__main__":
    main()
