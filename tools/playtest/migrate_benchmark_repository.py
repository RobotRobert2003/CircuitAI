"""Snapshot or verify a same-volume benchmark-repository migration.

This tool never moves or deletes data. Published evidence and build-validation
files get SHA-256 checks; build-theatres files get an inventory of size, mtime
and attributes. Moving the directory on the same volume preserves its file
identity, hard links and NTFS
compression without reading/decompressing hundreds of GB of generated files.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path

TREES = ('doc/benchmarks', 'doc/images', 'build-theatres')
REPARSE = 0x400


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def entries(root, tree):
    base = root / tree
    pending = [base]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as children:
            for entry in children:
                path = Path(entry.path)
                stat = entry.stat(follow_symlinks=False)
                relative = path.relative_to(root).as_posix()
                attributes = getattr(stat, 'st_file_attributes', 0)
                directory_entry = entry.is_dir(follow_symlinks=False)
                # Do not walk directory junctions into an unrelated checkout.
                if entry.is_symlink() or (directory_entry and attributes & REPARSE):
                    yield {'path': relative, 'kind': 'link', 'target': os.readlink(path)}
                elif directory_entry:
                    yield {'path': relative, 'kind': 'directory'}
                    pending.append(path)
                else:
                    row = {'path': relative, 'kind': 'file', 'bytes': stat.st_size,
                           'mtime_ns': stat.st_mtime_ns, 'attributes': attributes}
                    if tree != 'build-theatres':
                        row['sha256'] = digest(path)
                    yield row


def identity(path):
    stat = path.stat()
    return [stat.st_dev, stat.st_ino]


def selected_trees(trees):
    """Reject escapes and overlapping inventories before touching the manifest."""
    result = tuple(trees)
    if not result:
        raise ValueError('Select at least one migration tree')
    for tree in result:
        path = Path(tree)
        if path.anchor or '..' in path.parts or not path.parts or path.as_posix() != tree:
            raise ValueError('Expected a contained normalized relative tree: ' + tree)
    for i, tree in enumerate(result):
        for other in result[i + 1:]:
            if Path(tree).is_relative_to(other) or Path(other).is_relative_to(tree):
                raise ValueError('Migration trees overlap: ' + tree + ', ' + other)
    return result


def snapshot(source, manifest_dir, trees=TREES):
    trees = selected_trees(trees)
    for tree in trees:
        path = source / tree
        if (not path.is_dir() or path.is_symlink()
                or getattr(path.lstat(), 'st_file_attributes', 0) & REPARSE):
            raise ValueError('Expected an original directory, not a link: ' + str(path))
    if any(manifest_dir.resolve().is_relative_to((source / tree).resolve()) for tree in trees):
        raise ValueError('Keep the manifest outside the trees being migrated')
    manifest_dir.mkdir(parents=True, exist_ok=False)
    summary = {'schema': 1, 'source': str(source), 'trees': {},
               'verification': 'SHA-256 for all trees except build-theatres; same-volume root identity '
                               'and file size/mtime/attributes for raw working data.'}
    with gzip.open(manifest_dir / 'files.jsonl.gz', 'wt', encoding='utf-8') as output:
        for tree in trees:
            stats = {'identity': identity(source / tree), 'files': 0, 'bytes': 0, 'entries': 0}
            for row in entries(source, tree):
                output.write(json.dumps(row, separators=(',', ':')) + '\n')
                stats['entries'] += 1
                if row['kind'] == 'file':
                    stats['files'] += 1
                    stats['bytes'] += row['bytes']
            summary['trees'][tree] = stats
            print(tree, json.dumps(stats), flush=True)
    summary['inventory_sha256'] = digest(manifest_dir / 'files.jsonl.gz')
    (manifest_dir / 'manifest.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')


def verify(destination, manifest_dir):
    summary = json.loads((manifest_dir / 'manifest.json').read_text(encoding='utf-8'))
    if digest(manifest_dir / 'files.jsonl.gz') != summary['inventory_sha256']:
        raise ValueError('Migration inventory changed')
    with gzip.open(manifest_dir / 'files.jsonl.gz', 'rt', encoding='utf-8') as stream:
        expected = {row['path']: row for row in map(json.loads, stream)}
    counts = {}
    # Read the manifest's selection, so old three-tree migrations and later
    # build-validation-only moves both remain verifiable with the same tool.
    for tree in selected_trees(summary['trees']):
        if identity(destination / tree) != summary['trees'][tree]['identity']:
            raise ValueError('Expected original directory identity after same-volume move: ' + tree)
        count = 0
        for actual in entries(destination, tree):
            if expected.pop(actual['path'], None) != actual:
                raise ValueError('Migrated entry differs: ' + actual['path'])
            count += 1
        counts[tree] = count
        print('Verified', tree, count, 'entries', flush=True)
    if expected:
        raise ValueError('Missing migrated entries: ' + ', '.join(list(expected)[:10]))
    result = {'verified': True, 'destination': str(destination), 'entries': counts,
              'inventory_sha256': summary['inventory_sha256'],
              'verification': summary['verification']}
    (manifest_dir / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('snapshot', 'verify'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--tree', action='append', help='Snapshot only this relative tree; repeat to select more. Verify reads the manifest.')
    args = parser.parse_args()
    root, manifest = args.root.resolve(), args.manifest.resolve()
    if args.operation == 'snapshot':
        snapshot(root, manifest, args.tree if args.tree is not None else TREES)
    else:
        if args.tree is not None:
            parser.error('--tree applies only to snapshot; verify uses the manifest')
        verify(root, manifest)


if __name__ == '__main__':
    main()
