import tempfile
import unittest
from pathlib import Path
from script_settings import apply_override, role_settings_path, role_script_path, namespace_span

class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
    def write(self,name,text):
        p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(text.encode());return p
    def test_legacy_namespace_boundaries_and_crlf(self):
        p=self.write('global.as','namespace Global { namespace RoleSettings { namespace Tech {\r\nfloat Limit=1; // }\r\nvoid F() { }\r\n} namespace Air { float Limit=2; } } }')
        apply_override(self.root,'Limit=3');self.assertIn('Limit=3;',p.read_text());self.assertIn(b'\r\n',p.read_bytes());self.assertIn('Limit=2;',p.read_text())
    def test_split_and_role_qualified(self):
        p=self.write('settings/roles/air.as','namespace Global { namespace RoleSettings { namespace Air { bool Enabled=true; } } }')
        global_file=self.write('global.as','// runtime state untouched')
        apply_override(self.root,'Air.Enabled=false');self.assertIn('Enabled=false',p.read_text());self.assertEqual(global_file.read_text(),'// runtime state untouched')
    def test_missing_and_duplicate_rejected_without_writes(self):
        for body,key in [('float Limit=1;','Unknown'),('float Limit=1; float Limit=2;','Limit')]:
            p=self.write('global.as','namespace Global { namespace RoleSettings { namespace Tech { '+body+' } } }');before=p.read_bytes()
            with self.assertRaises(ValueError):apply_override(self.root,key+'=4')
            self.assertEqual(before,p.read_bytes())
    def test_strings_and_comments_are_not_namespaces(self):
        p=self.write('global.as','// namespace Tech {\nnamespace Global { namespace RoleSettings { namespace Tech { string Label="}"; } } }')
        apply_override(self.root,'Label="x"');self.assertIn('Label="x"',p.read_text())
    def test_no_fallback_from_invalid_split(self):
        self.write('settings/roles/air.as','namespace Wrong {}');self.write('global.as','namespace Global { namespace RoleSettings { namespace Air { int X=1; } } }')
        with self.assertRaises(ValueError):role_settings_path(self.root,'Air')
    def test_multi_declaration_and_quoted_punctuation(self):
        p=self.write('global.as','namespace Global { namespace RoleSettings { namespace Tech { float Metal=50, Energy=500; string Label="a,b;c"; } } }')
        apply_override(self.root,'Energy=600');apply_override(self.root,'Label="x,y;z"')
        self.assertIn('Metal=50, Energy=600;',p.read_text());self.assertIn('Label="x,y;z";',p.read_text())
    def test_current_and_legacy_role_modules(self):
        old=self.write('roles/air_build.as','old');self.assertEqual(old,role_script_path(self.root,'air_build'))
        new=self.write('roles/air/air_build.as','new');self.assertEqual(new,role_script_path(self.root,'air_build'))
        with self.assertRaises(ValueError):role_script_path(self.root,'../bad')
    def test_only_selected_tree_changes(self):
        source=self.write('source/global.as','namespace Global { namespace RoleSettings { namespace Tech { float X=1; } } }')
        staged=self.write('staged/global.as',source.read_text());apply_override(self.root/'staged','X=2')
        self.assertIn('X=1',source.read_text());self.assertIn('X=2',staged.read_text())

if __name__=='__main__':unittest.main()