#!/usr/bin/env python3
"""Enforce the invariant practice (D-076, projects/circuitai/practice-invariants.md).

Checks, all static:

1. Every invariant id the scripts or native code can log ("[INVARIANT] INV-nnn")
   has a row in projects/circuitai/invariants.md, and every row there is logged by code.
2. Every playtest check file (tools/playtest/checks/**/*.json) forbids the
   "[INVARIANT]" line, so a broken invariant fails every benchmark run.
3. Every rule row of the TECH table (Rule("key", ...) in tech_rules.as) appears
   in projects/circuitai/actor-matrix.md, so a rule that acts on an object is listed beside
   the other actors on that object.
4. Every decision from D-076 on has an "**Invariant" paragraph: the promise it
   adds or the one it relies on.

Exit 0 when clean, 1 with one line per finding.
"""
from documentation_store import document
import glob
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIRST_DECISION_WITH_INVARIANT = 76


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main():
    findings = []

    # 1. ids in scripts/native code vs the register
    script_ids = set()
    for path in glob.glob(os.path.join(ROOT, "data", "script", "src", "**", "*.as"), recursive=True):
        script_ids.update(re.findall(r'"(INV-\d{3})"', read(path)))
    # Native targeting owns launch events unavailable to the script observer.
    for path in glob.glob(os.path.join(ROOT, "src", "circuit", "**", "*.cpp"), recursive=True):
        script_ids.update(re.findall(r'\[INVARIANT\] (INV-\d{3})', read(path)))
    reg_path = document("invariants.md")
    reg_ids = set(re.findall(r"^\| (INV-\d{3}) \|", read(reg_path), re.M)) if os.path.exists(reg_path) else set()
    if not os.path.exists(reg_path):
        findings.append("projects/circuitai/invariants.md is missing")
    for i in sorted(script_ids - reg_ids):
        findings.append("%s is logged by code but has no row in projects/circuitai/invariants.md" % i)
    for i in sorted(reg_ids - script_ids):
        findings.append("%s has a row in projects/circuitai/invariants.md but no code logs it" % i)

    # 2. every check file forbids a broken invariant
    for path in sorted(glob.glob(os.path.join(ROOT, "tools", "playtest", "checks", "**", "*.json"), recursive=True)):
        try:
            data = json.loads(read(path))
        except ValueError as exc:
            findings.append("%s: not valid JSON (%s)" % (os.path.relpath(path, ROOT), exc))
            continue
        if not any("INVARIANT" in f.get("pattern", "") for f in data.get("forbid", [])):
            findings.append("%s: no forbid entry for [INVARIANT]" % os.path.relpath(path, ROOT))

    # 3. every TECH rule row is in the actor matrix
    rules_path = os.path.join(ROOT, "data", "script", "src", "roles", "tech", "tech_rules.as")
    matrix_path = document("actor-matrix.md")
    if os.path.exists(rules_path):
        keys = re.findall(r'Rule\("([a-z0-9.]+)"', read(rules_path))
        matrix = read(matrix_path) if os.path.exists(matrix_path) else ""
        if not matrix:
            findings.append("projects/circuitai/actor-matrix.md is missing")
        for k in keys:
            if "`%s`" % k not in matrix:
                findings.append("rule `%s` is not in projects/circuitai/actor-matrix.md" % k)

    # 4. decisions from D-076 name their invariant
    dec_path = document("decisions.md")
    if os.path.exists(dec_path):
        text = read(dec_path)
        heads = list(re.finditer(r"^## D-(\d{3}) ", text, re.M))
        for n, m in enumerate(heads):
            num = int(m.group(1))
            if num < FIRST_DECISION_WITH_INVARIANT:
                continue
            end = heads[n + 1].start() if n + 1 < len(heads) else len(text)
            body = text[m.start():end]
            if "**Invariant" not in body:
                findings.append("D-%03d has no **Invariant** paragraph" % num)

    for f in findings:
        print("  " + f)
    print("invariant practice check: %d finding(s)" % len(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
