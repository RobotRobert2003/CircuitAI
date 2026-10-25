// FRONT T2 factory turrets (owner, 2026-10-25; Front::T2FactoryNanos). Before this, FRONT ordered no
// construction turret for a T2 bot lab or vehicle plant until it stood, and then only slowly: the native
// assist when income covered one, the vehicle plant's build chain's 4 (the bot lab's chain has none),
// Front_TryBuildNano with 1000 metal banked, and a turret cap of one per 150 energy income for the team.
// Now, from the moment a T2 lab of ours is framed, a FRONT T1 constructor asking for work within
// Front::T2FactoryNanoReach orders its next turret until Front::T2FactoryNanos stand, are framed or are
// ordered there. Turrets of every source count, each attributed to its nearest factory, so a T1 lab's
// turrets next door are not taken for the T2 lab's. At most Front::T2FactoryNanoParallel of our orders
// are open at once; past that an asker helps a turret frame at the lab (the native repair task is one
// per frame, shared). Only constructors already asking for work get one: nothing is reassigned,
// re-issued or cancelled. An order that dies unbuilt holds that lab for FailHoldSeconds times the
// failures in a row (to 120 s), so a lab with no site does not churn orders. Front_IncomeNanoLimits
// raises the turret cap by the turrets still to be framed (Cap), so the energy cap neither refuses an
// order nor makes one unbuildable halfway.
// Cost: one owned-unit scan every Front::T2FactoryNanoScanSeconds while a lab is short (then nanos x
// factories, both small), every RecheckSeconds once all are complete; Work and Cap read the cache.
// Log [FRONT][LabNano].
namespace FrontFactoryNanos {
    const int RecheckSeconds = 30;
    const int FailHoldSeconds = 30;
    const int OrderTimeoutSeconds = 300;
    const int HelpTimeoutSeconds = 60;

    bool On() { return Global::RoleSettings::Front::T2FactoryNanos > 0 && Global::AISettings::Role == AiRole::FRONT; }

    // Our T2 bot labs and vehicle plants (frames and standing) as of the last scan, by id (resolved
    // with ai.GetTeamUnit when used: a handle kept across frames may outlive its unit), with the turrets
    // standing and framed nearest each
    array<int> labIds;
    array<AIFloat3> labPos;
    array<int> standing;
    array<int> framed;
    array<int> holdUntil;            // per lab id below: no new order before this frame
    array<int> holdLab;
    array<int> fails;
    // Our turret orders not yet removed, and the lab each is for
    array<IUnitTask@> orders;
    array<int> orderLab;
    int missing = 0;                 // turrets still to be framed over all labs (Cap)
    int lastScan = -100000;
    int lastLabCount = -1;
    int lastLog = -100000;
    array<CCircuitDef@> labDefs;
    CCircuitDef@ nanoDef = null;
    array<CCircuitUnit@> scanNanos;  // reused by Scan

    void Reset() {
        labIds.resize(0); labPos.resize(0); standing.resize(0); framed.resize(0);
        holdUntil.resize(0); holdLab.resize(0); fails.resize(0);
        orders.resize(0); orderLab.resize(0);
        missing = 0; lastScan = -100000; lastLabCount = -1;
        labDefs.resize(0); @nanoDef = null;
    }

