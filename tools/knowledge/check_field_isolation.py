#!/usr/bin/env python3
"""D-323: keep the battlefield map analysis out of behaviour until Part C.

The field (src/circuit/terrain/field/, CFieldService) is computed once per
process and drawn by the team-link widget. No manager, task or script role may
read it in Parts A and B. This check greps:

1. every .cpp/.h under src/circuit outside the allowed list for an include of
   FieldService.h or terrain/field/, or a call to GetFieldService();
2. every .as under data/script/src outside systems/presentation/ for `aiField`.

Exit 0 when clean, 1 with one line per finding. Relaxations for Part C are
decisions: add the file here and record why in decisions.md.

3. (D-358) every native file outside terrain/field/ and the allowed set for a
   per-class slope or wade-depth constant: passability is defined once, in
   field::FinePassability.
"""
import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

NATIVE_ALLOWED = {
    os.path.normpath("src/circuit/terrain/FieldService.h"),
    os.path.normpath("src/circuit/terrain/FieldService.cpp"),
    os.path.normpath("src/circuit/util/GameAttribute.h"),
    os.path.normpath("src/circuit/util/GameAttribute.cpp"),
    os.path.normpath("src/circuit/CircuitAI.cpp"),
    os.path.normpath("src/circuit/script/InitScript.cpp"),
    # D-358 (Part C, one consumer per change): the corridor table's readers
    os.path.normpath("src/circuit/resource/MexTerritory.h"),      # mex_lanes::FromCorridors
    os.path.normpath("src/circuit/module/MexOwnership.cpp"),      # the partition and the lane accessors
    os.path.normpath("src/circuit/terrain/BattleLanes.cpp"),      # BuildPass (FinePassability) and the Corridor* queries
}
# D-358: passability is defined once (terrain/field/FieldCorridors.h). No other
# native file may spell the movedef slope or depth limits for a class.
PASSABILITY_PATTERN = re.compile(r"\bSLOPE_(TANK|BOT|HOVER)\b|\bWADE_DEPTH\b|\bBA_WADE_DEPTH\b|\bBA_SHIP_DEPTH\b")
PASSABILITY_ALLOWED = {
    os.path.normpath("src/circuit/terrain/TerrainData.cpp"),   # the sector areas read the movedefs themselves, by design
    os.path.normpath("src/circuit/terrain/BattleAnalysis.cpp"), # the water-body and beach rules keep their depth constants until phase 5
}
NATIVE_PATTERN = re.compile(r'#include\s+"terrain/(FieldService\.h|field/)|GetFieldService\(\)')
SCRIPT_PATTERN = re.compile(r"\baiField\b")


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main():
    findings = []
    for path in sorted(glob.glob(os.path.join(ROOT, "src", "circuit", "**", "*.*"), recursive=True)):
        if not path.endswith((".cpp", ".h", ".hpp")):
            continue
        rel = os.path.normpath(os.path.relpath(path, ROOT))
        if rel in NATIVE_ALLOWED or rel.startswith(os.path.normpath("src/circuit/terrain/field") + os.sep):
            continue
        for number, line in enumerate(read(path).splitlines(), 1):
            if NATIVE_PATTERN.search(line):
                findings.append("%s:%d reads the field service (Part A keeps it out of behaviour)" % (rel.replace(os.sep, "/"), number))
    for path in sorted(glob.glob(os.path.join(ROOT, "src", "circuit", "**", "*.*"), recursive=True)):
        if not path.endswith((".cpp", ".h", ".hpp")):
            continue
        rel = os.path.normpath(os.path.relpath(path, ROOT))
        if rel in PASSABILITY_ALLOWED or rel.startswith(os.path.normpath("src/circuit/terrain/field") + os.sep):
            continue
        for number, line in enumerate(read(path).splitlines(), 1):
            if PASSABILITY_PATTERN.search(line):
                findings.append("%s:%d defines a class passability limit outside terrain/field/ (D-358: FinePassability is the one definition)" % (rel.replace(os.sep, "/"), number))
    for path in sorted(glob.glob(os.path.join(ROOT, "data", "script", "src", "**", "*.as"), recursive=True)):
        rel = os.path.normpath(os.path.relpath(path, ROOT))
        if rel.startswith(os.path.normpath("data/script/src/systems/presentation") + os.sep):
            continue
        for number, line in enumerate(read(path).splitlines(), 1):
            if SCRIPT_PATTERN.search(line):
                findings.append("%s:%d calls aiField outside systems/presentation/" % (rel.replace(os.sep, "/"), number))
    for finding in findings:
        print(finding)
    print("field isolation check: %d finding(s)" % len(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
