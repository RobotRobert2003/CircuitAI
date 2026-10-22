// Base layout policy entry point and facing selection. Canonical footprint,
// orientation and slot geometry lives in native BaseLayoutGeometry.h.
#include "../../define.as"
#include "../../global.as"
#include "../../types/role_config.as"
#include "../common/generic_helpers.as"

/******************************************************************************

LAYOUT HELPERS

A role's plan is a handful of reservations pushed at setup, before the first
factory is placed (Setup runs from AiGetFactoryToBuild, the same frame the
native chooser picks the start factory). Native holds the ground
(aiTerrainMgr.ReserveBuilding / ReserveGrid) and serves each site back to the
first construction of that def; everything else is placed around it
(D-043). The helpers below only do the geometry: a facing, its forward and
side unit vectors, offsets in elmos, and footprint extents.

Facing is the engine's: SOUTH 0 = +z, EAST 1 = +x, NORTH 2 = -z, WEST 3 = -x.
A factory's exit is on its facing side. Native's ReserveGrid uses the same
side vectors as Side() here, so a grid and an offset agree on left and right.

******************************************************************************/
#include "wall_helpers.as"

namespace LayoutHelpers {
    int alliedCheckFrame = -100000;
    // Validate snapped sites once at reservation time, not every simulation tick.
    bool CheckGrid(const array<int> &in slots, uint first, int columns, int facing, float width, float depth) {
        if (columns<=0 || first>=slots.length()) return false;
        const AIFloat3 origin=aiTerrainMgr.GetReservationPos(slots[first]);
        for (uint i=first+1; i<slots.length(); ++i) {
            const int cell=int(i-first);
            const AIFloat3 expected=Offset(origin,facing,float(cell%columns)*width,float(cell/columns)*depth);
            if (MapHelpers::SqDist(expected,aiTerrainMgr.GetReservationPos(slots[i]))>1.0f) {
                Invariants::Violation("INV-136",""+slots[i],"dense economy grid pitch changed after engine snapping");
                return false;
            }
        }
        return true;
    }
    void CheckAlliedPlacements()
    {
        if (ai.frame - alliedCheckFrame < SECOND) return;
        alliedCheckFrame = ai.frame;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            IBuilderTask@ task = u is null ? null : cast<IBuilderTask>(u.task);
            if (task is null || task.buildDef is null || task.GetBuildType() >= int(Task::BuildType::REPAIR)) continue;
            if (!WallHelpers::Allowed(task.buildDef, task.GetBuildPos()))
                Invariants::Violation("INV-089", "" + u.id, "wall construction overlaps an allied start base area");
            const int slot = AiTaskReservationId(task);
            if (slot < 0) continue;
            if (aiTerrainMgr.IsAllyLayoutBlocked(task.buildDef, aiTerrainMgr.GetReservationPos(slot), aiTerrainMgr.GetReservationFacing(slot)))
                Invariants::Violation("INV-088", "" + u.id, "building task overlaps another allied layout reservation");
        }
    }
    // State is aggregated before checking buildability: one live claim locks a cluster.
    int ActivationState(const array<int> &in slots)
    {
        bool blocked = slots.length() == 0;
        for (uint i = 0; i < slots.length(); ++i) {
            const int state = aiTerrainMgr.GetReservationState(slots[i]);
            if (state >= 1 && state <= 3) return 2;
            if (!aiTerrainMgr.IsReservationBuildable(slots[i])) blocked = true;
        }
        return blocked ? 1 : 0;
    }

    AIFloat3 Offset(const AIFloat3 &in p, int f, float across, float along)
    {
        if (f == 1) return AIFloat3(p.x + along, 0.0f, p.z - across);
        if (f == 2) return AIFloat3(p.x - across, 0.0f, p.z - along);
        if (f == 3) return AIFloat3(p.x - along, 0.0f, p.z + across);
        return AIFloat3(p.x + across, 0.0f, p.z + along);
    }


    const int FACING_SOUTH = 0;
    const int FACING_EAST = 1;
    const int FACING_NORTH = 2;
    const int FACING_WEST = 3;
    // The facing whose forward points most nearly from `from` to `to`.
    int FacingToward(const AIFloat3& in from, const AIFloat3& in to)
    {
        const float dx = to.x - from.x;
        const float dz = to.z - from.z;
        const float ax = (dx < 0.0f) ? -dx : dx;
        const float az = (dz < 0.0f) ? -dz : dz;
        if (ax > az) return (dx > 0.0f) ? FACING_EAST : FACING_WEST;
        return (dz > 0.0f) ? FACING_SOUTH : FACING_NORTH;
    }

    AIFloat3 TerrainCentre()
    {
        return AIFloat3(float(AiTerrainWidth()) * 0.5f, 0.0f, float(AiTerrainHeight()) * 0.5f);
    }

    // Setup: run the role's plan once, after its caps and porc chain are in.
    void ApplyForRole()
    {
        RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
        if (cfg is null || cfg.LayoutPlanHandler is null) {
            GenericHelpers::LogUtil("[Layout] no plan for this role; placement is the native spiral", 2);
            return;
        }
        if (!Global::Map::HasStart) {
            GenericHelpers::LogUtil("[Layout] start position unknown at setup; no plan pushed", 1);
            return;
        }
        cfg.LayoutPlanHandler(Global::AISettings::Side);
    }
}
