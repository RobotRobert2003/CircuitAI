"""External evidence ownership, path safety and migration preservation."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import benchmark_store
import migrate_benchmark_repository as migration
import storage
from test_storage import archived_game


class BenchmarkStoreTests(unittest.TestCase):
    def test_environment_override_selects_another_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, CIRCUIT_BENCHMARK_REPO=tmp)
            value = subprocess.check_output(
                [sys.executable, '-c', 'import benchmark_store; print(benchmark_store.EVIDENCE_ROOT)'],
                cwd=Path(__file__).parent, env=env, text=True).strip()
            self.assertEqual(Path(value), Path(tmp).resolve() / 'doc/benchmarks')

    def test_missing_checkout_fails_before_creating_run_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            external = Path(tmp) / 'missing'
            with patch.object(benchmark_store, 'BENCHMARK_REPO', external), \
                    patch.object(storage, 'RAW_ROOT', external / 'build-theatres'):
                with self.assertRaisesRegex(FileNotFoundError, 'Clone'):
                    storage.allocate('air', 'combat', 'edge', 'glitters', 'supplied')
            self.assertFalse(external.exists())

    def test_default_allocator_uses_external_raw_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            external = Path(tmp)
            (external / 'benchmark-store.json').write_text('{}')
            with patch.object(benchmark_store, 'BENCHMARK_REPO', external), \
                    patch.object(storage, 'RAW_ROOT', external / 'build-theatres'):
                folder = storage.allocate('sea', 'combat', 'subs', 'supreme', 'supplied')
            self.assertTrue(folder.is_relative_to(external / 'build-theatres/games/sea/combat/subs/supreme'))
            self.assertTrue((folder / 'run-plan.json').is_file())

    def test_default_publisher_keeps_failure_in_external_evidence_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            external = Path(tmp) / 'external'
            external.mkdir()
            (external / 'benchmark-store.json').write_text('{}')
            _, archive = archived_game(Path(tmp) / 'fixtures')
            with patch.object(benchmark_store, 'BENCHMARK_REPO', external), \
                    patch.object(storage, 'EVIDENCE_ROOT', external / 'doc/benchmarks'):
                result = storage.publish(archive)
            self.assertTrue(result.is_relative_to(external / 'doc/benchmarks/records'))
            self.assertEqual(storage.read_json(result / 'result.json')['verdict'], 'FAIL')

    def test_historical_evidence_resolves_without_rewriting_old_manifest(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(benchmark_store, 'BENCHMARK_REPO', Path(tmp)):
            self.assertEqual(benchmark_store.historical_path('doc/benchmarks/tech-rush.md'),
                             Path(tmp) / 'doc/benchmarks/tech-rush.md')

    def test_historical_path_refuses_traversal(self):
        with self.assertRaises(ValueError):
            benchmark_store.historical_path('../outside')

    def test_validation_location_honors_checkout_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            checkout = Path(tmp) / 'benchmark store'
            checkout.mkdir()
            (checkout / 'benchmark-store.json').write_text('{}')
            env = dict(os.environ, CIRCUIT_BENCHMARK_REPO=str(checkout))
            value = subprocess.check_output(
                [sys.executable, str(Path(benchmark_store.__file__)), 'validation'],
                env=env, text=True).strip()
            self.assertEqual(Path(value), checkout.resolve() / 'build-validation')
            self.assertFalse((checkout / 'build-validation').exists())

    def test_validation_location_fails_closed_when_checkout_is_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [sys.executable, str(Path(benchmark_store.__file__)), 'validation'],
                env=dict(os.environ, CIRCUIT_BENCHMARK_REPO=tmp),
                text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Clone', result.stderr)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_historical_build_paths_resolve_without_a_source_junction(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(benchmark_store, 'BENCHMARK_REPO', Path(tmp)):
            for name in ('build-validation/b04/source.zip', 'build-theatres/old/report.md'):
                self.assertEqual(benchmark_store.historical_path(name), Path(tmp) / name)
            self.assertEqual(benchmark_store.historical_path('tests/terrain_route_test.cpp'),
                             benchmark_store.SOURCE_ROOT / 'tests/terrain_route_test.cpp')


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        self.dest = self.root / 'destination'
        self.manifest = self.root / 'manifest'
        for tree in migration.TREES:
            path = self.source / tree
            path.mkdir(parents=True)
            (path / 'original.txt').write_bytes(b'original\r\nretained bytes\n')
        with contextlib.redirect_stdout(io.StringIO()):
            migration.snapshot(self.source, self.manifest)
        for tree in migration.TREES:
            dest = self.dest / tree
            dest.parent.mkdir(parents=True, exist_ok=True)
            (self.source / tree).rename(dest)

    def test_same_volume_move_preserves_evidence_and_original_directory_identity(self):
        with contextlib.redirect_stdout(io.StringIO()):
            result = migration.verify(self.dest, self.manifest)
        self.assertTrue(result['verified'])

    def test_published_content_change_is_detected_even_with_original_size_and_mtime(self):
        path = self.dest / 'doc/benchmarks/original.txt'
        stat = path.stat()
        path.write_bytes(path.read_bytes().replace(b'original', b'modified'))
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, 'differs'):
            migration.verify(self.dest, self.manifest)

    def test_extra_raw_file_is_detected(self):
        (self.dest / 'build-theatres/unrecorded.txt').write_text('unexpected')
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, 'differs'):
            migration.verify(self.dest, self.manifest)

    def test_missing_raw_file_is_detected(self):
        (self.dest / 'build-theatres/original.txt').unlink()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, 'Missing'):
            migration.verify(self.dest, self.manifest)


class ValidationMigrationTests(unittest.TestCase):
    def test_selected_validation_tree_is_hashed_and_other_trees_are_not_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, dest, manifest = root / 'source', root / 'dest', root / 'manifest'
            tree = source / 'build-validation'
            tree.mkdir(parents=True)
            (tree / 'pin.log').write_bytes(b'original\r\n')
            with contextlib.redirect_stdout(io.StringIO()):
                migration.snapshot(source, manifest, ('build-validation',))
                dest.mkdir()
                tree.rename(dest / tree.name)
                self.assertTrue(migration.verify(dest, manifest)['verified'])
            summary = json.loads((manifest / 'manifest.json').read_text())
            self.assertEqual(list(summary['trees']), ['build-validation'])
            pin = dest / 'build-validation/pin.log'
            stat = pin.stat()
            pin.write_bytes(b'modified\r\n')
            os.utime(pin, ns=(stat.st_atime_ns, stat.st_mtime_ns))
            with self.assertRaisesRegex(ValueError, 'differs'):
                migration.verify(dest, manifest)

    def test_unsafe_or_overlapping_tree_selection_is_rejected(self):
        for trees in (('../outside',), ('.',), ('/outside',),
                      ('build-validation', 'build-validation'),
                      ('build-validation', 'build-validation/pins')):
            with self.subTest(trees=trees), self.assertRaises(ValueError):
                migration.selected_trees(trees)

    def test_manifest_inside_moved_tree_is_rejected_before_creation(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            tree = source / 'build-validation'
            tree.mkdir()
            with self.assertRaisesRegex(ValueError, 'outside'):
                migration.snapshot(source, tree / 'manifest', ('build-validation',))
            self.assertEqual(list(tree.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
