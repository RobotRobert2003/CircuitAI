"""Validate data/script/src/helpers/units/unit_helpers.as (and other scripts) against the shared game cache.

Checks:
  1. every quoted arm*/cor*/leg* id in data/script/src exists in BAR and is reachable from a commander build tree
  2. faction-named lists (GetArmada*/GetCortex*/GetLegion*) contain only that faction's ids
  3. tier-named lists (T1/T2/T3) contain units of that tier
  4. per-side helpers (`side == "legion"`) return an id of that side
  5. the T1/T2 land, T1 air, T2 air, T1 naval and T1 hover combat lists cover the labs' effective buildoptions

Run:  python tools/knowledge/check_unit_helpers.py        (exit 1 on any finding in checks 1-4)
Cache: ../rjm.bar.docs/tools/knowledge/.cache/kb.json (BAR_DOCS_DIR overrides the docs repo path).
"""
import glob
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DOCS = os.environ.get("BAR_DOCS_DIR", os.path.abspath(os.path.join(ROOT, "..", "rjm.bar.docs")))
CACHE = os.path.join(DOCS, "tools", "knowledge", ".cache", "kb.json")
HELPERS = os.path.join(ROOT, "data", "script", "src", "helpers", "units", "unit_helpers.as")
SIDE_WORDS = {"armada", "cortex", "legion"}
ID_RE = re.compile(r'"((?:arm|cor|leg)[a-z0-9_]{2,})"')
# ids in generic/aggregate lists that are deliberately not from the lab in question
IGNORE_UNREACHABLE = set()


def load_kb():
    with open(CACHE, encoding="utf-8") as fh:
        return json.load(fh)


def functions(src):
    """Yield (name, args, body) for every function in the file."""
    for m in re.finditer(r'^\s*(?:array<string>|string|bool|int|void|dictionary)\s+(\w+)\s*\(([^)]*)\)\s*\{', src, re.M):
        i, d = m.end(), 1
        while d and i < len(src):
            d += {"{": 1, "}": -1}.get(src[i], 0)
            i += 1
        yield m.group(1), m.group(2), src[m.end():i - 1]


def ids_in(body):
    return [x for x in ID_RE.findall(body) if x not in SIDE_WORDS]


def faction(uid):
    return {"arm": "armada", "cor": "cortex", "leg": "legion"}.get(uid[:3], "?")


def tier(u):
    return u["customparams"].get("techlevel") or 1


def main():
    kb = load_kb()
    U = kb["units"]
    N = kb["names"]["names"]
    findings = []

    # 1. unknown / unreachable ids across all scripts (comments stripped)
    for f in glob.glob(os.path.join(ROOT, "data", "script", "src", "**", "*.as"), recursive=True):
        rel = os.path.relpath(f, ROOT).replace("\\", "/")
        if "/systems/production/factory_configs/" in rel:
            continue  # dead code path (UseDynamicFactoryProduction = false everywhere)
        s = re.sub(r"//[^\n]*", "", io.open(f, encoding="utf-8", errors="replace").read())
        for uid in sorted(set(ids_in(s))):
            if uid not in U:
                findings.append("UNKNOWN id %r in %s" % (uid, rel))
            elif not U[uid].get("reachable") and uid not in IGNORE_UNREACHABLE:
                findings.append("UNREACHABLE id %r (%s) in %s" % (uid, N.get(uid), rel))

    src = io.open(HELPERS, encoding="utf-8", errors="replace").read()
    for name, args, body in functions(src):
        lst = ids_in(body)
        # 2. faction lists
        for fac in ("Armada", "Cortex", "Legion"):
            if fac in name:
                for uid in lst:
                    if uid in U and faction(uid) != fac.lower():
                        findings.append("%s: %s is %s in a %s list" % (name, uid, faction(uid), fac))
        # 3. tier lists (names with Labs/Combat/Constructors/Builders/Plants/Shipyards)
        want = {"T1": {1, 1.5}, "T2": {2}, "T3": {3}}
        for tag, tiers in want.items():
            if re.search(tag + r"(?!\.5)", name) and any(k in name for k in ("Combat", "Constructor", "Builder", "Gantr", "T3")):
                for uid in lst:
                    if uid in U and tier(U[uid]) not in tiers:
                        findings.append("%s: %s is T%g" % (name, uid, tier(U[uid])))
        # 4. per-side returns
        if "side" in args:
            for m in re.finditer(r'side\s*==\s*"(\w+)"\)\s*(?:\{\s*)?(?:return\s*|ids\s*=\s*\{\s*)"((?:arm|cor|leg)[a-z0-9_]+)"', body):
                if faction(m.group(2)) != m.group(1):
                    findings.append("%s: branch %s returns %s" % (name, m.group(1), m.group(2)))

    # 5. coverage report (informational)
    def fn(name):
        for n, a, b in functions(src):
            if n == name:
                return b
        return ""

    def combat(uid):
        u = U[uid]
        return (u.get("speed") or 0) > 0 and u["weapondefs"] and not u.get("workertime")

    report = []
    for label, labs, lname, tiers in [
            ("T1 land armada", ["armlab", "armvp"], "GetArmadaT1CombatUnits", {1, 1.5}), ("T1 land cortex", ["corlab", "corvp"], "GetCortexT1CombatUnits", {1, 1.5}),
            ("T1 land legion", ["leglab", "legvp"], "GetLegionT1CombatUnits", {1, 1.5}), ("T2 land armada", ["armalab", "armavp"], "GetArmadaT2CombatUnits", {2}),
            ("T2 land cortex", ["coralab", "coravp"], "GetCortexT2CombatUnits", {2}), ("T2 land legion", ["legalab", "legavp"], "GetLegionT2CombatUnits", {2}),
            ("T1 air", ["armap", "corap", "legap"], "GetAllT1AircraftCombatUnits", None), ("T2 air", ["armaap", "coraap", "legaap"], "GetAllT2AircraftCombatUnits", None),
            ("T1 naval", ["armsy", "corsy", "legsy"], "GetAllT1NavalCombatUnits", None), ("T1 hover", ["armhp", "corhp", "leghp"], "GetAllT1HoverCombatUnits", None)]:
        body = fn(lname)
        have = set(ids_in(body))
        for sub in re.findall(r"(Get\w+)\(", body):
            if sub != lname:
                have |= set(ids_in(fn(sub)))
        avail = {x for l in labs for x in U[l]["buildoptions"] if x in U and combat(x) and (tiers is None or tier(U[x]) in tiers)}
        miss = sorted(avail - have)
        if miss:
            report.append("%s: not in %s: %s" % (label, lname, ", ".join("%s (%s)" % (x, N.get(x)) for x in miss)))

    print("unit_helpers check against BAR %s" % kb["meta"]["bar_commit"])
    print("findings: %d" % len(findings))
    for f in findings:
        print("  -", f)
    print("coverage gaps (informational): %d" % len(report))
    for r in report:
        print("  -", r)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
