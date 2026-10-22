"""Keep the benchmark workspace small: retain comparison evidence, delete bulk.

D-339 (2026-10-19) replaces the earlier keep-every-raw-file policy (D-213,
D-178 raw retention). The owner's budget is the whole CircuitAI.benchmarks
checkout under 5 GB. What a later comparison needs is the verdict and the
measurements, not the engine's working files:

  kept     every Git-tracked or not-ignored file (published bundles, ledgers,
           indices, pending owner edits), and in the ignored raw trees
           (build-theatres/, build-validation/) small result files: .json,
           .jsonl, .md, .csv, .tsv and script.txt up to --max-kib each
           (report.md, result.json, checks, manifests, summaries, staged.json
           with the DLL hash, teams.json, the game setup).
  deleted  everything else in the raw trees: infologs and launcher logs,
           screenshots, replays, staged DLL/debug-symbol copies, staged
           script/config snapshots (AI/Skirmish/**; the manifest's data hashes
           and Git history identify them), engine caches, LuaUI configs, object
           caches, linker intermediates and symbol pools.

Publish what a comparison needs (storage.py publish, with a screenshot if
wanted) BEFORE pruning. Paths passed with --keep (an active pin, a run still
being analysed) are retained whole. Dry run by default; --apply deletes.
Never follows or deletes reparse points (the old source-checkout junction).
Refuses to run while any engine writes inside the benchmark checkout.

  python tools/playtest/prune_benchmarks.py                       # dry run, whole store
  python tools/playtest/prune_benchmarks.py --apply --path <game dir>   # after one game
  python tools/playtest/prune_benchmarks.py --apply --keep <session>/pin
"""
import argparse, json, os, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import benchmark_store  # noqa: E402

KEEP_EXT = {'.json', '.jsonl', '.md', '.csv', '.tsv'}
KEEP_NAMES = {'script.txt'}
# Engine working trees inside a game write dir: never evidence.
DROP_DIRS = {'AI', 'cache', 'fontcache', 'music', 'temp', 'LuaUI', 'screenshots', 'demos', 'symbols'}
REPARSE = 0x400


def engines_in(root):
    """Command lines of running engines whose write dir is inside root."""
    query = ("Get-CimInstance Win32_Process -Filter \"Name='spring.exe' or Name='spring-headless.exe'\" "
             "| ForEach-Object { $_.CommandLine }")
    try:
        out = subprocess.run(['powershell', '-NoProfile', '-Command', query], capture_output=True,
                             text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        raise SystemExit('ERROR: cannot list engine processes; refusing to prune')
    needle = str(root).lower().replace('/', '\\')
    return [line for line in out.splitlines() if needle in line.lower().replace('/', '\\')]


def ignored_tops(repo):
    """The ignored raw trees; everything else in the checkout is left alone."""
    return [p for p in (benchmark_store.RAW_ROOT, benchmark_store.VALIDATION_ROOT) if p.is_dir()]


def keep_file(path, max_bytes):
    parts = set(path.parts)
    if parts & DROP_DIRS or 'storage-audit' in parts:
        return False
    if path.name in KEEP_NAMES or path.suffix.lower() in KEEP_EXT:
        try:
            return path.stat().st_size <= max_bytes
        except OSError:
            return True
    return False


def walk(top, keep):
    """Yield (path, size, delete?) without descending into reparse points."""
    stack = [top]
    while stack:
        d = stack.pop()
        if any(d == k or k in d.parents for k in keep):
            continue
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if e.is_symlink() or (getattr(st, 'st_file_attributes', 0) & REPARSE):
                continue
            p = Path(e.path)
            if e.is_dir(follow_symlinks=False):
                stack.append(p)
            else:
                yield p, st.st_size, st.st_nlink


def prune_empty(top, keep):
    for d, dirs, files in os.walk(top, topdown=False):
        p = Path(d)
        if p == top or any(p == k or k in p.parents for k in keep):
            continue
        try:
            if not os.listdir(p) and not (os.stat(p, follow_symlinks=False).st_file_attributes & REPARSE):
                os.rmdir(p)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--apply', action='store_true', help='delete; default is a dry run')
    ap.add_argument('--path', action='append', type=Path, default=[],
                    help='prune only these dirs (inside build-theatres/ or build-validation/); default both trees')
    ap.add_argument('--keep', action='append', type=Path, default=[], help='retain this path whole')
    # Metrics outputs (full-match-performance-v1.json is ~7 MiB) are the point
    # of a run; the cap only stops a stray multi-GB dump being kept.
    ap.add_argument('--max-kib', type=int, default=65536, help='largest result file kept (KiB)')
    a = ap.parse_args()
    repo = benchmark_store.require_checkout()
    tops = ignored_tops(repo)
    targets = [p.resolve() for p in a.path] or tops
    for t in targets:
        if not any(t == top or top in t.parents for top in tops):
            ap.error(f'{t} is not inside build-theatres/ or build-validation/')
    live = engines_in(repo)
    if live:
        raise SystemExit('ERROR: an engine is writing inside the benchmark checkout; stop it first:\n' + '\n'.join(live))
    keep = [k.resolve() for k in a.keep]
    max_bytes = a.max_kib * 1024
    kept = removed = kept_n = removed_n = failed = 0
    for top in targets:
        for path, size, _ in walk(top, keep):
            if keep_file(path, max_bytes):
                kept += size; kept_n += 1
                continue
            removed += size; removed_n += 1
            if a.apply:
                try:
                    path.unlink()
                except OSError:
                    failed += 1
        if a.apply:
            prune_empty(top, keep)
    G = 2 ** 30
    print(json.dumps({'mode': 'apply' if a.apply else 'dry-run', 'targets': [str(t) for t in targets],
                      'kept_files': kept_n, 'kept_gib': round(kept / G, 3),
                      'removed_files': removed_n, 'removed_gib_logical': round(removed / G, 2),
                      'failed': failed, 'kept_whole': [str(k) for k in keep]}, indent=1))
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
