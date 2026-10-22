#include "air_operations.as"
#include "../../helpers/spatial/air_home.as"

// AIR's immediate reserve: shared tasks and target identities, no per-frame orders.
namespace AirBaseResponse {
    array<CRouteTask@> groups(4);
    array<int> targets(4, -1);
    array<AIFloat3> aims(4);
    dictionary members;
    dictionary waiting;
    CRouteTask@ reserve;
    AIFloat3 assembly;
    int waitingSince = -1;
    float groundCost = 0, aaCost = 0;
    int updated = -100000, lastSeen = -100000;
    bool contact = false;
    bool Active() { return AirEconomy::Active() && Global::RoleSettings::Air::BaseResponseEnabled; }
    bool Emergency() { return Active() && contact; }
    bool InBase(const AIFloat3 &in p) {
        // The outer radius of a frontline ally can cross into enemy territory.
        // Keep cliff/edge intrusions on our side without claiming enemy bases.
        if (!AirHome::Friendly(p)) return false;
        for (uint i = 0; i < WallHelpers::starts.length(); ++i)
            if (AirMath::BaseContact(MapHelpers::SqDist(p, WallHelpers::starts[i]), Global::RoleSettings::Air::BaseResponseRadius)) return true;
        return false;
    }
    bool Free(CCircuitUnit@ u) {
        if (u is null || u.GetBuildProgress() < 1.0f || !u.circuitDef.IsAbleToFly()
            || u.circuitDef.GetBuildSpeed() > 0 || Team::Ferry::IsFerryTransport(u.circuitDef)
            || u.id == Team::Ferry::buildingId || AirOperations::Committed(u.id)
            || u.GetRulesParam("carrier_host_unit_id", -1) >= 0) return false;
        IUnitTask@ task = u.task;
        if (task is null) return true;
        if (task.GetType() == int(Task::Type::PLAYER) || task.GetType() == int(Task::Type::RETREAT)
            || task.IsExternalControlled()) return false;
        IFighterTask@ fight = cast<IFighterTask>(task);
        if (fight !is null && fight.GetFightType() == int(Task::FightType::FERRY)) return false;
        CAirWaveTask@ wave = cast<CAirWaveTask>(task);
        return wave is null || wave.IsDead(); // offensive commitments are never recalled
    }
    int Kind(const CCircuitDef@ d) {
        // Pure fighters cannot damage a ground incursion. Leave them on the
        // interceptor wall and available for bomber-wave ownership (D-277).
        if (AirScreen::IsFighter(d)) return -1;
        if (!d.HasSurfToLand()) return -1;
        if (d.GetTargetMinCost() > 0) return 3; // JSON-opted fortress, separate from cheap gunships
        return AirWaves::IsWaveBomber(d) ? 1 : 0;
    }
    bool Heavy(const CCircuitDef@ d) {
        // Same authoritative gantry-exclusive roster as the offensive wave policy.
        return d !is null && AirOperations::groundHeavyDefs.find(d.GetName()) >= 0;
    }
    void Forget(int id) {
        const string key = "" + id;
        AirRaids::held.delete(key); AirRaids::joining.delete(key);
        AirWaves::heldBombers.delete(key); AirWaves::heldFighters.delete(key);
        AirProduction::home.delete(key); AirScreen::Removed(id);
    }
    IUnitTask@ TaskFor(CCircuitUnit@ u) {
        if (!Active() || !contact || !Free(u)) return null;
        const int kind = Kind(u.circuitDef);
        if (kind < 0 || groups[kind] is null || groups[kind].IsDead()) return null;
        // Let the existing interceptor controller answer simultaneous aircraft.
        if (kind == 2 && AirScreen::IntrusionCost() > 0) return null;
        if (kind == 0 && !members.exists("" + u.id)) {
            if (reserve is null || reserve.IsDead()) {
                // Bounded allied-start candidates; no unit-by-unit world scan.
                // Prefer the least exposed friendly assembly site, then home.
                assembly = Global::Map::StartPos;
                float risk = aiBattle.AirThreat(assembly);
                for (uint i = 0; i < WallHelpers::starts.length(); ++i) {
                    const AIFloat3 p = WallHelpers::starts[i];
                    if (!AirHome::Friendly(p)) continue;
                    const float candidate = aiBattle.AirThreat(p);
                    if (candidate < risk) { risk = candidate; assembly = p; }
                }
                @reserve = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                if (reserve is null) return null;
                reserve.SetAirControl(true); reserve.SetHoldPosition(true);
                reserve.SetTraversal(true, 96.0f, false);
                reserve.SetLanes(12, 96.0f, 1.0f);
                array<AIFloat3> route = {AirScreen::Clamp(assembly + AIFloat3(0,0,64)), AirScreen::Clamp(assembly)};
                reserve.SetRoute(route);
            }
            if (waitingSince < 0 && u.circuitDef.GetName() != "corbw") waitingSince = ai.frame;
            waiting.set("" + u.id, true);
            u.SetIdleMode(0); u.SetFireState(2); Forget(u.id);
            return reserve;
        }
        u.SetIdleMode(0); u.SetFireState(2);
        members.set("" + u.id, kind);
        Forget(u.id);
        return groups[kind];
    }
    void ClearGroup(int kind) {
        CRouteTask@ old = groups[kind];
        @groups[kind] = null; targets[kind] = -1;
        if (old !is null && !old.IsDead()) old.Abort();
    }
    void Reset() {
        contact = false;
        for (int i = 0; i < 4; ++i) ClearGroup(i);
        members.deleteAll(); updated = -100000; lastSeen = -100000;
        ClearReserve(); groundCost = 0; aaCost = 0;
    }
    void ClearReserve() {
        CRouteTask@ old = reserve; @reserve = null;
        waiting.deleteAll(); waitingSince = -1;
        if (old !is null && !old.IsDead()) old.Abort();
    }
    int Required(float aircraftCost) {
        return AirMath::DefenceWave(groundCost, aaCost, aircraftCost,
            Global::RoleSettings::Air::BaseResponseGroundRatio, Global::RoleSettings::Air::BaseResponseAaRatio,
            Global::RoleSettings::Air::BaseResponseMinWave, Global::RoleSettings::Air::BaseResponseMaxWave);
    }
    void ReleaseReserve() {
        array<string>@ keys = waiting.getKeys();
        array<string> assembled;
        float cost = 0;
        int damageUnits = 0, assembledDamage = 0;
        const float radius = AiMax(64.0f, Global::RoleSettings::Air::BaseResponseAssemblyRadius);
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(keys[i]));
            if (!Free(u) || reserve is null || u.task !is reserve) { waiting.delete(keys[i]); continue; }
            // EMP support joins the release but cannot satisfy its lethal
            // strength requirement. Otherwise a Shuriken-only cohort can
            // repeatedly stun a foothold without ever destroying it.
            const bool damage = u.circuitDef.GetName() != "corbw";
            if (damage) { cost += u.circuitDef.costM; ++damageUnits; }
            if (MapHelpers::SqDist(u.GetPos(ai.frame), assembly) <= radius*radius) {
                assembled.insertLast(keys[i]);
                if (damage) ++assembledDamage;
            }
        }
        if (waiting.isEmpty()) { waitingSince = -1; return; }
        if (!contact || groups[0] is null || groups[0].IsDead()) return;
        if (damageUnits == 0) { waitingSince = -1; return; }
        const int wanted = Required(cost / float(damageUnits));
        const int age = ai.frame - waitingSince;
        const int deadline = AiMax(1, Global::RoleSettings::Air::BaseResponseMaxWaitSeconds)*SECOND;
        if (!AirMath::DefenceRelease(damageUnits, assembledDamage, wanted, age, deadline)) return;
        // Full releases use assembled units. The deadline explicitly also
        // releases late arrivals: production/path stalls must not wait forever.
        @keys = age >= deadline ? waiting.getKeys() : @assembled;
        keys.sortAsc(); int joined = 0;
        const int limit = AiMax(wanted, Global::RoleSettings::Air::BaseResponseMaxWave);
        for (uint i = 0; i < keys.length() && joined < limit; ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(keys[i]));
            if (!Free(u)) continue;
            if (!aiMilitaryMgr.TransferUnit(u, groups[0])) continue;
            waiting.delete(keys[i]); members.set(keys[i], 0); ++joined;
        }
        if (joined == 0) Invariants::Violation("INV-165", "gunship cohort", "eligible defense release transferred no aircraft");
        else GenericHelpers::LogUtil("[AIR][BaseResponse] wave=" + joined + " wanted=" + wanted
            + " aaMetal=" + aaCost + " groundMetal=" + groundCost + " age=" + age/SECOND
                + " lethal=" + damageUnits + " reason=" + (age >= deadline ? "deadline" : "assembled"), 1);
        // A partial transfer/remainder keeps its oldest waiting deadline.
        if (waiting.isEmpty()) waitingSince = -1;
    }
    void Tick() {
        if (!Active() || ai.frame-updated < SECOND) return;
        updated = ai.frame;
        AirHome::Refresh(); AirOperations::InitHeavyRoster();
        array<int> selected(3, -1);
        array<float> scores(3, -1.0f);
        bool selectedGunshipPriority = false;
        bool sawGunshipPriority = false;
        const int contacts = aiBattle.GetGroundContactCount();
        for (int i = 0; i < contacts; ++i) {
            const AIFloat3 p = aiBattle.GetGroundContactPos(i);
            if (!InBase(p)) continue;
            const CCircuitDef@ d = ai.GetCircuitDef(aiBattle.GetGroundContactDefId(i));
            if (d is null) continue;
            const int id = aiBattle.GetGroundContactId(i);
            // Reuse the existing shared contact pass, not a per-aircraft enemy
            // query. No persistent cache: current observed definitions are read
            // once per response tick. O(C) selection, unchanged one-second cadence.
            const bool gunshipPriority = AirMath::DefensiveGunshipPriority(
                Global::RoleSettings::Air::BaseResponsePrioritizeAntiAir,
                d.HasSurfToAir(), d.IsRoleAny(Unit::Role::AA.mask), d.IsMobile(), d.costM,
                Global::RoleSettings::Air::BaseResponseLightStaticAntiAirMaximumMetal);
            sawGunshipPriority = sawGunshipPriority || gunshipPriority;
            const float score = (d.HasSurfToLand() || d.HasSurfToAir() ? 100000.0f : 0.0f)
                + (d.GetBuildSpeed() > 0 ? 50000.0f : 0.0f) + d.costM;
            for (int k = 0; k < 3; ++k) {
                if (!AirMath::DefensiveBomberTarget(k == 1, d.IsMobile(), Heavy(d))) continue;
                // Stable targets avoid churning orders as a formation moves.
                // Fortress guns must not be held on a cheap raider by the
                // ordinary gunship group's 25k retention bonus. Value/AA and a
                // proportional 15% hysteresis permit immediate heavy response.
                const float rank = k == 2
                    ? d.costM * (d.IsRoleAny(Unit::Role::AA.mask | Unit::Role::COMM.mask) ? 2.0f : 1.0f)
                        * (targets[3] == id ? 1.15f : 1.0f)
                    : score + (targets[k] == id ? 25000.0f : 0.0f);
                const bool prefer = k == 0
                    ? AirMath::PreferDefensiveGunshipTarget(gunshipPriority, rank, selectedGunshipPriority, scores[k])
                    : rank > scores[k];
                if (prefer) {
                    scores[k] = rank; selected[k] = i;
                    if (k == 0) selectedGunshipPriority = gunshipPriority;
                }
            }
        }
        if (sawGunshipPriority && !selectedGunshipPriority)
            Invariants::Violation("INV-192", "gunship-defense", "observed priority AA lost to a lower target tier");
        const bool previous = contact;
        contact = selected[0] >= 0;
        if (contact) lastSeen = ai.frame;
        if (contact != previous) GenericHelpers::LogUtil("[AIR][BaseResponse] contact=" + contact, 1);
        if (!contact && ai.frame-lastSeen >= AiMax(1, Global::RoleSettings::Air::BaseResponseSearchSeconds)*SECOND) {
            for (int k = 0; k < 4; ++k) ClearGroup(k);
            members.deleteAll(); ClearReserve(); return;
        }
        groundCost = 0; aaCost = 0;
        if (selected[0] >= 0) {
            const AIFloat3 incident = aiBattle.GetGroundContactPos(selected[0]);
            const float radius = AiMax(1.0f, Global::RoleSettings::Air::BaseResponseThreatRadius);
            // O(contacts), once per response tick, never O(aircraft*contacts).
            // AA just outside the incident still counts when its range covers it.
            for (int i = 0; i < contacts; ++i) {
                const CCircuitDef@ d = ai.GetCircuitDef(aiBattle.GetGroundContactDefId(i));
                if (d is null) continue;
                const float sq = MapHelpers::SqDist(incident, aiBattle.GetGroundContactPos(i));
                if (sq <= radius*radius) groundCost += d.costM;
                const float reach = AiMax(radius, d.GetMaxRange());
                if (d.HasSurfToAir() && sq <= reach*reach) aaCost += d.costM;
            }
            for (int i = 0; i < aiBattle.GetAirContactCount(); ++i)
                if (aiBattle.IsAirContactArmed(i) && MapHelpers::SqDist(incident, aiBattle.GetAirContactPos(i)) <= radius*radius)
                    aaCost += aiBattle.GetAirContactCost(i);
            // The shared naval snapshot excludes dry ground contacts, so
            // coastal AA can be added once without double-counting shore flak.
            const int naval = aiBattle.GetNavalForceCount();
            for (int i = 0; i < naval; ++i) {
                if ((aiBattle.GetNavalForceFlags(i) & 9) != 0) continue; // friendly or factory
                const CCircuitDef@ d = ai.GetCircuitDef(aiBattle.GetNavalForceDefId(i));
                if (d is null || !d.HasSurfToAir()) continue;
                const float reach = AiMax(radius, d.GetMaxRange());
                if (MapHelpers::SqDist(incident, aiBattle.GetNavalForcePos(i)) <= reach*reach) aaCost += d.costM;
            }
        }
        for (int k = 0; k < 4; ++k) {
            if (k == 2) { ClearGroup(k); continue; } // legacy ground-escort slot
            const int index = selected[k == 2 ? 0 : (k == 3 ? 2 : k)];
            const int next = index < 0 ? -1 : aiBattle.GetGroundContactId(index);
            if (index >= 0) aims[k] = aiBattle.GetGroundContactPos(index);
            if (k == 1 && contact && index < 0) { ClearGroup(k); continue; }
            if (groups[k] is null || groups[k].IsDead()) {
                if (index < 0) continue;
                @groups[k] = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                if (groups[k] is null) continue;
                groups[k].SetAirControl(true); groups[k].SetTraversal(true, 192.0f, true);
                if (k == 0) groups[k].SetLanes(12, 96.0f, 1.0f);
                groups[k].SetPatrol(true); // retry an empty queue without landing
                targets[k] = -2;
            }
            if (next != targets[k]) {
                // Two points preserve lateral spacing while searching after
                // contact loss. Visible targets use native direct attack;
                // the staging cohort prevents single-file reinforcements.
                const AIFloat3 near = AirScreen::Clamp(aims[k] + (Global::Map::StartPos-aims[k])*0.1f);
                array<AIFloat3> route = {near, AirScreen::Clamp(aims[k])};
                groups[k].SetAirTarget(k == 2 ? -1 : next); groups[k].SetRoute(route);
                targets[k] = next;
                GenericHelpers::LogUtil("[AIR][BaseResponse] group=" + k + " target=" + next, 1);
            }
        }
        array<string>@ enrolled = members.getKeys();
        for (uint i = 0; i < enrolled.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(enrolled[i])); int k = -1;
            if (!members.get(enrolled[i], k) || k < 0 || k >= 4 || u is null || u.task !is groups[k]) members.delete(enrolled[i]);
            else if (!Free(u)) Invariants::Violation("INV-140", enrolled[i], "protected aircraft acquired by base response");
            else if (Kind(u.circuitDef) != k) Invariants::Violation("INV-156", enrolled[i], "base defense target policy differs from aircraft group");
        }
        if (!contact) return;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        int joined = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (members.exists("" + ids[i]) || waiting.exists("" + ids[i]) || !Free(u)) continue;
            IUnitTask@ task = TaskFor(u);
            if (task is null) continue;
            if (aiMilitaryMgr.TransferUnit(u, task)) ++joined;
            else { members.delete("" + ids[i]); Invariants::Violation("INV-140", ""+ids[i], "base response transfer failed"); }
        }
        if (joined > 0) GenericHelpers::LogUtil("[AIR][BaseResponse] dispatched=" + joined + " total=" + members.getSize(), 1);
        ReleaseReserve();
    }
    const array<string> lethal = {"armkam", "armbrawl", "corape", "legmos", "legstronghold", "corshad"};
    int ProductionTarget() {
        CCircuitDef@ best = ai.GetCircuitDef(GunshipName(Global::AISettings::Side, AirEconomy::t2 > 0));
        return AiMax(Global::RoleSettings::Air::BaseResponseGunships, Required(best is null ? 250.0f : best.costM));
    }
    int Deficit() {
        int ready = 0, frames = 0, pending = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || lethal.find(u.circuitDef.GetName()) < 0) continue;
            if (u.GetBuildProgress() < 1.0f) ++frames;
            else if (Free(u)) ++ready;
        }
        for (uint i = 0; i < lethal.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(lethal[i]);
            if (d !is null) pending += aiFactoryMgr.GetPendingRecruitCount(d);
        }
        return AirMath::DefenceDeficit(ProductionTarget(), ready, frames, pending);
    }
    string GunshipName(const string &in side, bool advanced) {
        return side == "armada" ? (advanced ? "armbrawl" : "armkam")
            : side == "cortex" ? (advanced ? "corape" : "corshad") : (advanced ? "legstronghold" : "legmos");
    }
    IUnitTask@ Produce(CCircuitUnit@ plant) {
        if (!Emergency()) return null;
        const string side = UnitHelpers::GetSideForUnitName(plant.circuitDef.GetName());
        const bool advanced = UnitHelpers::IsT2AircraftPlant(plant.circuitDef.GetName());
        if (!advanced && !UnitHelpers::IsT1AircraftPlant(plant.circuitDef.GetName())) return null;
        // Never substitute an EMP-only army for damage. A small support group
        // follows damage production at Cortex T1 and assembles with the cohort.
        string name = GunshipName(side, advanced);
        const int missing = Deficit();
        const int damageProjected = ProductionTarget() - missing;
        if (!advanced && side == "cortex" && damageProjected > 0) {
            const int support = AiMin(Global::RoleSettings::Air::BaseResponseEmpSupport,
                1+damageProjected/3);
            IUnitTask@ supportTask = AirProduction::Recruit(plant, "corbw", support, "base.emp", Task::Priority::HIGH);
            if (supportTask !is null) return supportTask;
        }
        if (missing > 0) {
            CCircuitDef@ def = ai.GetCircuitDef(name);
            IUnitTask@ task = AirProduction::Recruit(plant, name, AirProduction::Projected(def)+1,
                "base.defence", Task::Priority::HIGH);
            if (task !is null) return task;
        }
        if (!advanced && side == "cortex")
            return AirProduction::Recruit(plant, "corbw", Global::RoleSettings::Air::BaseResponseEmpSupport,
                "base.emp", Task::Priority::HIGH);
        return null;
    }
}
