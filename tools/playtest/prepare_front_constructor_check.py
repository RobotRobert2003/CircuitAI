"""Instrument an isolated staged game to observe stable FRONT constructor seats."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dir', type=Path, required=True)
args = parser.parse_args()
base = args.dir.resolve()
if not base.is_relative_to(RAW_ROOT):
    parser.error('Use the isolated benchmark game store')
scripts = base / 'AI/Skirmish/BARbTest/test/script'
probe = (ROOT/'tools/playtest/front_constructor_probe.as').read_text()
for profile in ('experimental_balanced', 'experimental_hard', 'experimental_terrible'):
    path = scripts/profile/'main.as'
    source = path.read_text()
    assert source.count('ArtilleryPolicy::Check();') == 1
    path.write_text(source.replace('ArtilleryPolicy::Check();',
        'ArtilleryPolicy::Check(); FrontRosterProbe::Tick();')+'\n'+probe)
path = scripts/'src/systems/construction/front_constructors.as'
source = path.read_text()
assert source.count('if (seat == 0) unit.AddAttribute') == 1
source = source.replace('if (seat == 0) unit.AddAttribute',
    'FrontRosterProbe::Added(unit.id,seat);\n        if (seat == 0) unit.AddAttribute')
assert source.count('seats[seat] = -1; Save(seat);') == 1
source = source.replace('seats[seat] = -1; Save(seat);',
    'FrontRosterProbe::Removed(unit.id,seat);\n        seats[seat] = -1; Save(seat);')
path.write_text(source)
print('Staged FRONT constructor observer:',base)
