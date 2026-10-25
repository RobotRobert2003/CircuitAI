#!/usr/bin/env python3
"""D-363: lint the AngelScript files a pull request changed, then the two whole-graph
checks that need no game and no external checkout.

Per changed file under data/script/:
  - every ``#include "..."`` resolves to a file (a dangling include leaves every AI
    standing at frame 0, see skills/ai-not-moving);
  - braces, parentheses and brackets balance outside strings and comments;
  - the committed blob has LF line endings (git ls-files --eol; CRLF in a blob
    means a tool wrote through the autocrlf working copy with the wrong newline mode);
  - a change under data_sample/ is reported as a warning: that tree is reference
    only (AGENTS.md).
Whole graph, whenever a script changed:
  - tools/knowledge/check_script_api.py: every aiXxx.Member the policy uses is
    registered in src/circuit/script/*.cpp (0 findings required);
  - tools/knowledge/check_field_isolation.py (0 findings required).
Findings are GitHub annotations (::error file=,line=) plus a step-summary table.
Exit 1 on any error.

  python tools/ci/lint_angelscript.py origin/smrt-test            # changed files from tools/ci/changed_files.sh
  python tools/ci/lint_angelscript.py origin/smrt-test a.as b.as  # these files
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INCLUDE = re.compile(r'^\s*#include\s+"([^"]+)"')
PAIRS = {'{': '}', '(': ')', '[': ']'}
CLOSERS = {v: k for k, v in PAIRS.items()}


def annotate(kind, path, line, title, message):
    where = f"file={path}" + (f",line={line}" if line else "")
    print(f"::{kind} {where},title={title}::{message}")


def strip_code(text):
    """Return the text with string literals and comments blanked (newlines kept),
    so bracket counting sees code only. Handles // and /* */ comments, "" strings
    with escapes, and AngelScript heredoc strings (triple quotes)."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append(re.sub(r'[^\n]', ' ', text[i:end]))
            i = end
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            j = min(j + 1, n)
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def check_file(rel):
    """Lint one script. Returns (errors, warnings)."""
    errors = warnings = 0
    path = os.path.join(ROOT, rel)
    raw = open(path, 'rb').read()
    # The committed blob, not the working copy: autocrlf gives Windows checkouts CRLF.
    eol = subprocess.run(['git', 'ls-files', '--eol', '--', rel], capture_output=True, text=True, cwd=ROOT).stdout
    if eol.startswith('i/crlf') or eol.startswith('i/mixed'):
        annotate('error', rel, None, 'line endings', f'{eol.split()[0]} committed; the repository stores LF')
        errors += 1
    text = raw.decode('utf-8', errors='replace')
    if rel.startswith('data_sample/'):
        annotate('warning', rel, None, 'reference tree', 'data_sample/ is reference only; the implementation target is data/ (AGENTS.md)')
        warnings += 1
    for number, line in enumerate(text.split('\n'), 1):
        m = INCLUDE.match(line)
        if m and not os.path.isfile(os.path.normpath(os.path.join(os.path.dirname(path), m.group(1)))):
            annotate('error', rel, number, 'include', f'#include "{m.group(1)}" does not resolve to a file')
            errors += 1
    stack = []
    for number, line in enumerate(strip_code(text).split('\n'), 1):
        for c in line:
            if c in PAIRS:
                stack.append((c, number))
            elif c in CLOSERS:
                if not stack or stack[-1][0] != CLOSERS[c]:
                    annotate('error', rel, number, 'brackets', f"unexpected '{c}'" + (f" (open '{stack[-1][0]}' from line {stack[-1][1]})" if stack else ''))
                    errors += 1
                    stack = []
                    break
                stack.pop()
    for opener, number in stack[:3]:
        annotate('error', rel, number, 'brackets', f"'{opener}' is never closed")
        errors += 1
    return errors, warnings


def run_checker(script):
    """Run a repository checker; return (ok, last line)."""
    result = subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'knowledge', script)],
                            capture_output=True, text=True, cwd=ROOT)
    output = (result.stdout + result.stderr).strip().splitlines()
    tail = output[-1] if output else ''
    if result.returncode != 0:
        for line in output[-20:]:
            print(line)
        annotate('error', 'data/script', None, script, tail or f'exit {result.returncode}')
    return result.returncode == 0, tail


def summary(lines):
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    base = argv[1]
    files = argv[2:]
    if not files:
        # the same selection as tools/ci/changed_files.sh angelscript, without a shell
        out = subprocess.run(['git', 'diff', '--name-only', '--diff-filter=ACMR', f'{base}...HEAD'],
                             capture_output=True, text=True, cwd=ROOT, check=True).stdout
        files = [f for f in out.splitlines() if re.match(r'^data/script/.*\.as$', f)]
    if not files:
        print('lint_angelscript: no AngelScript files changed')
        summary(['| Check | Files | Result |', '|---|---|---|', '| AngelScript lint | 0 | skipped, nothing changed |'])
        return 0
    print(f'lint_angelscript: {len(files)} changed script(s):')
    for f in files:
        print(f'  {f}')
    errors = warnings = 0
    for f in files:
        e, w = check_file(f)
        errors += e
        warnings += w
    rows = ['| Check | Files | Result |', '|---|---|---|',
            f'| includes, brackets, line endings | {len(files)} | {errors} error(s), {warnings} warning(s) |']
    for script in ('check_script_api.py', 'check_field_isolation.py'):
        ok, tail = run_checker(script)
        rows.append(f'| {script} (whole script graph) | all | {"ok" if ok else "FAILED"}: {tail} |')
        if not ok:
            errors += 1
    rows += ['', 'Changed scripts:'] + [f'- `{f}`' for f in files]
    summary(rows)
    print('lint_angelscript: clean' if errors == 0 else f'lint_angelscript: {errors} error(s)')
    return 0 if errors == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
