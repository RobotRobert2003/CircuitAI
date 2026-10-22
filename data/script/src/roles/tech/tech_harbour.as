#include "../../helpers/construction/sea_constructor_helpers.as"
#include "../../systems/construction/layout.as"
/******************************************************************************

TECH HARBOUR (D-121)

The owner's plan for a TECH that starts on an island (Tundra Continents): the
land phase is TECH's usual one (a bot lab, the advanced lab, mex upgrades, a
fusion, advanced fusions), packed onto the little flat ground there is (D-120,
D-121). Once HarbourAfterAdvancedFusions advanced fusions stand the economy
moves to the water beside the island:

  1. a land constructor builds a hover plant on the island (played: a T1
     shipyard needs water 30 deep, further out than a land constructor's
     reach, and every site was refused);
  2. its hover constructors float out and build the advanced shipyard first
     (owner: T2 sea units are the priority after the second advanced fusion),
     then floating turrets at the yards, tidals, and floating converters while
     energy floats;
  3. the advanced shipyard's construction subs grow the sea economy: a naval
     fusion while energy runs short, floating advanced converters (the land
     one's twin) while it floats;
  4. the advanced yard pumps sea units: its construction subs, then cruisers,
     missile ships and AA ships (a T1 yard, if one exists, its ships then
     destroyers).

Before the harbour the commander puts floating converters on the water while
energy floats, so the island's flat ground stays for the labs and fusions.

Land constructors keep their usual work on the island (owner: "they will be
isolated"); the land labs stop making combat units (they cannot leave). The
sea combat gate: harbour sea units are built whatever the income (owner:
"pumping out sea units"); INV-010 exempts them.

Only on a start the map file flags land-locked (Global::Map::LandLocked): land
maps never enter any of this.

******************************************************************************/
namespace TechHarbour {

    bool activeLatched = false;
    int activeFrame = -1;          // the frame the harbour began (INV-051)
    bool unlockedCaps = false;

    bool Enabled()
    {
        return Global::RoleSettings::Tech::HarbourEnabled && Global::Map::LandLocked;
    }

    CCircuitDef@ Def(const string &in name) { return (name.length() == 0) ? null : ai.GetCircuitDef(name); }
    string Side() { return Global::AISettings::Side; }
    int Queued(CCircuitDef@ d, Task::BuildType type) { return (d is null) ? 0 : aiBuilderMgr.GetQueuedBuildCount(int(type), d); }

    // The harbour begins once HarbourAfterAdvancedFusions advanced fusions stand (latched)
    bool Active()
    {
        if (activeLatched) return true;
        if (!Enabled()) return false;
        CCircuitDef@ af = Def(UnitHelpers::GetAdvFusionNameForSide(Side()));
        const int afus = (af is null) ? 0 : af.count;
        // the owner's trigger: the second advanced fusion. The safeguard: an island
        // whose flat ground runs out first (played: Tundra's north island, no site
        // for the fusion within reach of the advanced lab at 20 minutes) starts the
        // harbour HarbourLatestSeconds in, once the advanced lab stands
        const bool byFusions = afus >= Global::RoleSettings::Tech::HarbourAfterAdvancedFusions;
        const bool byTime = ai.frame >= Global::RoleSettings::Tech::HarbourLatestSeconds * SECOND && TechBuild::WasIntoT2();   // an advanced lab has stood (played: raided away at 19 minutes)
        if (!byFusions && !byTime) return false;
        activeLatched = true;
        activeFrame = ai.frame;
        GenericHelpers::LogUtil("[TECH][Harbour] " + (byFusions ? (afus + " advanced fusions stand") : ("" + int(ai.frame / (60 * SECOND)) + " minutes in with " + afus + " advanced fusion(s): the island's ground is spent"))
            + ": the economy moves to the water, the shipyards come next (D-121)", 1);
        UnlockCaps();
        return true;
    }

