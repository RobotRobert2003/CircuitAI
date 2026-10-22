import tempfile
import unittest
from pathlib import Path
from check_script_relocation import compare


class RelocationTests(unittest.TestCase):
    def test_move_preserves_include_order_and_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            before, after = Path(directory) / 'before', Path(directory) / 'after'
            before.mkdir(); (after / 'math').mkdir(parents=True)
            (before / 'main.as').write_text('#include "math.as"\nvoid Main() {}\n')
            (after / 'main.as').write_text('#include "math/math.as"\nvoid Main() {}\n')
            (before / 'math.as').write_text('const int Value = 7;\n')
            (after / 'math/math.as').write_text('const int Value = 7;\n')
            self.assertEqual(compare(before, after)['relocations'], {'math.as': 'math/math.as'})
            (after / 'math/math.as').write_text('const int Value = 8;\n')
            with self.assertRaisesRegex(ValueError, 'Non-include'):
                compare(before, after)

    def test_reordered_dependencies_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            before, after = Path(directory) / 'before', Path(directory) / 'after'
            for root in (before, after):
                root.mkdir()
                for name in ('first.as', 'second.as'):
                    (root / name).write_text('// unchanged\n')
            (before / 'main.as').write_text('#include "first.as"\n#include "second.as"\n')
            (after / 'main.as').write_text('#include "second.as"\n#include "first.as"\n')
            with self.assertRaisesRegex(ValueError, 'Include target or order'):
                compare(before, after)


if __name__ == '__main__':
    unittest.main()
