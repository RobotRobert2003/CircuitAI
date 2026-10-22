// Dense extraction uses the same native atomic reservation engine as labs/eco.
namespace MetalLayout {
    int lastPlan = -100000;
    int cursor = 0;
    int InitialModules = 5;
    int Columns = 4;
    int Rows = 2;
    string Key(int index) { return "metal.mex." + index; }
    int Modules() { return aiTerrainMgr.GetLayoutInt("metal.mex.modules", InitialModules); }
    CCircuitDef@ Mex() {
        const string side = Global::AISettings::Side;
        return ai.GetCircuitDef(side == "armada" ? "armmex" : side == "cortex" ? "cormex" : "legmex");
    }
    bool Managed() {
        return aiEconomyMgr.IsMetalMap() && (Global::AISettings::Role == AiRole::AIR || Global::AISettings::Role == AiRole::TECH);
    }
    void Release(const string &in key) {
        for (int s = 0; s < aiTerrainMgr.GetLayoutInt(key + ".n", 0); ++s)
            aiTerrainMgr.ReleasePersistentBuilding(aiTerrainMgr.GetLayoutInt(key + ".slot." + s, -1));
        aiTerrainMgr.ReleaseZone(aiTerrainMgr.GetLayoutInt(key + ".zone", 0));
        aiTerrainMgr.SetLayoutInt(key + ".n", 0);
    }
    void Plan() {
        if (!Managed() || ai.frame - lastPlan < SECOND) return;
        lastPlan = ai.frame;
        CCircuitDef@ d = Mex();
        if (d is null) return;
        int missing = -1;
        for (int m = 0; m < Modules(); ++m) {
            if (aiTerrainMgr.GetLayoutInt(Key(m) + ".n", 0) == 0) { missing = m; break; }
        }
        if (missing < 0) return;
        const int rings = int(MetalEconomy::HomeRadius / 96.0f);
        const int span = rings * 2 + 1;
        // Eight module candidates per second, at most 64 engine site tests.
        for (int attempt = 0; attempt < 8; ++attempt) {
            const int n = cursor++ % (span * span);
            const int ring = int((sqrt(float(n)) + 1.0f) * .5f);
            int x = 0, z = 0;
            if (ring > 0) {
                const int edgeSize = ring * 2;
                const int offset = n - (edgeSize - 1) * (edgeSize - 1);
                const int edge = offset / edgeSize, along = offset % edgeSize;
                if (edge == 0) { x = ring; z = -ring + 1 + along; }
                else if (edge == 1) { x = ring - 1 - along; z = ring; }
                else if (edge == 2) { x = -ring; z = ring - 1 - along; }
                else { x = -ring + 1 + along; z = -ring; }
            }
            const AIFloat3 p(Global::Map::StartPos.x + x * 96.0f, 0, Global::Map::StartPos.z + z * 96.0f);
            if (MapHelpers::SqDist(p, Global::Map::StartPos) > MetalEconomy::HomeRadius * MetalEconomy::HomeRadius) continue;
            if (aiTerrainMgr.PlanMexCluster(Key(missing), d, p, missing % 4, Columns, Rows)) return;
        }
    }
    IUnitTask@ Build(CCircuitUnit@ u) {
        Plan();
        CCircuitDef@ d = Mex();
        if (d is null || !u.circuitDef.CanBuild(d)) return null;
        if (d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;
        bool planned = true;
        for (int m = 0; m < Modules(); ++m) {
            const string key = Key(m);
            array<int> slots;
            for (int s = 0; s < aiTerrainMgr.GetLayoutInt(key + ".n", 0); ++s)
                slots.insertLast(aiTerrainMgr.GetLayoutInt(key + ".slot." + s, -1));
            if (slots.length() == 0) { planned = false; continue; }
            if (aiTerrainMgr.GetLayoutInt(key + ".started", 0) == 0) {
                const int state = LayoutHelpers::ActivationState(slots);
                if (state == 1) { Release(key); continue; }
                if (state == 2) aiTerrainMgr.SetLayoutInt(key + ".started", 1);
            }
            for (uint s = 0; s < slots.length(); ++s) {
                if (aiTerrainMgr.GetReservationState(slots[s]) != 0 || !aiTerrainMgr.IsReservationBuildable(slots[s])) continue;
                const AIFloat3 pos = aiTerrainMgr.GetReservationPos(slots[s]);
                if (!aiTerrainMgr.CanReachAt(u, pos, u.circuitDef.GetBuildDistance())) continue;
                IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEX, Task::Priority::HIGH, d, pos, -1));
                if (task is null) continue;
                if (!AiPinReservation(task, slots[s])) { aiBuilderMgr.AbortTask(task); continue; }
                aiTerrainMgr.SetLayoutInt(key + ".started", 1);
                return task;
            }
        }
        // Forty is the opening commitment, not an expansion cap. Keep one
        // additional module pending when every existing module is unavailable.
        if (planned) aiTerrainMgr.SetLayoutInt("metal.mex.modules", Modules() + 1);
        return null;
    }
}
