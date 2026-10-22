import unittest
from collections import Counter
from check_settings_extraction import members

class ExtractionTest(unittest.TestCase):
    def test_reopened_namespace_and_comments(self):
        a=members('namespace G { int X=1; void F() { X++; } }')
        b=members('namespace G { void F() { X++; } } // moved\nnamespace G { int X=1; }')
        self.assertEqual(Counter(a),Counter(b))
    def test_changed_initializer_body_namespace_or_duplicate(self):
        before=Counter(members('namespace G { int X=1; void F() { X++; } }'))
        for after in ['namespace G { int X=2; void F() { X++; } }','namespace G { int X=1; void F() { X--; } }','namespace H { int X=1; void F() { X++; } }','namespace G { int X=1; int X=1; void F() { X++; } }']:
            self.assertNotEqual(before,Counter(members(after)))
    def test_containers_preserved(self):
        entries=members('namespace G { dictionary X={{"a",1}}; array<string> Y={"x","y"}; }')
        self.assertEqual(2,len(entries))

if __name__=='__main__':unittest.main()