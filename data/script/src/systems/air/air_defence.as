#include "../../roles/air/air_build.as"

// AIR alone opts into this bounded base-defense policy. Native geometry still
// owns allied reservation exclusion and stockpile behavior is unchanged.
namespace AirDefence {
    dictionary retry;
    string Name(const string &in side, uint kind)
    {
        return kind == 0 ? UnitHelpers::GetAntiNukeNameForSide(side)
            : kind == 1 ? UnitHelpers::GetStaticT2AAFlakNameForSide(side) : UnitHelpers::GetStaticT2AARangeNameForSide(side);
    }
    int Planned(uint kind)
    {
        int count = 0;
        array<string> sides = { "armada", "cortex", "legion" };
        for (uint i = 0; i < sides.length(); ++i)
            count += AirEconomy::Planned(ai.GetCircuitDef(Name(sides[i], kind)), Task::BuildType::DEFENCE);
        return count;
    }
    IUnitTask@ Place(CCircuitUnit@ u, CCircuitDef@ d, bool anti)
    {
        int64 after = 0;
        if (retry.get(d.GetName(), after) && ai.frame < after) return null;
        const float coverage = anti ? aiBattle.InterceptorCoverage(d) : 0.0f;
        if (anti && coverage <= 0.0f) return null;
        const AIFloat3 home = Global::Map::StartPos;
        AIFloat3 neighbour = AirHome::Neighbour();
        if (neighbour.x < 0.0f) neighbour = home;
        AIFloat3 best(-1.0f, 0.0f, -1.0f);
        float score = 1.0e20f;
        for (int ring = 1; ring <= 15; ++ring) {
            for (int k = 0; k < 24; ++k) {
                const float angle = 6.2831853f * float(k) / 24.0f;
                const AIFloat3 p(home.x + cos(angle) * float(ring) * 96.0f, 0.0f, home.z + sin(angle) * float(ring) * 96.0f);
                if (!AirHome::Within(p, Global::RoleSettings::Air::HomeDefenceRadius) || !AirHome::Friendly(p)
                    || !AirLayout::Inside(p, 96.0f) || aiTerrainMgr.IsZoneAlly(p)) continue;
                if (anti && !PlacementMath::CoversCore(coverage, MapHelpers::SqDist(home, p), Global::RoleSettings::Air::AntiNukeCoreRadius + 16.0f)) continue;
                const float rank = anti ? MapHelpers::SqDist(neighbour, p) : MapHelpers::SqDist(home, p);
                if (rank >= score || !aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())
                    || !aiTerrainMgr.CanReserveBuilding(d, p, AirLayout::facing)) continue;
                score = rank; best = p;
            }
        }
        if (best.x >= 0.0f) {
            const int slot = aiTerrainMgr.ReserveBuilding(d, best, AirLayout::facing);
            if (slot >= 0) {
                const AIFloat3 snapped = aiTerrainMgr.GetReservationPos(slot);
                const bool own = !anti || PlacementMath::CoversCore(coverage, MapHelpers::SqDist(home, snapped), Global::RoleSettings::Air::AntiNukeCoreRadius);
                if (own && AirHome::Within(snapped, Global::RoleSettings::Air::HomeDefenceRadius)) {
                    IUnitTask@ t = AirLayout::Pinned(Task::BuildType::DEFENCE, Task::Priority::HIGH, d, slot);
                    if (t !is null) {
                        if (anti) GenericHelpers::LogUtil("[AIR][AntiNuke] coverage=" + int(coverage) + " at=" + int(snapped.x) + "," + int(snapped.z)
                            + " ownCore=yes neighbour=" + int(neighbour.x) + "," + int(neighbour.z)
                            + " neighbourCore=" + PlacementMath::CoversCore(coverage, MapHelpers::SqDist(neighbour, snapped), Global::RoleSettings::Air::AntiNukeCoreRadius), 1);
                        return t;
                    }
                }
                aiTerrainMgr.ReleaseReservation(slot);
            }
        }
        retry.set(d.GetName(), int64(ai.frame + 5 * SECOND));
        return null;
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (AirEconomy::recovery) return null;
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        for (uint i = 0; i < 3; ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(Name(side, i));
            const bool anti = i == 0;
            const int cap = i == 1 ? AiMin(4, 1 + AirEconomy::t2) : 1;
            if (!AirBuild::Can(u, d) || Planned(i) >= cap) continue;
            if (anti) {
                if (ai.frame < Global::RoleSettings::Air::AntiNukeAfterSeconds * SECOND
                    || AirEconomy::metal < Global::RoleSettings::Air::AntiNukeMetalIncome
                    || AirEconomy::energy < Global::RoleSettings::Air::AntiNukeEnergyIncome) continue;
            } else if (AirEconomy::EnemyAir() < (i == 1 ? 500.0f : 2500.0f) || AirEconomy::metal < 30.0f) continue;
            if (AirEconomy::bankM < d.costM * 0.6f
                || !ProductionMath::Funded(AirEconomy::bankM, AirEconomy::metal * 0.2f, 150.0f, 0.0f, d.costM, 60.0f)
                || !ProductionMath::Funded(AirEconomy::bankE, AirEconomy::energy * 0.2f, 500.0f, 0.0f, d.costE, 60.0f)) continue;
            IUnitTask@ t = Place(u, d, anti);
            if (t !is null) {
                if (Planned(i) > cap) Invariants::Violation("INV-091", "AIR", "static defense class exceeded its shared faction cap");
                return t;
            }
        }
        return null;
    }
}
