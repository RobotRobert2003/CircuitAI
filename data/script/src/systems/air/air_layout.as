#include "../../helpers/math/production_math.as"
#include "../../helpers/spatial/layout_helpers.as"
#include "../construction/lifecycle.as"

// AIR sites use native reservation/claim/frame ownership. No TECH controller calls.
#include "../../helpers/spatial/air_home.as"
#include "air_eco_layout.as"

namespace AirLayout {
    class Bay {
        string key;
        int cluster = -1;
        string defName;
        int slot = -1;
        int envelope = 0;
        bool started = false;
        int factoryId = -1;
        int facing = 0;
        AIFloat3 centre;
        array<int> nanos;
    }
    array<Bay@> bays;
    class WindCluster {
        bool started = false;
        string defName;
        AIFloat3 centre;
        int facing = 0;
        array<int> slots;
    }
    array<WindCluster@> windClusters;
    bool enabled = false;
    int searchAfter = 0;
    int facing = 0;
    dictionary placeRetry;
    dictionary originalFactoryCaps;

    void UnlockCampus()
    {
        const array<string> names = UnitHelpers::GetAllT2AircraftPlants();
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null) continue;
            if (!originalFactoryCaps.exists(names[i])) originalFactoryCaps.set(names[i], int(d.maxThisUnit));
            d.maxThisUnit = Global::RoleSettings::Air::MaxProductionBays > 0
                ? Global::RoleSettings::Air::MaxProductionBays : 2147483647;
        }
    }

    void SetOverlay(bool on) { WidgetLink::SetLayoutOverlay(on); }
    void Draw() { WidgetLink::LayoutTick(); }

    bool Inside(const AIFloat3 &in p, float margin)
    {
        return ProductionMath::Inside(p.x, p.z, float(AiTerrainWidth()), float(AiTerrainHeight()), margin);
    }

    AIFloat3 Offset(const AIFloat3 &in p, int f, float across, float along)
    {
        return LayoutHelpers::Offset(p, f, across, along);
    }
    string Key(int i) { return "air.bay." + i; }
    void Save(Bay@ b)
    {
        aiTerrainMgr.SetLayoutInt("air.supportRevision", aiTerrainMgr.GetLayoutInt("air.supportRevision", 0) + 1);
        aiTerrainMgr.SetLayoutInt(b.key + ".cluster", b.cluster);
        aiTerrainMgr.SetLayoutInt(b.key + ".slot", b.slot);
        aiTerrainMgr.SetLayoutInt(b.key + ".envelope", b.envelope);
        aiTerrainMgr.SetLayoutInt(b.key + ".started", b.started ? 1 : 0);
        aiTerrainMgr.SetLayoutInt(b.key + ".facing", b.facing);
        aiTerrainMgr.SetLayoutInt(b.key + ".tier", UnitHelpers::IsT2AircraftPlant(b.defName) ? 2 : 1);
        aiTerrainMgr.SetLayoutInt(b.key + ".x", int(b.centre.x));
        aiTerrainMgr.SetLayoutInt(b.key + ".z", int(b.centre.z));
        aiTerrainMgr.SetLayoutInt(b.key + ".n", int(b.nanos.length()));
        for (uint i = 0; i < b.nanos.length(); ++i) aiTerrainMgr.SetLayoutInt(b.key + ".nano." + i, b.nanos[i]);
        aiTerrainMgr.SetLayoutInt("air.bays", int(bays.length()));
    }
    void Init(const string &in side)
    {
        enabled = Global::RoleSettings::Air::ExperimentalBuild && aiTerrainMgr.SetLayoutEnabled(true);
        if (!enabled) return;
        UnlockCampus();
        AirEconomy::Reset(); AirProduction::Reset();
        AirBuild::AdoptExisting();
        aiBuilderMgr.experimentalBuild = true;
        aiBuilderMgr.experimentalAirDirect = true;
        if (aiTerrainMgr.GetLayoutInt("air.reclaimCaptured", 0) == 0) {
            aiTerrainMgr.SetLayoutInt("air.reclaimPrior", int(fpToIEEE(aiEconomyMgr.reclEnergyEff)));
            aiTerrainMgr.SetLayoutInt("air.nanoPrior", aiEconomyMgr.assistNanoEnabled ? 1 : 0);
            aiTerrainMgr.SetLayoutInt("air.reclaimCaptured", 1);
        }
        aiEconomyMgr.reclEnergyEff = 0.0f; // AIR's shared TECH threshold is the sole early-energy reclaim policy
        aiEconomyMgr.assistNanoEnabled = false; // one owner: native queued nanos cannot obstruct AIR slots
        bays.resize(0);
        windClusters.resize(0);
        placeRetry.deleteAll();
        facing = LayoutHelpers::FacingToward(Global::Map::StartPos, LayoutHelpers::TerrainCentre());
        AirEcoLayout::Init();
        const int count = aiTerrainMgr.GetLayoutInt("air.bays", 0);
        for (int i = 0; i < count; ++i) {
            Bay b;
            b.key = Key(i);
            b.cluster = aiTerrainMgr.GetLayoutInt(b.key + ".cluster", -1);
            b.slot = aiTerrainMgr.GetLayoutInt(b.key + ".slot", -1);
            b.envelope = aiTerrainMgr.GetLayoutInt(b.key + ".envelope", 0);
            b.started = aiTerrainMgr.GetLayoutInt(b.key + ".started", 0) != 0;
            b.facing = aiTerrainMgr.GetLayoutInt(b.key + ".facing", facing);
            b.defName = aiTerrainMgr.GetLayoutInt(b.key + ".tier", 1) == 2 ? UnitHelpers::GetT2AirPlantForSide(side) : UnitHelpers::GetT1AirPlantForSide(side);
            b.centre = AIFloat3(float(aiTerrainMgr.GetLayoutInt(b.key + ".x", 0)), 0.0f, float(aiTerrainMgr.GetLayoutInt(b.key + ".z", 0)));
            const int n = aiTerrainMgr.GetLayoutInt(b.key + ".n", 0);
            for (int j = 0; j < n; ++j) b.nanos.insertLast(aiTerrainMgr.GetLayoutInt(b.key + ".nano." + j, -1));
            bays.insertLast(b);
        }
        const int winds = aiTerrainMgr.GetLayoutInt("air.winds", 0);
        for (int i = 0; i < winds; ++i) {
            const string key = "air.wind." + i;
            WindCluster c;
            c.started = aiTerrainMgr.GetLayoutInt(key + ".started", 0) != 0;
            const int faction = aiTerrainMgr.GetLayoutInt(key + ".side", 0);
            c.defName = UnitHelpers::GetWindNameForSide(faction == 1 ? "cortex" : faction == 2 ? "legion" : "armada");
            c.facing = aiTerrainMgr.GetLayoutInt(key + ".facing", facing);
            c.centre = AIFloat3(float(aiTerrainMgr.GetLayoutInt(key + ".x", 0)), 0.0f, float(aiTerrainMgr.GetLayoutInt(key + ".z", 0)));
            for (int s = 0; s < aiTerrainMgr.GetLayoutInt(key + ".n", 6); ++s) c.slots.insertLast(aiTerrainMgr.GetLayoutInt(key + ".slot." + s, -1));
            windClusters.insertLast(c);
        }
        GenericHelpers::LogUtil("[AIR][Layout] enabled; adopted " + bays.length() + " bays, " + windClusters.length() + " wind clusters", 1);
    }
    void DiscardClusterPlan(const string &in key, int count)
    {
        for (int b = 0; b < count; ++b) {
            const string member = key + ".bay." + b;
            for (int n = 0; n < aiTerrainMgr.GetLayoutInt(member + ".n", 0); ++n)
                aiTerrainMgr.ReleasePersistentBuilding(aiTerrainMgr.GetLayoutInt(member + ".nano." + n, -1));
            aiTerrainMgr.ReleasePersistentBuilding(aiTerrainMgr.GetLayoutInt(member + ".slot", -1));
        }
        aiTerrainMgr.ReleaseZone(aiTerrainMgr.GetLayoutInt(key + ".envelope", 0));
    }
    Bay@ Reserve(CCircuitDef@ plant, const AIFloat3 &in anchor, bool force = false, Bay@ reuse = null)
    {
        if (!enabled || plant is null || (!force && ai.frame < searchAfter)) return null;
        const string side = Global::AISettings::Side;
        CCircuitDef@ advanced = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(side));
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
        if (advanced is null || nano is null) return null;
        array<Bay@> members;
        if (reuse !is null) {
            for (uint i = 0; i < bays.length(); ++i)
                if (bays[i] is reuse || (reuse.cluster >= 0 && bays[i].cluster == reuse.cluster)) members.insertLast(bays[i]);
            @plant = ai.GetCircuitDef(members[0].defName);
        }
        const int cluster = reuse !is null && reuse.cluster >= 0 ? reuse.cluster : aiTerrainMgr.GetLayoutInt("air.clusters", 0);
        const string key = "air.cluster." + cluster;
        const bool compact = ai.frame >= (MetalEconomy::Active() ? MetalEconomy::CompactCampusAfterSeconds
            : Global::RoleSettings::Air::CompactCampusAfterSeconds) * SECOND;
        const int variant = (MetalEconomy::Active() || compact) ? int(ai.frame / (10 * SECOND)) : 0;
        const int planFacing = (MetalEconomy::Active() || compact) ? (facing + variant / 3) % 4 : facing;
        // Cliffs and small islands can reject every full campus rectangle.
        // Keep each lab's twenty support pins atomic, then plan more compact
        // clusters until the aggregate six-site reserve is satisfied.
        const int count = members.length() > 0 ? int(members.length())
            : AirMath::CampusSize(compact, variant);
        // Perimeter-only bounded search, one atomic native transaction per site.
        for (int ring = 0; ring <= Global::RoleSettings::Air::EconomySearchRings; ++ring) {
            const int length = AiMax(1, 8 * ring);
            for (int k = 0; k < length; ++k) {
                const int edge = ring == 0 ? 0 : k / (2 * ring);
                const int along = ring == 0 ? 0 : k % (2 * ring) - ring;
                const int x = ring == 0 ? 0 : edge == 0 ? along : edge == 1 ? ring : edge == 2 ? -along : -ring;
                const int z = ring == 0 ? 0 : edge == 0 ? -ring : edge == 1 ? along : edge == 2 ? ring : -along;
                const AIFloat3 at = Offset(anchor, facing, float(x) * 96.0f - 168.0f, float(z) * 96.0f - 120.0f);
                if (!Inside(at, 0.0f) || !AirHome::EconomySite(at)
                    || (!MetalEconomy::Active() && aiTerrainMgr.IsZoneAlly(at))) continue;
                const int firstNanos = UnitHelpers::IsT2AircraftPlant(plant.GetName()) ? 20 : AiMin(5, Global::RoleSettings::Air::T1NanoLimit);
                // Narrow metal lanes need a longer compound with fewer columns.
                // Keep the same six sites and support pins, using the shared geometry.
                const int columns = AiMin(count, (MetalEconomy::Active() || compact) ? 3 - variant % 3 : 3);
                if (!aiTerrainMgr.PlanAirFactoryCluster(key, plant, advanced, nano, at, planFacing, count, columns, firstNanos)) continue;
                bool allowed = true;
                for (int b = 0; b < count; ++b) {
                    const AIFloat3 p = aiTerrainMgr.GetReservationPos(aiTerrainMgr.GetLayoutInt(key + ".bay." + b + ".slot", -1));
                    if (!AirHome::EconomySite(p) || AirEcoLayout::NearReactor(p, Global::RoleSettings::Air::EcoFactorySeparation)) allowed = false;
                }
                if (!allowed) { DiscardClusterPlan(key, count); continue; }
                const int envelope = aiTerrainMgr.GetLayoutInt(key + ".envelope", 0);
                for (int b = 0; b < count; ++b) {
                    Bay@ bay;
                    if (b < int(members.length())) @bay = members[b];
                    else { @bay = Bay(); bay.key = Key(int(bays.length())); bays.insertLast(bay); members.insertLast(bay); }
                    const string source = key + ".bay." + b;
                    bay.cluster = cluster; bay.slot = aiTerrainMgr.GetLayoutInt(source + ".slot", -1);
                    bay.defName = b == 0 ? plant.GetName() : advanced.GetName();
                    bay.centre = aiTerrainMgr.GetReservationPos(bay.slot); bay.facing = planFacing;
                    bay.envelope = envelope; bay.nanos.resize(0);
                    for (int n = 0; n < aiTerrainMgr.GetLayoutInt(source + ".n", 0); ++n)
                        bay.nanos.insertLast(aiTerrainMgr.GetLayoutInt(source + ".nano." + n, -1));
                    Save(bay);
                    if (UnitHelpers::IsT2AircraftPlant(bay.defName) && bay.nanos.length() != 20)
                        Invariants::Violation("INV-084", bay.key, "cluster T2 bay lacks twenty support slots");
                }
                aiTerrainMgr.SetLayoutInt("air.clusters", AiMax(cluster + 1, aiTerrainMgr.GetLayoutInt("air.clusters", 0)));
                if (members.length() != uint(count))
                    Invariants::Violation("INV-109", key, "AIR compound member count differs from its atomic plan");
                GenericHelpers::LogUtil("[AIR][Layout] cluster=" + cluster + " labs=" + count + " at=" + int(at.x) + "," + int(at.z), 1);
                return members[0];
            }
        }
        searchAfter = ai.frame + 10 * SECOND;
        return null;
    }
    Bay@ Activate(Bay@ bay)
    {
        if (bay is null) return bay;
        array<Bay@> members;
        array<int> slots;
        for (uint i = 0; i < bays.length(); ++i) {
            if (bays[i] !is bay && (bay.cluster < 0 || bays[i].cluster != bay.cluster)) continue;
            members.insertLast(bays[i]); slots.insertLast(bays[i].slot);
            for (uint n = 0; n < bays[i].nanos.length(); ++n) slots.insertLast(bays[i].nanos[n]);
        }
        // Claims protect in-flight tasks, but only a frame commits the campus.
        // Recompute this after a failed task instead of latching at enqueue.
        bool claimed = false, framed = false;
        for (uint i = 0; i < slots.length(); ++i) {
            const int slotState = aiTerrainMgr.GetReservationState(slots[i]);
            claimed = claimed || slotState == 1;
            framed = framed || slotState == 2 || slotState == 3;
        }
        if (framed) {
            for (uint i = 0; i < members.length(); ++i) {
                if (!members[i].started) { members[i].started = true; Save(members[i]); }
            }
            return bay;
        }
        if (claimed) return bay;
        for (uint i = 0; i < members.length(); ++i) {
            if (members[i].started) { members[i].started = false; Save(members[i]); }
        }
        const int state = LayoutHelpers::ActivationState(slots);
        if (state == 0) return bay;
        GenericHelpers::LogUtil("[AIR][Layout] relocate blocked unused cluster=" + bay.cluster, 1);
        for (uint i = 0; i < slots.length(); ++i) aiTerrainMgr.ReleasePersistentBuilding(slots[i]);
        aiTerrainMgr.ReleaseZone(bay.envelope);
        for (uint i = 0; i < members.length(); ++i) { members[i].slot = -1; members[i].envelope = 0; members[i].nanos.resize(0); Save(members[i]); }
        Bay@ replacement = Reserve(ai.GetCircuitDef(members[0].defName), Global::Map::StartPos, true, members[0]);
        return replacement is null ? null : bay;
    }
    int aheadFrame = -100000;
    void PlanAhead()
    {
        if (!enabled || ai.frame - aheadFrame < SECOND) return;
        // Claim the commander's nearby starter first. Speculative campuses
        // cannot force this one irreplaceable opening builder to walk away.
        if (AirEconomy::t1 + AirEconomy::t2 == 0 && !AirEconomy::HasMobileConstructor()
            && aiTerrainMgr.GetLayoutInt("air.starter.ordered", 0) == 0) return;
        aheadFrame = ai.frame;
        const string side = Global::AISettings::Side;
        // Reserve the starter and campus during the opening, before wind and
        // allied expansion use the land. Reservation spends no resources and
        // does not advance the actual mex/energy/factory build sequence.
        if (bays.length() == 0) Reserve(ai.GetCircuitDef(UnitHelpers::GetT1AirPlantForSide(side)), Global::Map::StartPos);
        AirEcoLayout::PlanAhead();
        if (bays.length() == 0 || ai.frame < searchAfter) return;
        const array<string> names = {UnitHelpers::GetT2AirPlantForSide(side), UnitHelpers::GetT1AirPlantForSide(side)};
        const int minimum = AiMax(6, Global::RoleSettings::Air::PlannedT2Bays);
        const array<int> wants = {AirMath::PlannedBays(AirEconomy::t2, minimum), AiMax(1, Global::RoleSettings::Air::PlannedT1Bays)};
        for (uint t = 0; t < names.length(); ++t) {
            int have = 0;
            Bay@ retry = null;
            for (uint i = 0; i < bays.length(); ++i) {
                // Adopted opening/gifted factories do not replace future campus capacity.
                if (bays[i].defName != names[t] || bays[i].cluster < 0) continue;
                if (bays[i].slot >= 0 || bays[i].started || bays[i].factoryId >= 0) ++have;
                else if (retry is null) @retry = bays[i];
            }
            if (have >= wants[t]) continue;
            Bay@ b = Reserve(ai.GetCircuitDef(names[t]), Global::Map::StartPos, true, retry);
            if (b !is null && t == 0 && b.nanos.length() != 20)
                Invariants::Violation("INV-084", b.key, "speculative T2 air bay lacks twenty turret slots");
            return; // one compound search per second
        }
    }
    void AdoptSupport(Bay@ bay)
    {
        CCircuitDef@ plant = ai.GetCircuitDef(bay.defName);
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
        if (plant is null || nano is null) return;
        const bool t2 = UnitHelpers::IsT2AircraftPlant(bay.defName);
        const float nw = float(nano.GetFootprintX()) * SQUARE_SIZE * 2.0f;
        const float half = float(plant.GetFootprintX()) * SQUARE_SIZE;
        for (int s = 0; s < (t2 ? 20 : 5); ++s) {
            const float x = t2 ? ProductionMath::BayAcross(s, half, nw, 32.0f) : float(s - 2) * nw;
            const float z = t2 ? ProductionMath::BayAlong(s, nw) : -half - nw;
            const AIFloat3 p = Offset(bay.centre, bay.facing, x, z);
            if (!Inside(p, nw) || MapHelpers::SqDist(p, bay.centre) > nano.GetBuildDistance() * nano.GetBuildDistance()) continue;
            const int slot = aiTerrainMgr.ReservePersistentBuilding(nano, p, bay.facing);
            if (slot >= 0) bay.nanos.insertLast(slot);
        }
        Save(bay);
    }
    // A started lab cannot relocate as a whole. Keep dead pins quarantined and
    // replace only missing support capacity, within the same lab's real reach.
    bool RepairSupport(uint index, CCircuitDef@ nano)
    {
        if (index >= bays.length() || nano is null || bays[index].factoryId < 0) return false;
        Bay@ bay = bays[index];
        const int wanted = UnitHelpers::IsT2AircraftPlant(bay.defName) ? 20 : AiMin(5, Global::RoleSettings::Air::T1NanoLimit);
        int usable = 0;
        for (uint s = 0; s < bay.nanos.length(); ++s) {
            const int state = aiTerrainMgr.GetReservationState(bay.nanos[s]);
            if (state >= 0 && state != 4) ++usable;
        }
        if (usable >= wanted) return false;
        const string key = bay.key + ".supportRepair";
        if (ai.frame < aiTerrainMgr.GetLayoutInt(key, 0)) return false;
        aiTerrainMgr.SetLayoutInt(key, ai.frame + 10 * SECOND);
        const float reach = nano.GetBuildDistance();
        const float stride = float(nano.GetFootprintX()) * 8.0f;
        for (int ring = 1; float(ring) * stride < reach; ++ring) {
            for (int k = 0; k < 24; ++k) {
                const float angle = 6.2831853f * float(k) / 24.0f;
                AIFloat3 p = Offset(bay.centre, bay.facing, cos(angle) * float(ring) * stride, sin(angle) * float(ring) * stride);
                if (!Inside(p, stride) || !AirHome::EconomySite(p) || aiTerrainMgr.IsZoneAlly(p)
                    || AirEconomy::SupportBay(nano, p) != int(index)
                    || !aiTerrainMgr.CanReserveBuilding(nano, p, bay.facing)) continue;
                const int slot = aiTerrainMgr.ReservePersistentBuilding(nano, p, bay.facing);
                if (slot < 0) continue;
                p = aiTerrainMgr.GetReservationPos(slot);
                if (AirEconomy::SupportBay(nano, p) != int(index)) {
                    aiTerrainMgr.ReleasePersistentBuilding(slot); continue;
                }
                bay.nanos.insertLast(slot); Save(bay);
                GenericHelpers::LogUtil("[AIR][Layout] repaired support " + bay.key + " viable=" + (usable + 1) + "/" + wanted
                    + " slot=" + slot + " at=" + int(p.x) + "," + int(p.z), 1);
                return true;
            }
        }
        GenericHelpers::LogUtil("[AIR][Layout] support repair has no reachable site " + bay.key, 2);
        return false;
    }
    // Required pins already have the complete native claim/retry/serialization contract.
    int pinReportAfter = 0;
    IUnitTask@ Pinned(Task::BuildType type, Task::Priority priority, CCircuitDef@ d, int slot)
    {
        if (slot < 0 || d is null || aiTerrainMgr.GetReservationState(slot) != 0) {
            if (MetalEconomy::Active() && d !is null && ai.frame >= pinReportAfter) {
                pinReportAfter = ai.frame + 10 * SECOND;
                GenericHelpers::LogUtil("[METAL][Pin] " + d.GetName() + " slot=" + slot
                    + " state=" + aiTerrainMgr.GetReservationState(slot), 1);
            }
            return null;
        }
        const AIFloat3 pos = aiTerrainMgr.GetReservationPos(slot);
        IUnitTask@ t = type == Task::BuildType::FACTORY
            ? aiBuilderMgr.Enqueue(TaskB::Factory(priority, d, pos, null, 0.0f, false, true, 300 * SECOND))
            : aiBuilderMgr.Enqueue(TaskB::Common(type, priority, d, pos, 0.0f, true, 180 * SECOND));
        const bool pinned = t !is null && AiPinReservation(t, slot);
        if (!pinned) {
            if (MetalEconomy::Active() && ai.frame >= pinReportAfter) {
                pinReportAfter = ai.frame + 10 * SECOND;
                GenericHelpers::LogUtil("[METAL][Pin] " + d.GetName() + " slot=" + slot
                    + " failed=" + (t is null ? "enqueue" : "claim"), 1);
            }
            if (t !is null) aiBuilderMgr.AbortTask(t);
            return null;
        }
        return t;
    }
    IUnitTask@ Place(CCircuitUnit@ u, CCircuitDef@ d, Task::BuildType type, Task::Priority priority, bool reactor = false, float walkRadius = 0.0f)
    {
        if (d is null || !d.IsAvailable(ai.frame) || !u.circuitDef.CanBuild(d)) return null;
        const string side = UnitHelpers::GetSideForUnitName(d.GetName());
        // Every AIR caller, including shared growth, must respect retirement.
        if (!MetalEconomy::Active() && AirEconomy::CompletedAfus() > 0 && (d.GetName() == UnitHelpers::GetWindNameForSide(side)
            || d.GetName() == UnitHelpers::GetSolarNameForSide(side)
            || d.GetName() == UnitHelpers::GetAdvSolarNameForSide(side))) return null;
        if (AirBuild::IsReactor(d) && AirBuild::ReactorPending()) return null;
        if (AirEcoLayout::Managed(d)) {
            // D-292: fusion, AFUS and advanced converters are module kinds. A
            // fusion reaches the ring search below only through the logged,
            // time-boxed fallback (no module site for FusionModuleFallbackSeconds).
            IUnitTask@ placed = AirEcoLayout::Place(u, d, type, priority);
            if (placed !is null || !AirEcoLayout::FusionFallbackDue(d)) return placed;
            @placed = PlaceField(u, d, type, priority, true, walkRadius);
            AirEcoLayout::FallbackPlaced(placed, d);
            return placed;
        }
        if (d.GetName() == UnitHelpers::GetWindNameForSide(UnitHelpers::GetSideForUnitName(d.GetName())))
            return PlaceWind(u, d, priority, walkRadius);
        return PlaceField(u, d, type, priority, reactor, walkRadius);
    }
    // Unmanaged economy placement: deterministic ring search around the start
    // (or behind it for reactors), outside every production bay. Unchanged by
    // D-292 apart from extraction; fusion uses it only as the module fallback.
    IUnitTask@ PlaceField(CCircuitUnit@ u, CCircuitDef@ d, Task::BuildType type, Task::Priority priority, bool reactor, float walkRadius)
    {
        const bool commander = UnitHelpers::IsCommander(u.circuitDef);
        const bool local = commander && walkRadius <= 0.0f;
        const string key = d.GetName() + (reactor ? ".reactor" : ".field") + (commander ? (local ? ".local." : ".walk.") + u.id : "");
        int64 retry = 0;
        if (placeRetry.get(key, retry) && ai.frame < retry) return null;
        AIFloat3 anchor = commander ? u.GetPos(ai.frame) : Global::Map::StartPos;
        if (reactor) anchor = Offset(anchor, facing, 0.0f, -900.0f);
        // Deterministic spaced patches, outside every reserved production bank.
        // The rear-biased anchor may lie beyond the map edge. Search far enough
        // to cover the opposite edge of our home disc too; fixed 24 rays left
        // large untested gaps exactly where a dense campus needed its reactors.
        const int rings = reactor ? AiMax(Global::RoleSettings::Air::EconomySearchRings,
            1 + int((Global::RoleSettings::Air::HomeEconomyRadius + 900.0f) / 96.0f))
            : Global::RoleSettings::Air::EconomySearchRings;
        for (int ring = 1; ring <= rings; ++ring) {
            const int samples = reactor ? AiMax(24, ring * 6) : 24;
            for (int k = 0; k < samples; ++k) {
                const float a = 6.2831853f * float(k) / float(samples);
                AIFloat3 p(anchor.x + cos(a) * float(ring) * 96.0f, 0.0f, anchor.z + sin(a) * float(ring) * 96.0f);
                if (local && !ProductionMath::WithinReach(MapHelpers::SqDist(anchor, p), u.circuitDef.GetBuildDistance())) continue;
                if (walkRadius > 0.0f && !ProductionMath::WithinReach(MapHelpers::SqDist(u.GetPos(ai.frame), p), walkRadius)) continue;
                bool near = false;
                for (uint b = 0; b < bays.length(); ++b)
                    if ((bays[b].slot >= 0 || bays[b].factoryId >= 0)
                        && MapHelpers::SqDist(p, bays[b].centre) < (reactor ? 700.0f * 700.0f : 250.0f * 250.0f)) near = true;
                if (near || !Inside(p, 96.0f) || !AirHome::EconomySite(p) || aiTerrainMgr.IsZoneAlly(p) || !aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())
                    || !aiTerrainMgr.CanReserveBuilding(d, p, facing)) continue;
                const int slot = aiTerrainMgr.ReserveBuilding(d, p, facing);
                if (slot < 0) continue;
                IUnitTask@ t = Pinned(type, priority, d, slot);
                if (t is null) aiTerrainMgr.ReleaseReservation(slot);
                return t;
            }
        }
        placeRetry.set(key, int64(ai.frame + 3 * SECOND));
        GenericHelpers::LogUtil("[AIR][Layout] no economy site for " + d.GetName() + "; retry in 3s", 2);
        return null;
    }
    void SaveWind(uint index)
    {
        WindCluster@ c = windClusters[index];
        const string key = "air.wind." + index;
        const string side = UnitHelpers::GetSideForUnitName(c.defName);
        aiTerrainMgr.SetLayoutInt(key + ".started", c.started ? 1 : 0);
        aiTerrainMgr.SetLayoutInt(key + ".side", side == "cortex" ? 1 : side == "legion" ? 2 : 0);
        aiTerrainMgr.SetLayoutInt(key + ".facing", c.facing);
        aiTerrainMgr.SetLayoutInt(key + ".x", int(c.centre.x));
        aiTerrainMgr.SetLayoutInt(key + ".z", int(c.centre.z));
        aiTerrainMgr.SetLayoutInt(key + ".n", int(c.slots.length()));
        for (uint s = 0; s < c.slots.length(); ++s) aiTerrainMgr.SetLayoutInt(key + ".slot." + s, c.slots[s]);
        aiTerrainMgr.SetLayoutInt("air.winds", int(windClusters.length()));
    }
    AIFloat3 WindPos(WindCluster@ c, CCircuitDef@ d, int s)
    {
        return Offset(c.centre, c.facing, ProductionMath::ClusterAcross(s, float(d.GetFootprintX()) * 16.0f),
            ProductionMath::ClusterAlong(s, float(d.GetFootprintZ()) * 16.0f));
    }
    IUnitTask@ PlaceWind(CCircuitUnit@ u, CCircuitDef@ d, Task::Priority priority, float walkRadius = 0.0f)
    {
        if (!MetalEconomy::Active() && (AirEconomy::CompletedAfus() > 0 || AirReclaim::Allowed())) return null;
        if (UnitHelpers::IsCommander(u.circuitDef)) {
            IUnitTask@ t = WindPass(u, d, priority, true);
            if (t !is null || (AirEconomy::CompletedConstructors() > 0 && walkRadius <= 0.0f)) return t;
        }
        return WindPass(u, d, priority, false, walkRadius);
    }
    IUnitTask@ WindPass(CCircuitUnit@ u, CCircuitDef@ d, Task::Priority priority, bool local, float walkRadius = 0.0f)
    {
        const AIFloat3 origin = u.GetPos(ai.frame);
        // Native states own occupied, claimed and destroyed slots. Fill holes first.
        for (uint i = 0; i < windClusters.length(); ++i) {
            WindCluster@ c = windClusters[i];
            if (c.defName != d.GetName() || c.slots.length() == 0) continue;
            if (!c.started) {
                const int state = LayoutHelpers::ActivationState(c.slots);
                if (state == 2) { c.started = true; SaveWind(i); }
                else if (state == 1) {
                    GenericHelpers::LogUtil("[AIR][Wind] relocate blocked unused cluster=" + i, 1);
                    for (uint s = 0; s < c.slots.length(); ++s) aiTerrainMgr.ReleasePersistentBuilding(c.slots[s]);
                    c.slots.resize(0); SaveWind(i);
                    continue;
                }
            }
            for (uint s = 0; s < c.slots.length(); ++s) {
                const AIFloat3 p = WindPos(c, d, int(s));
                if (local && !ProductionMath::WithinReach(MapHelpers::SqDist(origin, p), u.circuitDef.GetBuildDistance())) continue;
                if (walkRadius > 0.0f && !ProductionMath::WithinReach(MapHelpers::SqDist(origin, p), walkRadius)) continue;
                if (!Inside(p, 32.0f) || !AirHome::EconomySite(p) || !aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())) continue;
                int state = aiTerrainMgr.GetReservationState(c.slots[s]);
                if (state < 0 || state == 4) {
                    aiTerrainMgr.ReleasePersistentBuilding(c.slots[s]);
                    c.slots[s] = aiTerrainMgr.ReservePersistentBuilding(d, p, c.facing);
                    SaveWind(i);
                    state = aiTerrainMgr.GetReservationState(c.slots[s]);
                }
                if (state != 0) continue;
                IUnitTask@ task = Pinned(Task::BuildType::ENERGY, priority, d, c.slots[s]);
                if (task !is null) { c.started = true; SaveWind(i); return task; }
            }
        }
        const string key = d.GetName() + ".cluster" + (local ? ".local." + u.id : walkRadius > 0.0f ? ".walk." + u.id : "");
        int64 retry = 0;
        if (placeRetry.get(key, retry) && ai.frame < retry) return null;
        const float diameter = sqrt(ProductionMath::ClusterDiameterSquared(float(d.GetFootprintX()) * 16.0f, float(d.GetFootprintZ()) * 16.0f));
        const AIFloat3 anchor = local || walkRadius > 0.0f ? origin : Global::Map::StartPos;
        const int rings = local ? int(u.circuitDef.GetBuildDistance() / 32.0f) : walkRadius > 0.0f ? int(walkRadius / 96.0f) : Global::RoleSettings::Air::EconomySearchRings;
        const float step = local ? 32.0f : 96.0f;
        for (int ring = 1; ring <= rings; ++ring) {
            for (int k = 0; k < 24; ++k) {
                const float angle = 6.2831853f * float(k) / 24.0f;
                WindCluster c; c.defName = d.GetName(); c.facing = facing;
                c.centre = AIFloat3(anchor.x + cos(angle) * float(ring) * step, 0.0f,
                    anchor.z + sin(angle) * float(ring) * step);
                bool near = false;
                for (uint b = 0; b < bays.length(); ++b)
                    if (MapHelpers::SqDist(c.centre, bays[b].centre) < 250.0f * 250.0f) near = true;
                for (uint i = 0; i < windClusters.length(); ++i) {
                    CCircuitDef@ other = ai.GetCircuitDef(windClusters[i].defName);
                    if (other is null || windClusters[i].slots.length() == 0) continue;
                    const float separation = 0.5f * (diameter + sqrt(ProductionMath::ClusterDiameterSquared(float(other.GetFootprintX()) * 16.0f,
                        float(other.GetFootprintZ()) * 16.0f))) + Global::RoleSettings::Air::WindClusterGap + 16.0f;
                    if (MapHelpers::SqDist(c.centre, windClusters[i].centre) < separation * separation) near = true;
                }
                if (near || !Inside(c.centre, diameter) || !AirHome::EconomySite(c.centre) || aiTerrainMgr.IsZoneAlly(c.centre)) continue;
                for (int s = 0; s < 6; ++s) {
                    const AIFloat3 p = WindPos(c, d, s);
                    if (!AirHome::EconomySite(p)) break;
                    if (local && !ProductionMath::WithinReach(MapHelpers::SqDist(origin, p), u.circuitDef.GetBuildDistance())) break;
                    if (walkRadius > 0.0f && !ProductionMath::WithinReach(MapHelpers::SqDist(origin, p), walkRadius)) break;
                    if (!aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())) break;
                    const int id = aiTerrainMgr.ReservePersistentBuilding(d, p, facing);
                    if (id < 0) break;
                    c.slots.insertLast(id);
                    // Anchor the grid to the first snapped slot, avoiding accumulated rounding.
                    if (s == 0) {
                        const AIFloat3 snapped = aiTerrainMgr.GetReservationPos(id);
                        c.centre.x += snapped.x - p.x; c.centre.z += snapped.z - p.z;
                    }
                }
                if (c.slots.length() != 6) {
                    for (uint s = 0; s < c.slots.length(); ++s) aiTerrainMgr.ReleasePersistentBuilding(c.slots[s]);
                    continue;
                }
                windClusters.insertLast(c); SaveWind(windClusters.length() - 1);
                GenericHelpers::LogUtil("[AIR][Wind] cluster=" + (windClusters.length() - 1) + " slots=6 at=" + int(c.centre.x) + "," + int(c.centre.z)
                    + " local=" + local + " builder=" + u.id, 1);
                IUnitTask@ first = Pinned(Task::BuildType::ENERGY, priority, d, c.slots[0]);
                if (first !is null) { c.started = true; SaveWind(windClusters.length() - 1); }
                return first;
            }
        }
        placeRetry.set(key, int64(ai.frame + 3 * SECOND));
        return null;
    }
    void Leave()
    {
        if (!enabled) return;
        UnitHelpers::ApplyUnitLimits(originalFactoryCaps);
        originalFactoryCaps.deleteAll();
        aiEconomyMgr.reclEnergyEff = fpFromIEEE(uint(aiTerrainMgr.GetLayoutInt("air.reclaimPrior", int(fpToIEEE(20.0f)))));
        aiEconomyMgr.assistNanoEnabled = aiTerrainMgr.GetLayoutInt("air.nanoPrior", 1) != 0;
        aiTerrainMgr.ResetLayout(); aiTerrainMgr.SetLayoutEnabled(false);
        aiBuilderMgr.experimentalAirDirect = false;
        enabled = false; bays.resize(0); windClusters.resize(0); searchAfter = 0;
        AirEcoLayout::Leave();
        placeRetry.deleteAll();
    }
}
