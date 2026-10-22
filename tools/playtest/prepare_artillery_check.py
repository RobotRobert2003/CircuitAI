"""Instrument an already-staged, isolated BARbTest artillery regression.

Run playtest.py stage first, then this tool, then launch/watch (not run, which
would erase the instrumentation). Never edits production data or a live install.
"""
import argparse
import json
from pathlib import Path
from benchmark_store import RAW_ROOT
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ["easy", "medium", "hard", "hard_aggressive", "experimental_balanced",
            "experimental_hard", "experimental_terrible"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, required=True)
    parser.add_argument("--mode", choices=["profiles", "fire"], required=True)
    args = parser.parse_args()
    base = args.dir.resolve()
    if not base.is_relative_to((RAW_ROOT).resolve()):
        parser.error("use an isolated directory under the benchmark repository's build-theatres")
    staged = base / "AI/Skirmish/BARbTest/test/script"
    if not staged.is_dir():
        parser.error("stage BARbTest first")
    shutil.copyfile(ROOT / "tools/playtest/fixtures/artillery_probe.as", staged / "artillery_probe.as")
    for profile in PROFILES:
        # Start with production main, so repeated preparation is idempotent.
        text = (ROOT / "data/script" / profile / "main.as").read_text()
        text = '#include "../artillery_probe.as"\n' + text.replace(
            "ArtilleryPolicy::Check();", "ArtilleryPolicy::Check(); ArtilleryProbe::Tick();")
        if args.mode == "fire" and profile == "hard":
            text = text.replace("void AiMain()", "void AiLuaMessage(const string& in data) { ArtilleryProbe::Aim(data); }\n    void AiMain()")
        (staged / profile / "main.as").write_text(text)
    script = base / "script.txt"
    text = script.read_text()
    # Only AI OPTIONS blocks: MODOPTIONS is outside these bounded AI bodies.
    used = []

    def assign(match):
        index = int(match[1])
        profile = "hard" if args.mode == "fire" else PROFILES[index % len(PROFILES)]
        used.append(profile)
        body = re.sub(r"\[OPTIONS\]\s*\{[^{}]*\}", "", match[2], flags=re.I)
        return "[AI" + str(index) + "]\n\t{\n\t\t[OPTIONS] { profile=" + profile + "; }" + body + "}"

    text = re.sub(r"\[AI(\d+)\]\s*\{((?:[^{}]|\{[^{}]*\})*)\}", assign, text)
    if not used:
        parser.error("no AI sections found")
    script.write_text(text)
    (base / "profile-order.json").write_text(json.dumps(used, indent=2))
    if args.mode == "fire":
        shutil.copyfile(ROOT / "tools/playtest/widgets/artillery_fire_watch.lua",
                        base / "LuaUI/Widgets/artillery_fire_watch.lua")
    print("Prepared", len(used), "AIs:", ", ".join(used))


if __name__ == "__main__":
    main()
