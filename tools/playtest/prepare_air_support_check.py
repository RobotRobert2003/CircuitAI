"""Add a physical support-pin obstruction to an already staged AIR capacity game."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dir', type=Path, required=True)
a = p.parse_args()
base = a.dir.resolve()
if not base.is_relative_to(RAW_ROOT):
    p.error('Use benchmark-repository build-theatres')
scripts = base / 'AI/Skirmish/BARbTest/test/script'
for profile in ['experimental_balanced', 'experimental_hard', 'experimental_terrible']:
    path = scripts / profile / 'main.as'
    source = path.read_text()
    assert source.count('ArtilleryPolicy::Check();') == 1
    source = source.replace('ArtilleryPolicy::Check();', 'ArtilleryPolicy::Check();\n        AirSupportProbe::Tick();')
    path.write_text(source + '\n' + (ROOT / 'tools/playtest/air_support_probe.as').read_text())
(base / 'LuaUI/Widgets/allied_layout_fixture.lua').write_text((ROOT / 'tools/playtest/widgets/allied_layout_fixture.lua').read_text())
print('Staged physical T2 support obstruction:', base)
