"""Migration checks: exact archived originals and relocated source/doc links."""
import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from documentation_store import DOC_ROOT, document
from migrate_documentation import relocate


class DocumentationStoreTests(unittest.TestCase):
    def test_reject_path_escape(self):
        for path in ('../outside.md','/absolute.md'):
            with self.assertRaises(ValueError): document(path)

    def test_relocate_preserves_legacy_bytes_and_newlines(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            source=root/'code/doc/a.md'; target=root/'docs/project/a.md'
            other=root/'code/doc/b.md'; moved=root/'docs/project/b.md'
            raw=b'legacy \x96\r\n[other](b.md#part)\r\n[code](../src/a.cpp)\n[web](https://example.com/a)\n'
            result=relocate(raw,source,target,{source:target,other:moved})
            self.assertIn(b'legacy \x96\r\n',result)
            self.assertIn(b'[other](b.md#part)\r\n',result)
            self.assertIn(b'[code](../../code/src/a.cpp)\n',result)
            self.assertIn(b'[web](https://example.com/a)\n',result)

    def test_original_archive_is_complete_and_byte_exact(self):
        manifest=json.loads((DOC_ROOT/'documentation-migration.json').read_text())
        with zipfile.ZipFile(DOC_ROOT/'documentation-originals.zip') as archive:
            self.assertEqual(set(archive.namelist()),{r['old'] for r in manifest['moves']})
            for record in manifest['moves']:
                raw=archive.read(record['old'])
                self.assertEqual(len(raw),record['original_bytes'])
                self.assertEqual(hashlib.sha256(raw).hexdigest(),record['original_sha256'])
                self.assertTrue((DOC_ROOT/record['new']).is_file(),record['new'])


if __name__=='__main__': unittest.main()
