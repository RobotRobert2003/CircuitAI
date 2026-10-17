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
