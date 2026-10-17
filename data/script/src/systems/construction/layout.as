// TECH base layout policy: the native factory pair (D-060) and the turret box (D-063).
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/spatial/layout_helpers.as"
#include "../presentation/widget_link.as"
#include "compact_eco.as"

/******************************************************************************

LAYOUT (doc/layout-design.md)

Two things are planned at frame zero, before the first structure:

  1. The factory pair (D-060, native): the T1 and T2 bot labs side by side,
     each with its snug rear nano block and a held exit rectangle.

  2. The turret box (D-063): a rectangle of the flattest, most buildable
     ground directly behind the pair, sized from the settings and shrunk or
     slid until it fits. Inside it, rows of construction turrets are
     reserved as if they stood already - the "invisible turrets". Every row
     is laid slot by slot, so a boulder or a mex costs one slot, not the
     row, and never the plan.

Everything TECH builds for its economy after that - winds, solars, converters,
storages, fusions - is packed by native into the box on the free cells
nearest to a turret slot (PackNearGroup), inside a turret's reach and never
beyond it. The task is pinned to that footprint: no spiral, no walk. Turrets
themselves go up on demand, nearest the factories first, when the planner
finds build power short or metal floating.

This file answers "where"; it never decides "what" or "when". The planner
(eco_planner.as) decides those and crosses into here through Place,
NanoTask, CanPlace, CanPlaceTurret and BaseCentre only.

When the box cannot be planned (no candidate reaches LayoutBoxMinScore) the
economy is placed around the factory nanos with a short shake; that fallback
is logged once at level 1 and is the only case in which a TECH economy
structure is placed by the spiral.

******************************************************************************/
namespace Layout {

    const string FACTORY_ROOT = "tech.factory.start";
    const string BOX = "tech.box";

    bool planned = false;
    bool fallback = false;
    int facing = 0;
    bool fallbackLogged = false;

    // The box, mirrored in native layout ints (tech.box.*) for save/load.
    int boxZone = 0;
    int nanoGroup = 0;
    int boxAcross = 0;   // cells
    int boxDepth = 0;    // cells
    int boxRows = 0;
    array<int> overflowSupportGroups;
    int overflowSupportSearchFrame = -100000;
    array<int> extraZones;      // D-072: boxes grown behind the first when it was full
    int labSlot = -1;           // D-085: the advanced lab's footprint, reserved at the seed side of the block when the box is planned
    int fwdZone = 0;            // D-081: the forward cluster's zone, its own turret group
    int fwdGroup = 0;
    AIFloat3 fwdCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
    int fwdDepth = 0;
    int fwdReplans = 0;         // times an ally took its ground and it moved on
    int fwdCheckFrame = -100000;
    int fwdTryFrame = -100000;
    AIFloat3 lastBoxCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
    int lastBoxDepth = 0;
    AIFloat3 boxCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
    AIFloat3 factoryCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
    int pairHalfSpanCells = 0;   // D-082: half the pair's extent across the facing, in cells

    CCircuitDef@ nano;

    bool HasComplex()
    {
        return planned && !fallback && aiTerrainMgr.IsLayoutEnabled();
    }

    bool HasBox()
    {
        return HasComplex() && boxZone > 0 && nanoGroup > 0;
    }

    bool Enable(bool on)
    {
        const bool enabled = aiTerrainMgr.SetLayoutEnabled(on);
        GenericHelpers::LogUtil("[Layout] " + (enabled ? "on" : "off") + " for this AI"
            + (on && !enabled ? " (JSON gate is closed)" : ""), 1);
        return enabled;
    }

    void ClearScriptState()
    {
        CompactEco::Clear();
        planned = false;
        fallback = false;
        facing = 0;
        fallbackLogged = false;
        boxZone = 0;
        nanoGroup = 0;
        boxAcross = 0;
        boxDepth = 0;
        boxRows = 0;
        boxCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
        factoryCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
        @nano = null;
        extraZones.resize(0);
        lastBoxCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
        lastBoxDepth = 0;
    }

    void OnRoleLeave()
    {
        @Global::energyAllowed = null;   // D-077: TECH's energy veto must not follow the AI into another role
        homeCentre = AIFloat3(-1.0f, 0.0f, -1.0f); labSlot = -1;   // D-085/D-086
        if (!planned && !aiTerrainMgr.IsLayoutEnabled()) return;
        aiTerrainMgr.ResetLayout();
        aiTerrainMgr.SetLayoutEnabled(false);
        ClearScriptState();
        GenericHelpers::LogUtil("[Layout] cleared for a role switch", 1);
    }

    // Native's facing convention (ReserveGridEx): SOUTH 0 +z, EAST 1 +x, NORTH 2 -z, WEST 3 -x.
    AIFloat3 Fwd(int f)
    {
        if (f == 1) return AIFloat3(1.0f, 0.0f, 0.0f);
        if (f == 2) return AIFloat3(0.0f, 0.0f, -1.0f);
        if (f == 3) return AIFloat3(-1.0f, 0.0f, 0.0f);
        return AIFloat3(0.0f, 0.0f, 1.0f);
    }

    AIFloat3 Side(int f)
    {
        if (f == 1) return AIFloat3(0.0f, 0.0f, -1.0f);
        if (f == 2) return AIFloat3(-1.0f, 0.0f, 0.0f);
        if (f == 3) return AIFloat3(0.0f, 0.0f, 1.0f);
        return AIFloat3(1.0f, 0.0f, 0.0f);
    }

    // Footprint extent along the facing (cells), across it.
    int Along(const CCircuitDef@ def, int f)
    {
        return ((f & 1) == 1) ? def.GetFootprintX() : def.GetFootprintZ();
    }

    int Across(const CCircuitDef@ def, int f)
    {
        return ((f & 1) == 1) ? def.GetFootprintZ() : def.GetFootprintX();
    }

    bool ResolveDefs(const string& in side)
    {
        @nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
        return nano !is null;
    }

    // ---------------------------------------------------------------- adoption (save/load)

    bool Adopt(const string& in side)
    {
        if (!aiTerrainMgr.HasLayoutGroup(FACTORY_ROOT + ".t1.nano")) return false;
        if (!ResolveDefs(side)) return false;
        planned = true;
        fallback = false;
        facing = aiTerrainMgr.GetLayoutInt(FACTORY_ROOT + ".facing", 0);
        boxZone = aiTerrainMgr.GetLayoutInt(BOX + ".zone", 0);
        nanoGroup = aiTerrainMgr.GetLayoutInt(BOX + ".nano_group", 0);
        boxAcross = aiTerrainMgr.GetLayoutInt(BOX + ".across", 0);
        boxDepth = aiTerrainMgr.GetLayoutInt(BOX + ".depth", 0);
        boxRows = aiTerrainMgr.GetLayoutInt(BOX + ".rows", 0);
        boxCentre = AIFloat3(float(aiTerrainMgr.GetLayoutInt(BOX + ".centre_x", -1)), 0.0f,
            float(aiTerrainMgr.GetLayoutInt(BOX + ".centre_z", -1)));
        factoryCentre = AIFloat3(float(aiTerrainMgr.GetLayoutInt(BOX + ".factory_x", -1)), 0.0f,
            float(aiTerrainMgr.GetLayoutInt(BOX + ".factory_z", -1)));
        extraZones.resize(0);
        const int extra = aiTerrainMgr.GetLayoutInt(BOX + ".extra_count", 0);
        for (int i = 0; i < extra; ++i) extraZones.insertLast(aiTerrainMgr.GetLayoutInt(BOX + ".extra" + i, 0));
        lastBoxCentre = AIFloat3(float(aiTerrainMgr.GetLayoutInt(BOX + ".last_x", int(boxCentre.x))), 0.0f,
            float(aiTerrainMgr.GetLayoutInt(BOX + ".last_z", int(boxCentre.z))));
        lastBoxDepth = aiTerrainMgr.GetLayoutInt(BOX + ".last_depth", boxDepth);
        labSlot = aiTerrainMgr.GetLayoutInt(BOX + ".lab_slot", -1);
        fwdZone = aiTerrainMgr.GetLayoutInt(BOX + ".fwd_zone", 0);
        fwdGroup = aiTerrainMgr.GetLayoutInt(BOX + ".fwd_group", 0);
        fwdCentre = AIFloat3(float(aiTerrainMgr.GetLayoutInt(BOX + ".fwd_x", -1)), 0.0f, float(aiTerrainMgr.GetLayoutInt(BOX + ".fwd_z", -1)));
        fwdDepth = aiTerrainMgr.GetLayoutInt(BOX + ".fwd_depth", 0);
        fwdReplans = aiTerrainMgr.GetLayoutInt(BOX + ".fwd_replans", 0);
        overflowSupportGroups.resize(0);
        const int overflowCount = aiTerrainMgr.GetLayoutInt(BOX + ".overflow_count", 0);
        for (int index = 0; index < overflowCount; ++index)
            overflowSupportGroups.insertLast(aiTerrainMgr.GetLayoutInt(BOX + ".overflow_group" + index, 0));
        string box = ", no turret box";
        if (HasBox()) {
            box = ", turret box zone " + boxZone + " " + boxAcross + "x" + boxDepth + " cells, "
                + boxRows + " rows, " + aiTerrainMgr.GetGroupCount(nanoGroup, false) + " turret slots";
        }
        GenericHelpers::LogUtil("[Layout] adopted restored native plan: facing " + facing + box, 1);
        return true;
    }

    // ---------------------------------------------------------------- the factory pair (D-060)

    array<int> SearchOffsets(int step, int tries)
    {
        array<int> result;
        result.reserve(uint(1 + tries * 2));
        result.insertLast(0);
        for (int i = 1; i <= tries; ++i) {
            result.insertLast(i * step);
            result.insertLast(-i * step);
        }
        return result;
    }

