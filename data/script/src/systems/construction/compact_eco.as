// D-307: map-opted TECH economy, independent of the full factory-pair template.
namespace CompactEco {
    const string ROOT = "tech.compact";
    array<int> groups;
    array<int> zones;
    array<int> seeds;
    array<int> projects;
    array<int> expansionRetry;
    int failedSearchFrame = -100000;
    int searchCursor = 0;
    AIFloat3 searchOrigin(-1.0f, 0.0f, -1.0f);

    bool Active() { return Global::AISettings::Role == AiRole::TECH && Global::Map::Config.TechCompactEconomy && aiTerrainMgr.IsLayoutEnabled(); }

    void Clear()
    {
        groups.resize(0);
        zones.resize(0);
        seeds.resize(0);
        projects.resize(0);
        expansionRetry.resize(0);
        failedSearchFrame = -100000;
        searchCursor = 0; searchOrigin = AIFloat3(-1.0f, 0.0f, -1.0f);
    }

    void Adopt()
    {
        Clear();
        const int count = aiTerrainMgr.GetLayoutInt(ROOT + ".count", 0);
        for (int index = 0; index < count; ++index) {
            const int group = aiTerrainMgr.GetLayoutInt(ROOT + ".group" + index, 0);
            const int zone = aiTerrainMgr.GetGroupZone(group);
            if (group <= 0 || zone <= 0) continue;
            groups.insertLast(group);
            zones.insertLast(zone);
            seeds.insertLast(aiTerrainMgr.GetLayoutInt(ROOT + ".seed" + index, -1));
            projects.insertLast(aiTerrainMgr.GetLayoutInt(ROOT + ".project" + index, -1));
            expansionRetry.insertLast(0);
        }
        // The cramped advanced lab owns its initial two support slots.
        Layout::nanoGroup = aiTerrainMgr.GetLayoutInt(Layout::BOX + ".nano_group", 0);
        Layout::labSlot = aiTerrainMgr.GetLayoutInt(Layout::BOX + ".lab_slot", -1);
        RegisterFactories();
    }

    void RegisterFactories()
    {
        aiTerrainMgr.ClearFactoryZones();
        if (Layout::nanoGroup > 0) aiTerrainMgr.AddFactoryZone(aiTerrainMgr.GetGroupZone(Layout::nanoGroup), Layout::nanoGroup);
        for (uint index = 0; index < groups.length(); ++index)
            aiTerrainMgr.AddFactoryZone(zones[index], groups[index]);
        aiTerrainMgr.SetFactoryFront(Layout::LabFacing());
    }

    int Pack(int group, CCircuitDef@ definition, CCircuitUnit@ worker)
    {
        if (group <= 0) return -1;
        const int index = groups.find(group);
        const int zone = index >= 0 ? zones[index] : aiTerrainMgr.GetGroupZone(group);
        const int slot = aiTerrainMgr.PackNearGroup(zone, definition, group,
            Layout::LabFacing(), worker.GetPos(ai.frame), 0.0f, Layout::MinNanoDist(definition), 0);
        if (slot >= 0 && !aiTerrainMgr.CanReachAt(worker, aiTerrainMgr.GetReservationPos(slot), worker.circuitDef.GetBuildDistance())) {
            aiTerrainMgr.ReleaseReservation(slot);
            return -1;
        }
        if (slot >= 0 && index >= 0) {
            projects[index] = slot;
            aiTerrainMgr.SetLayoutInt(ROOT + ".project" + index, slot);
        }
        return slot;
    }

