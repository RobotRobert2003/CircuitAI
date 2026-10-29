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
        if (anti) {
            const int pad = AirLayout::ReserveAntiNuke();
            if (pad < 0) return null;
            const AIFloat3 p = aiTerrainMgr.GetReservationPos(pad);
            if (!aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())) return null;
            IUnitTask@ t = AirLayout::Pinned(Task::BuildType::DEFENCE, Task::Priority::HIGH, d, pad);
            if (t !is null) GenericHelpers::LogUtil("[AIR][AntiNuke] ordered income=" + AirEconomy::metal + "/" + AirEconomy::energy + " slot=" + pad, 1);
            return t;
        }
        const AIFloat3 home = Global::Map::StartPos;
        AIFloat3 best(-1.0f, 0.0f, -1.0f);
        float score = 1.0e20f;
        for (int ring = 1; ring <= 15; ++ring) {
            for (int k = 0; k < 24; ++k) {
                const float angle = 6.2831853f * float(k) / 24.0f;
                const AIFloat3 p(home.x + cos(angle) * float(ring) * 96.0f, 0.0f, home.z + sin(angle) * float(ring) * 96.0f);
                if (!AirHome::Within(p, Global::RoleSettings::Air::HomeDefenceRadius) || !AirHome::Friendly(p)
                    || !AirLayout::Inside(p, 96.0f) || aiTerrainMgr.IsZoneAlly(p)) continue;
                const float rank = MapHelpers::SqDist(home, p);
                if (rank >= score || !aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())
                    || !aiTerrainMgr.CanReserveBuilding(d, p, AirLayout::facing)) continue;
                score = rank; best = p;
            }
        }
        if (best.x >= 0.0f) {
            const int slot = aiTerrainMgr.ReserveBuilding(d, best, AirLayout::facing);
            if (slot >= 0) {
                const AIFloat3 snapped = aiTerrainMgr.GetReservationPos(slot);
                if (AirHome::Within(snapped, Global::RoleSettings::Air::HomeDefenceRadius)) {
                    IUnitTask@ t = AirLayout::Pinned(Task::BuildType::DEFENCE, Task::Priority::HIGH, d, slot);
                    if (t !is null) {
                        return t;
                    }
                }
                aiTerrainMgr.ReleaseReservation(slot);
            }
        }
        retry.set(d.GetName(), int64(ai.frame + 5 * SECOND));
        return null;
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u, bool antiOnly = false)
    {
        if (AirEconomy::recovery) return null;
        // The early dispatcher visits this before growth. Reject its fixed
        // time/income gate before allocating faction arrays or counting tasks.
        if (antiOnly && (ai.frame < Global::RoleSettings::Air::AntiNukeAfterSeconds * SECOND
            || AirEconomy::metal < Global::RoleSettings::Air::AntiNukeMetalIncome
            || AirEconomy::energy < Global::RoleSettings::Air::AntiNukeEnergyIncome)) return null;
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        for (uint i = 0; i < uint(antiOnly ? 1 : 3); ++i) {
            const bool anti = i == 0;
            // The persistent pad belongs to this AI's faction. A foreign gift
            // may assist it, but cannot claim it for another faction's unit.
            CCircuitDef@ d = ai.GetCircuitDef(Name(anti ? Global::AISettings::Side : side, i));
            const int cap = i == 1 ? AiMin(4, 1 + AirEconomy::t2) : 1;
            if (!AirBuild::Can(u, d) || Planned(i) >= cap) continue;
            if (anti) {
                if (ai.frame < Global::RoleSettings::Air::AntiNukeAfterSeconds * SECOND
                    || AirEconomy::metal < Global::RoleSettings::Air::AntiNukeMetalIncome
                    || AirEconomy::energy < Global::RoleSettings::Air::AntiNukeEnergyIncome) continue;
            } else if (AirEconomy::EnemyAir() < (i == 1 ? 500.0f : 2500.0f) || AirEconomy::metal < 30.0f) continue;
            if (!anti && (AirEconomy::bankM < d.costM * 0.6f
                || !ProductionMath::Funded(AirEconomy::bankM, AirEconomy::metal * 0.2f, 150.0f, 0.0f, d.costM, 60.0f)
                || !ProductionMath::Funded(AirEconomy::bankE, AirEconomy::energy * 0.2f, 500.0f, 0.0f, d.costE, 60.0f))) continue;
            IUnitTask@ t = Place(u, d, anti);
            if (t !is null) {
                if (Planned(i) > cap) Invariants::Violation("INV-091", "AIR", "static defense class exceeded its shared faction cap");
                return t;
            }
        }
        return null;
    }
}
