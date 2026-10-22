"""Locations shared by evidence publishers and isolated simulation runners.

Evidence, raw runs and retained build validations belong to the sibling
CircuitAI.benchmarks checkout.
Keep code/case definitions in CircuitAI. CIRCUIT_BENCHMARK_REPO permits another
checkout location without rewriting historical records or hardcoding a user.
"""
import os
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_REPO = Path(os.environ.get(
    'CIRCUIT_BENCHMARK_REPO', SOURCE_ROOT.parent / 'CircuitAI.benchmarks')).expanduser().resolve()
EVIDENCE_ROOT = BENCHMARK_REPO / 'doc/benchmarks'
RAW_ROOT = BENCHMARK_REPO / 'build-theatres'
VALIDATION_ROOT = BENCHMARK_REPO / 'build-validation'


def require_checkout():
    """Fail before creating a second, unversioned evidence store by accident."""
    if not (BENCHMARK_REPO / 'benchmark-store.json').is_file():
        raise FileNotFoundError(
            'Clone git@github.com:S3KCentrifugal/CircuitAI.benchmarks.git '
            f'to {BENCHMARK_REPO}, or set CIRCUIT_BENCHMARK_REPO to its checkout.')
    return BENCHMARK_REPO


def historical_path(path, source_root=SOURCE_ROOT):
    """Resolve old repository-relative evidence paths without changing records."""
    relative = Path(path)
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('Expected a contained repository-relative path')
    if (relative.parts[:2] in (('doc', 'benchmarks'), ('doc', 'images'))
            or relative.parts[:1] in (('build-theatres',), ('build-validation',))):
        return BENCHMARK_REPO / relative
    return Path(source_root) / relative


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('location', choices=('repo', 'evidence', 'raw', 'validation'))
    args = parser.parse_args()
    require_checkout()
    print({'repo': BENCHMARK_REPO, 'evidence': EVIDENCE_ROOT,
           'raw': RAW_ROOT, 'validation': VALIDATION_ROOT}[args.location])
