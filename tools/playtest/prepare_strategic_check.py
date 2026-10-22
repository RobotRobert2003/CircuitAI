"""Install a controlled strategic-weapon fixture into an isolated staged playtest."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT
import json
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dir', type=Path, required=True)
p.add_argument('--scenario', choices=['juno', 'nuclear'], required=True)
a = p.parse_args()
base = a.dir.resolve()
if not base.is_relative_to(RAW_ROOT):
    p.error('fixture directory must be under benchmark-repository build-theatres')
widget = base / 'LuaUI/Widgets/strategic_fixture.lua'
widget.write_text('local scenario = '+json.dumps(a.scenario)+'\n'+(ROOT/'tools/playtest/widgets/strategic_fixture.lua').read_text())
scripts = base/'AI/Skirmish/BARbTest/test/script/src/manager'
builder = scripts/'builder.as'
text = builder.read_text()
needle = 'IUnitTask@ AiMakeTask(CCircuitUnit@ u) {'
assert needle in text
builder.write_text(text.replace(needle, needle+'\n        if (ai.frame >= 0) return aiBuilderMgr.Enqueue(TaskB::Wait(60 * SECOND)); // fixture: no autonomous construction', 1))
military = scripts/'military.as'
text = military.read_text()
needle = 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)\n\t{'
assert needle in text
military.write_text(text.replace(needle, needle+'\n        if (u.circuitDef.GetName() == "armbanth") return null; // stationary mobile-only probe', 1))
(base/'strategic-fixture.json').write_text(json.dumps({'scenario':a.scenario}, indent=2))
print('Strategic fixture:', a.scenario, base)