    bool PlanFactories(const string& in side)
    {
        CCircuitDef@ t1 = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(side));
        CCircuitDef@ t2 = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(side));
        if (t1 is null || t2 is null || nano is null) return false;
        const AIFloat3 base = Global::Map::StartPos;
        const AIFloat3 lane = aiSetupMgr.GetLanePos();
        const bool laneKnown = (lane.x > 0.0f || lane.z > 0.0f)
            && MapHelpers::SqDist(lane, base) > 100.0f * 100.0f;
        const int primary = LayoutHelpers::FacingToward(base, laneKnown ? lane : LayoutHelpers::TerrainCentre());
        const array<int> facings = { primary, (primary + 1) % 4, (primary + 3) % 4 };
        const array<int>@ sideOffsets = SearchOffsets(
            Global::RoleSettings::Tech::LayoutFactorySideStepCells,
            Global::RoleSettings::Tech::LayoutFactorySideTries);
        const array<int>@ forwardOffsets = SearchOffsets(
            Global::RoleSettings::Tech::LayoutFactoryForwardStepCells,
            Global::RoleSettings::Tech::LayoutFactoryForwardTries);
        for (uint fi = 0; fi < facings.length(); ++fi) {
            for (uint f = 0; f < forwardOffsets.length(); ++f) {
                for (uint s = 0; s < sideOffsets.length(); ++s) {
                    if (aiTerrainMgr.PlanFactoryPair(FACTORY_ROOT, t1, t2, nano, base,
                            facings[fi], sideOffsets[s], forwardOffsets[f])) {
                        facing = facings[fi];
                        GenericHelpers::LogUtil("[Layout] native factory pair committed facing " + facing
                            + ", side offset " + sideOffsets[s] + " cells, forward offset "
                            + forwardOffsets[f] + " cells", 1);
                        return true;
                    }
                }
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- the turret box (D-063)

    int NanoRows()
    {
        return (Global::Map::Config.TechLayoutNanoRows > 0)
            ? Global::Map::Config.TechLayoutNanoRows
            : Global::RoleSettings::Tech::LayoutBoxNanoRows;
    }

    // The centre of the pair's rear edge, nanos included: the line the box
    // touches. Both labs share one rear edge (native aligns them); the T2
    // block is two nano rows deep, the T1 block one.
    bool PairRear(const string& in side, AIFloat3 &out rearCentre)
    {
        CCircuitDef@ t1 = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(side));
        CCircuitDef@ t2 = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(side));
        const int t1Slot = aiTerrainMgr.GetLayoutInt(FACTORY_ROOT + ".t1_slot", -1);
        const int t2Slot = aiTerrainMgr.GetLayoutInt(FACTORY_ROOT + ".t2_slot", -1);
        if (t1 is null || t2 is null || nano is null || t1Slot < 0 || t2Slot < 0) return false;
        const AIFloat3 p1 = aiTerrainMgr.GetReservationPos(t1Slot);
        const AIFloat3 p2 = aiTerrainMgr.GetReservationPos(t2Slot);
        if (p1.x < 0.0f || p2.x < 0.0f) return false;
        const AIFloat3 fwd = Fwd(facing);
        const float cell = SQUARE_SIZE * 2;
        // The factory rear edges: centre minus half the depth along the facing.
        const AIFloat3 r1 = p1 - fwd * (float(Along(t1, facing)) * 0.5f * cell);
        const AIFloat3 r2 = p2 - fwd * (float(Along(t2, facing)) * 0.5f * cell);
        const AIFloat3 mid = (r1 + r2) * 0.5f;
        factoryCentre = (p1 + p2) * 0.5f;
        {
            const AIFloat3 sv = Side(facing);
            const float span = abs((p2.x - p1.x) * sv.x + (p2.z - p1.z) * sv.z);
            const int widest = (Across(t1, facing) > Across(t2, facing)) ? Across(t1, facing) : Across(t2, facing);
            pairHalfSpanCells = int(span / (SQUARE_SIZE * 2) * 0.5f) + (widest + 1) / 2;
        }
        // The deeper of the two nano blocks (T2: two rows) plus a one-cell gap.
        const int nanoRowsBehind = 2;
        rearCentre = mid - fwd * (float(nanoRowsBehind * Along(nano, facing) + 1) * cell);
        return true;
    }

    float BoxScore(const AIFloat3& in centre, int acrossCells, int depthCells)
    {
        const float halfAcross = float(acrossCells) * SQUARE_SIZE;   // cells * 16 / 2
        const float halfAlong = float(depthCells) * SQUARE_SIZE;
        const float flat = aiTerrainMgr.FlatFraction(centre, facing, halfAcross, halfAlong,
            Global::RoleSettings::Tech::LayoutBoxMaxSlope);
        const float buildable = aiTerrainMgr.BuildableFraction(nano, centre, halfAcross, halfAlong, facing);
        return flat * buildable;
    }

    // D-082: the ground the structures will stand on: the block plus a halo
    // of LayoutHaloCells on both sides and behind it (never in front: the
    // factory pair is there). Scored like the block; the zone is reserved
    // with it, so converters, fusions and labs pack around the block within
    // a turret's reach instead of in a strip behind the rows.
    AIFloat3 HaloCentre(const AIFloat3& in blockCentre)
    {
        return blockCentre - Fwd(facing) * (float(Global::RoleSettings::Tech::LayoutHaloCells) * 0.5f * SQUARE_SIZE * 2);
    }
    float HaloHalfAcross(int acrossCells) { return float(acrossCells + 2 * Global::RoleSettings::Tech::LayoutHaloCells) * SQUARE_SIZE; }
    float HaloHalfAlong(int depthCells) { return float(depthCells + Global::RoleSettings::Tech::LayoutHaloCells) * SQUARE_SIZE; }
    float HaloScore(const AIFloat3& in blockCentre, int acrossCells, int depthCells)
    {
        const AIFloat3 c = HaloCentre(blockCentre);
        const float flat = aiTerrainMgr.FlatFraction(c, facing, HaloHalfAcross(acrossCells), HaloHalfAlong(depthCells),
            Global::RoleSettings::Tech::LayoutBoxMaxSlope);
        const float buildable = aiTerrainMgr.BuildableFraction(nano, c, HaloHalfAcross(acrossCells), HaloHalfAlong(depthCells), facing);
        return flat * buildable;
    }

    // D-083: is p inside the block rectangle (plus margin cells) centred on centre?
    bool InBlock(const AIFloat3& in centre, int acrossCells, int depthCells, const AIFloat3& in p, int marginCells)
    {
        if (p.x < 0.0f) return false;
        const AIFloat3 d = p - centre;
        const AIFloat3 f = Fwd(facing), s = Side(facing);
        const float along = abs(d.x * f.x + d.z * f.z);
        const float across = abs(d.x * s.x + d.z * s.z);
        const float cell = SQUARE_SIZE * 2;
        return along <= (float(depthCells) * 0.5f + float(marginCells)) * cell && across <= (float(acrossCells) * 0.5f + float(marginCells)) * cell;
    }

    // D-094: the turret rows of a box, one band per row from `front` backwards,
    // NanoRows() of them while they fit in depthCells, touching when
    // LayoutTurretBlock (D-081) else a shelf apart. The bands join `groupIn`
    // (0 = a new group); the group comes back in groupOut. Returns the rows laid.
    int LayRows(int zone, const AIFloat3& in front, int acrossCells, int depthCells, int groupIn, int &out groupOut)
    {
        const AIFloat3 fwd = Fwd(facing);
        const float cell = SQUARE_SIZE * 2;
        const int nanoAlong = Along(nano, facing);
        const int nanoAcross = Across(nano, facing);
        const int pitch = Global::RoleSettings::Tech::LayoutTurretBlock ? nanoAlong
            : (Global::RoleSettings::Tech::LayoutBoxShelfCells + nanoAlong);
        const int cols = (nanoAcross > 0) ? acrossCells / nanoAcross : 0;
        groupOut = groupIn;
        int rows = 0;
        for (int row = 0; row < NanoRows(); ++row) {
            if (row * pitch + nanoAlong > depthCells) break;   // the rows first; the shelf is what is left behind them
            const AIFloat3 rowFront = front - fwd * (float(row * pitch) * cell);
            const int g = aiTerrainMgr.LayBand(zone, nano, rowFront, facing, cols, 1, 0, false, true, false, groupOut);
            if (g > 0) groupOut = g;
            ++rows;
        }
        return rows;
    }

    // D-087/D-094: the one rule every box search ranks by. A candidate whose
    // halo scores LayoutHaloMin is good enough, and among good-enough ones the
    // nearer (`dist`, in the caller's own units) wins, the halo breaking ties;
    // while none is good enough the better halo wins, the nearer breaking ties.
    bool BetterBox(float halo, float dist, float bestHalo, float bestDist)
    {
        const float hmin = Global::RoleSettings::Tech::LayoutHaloMin;
        const bool ok = halo >= hmin, bestOk = bestHalo >= hmin;
        if (ok != bestOk) return ok;
        if (ok) return dist < bestDist || (dist == bestDist && halo > bestHalo);
        return halo > bestHalo || (halo == bestHalo && dist < bestDist);
    }

    // D-094: order the advanced lab on a reserved footprint, pinned. On failure
    // the reservation is released when the caller asks (a fresh search), kept
    // otherwise (the footprint planned at box time).
    IUnitTask@ OrderLabOn(CCircuitDef@ t2, int slot, int timeout, bool releaseOnFail, const string &in how)
    {
        const AIFloat3 p = aiTerrainMgr.GetReservationPos(slot);
        if (p.x < 0.0f) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, t2, p, null, 0.0f, false, true, timeout));
        if (t is null) {
            if (releaseOnFail) aiTerrainMgr.ReleaseReservation(slot);
            return null;
        }
        if (!AiPinReservation(t, slot)) {
            GenericHelpers::LogUtil("[Layout] could not pin the advanced lab to slot " + slot, 1);
            // Abort only this task; a failed claim may be owned by another task.
            aiBuilderMgr.AbortTask(t);
            return null;
        }
        aiTerrainMgr.SetLayoutInt(BOX + ".lab_facing", aiTerrainMgr.GetReservationFacing(slot));   // D-098
        aiTerrainMgr.SetLayoutInt(BOX + ".ordered_lab_x", int(p.x));
        aiTerrainMgr.SetLayoutInt(BOX + ".ordered_lab_z", int(p.z));
        aiTerrainMgr.SetLayoutInt(BOX + ".ordered_lab_gap", slot == labSlot
            ? Global::RoleSettings::Tech::LayoutLabFrontGapCells : 1);
        Builder::MarkT2BotFactoryEnqueued();
        GenericHelpers::LogUtil("[Layout] advanced lab " + how + " (" + int(p.x) + ", " + int(p.z) + "): "
            + aiTerrainMgr.CountGroupSlotsWithin(nanoGroup, p, Global::RoleSettings::Tech::ExpLabBuildPowerReach) + " turret slots within "
            + int(Global::RoleSettings::Tech::ExpLabBuildPowerReach), 1);
        return t;
    }

    bool PlanBox(const string& in side)
    {
        AIFloat3 front;
        if (!PairRear(side, front)) {
            GenericHelpers::LogUtil("[Layout] turret box: the factory pair's rear line is unknown", 1);
            return false;
        }
        // D-083 (owner's rule): the main cluster is centred on the start, the
        // home mexes around it, or slightly offset; the base does not spread
        // to wherever the pair happened to be committed
        const bool atStart = Global::RoleSettings::Tech::LayoutBoxAtStart;
        const AIFloat3 anchor = atStart ? HomeCentre() : front;   // D-086: centred on the home mexes
        AIFloat3 pairA(-1.0f, 0.0f, -1.0f), pairB(-1.0f, 0.0f, -1.0f);
        {
            const int t1Slot = aiTerrainMgr.GetLayoutInt(FACTORY_ROOT + ".t1_slot", -1);
            const int t2Slot = aiTerrainMgr.GetLayoutInt(FACTORY_ROOT + ".t2_slot", -1);
            if (t1Slot >= 0) pairA = aiTerrainMgr.GetReservationPos(t1Slot);
            if (t2Slot >= 0) pairB = aiTerrainMgr.GetReservationPos(t2Slot);
        }
        const AIFloat3 fwd = Fwd(facing);
        const AIFloat3 sideVec = Side(facing);
        const float cell = SQUARE_SIZE * 2;
        const int fullAcross = Global::RoleSettings::Tech::LayoutBoxAcrossCells;
        const int fullDepth = Global::RoleSettings::Tech::LayoutBoxDepthCells;
        const int shrink = Global::RoleSettings::Tech::LayoutBoxShrinkCells;
        const int minAcross = Global::RoleSettings::Tech::LayoutBoxMinAcrossCells;
        const int minDepth = Global::RoleSettings::Tech::LayoutBoxMinDepthCells;
        const array<int>@ sideOffsets = SearchOffsets(
            Global::RoleSettings::Tech::LayoutBoxSideStepCells,
            Global::RoleSettings::Tech::LayoutBoxSideTries);
        const int rearStep = Global::RoleSettings::Tech::LayoutBoxRearStepCells;
        const int rearTries = Global::RoleSettings::Tech::LayoutBoxRearTries;
        const float minScore = Global::RoleSettings::Tech::LayoutBoxMinScore;

        // Largest box first; a size is accepted when its best candidate
        // clears the score. Rows shrink only after the width has.
        for (int depth = fullDepth; depth >= minDepth; depth -= shrink) {
            for (int across = fullAcross; across >= minAcross; across -= shrink) {
                float best = -1.0f;      // the block's own score of the chosen candidate
                float bestHalo = -1.0f;  // D-082: candidates whose block clears the floor are ranked by the halo
                AIFloat3 bestCentre;
                int bestSide = 0, bestRear = 0;
                // D-082: the box may stand beside the pair, level with it or ahead of its
                // rear line (negative rear), when the side offset clears the pair's span;
                // so a pair with a mountain behind it gets its block in the open
                const int besideMin = pairHalfSpanCells + across / 2 + Global::RoleSettings::Tech::LayoutBoxBesideClearCells;
                float bestDist = 1.0e9f;
                for (int r = -Global::RoleSettings::Tech::LayoutBoxForwardTries; r <= rearTries; ++r) {
                    const int rear = r * rearStep;
                    for (uint s = 0; s < sideOffsets.length(); ++s) {
                        if (!atStart && rear < 0 && abs(sideOffsets[s]) < besideMin) continue;
                        const AIFloat3 centre = atStart
                            ? anchor - fwd * (float(rear) * cell) + sideVec * (float(sideOffsets[s]) * cell)
                            : front - fwd * (float(rear) * cell + float(depth) * 0.5f * cell) + sideVec * (float(sideOffsets[s]) * cell);
                        // never over a pair factory slot: the block would have holes and the lab no exit
                        if (atStart && (InBlock(centre, across, depth, pairA, Global::RoleSettings::Tech::LayoutBoxPairClearCells)
                                     || InBlock(centre, across, depth, pairB, Global::RoleSettings::Tech::LayoutBoxPairClearCells))) continue;
                        const float score = BoxScore(centre, across, depth);
                        if (score < minScore) continue;
                        const float halo = HaloScore(centre, across, depth);
                        const float dist = float(abs(sideOffsets[s]) + abs(rear));
                        if (BetterBox(halo, dist, bestHalo, bestDist)) {   // D-087 via D-094
                            bestDist = dist;
                            best = score; bestHalo = halo;
                            bestCentre = centre;
                            bestSide = sideOffsets[s];
                            bestRear = rear;
                        }
                    }
                }
                if (best < minScore) {
                    GenericHelpers::LogUtil("[Layout] turret box " + across + "x" + depth
                        + " cells: best ground scores " + int(best * 100.0f) + "%, under "
                        + int(minScore * 100.0f) + "%", 2);
                    continue;
                }
                const int zone = aiTerrainMgr.ReserveZone(HaloCentre(bestCentre), facing,
                    HaloHalfAcross(across), HaloHalfAlong(depth), false);   // D-082: the block and its halo
                if (zone == 0) continue;
                boxZone = zone;
                boxAcross = across;
                boxDepth = depth;
                boxCentre = bestCentre;
                lastBoxCentre = bestCentre;
                lastBoxDepth = depth;
                aiTerrainMgr.SetLayoutInt(BOX + ".last_x", int(bestCentre.x));
                aiTerrainMgr.SetLayoutInt(BOX + ".last_z", int(bestCentre.z));
                aiTerrainMgr.SetLayoutInt(BOX + ".last_depth", depth);
                // Turret rows: the first touches the pair's nanos, then one every
                // shelf plus a turret depth, as many as the depth holds. Each
                // slot is laid on its own: refused ground is a hole, not a veto.
                const int cols = (Across(nano, facing) > 0) ? across / Across(nano, facing) : 0;
                const AIFloat3 boxFront = bestCentre + fwd * (float(depth) * 0.5f * cell);
                int laidGroup = 0;
                const int rows = LayRows(zone, boxFront, across, depth, nanoGroup, laidGroup);   // D-081 via D-094
                nanoGroup = laidGroup;
                boxRows = rows;
                if (rows < Global::RoleSettings::Tech::LayoutBoxMinRows)
                    Invariants::Violation("INV-012", "box", "the main turret cluster has " + rows + " rows, under " + Global::RoleSettings::Tech::LayoutBoxMinRows);
                const int slots = (nanoGroup > 0) ? aiTerrainMgr.GetGroupCount(nanoGroup, false) : 0;
                aiTerrainMgr.SetLayoutInt(BOX + ".zone", boxZone);
                aiTerrainMgr.SetLayoutInt(BOX + ".nano_group", nanoGroup);
                aiTerrainMgr.SetLayoutInt(BOX + ".across", boxAcross);
                aiTerrainMgr.SetLayoutInt(BOX + ".depth", boxDepth);
                aiTerrainMgr.SetLayoutInt(BOX + ".rows", boxRows);
                aiTerrainMgr.SetLayoutInt(BOX + ".centre_x", int(boxCentre.x));
                aiTerrainMgr.SetLayoutInt(BOX + ".centre_z", int(boxCentre.z));
                aiTerrainMgr.SetLayoutInt(BOX + ".factory_x", int(factoryCentre.x));
                aiTerrainMgr.SetLayoutInt(BOX + ".factory_z", int(factoryCentre.z));
                GenericHelpers::LogUtil("[Layout] turret box " + across + "x" + depth + " cells at ("
                    + int(bestCentre.x) + ", " + int(bestCentre.z) + "), " + (atStart ? "from the start " : "") + "rear " + bestRear + ", side " + bestSide
                    + ", ground " + int(best * 100.0f) + "%, halo " + int(bestHalo * 100.0f) + "%: zone " + zone + ", " + rows + " rows, "
                    + slots + " of " + (rows * cols) + " turret slots", 1);
                // D-085: the advanced lab's footprint is reserved now, on empty ground,
                // at the seed side of the block where the most of the first turrets
                // reach it and its exit is clear (played: by the time the lab was
                // ordered the opening's turbines had taken that ground and no site
                // with a clear exit was left near the seed)
                {
                    CCircuitDef@ t2 = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(side));
                    if (t2 !is null) {
                        // D-096 (owner's rule, replaces D-088's any facing): the lab faces the
                        // front (LabFacing), else one of the two facings beside it, never away;
                        // within a facing the site ahead of the block, flush, nearest the home
                        // centre (PickMost). Played: a lab facing into its own turrets, then
                        // walled in by windmills.
                        const AIFloat3 home = HomeCentre();
                        const float flush = Global::RoleSettings::Tech::LayoutLabFlushElmos;
                        const array<int>@ labFacings = LabFacings();
                        int bestF = -1;
                        // D-096: the front line first, when the block itself faces the front
                        labSlot = (LabFacing() == facing) ? ReserveFrontLab(t2, boxFront, across) : -1;
                        if (labSlot >= 0) bestF = facing;
                        for (uint fi = 0; fi < labFacings.length() && bestF < 0; ++fi) {
                            AIFloat3 p;
                            const int s = aiTerrainMgr.PickMost(zone, t2, nanoGroup, labFacings[fi], Global::RoleSettings::Tech::ExpLabBuildPowerReach, flush, home, p);
                            if (s >= Global::RoleSettings::Tech::LayoutLabMinSlots) bestF = labFacings[fi];
                        }
                        const AIFloat3 ft = FrontTarget();
                        const AIFloat3 ln = aiSetupMgr.GetLanePos();
                        GenericHelpers::LogUtil("[Layout] the front is (" + int(ft.x) + ", " + int(ft.z) + "): the labs face " + LabFacing()
                            + " (lane (" + int(ln.x) + ", " + int(ln.z) + "), the pair faces " + facing + ")", 1);
                        if (labSlot < 0) labSlot = (bestF < 0) ? -1 : aiTerrainMgr.PackNearGroupMost(zone, t2, nanoGroup, bestF, Global::RoleSettings::Tech::ExpLabBuildPowerReach, flush, 0, home);
                        if (labSlot >= 0) GenericHelpers::LogUtil("[Layout] advanced lab faces " + bestF + " (the pair faces " + facing + ")", 1);
                        aiTerrainMgr.SetLayoutInt(BOX + ".lab_slot", labSlot);
                        if (labSlot >= 0) {
                            const AIFloat3 lp = aiTerrainMgr.GetReservationPos(labSlot);
                            GenericHelpers::LogUtil("[Layout] advanced lab's footprint reserved at (" + int(lp.x) + ", " + int(lp.z) + "), "
                                + int(sqrt(MapHelpers::SqDist(lp, HomeCentre()))) + " from the home centre, " + aiTerrainMgr.CountGroupSlotsWithin(nanoGroup, lp, Global::RoleSettings::Tech::ExpLabBuildPowerReach) + " turret slots within reach, "
                                + aiTerrainMgr.CountGroupSlotsWithin(nanoGroup, lp, flush) + " flush (D-095)", 1);
                        } else GenericHelpers::LogUtil("[Layout] no footprint for the advanced lab in the block's halo at plan time", 1);
                    }
                }
                PlanForwardBox();   // D-081: at least one cluster forward in clear space
                return slots > 0;
            }
        }
        return false;
    }

    // D-072: when the box is full, another box of the same width directly
    // behind the last one, with its own turret rows in the same group, so
    // energy, converters, fusions and labs stay tight to the turret cluster
    // instead of scattering around the base centre.
    int growFailFrame = -100000;
    bool GrowBox()
    {
        if (!HasBox() || lastBoxCentre.x < 0.0f || nano is null) return false;
        if (int(extraZones.length()) >= Global::RoleSettings::Tech::LayoutBoxMaxExtra) return false;
        if (ai.frame - growFailFrame < 60 * SECOND) return false;   // a failed search is not repeated every ask
        const AIFloat3 fwd = Fwd(facing);
        const AIFloat3 sideVec = Side(facing);
        const float cell = SQUARE_SIZE * 2;
        const int across = boxAcross;
        const int shrink = Global::RoleSettings::Tech::LayoutBoxShrinkCells;
        const int minDepth = Global::RoleSettings::Tech::LayoutBoxMinDepthCells;
        const float minScore = Global::RoleSettings::Tech::LayoutBoxMinScore;
        // behind the last box first; then beside the first box on either hand
        // (played: the ground behind the base on Supreme Isthmus scored under
        // the floor and the base scattered); the best ground wins
        const AIFloat3 rearFront = lastBoxCentre - fwd * (float(lastBoxDepth) * 0.5f * cell);
        const AIFloat3 firstFront = boxCentre + fwd * (float(boxDepth) * 0.5f * cell);
        for (int depth = Global::RoleSettings::Tech::LayoutBoxDepthCells; depth >= minDepth; depth -= shrink) {
            array<AIFloat3> fronts = { rearFront, firstFront + sideVec * (float(across) * cell), firstFront - sideVec * (float(across) * cell) };
            array<string> names = { "behind", "beside (right)", "beside (left)" };
            float best = -1.0f; float bestHalo = -1.0f; float bestDist = 1.0e9f; int bestIdx = -1; AIFloat3 bestCentre;
            for (uint i = 0; i < fronts.length(); ++i) {
                const AIFloat3 centre = fronts[i] - fwd * (float(depth) * 0.5f * cell);
                const float score = BoxScore(centre, across, depth);
                if (score < minScore) continue;
                const float halo = HaloScore(centre, across, depth);   // D-082
                // D-094: the same rule as PlanBox, nearness measured to the home centre
                const float dist = sqrt(MapHelpers::SqDist(centre, HomeCentre()));
                if (BetterBox(halo, dist, bestHalo, bestDist)) { best = score; bestHalo = halo; bestDist = dist; bestIdx = int(i); bestCentre = centre; }
            }
            if (bestIdx < 0) continue;
            const int zone = aiTerrainMgr.ReserveZone(HaloCentre(bestCentre), facing, HaloHalfAcross(across), HaloHalfAlong(depth), false);
            if (zone == 0) continue;
            const AIFloat3 front = fronts[bestIdx];
            int laidGroup = 0;
            const int previousSlots = nanoGroup > 0 ? aiTerrainMgr.GetGroupCount(nanoGroup, false) : 0;
            const int rows = LayRows(zone, front, across, depth, nanoGroup, laidGroup);   // D-081 via D-094
            if (laidGroup <= 0 || aiTerrainMgr.GetGroupCount(laidGroup, false) <= previousSlots) {
                aiTerrainMgr.ReleaseZone(zone);
                continue; // A reserved rectangle without support is not capacity.
            }
            nanoGroup = laidGroup;
            extraZones.insertLast(zone);
            if (bestIdx == 0) { lastBoxCentre = bestCentre; lastBoxDepth = depth; }
            aiTerrainMgr.SetLayoutInt(BOX + ".extra_count", int(extraZones.length()));
            aiTerrainMgr.SetLayoutInt(BOX + ".extra" + (extraZones.length() - 1), zone);
            aiTerrainMgr.SetLayoutInt(BOX + ".last_x", int(lastBoxCentre.x));
            aiTerrainMgr.SetLayoutInt(BOX + ".last_z", int(lastBoxCentre.z));
            aiTerrainMgr.SetLayoutInt(BOX + ".last_depth", lastBoxDepth);
            aiTerrainMgr.SetLayoutInt(BOX + ".nano_group", nanoGroup);
            GenericHelpers::LogUtil("[Layout] turret box full: grown " + names[bestIdx] + " by " + across + "x" + depth + " cells at ("
                + int(bestCentre.x) + ", " + int(bestCentre.z) + "), ground " + int(best * 100.0f) + "%: zone " + zone + ", " + rows
                + " turret rows (box " + (extraZones.length() + 1) + ")", 1);
            return true;
        }
        growFailFrame = ai.frame;
        GenericHelpers::LogUtil("[Layout] turret box full and no ground behind or beside it scores " + int(minScore * 100.0f) + "%; retried in a minute", 1);
        return false;
    }

    // D-081 (owner's rule): at least one cluster forward of the main one, in
    // clear space, its turret rows in their own group so it fills after the
    // main block and can be given up. An ally taking its ground (native's
    // ally zone around allied builder structures) moves it further forward,
    // LayoutForwardTries times.
    bool PlanForwardBox()
    {
        if (!HasBox() || nano is null || fwdZone != 0) return false;
        if (fwdReplans >= Global::RoleSettings::Tech::LayoutForwardTries) {
            // A finite search can be blocked by an allied structure or wreck.
            // Reconsider it at a bounded interval; never retry on every builder
            // ask or permanently give up after the original obstruction clears.
            if (ai.frame - fwdTryFrame < int(Global::RoleSettings::Tech::LayoutForwardBlockedRetrySeconds) * SECOND) return false;
            fwdReplans = 0;
            aiTerrainMgr.SetLayoutInt(BOX + ".fwd_replans", 0);
        }
        if (ai.frame - fwdTryFrame < int(Global::RoleSettings::Tech::LayoutForwardRetrySeconds) * SECOND) return false;
        fwdTryFrame = ai.frame;
        const AIFloat3 fwd = Fwd(facing);
        const AIFloat3 sideVec = Side(facing);
        const float cell = SQUARE_SIZE * 2;
        const int across = boxAcross;
        const int shrink = Global::RoleSettings::Tech::LayoutBoxShrinkCells;
        const int minDepth = Global::RoleSettings::Tech::LayoutBoxMinDepthCells;
        const float minScore = Global::RoleSettings::Tech::LayoutBoxMinScore;
        const int ahead = Global::RoleSettings::Tech::LayoutForwardGapCells + fwdReplans * Global::RoleSettings::Tech::LayoutForwardStepCells;
        const AIFloat3 boxFront = boxCentre + fwd * (float(boxDepth) * 0.5f * cell);
        const AIFloat3 front = boxFront + fwd * (float(ahead) * cell);
        for (int depth = Global::RoleSettings::Tech::LayoutBoxDepthCells; depth >= minDepth; depth -= shrink) {
            array<AIFloat3> fronts = { front, front + sideVec * (float(across) * 0.5f * cell), front - sideVec * (float(across) * 0.5f * cell) };
            float best = -1.0f; int bestIdx = -1; AIFloat3 bestCentre;
            for (uint i = 0; i < fronts.length(); ++i) {
                const AIFloat3 centre = fronts[i] + fwd * (float(depth) * 0.5f * cell);
                if (aiTerrainMgr.IsZoneAlly(centre)) continue;   // an ally's ground
                const float score = BoxScore(centre, across, depth);
                if (score >= minScore && score > best) { best = score; bestIdx = int(i); bestCentre = centre; }
            }
            if (bestIdx < 0) continue;
            const int nanoAlong = Along(nano, facing);
            const int nanoAcross = Across(nano, facing);
            const int rowsFit = (nanoAlong > 0) ? depth / nanoAlong : 0;
            if (rowsFit < Global::RoleSettings::Tech::LayoutBoxMinRows) continue;
            const int zone = aiTerrainMgr.ReserveZone(bestCentre, facing, float(across) * SQUARE_SIZE, float(depth) * SQUARE_SIZE, false);
            if (zone == 0) continue;
            const int cols = (nanoAcross > 0) ? across / nanoAcross : 0;
            const AIFloat3 zoneFront = fronts[bestIdx] + fwd * (float(depth) * cell);
            int group = 0;
            const int rows = LayRows(zone, zoneFront, across, depth, 0, group);   // D-081 via D-094 (now honours LayoutTurretBlock)
            if (group <= 0 || aiTerrainMgr.GetGroupCount(group, false) == 0) {
                aiTerrainMgr.ReleaseZone(zone);
                continue;
            }
            fwdZone = zone; fwdGroup = group; fwdCentre = bestCentre; fwdDepth = depth;
            aiTerrainMgr.SetLayoutInt(BOX + ".fwd_zone", fwdZone);
            aiTerrainMgr.SetLayoutInt(BOX + ".fwd_group", fwdGroup);
            aiTerrainMgr.SetLayoutInt(BOX + ".fwd_x", int(fwdCentre.x));
            aiTerrainMgr.SetLayoutInt(BOX + ".fwd_z", int(fwdCentre.z));
            aiTerrainMgr.SetLayoutInt(BOX + ".fwd_depth", fwdDepth);
            aiTerrainMgr.SetLayoutInt(BOX + ".fwd_replans", fwdReplans);
            GenericHelpers::LogUtil("[Layout] forward cluster " + across + "x" + depth + " cells at (" + int(bestCentre.x) + ", " + int(bestCentre.z)
                + "), " + ahead + " cells ahead of the main cluster, ground " + int(best * 100.0f) + "%: zone " + zone + ", " + rows + " rows, "
                + ((group > 0) ? aiTerrainMgr.GetGroupCount(group, false) : 0) + " turret slots" + (fwdReplans > 0 ? " (re-plan " + fwdReplans + ")" : ""), 1);
            return true;
        }
        ++fwdReplans;
        aiTerrainMgr.SetLayoutInt(BOX + ".fwd_replans", fwdReplans);
        GenericHelpers::LogUtil("[Layout] no clear ground for a forward cluster " + ahead + " cells ahead; attempt "
            + fwdReplans + "/" + Global::RoleSettings::Tech::LayoutForwardTries
            + (ForwardGivenUp() ? "; state=blocked; bounded retry pending" : "; state=searching; next candidate pending"), 1);
        return false;
    }

    // The forward cluster taken by an ally: given up and planned further on.
    void CheckForward(bool immediate = false)
    {
        if (!immediate && ai.frame - fwdCheckFrame < 10 * SECOND) return;
        fwdCheckFrame = ai.frame;
        if (fwdZone == 0) { PlanForwardBox(); return; }
        const int state = aiTerrainMgr.GetZoneActivationState(fwdZone);
        if (state == 2) aiTerrainMgr.SetLayoutInt(BOX + ".fwd_started", 1);
        if (aiTerrainMgr.GetLayoutInt(BOX + ".fwd_started", 0) != 0) return;
        // An economy box deliberately spans partly usable terrain (BoxScore).
        // Its existing holes are not new obstructions. A structure taking the
        // reserved cells triggers relocation; any claimed economy/nano locks it.
        if (aiTerrainMgr.IsZoneClear(fwdZone)) return;
        GenericHelpers::LogUtil("[Layout] forward cluster at (" + int(fwdCentre.x) + ", " + int(fwdCentre.z) + ") physically blocked before activation: recalculating", 1);
        if (fwdGroup > 0) aiTerrainMgr.ReleaseGroup(fwdGroup);
        aiTerrainMgr.ReleaseZone(fwdZone);
        fwdZone = 0; fwdGroup = 0; ++fwdReplans; fwdTryFrame = -100000;
        aiTerrainMgr.SetLayoutInt(BOX + ".fwd_zone", 0);
        aiTerrainMgr.SetLayoutInt(BOX + ".fwd_group", 0);
        aiTerrainMgr.SetLayoutInt(BOX + ".fwd_replans", fwdReplans);
        PlanForwardBox();
    }
    bool ForwardPlanned() { return fwdZone != 0; }
    bool ForwardGivenUp() { return fwdReplans >= Global::RoleSettings::Tech::LayoutForwardTries; }

    // Every box zone, the first first: the older box fills before the newer
    int ZoneCount() { return HasBox() ? 1 + int(extraZones.length()) : 0; }
    int ZoneAt(int i) { return (i == 0) ? boxZone : extraZones[i - 1]; }

    void Plan(const string& in side, bool sharedSequence = false)
    {
        if ((!sharedSequence && !Global::RoleSettings::Tech::ExperimentalBuild) || !Global::RoleSettings::Tech::LayoutEnabled || !Enable(true)) return;
        if (CompactEco::Active()) {
            // This map cannot fit the atomic pair. Keep the existing cramped
            // factory/exit policy, but give economy its own small pinned banks.
            ResolveDefs(side);
            fallback = true;
            CompactEco::Adopt();
            GenericHelpers::LogUtil("[Layout] compact economy enabled: adaptive single-footprint banks, up to "
                + (Global::RoleSettings::Tech::CompactEcoColumns * Global::RoleSettings::Tech::CompactEcoRows) + " turrets each", 1);
            return;
        }
        if (Adopt(side)) return;
        if (!ResolveDefs(side) || !PlanFactories(side)) {
            fallback = true;
            planned = false;
            // D-120: the reservation registry stays on. Every TECH placement
            // (the experimental build, D-066) goes through it; switched off, it
            // refused every site and TECH built nothing (played: Tundra
            // Continents, 4 units at 14 minutes). Only the planned pair and its
            // turret box are skipped: structures are packed near their builder
            GenericHelpers::LogUtil("[Layout] no atomic factory pair fits: no planned pair or turret box; structures are packed where the ground allows (D-120)", 1);
            return;
        }
        planned = true;
        fallback = false;
        if (!PlanBox(side)) {
            boxZone = 0;
            nanoGroup = 0;
            GenericHelpers::LogUtil("[Layout] no turret box fits behind the factory pair; the economy is placed around the factory nanos", 1);
        }
    }

    void Update(float metalIncome, bool t2LabStands, int t2ConstructorCount)
    {
        LayoutHelpers::CheckAlliedPlacements();
        if (!planned && aiTerrainMgr.IsLayoutEnabled()) {
            Adopt(Global::AISettings::Side);
        } else if (planned) {
            facing = aiTerrainMgr.GetLayoutInt(FACTORY_ROOT + ".facing", facing);
        }
        if (planned && HasBox()) CheckForward();   // D-081
        if (planned && HasBox()) RegisterFactoryZones();   // D-104
    }

    // ---------------------------------------------------------------- queries for the planner

    // The centre of the planned base: the turret box, else the factory nanos,
    // else the start. The planner measures build power around it.
    AIFloat3 BaseCentre()
    {
        if (HasBox()) return boxCentre;
        return FactoryNanoCentre();
    }

    AIFloat3 FactoryNanoCentre()
    {
        const AIFloat3 center = aiTerrainMgr.GetLayoutGroupCenter(FACTORY_ROOT + ".t1.nano");
        return (center.x >= 0.0f && center.z >= 0.0f) ? center : Global::Map::StartPos;
    }

    // Is there a planned turret slot left: a completed factory's rear slot
    // or a box slot? The planner asks before it names a turret.
    bool CanPlaceTurret()
    {
        if (CompactEco::Active()) return true; // admission only; placement checks reach and capacity
        if (fallback && aiTerrainMgr.IsLayoutEnabled()) return true;   // D-121: cramped ground: CrampedNanoTask decides how many
        if (!HasComplex()) return false;
        if (aiTerrainMgr.GetFactoryNanoAvailable() > 0) return true;
        return HasBox() && (aiTerrainMgr.GetGroupCount(nanoGroup, true) > 0 || (fwdGroup > 0 && aiTerrainMgr.GetGroupCount(fwdGroup, true) > 0));
    }

    // ---------------------------------------------------------------- placement

    // A structure that kills the turrets next to it when it dies keeps this
    // distance from every turret slot (knowledge base: an advanced converter
    // kills a nano within 173 elmos, a fusion within 379). The defaults are 0:
    // the owner chose density and shared build power over firebreaks.
    float MinNanoDist(const CCircuitDef@ def)
    {
        if (def is null) return 0.0f;
        const string name = def.GetName();
        const string side = Global::AISettings::Side;
        if (name == UnitHelpers::GetAdvEnergyConverterNameForSide(side)) return Global::RoleSettings::Tech::LayoutConverterNanoGap;
        if (name == UnitHelpers::GetFusionNameForSide(side) || name == UnitHelpers::GetAdvFusionNameForSide(side)) return Global::RoleSettings::Tech::LayoutFusionNanoGap;
        return 0.0f;
    }

    // D-199: admission has always accepted every non-null definition: the
    // old probe's false result was unconditionally promoted to true because
    // Place may grow the box. Avoid that discarded search and its memo objects.
    // Actual placement retains every terrain, occupancy and reach check.
    // Admission is O(1); actual Place search is not. The original/optimized
    // predicate oracle lives in tools/knowledge/check_performance_policy.py.
    bool CanPlace(const CCircuitDef@ def)
    {
        return def !is null;
    }

    // Enqueue a structure on the box cells nearest to a turret, pinned to
    // that exact footprint. Null when nothing fits: the caller must not fall
    // back to the spiral (the walking cap, D-063).
    // D-108: a new set of def: the clusters' zones first (main, then forward),
    // then, when no zone has room, the ring round each zone within turret reach
    // (played: the converters filled every zone and the advanced fusions found no
    // site after six)
    int PackSetAnywhere(CCircuitDef@ def, const AIFloat3& in anchor, int setSize)
    {
        for (int pass = 0; pass < 2; ++pass) {
            const bool ring = (pass == 1);
            for (int i = 0; i < ZoneCount(); ++i) {
                const int id = aiTerrainMgr.PackSet(ZoneAt(i), def, nanoGroup, facing, anchor, setSize, ring, Global::RoleSettings::Tech::LayoutSetMaximumTurretGapCells);
                if (id >= 0) return id;
            }
            if (fwdZone != 0 && fwdGroup > 0) {
                const int id = aiTerrainMgr.PackSet(fwdZone, def, fwdGroup, facing, anchor, setSize, ring, Global::RoleSettings::Tech::LayoutSetMaximumTurretGapCells);
                if (id >= 0) return id;
            }
        }
        // Saturated support, not only saturated turret slots, needs capacity.
        // GrowBox keeps the existing configured limit and failed-search delay.
        // Never extend an economy line beyond support simply to keep building.
        if (GrowBox()) {
            RegisterFactoryZones();
            return aiTerrainMgr.PackSet(ZoneAt(ZoneCount() - 1), def, nanoGroup, facing, anchor, setSize, true,
                Global::RoleSettings::Tech::LayoutSetMaximumTurretGapCells);
        }
        return -1;
    }

    // D-108: while the advanced fusions have a dedicated builder, the next set of
    // their ground is always held ahead, so the converters cannot take it
    int afusAheadLog = -100000;
    int afusAheadTry = -100000;
    void HoldAfusSetAhead()
    {
        if (!HasBox()) return;
        CCircuitDef@ af = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side));
        if (af is null || aiTerrainMgr.NextSetSlot(af) >= 0) return;
        if (ai.frame - afusAheadTry < 10 * SECOND) return;   // a failed search is not repeated every tick
        afusAheadTry = ai.frame;
        setAsk.set(af.GetName(), ai.frame);   // held, not released as unasked
        const int id = PackSetAnywhere(af, TurretSeed(), SetSizeOf(af));
        if (id >= 0 || ai.frame - afusAheadLog > 60 * SECOND) {
            afusAheadLog = ai.frame;
            const AIFloat3 p = (id >= 0) ? aiTerrainMgr.GetReservationPos(id) : AIFloat3(-1.0f, 0.0f, -1.0f);
            GenericHelpers::LogUtil("[Layout] advanced fusion set held ahead" + ((id >= 0) ? (" at (" + int(p.x) + ", " + int(p.z) + ")") : ": no room") + " (D-108)", 1);
        }
    }

    // D-101: the set size for a def, 0 for a def placed one at a time
    int SetSizeOf(CCircuitDef@ def)
    {
        const string side = Global::AISettings::Side;
        if (def.GetName() == UnitHelpers::GetAdvFusionNameForSide(side)) return Global::RoleSettings::Tech::LayoutAfusSetSize;
        if (def.GetName() == UnitHelpers::GetAdvEnergyConverterNameForSide(side)) return Global::RoleSettings::Tech::LayoutConvSetSize;
        return 0;
    }

    dictionary setAsk;   // D-101: def name -> the frame Place last asked for it

    // D-101: a set's unserved slots go back to the pool once nothing has asked
    // for its def for LayoutSetHoldSeconds (the plan moved on)
    void TickSets()
    {
        array<string>@ keys = setAsk.getKeys();
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            int at = 0;
            if (!setAsk.get(keys[i], at)) continue;
            if (ai.frame - at < int(Global::RoleSettings::Tech::LayoutSetHoldSeconds) * SECOND) continue;
            CCircuitDef@ d = ai.GetCircuitDef(keys[i]);
            if (d !is null) aiTerrainMgr.ReleaseSetSlots(d);
            setAsk.delete(keys[i]);
        }
    }

    // D-101 (owner's rule): a construction turret of ours stands
    bool TurretsStand()
    {
        return nano !is null && (nano.count - aiBuilderMgr.GetUnfinishedCount(nano)) > 0;
    }

    // D-101 (owner's rule): while a turret stands, a factory is placed by the
    // layout (next to the turrets, facing the front, exit clear); only with no
    // turret on the map (the first lab, or a restart after a wipe) anywhere. The
    // reservation is armed: native's factory task serves it. -1 when none.
    // D-104: native packs every factory flush against these clusters (the main
    // cluster first, then the forward one), facing the front
    void RegisterFactoryZones()
    {
        aiTerrainMgr.ClearFactoryZones();
        for (int i = 0; i < ZoneCount(); ++i) aiTerrainMgr.AddFactoryZone(ZoneAt(i), nanoGroup);
        if (fwdZone != 0 && fwdGroup > 0) aiTerrainMgr.AddFactoryZone(fwdZone, fwdGroup);
        aiTerrainMgr.SetFactoryFront(LabFacing());
    }

    int ReserveFactorySite(CCircuitDef@ def)
    {
        CheckForward(true);
        if (def is null || !HasBox() || !TurretsStand()) return -1;
        // D-104: flush against the turrets (air: any facing, no exit test)
        RegisterFactoryZones();
        {
            const int fid = aiTerrainMgr.PackFactoryFlush(def, TurretSeed());
            if (fid >= 0) {
                const AIFloat3 fp = aiTerrainMgr.GetReservationPos(fid);
                GenericHelpers::LogUtil("[Layout] " + def.GetName() + " flush against the turrets at (" + int(fp.x) + ", " + int(fp.z) + ") facing "
                    + aiTerrainMgr.GetReservationFacing(fid) + " (D-104)", 1);
                return fid;
            }
        }
        const array<int>@ labFacings = LabFacings();
        for (uint f = 0; f < labFacings.length(); ++f) {
            for (int i = 0; i < ZoneCount(); ++i) {
                const int id = aiTerrainMgr.PackNearGroup(ZoneAt(i), def, nanoGroup, labFacings[f], TurretSeed(), 0.0f, 0.0f, 0);
                if (id < 0) continue;
                const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
                GenericHelpers::LogUtil("[Layout] " + def.GetName() + " placed by the layout at (" + int(p.x) + ", " + int(p.z) + ") facing " + labFacings[f]
                    + ": a turret stands, so not anywhere (D-101)", 1);
                return id;
            }
            if (fwdZone != 0 && fwdGroup > 0) {
                const int id = aiTerrainMgr.PackNearGroup(fwdZone, def, fwdGroup, labFacings[f], fwdCentre, 0.0f, 0.0f, 0);
                if (id >= 0) return id;
            }
        }
        GenericHelpers::LogUtil("[Layout] no layout site for " + def.GetName() + " although a turret stands", 1);
        return -1;
    }

    // D-121: where cramped-ground structures gather: the advanced lab, else the
    // T1 lab, else the builder, else the start
    AIFloat3 CrampedAnchor(CCircuitUnit@ builder)
    {
        if (Factory::primaryT2BotLab !is null) return Factory::primaryT2BotLab.GetPos(ai.frame);
        if (Factory::primaryT1BotLab !is null) return Factory::primaryT1BotLab.GetPos(ai.frame);
        if (builder !is null) return builder.GetPos(ai.frame);
        return Global::Map::StartPos;
    }

    int crampedLabLog = -100000;
    // D-121: cramped ground's pair: when the first lab is placed with no planned
    // pair, the advanced lab's footprint is held beside it at once, reached by the
    // commander (played: the ground near the first lab filled with turbines, the
    // advanced lab went across the island where raiders stood, and its pinned
    // order was never served)
    void ReserveCrampedLabSlot(const AIFloat3 &in firstLab, CCircuitUnit@ walker)
    {
        if (!fallback || labSlot >= 0) return;
        CCircuitDef@ t2 = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
        if (t2 is null) return;
        const int id = CrampedLabSite(t2, firstLab, Global::RoleSettings::Tech::CrampedPlaceRadius, walker, 32.0f, true);
        if (id < 0) { GenericHelpers::LogUtil("[Layout] no footprint for the advanced lab beside the first lab (D-121)", 1); return; }
        labSlot = id;
        const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
        GenericHelpers::LogUtil("[Layout] advanced lab's footprint held beside the first lab at (" + int(p.x) + ", " + int(p.z) + "), "
            + int(sqrt(MapHelpers::SqDist(p, firstLab))) + " from it (D-121)", 1);
    }
    // D-121: a land constructor that can build `def`, for the reach test
    CCircuitUnit@ CrampedWalker(CCircuitDef@ def)
    {
        if (Builder::primaryT1BotConstructor !is null && Builder::primaryT1BotConstructor.circuitDef.CanBuild(def)) return Builder::primaryT1BotConstructor;
        if (Builder::primaryT2BotConstructor !is null) return Builder::primaryT2BotConstructor;
        return Builder::primaryT1BotConstructor;
    }

    // D-121: a lab footprint on cramped ground: rings out from `at`, any facing,
    // the exit clear, reserved; -1 when none within `radius`
    int CrampedLabSite(CCircuitDef@ lab, const AIFloat3 &in at, float radius, CCircuitUnit@ walker = null, float step = SQUARE_SIZE * 2, bool reserveTechSupport = false,
        CCircuitDef@ supportDefinition = null, const string &in supportStateKey = "")
    {
        const float clear = float(lab.GetFootprintX() > lab.GetFootprintZ() ? lab.GetFootprintX() : lab.GetFootprintZ()) * SQUARE_SIZE * 2;
        const int firstRing = int(clear / step);
        const int rings = int(radius / step);
        for (int r = firstRing; r <= rings; ++r) {
            const int n = 8 * r;
            for (int k = 0; k < n; ++k) {
                const float a = 6.2831853f * float(k) / float(n);
                const AIFloat3 p(at.x + cos(a) * float(r) * step, 0.0f, at.z + sin(a) * float(r) * step);
                // off the map: never asked (played: the harbour near the map's edge,
                // a ring point at z < 0, and the native reach test indexed its sector
                // out of range: the game crashed, SCRIPT CRASH in CrampedLabSite)
                if (p.x < 64.0f || p.z < 64.0f || p.x > float(AiTerrainWidth()) - 64.0f || p.z > float(AiTerrainHeight()) - 64.0f) continue;
                // played: a ridge splits Tundra's island; a site across it was
                // "out of the builder's reach" and every order aborted
                if (walker !is null && !aiTerrainMgr.CanReachAt(walker, p, Global::RoleSettings::Tech::CrampedReachElmos)) continue;
                const int preferredFacing = LabFacing();
                const array<int> candidateFacings = { preferredFacing, (preferredFacing + 1) % 4,
                    (preferredFacing + 3) % 4, (preferredFacing + 2) % 4 };
                for (uint facingIndex = 0; facingIndex < candidateFacings.length(); ++facingIndex) {
                    const int f = candidateFacings[facingIndex];
                    if (!aiTerrainMgr.CanReserveBuilding(lab, p, f)) continue;
                    if (!aiTerrainMgr.IsExitClear(lab, p, f, 320.0f, 32.0f)) continue;   // D-074
                    CCircuitDef@ support = supportDefinition is null ? nano : supportDefinition;
                    if (reserveTechSupport && !aiTerrainMgr.CanReserveNanoBlockAt(support, lab, p, f,
                        Global::RoleSettings::Tech::CrampedSupportColumns,
                        Global::RoleSettings::Tech::CrampedSupportRows, 0)) continue;
                    const int id = aiTerrainMgr.ReserveBuilding(lab, p, f, 0);
                    if (id < 0) continue;
                    // Harbour/hover/flank callers own their distinct support
                    // policy. Do not reserve land nanos under a shipyard or
                    // overwrite the primary bot lab's saved facing for them.
                    if (!reserveTechSupport) return id;
                    // The reserved factory already contributes its actual exit to
                    // native FactoryExitLanes. Commit reachable support with it;
                    // footprint-only fallback sites used to strand unsupported labs.
                    const int group = support is null ? -1 : aiTerrainMgr.ReserveNanoBlockAt(support, lab, p, f,
                        Global::RoleSettings::Tech::CrampedSupportColumns,
                        Global::RoleSettings::Tech::CrampedSupportRows, 0);
                    if (group <= 0 || support is null || aiTerrainMgr.CountGroupSlotsWithin(group, p, support.GetBuildDistance()) == 0) {
                        if (group > 0) {
                            const int supportZone = aiTerrainMgr.GetGroupZone(group);
                            aiTerrainMgr.ReleaseGroup(group);
                            if (supportZone > 0) aiTerrainMgr.ReleaseZone(supportZone);
                        }
                        aiTerrainMgr.ReleaseReservation(id);
                        continue;
                    }
                    if (supportStateKey.length() > 0) {
                        // Harbour modules own their support and facing; never
                        // replace the primary bot factory's metadata.
                        aiTerrainMgr.SetLayoutInt(supportStateKey + ".support_group", group);
                    } else {
                        nanoGroup = group;
                        aiTerrainMgr.SetLayoutInt(BOX + ".nano_group", group);
                        aiTerrainMgr.SetLayoutInt(BOX + ".lab_slot", id);
                        aiTerrainMgr.SetLayoutInt(BOX + ".lab_facing", f);
                    }
                    return id;
                }
            }
        }
        return -1;
    }

    // D-121: turrets on cramped ground: near the labs, as many as the income pays
    // for (CrampedTurretsBase + one per CrampedTurretMetalStep of income, at most
    // CrampedTurretsMax)
    IUnitTask@ CrampedNanoTask(CCircuitUnit@ unit, Task::Priority priority)
    {
        if (nano is null || unit is null || unit.circuitDef is null || !unit.circuitDef.CanBuild(nano)) return null;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        int allowed = Global::RoleSettings::Tech::CrampedTurretsBase + int(mi / Global::RoleSettings::Tech::CrampedTurretMetalStep);
        if (allowed > Global::RoleSettings::Tech::CrampedTurretsMax) allowed = Global::RoleSettings::Tech::CrampedTurretsMax;
        const int have = nano.count + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::NANO), nano);
        if (have >= allowed) return null;
        const AIFloat3 at = CrampedAnchor(unit);
        const int supportSlot = aiTerrainMgr.NextSlotAny(nanoGroup, at);
        if (supportSlot >= 0) {
            IUnitTask@ supported = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, priority, nano,
                aiTerrainMgr.GetReservationPos(supportSlot), 0.0f, true, 120 * SECOND));
            if (supported is null) return null;
            if (!AiPinReservation(supported, supportSlot)) { aiBuilderMgr.AbortTask(supported); return null; }
            return supported;
        }
        GenericHelpers::LogUtil("[Layout] cramped turret " + (have + 1) + " of " + allowed + " near (" + int(at.x) + ", " + int(at.z) + ") (D-121)", 1);
        return aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, priority, nano, at, Global::RoleSettings::Tech::CrampedTurretRadius, true, 120 * SECOND));
    }

    // D-103: a factory ordered on a layout site (ReserveFactorySite), pinned;
    // null when the layout has no site for it
    IUnitTask@ OrderFactory(CCircuitDef@ def, int timeout)
    {
        // D-114: a land factory from +200 metal goes to a front factory cluster
        if (def !is null) {
            bool routed;
            IUnitTask@ ft = TechFactories::Route(def.GetName(), null, routed);
            if (routed) return ft;
        }
        const int id = ReserveFactorySite(def);
        if (id < 0) return null;
        const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, def, p, null, 0.0f, false, true, timeout));
        if (t is null) { aiTerrainMgr.ReleaseReservation(id); return null; }
        if (!AiPinReservation(t, id)) {
            GenericHelpers::LogUtil("[Layout] could not pin " + def.GetName() + " to slot " + id, 1);
            // Abort only this task; a failed claim may be owned by another task.
            aiBuilderMgr.AbortTask(t);
            return null;
        }
        return t;
    }

    int noRoomSince = -1;     // D-099: INV-020
    int noRoomLog = -100000;
    string noRoomDef = "";

    // A whole rectangular bank can be impossible on an island even when a
    // small reactor/support module fits. Search a fixed number of sites only
    // after ordinary packing fails; commit both footprints or release both.
    int ReserveSupportedOverflow(CCircuitDef@ definition, CCircuitUnit@ builder)
    {
        if (nano is null || builder is null || overflowSupportGroups.length() >= uint(Global::RoleSettings::Tech::LayoutOverflowModules)) return -1;
        if (ai.frame - overflowSupportSearchFrame < int(Global::RoleSettings::Tech::LayoutOverflowRetrySeconds) * SECOND) return -1;
        overflowSupportSearchFrame = ai.frame;
        const AIFloat3 home = BaseCentre();
        const int direction = LabFacing();
        const AIFloat3 forward = Fwd(direction);
        const AIFloat3 sideways = Side(direction);
        const array<AIFloat3> bearings = { forward * -1.0f, sideways, sideways * -1.0f,
            (sideways - forward) * 0.70710678f, (sideways + forward) * -0.70710678f,
            forward, (sideways + forward) * 0.70710678f, (forward - sideways) * 0.70710678f };
        for (int ring = 1; ring <= Global::RoleSettings::Tech::LayoutOverflowRings; ++ring) {
            for (uint index = 0; index < bearings.length(); ++index) {
                const AIFloat3 position = home + bearings[index] * (float(ring) * Global::RoleSettings::Tech::LayoutOverflowStepElmos);
                if (position.x < 0 || position.z < 0 || position.x >= AiTerrainWidth() || position.z >= AiTerrainHeight()) continue;
                if (!aiTerrainMgr.CanReachAt(builder, position, builder.circuitDef.GetBuildDistance())) continue;
                if (!aiTerrainMgr.CanReserveBuilding(definition, position, direction)) continue;
                const int slot = aiTerrainMgr.ReserveBuilding(definition, position, direction, 0);
                if (slot < 0) continue;
                const int support = aiTerrainMgr.ReserveNanoBlockAt(nano, definition, position, direction,
                    Global::RoleSettings::Tech::CrampedSupportColumns, Global::RoleSettings::Tech::CrampedSupportRows, 0);
                if (support <= 0 || aiTerrainMgr.CountGroupSlotsWithin(support, position, nano.GetBuildDistance()) == 0) {
                    if (support > 0) { const int zone = aiTerrainMgr.GetGroupZone(support); aiTerrainMgr.ReleaseGroup(support); if (zone > 0) aiTerrainMgr.ReleaseZone(zone); }
                    aiTerrainMgr.ReleaseReservation(slot);
                    continue;
                }
                aiTerrainMgr.SetLayoutInt(BOX + ".overflow_group" + overflowSupportGroups.length(), support);
                overflowSupportGroups.insertLast(support);
                aiTerrainMgr.SetLayoutInt(BOX + ".overflow_count", int(overflowSupportGroups.length()));
                GenericHelpers::LogUtil("[Layout] supported overflow " + definition.GetName() + " slot=" + slot + " support=" + support, 1);
                return slot;
            }
        }
        GenericHelpers::LogUtil("[Layout] supported overflow search blocked for " + definition.GetName(), 1);
        return -1;
    }

    bool OverflowSupports(const AIFloat3 &in position)
    {
        if (nano is null) return false;
        for (uint index = 0; index < overflowSupportGroups.length(); ++index)
            if (aiTerrainMgr.CountGroupSlotsWithin(overflowSupportGroups[index], position, nano.GetBuildDistance()) > 0) return true;
        return false;
    }

    IUnitTask@ ReplaceLost(Task::BuildType type, CCircuitDef@ def, CCircuitUnit@ builder)
    {
        if (!Global::RoleSettings::Tech::EconomyRecoveryEnabled || builder is null || def is null
            || !def.IsAvailable(ai.frame) || !builder.circuitDef.CanBuild(def)) return null;
        const int id = aiTerrainMgr.NextLostReservation(builder, def, Global::RoleSettings::Tech::RecoverySlotBudget);
        if (id < 0) return null;
        // INV-223: recovery must reuse a free lost slot, never reserve new ground.
        if (aiTerrainMgr.GetReservationState(id) != 0 || aiTerrainMgr.GetLostReservationCount(def) <= 0) {
            Invariants::Violation("INV-223", def.GetName(), "recovery selected an owned or non-lost slot " + id);
            return null;
        }
        IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Common(type, Task::Priority::HIGH, def,
            aiTerrainMgr.GetReservationPos(id), 0.0f, true, 300 * SECOND));
        if (task is null) return null; // the loss remains owned by the reservation
        if (!AiPinReservation(task, id)) { aiBuilderMgr.AbortTask(task); return null; }
        GenericHelpers::LogUtil("[TECH][Recovery] " + def.GetName() + " slot=" + id + " worker=" + builder.id, 1);
        return task;
    }

    IUnitTask@ Place(Task::BuildType type, Task::Priority priority, CCircuitDef@ def, int timeout, CCircuitUnit@ builder = null)
    {
        if (AiPerfEnabled) AiPerfBegin(4);
        IUnitTask@ result = PlaceMeasured(type, priority, def, timeout, builder);
        if (AiPerfEnabled) AiPerfEnd(4);
        return result;
    }

    IUnitTask@ PlaceMeasured(Task::BuildType type, Task::Priority priority, CCircuitDef@ def, int timeout, CCircuitUnit@ builder)
    {
        if (def is null) return null;
        if (Global::AISettings::Role == AiRole::TECH) {
            IUnitTask@ replacement = ReplaceLost(type, def, builder);
            if (replacement !is null) return replacement;
            // The replacement-only income exemption cannot spill into expansion
            // if the destroyed footprint is unsafe, blocked, or already claimed.
            if (def.GetName() == UnitHelpers::GetAdvEnergyConverterNameForSide(Global::AISettings::Side)
                && Economy::GetMinMetalIncomeLast10s() < Global::RoleSettings::Tech::MinimumMetalIncomeForAdvConverter) return null;
        }
        if (CompactEco::Active()) return CompactEco::Place(type, priority, def, timeout, builder);
        // Among the cells equally close to a turret, the one nearest the
        // builder that asked: the less it walks, the sooner it builds (D-064).
        AIFloat3 anchor = factoryCentre;
        if (builder !is null) anchor = builder.GetPos(ai.frame);
        if (!HasBox()) {
            // D-121: with no planned pair (cramped ground, D-120) there are no
            // factory nanos either: FactoryNanoCentre is the bare start, and 8
            // cells around it found no site for a converter 1608 times on Tundra.
            // The structure is packed nearest a standing lab (else the builder),
            // CrampedPlaceRadius far
            if (fallback) {
                const AIFloat3 at = CrampedAnchor(builder);
                if (!fallbackLogged) {
                    fallbackLogged = true;
                    GenericHelpers::LogUtil("[Layout] no planned pair: economy structures are packed within " + int(Global::RoleSettings::Tech::CrampedPlaceRadius)
                        + " of the nearest lab (D-121)", 1);
                }
                return aiBuilderMgr.Enqueue(TaskB::Common(type, priority, def, at, Global::RoleSettings::Tech::CrampedPlaceRadius, true, timeout));
            }
            if (!fallbackLogged) {
                fallbackLogged = true;
                GenericHelpers::LogUtil("[Layout] no turret box: economy structures are placed within "
                    + Global::RoleSettings::Tech::LayoutFallbackShakeCells + " cells of the factory nanos", 1);
            }
            return aiBuilderMgr.Enqueue(TaskB::Common(type, priority, def, FactoryNanoCentre(),
                float(Global::RoleSettings::Tech::LayoutFallbackShakeCells) * SQUARE_SIZE * 2, true, timeout));
        }
        CheckForward(true);
        int id = -1;
        // D-101 (owner's rule): advanced fusions and advanced converters go in sets,
        // the first flush against a turret, the rest lined up away from it; the
        // set's next slot before a new set; a new set flush against the turrets again
        const int setSize = SetSizeOf(def);
        if (setSize > 0) {
            setAsk.set(def.GetName(), ai.frame);
            id = aiTerrainMgr.NextSetSlot(def);
            bool fresh = false;
            if (id < 0) {
                id = PackSetAnywhere(def, anchor, setSize);
                fresh = id >= 0;
            }
            if (fresh) {
                const AIFloat3 sp = aiTerrainMgr.GetReservationPos(id);
                int gap = aiTerrainMgr.EdgeGapToGroup(def, sp, aiTerrainMgr.GetReservationFacing(id), nanoGroup);
                if (fwdGroup > 0) {
                    const int fg = aiTerrainMgr.EdgeGapToGroup(def, sp, aiTerrainMgr.GetReservationFacing(id), fwdGroup);
                    if (fg >= 0 && (gap < 0 || fg < gap)) gap = fg;
                }
                GenericHelpers::LogUtil("[Layout] new set of " + def.GetName() + " at (" + int(sp.x) + ", " + int(sp.z) + "), " + gap + " cell(s) from a turret", 1);
                // INV-022 (D-101): the first of a set touches a turret
                if (gap < 0 || (Global::RoleSettings::Tech::LayoutSetMaximumTurretGapCells >= 0
                    && gap > Global::RoleSettings::Tech::LayoutSetMaximumTurretGapCells))
                    Invariants::Violation("INV-022", def.GetName(), "a new set of " + def.GetName() + " starts " + gap + " cell(s) from the turrets, not flush");
            }
        }
        for (int i = 0; i < ZoneCount() && id < 0; ++i)
            id = aiTerrainMgr.PackNearGroup(ZoneAt(i), def, nanoGroup, facing, anchor, 0.0f, MinNanoDist(def), 0);
        // D-099 (played: 130 advanced converters filled the main box and the
        // economy stopped at +24k energy). Owner's rule: the box does not grow,
        // a structure beyond it would be out of the turrets' reach; the ground
        // around the turrets is used (native packs the ring around a full zone
        // within a turret's reach), then the next nearest cluster: the forward
        // one, served by its own turrets.
        if (id < 0 && fwdZone != 0 && fwdGroup > 0)
            id = aiTerrainMgr.PackNearGroup(fwdZone, def, fwdGroup, facing, anchor, 0.0f, MinNanoDist(def), 0);
        for (uint index = 0; index < overflowSupportGroups.length() && id < 0; ++index) {
            const int group = overflowSupportGroups[index];
            id = aiTerrainMgr.PackNearGroup(aiTerrainMgr.GetGroupZone(group), def, group, facing, anchor, 0.0f, MinNanoDist(def), 0);
        }
        if (id < 0) id = ReserveSupportedOverflow(def, builder);
        if (id < 0) {
            if (noRoomSince < 0) noRoomSince = ai.frame;
            // said once per def every 30 s (played: 4,139 lines in 20 minutes)
            if (def.GetName() != noRoomDef || ai.frame - noRoomLog > 30 * SECOND) {
                noRoomDef = def.GetName(); noRoomLog = ai.frame;
                GenericHelpers::LogUtil("[Layout] no room within reach of any turret cluster for " + def.GetName()
                    + " (" + int((ai.frame - noRoomSince) / SECOND) + " s without room)", 1);
            }
            // INV-020 (D-099): the economy is not refused for lack of room for long
            if (ai.frame - noRoomSince >= int(Global::RoleSettings::Tech::InvariantNoRoomSeconds) * SECOND)
                Invariants::Violation("INV-020", "room", "no layout room for " + def.GetName() + " for " + int((ai.frame - noRoomSince) / SECOND) + " s");
            return null;
        }
        noRoomSince = -1;
        const AIFloat3 pos = aiTerrainMgr.GetReservationPos(id);
        // INV-014 (D-082): every packed structure stands within a turret's reach of a slot
        if (aiTerrainMgr.CountGroupSlotsWithin(nanoGroup, pos, Global::RoleSettings::Tech::InvariantReachElmos) == 0
            && (fwdGroup == 0 || aiTerrainMgr.CountGroupSlotsWithin(fwdGroup, pos, Global::RoleSettings::Tech::InvariantReachElmos) == 0)
            && !OverflowSupports(pos))
            Invariants::Violation("INV-014", def.GetName(), def.GetName() + " packed at (" + int(pos.x) + ", " + int(pos.z) + ") with no turret slot within " + int(Global::RoleSettings::Tech::InvariantReachElmos));
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(type, priority, def, pos, 0.0f, true, timeout));
        if (t is null) {
            aiTerrainMgr.ReleaseReservation(id);
            return null;
        }
        if (!AiPinReservation(t, id)) {
            GenericHelpers::LogUtil("[Layout] could not pin " + def.GetName() + " to slot " + id, 1);
            // Failed claims may belong to another task. Abort releases only
            // this enqueue's bookkeeping; never release the shared slot here.
            aiBuilderMgr.AbortTask(t);
            return null;
        }
        return t;
    }

    // The next construction turret slot, nearest the factories: a completed
    // factory's own rear slot (D-060), then the box row behind it. Pinned,
    // never spiralled. Null when no slot is left or the unit cannot build one.
    // D-083/D-085: where the block grows from - the start position (the home
    // mexes), or the nearest standing lab to the box when the box is planned
    // behind the pair. The turrets fill from here and the advanced lab is
    // placed nearest here among the sites the most turret slots reach.
    // D-086: the centre of the home mex spots (OpeningMexCap nearest the start
    // within OpeningMexRadius): where the commander and the first constructors
    // are when the turrets begin, so the least walking.
    AIFloat3 homeCentre = AIFloat3(-1.0f, 0.0f, -1.0f);
    AIFloat3 HomeCentre()
    {
        if (homeCentre.x < 0.0f) {
            homeCentre = Global::Map::StartPos;
            if (Global::RoleSettings::Tech::LayoutSeedAtHomeMexes)
                homeCentre = aiEconomyMgr.GetMexCentroidWithin(Global::Map::StartPos, Global::RoleSettings::Tech::OpeningMexRadius, Global::RoleSettings::Tech::OpeningMexCap);
            GenericHelpers::LogUtil("[Layout] home centre (" + int(homeCentre.x) + ", " + int(homeCentre.z) + "), "
                + int(sqrt(MapHelpers::SqDist(homeCentre, Global::Map::StartPos))) + " from the start", 1);
        }
        return homeCentre;
    }

    // D-096 (owner's rule): the labs face the nearest enemy, so what they make
    // walks out toward it. D-098 (owner: from the north-east start of Supreme
    // Isthmus the front is south, the straight line to the map centre is west,
    // across the cliffs): the lane, native's point on our side's front line,
    // the one the factory pair faces; the map centre only while the lane is
    // unknown. A seen enemy group of LayoutFrontMinCost is the front only when
    // it is nearer home than that: a second front.
    AIFloat3 FrontTarget()
    {
        const AIFloat3 home = HomeCentre();
        const AIFloat3 lane = aiSetupMgr.GetLanePos();
        const bool laneKnown = (lane.x > 0.0f || lane.z > 0.0f) && MapHelpers::SqDist(lane, home) > 100.0f * 100.0f;
        const AIFloat3 front = laneKnown ? lane : LayoutHelpers::TerrainCentre();
        const AIFloat3 g = aiEnemyMgr.GetNearestGroupPos(home, Global::RoleSettings::Tech::LayoutFrontMinCost);
        return (g.x >= 0.0f && MapHelpers::SqDist(g, home) < MapHelpers::SqDist(front, home)) ? g : front;
    }

    // D-098: the facing the advanced lab was ordered with (INV-018 checks the lab
    // stands that way; a front seen later does not turn a standing lab)
    int LabPlannedFacing()
    {
        return aiTerrainMgr.GetLayoutInt(BOX + ".lab_facing", -1);
    }

    int LabFacing()
    {
        return LayoutHelpers::FacingToward(HomeCentre(), FrontTarget());
    }

    // D-096: the facings a lab may take, the front first, then the two beside it;
    // never away from the enemy
    array<int> LabFacings()
    {
        const int f = LabFacing();
        array<int> facings = { f, (f + 1) % 4, (f + 3) % 4 };
        return facings;
    }

    // D-096 (the D-063 picture): the advanced lab on the block's front line, its
    // back to turret row 0 (flush), its exit toward the enemy. Tried from touching
    // the front outward, LayoutLabFrontGapCells at most; along the front edge
    // within the block's width; the free, buildable footprint with a clear exit
    // nearest the home centre wins. -1 when none: the ranked search decides.
    int ReserveFrontLab(CCircuitDef@ t2, const AIFloat3& in boxFront, int across)
    {
        const AIFloat3 fwd = Fwd(facing);
        const AIFloat3 sideVec = Side(facing);
        const float cell = SQUARE_SIZE * 2;
        const int labAlong = Along(t2, facing);
        const int labAcross = Across(t2, facing);
        const AIFloat3 home = HomeCentre();
        const int reach = (across - labAcross) / 2;
        for (int k = 0; k <= Global::RoleSettings::Tech::LayoutLabFrontGapCells; ++k) {
            AIFloat3 best(-1.0f, 0.0f, -1.0f);
            float bestSq = 1.0e30f;
            for (int s = -reach; s <= reach; ++s) {
                const AIFloat3 p = boxFront + fwd * ((float(labAlong) * 0.5f + float(k)) * cell) + sideVec * (float(s) * cell);
                if (!aiTerrainMgr.CanReserveBuilding(t2, p, facing)) continue;
                if (!aiTerrainMgr.IsExitClear(t2, p, facing, 320.0f, 32.0f)) continue;
                const float sq = MapHelpers::SqDist(p, home);
                if (sq < bestSq) { bestSq = sq; best = p; }
            }
            if (best.x < 0.0f) continue;
            const int id = aiTerrainMgr.ReserveBuilding(t2, best, facing);
            if (id < 0) continue;
            GenericHelpers::LogUtil("[Layout] advanced lab on the front line at (" + int(best.x) + ", " + int(best.z) + ") facing " + facing
                + ", " + k + " cells ahead of turret row 0", 1);
            return id;
        }
        GenericHelpers::LogUtil("[Layout] no front-line site for the advanced lab: the ranked search decides", 1);
        return -1;
    }

    AIFloat3 TurretSeed()
    {
        if (CompactEco::Active()) {
            // A cramped lab can be farther than the rush's local-worker limit
            // from the economy. Its independent bank is the support centre.
            if (CompactEco::seeds.length() > 0) {
                const AIFloat3 seed = aiTerrainMgr.GetReservationPos(CompactEco::seeds[0]);
                if (seed.x >= 0.0f) return seed;
            }
            return HomeCentre();
        }
        // D-088: the block fills from the advanced lab's footprint, so the first
        // turrets stand flush with the lab, as the pair's nanos do with the T1 lab
        if (Global::RoleSettings::Tech::LayoutBoxAtStart) {
            // D-090: the advanced lab itself, however it was placed (played: no
            // footprint at plan time, the lab placed by the fallback, the turrets
            // filling from the home centre 680 elmos away)
            CCircuitDef@ t2def = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
            if (Factory::primaryT2BotLab !is null) return Factory::primaryT2BotLab.GetPos(ai.frame);
            if (t2def !is null && aiBuilderMgr.GetUnfinishedCount(t2def) > 0) {
                CCircuitUnit@ fr = aiBuilderMgr.FindUnfinishedNear(HomeCentre(), 4000.0f, t2def);
                if (fr !is null) return fr.GetPos(ai.frame);
            }
            if (labSlot >= 0) {
                const AIFloat3 lp = aiTerrainMgr.GetReservationPos(labSlot);
                if (lp.x >= 0.0f) return lp;
            }
        }
        if (Global::RoleSettings::Tech::LayoutBoxAtStart) return HomeCentre();
        AIFloat3 seed = boxCentre;
        float bestSq = 1.0e30f;
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            CCircuitUnit@ f = null; if (!Factory::allFactories.get(keys[i], @f) || f is null) continue;
            const AIFloat3 fp = f.GetPos(ai.frame);
            const float sq = MapHelpers::SqDist(fp, boxCentre);
            if (sq < bestSq) { bestSq = sq; seed = fp; }
        }
        return seed;
    }

    // D-097 (owner's rule): construction turrets go up one at a time while the
    // economy is small, and in parallel once the metal and the nearby build power
    // make that pay. With k turrets in flight the nearby build power B (mobile and
    // static, within EcoBuildPowerRadius of the base centre) finishes them in
    // k * T / B seconds (T the turret's buildtime), in which time the bank M and
    // the income I must pay k * C (C its metal cost):
    //   by power: k <= B * PowerTurretBatchSeconds / T  (each still finishes fast)
    //   by metal: k * (C - I * T / B) <= M               (paid in full, no stall)
    // The smaller of the two, at least 1, at most PowerTurretsMax: the slots.
    // D-098 (owner: a turret and the advanced lab at once early stalls; with
    // metal high, the build power goes on what is building): every dear frame
    // (ChainParallelCostM or more) under construction near the base takes one
    // slot; the turrets get the rest, none while the lab takes the only one.
    int TurretsAllowed(string &out why)
    {
        const int slots = TurretSlots(why);
        const int dear = aiBuilderMgr.CountUnfinishedNear(BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius,
            Global::RoleSettings::Tech::ChainParallelCostM, nano);
        why += ", " + dear + " dear frames take a slot";
        return (slots > dear) ? (slots - dear) : 0;
    }

    // D-098: a slot of the nearby build power is free for one more frame, turret
    // or dear structure
    bool BuildSlotFree()
    {
        string why;
        const int slots = TurretSlots(why);
        const int dear = aiBuilderMgr.CountUnfinishedNear(BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius,
            Global::RoleSettings::Tech::ChainParallelCostM, nano);
        return TurretsInFlight() + dear < slots;
    }

    // D-098: the turret frame going up nearest the base centre, or null
    CCircuitUnit@ TurretFrame()
    {
        if (nano is null || aiBuilderMgr.GetUnfinishedCount(nano) == 0) return null;
        return aiBuilderMgr.FindUnfinishedNear(BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, nano);
    }

    int TurretSlots(string &out why)
    {
        if (nano is null) { why = "no turret def"; return 1; }
        const float t = Global::RoleSettings::Tech::PowerTurretBuildTime;
        const float bp = aiBuilderMgr.GetBuildPowerNear(BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius);
        const float m = aiEconomyMgr.metal.current;
        const float inc = aiEconomyMgr.metal.income;
        const float c = nano.costM;
        const int maxK = Global::RoleSettings::Tech::PowerTurretsMax;
        int byPower = (bp > 0.0f) ? int(bp * Global::RoleSettings::Tech::PowerTurretBatchSeconds / t) : 0;
        int byMetal = maxK;
        if (bp > 0.0f) {
            const float net = c - inc * t / bp;   // metal each turret needs from the bank
            if (net > 0.0f) byMetal = int(m / net);
        } else byMetal = 0;
        int k = (byPower < byMetal) ? byPower : byMetal;
        if (k < 1) k = 1;
        if (k > maxK) k = maxK;
        why = "build power " + int(bp) + " (" + byPower + " by power), bank " + int(m) + " + " + int(inc) + "/s (" + byMetal + " by metal)";
        return k;
    }

    // D-097: turret orders not yet started plus turret frames under construction
    int TurretsInFlight()
    {
        // Constant-size roster; native lifecycle counters are O(1) per definition.
        // Include donated faction/platform turrets: the resource budget is shared.
        const array<string> names = UnitHelpers::GetT1NanoUnitNames();
        int committed = 0;
        for (uint index = 0; index < names.length(); ++index) {
            CCircuitDef@ definition = ai.GetCircuitDef(names[index]);
            if (definition !is null) committed += aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::NANO), definition)
                + aiBuilderMgr.GetUnfinishedCount(definition);
        }
        return committed;
    }

    bool TurretsCapped()
    {
        string why;
        return TurretsInFlight() >= TurretsAllowed(why);
    }

    int turretCapLog = -100000;
    int lastTurretAllowed = -1;

    // Synchronous enqueue callbacks see the same budget that admitted the order.
    // Restore it after the call so unrelated/native admissions use their own budget.
    int activeTurretAdmissionBudget = -1;
    IUnitTask@ NanoTask(CCircuitUnit@ unit, Task::Priority priority, int parallelBudget = -1)
    {
        const int previousBudget = activeTurretAdmissionBudget;
        string why;
        activeTurretAdmissionBudget = parallelBudget >= 0 ? parallelBudget : TurretsAllowed(why);
        IUnitTask@ result = AdmitNanoTask(unit, priority, activeTurretAdmissionBudget);
        activeTurretAdmissionBudget = previousBudget;
        return result;
    }

    IUnitTask@ AdmitNanoTask(CCircuitUnit@ unit, Task::Priority priority, int parallelBudget)
    {
        const bool crampedLayout = fallback && aiTerrainMgr.IsLayoutEnabled();
        if ((!HasComplex() && !crampedLayout) || unit is null || unit.circuitDef is null || nano is null) return null;
        if (!unit.circuitDef.CanBuild(nano)) return null;
        // D-097: every turret order passes here (the chain's nano step, the
        // power rule, the economy rows): no new one while the calculation says
        // the ones in flight are enough; the caller assists instead
        {
            string why;
            // Ordinary callers retain the resource-derived cap. A timed
            // opening may supply a bounded concurrent-project budget; geometry,
            // ally reservations, pinning and completed counts stay shared.
            const int allowed = parallelBudget >= 0 ? parallelBudget : TurretsAllowed(why);
            const int inFlight = TurretsInFlight();
            if (inFlight >= allowed) {
                if (ai.frame - turretCapLog > 15 * SECOND || allowed != lastTurretAllowed) {
                    turretCapLog = ai.frame; lastTurretAllowed = allowed;
                    GenericHelpers::LogUtil("[Layout] turrets: " + inFlight + " in flight of " + allowed + " allowed (" + why + "): assist what is building, no new turret", 1);
                }
                return null;
            }
            GenericHelpers::LogUtil("[Layout] turrets: order " + (inFlight + 1) + " of " + allowed + " allowed (" + why + ")", 1);
        }
        // Cramped geometry changes where a turret fits, not whether another
        // concurrent project is affordable. Keep its admission gate shared.
        if (CompactEco::Active()) return CompactEco::NanoTask(unit, priority);
        if (crampedLayout) return CrampedNanoTask(unit, priority);
        for (uint index = 0; index < overflowSupportGroups.length(); ++index) {
            const int slot = aiTerrainMgr.NextSlotAny(overflowSupportGroups[index], unit.GetPos(ai.frame));
            if (slot < 0) continue;
            IUnitTask@ support = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, priority, nano,
                aiTerrainMgr.GetReservationPos(slot), 0.0f, true, 120 * SECOND));
            if (support is null) return null;
            if (!AiPinReservation(support, slot)) { aiBuilderMgr.AbortTask(support); return null; }
            return support;
        }
        // D-088: the pair's factory-nano slots stand behind the T1 lab, the
        // throwaway (played: the first turrets and the turbines packed there, 700
        // elmos from the block); with the block at the home mexes every turret
        // goes into the block
        if (!Global::RoleSettings::Tech::LayoutBoxAtStart && aiTerrainMgr.GetFactoryNanoAvailable() > 0) {
            IUnitTask@ t = aiBuilderMgr.EnqueueFactoryNano(
                TaskB::Common(Task::BuildType::NANO, priority, nano, Global::Map::StartPos, 0.0f, true, 120 * SECOND), unit);
            if (t !is null) return t;
        }
        if (!HasBox()) return null;
        CheckForward(true);
        const bool fwdFree = (fwdGroup > 0) && aiTerrainMgr.GetGroupCount(fwdGroup, true) > 0;
        if (aiTerrainMgr.GetGroupCount(nanoGroup, true) == 0 && !fwdFree && !GrowBox()) return null;   // D-072: more rows behind
        // D-069: the slot nearest a standing lab, whichever lab that is, so
        // every turret reaches a lab; the pair's centre only when no lab stands.
        int id = -1;
        // D-077 (owner's rule): turrets start at the centre of the planned
        // layout and grow outward as one connected cluster, so the most
        // structures sit in range of the build power.
        if (Global::RoleSettings::Tech::ExpTurretCentreOut && boxCentre.x >= 0.0f) {
            // the block's seed is the nearest standing lab (D-069's reason: the first
            // turrets must reach a lab), the box centre only while no lab stands;
            // from the second turret on the block grows from its own centroid
            const AIFloat3 seed = TurretSeed();
            id = aiTerrainMgr.NextSlotConnected(nanoGroup, seed);
            if (id < 0 && fwdGroup > 0) id = aiTerrainMgr.NextSlotConnected(fwdGroup, fwdCentre);   // D-081: the forward cluster once the main block is full
            if (id >= 0) GenericHelpers::LogUtil("[Layout] turret slot " + id + ", " + int(sqrt(MapHelpers::SqDist(aiTerrainMgr.GetReservationPos(id), boxCentre))) + " from the box centre (connected)", 2);
        }
        if (id < 0 && Global::RoleSettings::Tech::ExpTurretNearLab) {
            float bestSq = 1.0e30f;
            array<string>@ keys = Factory::allFactories.getKeys();
            for (uint i = 0; keys !is null && i < keys.length(); ++i) {
                CCircuitUnit@ f = null; if (!Factory::allFactories.get(keys[i], @f) || f is null) continue;
                const AIFloat3 fp = f.GetPos(ai.frame);
                const int cand = aiTerrainMgr.NextSlotAny(nanoGroup, fp);
                if (cand < 0) continue;
                const float sq = MapHelpers::SqDist(aiTerrainMgr.GetReservationPos(cand), fp);
                if (sq < bestSq) { bestSq = sq; id = cand; }
            }
            if (id >= 0) GenericHelpers::LogUtil("[Layout] turret slot " + id + ", " + int(sqrt(bestSq)) + " from the nearest lab", 2);
        }
        if (id < 0) id = aiTerrainMgr.NextSlotAny(nanoGroup, factoryCentre);
        if (id < 0) return null;
        const AIFloat3 pos = aiTerrainMgr.GetReservationPos(id);
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, priority, nano, pos, 0.0f, true, 120 * SECOND));
        if (t is null) return null;
        if (!AiPinReservation(t, id)) {
            GenericHelpers::LogUtil("[Layout] could not pin a turret to slot " + id, 1);
            aiBuilderMgr.AbortTask(t);
            return null;
        }
        return t;
    }

    // The advanced lab's site (D-069): the pair's planned slot, unless a free
    // footprint within ExpLabSiteRadius of it has strictly more static build
    // power (turrets, workertime) within ExpLabBuildPowerReach - then that
    // footprint, reserved and pinned, facing as the pair does. Every block,
    // zone and exit cone is honoured by CanReserveBuilding. The first lab is
    // the exception (tech_build.as: at the commander). Null when the lab
    // cannot be ordered now (cooldown, def unavailable, nothing enqueued).
    IUnitTask@ T2LabTask(int timeout)
    {
        const string side = Global::AISettings::Side;
        CCircuitDef@ t2 = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(side));
        if (t2 is null) return null;
        {
            bool routed;   // D-114: from +200 metal the advanced lab goes to a front factory cluster
            IUnitTask@ ft = TechFactories::Route(t2.GetName(), null, routed);
            if (routed) return ft;
        }
        if (!t2.IsAvailable(ai.frame)) return null;
        if (!Builder::IsT2BotFactoryOffCooldown()) return null;
        // D-121: no planned pair (cramped ground): the nearest footprint to the T1
        // lab, any facing (played: the pair's slot is -1 there and every order aborted)
        if (fallback) {
            // the footprint held beside the first lab (ReserveCrampedLabSlot) first
            if (labSlot >= 0 && !aiTerrainMgr.IsSlotDead(labSlot) && aiTerrainMgr.GetReservationPos(labSlot).x >= 0.0f)
                return OrderLabOn(t2, labSlot, timeout, false, "on its cramped slot beside the first lab (D-121)");
            const AIFloat3 at = CrampedAnchor(null);
            const int id = CrampedLabSite(t2, at, Global::RoleSettings::Tech::CrampedPlaceRadius, CrampedWalker(t2), SQUARE_SIZE * 2, true);
            if (id < 0) {
                if (ai.frame - crampedLabLog >= 60 * SECOND) {
                    crampedLabLog = ai.frame;
                    GenericHelpers::LogUtil("[Layout] no reachable footprint for the advanced lab within " + int(Global::RoleSettings::Tech::CrampedPlaceRadius)
                        + " of (" + int(at.x) + ", " + int(at.z) + ") (D-121)", 1);
                }
                return null;
            }
            return OrderLabOn(t2, id, timeout, true, "on cramped ground (no planned pair, D-121) at");
        }
        // D-116: the planned footprint the engine refused (a dead slot, never
        // served again) is given up and the lab placed elsewhere (played on All
        // That Glitters, build99: every advanced lab order was pinned to the dead
        // slot and aborted for 15 minutes). Its ground stays held.
        if (labSlot >= 0 && aiTerrainMgr.IsSlotDead(labSlot)) {
            const AIFloat3 dp = aiTerrainMgr.GetReservationPos(labSlot);
            GenericHelpers::LogUtil("[Layout] advanced lab's planned footprint at (" + int(dp.x) + ", " + int(dp.z)
                + ") refused by the engine (a dead slot): the lab is placed elsewhere (D-116)", 1);
            labSlot = -1;
            aiTerrainMgr.SetLayoutInt(BOX + ".lab_slot", -1);
        }
        // D-104 (owner's rule): an advanced lab after the first (its planned
        // front-line footprint used) stands flush against the turrets, facing the
        // front (played: the rebuilt lab 7 cells out through the ranked search)
        if (TechBuild::WasIntoT2() && (labSlot < 0 || aiTerrainMgr.GetReservationPos(labSlot).x < 0.0f)) {
            IUnitTask@ ft = OrderFactory(t2, timeout);
            if (ft !is null) { Builder::MarkT2BotFactoryEnqueued(); return ft; }
        }
        // D-073: the site is scored by the turret slots (standing or planned) that
        // reach it, front first among equals: the pair's planned slot against the
        // best free footprint inside the turret layout (owner: "on the turret
        // layout, tight, the more build power in range of the factory the better;
        // its units leave for the front late").
        const float reach = Global::RoleSettings::Tech::ExpLabBuildPowerReach;
        // D-085: the footprint reserved when the box was planned
        // D-086 (owner's rule): the lab goes closest to the construction turrets.
        // Once a turret stands, the planned footprint is kept only if one is
        // within LayoutLabServedReach; else it is released and the lab packed
        // nearest a standing turret (built slots rank first natively), exit clear.
        if (labSlot >= 0 && aiBuilderMgr.GetStaticBuildPowerNear(TurretSeed(), 3000.0f) > 0.0f) {
            const AIFloat3 lp = aiTerrainMgr.GetReservationPos(labSlot);
            if (lp.x >= 0.0f && aiBuilderMgr.GetStaticBuildPowerNear(lp, Global::RoleSettings::Tech::LayoutLabServedReach) <= 0.0f) {
                for (int i = 0; i < ZoneCount(); ++i) {
                    const int nid = aiTerrainMgr.PackNearGroup(ZoneAt(i), t2, nanoGroup, aiTerrainMgr.GetReservationFacing(labSlot), TurretSeed(), 0.0f, 0.0f, 0);   // D-096: the planned facing
                    if (nid < 0) continue;
                    const AIFloat3 np = aiTerrainMgr.GetReservationPos(nid);
                    if (aiBuilderMgr.GetStaticBuildPowerNear(np, Global::RoleSettings::Tech::LayoutLabServedReach) <= 0.0f) { aiTerrainMgr.ReleaseReservation(nid); continue; }
                    aiTerrainMgr.ReleaseReservation(labSlot);
                    GenericHelpers::LogUtil("[Layout] advanced lab moved from its planned slot (" + int(lp.x) + ", " + int(lp.z) + ") to ("
                        + int(np.x) + ", " + int(np.z) + "), next to a standing turret", 1);
                    labSlot = nid;
                    aiTerrainMgr.SetLayoutInt(BOX + ".lab_slot", labSlot);
                    break;
                }
            }
        }
        if (labSlot >= 0 && aiTerrainMgr.GetReservationPos(labSlot).x >= 0.0f)
            return OrderLabOn(t2, labSlot, timeout, false, "on its planned slot");
        const int t2Slot = aiTerrainMgr.GetLayoutInt(FACTORY_ROOT + ".t2_slot", -1);
        AIFloat3 pairPos = (t2Slot >= 0) ? aiTerrainMgr.GetReservationPos(t2Slot) : Global::Map::StartPos;
        if (pairPos.x < 0.0f) pairPos = Global::Map::StartPos;
        const int pairScore = (nanoGroup > 0) ? aiTerrainMgr.CountGroupSlotsWithin(nanoGroup, pairPos, reach) : 0;
        int bestScore = pairScore;
        int bestZone = 0;
        AIFloat3 bestPos = pairPos;
        for (int i = 0; i < ZoneCount(); ++i) {
            AIFloat3 p;
            const int s = aiTerrainMgr.PickMost(ZoneAt(i), t2, nanoGroup, LabFacing(), reach, Global::RoleSettings::Tech::LayoutLabFlushElmos, TurretSeed(), p);   // D-096
            if (s > bestScore) { bestScore = s; bestZone = ZoneAt(i); bestPos = p; }
        }
        if (bestZone == 0 && HasBox() && GrowBox()) {
            AIFloat3 p;
            const int s = aiTerrainMgr.PickMost(ZoneAt(ZoneCount() - 1), t2, nanoGroup, LabFacing(), reach, Global::RoleSettings::Tech::LayoutLabFlushElmos, TurretSeed(), p);   // D-096
            if (s > bestScore) { bestScore = s; bestZone = ZoneAt(ZoneCount() - 1); bestPos = p; }
        }
        if (bestZone == 0) {
            // D-087: before the pair's slot, the footprint nearest a turret slot, in
            // any facing whose exit is clear (played: the pair's facing had no site
            // with a clear exit in the block and the lab went to the pair's slot)
            const array<int>@ labFacings = LabFacings();   // D-096: the front first, never away
            for (uint f = 0; f < labFacings.length(); ++f) {
                const int ff = labFacings[f];
                for (int i = 0; i < ZoneCount(); ++i) {
                    const int nid = aiTerrainMgr.PackNearGroup(ZoneAt(i), t2, nanoGroup, ff, TurretSeed(), 0.0f, 0.0f, 0);
                    if (nid < 0) continue;
                    return OrderLabOn(t2, nid, timeout, true, "nearest a turret slot, facing " + ff + ", at");
                }
            }
            IUnitTask@ t = Builder::EnqueueT2BotLabIfNeeded(side, Global::Map::StartPos, 0.0f, timeout);
            if (t !is null) GenericHelpers::LogUtil("[Layout] advanced lab on the pair's slot (" + int(pairPos.x) + ", " + int(pairPos.z)
                + "): " + pairScore + " turret slots within " + int(reach) + "; no footprint in the turret layout is reached by more", 1);
            return t;
        }
        const int id = aiTerrainMgr.PackNearGroupMost(bestZone, t2, nanoGroup, LabFacing(), reach, Global::RoleSettings::Tech::LayoutLabFlushElmos, 0, TurretSeed());   // D-096   // D-085: nearest the seed among the most-reached sites
        if (id < 0) {
            GenericHelpers::LogUtil("[Layout] advanced lab: the turret-layout footprint could not be reserved; the pair's slot is used", 1);
            return Builder::EnqueueT2BotLabIfNeeded(side, Global::Map::StartPos, 0.0f, timeout);
        }
        return OrderLabOn(t2, id, timeout, true, "in the turret layout (most slots reach it, nearest the seed) at");
    }

    // ---------------------------------------------------------------- overlay

    // Compatibility wrappers; the shared widget service handles every role.
    void SetOverlay(bool on) { WidgetLink::SetLayoutOverlay(on); }

}
