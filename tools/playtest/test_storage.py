"""Storage boundaries: preserve history, resolve old commands, refuse collisions."""
import argparse
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import benchmark
import storage


def archived_game(root, complete=True):
    directory = storage.allocate('air','combat','edge','glitters','supplied',root=root,seed=1651)
    archive = directory/'runs'/storage.run_id()
    archive.mkdir(parents=True)
    (directory/'teams.json').write_text(json.dumps({'map':'Glitters v2','game':'BAR pinned','teams':[]}))
    (directory/'script.txt').write_text('exact starting conditions')
    (directory/'run-inputs.json').write_text('{"engine_sha256":"pinned"}')
    (archive/'report.md').write_text('Original FAIL verdict\n')
    (archive/'infolog.txt').write_text('[f=0001000] retained evidence\n')
    (archive/'screen.png').write_bytes(b'fixture screenshot bytes')
    storage.archive_metadata(directory,archive,b'{"expect":[]}', 'FAIL','deadline',1000,complete)
    return directory, archive


class StorageTests(unittest.TestCase):
    def test_resolve_all_legacy_paths_and_short_ids_preserves_definitions(self):
        aliases = storage.read_json(storage.HERE/'storage-aliases.json')
        actual = {old:storage.resolve_definition(old, 'cases' if '/air_cases/' in old else 'checks').relative_to(storage.ROOT).as_posix()
                  for old in aliases}
        self.assertEqual(actual, aliases)
        short = {old:storage.resolve_definition(Path(old).stem, 'cases' if '/air_cases/' in old else 'checks').relative_to(storage.ROOT).as_posix()
                 for old in aliases}
        self.assertEqual(short, aliases)

    def test_resolve_canonical_id_selects_category(self):
        self.assertEqual(storage.resolve_definition('air/combat/edge-glitters','cases'),
                         storage.HERE/'cases/air/combat/edge-glitters.json')

    def test_resolve_custom_path_remains_supported(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'custom.json'; path.write_text('{}')
            self.assertEqual(storage.resolve_definition(path,'checks'),path.resolve())

    def test_resolve_duplicate_short_name_requires_qualification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); (root/'storage-aliases.json').write_text('{}')
            for domain in ('air','tech'):
                path=root/'checks'/domain/'same.json';path.parent.mkdir(parents=True);path.write_text('{}')
            with patch.object(storage,'HERE',root), self.assertRaisesRegex(ValueError,'Ambiguous'):
                storage.resolve_definition('same','checks')

    def test_resolve_missing_path_cannot_escape_category(self):
        with self.assertRaisesRegex(ValueError,'escapes'):
            storage.resolve_definition('../../../not-a-definition','checks')

    def test_allocate_same_conditions_keeps_distinct_games(self):
        with tempfile.TemporaryDirectory() as tmp:
            a=storage.allocate('air','combat','edge','glitters','supplied',root=tmp)
            b=storage.allocate('air','combat','edge','glitters','supplied',root=tmp)
            self.assertNotEqual(a,b)
            self.assertTrue(a.is_relative_to(Path(tmp).resolve()/'build-theatres/games/air/combat/edge/glitters'))

    def test_allocate_collision_preserves_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(storage,'run_id',return_value='same-id'):
            a=storage.allocate('tech','economy','rush','supreme','benchmark',root=tmp)
            original=(a/'run-plan.json').read_bytes()
            with self.assertRaises(FileExistsError):
                storage.allocate('tech','economy','rush','supreme','benchmark',root=tmp)
            self.assertEqual((a/'run-plan.json').read_bytes(),original)

    def test_capture_uses_staged_files_and_executable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); ai=root/'AI/Skirmish/BARbTest/test';ai.mkdir(parents=True)
            (ai/'policy.as').write_text('staged policy')
            (root/'script.txt').write_text('settings')
            exe=root/'engine.exe';exe.write_bytes(b'engine fixture')
            value=storage.capture_inputs(root,exe)
            self.assertEqual(value['ai_files']['policy.as'],storage.file_hash(ai/'policy.as'))
            self.assertEqual(value['engine_sha256'],storage.file_hash(exe))

    def test_archive_retains_original_checks_and_settings_after_restage(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory, archive=archived_game(tmp)
            (directory/'script.txt').write_text('later settings')
            self.assertEqual((archive/'script.txt').read_text(),'exact starting conditions')
            self.assertEqual((archive/'checks.json').read_bytes(),b'{"expect":[]}')
            self.assertEqual(storage.read_json(archive/'result.json')['verdict'],'FAIL')

    def test_publish_is_idempotent_and_preserves_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            _,archive=archived_game(tmp)
            store=Path(tmp)/'records'
            first=storage.publish(archive,['screen.png'],store=store)
            again=storage.publish(archive,['screen.png'],store=store)
            self.assertEqual(first,again)
            self.assertEqual(storage.read_json(first/'result.json')['verdict'],'FAIL')
            self.assertFalse((first/'infolog.txt').exists())
            self.assertEqual((first/'screen.png').read_bytes(),(archive/'screen.png').read_bytes())

    def test_publish_changed_original_evidence_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            _,archive=archived_game(tmp);(archive/'report.md').write_text('PASS')
            with self.assertRaisesRegex(ValueError,'changed after recording'):
                storage.publish(archive,store=Path(tmp)/'records')

    def test_publish_retries_transient_rename_without_changing_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, archive = archived_game(tmp)
            original_rename = Path.rename
            attempts = []
            def rename(path, target):
                attempts.append(path)
                if len(attempts) == 1:
                    raise PermissionError('temporary reader lock')
                return original_rename(path, target)
            with patch.object(Path, 'rename', rename), patch.object(storage.time, 'sleep') as sleep:
                dest = storage.publish(archive, ['screen.png'], store=Path(tmp)/'records')
            self.assertEqual(len(attempts), 2)
            self.assertEqual(attempts[0], attempts[1])
            sleep.assert_called_once_with(.05)
            self.assertEqual((dest/'screen.png').read_bytes(), (archive/'screen.png').read_bytes())
            self.assertEqual(storage.read_json(dest/'result.json')['verdict'], 'FAIL')

    def test_publish_permanent_rename_failure_retains_pending_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, archive = archived_game(tmp)
            store = Path(tmp)/'records'
            with patch.object(Path, 'rename', side_effect=PermissionError('denied')) as rename, \
                    patch.object(storage.time, 'sleep'), self.assertRaises(PermissionError):
                storage.publish(archive, store=store)
            self.assertEqual(rename.call_count, 8)
            pending = list(store.rglob('.pending-*'))
            self.assertEqual(len(pending), 1)
            self.assertEqual((pending[0]/'report.md').read_bytes(), (archive/'report.md').read_bytes())

    def test_publish_changed_selection_cannot_overwrite_existing_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            _,archive=archived_game(tmp);store=Path(tmp)/'records'
            dest=storage.publish(archive,store=store)
            original=(dest/'publication.json').read_bytes()
            with self.assertRaisesRegex(ValueError,'Conflicting immutable'):
                storage.publish(archive,['screen.png'],store=store)
            self.assertEqual((dest/'publication.json').read_bytes(),original)

    def test_publish_refuses_live_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            _,archive=archived_game(tmp,complete=False)
            with self.assertRaisesRegex(ValueError,'still-running'):
                storage.publish(archive,store=Path(tmp)/'records')

    def test_publish_post_run_analysis_gets_its_own_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            _,archive=archived_game(tmp);(archive/'arena-results.json').write_text('{"measured":true}')
            dest=storage.publish(archive,store=Path(tmp)/'records')
            publication=storage.read_json(dest/'publication.json')
            self.assertEqual(publication['files']['arena-results.json'],storage.file_hash(archive/'arena-results.json'))

    def test_index_distinguishes_record_from_view_revision_and_ledger(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); cards=root/'scorecards';cards.mkdir()
            (cards/'ratings.json').write_text('{}')
            dated=cards/'2026-10-03';dated.mkdir()
            (dated/'a.json').write_text('{}');(dated/'a.md').write_text('view')
            revision=cards/'revisions/a';revision.mkdir(parents=True)
            (revision/'schema-1.json').write_text('{}')
            entries=storage.build_index(root)
            self.assertEqual({e['path']:e['kind'] for e in entries}, {
                'scorecards/ratings.json':'derived-index','scorecards/2026-10-03/a.json':'legacy-evidence',
                'scorecards/2026-10-03/a.md':'rendered-view','scorecards/revisions/a/schema-1.json':'historical-revision'})


class RushHistoryTests(unittest.TestCase):
    def test_append_busy_ledger_keeps_original_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'rush.md';path.write_text('original history')
            path.with_name('rush.md.lock').write_text('another writer')
            with patch.object(benchmark,'DOC',path),self.assertRaisesRegex(RuntimeError,'retry'):
                benchmark.append_row('new','| new | row |')
            self.assertEqual(path.read_text(),'original history')

    def test_record_collision_does_not_replace_previous_benchmark(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); run=root/'same-id';run.mkdir()
            (run/'infolog.txt').write_text('[f=0010800] [Playtest] finished armalab team 0 at 6.0 min\n')
            args=argparse.Namespace(run_dir=str(run),objective='t2',note='first',steps=False)
            with patch.object(benchmark,'DOC',root/'rush.md'),contextlib.redirect_stdout(io.StringIO()):
                benchmark.record(args)
                original=(root/'rush.md').read_bytes()
                args.note='conflicting observation'
                with self.assertRaisesRegex(ValueError,'refusing to replace'):
                    benchmark.record(args)
                self.assertEqual((root/'rush.md').read_bytes(),original)

    def test_record_identical_benchmark_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);run=root/'unique';run.mkdir()
            (run/'infolog.txt').write_text('[f=0010800] [Playtest] finished armalab team 0 at 6.0 min\n')
            args=argparse.Namespace(run_dir=str(run),objective='t2',note='same',steps=False)
            with patch.object(benchmark,'DOC',root/'rush.md'),contextlib.redirect_stdout(io.StringIO()):
                benchmark.record(args);original=(root/'rush.md').read_bytes();benchmark.record(args)
                self.assertEqual((root/'rush.md').read_bytes(),original)


if __name__ == '__main__':
    unittest.main()
