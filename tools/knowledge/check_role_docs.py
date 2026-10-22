"""Check that projects/circuitai/roles/*.md is in step with data/script/src/roles/*.as.

For every role script:
  1. a document projects/circuitai/roles/<role>.md exists
  2. the document's `<!-- source: ...; blob: <hash>; lines: N -->` marker matches the
     script's current git blob hash and line count (stale marker = the script changed
     after the doc was last reviewed)
  3. every `<Role>_*` function defined in the script (not commented out) is named in
     the document
  4. every RoleConfig slot the script wires (`@cfg.<Slot> = ...` or the RoleConfig
     constructor's MainUpdate argument) is named in the document
  5. projects/circuitai/roles/README.md's handler coverage matrix agrees with the wiring

Run:   python tools/knowledge/check_role_docs.py            (exit 1 on findings)
       python tools/knowledge/check_role_docs.py --update    (rewrite the source
       markers after you have reviewed and updated the documents)

The staging hook in .githooks/pre-commit runs this; see projects/circuitai/roles/README.md,
"Keeping these documents current".
"""
from pathlib import Path
import io
import os
from documentation_store import document
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ROLES = os.path.join(ROOT, "data", "script", "src", "roles")
DOCS = str(document("roles"))
README = os.path.join(DOCS, "README.md")
MARKER = re.compile(r"<!--\s*source:\s*(?P<src>\S+);\s*blob:\s*(?P<blob>[0-9a-f]+);\s*lines:\s*(?P<lines>\d+)\s*-->")
FUNC = re.compile(r"^\s*(?:void|bool|string|int|uint|float|IUnitTask\s*@|CCircuitDef\s*@|CCircuitUnit\s*@|array<string>)\s*([A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+)\s*\(", re.M)
SLOT = re.compile(r"@cfg\.([A-Za-z]+)\s*=")
ROLE_NAME = {"air": "AIR", "front": "FRONT", "sea": "SEA", "support": "SUPPORT", "tactical": "TACTICAL", "tech": "TECH"}


def blob(path):
    return subprocess.check_output(["git", "hash-object", path], cwd=ROOT, text=True).strip()


def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"(?m)//.*$", "", src)


def script_facts(path):
    raw = io.open(path, encoding="utf-8", errors="replace").read()
    code = strip_comments(raw)
    funcs = sorted(set(FUNC.findall(code)))
    slots = set(SLOT.findall(code))
    if re.search(r"RoleConfig\(AiRole::\w+,\s*cast<MainUpdateDelegate", code):
        slots.add("MainUpdateHandler")
    return raw.count("\n") + (0 if raw.endswith("\n") else 1), funcs, sorted(slots)


def matrix_from_readme(text):
    """Return {slot: {ROLE: bool}} from the handler coverage matrix."""
    m = re.search(r"## Handler coverage matrix.*?\n\| Slot \|(.*?)\|\n\|[-: |]+\|\n(.*?)\n\n", text, re.S)
    if not m:
        return None, []
    roles = [c.strip() for c in m.group(1).split("|") if c.strip()]
    table = {}
    for line in m.group(2).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if not cells or cells[0].startswith("**"):
            continue
        slot = cells[0].strip("`")
        table[slot] = {r: ("yes" in c.lower()) for r, c in zip(roles, cells[1:])}
    return table, roles


def main(update=False):
    findings, updated = [], []
    readme = io.open(README, encoding="utf-8").read() if os.path.exists(README) else ""
    matrix, mroles = matrix_from_readme(readme)
    if matrix is None:
        findings.append("README.md: handler coverage matrix not found")

    scripts = sorted(Path(ROLES).rglob("*.as"))
    names = [path.stem for path in scripts]
    if len(names) != len(set(names)):
        findings.append("Role module basenames must be unique for documentation ownership")
    for path in scripts:
        role = path.stem
        script = str(path)
        doc = os.path.join(DOCS, role + ".md")
        rel_script = path.relative_to(ROOT).as_posix()
        if not os.path.exists(doc):
            findings.append("%s: no document projects/circuitai/roles/%s.md" % (rel_script, role))
            continue
        lines, funcs, slots = script_facts(script)
        h = blob(script)
        text = io.open(doc, encoding="utf-8").read()
        m = MARKER.search(text)
        if update:
            marker = "<!-- source: %s; blob: %s; lines: %d -->" % (rel_script, h, lines)
            new = MARKER.sub(marker, text) if m else text.rstrip("\n") + "\n\n" + marker + "\n"
            if new != text:
                io.open(doc, "w", encoding="utf-8", newline="\n").write(new)
                updated.append(doc)
            text = new
        elif m is None:
            findings.append("projects/circuitai/roles/%s.md: no source marker (run with --update after reviewing the document)" % role)
        elif m.group("blob") != h or int(m.group("lines")) != lines:
            findings.append("projects/circuitai/roles/%s.md: STALE - %s changed since the document was reviewed (marker blob %s/%s lines, script now %s/%d). Review the document, then run --update."
                            % (role, rel_script, m.group("blob")[:12], m.group("lines"), h[:12], lines))
        for fn in funcs:
            if fn not in text:
                findings.append("projects/circuitai/roles/%s.md: function %s not mentioned" % (role, fn))
        for s in slots:
            if s not in text:
                findings.append("projects/circuitai/roles/%s.md: wired slot %s not mentioned" % (role, s))
        if matrix is not None:
            R = ROLE_NAME.get(role, role.upper())
            if R in mroles:
                for slot, row in matrix.items():
                    wired = slot in slots
                    if row.get(R) != wired:
                        findings.append("README.md matrix: %s x %s says %s, script wiring says %s" % (slot, R, "yes" if row.get(R) else "no", "yes" if wired else "no"))
                for s in slots:
                    if s not in matrix:
                        findings.append("README.md matrix: slot %s (wired by %s) missing from the matrix" % (s, R))

    print("role docs check: %d finding(s)" % len(findings))
    for x in findings:
        print("  -", x)
    for u in updated:
        print("  updated marker:", os.path.relpath(u, ROOT).replace("\\", "/"))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(update="--update" in sys.argv))
