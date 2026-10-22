"""Archive cache reuse must remain isolated, optional and observable."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import playtest


class ArchiveCacheTests(unittest.TestCase):
    def test_copy_is_independent_and_receipted(self):
        with tempfile.TemporaryDirectory() as temp:
            source=Path(temp)/'source';source.mkdir()
            target=Path(temp)/'game';target.mkdir()
            data=b'return { internalver = 22 }'
            cache=source/'ArchiveCache22.lua';cache.write_bytes(data)
            receipt=playtest.seed_archive_cache(source,target)
            self.assertEqual(receipt[0]['sha256'],hashlib.sha256(data).hexdigest())
            (target/'cache/ArchiveCache22.lua').write_text('engine update')
            self.assertEqual(cache.read_bytes(),data)

    def test_missing_source_is_cold_load(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            self.assertEqual(playtest.seed_archive_cache(root/'missing',root),[])
            self.assertTrue((root/'archive-cache-seed.json').is_file())

    def test_existing_local_cache_and_unrelated_files_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'source';source.mkdir()
            (source/'ArchiveCache22.lua').write_text('source')
            (source/'ArchiveCache-other.lua').write_text('not scanner metadata')
            local=root/'cache';local.mkdir()
            (local/'ArchiveCache22.lua').write_text('existing')
            self.assertEqual(playtest.seed_archive_cache(source,root),[])
            self.assertEqual((local/'ArchiveCache22.lua').read_text(),'existing')
            self.assertFalse((local/'ArchiveCache-other.lua').exists())

    def test_read_failure_is_cold_load(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'source';source.mkdir()
            (source/'ArchiveCache22.lua').write_text('source')
            with patch.object(Path,'read_bytes',side_effect=OSError('busy')):
                self.assertEqual(playtest.seed_archive_cache(source,root),[])

    def test_cache_changed_during_read_is_not_copied(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'source';source.mkdir()
            cache=source/'ArchiveCache22.lua';cache.write_text('before')
            def changed():
                cache.write_text('after, different size')
                return b'before'
            with patch.object(Path,'read_bytes',side_effect=changed):
                self.assertEqual(playtest.seed_archive_cache(source,root),[])
            self.assertFalse((root/'cache/ArchiveCache22.lua').exists())

    def test_oversized_cache_is_not_read(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'source';source.mkdir()
            with (source/'ArchiveCache22.lua').open('wb') as stream:
                stream.truncate(16*1024*1024+1)
            with patch.object(Path,'read_bytes',side_effect=AssertionError('unbounded read')):
                self.assertEqual(playtest.seed_archive_cache(source,root),[])


if __name__=='__main__':unittest.main()
