#include "../../types/strategic_objectives.as"
#include "../../global.as"
#include "../../systems/world/objective_manager.as"
#include "../spatial/map_helpers.as"

namespace ObjectiveHelpers {
    // State moved to ObjectiveManager; leave only pure helpers in this namespace
    // Renamed: "assigned" instead of "claimed"
    bool IsAssigned(const string &in id) { return ObjectiveManager::IsAssigned(id); }
    bool IsCompleted(const string &in id) { return ObjectiveManager::IsCompleted(id); }
    bool TryAssign(const string &in id, const string &in who) { return ObjectiveManager::TryAssign(id, who); }
    string GetAssignee(const string &in id) { return ObjectiveManager::GetAssignee(id); }
    void Complete(const string &in id) { ObjectiveManager::Complete(id); }
    void Unassign(const string &in id) { ObjectiveManager::Unassign(id); }

    // Defense tracking wrappers
    void IncrementDefenseQueued(const string &in id, const string &in defType, int count = 1) { ObjectiveManager::IncrementDefenseQueued(id, defType, count); }
    void IncrementDefenseBuilt(const string &in id, const string &in defType, int count = 1) { ObjectiveManager::IncrementDefenseBuilt(id, defType, count); }
    // Per-objective counts for queued and completed buildings of a given unit type
    int GetObjectiveBuildingsQueuedCount(const string &in id, const string &in defType) { return ObjectiveManager::GetObjectiveBuildingsQueuedCount(id, defType); }
    int GetObjectiveBuildingsBuiltCount(const string &in id, const string &in defType) { return ObjectiveManager::GetObjectiveBuildingsBuiltCount(id, defType); }
    int GetDefenseQueuedTotal(const string &in id) { return ObjectiveManager::GetDefenseQueuedTotal(id); }
    int GetDefenseBuiltTotal(const string &in id) { return ObjectiveManager::GetDefenseBuiltTotal(id); }
    void ResetDefenseState(const string &in id) { ObjectiveManager::ResetDefenseState(id); }
    array<string> GetDefenseQueuedTypes(const string &in id) { return ObjectiveManager::GetDefenseQueuedTypes(id); }
    array<string> GetDefenseBuiltTypes(const string &in id) { return ObjectiveManager::GetDefenseBuiltTypes(id); }

    // State enum passthrough
    int GetState(const string &in id) { return ObjectiveManager::GetState(id); }
    void SetState(const string &in id, int state) { ObjectiveManager::SetState(id, state); }

    array<Objectives::StrategicObjective@>@ GetAll() {
    return Global::Map::Config.Objectives;
    }

    // --- Objective step factory helpers ---
    // Create a basic step with type only (count defaults to 1)
    Objectives::ObjectiveStep@ MakeStep(Objectives::BuildingType type)
    {
        Objectives::ObjectiveStep@ s = Objectives::ObjectiveStep();
        s.type = type;
        s.count = 1;
        // Eco thresholds default to 0 (no gate)
        s.minMetalIncome = 0.0f;
        s.minEnergyIncome = 0.0f;
        return s;
    }

    // Create a step with type and count
    Objectives::ObjectiveStep@ MakeStep(Objectives::BuildingType type, int count)
    {
        Objectives::ObjectiveStep@ s = MakeStep(type);
        s.count = count;
        return s;
    }

    // Create a step with type, count, and per-step eco gates
    Objectives::ObjectiveStep@ MakeStep(Objectives::BuildingType type, int count, float minMetalIncome, float minEnergyIncome)
    {
        Objectives::ObjectiveStep@ s = MakeStep(type, count);
        s.minMetalIncome = minMetalIncome;
        s.minEnergyIncome = minEnergyIncome;
        return s;
    }

    // --- Distance helpers ---
    // Compute squared distance from a point to a line segment AB in XZ plane
    float _SqDistPointToSegmentXZ(const AIFloat3 &in p, const AIFloat3 &in a, const AIFloat3 &in b)
    {
        // Handle degenerate segment
        const float abx = b.x - a.x; const float abz = b.z - a.z;
        const float ab2 = abx * abx + abz * abz;
        if (ab2 <= 1e-6f) return MapHelpers::SqDist(p, a);

        // Project point onto segment, clamp t to [0,1]
        const float apx = p.x - a.x; const float apz = p.z - a.z;
        float t = (apx * abx + apz * abz) / ab2; if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
        const float qx = a.x + t * abx; const float qz = a.z + t * abz;
        const float dx = p.x - qx; const float dz = p.z - qz;
        return dx * dx + dz * dz;
    }