    // Role and map limits may hold these at 0 on a TECH start: the harbour's own units are opened
    void Open(const string &in name, int cap)
    {
        CCircuitDef@ d = Def(name);
        if (d !is null && d.maxThisUnit < cap) d.maxThisUnit = cap;
    }
    // TECH re-applies the merged map and role limits every economy update, which
    // closed the cruisers and AA ships again (played: only missile ships came
    // out): Tech_UpdateEconomy calls this after, once the harbour runs
    void ReapplyCaps() { if (activeLatched) { unlockedCaps = false; UnlockCaps(); } }
    void UnlockCaps()
    {
        if (unlockedCaps) return;
        unlockedCaps = true;
        const string side = Side();
        Open(UnitHelpers::GetT1ShipyardForSide(side), 1);
        Open(UnitHelpers::GetT1HoverPlantForSide(side), 1);
        Open(UnitHelpers::GetT1HoverConstructor(side), Global::RoleSettings::Tech::HarbourHoverConstructors);
        Open(UnitHelpers::GetT2ShipyardForSide(side), Global::RoleSettings::Tech::HarbourMaxT2Shipyards);
        array<string> t1c = UnitHelpers::GetAllT1SeaConstructors();
        for (uint i = 0; i < t1c.length(); ++i) Open(t1c[i], Global::RoleSettings::Tech::HarbourT1SeaConstructors);
        array<string> t2c = UnitHelpers::GetAllT2SeaConstructors();
        for (uint i = 0; i < t2c.length(); ++i) Open(t2c[i], Global::RoleSettings::Tech::HarbourT2SeaConstructors);
        Open(UnitHelpers::GetT1NavalNanoNameForSide(side), 200);
        Open(UnitHelpers::GetTidalNameForSide(side), 200);
        Open(UnitHelpers::GetNavalEnergyConverterNameForSide(side), 200);
        Open(UnitHelpers::GetAdvNavalEnergyConverterNameForSide(side), 200);
        Open(UnitHelpers::GetNavalFusionNameForSide(side), 200);
        array<string> units = CombatT1(side);
        for (uint i = 0; i < units.length(); ++i) Open(units[i], 500);
        units = CombatT2(side);
        for (uint i = 0; i < units.length(); ++i) Open(units[i], 500);
    }

    array<string> CombatT1(const string &in side)
    {
        array<string> a = { UnitHelpers::GetNavalDestroyerNameForSide(side) };
        return a;
    }
    // the advanced yard's cycle: cruisers, a missile ship, an AA ship
    array<string> CombatT2(const string &in side)
    {
        array<string> a = { UnitHelpers::GetNavalT2DestroyerNameForSide(side), UnitHelpers::GetNavalT2DestroyerNameForSide(side),
            UnitHelpers::GetNavalMissileShipNameForSide(side), UnitHelpers::GetNavalT2DestroyerNameForSide(side),
            UnitHelpers::GetNavalAAShipNameForSide(side) };
        return a;
    }

    // Where the harbour gathers: the advanced yard, else the T1 yard, else the land labs
    AIFloat3 Anchor()
    {
        if (Factory::primaryT2Shipyard !is null) return Factory::primaryT2Shipyard.GetPos(ai.frame);
        if (Factory::primaryT1Shipyard !is null) return Factory::primaryT1Shipyard.GetPos(ai.frame);
        if (Factory::primaryT1HoverPlant !is null) return Factory::primaryT1HoverPlant.GetPos(ai.frame);
        return Layout::CrampedAnchor(null);
    }

    int logFrame = -100000;
    int yardTry = -100000;   // the advanced shipyard's site search, at most every 10 s (a ring of ~1300 points)
    void Say(const string &in what)
    {
        GenericHelpers::LogUtil("[TECH][Harbour] " + what + " (D-121)", 1);
    }

