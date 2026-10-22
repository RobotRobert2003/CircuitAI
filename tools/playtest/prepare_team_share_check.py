"""Stage supplied metal/factory sharing probes in an isolated 16-AI game."""
import argparse
import json
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dir', type=Path, required=True)
args = parser.parse_args()
base = args.dir.resolve()
if not base.is_relative_to(RAW_ROOT):
    parser.error('Use an isolated directory under build-theatres')
teams = json.loads((base / 'teams.json').read_text())['teams']
donors = {}
for team in teams:
    donors.setdefault(team['role'], team)
assert set(donors) == {'TECH', 'AIR', 'FRONT', 'SEA', 'TACTICAL', 'SUPPORT'}
rows = []
for team in donors.values():
    prefix = {'armada': 'arm', 'cortex': 'cor', 'legion': 'leg'}[team['side']]
    suffix = {'AIR': 'ap', 'SEA': 'sy', 'TACTICAL': 'hp'}.get(team['role'], 'lab')
    rows.append('{team=%d,role="%s",factory="%s",x=%d,z=%d}' %
                (team['team'], team['role'], prefix + suffix, team['x'], team['z']))
source = 'local donors={' + ','.join(rows) + '}\n'
source += (ROOT / 'tools/playtest/widgets/team_share_fixture.lua').read_text()
(base / 'LuaUI/Widgets/team_share_fixture.lua').write_text(source)
(base / 'team-share-fixture.json').write_text(json.dumps(list(donors.values()), indent=2))
print('Supplied sharing fixture:', base)
