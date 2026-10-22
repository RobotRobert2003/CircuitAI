"""Inject the opt-in resource probe into an already staged isolated game."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dir', type=Path, required=True)
args = parser.parse_args()
base = args.dir.resolve()
if not base.is_relative_to(RAW_ROOT.resolve()):
    parser.error('fixture must be inside benchmark-repository build-theatres')
for profile in ('experimental_balanced', 'experimental_hard', 'experimental_terrible'):
    path = base / 'AI/Skirmish/BARbTest/test/script' / profile / 'main.as'
    source = path.read_text()
    source = source.replace('ArtilleryPolicy::Check();', 'ArtilleryPolicy::Check();\n        LayoutResourceProbe::Tick();', 1)
    source = source.replace('Team::HandleMessage(msg, fromTeamId);', 'Team::HandleMessage(msg, fromTeamId);\n        LayoutResourceProbe::Message(msg, fromTeamId);', 1)
    source += '\n' + (ROOT / 'tools/playtest/layout_resource_probe.as').read_text()
    path.write_text(source)
print('Staged blueprint resource probe:', base)
