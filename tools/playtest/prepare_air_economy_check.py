"""Isolated AIR gift/capacity scenarios; supplied assets are never natural benchmarks."""
import argparse
import json
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dir', type=Path, required=True)
p.add_argument('--dll', required=True)
p.add_argument('--scenario', choices=['constructor', 'capacity'], required=True)
a = p.parse_args()
base = a.dir.resolve()
if not base.is_relative_to(RAW_ROOT):
    p.error('Use benchmark-repository build-theatres')
base.mkdir(parents=True, exist_ok=True)
starts = base / 'starts.as'
starts.write_text('StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),\n'
                  'StartSpot(AIFloat3(11456,0,1901), AiRole::FRONT, false),\n')
minutes = '45' if a.scenario == 'capacity' else '25'
subprocess.run([sys.executable, str(ROOT / 'tools/playtest/playtest.py'), 'stage',
    '--dir', str(base), '--dll', a.dll, '--map', 'Supreme Isthmus v1.7', '--map-file', str(starts),
    '--game', 'Beyond All Reason test-31479-433a460', '--engine', 'recoil_2026.07.04',
    '--role', 'AIR', '--roles', 'all', '--side', 'armada', '--ally-spots', '1', '--bonus', '0',
    '--speed', '8', '--minutes', minutes, '--shots', '5,10,20,24' if minutes == '25' else '10,20,35,44',
    '--slow-near-shots', '--width', '1280', '--height', '720', '--modoption', 'deathmode=neverend',
    '--extra-widget', str(ROOT / 'tools/playtest/widgets/air_watch.lua'),
    '--extra-widget', str(ROOT / 'tools/playtest/widgets/air_opening_watch.lua')], check=True)
subprocess.run([sys.executable, str(ROOT / 'tools/playtest/prepare_air_check.py'),
    '--dir', str(base), '--scenario', a.scenario, '--seed', '1001162'], check=True)
scripts = base / 'AI/Skirmish/BARbTest/test/script/src'
setup = scripts / 'setup.as'
s = setup.read_text(); key = 'Global::AISettings::Role = derivedRole;'
assert s.count(key) == 1
setup.write_text(s.replace(key, 'derivedRole = ai.teamId == 0 ? AiRole::AIR : AiRole::FRONT;\n' + key))
for name, manager, descriptor in [('builder', 'aiBuilderMgr', 'TaskB::Wait(60 * SECOND)'),
                                  ('factory', 'aiFactoryMgr', 'TaskS::Wait(false, 60 * SECOND)')]:
    path = scripts / 'manager' / (name + '.as')
    s = path.read_text(); at = s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'); brace = s.index('{', at)
    path.write_text(s[:brace + 1] + '\n if (ai.teamId == 1) return ' + manager + '.Enqueue(' + descriptor + '); // isolated economy\n' + s[brace + 1:])
if a.scenario == 'capacity':
    # Known targets exercise the growing fleet without pretending to test PvP defense.
    (base / 'LuaUI/Widgets/air_capacity_targets.lua').write_text('''
function widget:GetInfo() return {name="AIR capacity targets",layer=119,enabled=true} end
function widget:GameFrame(f)
 if f==900 then
  Spring.SendCommands({"cheat 1","globallos","give 6 armfus 1 @11456,0,1901"})
  Spring.Echo("[AirCapacity] supplied static targets/global LOS; enemy construction frozen")
 end
end
''')
(base / 'economy-fixture.json').write_text(json.dumps({'scenario': a.scenario,
    'enemy_construction_frozen': True, 'global_los': a.scenario == 'capacity',
    'supplied_assets': True, 'natural_benchmark': False}, indent=2))
print(base)