    // The cramped lab may move onto a shelf away from the home mex centre.
    // Keep the rush locality limit around actual support sites as well as home.
    bool LocalWorker(const AIFloat3& in position, float radius)
    {
        const float limit = radius * radius;
        if (MapHelpers::SqDist(position, Layout::HomeCentre()) <= limit) return true;
        if (Layout::labSlot >= 0) {
            const AIFloat3 lab = aiTerrainMgr.GetReservationPos(Layout::labSlot);
            if (lab.x >= 0.0f && MapHelpers::SqDist(position, lab) <= limit) return true;
        }
        for (uint index = 0; index < seeds.length(); ++index) {
            const AIFloat3 seed = aiTerrainMgr.GetReservationPos(seeds[index]);
            if (seed.x >= 0.0f && MapHelpers::SqDist(position, seed) <= limit) return true;
        }
        return false;
    }

    AIFloat3 SearchOrigin()
    {
        if (Layout::labSlot >= 0) {
            const AIFloat3 lab = aiTerrainMgr.GetReservationPos(Layout::labSlot);
            if (lab.x >= 0.0f) return lab;
        }
        return Layout::HomeCentre();
    }

    // Square spiral visits every grid point, including pockets between spokes.
    AIFloat3 SearchOffset(int index)
    {
        if (index <= 0) return AIFloat3(0.0f, 0.0f, 0.0f);
        const int ring = int(ceil((sqrt(float(index + 1)) - 1.0f) * 0.5f));
        const int edge = ring * 2;
        const int offset = index - (edge - 1) * (edge - 1);
        const int side = offset / edge, along = offset % edge;
        if (side == 0) return AIFloat3(float(ring), 0.0f, float(-ring + along));
        if (side == 1) return AIFloat3(float(ring - along), 0.0f, float(ring));
        if (side == 2) return AIFloat3(float(-ring), 0.0f, float(ring - along));
        return AIFloat3(float(-ring + along), 0.0f, float(-ring));
    }

    // At most 128 footprint probes and eight economy packing searches per ask.
    // Failure waits 60 seconds then resumes, so repeated asks do not scan the
    // same blocked prefix forever. Only capacity growth searches terrain.
    // Native owns claims, loss recovery and saved IDs; Clear/Adopt owns arrays.
    // A one-turret bank commits only if the requested economy footprint fits too.
    int Grow(CCircuitUnit@ worker, CCircuitDef@ requested, int &out buildingSlot)
    {
        buildingSlot = -1;
        if (Layout::nano is null || worker is null || worker.circuitDef is null
            || groups.length() >= uint(Global::RoleSettings::Tech::CompactEcoMaxClusters)
            || ai.frame - failedSearchFrame < int(Global::RoleSettings::Tech::CompactEcoRetrySeconds) * SECOND) return 0;
        const int direction = Layout::LabFacing();
        const AIFloat3 forward = Layout::Fwd(direction);
        const AIFloat3 origin = SearchOrigin();
        if (MapHelpers::SqDist(origin, searchOrigin) > 1.0f) {
            searchOrigin = origin; searchCursor = 0;
        }
        const float halfWidth = float(Layout::Across(Layout::nano, direction)) * SQUARE_SIZE;
        const float halfDepth = float(Layout::Along(Layout::nano, direction)) * SQUARE_SIZE;
        const float margin = AiMax(halfWidth, halfDepth);
        const int diameter = Global::RoleSettings::Tech::CompactEcoSearchRings * 2 + 1;
        const int count = diameter * diameter;
        if (count <= 0) return 0;
        int packingAttempts = 0;
        for (int tried = 0; tried < AiMin(count, Global::RoleSettings::Tech::CompactEcoSearchBudget); ++tried) {
            const AIFloat3 centre = origin + SearchOffset(searchCursor) * Global::RoleSettings::Tech::CompactEcoSearchStep;
            searchCursor = (searchCursor + 1) % count;
            if (centre.x < margin || centre.z < margin || centre.x >= AiTerrainWidth() - margin || centre.z >= AiTerrainHeight() - margin) continue;
            if (!aiTerrainMgr.CanReachAt(worker, centre, worker.circuitDef.GetBuildDistance())) continue;
            if (!aiTerrainMgr.CanReserveBuilding(Layout::nano, centre, direction)) continue;
            const int zone = aiTerrainMgr.ReserveZone(centre, direction, halfWidth, halfDepth, false);
            if (zone <= 0) continue;
            const int group = aiTerrainMgr.LayBand(zone, Layout::nano, centre + forward * halfDepth,
                direction, 1, 1, 0, true, true, false, 0);
            const bool supported = group > 0 && aiTerrainMgr.GetGroupCount(group, false) == 1
                && aiTerrainMgr.GetGroupActivationState(group) == 0;
            int slot = -1;
            if (supported) {
                if (requested is null) slot = aiTerrainMgr.NextReachableSlot(worker, Layout::nano, zone, group, 1);
                else { ++packingAttempts; slot = Pack(group, requested, worker); }
            }
            if (slot < 0) {
                if (group > 0) aiTerrainMgr.ReleaseGroup(group);
                aiTerrainMgr.ReleaseZone(zone);
                if (packingAttempts >= Global::RoleSettings::Tech::CompactEcoPackingAttempts) break;
                continue;
            }
            aiTerrainMgr.SetLayoutInt(ROOT + ".group" + groups.length(), group);
            const int seed = requested is null ? slot : aiTerrainMgr.NextSlotAny(group, centre);
            aiTerrainMgr.SetLayoutInt(ROOT + ".seed" + groups.length(), seed);
            aiTerrainMgr.SetLayoutInt(ROOT + ".project" + groups.length(), slot);
            groups.insertLast(group); zones.insertLast(zone); seeds.insertLast(seed); projects.insertLast(slot);
            expansionRetry.insertLast(0);
            aiTerrainMgr.SetLayoutInt(ROOT + ".count", int(groups.length()));
            RegisterFactories();
            buildingSlot = slot;
            searchCursor = 0;
            GenericHelpers::LogUtil("[Layout][Compact] cluster=" + groups.length() + " group=" + group
                + " zone=" + zone + " turrets=1 adaptive at (" + int(centre.x) + ", " + int(centre.z) + ")", 1);
            return group;
        }
        failedSearchFrame = ai.frame;
        GenericHelpers::LogUtil("[Layout][Compact] no reachable supported site; bounded retry pending", 1);
        return 0;
    }

