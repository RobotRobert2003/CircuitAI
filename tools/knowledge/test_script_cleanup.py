"""Regression tests for deletion-only cleanup acceptance."""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from check_script_cleanup import verify


class CleanupTests(unittest.TestCase):
    def check(self, candidate):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            before, after = root/'before', root/'after'
            for folder in (before, after):
                (folder/'script').mkdir(parents=True)
            (before/'script/main.as').write_text('int Gone(){return 4;}\nint Live(){return 2;}')
            (after/'script/main.as').write_text(candidate)
            manifest = root/'manifest.json'
            manifest.write_text(json.dumps({'removals': [dict(file='data/script/main.as', kind='function', name='Gone')]}))
            return verify(before, after, manifest)

    def test_approved_deletion_passes(self):
        self.assertTrue(self.check('int Live(){return 2;}')['manifest_checked'])

    def test_changed_surviving_body_fails(self):
        with self.assertRaises(AssertionError):
            self.check('int Live(){return 4;}')

    def test_missing_deletion_fails(self):
        with self.assertRaises(AssertionError):
            self.check('int Gone(){return 4;}\nint Live(){return 2;}')

    def test_unexpected_deletion_fails(self):
        with self.assertRaises(AssertionError):
            self.check('')

    def test_else_if_is_not_a_function(self):
        from check_script_cleanup import functions
        self.assertEqual(len(functions('void Live(){\n if(true){}\n else if(false){}\n}')), 1)


if __name__ == '__main__':
    unittest.main()
