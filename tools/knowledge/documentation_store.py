"""Canonical CircuitAI documentation in the shared documentation checkout.

AI code, runnable skills, scenarios and observers stay in CircuitAI. Published
execution evidence stays in CircuitAI.benchmarks. Do not silently recreate a
second doc/ tree when the sibling checkout is absent.
"""
import os
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[2]
DOCS_REPO = Path(os.environ.get('CIRCUIT_DOCS_REPO', SOURCE_ROOT.parent / 'rjm.bar.docs')).expanduser().resolve()
DOC_ROOT = DOCS_REPO / 'projects/circuitai'


def require_docs():
    if not (DOC_ROOT / 'documentation-store.json').is_file():
        raise FileNotFoundError(f'CircuitAI documentation checkout missing: {DOC_ROOT}. '
                                'Clone rjm.bar.docs beside CircuitAI or set CIRCUIT_DOCS_REPO.')
    return DOC_ROOT


def document(relative):
    relative = Path(relative)
    if relative.anchor or '..' in relative.parts:
        raise ValueError('Expected a contained documentation path')
    return require_docs() / relative


if __name__ == '__main__':
    print(require_docs())
