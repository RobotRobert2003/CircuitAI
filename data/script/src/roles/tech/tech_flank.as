// D-136: a dedicated factory feeds an accessible specialist mountain lane.
#include "../../systems/world/lanes.as"
#include "../../systems/construction/layout.as"
#include "../../systems/construction/lifecycle.as"

namespace TechFlank {
    bool loaded = false, enabled = true, laneQualified = false;
    float minMetal = 200.0f, siteRadius = 1200.0f;
    string combatName;
    int factoryId = -1, retryFrame = -100000, laneRevision = -1;
    AIFloat3 site(-1.0f, 0.0f, -1.0f);
    AIFloat3 corridor(-1.0f, 0.0f, -1.0f);
    IUnitTask@ buildTask;
    CRouteTask@ routeTask;
    array<AIFloat3> route;
    dictionary members;

    void Say(const string &in s) { GenericHelpers::LogUtil("[TECH][Flank] " + s, 1); }
    void Load()
    {
        if (loaded) return;
        loaded = true;
        enabled = aiSetupMgr.ConfigBool("lanes/flank_enabled", true);
        minMetal = AiMax(0.0f, aiSetupMgr.ConfigFloat("lanes/flank_min_metal", 200.0f));
        siteRadius = AiMax(256.0f, aiSetupMgr.ConfigFloat("lanes/flank_site_radius", 1200.0f));
        const string side = Global::AISettings::Side;
        combatName = aiSetupMgr.ConfigString("lanes/flank_unit_" + side,
            side == "legion" ? "legsrail" : (side == "cortex" ? "cortermite" : "armsptk"));
        factoryId = aiTerrainMgr.GetLayoutInt("tech.flank.factory", -1);
        site = AIFloat3(float(aiTerrainMgr.GetLayoutInt("tech.flank.x", -1)), 0.0f,
            float(aiTerrainMgr.GetLayoutInt("tech.flank.z", -1)));
    }
    bool Enabled() { Load(); return enabled && Global::AISettings::Role == AiRole::TECH && Lanes::Enabled(); }
    CCircuitDef@ Lab() { return ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side)); }
    bool Owns(CCircuitUnit@ u)
    {
        Load();
        if (u is null || u.circuitDef is null) return false;
        CCircuitDef@ lab = Lab();
        if (site.x < 0.0f || lab is null || u.circuitDef.id != lab.id || u.GetPos(ai.frame).distance2D(site) > 64.0f) return false;
        if (u.id == factoryId) return true;
        factoryId = u.id;
        aiTerrainMgr.SetLayoutInt("tech.flank.factory", factoryId);
        return true;
    }
    int Count(bool unfinishedOnly = false)
    {
        Load();
        if (site.x < 0.0f) return 0;
        CCircuitUnit@ f = factoryId < 0 ? null : ai.GetTeamUnit(factoryId);
        if (f is null) @f = aiBuilderMgr.FindUnfinishedNear(site, 64.0f, Lab());
        return Owns(f) && (!unfinishedOnly || f.GetBuildProgress() < 1.0f) ? 1 : 0;
    }
    int NormalLabCount()
    {
        return AiMax(0, UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs()) - Count());
    }
    // A complete native land path to the friendly end is mandatory. No nearest-
    // shore snap, amphibious connector, or transport is substituted.
    bool Select(const AIFloat3 &in from)
    {
        laneQualified = false; // a failed refresh must not reuse the previous qualification
        float best = 1.0e30f;
        int selected = -1, rejected = 0;
        array<AIFloat3> chosen;
        for (int i = 0; i < aiBattle.GetLaneCount(); ++i) {
            if (!aiBattle.IsLaneSpecialist(i)) continue;
            array<AIFloat3>@ points = aiBattle.GetLaneRoute(i, from, Lanes::ALLTERRAIN);
            if (points.length() < 2) { ++rejected; continue; }
            const AIFloat3 mid = aiBattle.GetLanePoint(i, 0.5f);
            // Keep a standing factory on its established theatre after surveys.
            if (corridor.x >= 0.0f && mid.distance2D(corridor) > 1600.0f) continue;
            float length = 0.0f, elevation = 0.0f;
            for (uint k = 1; k < points.length(); ++k) length += points[k].distance2D(points[k-1]);
            for (int k = 2; k <= 8; ++k) elevation += aiBattle.GetLanePoint(i, float(k)/10.0f).y;
            const float gain = AiMax(0.0f, elevation / 7.0f - aiBattle.Height(from));
            const float score = length * (1.0f + 0.01f * aiBattle.GetLaneThreat(i)) / (1.0f + gain * 0.003f);
            if (score >= best) continue;
            best = score; selected = i; chosen = points;
        }
        laneRevision = Lanes::calcs;
        if (selected < 0) { Say("no reachable specialist lane; disconnected=" + rejected); return false; }
        laneQualified = true;
        route = chosen;
        if (routeTask !is null && !routeTask.IsDead()) routeTask.SetRoute(route);
        corridor = aiBattle.GetLanePoint(selected, 0.5f);
        Say("selected lane=" + selected + " middle=(" + int(corridor.x) + "," + int(corridor.z)
            + ") waypoints=" + route.length() + " disconnected=" + rejected);
        return true;
    }
    void Tick()
    {
        if (!Enabled()) return;
        // Resolve IDs each tick; do not retain a borrowed unit across frames.
        if (factoryId >= 0 && !Owns(ai.GetTeamUnit(factoryId))) {
            factoryId = -1;
            aiTerrainMgr.SetLayoutInt("tech.flank.factory", -1);
            Say("factory lost; replacement eligible");
        }
        array<string>@ keys = members.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(int(parseInt(keys[i])));
            if (u is null) { members.delete(keys[i]); aiTerrainMgr.SetLayoutInt("tech.flank.unit." + keys[i], 0); continue; }
            if (routeTask !is null && u.task !is routeTask)
                Invariants::Violation("INV-067", keys[i], "flank combat unit left its dedicated route");
        }
    }
    IUnitTask@ Work(CCircuitUnit@ u)
    {
        if (!Enabled() || u is null || u.circuitDef is null || UnitHelpers::IsAirConstructor(u.circuitDef)) return null;
        CCircuitDef@ lab = Lab();
        CCircuitDef@ combat = ai.GetCircuitDef(combatName);
        if (lab is null || combat is null || !lab.CanBuild(combat) || !u.circuitDef.CanBuild(lab)) return null;
        CCircuitUnit@ f = factoryId < 0 ? null : ai.GetTeamUnit(factoryId);
        if (f !is null) {
            if (f.GetBuildProgress() < 1.0f && !Lifecycle::IsRetiring(f))
                return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, f, 60 * SECOND));
            return null;
        }
        if (buildTask !is null && !buildTask.IsDead()) return buildTask;
        if (Economy::GetMinMetalIncomeLast10s() < minMetal || ai.frame - retryFrame < 15 * SECOND) return null;
        retryFrame = ai.frame;
        // Ensure ordinary T2 production remains on a separate lab.
        if (site.x < 0.0f && (Factory::primaryT2BotLab is null || Lifecycle::IsRetiring(Factory::primaryT2BotLab))) return null;
        if (!Select(Global::Map::StartPos)) return null;
        const int reservation = Layout::CrampedLabSite(lab, Global::Map::StartPos, siteRadius, u, 32.0f);
        if (reservation < 0) { Say("no reachable factory footprint; retry later"); return null; }
        const AIFloat3 p = aiTerrainMgr.GetReservationPos(reservation);
        if (!Select(p)) { aiTerrainMgr.ReleaseReservation(reservation); return null; }
        if (lab.maxThisUnit <= lab.count) lab.maxThisUnit = lab.count + 1;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::HIGH, lab, p, null, 0.0f, false, true, 600 * SECOND));
        if (t is null) { aiTerrainMgr.ReleaseReservation(reservation); return null; }
        AiPinReservation(t, reservation);
        site = p;
        aiTerrainMgr.SetLayoutInt("tech.flank.x", int(p.x));
        aiTerrainMgr.SetLayoutInt("tech.flank.z", int(p.z));
        @buildTask = t;
        Say("ordered " + lab.GetName() + " at (" + int(p.x) + "," + int(p.z) + ") income=" + int(Economy::GetMinMetalIncomeLast10s()));
        return t;
    }
    CRouteTask@ Route()
    {
        if (routeTask !is null && !routeTask.IsDead()) return routeTask;
        if (route.length() < 2 && !Select(site)) return null;
        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Route());
        IFighterTask@ ft = cast<IFighterTask>(t);
        @routeTask = ft is null ? null : cast<CRouteTask>(ft);
        if (routeTask !is null) {
            routeTask.SetTraversal(true, 48.0f, true);
            routeTask.SetLanes(1, 0.0f, 0.0f);
            routeTask.SetRoute(route);
        }
        return routeTask;
    }
    IUnitTask@ Produce(CCircuitUnit@ f)
    {
        if (!Enabled() || !Owns(f)) return null;
        if (Lifecycle::IsRetiring(f)) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
        if (laneRevision != Lanes::calcs && !Select(f.GetPos(ai.frame)))
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
        if (!laneQualified) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
        CCircuitDef@ combat = ai.GetCircuitDef(combatName);
        if (combat is null || !f.circuitDef.CanBuild(combat) || Route() is null)
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
        if (combat.maxThisUnit <= combat.count) combat.maxThisUnit = combat.count + 1;
        Say("produce " + combatName + " factory=" + f.id);
        return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, combat, f.GetPos(ai.frame), 64.0f));
    }
    IUnitTask@ MilitaryTask(CCircuitUnit@ u)
    {
        if (!Enabled() || u is null || u.circuitDef is null || u.circuitDef.GetName() != combatName) return null;
        const string key = "" + u.id;
        if ((factoryId < 0 || u.GetProducerId() != factoryId) && aiTerrainMgr.GetLayoutInt("tech.flank.unit." + key, 0) == 0) return null;
        CRouteTask@ t = Route();
        if (t is null) return null;
        members.set(key, true);
        aiTerrainMgr.SetLayoutInt("tech.flank.unit." + key, 1);
        Say("routed " + combatName + " unit=" + u.id + " producer=" + u.GetProducerId() + " waypoints=" + t.GetRouteSize());
        return t;
    }
    void TaskRemoved(IUnitTask@ t) { if (t is routeTask) @routeTask = null; if (t is buildTask) @buildTask = null; }
    void UnitRemoved(CCircuitUnit@ u)
    {
        if (u is null) return;
        const string key = "" + u.id;
        if (members.exists(key)) {
            members.delete(key);
            aiTerrainMgr.SetLayoutInt("tech.flank.unit." + key, 0);
        }
    }
}
