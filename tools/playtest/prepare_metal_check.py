"""Register explicit role/start fixtures in an isolated staged tree only.

Run with --map to write the --map-file input before staging, then again with
--dir after stage to register that same file. No live install or resources edited.
"""
import argparse
from pathlib import Path

MAPS = {
    "Full Metal Plate 1.7": [(2400,850,"TECH"),(4700,2500,"AIR"),(9650,11400,"TECH"),(7350,9750,"AIR")],
    "SpeedMetal BAR V2": [(1000,250,"TECH"),(1000,900,"AIR"),(12300,250,"TECH"),(12300,900,"AIR")],
    "Nine_Metal_Islands_V1": [(1900,5400,"TECH"),(2037,10300,"AIR"),(15100,9200,"TECH"),(14440,5084,"AIR")],
}
def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--map", required=True, choices=MAPS)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--dir", type=Path)
    p.add_argument("--cancel-first", action="store_true", help="In the staged tree only, cancel one served unframed mex and assert pin recovery")
    a = p.parse_args()
    spots = ",\n".join(f"StartSpot(AIFloat3({x}, 0, {z}), AiRole::{role}, false)" for x,z,role in MAPS[a.map])
    text = f'''// Controlled start/role fixture; no economy gifts.
namespace MetalFixture {{
StartSpot@[] spots = {{
{spots}
}};
dictionary limits;
MapConfig config = MapConfig("{a.map}", limits, spots, null);
}}
'''
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(text, encoding="utf-8")
    if a.dir:
        root = a.dir.resolve() / "AI/Skirmish/BARbTest/test/script/src"
        maps = root / "maps.as"
        source = maps.read_text(encoding="utf-8")
        if 'maps/metal_fixture.as' not in source:
            source = '#include "maps/metal_fixture.as"\n' + source
            source = source.replace('void registerMaps() {', 'void registerMaps() {\n        mapManager.RegisterMapConfig(MetalFixture::config);')
            maps.write_text(source, encoding="utf-8")
        (root / "maps/metal_fixture.as").write_text(text, encoding="utf-8")
        if a.cancel_first:
            manager = root / 'systems/construction/metal_economy.as'
            policy = manager.read_text(encoding='utf-8')
            if 'MetalCancelFixture::Tick' not in policy:
                policy = '#include "metal_cancel_fixture.as"\n' + policy
                policy = policy.replace('snapshotFrame = ai.frame;', 'snapshotFrame = ai.frame;\n        MetalCancelFixture::Tick();', 1)
                manager.write_text(policy, encoding='utf-8')
            (root / 'systems/construction/metal_cancel_fixture.as').write_text('''// Controlled cancellation, staged tests only. No resource or unit gifts.
namespace MetalCancelFixture {
    bool cancelled = false;
    void Tick() {
        if (cancelled || ai.teamId != 0) return;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null) continue;
            IBuilderTask@ order = cast<IBuilderTask>(u.task);
            if (order is null || order.IsDead() || order.target !is null
                || order.GetBuildType() != int(Task::BuildType::MEX)) continue;
            const int pin = AiTaskReservationId(order);
            if (pin < 0) continue;
            cancelled = true;
            aiBuilderMgr.AbortTask(order);
            GenericHelpers::LogUtil("[MetalCancelFixture] cancelled pin=" + pin
                + " taskPin=" + AiTaskReservationId(order) + " state=" + aiTerrainMgr.GetReservationState(pin), 1);
            return;
        }
    }
}
''', encoding='utf-8')
    print(a.output.resolve())
if __name__ == "__main__":
    main()
