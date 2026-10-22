"""Summarize opt-in D-199 phases without double-counting nested scopes."""
import argparse
import json
from pathlib import Path
import re


def analyze(text):
    phases, garbage, oracle, labels = [], [], [], []
    for line in text.splitlines():
        for tag, rows in (("PerfPhase", phases), ("PerfGC", garbage), ("LocalOracle", oracle), ("PerfLabel", labels)):
            marker = f"[{tag}] "
            if marker not in line:
                continue
            row = {}
            for key, value in re.findall(r"(\w+)=([^\s]+)", line.split(marker, 1)[1]):
                row[key] = value if key in ("phase", "label") else float(value) if "." in value else int(value)
            rows.append(row)
    return {"phases": phases, "labels": labels, "garbage": garbage, "oracle": oracle,
            "notes": ["Inclusive phases overlap; never add parent and child durations.",
                      "GC counts do not measure GC duration or all heap allocations.",
                      "Oracle counters are periodically reported lower bounds; absence of a final row is not a total.",
                      "Oracle and profiling add diagnostic overhead; this is not a production-speed benchmark."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    result = analyze((args.directory / "infolog.txt").read_text(encoding="utf-8", errors="replace"))
    (args.directory / "performance-phases.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    frame = max((r["frame"] for r in result["phases"]), default=0)
    print(json.dumps({"last_frame": frame, "last_tech_phases": [r for r in result["phases"]
                    if r["frame"] == frame and r["team"] in (1, 8)], "oracle": result["oracle"][-6:]}, indent=2))


if __name__ == "__main__":
    main()
