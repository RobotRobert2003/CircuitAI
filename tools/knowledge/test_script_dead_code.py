"""Safety checks for the conservative review inventory."""
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from review_script_dead_code import include_graph,setting_references,mask

class DeadCodeReviewTests(unittest.TestCase):
    def test_include_comments_are_not_load_edges(self):
        with TemporaryDirectory() as d:
            p=Path(d)/'main.as';q=Path(d)/'used.as';q.write_text('')
            p.write_text('// #include "missing.as"\n#include "used.as"\n')
            seen,missing=include_graph(p)
            self.assertEqual(seen,{p.resolve(),q.resolve()});self.assertEqual(missing,[])
    def test_namespaces_separate_identical_setting_names(self):
        p=Path('settings/roles/air.as');q=Path('role.as')
        declarations='namespace Global { namespace Air { int Limit=1, Spare=2; } namespace Sea { int Limit=3; } }'
        uses='void Tick() { int x=Global::Air::Limit; Global::Sea::Limit=4; }'
        rows=setting_references({p:mask(declarations),q:mask(uses)})
        byname={r['name']:r for r in rows}
        self.assertEqual(set(byname),{'Global::Air::Spare','Global::Sea::Limit'})
        self.assertEqual(len(byname['Global::Sea::Limit']['writes']),1)
    def test_default_value_read_is_not_misclassified_as_write_only(self):
        p=Path('settings/shared/test.as');q=Path('main.as')
        rows=setting_references({p:mask('namespace G { int X=1; }'),q:mask('void Tick(){ G::X = Read(G::X); }')})
        self.assertEqual(rows,[])

if __name__=='__main__':unittest.main()
