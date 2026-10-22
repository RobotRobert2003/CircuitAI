"""Stage supplied radar/co-located factory checks without changing shipped policy."""
import argparse
import json
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys
import playtest
from prepare_air_operations_cases import MAPS


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dir', type=Path, required=True)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--map', choices=[m[0] for m in MAPS], default='supreme')
    p.add_argument('--clusters', action='store_true')
    a = p.parse_args()
    base = a.dir.resolve()
    if not base.is_relative_to(RAW_ROOT):
        p.error('Use an isolated build-theatres directory')
    _, name, side, _, _ = next(m for m in MAPS if m[0] == a.map)
    spots = playtest.map_spots(name)
    selected = [next((s for s in half if s[2]=='AIR'), next((s for s in half if s[2] in ('TECH','TACTICAL','FRONT')), half[0]))
                for half in (spots[:len(spots)//2], spots[len(spots)//2:])]
    base.mkdir(parents=True, exist_ok=True)
    starts = base/'starts.as'
    starts.write_text('\n'.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::AIR, false),' for x,z,_ in selected))
    subprocess.run([sys.executable, str(playtest.HERE/'playtest.py'), 'stage', '--dir', str(base),
        '--dll', str(a.dll), '--map', name, '--map-file', str(starts), '--roles', 'all', '--role', 'AIR',
        '--side', side, '--ally-spots', '1', '--engine', 'recoil_2026.07.04',
        '--game', 'Beyond All Reason test-31479-433a460', '--ai-option', 'profile=experimental_hard',
        '--ai-option', 'random_seed=1791003', '--modoption', 'deathmode=neverend', '--bonus', '0',
        '--speed', '8', '--minutes', '8', '--shots', '', '--width', '1600', '--height', '900', '--lean-render',
        '--extra-widget', str(playtest.HERE/'widgets/air_recon_watch.lua')], check=True)
    scripts = base/'AI/Skirmish/BARbTest/test/script'
    setup = scripts/'src/setup.as'
    text = setup.read_text()
    needle = 'Global::AISettings::Role = derivedRole;'
    assert text.count(needle)==1
    setup.write_text(text.replace(needle, 'derivedRole = AiRole::AIR;\n'+needle))
    for manager, api, wait in [('builder','aiBuilderMgr','TaskB::Wait(60 * SECOND)'),
                              ('factory','aiFactoryMgr','TaskS::Wait(false, 60 * SECOND)')]:
        path = scripts/'src/manager'/f'{manager}.as'
        text = path.read_text(); at = text.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'); brace=text.index('{',at)
        path.write_text(text[:brace+1]+f'\n if (ai.frame >= 0) {{ u.SetFireState(0); return {api}.Enqueue({wait}); }} // supplied recon fixture\n'+text[brace+1:])
    probe = (playtest.HERE/'air_recon_probe.as').read_text().replace('const bool clusters = false;', f'const bool clusters = {str(a.clusters).lower()};')
    for profile in ['experimental_hard','experimental_balanced','experimental_terrible']:
        path=scripts/profile/'main.as'; text=path.read_text()
        assert text.count('ArtilleryPolicy::Check();')==1
        path.write_text(text.replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check(); AirReconProbe::Tick();')+'\n'+probe)
    config = {'side':side,'radar':{'armada':'armawac','cortex':'corawac','legion':'legwhisper'}[side],
              'home':list(selected[0][:2]),'enemy':list(selected[1][:2]),'speed':8,'clusters':a.clusters}
    # Lua parses this compact literal; all strings come from the fixed roster above.
    (base/'LuaUI/Config').mkdir(parents=True, exist_ok=True)
    (base/'LuaUI/Config/air_recon.lua').write_text('return {radar="'+config['radar']+'",speed=8,home={'+','.join(map(str,config['home']))+'}}\n')
    (base/'recon-fixture.json').write_text(json.dumps({'supplied_assets':True,'builders_frozen':True,
        'natural_benchmark':False,'config':config},indent=2))
    print(base)


if __name__ == '__main__':
    main()
