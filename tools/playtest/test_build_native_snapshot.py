"""Prove snapshot cache reuse cannot hide changed source or recompile restored headers."""
import os
from pathlib import Path
import tempfile
import unittest

from build_native_snapshot import restore_source_times


class SourceTimeTests(unittest.TestCase):
    def test_content_decides_reuse_even_when_timestamps_disagree(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);prior=root/'pin/source/src';current=root/'new/src'
            prior.mkdir(parents=True);current.mkdir(parents=True)
            for name,old,new in [('same.h','same','same'),('changed.cpp','old','new')]:
                (prior/name).write_text(old);(current/name).write_text(new)
                os.utime(prior/name,(1000,1000))
                os.utime(current/name,(3000 if old==new else 500,)*2)
            result=restore_source_times(root/'new',root/'pin',2000)
            self.assertEqual(result,{'changed':1,'reused':1})
            self.assertEqual((current/'same.h').stat().st_mtime,1000)
            self.assertGreater((current/'changed.cpp').stat().st_mtime,2000)
            self.assertEqual((current/'changed.cpp').read_text(),'new')


if __name__=='__main__':unittest.main()
