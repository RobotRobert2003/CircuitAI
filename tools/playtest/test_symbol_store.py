import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from symbol_store import stage_symbols


class SymbolStoreTests(unittest.TestCase):
    def test_cleanup_retains_unique_symbols_and_ignores_mutable_builds(self):
        import deduplicate_symbols
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            for name, content in [('one', b'abcd'), ('two', b'abcd'), ('three', b'efgh')]:
                path = root/'build-theatres'/name/'AI/Skirmish/Test/test/SkirmishAI.dbg'
                path.parent.mkdir(parents=True)
                path.write_bytes(content)
                paths.append(path)
            mutable = root/'build-validation/build/SkirmishAI.dbg'
            mutable.parent.mkdir(parents=True)
            mutable.write_bytes(b'abcd')
            with patch.object(deduplicate_symbols, 'require_checkout', return_value=root), patch('sys.argv', ['cleanup', '--apply']):
                deduplicate_symbols.main()
            self.assertTrue(os.path.samefile(paths[0], paths[1]))
            self.assertFalse(os.path.samefile(paths[0], paths[2]))
            self.assertFalse(os.path.samefile(paths[0], mutable))
            self.assertEqual(paths[2].read_bytes(), b'efgh')

    def test_dedup_and_restage_preserve_old_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, first, second = [root / name for name in ('build.dbg', 'first.dbg', 'second.dbg')]
            source.write_bytes(b'old symbols')
            stage_symbols(source, first, root/'pool')
            stage_symbols(source, second, root/'pool')
            self.assertTrue(os.path.samefile(first, second))
            self.assertFalse(os.path.samefile(source, first))
            source.write_bytes(b'new symbols')
            stage_symbols(source, first, root/'pool')
            self.assertEqual(second.read_bytes(), b'old symbols')
            self.assertEqual(first.read_bytes(), b'new symbols')

    def test_corrupt_pool_does_not_replace_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root/'build.dbg', root/'archive.dbg'
            source.write_bytes(b'symbols')
            checksum = stage_symbols(source, destination, root/'pool')
            (root/'pool'/(checksum+'.dbg')).write_bytes(b'corrupted')
            destination.unlink()
            destination.write_bytes(b'preserve me')
            with self.assertRaises(RuntimeError):
                stage_symbols(source, destination, root/'pool')
            self.assertEqual(destination.read_bytes(), b'preserve me')


if __name__ == '__main__':
    unittest.main()
