"""Add a compact-cluster observer to an already staged isolated game."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dir', type=Path, required=True)
p.add_argument('--observe-only', action='store_true')
a = p.parse_args()
base = a.dir.resolve()
if not base.is_relative_to(RAW_ROOT):
    p.error('Use benchmark-repository build-theatres')
probe = (ROOT / 'tools/playtest/air_cluster_probe.as').read_text()
if a.observe_only:
    probe = probe.replace('const bool controlled = true;', 'const bool controlled = false;')
for profile in ['experimental_balanced', 'experimental_hard', 'experimental_terrible']:
    path = base / 'AI/Skirmish/BARbTest/test/script' / profile / 'main.as'
    source = path.read_text()
    assert source.count('ArtilleryPolicy::Check();') == 1
    path.write_text(source.replace('ArtilleryPolicy::Check();',
        'ArtilleryPolicy::Check();\n        AirClusterProbe::Tick();') + '\n' + probe)
if not a.observe_only:
    (base / 'LuaUI/Widgets/allied_layout_fixture.lua').write_text(
        (ROOT / 'tools/playtest/widgets/allied_layout_fixture.lua').read_text())
print('Staged cluster probe:', base)
