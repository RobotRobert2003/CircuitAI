"""Catalog tests protect definition discovery and evidence separation."""
import unittest
import index_test_cases as catalog


class CatalogTests(unittest.TestCase):
    def test_domains_follow_paths_and_suites(self):
        from pathlib import Path
        self.assertEqual(catalog.domain(Path('tools/playtest/cases/sea/combat/submarine-screen.json')), 'sea')
        self.assertEqual(catalog.domain(Path('tests/air_math_tests.as')), 'air')
        self.assertEqual(catalog.domain(Path('tests/local_reservations_test.cpp')), 'shared')

    def test_every_categorized_definition_is_present_once(self):
        rows = catalog.discover()
        ids = [r['id'] for r in rows]
        self.assertEqual(len(ids), len(set(ids)))
        for kind in ('cases', 'checks'):
            for p in (catalog.ROOT / 'tools/playtest' / kind).rglob('*.json'):
                self.assertIn(p.relative_to(catalog.ROOT).as_posix(), ids)
        self.assertTrue(all(r['execution'] == 'not inferred' for r in rows))
        self.assertTrue(all('/runs/' not in r['id'] for r in rows))

    def test_standalone_probes_and_observers_are_discoverable(self):
        rows = {r['id']: r for r in catalog.discover()}
        for base, pattern in [('tools/playtest', '*.as'), ('tools/playtest/widgets', '*.lua')]:
            for path in (catalog.ROOT / base).glob(pattern):
                row = rows[path.relative_to(catalog.ROOT).as_posix()]
                self.assertEqual(row['kind'], 'fixture/observer')
                self.assertEqual(row['execution'], 'not inferred')


if __name__ == '__main__':
    unittest.main()
