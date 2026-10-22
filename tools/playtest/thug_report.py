"""Publish a Thug investigation matrix without hiding failed candidate runs.

Input logs are the captured stdout of ranged_benchmark/run_thug_natural.
Original watcher verdicts, combat assertions and integration failures remain
separate. This report never turns missing performance evidence into a PASS.
"""
import argparse
import json
from pathlib import Path
import re
import shutil

import storage


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--logs',type=Path,required=True)
    parser.add_argument('--final',default='b11')
    parser.add_argument('--performance',type=Path)
    args=parser.parse_args()
    games={}; natural={}
    for path in sorted(args.logs.glob('thug-*.log')):
        for line in path.read_text(errors='replace').splitlines():
            if line.startswith('MEASUREMENTS='):
                row=json.loads(line[13:]); row['driver_log']=path.name
                games[row['directory']]=row
            if line.startswith('THUG_NATURAL='):
                directory=Path(line.split('=',1)[1])
                archives=sorted((directory/'runs').glob('*/result.json'))
                if not archives: continue
                result=json.loads(archives[-1].read_text())
                text=(directory/'infolog.txt').read_text(errors='replace')
                spawn=re.search(r'\[RangedArena\] frame=(\d+) finished .*team=0 unit=corthud ',text)
                shot=re.search(r'\[RangedArena\] frame=(\d+) shot .*unit=corthud ',text)
                natural[str(directory)]=dict(directory=str(directory),driver_log=path.name,
                    result=result,first_thug_seconds=int(spawn[1])/30 if spawn else None,
                    first_shot_seconds=int(shot[1])/30 if shot else None,
                    invariants=sorted(set(re.findall(r'\[INVARIANT\] (INV-\d+)',text))))
    final=[row for row in games.values() if row['driver_log'].startswith('thug-'+args.final+'-')]
    performance=json.loads(args.performance.read_text()) if args.performance else None
    matrix=dict(schema=1,final_build=args.final,games=list(games.values()),natural=list(natural.values()),
        performance=performance,notes=[
            'A requested seed is not identical synchronized input: unsynced cheat-spawn receipt frames can vary. Raw spawn frames and pins are retained.',
            'Concurrent combat/natural runs are correctness evidence, not controlled CPU comparisons.',
            'Final-build games are listed separately; intermediate candidates are not retrospectively relabeled.',
            'Original watcher PASS and combat assertion PASS are separate requirements.'])
    directory=storage.allocate('shared','combat','thug-engagement','multi','regression')
    archive=directory/'runs'/directory.name; archive.mkdir(parents=True)
    storage.write_json(archive/'matrix.json',matrix)
    lines=['# Thug engagement verification','',
        f'Final build: **{args.final}**. {len(games)} measured supplied-force runs; {len(natural)} archived natural/integration runs.',
        '', '**Acceptance remains partial.** Retain the failed terrain/casualty and unrelated integration checks; CPU acceptance requires a quiet host.',
        '', '## Final-build supplied-force runs','',
        '| Case | Seed | Kills | Losses | Orders/min | Combat result |',
        '| --- | --- | --- | --- | --- | --- |']
    for row in final:
        rate=row['commands_per_game_minute']
        lines.append(f"| {row['case']} | {row['seed']} | {row['enemy_kills']} | {row['friendly_losses']} | {rate:.1f} | {'PASS' if row['passed'] else 'FAIL: '+', '.join(row['failures'])} |")
    lines+=['','## Natural integration','',
        '| Driver | First Thug (s) | First fire (s) | Original verdict | Invariants |',
        '| --- | --- | --- | --- | --- |']
    for row in natural.values():
        lines.append(f"| {row['driver_log']} | {row['first_thug_seconds']} | {row['first_shot_seconds']} | {row['result']['verdict']} | {', '.join(row['invariants'])} |")
    lines+=['','## Interpretation','',*['- '+note for note in matrix['notes']],
        '', 'See matrix.json for every original run path, assertion, timing window and failed trial. The source implementation document records scope, unit checks, migration and outstanding limitations.']
    if performance:
        lines+=['','## Fixed-population comparison','',performance['cpu_acceptance'],'',
            '| Metric | Baseline median | Candidate median | Ratio | Within declared allowance |',
            '| --- | --- | --- | --- | --- |']
        for key,row in performance['comparison'].items():
            lines.append(f"| {key} | {row['baseline_median']:.4f} | {row['candidate_median']:.4f} | {row['ratio']:.3f} | {row['within_allowance']} |")
    (archive/'report.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    photos=[]
    selected=next((row for row in final if row['case']=='thug-crossfire-reveal'),None)
    if selected:
        images=sorted((Path(selected['directory'])/'screenshots').glob('*.png'))
        if len(images)>1:
            name='crossfire-withdrawal.png'; shutil.copy2(images[1],archive/name); photos.append(name)
    storage.archive_metadata(directory,archive,b'{"aggregate":"original checks and assertions are retained in matrix.json"}\n',
        'FAIL','partial combat acceptance; see report and original integration failures',0,True)
    dest=storage.publish(archive,photos)
    storage.build_index()
    print('THUG_REPORT='+str(dest))
    return 0


if __name__=='__main__': raise SystemExit(main())
