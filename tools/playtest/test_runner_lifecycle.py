"""Completion, shutdown and verdict contracts; no game or wall-clock waits."""
import argparse
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import engine_process
import playtest
import t3_matrix
import run_commander_regression
import run_commander_performance
import ranged_arena


class RunnerTests(unittest.TestCase):
    def judge(self, initial, checks, batches=(), alive=True, step=1, **options):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            info=root/'infolog.txt';info.write_text(initial)
            check=root/'checks.json';check.write_text(json.dumps(checks))
            args=argparse.Namespace(dir=directory,checks=str(check),role='FRONT',minutes=5,
                wall_minutes=8,keep_going=options.pop('keep_going',False),no_stop=options.pop('no_stop',True),poll=.1,print_report=False,timeline_lines=20,
                startup_seconds=120,stall_seconds=60,**options)
            clock=[1000.0];remaining=iter(batches)
            def advance(_):
                clock[0]+=step
                with info.open('a') as out:out.write(next(remaining,''))
            with patch.object(playtest,'engine_alive',side_effect=alive if isinstance(alive,list) else None,return_value=alive), \
                 patch.object(playtest,'request_stop'), patch.object(playtest,'stop'), \
                 patch.object(playtest.time,'sleep',side_effect=advance), \
                 patch.object(playtest.time,'time',side_effect=lambda:clock[0]), \
                 contextlib.redirect_stdout(io.StringIO()):
                result=playtest.watch(args)
            return result,(root/'report.md').read_text(),clock[0]-1000

    def test_decided_game_ends_early_by_default(self):
        result,report,elapsed=self.judge('[f=1800] [Playtest] decided: one alliance\n',{})
        self.assertEqual(result,0)
        self.assertIn('game decided at 1.0 min',report)
        self.assertEqual(elapsed,0)

    def test_decided_game_still_reads_shutdown_failure(self):
        result,report,_=self.judge('[f=1800] [Playtest] decided: one alliance\n',{},
            ['[f=1801] Fatal: shutdown failure\n'],alive=[True,False],no_stop=False)
        self.assertEqual(result,1)
        self.assertIn('shutdown failure',report)

    def test_play_decided_preserves_later_wave_and_survival_tail(self):
        result,report,elapsed=self.judge('[f=1800] [Playtest] decided: one alliance\n',
            {'complete_on':{'pattern':'last_wave_complete'},'completion_grace_seconds':10},
            ['[f=2100] last_wave_complete\n','[f=2400] survival\n'],play_decided=True)
        self.assertEqual(result,0)
        self.assertIn('frame 2400',report)
        self.assertEqual(elapsed,2)

    def test_stop_when_met_keeps_all_expectations(self):
        result,report,elapsed=self.judge('[f=100] first\n',
            {'expect':[{'key':'a','pattern':'first','scope':'any'},
                       {'key':'b','pattern':'second','scope':'any'}]},
            ['[f=200] second\n'],stop_when_met=True)
        self.assertEqual(result,0)
        self.assertIn('frame 200',report)
        self.assertEqual(elapsed,1)

    def test_arena_keeps_lobby_default_and_explicit_game_override(self):
        # Stop at the first staging call: verify argv without staging a game.
        for game in (None,'pinned-game'):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);case=root/'case.json'
                case.write_text(json.dumps(dict(name='merge-smoke',map_key='comet',map='Comet',
                    starts=[[100,100],[1000,1000]],ally_spots='1,2',modoptions={'experimentallegionfaction':1})))
                args=argparse.Namespace(case='merge-smoke',seed=1,dll=root/'AI.dll',data=root/'data',
                    game=game,speed=20,mode='fast',minutes=2,profile='experimental_balanced',headless=True)
                with patch.object(ranged_arena.storage,'resolve_definition',return_value=case), \
                     patch.object(ranged_arena.storage,'allocate',return_value=root), \
                     patch.object(ranged_arena.subprocess,'run',side_effect=RuntimeError('staging captured')) as stage:
                    with self.assertRaisesRegex(RuntimeError,'staging captured'):ranged_arena.prepare(args)
                argv=stage.call_args.args[0]
                self.assertEqual('--game' in argv,game is not None)
                if game:self.assertEqual(argv[argv.index('--game')+1],game)
                self.assertEqual(argv.count('experimentallegionfaction=1'),1)
                self.assertEqual(argv[argv.index('--ally-spots')+1],'1,2')
                self.assertEqual(argv[argv.index('--mode')+1],'fast')

    def test_completion_waits_for_all_expectations_and_survival(self):
        checks={'complete_on':{'pattern':'complete'},'completion_grace_seconds':10,
                'expect':[{'key':'last_wave','pattern':'last_wave','scope':'any'}]}
        result,report,elapsed=self.judge('[f=100] complete\n',checks,
            ['[f=450] progress\n','[f=500] last_wave\n'])
        self.assertEqual(result,0)
        self.assertIn('frame 500',report)
        self.assertEqual(elapsed,2)

    def test_fatal_after_kill_remains_failure(self):
        result,_,_=self.judge('[f=100] complete\n',{'complete_on':{'pattern':'complete'}},
                             ['[f=150] Fatal: failure\n'])
        self.assertEqual(result,1)

    def test_diagnostic_continuation_keeps_failure_after_completion(self):
        checks={'forbid':[{'key':'invariant','pattern':'INVARIANT','scope':'any'}],
                'complete_on':{'pattern':'complete'},'completion_grace_seconds':10}
        result,report,elapsed=self.judge('[f=100] INVARIANT bad\n',checks,
            ['[f=200] complete\n','[f=510] progress\n'],keep_going=True)
        self.assertEqual(result,1)
        self.assertEqual(elapsed,2)
        self.assertIn('frame 510',report)

    def test_identity_binding_ignores_a_different_commander_or_target(self):
        checks={'expect':[
            {'key':'declined','pattern':r'declined unit=(?P<unit>\d+) target=(?P<target>\d+)','scope':'any'},
            {'key':'fired','pattern':r'fired unit=(?P<unit>\d+) target=(?P<target>\d+)','scope':'any','same_as':'declined','after_key':'declined'}],
            'complete_on':{'key':'done','pattern':'complete'},'completion_grace_seconds':0}
        result,report,elapsed=self.judge('[f=100] declined unit=2 target=3\n[f=120] fired unit=4 target=3\n[f=130] complete\n',checks,
            ['[f=150] fired unit=2 target=4\n','[f=170] fired unit=2 target=3\n'])
        self.assertEqual(result,0);self.assertEqual(elapsed,2)
        self.assertIn('frame 170',report)

    def test_minimum_observation_time_ignores_early_matching_event(self):
        checks={'expect':[{'key':'remembered','pattern':'remembered','scope':'any','after_minute':1}],
                'complete_on':{'key':'done','pattern':'complete'},'completion_grace_seconds':0}
        result,report,elapsed=self.judge('[f=100] remembered\n[f=110] complete\n',checks,['[f=1830] remembered\n'])
        self.assertEqual(result,0);self.assertEqual(elapsed,1)
        self.assertIn('frame 1830',report)

    def test_invalid_identity_binding_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            check=Path(directory)/'checks.json'
            for previous in ('absent','seen'):
                check.write_text(json.dumps({'expect':[{'key':'seen','pattern':'x'},{'key':'later','pattern':'y','same_as':previous}]}))
                with self.assertRaises(ValueError):playtest.validate_checks(str(check))

    def test_pass_on_does_not_shorten_fixed_performance_window(self):
        result,report,elapsed=self.judge('[f=100] pass\n',{'pass_on':{'key':'pass','pattern':'pass','scope':'any'}},
                                       ['[f=9000] done\n'])
        self.assertEqual(result,0)
        self.assertEqual(elapsed,1)
        self.assertIn('frame 9000',report)

    def test_startup_and_progress_watchdogs(self):
        for log,reason in [('', 'startup timeout'),('[f=100] ready\n','simulation progress timeout')]:
            result,report,elapsed=self.judge(log,{},step=31)
            self.assertEqual(result,1)
            self.assertIn(reason,report)
            self.assertLess(elapsed,130)

    def test_exception_still_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(playtest,'_watch',side_effect=ValueError('broken observer')), \
             patch.object(playtest,'stop') as stop:
            with self.assertRaises(ValueError):
                playtest.watch(argparse.Namespace(dir=directory,no_stop=False))
            stop.assert_called_once()
            self.assertEqual(json.loads((Path(directory)/'runner-error.json').read_text())['verdict'],'FAIL')

    def test_invalid_checks_prevent_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            check=Path(directory)/'checks.json';check.write_text('{"expect":[{"key":"x","pattern":"["}]}')
            with patch('sys.argv',['playtest','run','--checks',str(check)]), \
                 patch.object(playtest,'launch') as launch, patch.object(playtest,'stage') as stage:
                with self.assertRaises(Exception):playtest.main()
                launch.assert_not_called();stage.assert_not_called()

    def test_probe_failure_is_not_engine_exit(self):
        with patch.object(playtest.subprocess,'run',side_effect=subprocess.TimeoutExpired('cim',5)):
            with self.assertRaisesRegex(RuntimeError,'inventory unavailable'):playtest.running_pids(Path.cwd())

    def test_low_disk_space_prevents_process_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'script.txt').write_text('fixture')
            dll=root/'AI/Skirmish'/playtest.AI_SHORT/playtest.AI_VERSION/'SkirmishAI.dll'
            dll.parent.mkdir(parents=True);dll.write_bytes(b'fixture')
            with patch.object(playtest.shutil,'disk_usage',return_value=Mock(free=1024**3)), \
                 patch.object(playtest.subprocess,'Popen') as launch:
                with self.assertRaises(SystemExit):playtest.launch(argparse.Namespace(dir=directory))
                launch.assert_not_called()

    def test_stale_pid_is_never_terminated(self):
        process=Mock();process.matches.return_value=False
        record={'pid':17,'created':100,'write_dir':engine_process.canonical(Path.cwd())}
        with patch.object(engine_process,'EngineProcess',return_value=process):
            with self.assertRaisesRegex(RuntimeError,'identity changed'):engine_process.attach(record,Path.cwd())
        process.terminate.assert_not_called();process.close.assert_called_once()