    int Extend(CCircuitUnit@ worker, uint index)
    {
        const int group = groups[index];
        const int direction = Layout::LabFacing();
        const float spacing = float(AiMax(Layout::Across(Layout::nano, direction), Layout::Along(Layout::nano, direction))
            + Global::RoleSettings::Tech::CompactEcoGapCells) * 2.0f * SQUARE_SIZE;
        const int slot = aiTerrainMgr.PackNearGroup(zones[index], Layout::nano, group, direction,
            aiTerrainMgr.GetReservationPos(seeds[index]), Global::RoleSettings::Tech::CompactEcoTurretSpread, spacing, group);
        if (slot >= 0 && aiTerrainMgr.CanReachAt(worker, aiTerrainMgr.GetReservationPos(slot), worker.circuitDef.GetBuildDistance())) return slot;
        if (slot >= 0) aiTerrainMgr.ReleaseReservation(slot);
        expansionRetry[index] = ai.frame + int(Global::RoleSettings::Tech::CompactEcoRetrySeconds) * SECOND;
        return -1;
    }

    IUnitTask@ Order(int slot, Task::BuildType type, Task::Priority priority, CCircuitDef@ definition, int timeout, bool fresh)
    {
        if (slot < 0) return null;
        IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Common(type, priority, definition,
            aiTerrainMgr.GetReservationPos(slot), 0.0f, true, timeout));
        if (task is null) { if (fresh) aiTerrainMgr.ReleaseReservation(slot); return null; }
        if (!AiPinReservation(task, slot)) { aiBuilderMgr.AbortTask(task); return null; }
        return task;
    }

    IUnitTask@ NanoTask(CCircuitUnit@ worker, Task::Priority priority)
    {
        int slot = -1;
        // Try the cramped lab's support first, but its old two-slot template
        // can be unbuildable on this map. It must not prevent independent
        // economy banks. An unusable pocket cannot veto other patches either.
        if (Layout::nanoGroup > 0)
            slot = aiTerrainMgr.NextReachableSlot(worker, Layout::nano, aiTerrainMgr.GetGroupZone(Layout::nanoGroup), Layout::nanoGroup, 8);
        for (uint index = 0; slot < 0 && index < groups.length(); ++index) {
            slot = aiTerrainMgr.NextReachableSlot(worker, Layout::nano, zones[index], groups[index], 8);
        }
        // O(C) group checks, at most eight bounded native packing searches.
        // Failed extensions cool down independently; a full bank costs no probe.
        int attempts = 0;
        for (uint index = 0; slot < 0 && index < groups.length(); ++index) {
            if (ai.frame < expansionRetry[index] || aiTerrainMgr.GetGroupCount(groups[index], false)
                >= Global::RoleSettings::Tech::CompactEcoColumns * Global::RoleSettings::Tech::CompactEcoRows) continue;
            if (++attempts > Global::RoleSettings::Tech::CompactEcoPackingAttempts) break;
            slot = Extend(worker, index);
        }
        if (slot < 0) Grow(worker, null, slot);
        return Order(slot, Task::BuildType::NANO, priority, Layout::nano, 120 * SECOND, false);
    }

    IUnitTask@ Place(Task::BuildType type, Task::Priority priority, CCircuitDef@ definition, int timeout, CCircuitUnit@ worker)
    {
        if (worker is null || worker.circuitDef is null || !worker.circuitDef.CanBuild(definition)) return null;
        int slot = Pack(Layout::nanoGroup, definition, worker);
        for (uint index = 0; slot < 0 && index < groups.length(); ++index) slot = Pack(groups[index], definition, worker);
        if (slot < 0) Grow(worker, definition, slot);
        // Small banks hold individual reactors/converters. Every footprint is
        // still within native-verified turret reach; no long set or loose spiral.
        return Order(slot, type, priority, definition, timeout, true);
    }

    IUnitTask@ SupportTask(CCircuitUnit@ worker)
    {
        if (!Active() || Layout::nano is null || !worker.circuitDef.CanBuild(Layout::nano)
            || !Layout::nano.IsAvailable(ai.frame) || aiEconomyMgr.metal.current < Layout::nano.costM
            || Layout::TurretsCapped()) return null;
        // Stable seed/project IDs avoid per-worker global reservation/unit scans:
        // O(C log R) once seeded, C <= 24 banks and R native reservations. A
        // missing seed may resolve another built member with one O(R) scan.
        // Claims/frames are live; native loss recovery owns destruction,
        // Clear/Adopt owns lifetime.
        // Further turrets still use ordinary income/power policy. No growth here.
        for (uint index = 0; index < groups.length(); ++index) {
            const int group = groups[index];
            const int seedState = aiTerrainMgr.GetReservationState(seeds[index]);
            const int projectState = aiTerrainMgr.GetReservationState(projects[index]);
            if ((seedState >= 1 && seedState <= 3) || projectState < 1 || projectState > 3) continue;
            // Ordinary turret growth may have started a different member first.
            const int built = aiTerrainMgr.NextBuilt(group, worker.GetPos(ai.frame));
            if (built >= 0) {
                seeds[index] = built;
                aiTerrainMgr.SetLayoutInt(ROOT + ".seed" + index, built);
                continue;
            }
            const int slot = aiTerrainMgr.NextReachableSlot(worker, Layout::nano, zones[index], group, 8);
            if (slot < 0) continue;
            IUnitTask@ task = Order(slot, Task::BuildType::NANO, Task::Priority::HIGH, Layout::nano, 120 * SECOND, false);
            if (task !is null) {
                seeds[index] = slot;
                aiTerrainMgr.SetLayoutInt(ROOT + ".seed" + index, slot);
            }
            return task;
        }
        return null;
    }
}