    // Separate, persistent support groups for each harbour factory family.
    // Indexed native lookups avoid scanning unrelated economy reservations.
    IUnitTask@ SupportTask(CCircuitUnit@ builder, const string &in key, CCircuitDef@ turret)
    {
        if (turret is null || !builder.circuitDef.CanBuild(turret) || Layout::TurretsCapped()) return null;
        const int group = aiTerrainMgr.GetLayoutInt(key + ".support_group", 0);
        const int slot = group <= 0 ? -1 : aiTerrainMgr.NextSlotAny(group, builder.GetPos(ai.frame));
        if (slot < 0) return null;
        const AIFloat3 position = aiTerrainMgr.GetReservationPos(slot);
        if (!aiTerrainMgr.CanReachAt(builder, position, builder.circuitDef.GetBuildDistance())) return null;
        IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, Task::Priority::HIGH,
            turret, position, 0.0f, true, 120 * SECOND));
        if (task is null) return null;
        if (!AiPinReservation(task, slot)) { aiBuilderMgr.AbortTask(task); return null; }
        return task;
    }

    void ReleaseUnusedSupport(const string &in key)
    {
        const int group = aiTerrainMgr.GetLayoutInt(key + ".support_group", 0);
        if (group <= 0) return;
        const int zone = aiTerrainMgr.GetGroupZone(group);
        aiTerrainMgr.ReleaseGroup(group);
        if (zone > 0) aiTerrainMgr.ReleaseZone(zone);
        aiTerrainMgr.SetLayoutInt(key + ".support_group", 0);
    }

    // ---------------------------------------------------------------- land constructors

    // A land constructor or the commander: the hover plant, once, on the island
    // (its hover constructors reach the deep water a land constructor cannot)
    IUnitTask@ LandTask(CCircuitUnit@ u)
    {
        if (!Active() || u is null) return null;
        CCircuitDef@ hp = Def(UnitHelpers::GetT1HoverPlantForSide(Side()));
        if (hp is null || !u.circuitDef.CanBuild(hp)) return null;
        CCircuitDef@ turret = Def(UnitHelpers::GetT1NanoNameForSide(Side()));
        if (hp.count > 0) {
            IUnitTask@ current = TechBuild::KeepCurrent(u);
            if (current !is null) return current;
            return SupportTask(u, "tech.harbour.hover", turret);
        }
        if (Queued(hp, Task::BuildType::FACTORY) > 0) return null;
        const int id = Layout::CrampedLabSite(hp, Layout::CrampedAnchor(u), Global::RoleSettings::Tech::CrampedPlaceRadius,
            u, SQUARE_SIZE * 2, true, turret, "tech.harbour.hover");
        if (id < 0) {
            if (ai.frame - logFrame > 60 * SECOND) { logFrame = ai.frame; Say("no reachable footprint for the hover plant near the labs"); }
            return null;
        }
        const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, hp, p, null, 0.0f, false, true, 600 * SECOND));
        if (t is null) { aiTerrainMgr.ReleaseReservation(id); ReleaseUnusedSupport("tech.harbour.hover"); return null; }
        if (!AiPinReservation(t, id)) { aiBuilderMgr.AbortTask(t); ReleaseUnusedSupport("tech.harbour.hover"); return null; }
        Say(u.circuitDef.GetName() + " " + u.id + " orders the hover plant at (" + int(p.x) + ", " + int(p.z) + ")");
        return t;
    }

    // Before the harbour: the commander puts floating converters on the water while
    // energy floats (played: the island's flat ground near the builders was full,
    // T1 converters found no site, metal stayed at +13 and the advanced lab's +18
    // gate never opened). The land stays for the labs and the fusions
    IUnitTask@ CommanderFloat(CCircuitUnit@ u)
    {
        if (!Enabled() || u is null || !UnitHelpers::IsCommander(u.circuitDef) || !aiEconomyMgr.isEnergyFull) return null;
        if (aiEconomyMgr.energy.income < Global::RoleSettings::Tech::HarbourCommanderMinEnergy) return null;   // the start bank is full, not floating
        CCircuitDef@ fmkr = Def(UnitHelpers::GetNavalEnergyConverterNameForSide(Side()));
        if (fmkr is null || !u.circuitDef.CanBuild(fmkr) || Queued(fmkr, Task::BuildType::CONVERT) > 0) return null;
        if (fmkr.count >= Global::RoleSettings::Tech::HarbourCommanderConverters) return null;
        IUnitTask@ t = Builder::EnqueueT1NavalEnergyConverter(Side(), u.GetPos(ai.frame), Global::RoleSettings::Tech::HarbourCommanderReach, 60 * SECOND);
        if (t !is null && ai.frame - logFrame > 60 * SECOND) { logFrame = ai.frame; Say("energy floats: the commander puts converters on the water (" + fmkr.count + " stand)"); }
        return t;
    }

    // ---------------------------------------------------------------- construction ships and subs

    IUnitTask@ SeaTask(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return null;
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        const float ei = aiEconomyMgr.energy.income;
        const bool energyFull = aiEconomyMgr.isEnergyFull;
        const bool energyLow = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Tech::HarbourEnergyLowShare;
        const AIFloat3 at = Anchor();
        const float r = Global::RoleSettings::Tech::HarbourRadius;
        const bool t2 = SeaConstructor::IsT2(u.circuitDef);

        // a construction it holds is kept (played: a hover constructor ordered the
        // advanced shipyard, native re-asked before the frame stood, got a tidal
        // and left the yard; the yard was never built on either island). D-050's
        // rule for land builders, the same way
        {
            IUnitTask@ keep = TechBuild::KeepCurrent(u);
            if (keep !is null) return keep;
        }

        // 1. the advanced shipyard (owner: the priority after the second advanced fusion)
        CCircuitDef@ ayard = Def(UnitHelpers::GetT2ShipyardForSide(side));
        if (ayard !is null && u.circuitDef.CanBuild(ayard)
            && ayard.count + Queued(ayard, Task::BuildType::FACTORY) < Global::RoleSettings::Tech::HarbourMaxT2Shipyards) {
            // the site is picked here (played: native's search started from the
            // island's middle and found no water 30 deep within its radius)
            const int id = (ai.frame - yardTry >= 10 * SECOND) ? Layout::CrampedLabSite(ayard, Anchor(),
                Global::RoleSettings::Tech::HarbourYardSearch, u, 64.0f, true,
                Def(UnitHelpers::GetT1NavalNanoNameForSide(side)), "tech.harbour.yard") : -2;
            if (id != -2) yardTry = ai.frame;
            if (id >= 0) {
                const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
                IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, ayard, p, null, 0.0f, false, true, 600 * SECOND));
                if (t is null) { aiTerrainMgr.ReleaseReservation(id); ReleaseUnusedSupport("tech.harbour.yard"); }
                else {
                    if (!AiPinReservation(t, id)) { aiBuilderMgr.AbortTask(t); ReleaseUnusedSupport("tech.harbour.yard"); return null; }
                    Builder::MarkT2FactoryEnqueued();
                    Say(u.circuitDef.GetName() + " " + u.id + " orders the advanced shipyard at (" + int(p.x) + ", " + int(p.z) + ")");
                    return t;
                }
            } else if (id == -1 && ai.frame - logFrame > 60 * SECOND) { logFrame = ai.frame; Say("no site for the advanced shipyard within " + int(Global::RoleSettings::Tech::HarbourYardSearch) + " of the harbour"); }
        }
        // a yard going up: everyone helps it
        {
            CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedNear(at, r, ayard);
            if (f is null) @f = aiBuilderMgr.FindUnfinishedNear(at, r, Def(UnitHelpers::GetT1ShipyardForSide(side)));
            if (f !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, f, 60 * SECOND));
        }
        // 2. floating turrets at the yards
        CCircuitDef@ fnano = Def(UnitHelpers::GetT1NavalNanoNameForSide(side));
        IUnitTask@ supportTask = SupportTask(u, "tech.harbour.yard", fnano);
        if (supportTask !is null) return supportTask;
        if (fnano !is null && u.circuitDef.CanBuild(fnano) && !Layout::TurretsCapped()
            && fnano.count + Queued(fnano, Task::BuildType::NANO) < Global::RoleSettings::Tech::HarbourTurrets) {
            IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, Task::Priority::HIGH, fnano, at, Global::RoleSettings::Tech::HarbourTurretRadius, true, 120 * SECOND));
            if (t !is null) return t;
        }
        if (t2) {
            // 3. T2: floating advanced converters while energy is over
            // HarbourConverterEnergyShare of storage, else a naval fusion. Played:
            // over 30%: 24 converters on +1600 energy and no fusion (metal +84);
            // only when full: 1 fusion and 2 converters (metal +60)
            const bool energyHigh = aiEconomyMgr.energy.current > aiEconomyMgr.energy.storage * Global::RoleSettings::Tech::HarbourConverterEnergyShare;
            if (energyFull || energyHigh) {
                IUnitTask@ t = Builder::EnqueueAdvNavalEnergyConverter(side, at, r, 60 * SECOND);
                if (t !is null) return t;
            }
            CCircuitDef@ nfus = Def(UnitHelpers::GetNavalFusionNameForSide(side));
            if (nfus !is null && Queued(nfus, Task::BuildType::ENERGY) == 0 && aiBuilderMgr.GetUnfinishedCount(nfus) == 0) {
                IUnitTask@ t = Builder::EnqueueNavalFUS(side, at, r, 300 * SECOND);
                if (t !is null) return t;
            }
        } else {
            // 3. T1: floating converters while energy floats, else tidals
            if (energyFull) {
                IUnitTask@ t = Builder::EnqueueT1NavalEnergyConverter(side, at, r, 30 * SECOND);
                if (t !is null) return t;
            }
            if (ei < Global::RoleSettings::Tech::HarbourTidalUntilEnergy || energyLow) {
                IUnitTask@ t = Builder::EnqueueT1Tidal(side, at, r, 30 * SECOND);
                if (t !is null) return t;
            }
        }
        // 4. help what goes up at the harbour
        {
            CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedNear(at, r, null);
            if (f !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL, f, 30 * SECOND));
        }
        return null;
    }

    // ---------------------------------------------------------------- the yards

    int t2Cycle = 0;
    string SeaCon(const string &in side, bool t2)
    {
        array<string> a = t2 ? UnitHelpers::GetAllT2SeaConstructors() : UnitHelpers::GetAllT1SeaConstructors();
        const uint i = (side == "armada") ? 0 : ((side == "cortex") ? 1 : 2);
        return (i < a.length()) ? a[i] : "";
    }
    dictionary refusedLogged;
    IUnitTask@ Recruit(CCircuitUnit@ yard, const string &in name, Task::RecruitType type, Task::Priority prio)
    {
        CCircuitDef@ d = Def(name);
        if (d is null || !d.IsAvailable(ai.frame) || !yard.circuitDef.CanBuild(d)) {
            if (!refusedLogged.exists(name)) {   // once a unit type: why the yard cannot make it
                refusedLogged.set(name, true);
                Say(yard.circuitDef.GetName() + " cannot make " + name + ": " + (d is null ? "no def" : (!yard.circuitDef.CanBuild(d) ? "not in its build list"
                    : ("unavailable (count " + d.count + ", cap " + d.maxThisUnit + ")"))));
            }
            return null;
        }
        return aiFactoryMgr.Enqueue(TaskS::Recruit(type, prio, d, yard.GetPos(ai.frame), 64.f));
    }

    IUnitTask@ YardTask(CCircuitUnit@ yard)
    {
        if (!Active() || yard is null || yard.circuitDef is null) return null;
        const string name = yard.circuitDef.GetName();
        const string side = UnitHelpers::GetSideForUnitName(name);
        if (UnitHelpers::IsT1HoverPlant(name)) {
            CCircuitDef@ hc = Def(UnitHelpers::GetT1HoverConstructor(side));
            if (hc !is null && hc.count < Global::RoleSettings::Tech::HarbourHoverConstructors) {
                IUnitTask@ t = Recruit(yard, hc.GetName(), Task::RecruitType::BUILDPOWER, Task::Priority::HIGH);
                if (t !is null) return t;
            }
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 10 * SECOND));
        }
        if (UnitHelpers::IsT1Shipyard(name)) {
            if (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1SeaConstructors()) < Global::RoleSettings::Tech::HarbourT1SeaConstructors) {
                IUnitTask@ t = Recruit(yard, SeaCon(side, false), Task::RecruitType::BUILDPOWER, Task::Priority::HIGH);
                if (t !is null) return t;
            }
            // destroyers only once the advanced yard stands: until then the metal goes to it
            if (Factory::primaryT2Shipyard !is null) {
                IUnitTask@ t = Recruit(yard, UnitHelpers::GetNavalDestroyerNameForSide(side), Task::RecruitType::FIREPOWER, Task::Priority::NORMAL);
                if (t !is null) return t;
            }
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
        }
        if (UnitHelpers::IsT2Shipyard(name)) {
            if (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2SeaConstructors()) < Global::RoleSettings::Tech::HarbourT2SeaConstructors) {
                IUnitTask@ t = Recruit(yard, SeaCon(side, true), Task::RecruitType::BUILDPOWER, Task::Priority::HIGH);
                if (t !is null) return t;
            }
            array<string> cycle = CombatT2(side);
            for (uint k = 0; k < cycle.length(); ++k) {
                const string unit = cycle[(t2Cycle + k) % cycle.length()];
                IUnitTask@ t = Recruit(yard, unit, Task::RecruitType::FIREPOWER, Task::Priority::HIGH);
                if (t !is null) { t2Cycle = (t2Cycle + k + 1) % cycle.length(); return t; }
            }
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
        }
        return null;
    }

    // A land lab once the harbour runs: constructors as usual, never combat (it cannot leave the island)
    bool HoldsLandCombat(const string &in labName)
    {
        return Active() && (UnitHelpers::IsT1BotLab(labName) || UnitHelpers::IsT2BotLab(labName)
            || UnitHelpers::IsT1VehicleLab(labName) || UnitHelpers::IsT2VehicleLab(labName));
    }

    bool IsHoverConstructor(const CCircuitDef@ d)
    {
        return d !is null && Enabled() && d.GetName() == UnitHelpers::GetT1HoverConstructor(UnitHelpers::GetSideForUnitName(d.GetName()));
    }

    // The fleet: every harbour combat ship runs the advanced yard's route: its
    // lane through the front to past the enemy's base (Spam's route task, D-111).
    // Played: 67 ships sat at home with nothing seen to attack
    IUnitTask@ FleetTask(CCircuitUnit@ u)
    {
        if (!IsHarbourUnit(u.circuitDef)) return null;
        CCircuitUnit@ yard = (Factory::primaryT2Shipyard !is null) ? Factory::primaryT2Shipyard : Factory::primaryT1Shipyard;
        if (yard is null) return null;
        CRouteTask@ route = Spam::RouteFor(yard);
        if (route is null) return null;
        return route;
    }

    // INV-010: harbour sea units are exempt from the combat gate
    bool IsHarbourUnit(const CCircuitDef@ d)
    {
        if (!Active() || d is null) return false;
        const string side = Side();
        array<string> a = CombatT1(side);
        array<string> b = CombatT2(side);
        const string n = d.GetName();
        return a.find(n) >= 0 || b.find(n) >= 0;
    }
}
