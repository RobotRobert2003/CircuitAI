"""Liche escort strikes (owner 2026-10-24): supplied Phoenix waves carry Liches
that guard a bomber and break off for roster targets; supplied units, not economy.

Stages the AIR-vs-FRONT Supreme Isthmus arena of prepare_air_strike_check.py
(builders and factories frozen, global LOS, fixed seeds) with the
liche_strike_fixture.lua widget. Run it, then:

    python tools/playtest/playtest.py launch --dir <dir> --headless --engine recoil_2026.07.04
    python tools/playtest/playtest.py watch --dir <dir> --checks <dir>/checks.json --minutes 13
    python tools/playtest/analyze_liche_strikes.py <dir>/infolog.txt
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument('--dir', type=Path, required=True)
p.add_argument('--dll', required=True)
p.add_argument('--data', default=str(ROOT / 'data'))
p.add_argument('--game', default='Beyond All Reason test-31450-6562fb1')
p.add_argument('--engine', default='recoil_2026.07.04')
p.add_argument('--profile', default='experimental_balanced')
p.add_argument('--minutes', default='13')
p.add_argument('--seed', type=int, default=1621)
a = p.parse_args()
base = a.dir.resolve()
if a.seed <= 0:
    p.error('Use a positive seed')
base.mkdir(parents=True, exist_ok=True)
starts = base / 'starts.as'
starts.write_text('StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),\n'
                  'StartSpot(AIFloat3(11456,0,1901), AiRole::FRONT, false),\n')
subprocess.run([sys.executable, str(ROOT / 'tools/playtest/playtest.py'), 'stage',
    '--dir', str(base), '--dll', a.dll, '--data', a.data, '--map', 'Supreme Isthmus v1.7', '--map-file', str(starts),
    '--game', a.game, '--engine', a.engine,
    '--role', 'AIR', '--roles', 'all', '--side', 'armada', '--ally-spots', '1', '--bonus', '0',
    '--mode', 'fast', '--speed', '20', '--minutes', a.minutes, '--headless',
    '--ai-option', 'profile=' + a.profile, '--ai-option', 'random_seed=' + str(a.seed),
    '--modoption', 'deathmode=neverend', '--extra-widget', str(ROOT / 'tools/playtest/widgets/liche_strike_fixture.lua')],
    check=True)
scripts = base / 'AI/Skirmish/BARbTest/test/script/src'
start_script = base / 'script.txt'
source = start_script.read_text()
source, count = re.subn(r'(\[GAME\]\s*\{)', lambda m: m[1] + '\n FixedRNGSeed=' + str(a.seed) + ';', source, count=1)
assert count == 1
start_script.write_text(source)
setup = scripts / 'setup.as'
s = setup.read_text(); key = 'Global::AISettings::Role = derivedRole;'
assert s.count(key) == 1
setup.write_text(s.replace(key, 'derivedRole = ai.teamId == 0 ? AiRole::AIR : AiRole::FRONT;\n' + key))
for name, manager, descriptor in [('builder', 'aiBuilderMgr', 'TaskB::Wait(60 * SECOND)'),
                                  ('factory', 'aiFactoryMgr', 'TaskS::Wait(false, 60 * SECOND)')]:
    path = scripts / 'manager' / (name + '.as')
    s = path.read_text(); at = s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'); brace = s.index('{', at)
    path.write_text(s[:brace + 1] + '\n if (ai.frame >= 0) return ' + manager + '.Enqueue(' + descriptor + '); // controlled combat\n' + s[brace + 1:])
(base / 'liche-strike-fixture.json').write_text(json.dumps({'side': 'armada', 'profile': a.profile,
    'engine_seed': a.seed, 'ai_seed': a.seed, 'global_los': True, 'supplied_units': True,
    'builders_and_factories_frozen': True, 'stages': 3, 'liches_per_stage': 6}, indent=2))
checks = json.loads((ROOT / 'tools/playtest/checks/air/combat/liche_strike.json').read_text())
(base / 'checks.json').write_text(json.dumps(checks, indent=2))
print(base)
