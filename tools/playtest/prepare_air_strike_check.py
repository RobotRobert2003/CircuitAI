"""Rendered early/mid/late AIR combat capability checks; supplied units, not economy."""
from script_settings import role_settings_path
import argparse
import json
import re
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dir', type=Path, required=True)
p.add_argument('--dll', required=True)
p.add_argument('--side', choices=['armada', 'cortex', 'legion'], default='armada')
p.add_argument('--profile', default='experimental_balanced')
p.add_argument('--minutes', default='13')
p.add_argument('--seed', type=int, default=1621)
p.add_argument('--assembly-radius', type=float)
a = p.parse_args()
base = a.dir.resolve()
if not base.is_relative_to(RAW_ROOT) or a.seed <= 0:
    p.error('Use benchmark-repository build-theatres and a positive seed')
if a.assembly_radius is not None and not 64 <= a.assembly_radius <= 800:
    p.error('Assembly radius must be between 64 and 800')
base.mkdir(parents=True, exist_ok=True)
starts = base / 'starts.as'
starts.write_text('StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),\n'
                  'StartSpot(AIFloat3(11456,0,1901), AiRole::FRONT, false),\n')
subprocess.run([sys.executable, str(ROOT / 'tools/playtest/playtest.py'), 'stage',
    '--dir', str(base), '--dll', a.dll, '--map', 'Supreme Isthmus v1.7', '--map-file', str(starts),
    '--game', 'Beyond All Reason test-31479-433a460', '--engine', 'recoil_2026.07.04',
    '--role', 'AIR', '--roles', 'all', '--side', a.side, '--ally-spots', '1', '--bonus', '0',
    '--speed', '5', '--minutes', a.minutes, '--shots', '', '--width', '1280', '--height', '720',
    '--ai-option', 'profile=' + a.profile, '--ai-option', 'random_seed=' + str(a.seed), '--modoption', 'experimentallegionfaction=1',
    '--modoption', 'deathmode=neverend', '--extra-widget', str(ROOT / 'tools/playtest/widgets/air_strike_fixture.lua'),
    '--extra-widget', str(ROOT / 'tools/playtest/widgets/air_watch.lua')], check=True)
scripts = base / 'AI/Skirmish/BARbTest/test/script/src'
start_script = base / 'script.txt'
source = start_script.read_text()
source, count = re.subn(r'(\[GAME\]\s*\{)', lambda m: m[1] + '\n FixedRNGSeed=' + str(a.seed) + ';', source, count=1)
assert count == 1
start_script.write_text(source)
if a.assembly_radius is not None:
    settings = role_settings_path(scripts, 'Air')
    source, count = re.subn(r'float StrikeAssemblyRadius = [\d.]+f;',
        'float StrikeAssemblyRadius = ' + str(a.assembly_radius) + 'f;', settings.read_text())
    assert count == 1
    settings.write_text(source)
setup = scripts / 'setup.as'
s = setup.read_text(); key = 'Global::AISettings::Role = derivedRole;'
assert s.count(key) == 1
setup.write_text(s.replace(key, 'derivedRole = ai.teamId == 0 ? AiRole::AIR : AiRole::FRONT;\n' + key))
for name, manager, descriptor in [('builder', 'aiBuilderMgr', 'TaskB::Wait(60 * SECOND)'),
                                  ('factory', 'aiFactoryMgr', 'TaskS::Wait(false, 60 * SECOND)')]:
    path = scripts / 'manager' / (name + '.as')
    s = path.read_text(); at = s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'); brace = s.index('{', at)
    path.write_text(s[:brace + 1] + '\n if (ai.frame >= 0) return ' + manager + '.Enqueue(' + descriptor + '); // controlled combat\n' + s[brace + 1:])
(base / 'LuaUI/Config').mkdir(parents=True, exist_ok=True)
(base / 'LuaUI/Config/air_strike_fixture.lua').write_text('return {side=' + json.dumps(a.side) + '}\n')
(base / 'air-strike-fixture.json').write_text(json.dumps({'side': a.side, 'profile': a.profile,
    'engine_seed': a.seed, 'ai_seed': a.seed, 'assembly_radius_override': a.assembly_radius,
    'global_los': True, 'supplied_units': True, 'builders_and_factories_frozen': True}, indent=2))
checks=json.loads((ROOT/'tools/playtest/checks/air/combat/air_strike_stages.json').read_text())
checks['expect'].append({'key':'early-damage','pattern':r'\[AirStrike\] stage-damage stage=1','scope':'any','by_minute':4})
(base/'checks.json').write_text(json.dumps(checks,indent=2))
print(base)