    void Defs() {
        if (nanoDef !is null) return;
        @nanoDef = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
        array<string> names = UnitHelpers::GetAllT2BotLabs();
        array<string> veh = UnitHelpers::GetAllT2VehicleLabs();
        for (uint i = 0; i < veh.length(); ++i) names.insertLast(veh[i]);
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d !is null) labDefs.insertLast(d);
        }
    }

    int LabCount() {
        int n = 0;
        for (uint i = 0; i < labDefs.length(); ++i) n += labDefs[i].count;
        return n;
    }

    int Ours(int labId) {
        int n = 0;
        for (uint i = 0; i < orders.length(); ++i)
            if (orderLab[i] == labId && orders[i] !is null && !orders[i].IsDead()) ++n;
        return n;
    }
    int Live() {
        int n = 0;
        for (uint i = 0; i < orders.length(); ++i) if (orders[i] !is null && !orders[i].IsDead()) ++n;
        return n;
    }
    // Turrets standing, framed or ordered by us at lab i (an order of ours that has framed is one of the frames)
    int Committed(uint i) { return standing[i] + AiMax(framed[i], Ours(labIds[i])); }

    int HoldIndex(int labId) {
        for (uint i = 0; i < holdLab.length(); ++i) if (holdLab[i] == labId) return int(i);
        holdLab.insertLast(labId); holdUntil.insertLast(-1); fails.insertLast(0);
        return int(holdLab.length()) - 1;
    }

    void Scan() {
        lastScan = ai.frame;
        labIds.resize(0); labPos.resize(0); standing.resize(0); framed.resize(0); scanNanos.resize(0);
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef is null) continue;
            if (u.circuitDef is nanoDef) { scanNanos.insertLast(u); continue; }
            for (uint d = 0; d < labDefs.length(); ++d) {
                if (u.circuitDef !is labDefs[d]) continue;
                labIds.insertLast(u.id); labPos.insertLast(u.GetPos(ai.frame)); standing.insertLast(0); framed.insertLast(0);
                break;
            }
        }
        // each turret goes to its nearest factory within reach: our T2 labs or any standing factory
        const float r = Global::RoleSettings::Front::T2FactoryNanoRadius;
        for (uint n = 0; n < scanNanos.length(); ++n) {
            const AIFloat3 p = scanNanos[n].GetPos(ai.frame);
            int best = -1;
            float bestSq = r * r;
            for (uint i = 0; i < labIds.length(); ++i) {
                const float sq = MapHelpers::SqDist(p, labPos[i]);
                if (sq <= bestSq) { bestSq = sq; best = int(i); }
            }
            if (best < 0) continue;
            bool other = false;   // a T1 (or other) factory nearer than that lab
            for (uint f = 0; f < Factory::factoryList.length() && !other; ++f) {
                CCircuitUnit@ fac = Factory::factoryList[f];
                if (fac is null || labIds.find(fac.id) >= 0) continue;
                other = MapHelpers::SqDist(p, fac.GetPos(ai.frame)) < bestSq;
            }
            if (other) continue;
            if (scanNanos[n].GetBuildProgress() < 1.0f) framed[best]++; else standing[best]++;
        }
        for (int i = int(orders.length()) - 1; i >= 0; --i)
            if (orders[i] is null || orders[i].IsDead()) { orders.removeAt(i); orderLab.removeAt(i); }
        const int want = Global::RoleSettings::Front::T2FactoryNanos;
        missing = 0;
        for (uint i = 0; i < labIds.length(); ++i) missing += AiMax(0, want - standing[i] - framed[i]);
        lastLabCount = LabCount();
    }

    void Refresh() {
        if (!On()) return;
        Defs();
        if (nanoDef is null) return;
        const bool open = missing > 0 || LabCount() != lastLabCount;
        const int every = (open ? Global::RoleSettings::Front::T2FactoryNanoScanSeconds : RecheckSeconds) * SECOND;
        if (ai.frame - lastScan >= every) Scan();
    }

    // Front_IncomeNanoLimits: the turret cap, raised by the turrets the T2 labs still need
    int Cap(int energyCap) {
        Refresh();
        if (!On() || nanoDef is null || missing <= 0) return energyCap;
        return AiMax(energyCap, nanoDef.count + missing);
    }

    // Front_BuilderAiTaskRemoved: an order of ours that died unbuilt holds its lab a while
    void TaskRemoved(IUnitTask@ task, bool done) {
        for (uint i = 0; i < orders.length(); ++i) {
            if (orders[i] !is task) continue;
            const int h = HoldIndex(orderLab[i]);
            if (done) fails[h] = 0;
            else {
                fails[h] = AiMin(4, fails[h] + 1);
                holdUntil[h] = ai.frame + FailHoldSeconds * fails[h] * SECOND;
                GenericHelpers::LogUtil("[FRONT][LabNano] turret order for lab " + orderLab[i] + " ended unbuilt ("
                    + fails[h] + " in a row); next in " + (FailHoldSeconds * fails[h]) + " s", 1);
            }
            orders.removeAt(i); orderLab.removeAt(i);
            return;
        }
    }

    IUnitTask@ Work(CCircuitUnit@ u) {
        if (!On() || u is null || u.circuitDef is null || FrontRecovery::Active()) return null;
        if (UnitHelpers::IsCommander(u.circuitDef) || UnitHelpers::GetConstructorTier(u.circuitDef) != 1) return null;
        Refresh();
        if (nanoDef is null || missing <= 0 || !u.circuitDef.CanBuild(nanoDef)) return null;
        const int want = Global::RoleSettings::Front::T2FactoryNanos;
        const float reach = Global::RoleSettings::Front::T2FactoryNanoReach;
        const AIFloat3 wp = u.GetPos(ai.frame);
        // the lab within reach furthest from its complement (the first framed on a tie)
        int pick = -1, need = 0;
        for (uint i = 0; i < labIds.length(); ++i) {
            const int n = want - Committed(i);
            if (n <= need || MapHelpers::SqDist(wp, labPos[i]) > reach * reach) continue;
            CCircuitUnit@ lab = ai.GetTeamUnit(labIds[i]);
            if (lab is null || lab.GetBuildProgress() < Global::RoleSettings::Front::T2FactoryNanoStartProgress) continue;
            pick = int(i); need = n;
        }
        if (pick < 0) return null;
        CCircuitUnit@ lab = ai.GetTeamUnit(labIds[pick]);
        const AIFloat3 at = labPos[pick];
        const int h = HoldIndex(lab.id);
        if (Live() >= Global::RoleSettings::Front::T2FactoryNanoParallel || ai.frame < holdUntil[h]) {
            // no new order: help a turret frame at this lab, if one is going up
            CCircuitUnit@ frame = aiBuilderMgr.FindUnfinishedNear(at, Global::RoleSettings::Front::T2FactoryNanoRadius, nanoDef);
            return frame is null ? null : aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, HelpTimeoutSeconds * SECOND));
        }
        // the energy cap is raised by Cap at the next economy update; until then by one for this order
        if (nanoDef.maxThisUnit >= 0 && nanoDef.count >= nanoDef.maxThisUnit) nanoDef.maxThisUnit = nanoDef.count + 1;
        if (!nanoDef.IsAvailable(ai.frame)) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, Task::Priority::HIGH, nanoDef, at,
            SQUARE_SIZE * 24, true, OrderTimeoutSeconds * SECOND));
        if (t is null) {
            fails[h] = AiMin(4, fails[h] + 1);
            holdUntil[h] = ai.frame + FailHoldSeconds * fails[h] * SECOND;
            if (ai.frame - lastLog >= 30 * SECOND) {
                lastLog = ai.frame;
                GenericHelpers::LogUtil("[FRONT][LabNano] no turret site at " + lab.circuitDef.GetName() + " " + lab.id
                    + "; next in " + (FailHoldSeconds * fails[h]) + " s", 1);
            }
            return null;
        }
        orders.insertLast(t); orderLab.insertLast(lab.id);
        Builder::MarkNanoEnqueued();
        Factory::_SetNanoCount(lab, Factory::_GetNanoCount(lab) + 1);   // Front_TryBuildNano's per-factory count
        GenericHelpers::LogUtil("[FRONT][LabNano] turret " + (Committed(pick)) + "/" + want + " for " + lab.circuitDef.GetName() + " " + lab.id
            + " (" + (lab.GetBuildProgress() < 1.0f ? "frame " + int(lab.GetBuildProgress() * 100.0f) + "%" : "standing")
            + ", " + standing[pick] + " standing, " + framed[pick] + " framed, " + Live() + " ordered) by "
            + u.circuitDef.GetName() + " " + u.id + " | M +" + int(Economy::GetMinMetalIncomeLast10s()) + " bank " + int(aiEconomyMgr.metal.current), 1);
        return t;
    }
}
