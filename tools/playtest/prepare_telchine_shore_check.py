"""Reuse the amphibious harness for labelled shoreline and inland-combat probes."""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dir', type=Path, required=True)
p.add_argument('--dll', required=True)
p.add_argument('--beachhead', action='store_true', help='Exercise retained guards protecting allied island factories while an assault advances')
p.add_argument('--profile', default='experimental_balanced')
p.add_argument('--owner-role', choices=['TECH', 'AIR'], default='TECH')
p.add_argument('--allied-guards', action='store_true', help='Add twelve autonomous AIR Telchines to compete for the same guard site')
p.add_argument('--minutes', type=int, default=12)
p.add_argument('--map', choices=['tundra', 'supreme'], default='tundra', help='Supreme is for inland land-attack checks only')
p.add_argument('--land-attack', action='store_true', help='Add enemy land targets on the starting island to exercise autonomous formation combat')
a = p.parse_args()
if a.map != "tundra" and (not a.land_attack or a.beachhead or a.allied_guards):
    p.error("Supreme requires --land-attack without beachhead or allied-guards")
if a.allied_guards and (not a.beachhead or a.owner_role != 'TECH'):
    p.error('--allied-guards requires --beachhead and --owner-role TECH')
base = a.dir.resolve()
if not base.is_relative_to(RAW_ROOT):
    p.error('Use benchmark-repository build-theatres')
subprocess.run([sys.executable, str(ROOT / 'tools/playtest/prepare_amphibious_check.py'),
    '--map', a.map, '--dir', str(base), '--dll', a.dll,
    '--profile', a.profile, '--windowed', '--speed', '8', '--minutes', str(a.minutes)], check=True)
if a.owner_role == 'AIR':
    setup = base / 'AI/Skirmish/BARbTest/test/script/src/setup.as'
    text = setup.read_text()
    text = text.replace('ai.teamId == 0 ? AiRole::TECH : (ai.teamId == 1 ? AiRole::AIR',
                        'ai.teamId == 0 ? AiRole::AIR : (ai.teamId == 1 ? AiRole::FRONT')
    setup.write_text(text)
    teams = json.loads((base / 'teams.json').read_text())
    teams['teams'][0]['role'] = 'AIR'
    # The allied fixture only holds injected economic assets. A frozen TECH
    # with a gifted T2 lab would correctly violate its production invariants.
    teams['teams'][1]['role'] = 'FRONT'
    (base / 'teams.json').write_text(json.dumps(teams, indent=2) + '\n')
widgets = base / 'LuaUI/Widgets'
# Replace only this isolated run's injection and camera widgets.
shutil.copy2(ROOT / 'tools/playtest/widgets/telchine_shore_fixture.lua', widgets / 'amphibious_fixture.lua')
(widgets / 'amphibious_visual.lua').unlink()
shutil.copy2(ROOT / 'tools/playtest/widgets/telchine_match_watch.lua', widgets / 'telchine_match_watch.lua')
config = base / 'LuaUI/Config'
(config / 'telchine_observer.lua').write_text('return {controlled=true}\n')
(config / 'telchine_speed.txt').write_text('8\n')
(config / 'telchine_shore.lua').write_text('return {beachhead=' + str(a.beachhead).lower()
    + ', alliedGuards=' + str(a.allied_guards).lower() + ', landAttack=' + str(a.land_attack).lower() + '}\n')
(base / 'shore-probe.txt').write_text(
    f'Controlled naval retreat probe: {12 if a.beachhead else 6} gifted {a.owner_role} Telchines, '
    f'{12 if a.allied_guards else 0} additional allied AIR Telchines, frozen builders and production, '
    'global LOS, spectator godmode for order permission; fixture orders only enemy team 2.\n')
(base / 'amphibious-fixture.json').write_text(json.dumps({
    'fixture': 'telchine_beachhead' if a.beachhead else 'telchine_shore', 'controlled': True,
    'injected_telchines': 24 if a.allied_guards else (12 if a.beachhead else 6), 'allied_island_factories': a.beachhead,
    'role': a.owner_role, 'profile': a.profile, 'allied_guard_competitor': a.allied_guards,
    'land_attack_targets': a.land_attack, 'map': a.map,
    'global_los': True, 'godmode': 3,
    'ordered_teams': [2], 'autonomous_builders': False,
    'natural_production': False, 'deathmode': 'neverend'}, indent=2) + '\n')
print(base)
