"""Stage an unboosted Tundra 8v8 with paired role/faction rosters and explicit seeds."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dir', type=Path, required=True)
p.add_argument('--dll', required=True)
p.add_argument('--seed', type=int, required=True)
p.add_argument('--profile', default='experimental_balanced')
p.add_argument('--minutes', type=int, default=55)
a = p.parse_args()
base = a.dir.resolve()
if not base.is_relative_to(RAW_ROOT) or a.seed <= 0:
    p.error('Use benchmark-repository build-theatres and a positive seed')
base.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'data/script/src/maps/tundra_continents.as').read_text()
# Keep the real map's known start coordinates. Pair the role and faction
# rosters; this is not a claim that Tundra's terrain is geometrically symmetric.
source, n1 = re.subn(r'(AIFloat3\(\s*300, 0,\s*460\), AiRole::)TACTICAL', r'\1AIR', source)
source, n2 = re.subn(r'(AIFloat3\(\s*9000, 0,\s*11400\), AiRole::)SEA', r'\1TACTICAL', source)
assert n1 == n2 == 1
map_file = base / 'tundra_mirrored_roster.as'
map_file.write_text(source)
subprocess.run([sys.executable, str(ROOT / 'tools/playtest/playtest.py'), 'stage',
    '--dir', str(base), '--dll', a.dll, '--map', 'Tundra Continents v2.3.1',
    '--map-file', str(map_file), '--game', 'Beyond All Reason test-31450-6562fb1',
    '--engine', 'recoil_2026.07.04', '--role', 'TECH', '--roles', 'all', '--side', 'legion',
    '--speed', '8', '--minutes', str(a.minutes), '--shots', '3@2600,10@2600,20@2600',
    '--ai-option', 'profile=' + a.profile, '--ai-option', 'random_seed=' + str(a.seed),
    '--modoption', 'experimentallegionfaction=1', '--modoption', 'experimentalextraunits=0',
    '--modoption', 'deathmode=com', '--modoption', 'nowasting=disabled',
    '--modoption', 'dynamiccheats=0',
    '--extra-widget', str(ROOT / 'tools/playtest/widgets/telchine_match_watch.lua'),
    '--extra-widget', str(ROOT / 'tools/playtest/widgets/team_stats.lua')], check=True)
staged_map = base / 'AI/Skirmish/BARbTest/test/script/src/maps/tundra_continents.as'
staged_map.write_text(source)
manifest = json.loads((base / 'teams.json').read_text())
roster = {'TECH': ['legion'], 'AIR': ['cortex'],
          'TACTICAL': ['armada', 'cortex'], 'SEA': ['armada', 'cortex', 'legion', 'armada']}
counts = {}
script = (base / 'script.txt').read_text().replace('[GAME]\n{', '[GAME]\n{\n\tFixedRNGSeed=' + str(a.seed) + ';', 1)
for team in manifest['teams']:
    key = (team['ally'], team['role'])
    slot = counts.get(key, 0)
    team['side'] = roster[team['role']][slot]
    counts[key] = slot + 1
    pattern = r'(\[TEAM' + str(team['team']) + r'\]\s*\{[^}]*?Side=)[^;]+'
    script, count = re.subn(pattern, lambda m: m[1] + team['side'], script, count=1)
    assert count == 1
(base / 'script.txt').write_text(script)
manifest.update({'seed': a.seed, 'mirrored_rosters': True, 'natural': True, 'gifts': False, 'resource_boost': False})
(base / 'teams.json').write_text(json.dumps(manifest, indent=2) + '\n')
config = base / 'LuaUI/Config'
config.mkdir(parents=True, exist_ok=True)
(config / 'telchine_speed.txt').write_text('8\n')
print(base)
