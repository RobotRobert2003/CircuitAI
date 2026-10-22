"""SEA recovery fixture or 8v8 natural production benchmark, with immutable pins."""
from script_settings import role_settings_path
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import playtest
import storage
from air_arena import lua


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', required=True, type=Path)
    p.add_argument('--fixture', action='store_true')
    p.add_argument('--capacity', action='store_true', help='8v8 with supplied economy, yards and fleet; not an economy benchmark')
    p.add_argument('--profile', default='experimental_balanced')
    p.add_argument('--minutes', type=float)
    p.add_argument('--stage-only', action='store_true')
    a = p.parse_args()
    if a.fixture and a.capacity: p.error('--fixture and --capacity are exclusive')
    minutes = a.minutes or (8 if a.fixture else 12 if a.capacity else 30)
    d = storage.allocate('sea', 'economy', 'priorities' if a.fixture else 'capacity-8v8' if a.capacity else 'production-8v8',
                         'supreme' if a.fixture else 'shore', 'supplied' if a.fixture or a.capacity else 'natural', seed=2111)
    starts = [(5800, 10500), (11500, 7500)] if a.fixture else [
        (x, z) for side in ((1600, 2800), (13750, 12550)) for x in side for z in (600, 1200, 1800, 2400)]
    start_file = d/'starts.as'
    start_file.write_text(',\n'.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::SEA, false)' for x,z in starts))
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    cmd = call + ['stage', '--dir', str(d), '--dll', str(a.dll), '--data', str(playtest.REPO/'data'),
        '--map', 'Supreme Isthmus v1.7' if a.fixture else 'Shore_to_Shore_V3', '--map-file', str(start_file),
        '--engine', 'recoil_2026.07.04',
        '--role', 'SEA', '--roles', 'all', '--side', 'armada', '--bonus', '0', '--speed', '20',
        '--minutes', str(minutes), '--shots', '0.8@2200@6200:10700,2@2200@6200:10700,5@2800@6500:10800,7@3500@6500:10800' if a.fixture else '1@6000@5000:1550,3@6000@6500:1550,5@6000@7500:1550,10@6000@5500:1550' if a.capacity else '5@4200@2200:1550,10@6000@5500:1550,20@7000@7500:1550,29@5000@2800:1550',
        '--width', '1280', '--height', '720', '--lean-render', '--ai-option', 'profile='+a.profile,
        '--ai-option', 'random_seed=2111', '--extra-widget', str(playtest.HERE/'widgets/sea_recovery_watch.lua'),
        '--extra-widget', str(playtest.HERE/'widgets/workforce_perf_watch.lua')]
    if a.fixture:
        cmd += ['--modoption', 'deathmode=neverend', '--modoption', 'startmetal=0',
                '--modoption', 'startmetalstorage=1000', '--modoption', 'startenergy=1000000', '--modoption', 'startenergystorage=1000000']
    subprocess.run(cmd, check=True)
    script = d/'script.txt'
    script.write_text(script.read_text().replace('[GAME]\n{', '[GAME]\n{\n FixedRNGSeed=2111;', 1))
    staged = d/'AI/Skirmish/BARbTest/test/script'
    setup = staged/'src/setup.as'
    setup.write_text(setup.read_text().replace('Global::AISettings::Role = derivedRole;',
        'derivedRole=AiRole::SEA;\nGlobal::AISettings::Role = derivedRole;'))
    if not a.fixture:
        m = staged/'src/maps/shore_to_shore.as'
        s, n = re.subn(r'(StartSpot@\[\] spots = \{).*?(\n\s*\};)',
                      lambda match: match[1]+'\n'+start_file.read_text()+match[2], m.read_text(), count=1, flags=re.S)
        assert n == 1
        m.write_text(s)
    if a.fixture:
        g=role_settings_path(staged/'src', 'Sea');g.write_text(g.read_text().replace('bool FleetOperations = true;', 'bool FleetOperations = false;'))
        for name, manager, wait in [('builder','aiBuilderMgr','TaskB::Wait(60*SECOND)'),
                                     ('factory','aiFactoryMgr','TaskS::Wait(false,SECOND)'),
                                     ('military','aiMilitaryMgr','TaskF::Wait(60*SECOND)')]:
            path=staged/'src/manager'/(name+'.as'); s=path.read_text(); at=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
            if name=='military':
                # Hold supplied repair targets with a stationary route task;
                # observer fixture supplies movement-free health targets only.
                path.write_text(s[:at+1]+'\n if (ai.frame>=0) { CRouteTask@ hold=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route())); array<AIFloat3> stay={u.GetPos(ai.frame)}; hold.SetHoldPosition(true); hold.SetPatrol(true); hold.SetRoute(stay); return hold; }\n'+s[at+1:])
                continue
            condition='!SeaRecovery::IsSub(u.circuitDef)' if name=='builder' else 'ai.frame<4*MINUTE'
            path.write_text(s[:at+1]+'\n if ('+condition+') return '+manager+'.Enqueue('+wait+');\n'+s[at+1:])
    cfg={'fixture':a.fixture,'capacity':a.capacity,'minutes':minutes,'teams':json.loads((d/'teams.json').read_text())['teams']}
    (d/'LuaUI/Config').mkdir(exist_ok=True,parents=True)
    (d/'LuaUI/Config/sea_recovery.lua').write_text('return '+lua(cfg)+'\n')
    storage.write_json(d/'recovery-pins.json', dict(cfg, seed=2111, profile=a.profile,
        dll_sha256=hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        staged_data={str(f.relative_to(staged.parent)):hashlib.sha256(f.read_bytes()).hexdigest()
                     for f in staged.parent.rglob('*') if f.suffix in ('.as','.json')},
        overrides=['SEA role forced', '16 water starts' if not a.fixture else 'frozen construction workers; supplied recovery scene; factories released at 4 minutes',
                   'Supplied T1/T2/platform, economy and fleet' if a.capacity else 'No capacity injection']))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),
                    '--dll',str(a.dll),'--scripts',str(staged)],check=True)
    dbg=d/'AI/Skirmish/BARbTest/test/SkirmishAI.dbg'
    if dbg.exists(): subprocess.run(['compact.exe','/C','/EXE:LZX','/I','/Q',str(dbg)],check=True)
    print('SEA_RECOVERY='+str(d),flush=True)
    if a.stage_only: return 0
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    return subprocess.call(call+['watch','--dir',str(d),'--role','SEA','--checks',
        'sea-recovery-priorities' if a.fixture else 'sea-capacity-8v8' if a.capacity else 'sea-production-8v8',
        '--minutes',str(minutes),'--wall-minutes','60','--keep-going'])

if __name__=='__main__': raise SystemExit(main())
