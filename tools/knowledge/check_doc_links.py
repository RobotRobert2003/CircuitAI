#!/usr/bin/env python3
"""Verify that every relative Markdown link in this repository's documentation
resolves to a file that exists.

Nine links to a `doc/roles/hover.md` that was never written sat unnoticed
across the role documents, the knowledge index and AGENTS.md's repository map,
including one that told the reader to "**read this**". A link to a missing
document is worse than no link: it asserts the answer exists somewhere.

Scope: `*.md` under the directories in DIRS, plus the repository-root
instruction files. Absolute URLs, anchors and mailto: links are skipped;
anchors on a relative link are stripped before resolving, so `foo.md#bar`
checks `foo.md`.

Exit 0 when every link resolves, 1 otherwise. Run it before finishing any
documentation change.
"""
import io
import os
import re
import sys
from pathlib import Path
from documentation_store import require_docs, SOURCE_ROOT

DIRS = ['data/script', 'skills', 'tools/playtest', 'doc']
ROOT_FILES = ['AGENTS.md', 'README.md', 'BARB5_CHANGELOG.md']
LINK = re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')
SKIP_PREFIX = ('http://', 'https://', '#', 'mailto:')


def markdown_files():
    for path in require_docs().rglob('*.md'):
        yield str(path)
    for path in ROOT_FILES:
        if (SOURCE_ROOT/path).is_file():
            yield str(SOURCE_ROOT/path)
    for d in DIRS:
        for dirpath, _dirnames, filenames in os.walk(SOURCE_ROOT/d):
            for fn in sorted(filenames):
                if fn.endswith('.md'):
                    yield os.path.join(dirpath, fn)


def main():
    broken = []
    checked = 0
    for path in markdown_files():
        text = io.open(path, encoding='utf-8', errors='replace').read()
        for target in LINK.findall(text):
            if target.startswith(SKIP_PREFIX):
                continue
            rel = target.split('#', 1)[0]
            if not rel:
                continue
            checked += 1
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), rel))
            if not os.path.exists(resolved):
                broken.append((path, target, resolved))

    for src, target, resolved in broken:
        print('BROKEN %s -> %s (resolves to %s)'
              % (src.replace(os.sep, '/'), target, resolved.replace(os.sep, '/')))
    print('doc link check: %d relative link(s), %d broken' % (checked, len(broken)))
    return 1 if broken else 0


if __name__ == '__main__':
    sys.exit(main())
