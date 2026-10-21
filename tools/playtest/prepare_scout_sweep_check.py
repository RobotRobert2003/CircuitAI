"""Stage supplied plants/income with real scout production, gates and MOVE routes.

No shipped policy constants are shortened. Builders and unrelated production
are frozen only in this isolated fixture; economic samples and resource banks
are supplied, so this is functional evidence, not a natural economy benchmark.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import playtest
from benchmark_store import RAW_ROOT


def replace(path, old, new):
    text = path.read_text()
    assert text.count(old) == 1, (path, old)
    path.write_text(text.replace(old, new))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dir', type=Path, required=True)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--side', choices=playtest.SIDES, default='cortex')
    p.add_argument('--profile', default='experimental_balanced')
    p.add_argument('--map', default='Supreme Isthmus v1.7')
    p.add_argument('--mixed', action='store_true', help='Supply an allied-faction plant pair to the AIR team')
    p.add_argument('--silo', choices=['armsilo', 'corsilo', 'legsilo'], default='armsilo')
    a = p.parse_args()
    base = a.dir.resolve()
    if not base.is_relative_to(RAW_ROOT):
        p.error('Use an isolated external benchmark directory')
    base.mkdir(parents=True, exist_ok=True)
    spots = playtest.map_spots(a.map)
    half = len(spots)//2
    home = next(s for s in spots[:half] if s[2] == 'AIR')
    tech = next(s for s in spots[:half] if s[2] == 'TECH')
    enemy = next(s for s in spots[half:] if s[2] == 'AIR')
    starts = base/'starts.as'
    starts.write_text('\n'.join(f'StartSpot(AIFloat3({s[0]},0,{s[1]}), AiRole::{role}, false),'
                               for s, role in [(home, 'AIR'), (tech, 'TECH'), (enemy, 'FRONT')]))
    subprocess.run([sys.executable, str(playtest.HERE/'playtest.py'), 'stage', '--dir', str(base),
                    '--dll', str(a.dll), '--map', a.map, '--map-file', str(starts), '--roles', 'all',
                    '--role', 'AIR', '--side', a.side, '--ally-spots', '1,2',
                    '--engine', 'recoil_2026.07.04', '--game', 'Beyond All Reason test-31479-433a460',
                    '--ai-option', 'profile='+a.profile, '--ai-option', 'random_seed=1791003',
                    '--modoption', 'deathmode=neverend', '--speed', '20', '--minutes', '11',
                    '--shots', '', '--headless', '--lean-render', '--bonus', '0',
                    '--extra-widget', str(playtest.HERE/'widgets/scout_sweep_watch.lua')], check=True)
    scripts = base/'AI/Skirmish/BARbTest/test/script'
    for manager, code in [('builder', 'return aiBuilderMgr.Enqueue(TaskB::Wait(60*SECOND));'),
                          ('factory', 'IUnitTask@ probe = ai.teamId == 0 ? AirScoutSweep::Produce(u) : null; '
                           'return probe is null ? aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND)) : probe;')]:
        path = scripts/'src/manager'/f'{manager}.as'
        text = path.read_text()
        at = text.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)')
        brace = text.index('{', at)
        path.write_text(text[:brace+1]+'\n if (ai.frame>=0) { '+code+' } // supplied fixture\n'+text[brace+1:])
    replace(scripts/'src/manager/economy.as',
            '_UpdateSlidingMinima(ai.frame, metal.income, energy.income);',
            '_UpdateSlidingMinima(ai.frame, ai.frame < 30*SECOND ? 59.0f : 60.0f, (ai.frame >= 30*SECOND && ai.frame < 60*SECOND) ? 1999.0f : 2000.0f);')
    # A deliberately frozen TECH cannot satisfy its economic build ladder.
    # Keep the TECH nuke lifecycle/message path; omit unrelated build planning.
    path = scripts/'src/roles/tech/tech.as'
    replace(path, 'void Tech_EconomyUpdate()\n\t{', 'void Tech_EconomyUpdate()\n\t{\n if(ai.frame>=0) return; // supplied fixture: frozen economic ladder')
    probe = (playtest.HERE/'scout_sweep_probe.as').read_text()
    for profile in ['experimental_balanced', 'experimental_hard', 'experimental_terrible']:
        path = scripts/profile/'main.as'
        replace(path, 'ArtilleryPolicy::Check();', 'ArtilleryPolicy::Check(); ScoutSweepProbe::Tick();')
        path.write_text(path.read_text()+'\n'+probe)
    cfg = {'side': a.side, 'home': home[:2], 'tech': tech[:2], 'mixed': a.mixed, 'silo': a.silo}
    (base/'LuaUI/Config').mkdir(parents=True, exist_ok=True)
    (base/'LuaUI/Config/scout_sweep.lua').write_text('return {side="'+a.side+'",silo="'+a.silo+'",mixed='+str(a.mixed).lower()+',home={'+','.join(map(str,home[:2]))+'},tech={'+','.join(map(str,tech[:2]))+'}}\n')
    (base/'scout-sweep-fixture.json').write_text(json.dumps(dict(config=cfg,
        supplied_income=True, supplied_banks=True, supplied_plants=True, natural_benchmark=False,
        unmodified_schedule_seconds=[120, 300], unmodified_package=[10, 4]), indent=2))
    print(base)


if __name__ == '__main__':
    main()
