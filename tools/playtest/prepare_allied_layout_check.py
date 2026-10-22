"""Stage the explicit shared-layout obstruction probe, never production data."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dir', type=Path, required=True)
args = parser.parse_args()
base = args.dir.resolve()
if not base.is_relative_to((RAW_ROOT).resolve()):
    parser.error('fixture must be inside benchmark-repository build-theatres')
script = base / 'AI/Skirmish/BARbTest/test/script'
for profile in ['experimental_hard', 'experimental_balanced', 'experimental_terrible']:
    path = script / profile / 'main.as'
    source = path.read_text()
    source = source.replace('ArtilleryPolicy::Check();', 'ArtilleryPolicy::Check();\n        AlliedProbe::Tick();', 1)
    source = source.replace('Team::HandleMessage(msg, fromTeamId);', 'Team::HandleMessage(msg, fromTeamId);\n        AlliedProbe::Message(msg);', 1)
    source += '\n' + (ROOT / 'tools/playtest/allied_layout_probe.as').read_text()
    path.write_text(source)
print('Staged allied layout probe:', base)