    // Compute distance (XZ) from reference to an objective; supports point or polyline
    float DistanceFrom(const AIFloat3 &in ref, const Objectives::StrategicObjective@ o)
    {
        if (o is null) return 0.0f;
        // Prefer point if present (non-zero)
        if (o.pos.x != 0.0f || o.pos.z != 0.0f) {
            return sqrt(MapHelpers::SqDist(ref, o.pos));
        }
        // If line present, compute min distance to its segments or points
        float best = 1e30f;
        if (o.line.length() > 0) {
            if (o.line.length() == 1) {
                best = MapHelpers::SqDist(ref, o.line[0]);
            } else {
                for (uint i = 1; i < o.line.length(); ++i) {
                    float d2 = _SqDistPointToSegmentXZ(ref, o.line[i - 1], o.line[i]);
                    if (d2 < best) best = d2;
                }
            }
            return sqrt(best);
        }
        return 0.0f;
    }

    // Utility: copy and sort a list by distance from reference (ascending). If 'src' is null, sorts all.
    array<Objectives::StrategicObjective@> SortByDistance(const AIFloat3 &in ref, array<Objectives::StrategicObjective@>@ src = null)
    {
        array<Objectives::StrategicObjective@>@ all = (src is null ? GetAll() : src);
        // Manual insertion sort to avoid capturing 'ref' inside a lambda comparator
        array<Objectives::StrategicObjective@> results;
        for (uint i = 0; i < all.length(); ++i) {
            Objectives::StrategicObjective@ currentObjective = all[i];
            float dcur = DistanceFrom(ref, currentObjective);
            uint j = 0;
            for (; j < results.length(); ++j) {
                float dj = DistanceFrom(ref, results[j]);
                if (dcur < dj) break;
            }
            results.insertAt(j, currentObjective);
        }
        return results;
    }

    // Log all objectives with distance from map start position, including builderGroup, prefixed by role tag
    void LogAllObjectivesFromStart(AiRole role, const string &in roleName)
    {
        const AIFloat3 start = Global::Map::StartPos;
        array<Objectives::StrategicObjective@>@ all = GetAll();
        for (uint i = 0; i < all.length(); ++i) {
            auto@ o = all[i];
            float d = DistanceFrom(start, o);
            string name = (o.id.length() > 0 ? o.id : o.note);
            if (name.length() == 0) name = "<unnamed>";
            string groupStr = "PRIMARY";
            if (o.builderGroup == Objectives::BuilderGroup::SECONDARY) groupStr = "SECONDARY";
            else if (o.builderGroup == Objectives::BuilderGroup::TACTICAL) groupStr = "TACTICAL";
            GenericHelpers::LogUtil("[OBJECTIVE] role=" + roleName + " name=" + name + " dist=" + d + " group=" + groupStr, 2);
        }
    }

    bool StepEcoSatisfied(const Objectives::ObjectiveStep@ s)
    {
        if (s is null) return true;
        if (s.minMetalIncome > 0 && aiEconomyMgr.metal.income < s.minMetalIncome) return false;
        if (s.minEnergyIncome > 0 && aiEconomyMgr.energy.income < s.minEnergyIncome) return false;
        return true;
    }

    // Preferred build position: objective point if set; else first line point; else fallback
    AIFloat3 PreferredBuildPos(const Objectives::StrategicObjective@ o, const AIFloat3 &in fallback)
    {
        if (o is null) return fallback;
        if (o.pos.x != 0.0f || o.pos.z != 0.0f) return o.pos;
        if (o.line.length() > 0) return o.line[0];
        return fallback;
    }

    bool Matches(
        const Objectives::StrategicObjective@ o,
        AiRole role, const string &in side,
        Objectives::ConstructorClass cls, int tier,
        int frame
    ) {
    if (o is null) return false;
    if (IsCompleted(o.id)) return false;

        if (o.roles.length() > 0) {
            bool ok = false; for (uint i = 0; i < o.roles.length(); ++i) if (o.roles[i] == role) { ok = true; break; }
            if (!ok) return false;
        }
        if (o.sides.length() > 0) {
            bool ok = false; for (uint i = 0; i < o.sides.length(); ++i) if (o.sides[i] == side) { ok = true; break; }
            if (!ok) return false;
        }
        if (o.classes.length() > 0) {
            bool ok = false; for (uint i = 0; i < o.classes.length(); ++i) if (o.classes[i] == cls || o.classes[i] == Objectives::ConstructorClass::ANY) { ok = true; break; }
            if (!ok) return false;
        }
        if (o.tiers.length() > 0) {
            bool ok = false; for (uint i = 0; i < o.tiers.length(); ++i) if (o.tiers[i] == tier) { ok = true; break; }
            if (!ok) return false;
        }
        if (o.startFrameMax > 0 && frame > o.startFrameMax) return false;
    if (o.minMetalIncome > 0 && aiEconomyMgr.metal.income < o.minMetalIncome) return false;
    if (o.minEnergyIncome > 0 && aiEconomyMgr.energy.income < o.minEnergyIncome) return false;
        return true;
    }