class MatrixTests(unittest.TestCase):
    def score(self, tail='', commander=True):
        with tempfile.TemporaryDirectory() as directory:
            log=Path(directory)/'infolog.txt'
            log.write_text(('[f=360] spawn id=1 team=0 unit=armcom x=0 z=0\n' if commander else '')+
                '[f=750] spawn id=2 team=1 unit=corjugg\n'
                '[f=900] damage id=2 team=1 amount=999 attacker=1 attackerTeam=0 weaponName=disintegrator\n'
                '[f=900] death id=2 team=1\n'
                '[f=1200] commander id=1 x=0 z=0 hp=1000 cloaked=true\n'+tail)
            return t3_matrix.score(log)

    def test_kill_and_observed_survival(self):self.assertTrue(self.score()['pass'])
    def test_missing_commander_cannot_pass(self):self.assertFalse(self.score(commander=False)['pass'])
    def test_late_invariant_cannot_pass(self):self.assertFalse(self.score('[f=1201] [INVARIANT] INV-199\n')['pass'])
    def test_late_death_cannot_pass(self):self.assertFalse(self.score('[f=1201] death id=1 team=0\n')['pass'])

    def test_suite_requires_process_and_archive_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);report=root/'report.md';archive=root/'result.json'
            for code,verdict,expected in [(1,'PASS',False),(0,'FAIL',False),(0,None,False),(0,'PASS',True)]:
                archive.unlink(missing_ok=True)
                if verdict:archive.write_text(json.dumps({'verdict':verdict}))
                def run(command,stdout,**kwargs):
                    stdout.write('[playtest] report: '+str(report)+'\n')
                    return subprocess.CompletedProcess(command,code)
                with patch.object(run_commander_regression.subprocess,'run',side_effect=run):
                    row=run_commander_regression.run_record(['test'],root/'launch.txt')
                self.assertEqual(row['pass'],expected,(code,verdict))

    def test_suite_stops_unplayed_cases_after_missing_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);out=root/'suite.json'
            definition=root/'case.json';definition.write_text('{"checks":"check"}')
            failed={'returncode':2,'archive_verdict':None,'report':None,
                    'diagnostic':'launch.txt','pass':False,'wall_seconds':1}
            argv=['runner','--dll','pin.dll','--data','data','--out',str(out),'--cases','first,second']
            with patch.object(sys,'argv',argv), \
                 patch.object(run_commander_regression.storage,'resolve_definition',return_value=definition), \
                 patch.object(run_commander_regression.storage,'file_hash',return_value='hash'), \
                 patch.object(run_commander_regression.playtest,'validate_checks',return_value={}), \
                 patch.object(run_commander_regression,'run_record',return_value=failed) as launch, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(run_commander_regression.main(),1)
            self.assertEqual(launch.call_count,1)
            record=json.loads(out.read_text())
            self.assertFalse(record['complete'])
            self.assertFalse(record['pass'])
            self.assertEqual(record['results'][0]['case'],'first')

    def test_suite_rejects_numeric_arena_failure_even_after_watch_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);archive=root/'runs/test';archive.mkdir(parents=True)
            report=archive/'report.md'
            (archive/'result.json').write_text('{"verdict":"PASS"}')
            (root/'ranged-arena.json').write_text('{}')
            def run(command,stdout,**kwargs):
                stdout.write('[playtest] report: '+str(report)+'\n')
                return subprocess.CompletedProcess(command,0)
            with patch.object(run_commander_regression.subprocess,'run',side_effect=run), \
                 patch.object(run_commander_regression,'summarize',return_value={'passed':False,'failures':['ranged casualties']}):
                row=run_commander_regression.run_record(['test'],root/'launch.txt')
            self.assertFalse(row['pass'])
            self.assertEqual(row['archive_verdict'],'PASS')


