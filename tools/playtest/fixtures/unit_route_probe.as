// Fixed workload, no orders: compare identical queries across DLLs. Native
// CIRCUIT_VERIFY_UNIT_ROUTES separately checks exact geometry/search equality.
namespace UnitRouteProbe {
    void Query(int sample) {
        if (ai.teamId != 0) return;
        const array<string> names = {"armck", "armack", "armbeaver", "armamph"};
        for (uint index = 0; index < names.length(); ++index) {
            CCircuitDef@ def = ai.GetCircuitDef(names[index]);
            const bool dry = index < 2;
            AIFloat3 from(1200, 0, 10400);
            AIFloat3 to(dry ? 4000 : 6144, 0, dry ? 10400 : 6144);
            if (AiPerfEnabled) AiPerfBeginLabel("route-fixture-" + sample + "-" + index);
            array<AIFloat3>@ points = aiBattle.GetUnitTerrainRoute(def, from, to, dry, 1, 6, 8, 0);
            if (AiPerfEnabled) AiPerfEndLabel();
            string ordered;
            for (uint point = 0; point < points.length(); ++point)
                ordered += ";" + int(points[point].x) + "," + int(points[point].z);
            GenericHelpers::LogUtil("[UnitRouteTest] sample=" + sample + " def=" + names[index]
                + " count=" + points.length() + " route=" + ordered, 1);
        }
        if (sample == 9) GenericHelpers::LogUtil("[UnitRouteTest] PASS queries completed", 1);
    }
    bool Handle(const string& in message) {
        if (message.findFirst("unit-route-probe|") != 0) return false;
        array<string>@ fields = message.split("|");
        if (fields.length() == 2) Query(parseInt(fields[1]));
        return true;
    }
}
