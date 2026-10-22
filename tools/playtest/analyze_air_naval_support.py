"""Summarize observed AIR patrol/torpedo evidence without changing check verdicts."""
import argparse
import json
import re
from pathlib import Path


def analyze(path):
    result = {"schema": 1, "source": str(path.resolve()), "naval_launches": [],
              "recon_launches": [], "patrol_assignments": 0, "fallback_assignments": 0,
              "aa_escape_frames": [], "aa_escape_failures": 0, "torpedo_finished": 0,
              "first_damage_frame": None, "damage": 0, "naval_kills": 0,
              "peak_air_apm": 0, "peak_all_apm": 0, "max_patrols": 0,
              "max_patrol_span": [0, 0], "return_survivors": [], "invariants": []}
    frame = 0
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            match = re.search(r"\[f=(\d+)\]", line)
            if match:
                frame = int(match[1])
            match = re.search(r"\[AirOrders\] frame=\d+ team=0 all_apm=(\d+) air_apm=(\d+)", line)
            if match:
                result["peak_all_apm"] = max(result["peak_all_apm"], int(match[1]))
                result["peak_air_apm"] = max(result["peak_air_apm"], int(match[2]))
            if "[AIR][Recon] patrol plane=" in line:
                result["patrol_assignments"] += 1
            if "[AIR][Recon] least-exposed fallback" in line:
                result["fallback_assignments"] += 1
            for tag, key in (("[AIR][Naval] launch=", "naval_launches"),
                             ("[AIR][Recon] synchronized sweep=", "recon_launches")):
                if tag in line:
                    result[key].append({"frame": frame, "event": line.split(tag, 1)[1].strip()})
            match = re.search(r"AA_escape frame=(\d+)", line)
            if match:
                result["aa_escape_frames"].append(int(match[1]))
            if "AA_escape_failed" in line:
                result["aa_escape_failures"] += 1
            if "[AirNavalWatch] torpedo_finished" in line:
                result["torpedo_finished"] += 1
            match = re.search(r"torpedo_damage frame=(\d+)", line)
            if match and result["first_damage_frame"] is None:
                result["first_damage_frame"] = int(match[1])
            match = re.search(r"census frame=\d+ planes=\d+ airborne=\d+ patrol=(\d+) attacking=\d+ span=(-?\d+),(-?\d+) damage=(\d+) dead=(\d+)", line)
            if match:
                result["damage"] = max(result["damage"], int(match[4]))
                result["naval_kills"] = max(result["naval_kills"], int(match[5]))
                if int(match[1]) > 0:
                    result["max_patrols"] = max(result["max_patrols"], int(match[1]))
                    result["max_patrol_span"] = [max(result["max_patrol_span"][i], int(match[i+2])) for i in range(2)]
            match = re.search(r"\[AIR\]\[Naval\] return survivors=(\d+)", line)
            if match:
                result["return_survivors"].append(int(match[1]))
            if "[INVARIANT]" in line:
                result["invariants"].append(line.strip())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    out = args.archive / "air-naval-analysis.json"
    out.write_text(json.dumps(analyze(args.archive / "infolog.txt"), indent=2) + "\n", encoding="utf-8")
    print(out)


if __name__ == "__main__":
    main()
