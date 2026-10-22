#!/usr/bin/env python3
"""Check that every native member the AngelScript policy uses is registered.

Two checks, both cheap and both catch "the AI does not move at game start":

  1. source parity: every `aiXxx.Member` / `ai.Member` used under data/script
     is registered by a RegisterObjectMethod/RegisterObjectProperty call in
     src/circuit/script/*.cpp (the declaration strings are parsed);
  2. binary parity (--dll PATH): every registration declaration the script
     relies on is present as a literal string inside that SkirmishAI.dll, so
     a script deployed ahead of its DLL (or a DLL copied mid-build) is caught
     before the game is launched.

Usage:
  python tools/knowledge/check_script_api.py
  python tools/knowledge/check_script_api.py --dll "%LOCALAPPDATA%/Programs/Beyond-All-Reason/data/engine/recoil_2026.07.04/AI/Skirmish/SMRTBARb/stable/SkirmishAI.dll"

Exit code 1 on any finding. See skills/ai-not-moving/SKILL.md.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT_SRC = os.path.join(ROOT, "src", "circuit", "script")
SCRIPT_DIR = os.path.join(ROOT, "data", "script")

RE_METHOD = re.compile(r'RegisterObjectMethod\("(\w+)",\s*"([^"]+)"')
RE_PROPERTY = re.compile(r'RegisterObjectProperty\("(\w+)",\s*"([^"]+)"')
RE_GLOBAL_PROP = re.compile(r'RegisterGlobalProperty\("([^"]+)"')
RE_GLOBAL_FUNC = re.compile(r'RegisterGlobalFunction\("([^"]+)"')
RE_USE = re.compile(r'\b(ai[A-Z]\w*|ai)\.(\w+)')


def member_name(decl):
    """'int Foo(const string& in) const' -> 'Foo'; 'const float costM' -> 'costM'."""
    head = decl.split("(", 1)[0].strip()
    return head.split()[-1]


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def registrations():
    """type -> {member: declaration}; globals: name -> type; global functions: names."""
    members = {}
    global_types = {}
    global_funcs = set()
    decls = []
    for name in sorted(os.listdir(SCRIPT_SRC)):
        if not name.endswith(".cpp"):
            continue
        text = read(os.path.join(SCRIPT_SRC, name))
        for typ, decl in RE_METHOD.findall(text) + RE_PROPERTY.findall(text):
            members.setdefault(typ, {})[member_name(decl)] = decl
            decls.append(decl)
        for decl in RE_GLOBAL_PROP.findall(text):
            parts = decl.split()
            if len(parts) >= 2:
                global_types[parts[-1]] = parts[-2]
        for decl in RE_GLOBAL_FUNC.findall(text):
            global_funcs.add(member_name(decl))
    return members, global_types, global_funcs


def script_uses(script_dir=SCRIPT_DIR):
    """(file, line, global, member) for every aiXxx.member in the policy scripts."""
    uses = []
    for dirpath, _, files in os.walk(script_dir):
        for name in files:
            if not name.endswith(".as"):
                continue
            path = os.path.join(dirpath, name)
            try:
                shown = os.path.relpath(path, ROOT)
            except ValueError:  # staged scripts on another drive (benchmark store on H:)
                shown = path
            for lineno, line in enumerate(read(path).splitlines(), 1):
                code = line.split("//", 1)[0]
                for g, m in RE_USE.findall(code):
                    uses.append((shown, lineno, g, m))
    return uses


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll", help="SkirmishAI.dll to check the used declarations against")
    ap.add_argument("--scripts", default=SCRIPT_DIR, help="Exact staged script tree; defaults to active repository data/script")
    args = ap.parse_args(argv)

    members, global_types, _ = registrations()
    if not os.path.isdir(args.scripts):
        print("Script directory not found: %s" % args.scripts)
        return 1
    uses = script_uses(args.scripts)
    findings = 0
    needed_decls = {}
    for path, lineno, g, m in uses:
        typ = global_types.get(g)
        if typ is None:
            continue  # a script-side global that happens to start with "ai"
        decl = members.get(typ, {}).get(m)
        if decl is None:
            print("UNREGISTERED %s:%d  %s.%s (type %s)" % (path, lineno, g, m, typ))
            findings += 1
        else:
            needed_decls.setdefault(decl, (path, lineno, g, m))

    if args.dll:
        dll_path = os.path.expandvars(args.dll)
        if not os.path.isfile(dll_path):
            print("DLL not found: %s" % dll_path)
            return 1
        size = os.path.getsize(dll_path)
        if size > 64 * 1024 * 1024:
            print("SUSPECT DLL size %d bytes (a stripped SkirmishAI.dll is about 7 MB; this is unstripped or a mid-build copy)" % size)
            findings += 1
        with open(dll_path, "rb") as f:
            blob = f.read()
        for decl, (path, lineno, g, m) in sorted(needed_decls.items()):
            if decl.encode("utf-8") not in blob:
                print("MISSING IN DLL %s.%s  (%s:%d) declaration %r" % (g, m, path, lineno, decl))
                findings += 1
        print("script api check: %d used member(s) checked against %s" % (len(needed_decls), dll_path))
    else:
        print("script api check: %d used member(s) checked against the source registrations" % len(needed_decls))
    print("script api check: %d finding(s)" % findings)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