class PerformanceEnvironmentTests(unittest.TestCase):
    def test_controls_only_plan_does_not_repeat_natural_games(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);pin=root/'pin';out=root/'series.json'
            (pin/'data/script').mkdir(parents=True)
            (pin/'SkirmishAI.dll').write_bytes(b'pin')
            failed={'returncode':2,'archive_verdict':None,'report':None,
                    'diagnostic':'launch.txt','pass':False,'wall_seconds':1}
            argv=['runner','--baseline',str(pin),'--candidate',str(pin),'--out',str(out),
                  '--arenas-only','--attribution']
            with patch.object(sys,'argv',argv), \
                 patch.dict(run_commander_performance.os.environ,{},clear=True), \
                 patch.object(run_commander_performance,'environment'), \
                 patch.object(run_commander_performance,'run_record',return_value=failed), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(run_commander_performance.main(),1)
            plan=json.loads(out.read_text())['plan']
            self.assertEqual(len(plan),9)
            self.assertEqual({x['kind'] for x in plan},{'arena'})
            self.assertTrue(plan[-1]['native_phases'])

    def test_missing_archive_stops_incomplete_performance_series(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);pin=root/'pin';out=root/'series.json'
            (pin/'data/script').mkdir(parents=True)
            (pin/'SkirmishAI.dll').write_bytes(b'pin')
            failed={'returncode':2,'archive_verdict':None,'report':None,
                    'diagnostic':'launch.txt','pass':False,'wall_seconds':1}
            argv=['runner','--baseline',str(pin),'--candidate',str(pin),'--out',str(out)]
            with patch.object(sys,'argv',argv), \
                 patch.dict(run_commander_performance.os.environ,{},clear=True), \
                 patch.object(run_commander_performance,'environment'), \
                 patch.object(run_commander_performance,'run_record',return_value=failed) as launch, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(run_commander_performance.main(),1)
            self.assertEqual(launch.call_count,1)
            record=json.loads(out.read_text())
            self.assertFalse(record['complete'])
            self.assertFalse(record['checks_pass'])

    def inventory(self, processes, allow=False):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'environment.json'
            response=subprocess.CompletedProcess(['powershell'],0,
                json.dumps({'competing':processes,'load':[]}), '')
            with patch.object(run_commander_performance.subprocess,'run',return_value=response):
                return run_commander_performance.environment(path,allow)

    def test_lobby_is_rejected_by_default(self):
        with self.assertRaises(RuntimeError):
            self.inventory([{'Name':'spring.exe','CommandLine':'spring.exe --menu rapid://game'}])

    def test_explicit_lobby_exception_retains_qualification(self):
        lobby={'Name':'spring.exe','CommandLine':'spring.exe --menu rapid://game'}
        data=self.inventory([lobby],True)
        self.assertEqual(data['allowed_lobby'],[lobby])
        self.assertFalse(data['uncontended'])
        self.assertEqual(data['competing'],[])

    def test_lobby_exception_does_not_admit_matches_or_builds(self):
        for process in ({'Name':'spring.exe','CommandLine':'spring.exe --isolation script.txt'},
                        {'Name':'python.exe','CommandLine':'build_native_snapshot.py --menu'}):
            with self.subTest(process=process),self.assertRaises(RuntimeError):
                self.inventory([process],True)

    def test_empty_inventory_is_uncontended(self):
        self.assertTrue(self.inventory([],True)['uncontended'])


@unittest.skipUnless(engine_process.os.name=='nt','Windows process ownership')
class WindowsProcessIntegrationTests(unittest.TestCase):
    def test_creation_identity_and_exact_handle_cleanup(self):
        # A real owned child exercises kernel handles; stale identity must not
        # terminate it. No game, user process or numeric-PID kill is involved.
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
        handle=None
        try:
            handle=engine_process.EngineProcess(child.pid)
            record=handle.identity(Path.cwd())
            stale=dict(record,created=record['created']+1)
            with self.assertRaisesRegex(RuntimeError,'identity changed'):
                engine_process.attach(stale,Path.cwd())
            self.assertTrue(handle.alive())
            attached=engine_process.attach(record,Path.cwd())
            try:
                attached.terminate()
                self.assertFalse(handle.alive())
            finally:attached.close()
        finally:
            if handle:
                if handle.alive():handle.terminate()
                handle.close()
            if child.poll() is None:child.kill()
            child.wait(timeout=5)


if __name__=='__main__':unittest.main()
