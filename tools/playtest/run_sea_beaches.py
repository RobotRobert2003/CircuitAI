"""Serial natural SEA games with read-only enemy-beach visibility telemetry."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

import playtest
import storage
from air_arena import lua
from run_sea import MAPS


def summarize(text):
    sites = {}
    for line in text.splitlines():
        if '[SeaBeach]' not in line:
            continue
        row = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if ' site ' in line:
            sites[row['id']] = dict(x=int(row['x']), z=int(row['z']), ally=int(row['ally']), label=row.get('label'), samples=[])
        elif ' sample ' in line and row['id'] in sites:
            sites[row['id']]['samples'].append((int(row['frame']) / 30, row['los']=='true', row['scout']=='true'))
    for site in sites.values():
        samples = site.pop('samples')
        site['sample_count'] = len(samples)
        for name, column in [('los', 1), ('scout_near', 2)]:
            hits = [s[0] for s in samples if s[column]]
            site[name+'_first_seconds'] = hits[0] if hits else None
            # Include unseen start and tail; separated visits, not log count.
            bounds = [samples[0][0] if samples else 0] + hits + [samples[-1][0] if samples else 0]
            site[name+'_max_gap_seconds'] = max((b-a for a,b in zip(bounds,bounds[1:])), default=0)
            revisits = hits + [samples[-1][0]] if hits and samples else []
            site[name+'_max_gap_after_first_seconds'] = max((b-a for a,b in zip(revisits,revisits[1:])), default=None)
            site[name+'_visible_fraction'] = len(hits)/len(samples) if samples else None
        site['last_seconds'] = samples[-1][0] if samples else None
    return sites


def assess_focus(sites, expected=4, first_deadline=300, maximum_gap=180):
    """Explicit audit targets, not a promise that scouts can ignore defences."""
    focus=[s for s in sites.values() if s.get('label')]
    failures=[]
    if len(focus)!=expected:
        failures.append(f'Expected {expected} named focus sites; observed {len(focus)}')
    for s in focus:
        first=s['los_first_seconds']
        gap=s['los_max_gap_after_first_seconds']
        if first is None or first>first_deadline:
            failures.append(s['label']+': not in LOS by '+str(first_deadline)+' seconds')
        if gap is None or gap>maximum_gap:
            failures.append(s['label']+': revisit gap exceeds '+str(maximum_gap)+' seconds or no sighting')
        if not s['sample_count']:
            failures.append(s['label']+': missing samples')
    return failures


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--data', type=Path, default=playtest.REPO/'data')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--maps', default='supreme,glacial,tundra,caldera,erebos')
    p.add_argument('--minutes', type=int, default=15)
    p.add_argument('--roles', default='SEA', help='SEA for isolated natural naval economy; all for complete team rosters')
    p.add_argument('--visual', action='store_true', help='Rendered Supreme overview evidence; default fast headless')
    p.add_argument('--policy-probe', action='store_true', help='Read-only score diagnostics at Supreme outer shores')
    p.add_argument('--keep-going', action='store_true', help='Bounded diagnostic only; retain failed runtime verdicts')
    a=p.parse_args()
    a.out.mkdir(parents=True, exist_ok=False)
    results=[]
    for key in a.maps.split(','):
        d=storage.allocate('sea','combat','enemy-beaches',key,'natural',seed=220001)
        call=[sys.executable,str(playtest.HERE/'playtest.py')]
        with (a.out/(key+'-launcher.log')).open('w',encoding='utf-8') as log:
            def run(args):
                return subprocess.run(call+args,stdout=log,stderr=subprocess.STDOUT)
            start=time.monotonic()
            try:
                stage=['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(a.data),
                    '--map',MAPS[key],'--game','Beyond All Reason test-31671-ad2e1b7','--engine','recoil_2026.07.04',
                    '--role','SEA','--roles',a.roles,'--side','armada','--bonus','0','--mode','visual' if a.visual else 'fast',
                    '--minutes',str(a.minutes),'--speed','20','--shots','5@14000@6144:6144,10@14000@6144:6144' if a.visual else '',
                    '--ai-option','profile=experimental_balanced','--ai-option','random_seed=220001',
                    '--modoption','date_day=15','--extra-widget',str(playtest.HERE/'widgets/sea_watch.lua'),
                    '--extra-widget',str(playtest.HERE/'widgets/sea_beach_watch.lua')]
                if not a.visual: stage.append('--headless')
                if run(stage).returncode: raise RuntimeError('stage failed')
                if a.policy_probe:
                    if key!='supreme': raise ValueError('The score probe is defined for Supreme only')
                    patrol=d/'AI/Skirmish/BARbTest/test/script/src/systems/sea/sea_patrol.as'
                    source=patrol.read_text()
                    needle='if (rank<=score || !Safe(u,s.pos,b.body)) continue;'
                    assert source.count(needle)==1
                    probe='''if ((s.pos.x<800 && s.pos.z>3500 && s.pos.z<4800)
                        || (s.pos.x>11400 && s.pos.z>7500 && s.pos.z<8800))
                        AiLog("[BeachCandidate] id="+b.id+" x="+s.pos.x+" z="+s.pos.z
                            +" priority="+s.priority+" visited="+s.visited+" rank="+rank
                            +" best="+score+" enemyDistance="+s.enemyDistance);
                    '''
                    patrol.write_text(source.replace(needle,probe+needle))
                teams=json.loads((d/'teams.json').read_text())['teams']
                (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
                focus=[]
                if key=='supreme':
                    # Fixed observation sites validated against captured v1.7
                    # terrain. Never injected into production scout goals.
                    focus=[dict(x=256,z=4200,ally=1,label='northwest-edge'),
                           dict(x=3500,z=7000,ally=1,label='northwest-central'),
                           dict(x=12032,z=8088,ally=0,label='southeast-edge'),
                           dict(x=8788,z=5288,ally=0,label='southeast-central')]
                (d/'LuaUI/Config/sea_beach_watch.lua').write_text('return '+lua(dict(teams=teams,focus=focus,contacts=a.roles=='all')))
                (d/'beach-observer-pin.json').write_text(json.dumps(dict(
                    dll_sha256=hashlib.sha256(a.dll.read_bytes()).hexdigest(),
                    observer_sha256=hashlib.sha256((playtest.HERE/'widgets/sea_beach_watch.lua').read_bytes()).hexdigest(),
                    roles=a.roles,profile='experimental_balanced',seed=220001,
                    requested_speed=20,sampling_seconds=5,focus=focus,policy_probe=a.policy_probe),indent=2))
                script=d/'script.txt'
                script.write_text(script.read_text().replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed=220001;',1))
                checks=json.loads((playtest.HERE/'checks/sea/reliability/sea_compile.json').read_text())
                checks['stop_minute']=a.minutes
                checks['expect'].append(dict(key='beach-observer',pattern=r'\[SeaBeach\].*ready sites=[1-9]',scope='any',by_minute=1))
                checks['forbid'].append(dict(key='beach-error',pattern=r'Error in.*sea_beach_watch',scope='any'))
                checkfile=d/'beach-checks.json';checkfile.write_text(json.dumps(checks))
                if run(['launch','--dir',str(d),'--engine','recoil_2026.07.04']+([] if a.visual else ['--headless'])).returncode:
                    raise RuntimeError('launch failed')
                print('RUNNING '+key+' '+str(d),flush=True)
                code=run(['watch','--dir',str(d),'--role','SEA','--checks',str(checkfile),
                    '--minutes',str(a.minutes),'--wall-minutes','15']+(['--keep-going'] if a.keep_going else [])).returncode
                archives=list((d/'runs').glob('*'))
                if len(archives)!=1: raise RuntimeError('Expected one archived run')
                archive=archives[0]
                sites=summarize((archive/'infolog.txt').read_text(errors='replace'))
                row=dict(map=MAPS[key],archive=str(archive),returncode=code,sites=sites,
                    wall_seconds=time.monotonic()-start,diagnostic=a.keep_going)
                # The named enemy beaches assume the full coastal roster.
                # SEA-only games omit TACTICAL starts and therefore change
                # public territory inference; retain measurements, not that
                # full-roster acceptance contract, for the broad smoke matrix.
                if focus and a.roles=='all':
                    row['focus_acceptance']=dict(first_deadline_seconds=300,maximum_gap_seconds=180,
                        failures=assess_focus(sites))
                (a.out/(key+'-coverage.json')).write_text(json.dumps(row,indent=2))
                results.append(row)
                print('FINISHED '+key+' runtime='+str(code)+' sites='+str(len(sites)),flush=True)
                if code and not a.keep_going:
                    break
            except Exception as exc:
                results.append(dict(map=MAPS[key],directory=str(d),error=str(exc),returncode=1,sites={}))
                raise
            finally:
                run(['stop','--dir',str(d)])
                (a.out/'summary.json').write_text(json.dumps(results,indent=2))
    return int(any(r['returncode'] or not r['sites'] or r.get('focus_acceptance',{}).get('failures')
                   or any(not s['sample_count'] for s in r['sites'].values()) for r in results))


if __name__=='__main__':
    sys.exit(main())