    array<Objectives::StrategicObjective@> Find(
        AiRole role, const string &in side,
        Objectives::ConstructorClass cls, int tier,
        const AIFloat3 &in reference, int frame
    ) {
    // Start with base-range filtered objectives
    array<Objectives::StrategicObjective@>@ all = ObjectiveManager::FilterByBaseRange(GetAll());
    array<Objectives::StrategicObjective@> results;
        for (uint i = 0; i < all.length(); ++i) {
            auto@ o = all[i];
            if (Matches(o, role, side, cls, tier, frame) && !IsAssigned(o.id)) results.insertLast(o);
        }
        // Manual insertion sort to avoid capturing 'reference' in a lambda comparator
        for (uint i = 1; i < results.length(); ++i) {
            Objectives::StrategicObjective@ key = results[i];
            int j = i - 1;
            // Compare by priority first (descending), then by distance from reference (ascending)
            while (j >= 0) {
                Objectives::StrategicObjective@ prev = results[uint(j)];
                bool shouldSwap = false;
                if (prev.priority < key.priority) {
                    shouldSwap = true; // higher priority comes first
                } else if (prev.priority == key.priority) {
                    float da = DistanceFrom(reference, prev);
                    float db = DistanceFrom(reference, key);
                    if (da > db) shouldSwap = true;
                }
                if (!shouldSwap) break;
                results[uint(j + 1)] = results[uint(j)];
                j--;
            }
            results[uint(j + 1)] = key;
        }
        return results;
    }

    // Overload: find with a target builder group (PRIMARY, SECONDARY, TACTICAL)
    array<Objectives::StrategicObjective@> Find(
        AiRole role, const string &in side,
        Objectives::ConstructorClass cls, int tier,
        const AIFloat3 &in reference, int frame,
        Objectives::BuilderGroup group
    ) {
        // Filter by base range first
        array<Objectives::StrategicObjective@>@ base = ObjectiveManager::FilterByBaseRange(GetAll());
        array<Objectives::StrategicObjective@> scoped = ObjectiveManager::FilterByBuilderGroup(base, group);
        array<Objectives::StrategicObjective@> results;
        for (uint i = 0; i < scoped.length(); ++i) {
            auto@ o = scoped[i];
            if (Matches(o, role, side, cls, tier, frame) && !IsAssigned(o.id)) results.insertLast(o);
        }
        // Same priority-then-distance sort as the base Find
        for (uint i = 1; i < results.length(); ++i) {
            Objectives::StrategicObjective@ key = results[i];
            int j = i - 1;
            while (j >= 0) {
                Objectives::StrategicObjective@ prev = results[uint(j)];
                bool shouldSwap = false;
                if (prev.priority < key.priority) {
                    shouldSwap = true;
                } else if (prev.priority == key.priority) {
                    float da = DistanceFrom(reference, prev);
                    float db = DistanceFrom(reference, key);
                    if (da > db) shouldSwap = true;
                }
                if (!shouldSwap) break;
                results[uint(j + 1)] = results[uint(j)];
                j--;
            }
            results[uint(j + 1)] = key;
        }
        return results;
    }

    // --- Reusable logging helper ---
    // Logs summary and top candidates for objectives matching a role/constructor class near a reference point.
    void LogMatchingObjectivesForRole(
        AiRole role,
        const string &in roleName,
        const string &in side,
        Objectives::ConstructorClass constructorClass,
        const AIFloat3 &in ref,
        int frame,
        int maxPerTier = 5
    ) {
        // Overall stats
        array<Objectives::StrategicObjective@>@ allRef = GetAll();
        int total = (allRef is null ? 0 : allRef.length());
        array<Objectives::StrategicObjective@> inRange = ObjectiveManager::FilterByBaseRange(allRef);

        // Tiered finds using existing Find helper
        array<Objectives::StrategicObjective@> tier1 = ObjectiveHelpers::Find(
            role, side, constructorClass, 1, ref, frame
        );
        array<Objectives::StrategicObjective@> tier2 = ObjectiveHelpers::Find(
            role, side, constructorClass, 2, ref, frame
        );

        GenericHelpers::LogUtil("[" + roleName + "][Obj] total=" + total + " inRange=" + inRange.length() +
            " tier1=" + tier1.length() + " tier2=" + tier2.length(), 2);

        int logT1 = (int(tier1.length()) < maxPerTier ? int(tier1.length()) : maxPerTier);
        for (int i = 0; i < logT1; ++i) {
            Objectives::StrategicObjective@ o = tier1[uint(i)];
            float d = DistanceFrom(ref, o);
            GenericHelpers::LogUtil("[" + roleName + "][Obj][T1] #" + i + " id=" + o.id + " prio=" + o.priority + " d=" + d, 2);
        }
        int logT2 = (int(tier2.length()) < maxPerTier ? int(tier2.length()) : maxPerTier);
        for (int i = 0; i < logT2; ++i) {
            Objectives::StrategicObjective@ o2 = tier2[uint(i)];
            float d2 = DistanceFrom(ref, o2);
            GenericHelpers::LogUtil("[" + roleName + "][Obj][T2] #" + i + " id=" + o2.id + " prio=" + o2.priority + " d=" + d2, 2);
        }
    }
}
