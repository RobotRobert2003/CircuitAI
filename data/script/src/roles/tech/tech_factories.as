// TECH D-114: land factories move toward the front. From +200 metal every new
// land factory (T1 / T2 bot or vehicle lab, T3 gantry) stands in its own front
// factory cluster: the factory plus a block of construction turrets directly
// behind it (T1 2, T2 4, T3 6), turrets built first. A cluster is placed on the
// first spot, at least FrontMinShare of the way from the base toward the front
// and further forward as needed, where the factory and its turret block fit on
// flat, buildable ground with a clear exit lane; away from allied buildings when
// possible, close to them when nothing else fits. Clusters never move back: the
// search starts where the furthest one stands. With FrontReclaimAtCount land
// factories on the map, the land factories at the main base are reclaimed and
// their ground goes back to the economy; with none on the map, the base may
// hold one again.
// Design and evidence: doc/decisions.md D-114; roles/tech_factories.md.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/construction/guard_helpers.as"
#include "../../manager/builder.as"
#include "../../systems/construction/layout.as"
#include "../../systems/construction/lifecycle.as"
#include "tech_build.as"
#include "tech_gantry.as"

namespace TechFactories {

    float Sq(float v) { return v * v; }

    array<string> LandFactoryNames()
    {
        array<string> names;
        array<array<string>> lists = { UnitHelpers::GetAllT1BotLabs(), UnitHelpers::GetAllT1VehicleLabs(),
            UnitHelpers::GetAllT2BotLabs(), UnitHelpers::GetAllT2VehicleLabs(), UnitHelpers::GetAllLandGantries() };
        for (uint i = 0; i < lists.length(); ++i)
            for (uint k = 0; k < lists[i].length(); ++k)
                if (lists[i][k].length() > 0) names.insertLast(lists[i][k]);
        return names;
    }
    bool IsLandFactory(const string &in name) { return LandFactoryNames().find(name) >= 0; }
    bool IsLandFactory(const CCircuitDef@ d) { return d !is null && IsLandFactory(d.GetName()); }
    // every land factory of ours on the map, frames included
    int LandFactoryCount() { return AiMax(0, UnitDefHelpers::SumUnitDefCounts(LandFactoryNames()) - TechFlank::Count()); }
    int TierOf(const string &in name)
    {
        if (UnitHelpers::IsLandGantry(name)) return 3;
        if (UnitHelpers::GetAllT2BotLabs().find(name) >= 0 || UnitHelpers::GetAllT2VehicleLabs().find(name) >= 0) return 2;
        return 1;
    }
    void TurretBlock(int tier, int &out cols, int &out rows)
    {
        if (tier >= 3) { cols = Global::RoleSettings::Tech::FrontT3TurretCols; rows = Global::RoleSettings::Tech::FrontT3TurretRows; }
        else if (tier == 2) { cols = Global::RoleSettings::Tech::FrontT2TurretCols; rows = Global::RoleSettings::Tech::FrontT2TurretRows; }
        else { cols = Global::RoleSettings::Tech::FrontT1TurretCols; rows = Global::RoleSettings::Tech::FrontT1TurretRows; }
    }

    // Front placement applies from the economy's +200 (EcoOnline) while a land
    // factory stands anywhere; with none on the map the base may hold one again
    bool Active() { return TechBuild::EcoOnline() && LandFactoryCount() > 0; }

    // ---------------------------------------------------------------- clusters

    class Cluster {
        string defName;
        int tier = 1;
        int labRes = -1;             // the factory's reservation (forgotten by native once built)
        AIFloat3 pos;                // the factory's site
        int facing = 0;
        int exitZone = 0;
        int envelope = 0;
        bool started = false;
        string aheadKey;
        int nanoGroup = 0;           // its turret block
        array<AIFloat3> turretPos;   // the turret slots ordered so far (script's record: built slots are forgotten)
        int slots = 0;               // the block's size
        float share = 0.0f;          // how far toward the front, 0..1
        int labId = -1;
        int orderedFrame = -100000;
        int standFrame = -1;         // first seen finished (INV-038)
        int invLog = -100000;
        bool labSeen = false;        // its factory (a frame or finished) seen (INV-045)
        int turretFrame = -1;        // the last turret order or frame seen
        int plannedFrame = -1;       // INV-046
        bool ahead = false;          // reserved ground only, no spending authority
        bool built = false;          // its factory stood once: native forgot labRes, a rebuild re-reserves
        int gantryProgressFrame = -1;
        int gantryCompletedTurrets = 0;
        bool gantryFallback = false;
        bool earlyGantry = false; // budget/path checks apply only to this optional admission
        IUnitTask@ gantrySupportTask; // native owns its command/recovery lifecycle
        IUnitTask@ labTask;          // the factory's order while it lives (builders join it)
        Row@ row;                    // D-117: a T1 spam lab's row
        int rowK = 0;                // D-117: its place in the row (0 = the row's first lab)
        int invOpenLog = -100000;    // INV-046
    }
    array<Cluster@> clusters;
    // Existing order is chosen in stable cluster insertion order. Planning-only
    // reservations never acquire spending authority through a builder ask.
    Cluster@ ExistingGantry(const string& in definitionName = "") {
        for (uint index = 0; index < clusters.length(); ++index) {
            Cluster@ cluster = clusters[index];
            if (cluster.ahead || cluster.tier < 3 || cluster.labRes < 0) continue;
            if (definitionName.length() > 0 && cluster.defName != definitionName) continue;
            CCircuitUnit@ factory = LabAt(cluster);
            if (factory is null || factory.GetBuildProgress() < 1.0f) return cluster;
        }
        return null;
    }
    float reachShare = 0.0f;         // the furthest cluster's share: the search never goes back
    dictionary searchTry;            // def name -> frame of the last failed search
    int searchLog = -100000;

    // D-102 (owner): the advanced lab goes back up before any T1 lab. Once the
    // economy is online a T1 front lab waits for a finished advanced lab (INV-025);
    // with none, rule lab.front plans and builds a T2 front cluster
    // a finished advanced lab that is not retiring (played: a T1 lab ordered while
    // the rezoned base advanced lab was being reclaimed started after it was gone)
    bool AdvancedLabUp()
    {
        const array<string> t2 = UnitHelpers::GetAllT2BotLabs();
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null) continue;
            if (ai.GetTeamUnit(f.id) is null || t2.find(f.circuitDef.GetName()) < 0 || TechFlank::Owns(f)) continue;
            if (f.GetBuildProgress() >= 1.0f && !Lifecycle::IsRetiring(f)) return true;
        }
        return false;
    }
    CCircuitDef@ AdvancedLabDef()
    {
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
        return d;   // no IsAvailable: TECH's start caps hide it; Work lifts the cap
    }
    // any advanced lab of ours not retiring, a frame included (played on build96:
    // the base's new advanced lab was a frame, so a second was planned at the front)
    bool AdvancedLabAny()
    {
        const array<string> t2 = UnitHelpers::GetAllT2BotLabs();
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null) continue;
            if (ai.GetTeamUnit(f.id) is null || t2.find(f.circuitDef.GetName()) < 0 || TechFlank::Owns(f)) continue;
            if (!Lifecycle::IsRetiring(f)) return true;
        }
        CCircuitDef@ d = AdvancedLabDef();
        return d !is null && aiBuilderMgr.GetUnfinishedCount(d) > TechFlank::Count(true);
    }
    bool NeedAdvancedLab()
    {
        if (!Active() || AdvancedLabAny() || AdvancedLabDef() is null) return false;
        for (uint i = 0; i < clusters.length(); ++i)
            if (!clusters[i].ahead && clusters[i].tier == 2 && clusters[i].labRes >= 0 && LabAt(clusters[i]) is null) return false;   // one open already: OpenAbove carries it
        return true;
    }

    CCircuitDef@ Nano() { return ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side)); }

    CCircuitUnit@ LabAt(Cluster@ c)
    {
        if (c.labId >= 0) {
            CCircuitUnit@ u = ai.GetTeamUnit(c.labId);
            if (u !is null) {
                if (u.GetBuildProgress() >= 1.0f) c.built = true;
                return u;
            }
            c.labId = -1;
        }
        CCircuitDef@ d = ai.GetCircuitDef(c.defName);
        if (d is null) return null;
        CCircuitUnit@ f = aiBuilderMgr.FindOwnNear(c.pos, 48.0f, d);
        if (f is null) @f = aiBuilderMgr.FindUnfinishedNear(c.pos, 48.0f, d);
        if (f !is null) c.labId = f.id;
        return f;
    }
    CCircuitUnit@ TurretAt(const AIFloat3& in p)
    {
        CCircuitDef@ nano = Nano();
        if (nano is null) return null;
        CCircuitUnit@ t = aiBuilderMgr.FindOwnNear(p, 32.0f, nano);
        if (t is null) @t = aiBuilderMgr.FindUnfinishedNear(p, 32.0f, nano);
        return t;
    }
    int TurretsOf(Cluster@ c)
    {
        int n = 0;
        for (uint k = 0; k < c.turretPos.length(); ++k) if (TurretAt(c.turretPos[k]) !is null) ++n;
        return n;
    }
    int FinishedTurrets(Cluster@ c)
    {
        CCircuitDef@ nano = Nano();
        if (nano is null) return 0;
        int n = 0;
        for (uint k = 0; k < c.turretPos.length(); ++k) {
            CCircuitUnit@ t = aiBuilderMgr.FindOwnNear(c.turretPos[k], 32.0f, nano);
            if (t !is null) ++n;
        }
        return n;
    }
    bool IsClusterLab(CCircuitUnit@ u)
    {
        if (u is null) return false;
        for (uint i = 0; i < clusters.length(); ++i) {
            CCircuitUnit@ l = LabAt(clusters[i]);
            if (l !is null && l.id == u.id) return true;
        }
        return false;
    }
    // The turrets that stand finished before a cluster's factory is ordered: the
    // whole block (D-114), a gantry's first FrontT3TurretsFirst of its 50 (D-119)
    int TurretsBeforeLab(Cluster@ c)
    {
        if (c.tier >= 3 && Global::RoleSettings::Tech::FrontT3TurretsFirst < c.slots) return Global::RoleSettings::Tech::FrontT3TurretsFirst;
        return c.slots;
    }
    // D-119: a lab placed for spam (a T1 front cluster's), never assisted but by its two turrets
    bool IsSpamLab(CCircuitUnit@ u)
    {
        if (u is null) return false;
        for (uint i = 0; i < clusters.length(); ++i) {
            if (clusters[i].tier != 1) continue;
            CCircuitUnit@ l = LabAt(clusters[i]);
            if (l !is null && l.id == u.id) return true;
        }
        return false;
    }
    // D-119: `t` is one of the turrets of the cluster whose lab is `lab`
    bool IsOwnTurret(CCircuitUnit@ t, CCircuitUnit@ lab)
    {
        if (t is null || t.circuitDef is null || t.circuitDef.IsMobile()) return false;
        Cluster@ c = ClusterOfTurret(t);
        if (c is null) return false;
        CCircuitUnit@ l = LabAt(c);
        return l !is null && lab !is null && l.id == lab.id;
    }

    // ---------------------------------------------------------------- the search

    // Is the cluster at p (factory site, its turret block behind it) on flat,
    // buildable ground with its exit clear; `roomy`: also clear of other
    // buildings (ours and allies') by FrontClearCells all round
    bool Fits(CCircuitDef@ lab, CCircuitDef@ nano, const AIFloat3& in p, int facing, int rows, bool roomy)
    {
        const float cell = SQUARE_SIZE * 2;
        const float halfAcross = float(Layout::Across(lab, facing)) * 0.5f * cell;
        const float depth = float(Layout::Along(lab, facing) + rows * Layout::Along(nano, facing));
        const float halfAlong = depth * 0.5f * cell;
        // the cluster's centre: half the turret block behind the factory's centre
        const AIFloat3 centre = p - Layout::Fwd(facing) * (float(rows * Layout::Along(nano, facing)) * 0.5f * cell);
        const float m = 64.0f;
        if (p.x < m || p.z < m || p.x > float(AiTerrainWidth()) - m || p.z > float(AiTerrainHeight()) - m) return false;
        if (aiTerrainMgr.FlatFraction(centre, facing, halfAcross, halfAlong, Global::RoleSettings::Tech::LayoutBoxMaxSlope)
            < Global::RoleSettings::Tech::FrontMinFlat) return false;
        if (roomy) {
            if (aiTerrainMgr.IsZoneAlly(p)) return false;
            const float clear = float(Global::RoleSettings::Tech::FrontClearCells) * cell;
            if (aiTerrainMgr.BuildableFraction(lab, centre, halfAcross + clear, halfAlong + clear, facing) < Global::RoleSettings::Tech::FrontRoomyShare)
                return false;
        }
        return aiTerrainMgr.CanReserveBuilding(lab, p, facing) && aiTerrainMgr.IsExitClear(lab, p, facing, 320.0f, 32.0f);
    }

    // ---------------------------------------------------------------- spam rows (D-117)

    // Owner's rule: T1 spam labs stand side by side in rows of up to
    // FrontRowMaxLabs, each with exactly its two turrets behind it; a row may be a
    // single lab where the ground allows no more. A row never cramps the ground:
    // beside it a lane FrontT3LaneCells wide, passable and held clear (a corridor:
    // nothing of ours is placed on it) lets the largest T3 walk from the factories
    // behind to the front. A row needs at least one such lane.
    class Row {
        AIFloat3 origin;             // the first lab's site (k = 0)
        int facing = 0;
        int minK = 0, maxK = 0;      // the labs' places, k across the row
        int laneL = 0, laneR = 0;    // the corridor zones at each end (0 = none)
        array<Cluster@> labs;
    }
    array<Row@> spamRows;

    int RowPitchCells(CCircuitDef@ lab, CCircuitDef@ nano, int facing)
    {
        int cols, rows;
        TurretBlock(1, cols, rows);
        const int wide = (Layout::Across(lab, facing) > cols * Layout::Across(nano, facing)) ? Layout::Across(lab, facing) : cols * Layout::Across(nano, facing);
        return wide + Global::RoleSettings::Tech::FrontRowGapCells;
    }
    AIFloat3 RowSlot(Row@ r, CCircuitDef@ lab, CCircuitDef@ nano, int k)
    {
        return r.origin + Layout::Side(r.facing) * (float(k * RowPitchCells(lab, nano, r.facing)) * SQUARE_SIZE * 2);
    }
    // The lane beside place k on side dir (-1 / +1): its centre, across the whole
    // depth of the cluster (the lab, its turrets) and FrontT3LaneCells beyond
    // both ends, so a unit can enter and leave it
    void LaneBox(CCircuitDef@ lab, CCircuitDef@ nano, const AIFloat3& in slot, int facing, int dir, AIFloat3 &out centre, float &out halfAcross, float &out halfAlong)
    {
        int cols, rows;
        TurretBlock(1, cols, rows);
        const float cell = SQUARE_SIZE * 2;
        const int lane = Global::RoleSettings::Tech::FrontT3LaneCells;
        const int depth = Layout::Along(lab, facing) + rows * Layout::Along(nano, facing) + 2 * lane;
        const int wide = RowPitchCells(lab, nano, facing) - Global::RoleSettings::Tech::FrontRowGapCells;
        halfAcross = float(lane) * 0.5f * cell;
        halfAlong = float(depth) * 0.5f * cell;
        const float back = float(rows * Layout::Along(nano, facing)) * 0.5f * cell;   // the cluster's centre is behind the lab's
        centre = slot + Layout::Side(facing) * (float(dir) * (float(wide) * 0.5f + float(lane) * 0.5f) * cell) - Layout::Fwd(facing) * back;
    }
    bool LanePassable(CCircuitDef@ nano, const AIFloat3& in centre, float halfAcross, float halfAlong, int facing)
    {
        const float m = 64.0f;
        if (centre.x < m || centre.z < m || centre.x > float(AiTerrainWidth()) - m || centre.z > float(AiTerrainHeight()) - m) return false;
        const float need = Global::RoleSettings::Tech::FrontLaneMinFlat;
        return aiTerrainMgr.FlatFraction(centre, facing, halfAcross, halfAlong, Global::RoleSettings::Tech::LayoutBoxMaxSlope) >= need
            && aiTerrainMgr.BuildableFraction(nano, centre, halfAcross, halfAlong, facing) >= need;
    }
    // Hold the lane beside place k on side dir as a corridor; 0 when it is not passable
    // (`again`: a lane the row held a moment ago, put back without the test: wrecks
    // or units on it since do not lose it, D-119, INV-047)
    int HoldLane(CCircuitDef@ lab, CCircuitDef@ nano, const AIFloat3& in slot, int facing, int dir, bool again = false)
    {
        AIFloat3 c; float ha, hl;
        LaneBox(lab, nano, slot, facing, dir, c, ha, hl);
        if (!again && !LanePassable(nano, c, ha, hl, facing)) return 0;
        return aiTerrainMgr.ReserveZone(c, facing, ha, hl, true);
    }
    // A new lab at the end of a row with room; the lane at that end moves out
    // past it. Null when no row can take one.
    dictionary rowWhy;   // row and end -> frame of its last reason logged
    // D-119: which of Fits' tests a place fails, for the log
    string WhyNotFits(CCircuitDef@ lab, CCircuitDef@ nano, const AIFloat3& in p, int facing, int rows)
    {
        const float cell = SQUARE_SIZE * 2;
        const float halfAcross = float(Layout::Across(lab, facing)) * 0.5f * cell;
        const float halfAlong = float(Layout::Along(lab, facing) + rows * Layout::Along(nano, facing)) * 0.5f * cell;
        const AIFloat3 centre = p - Layout::Fwd(facing) * (float(rows * Layout::Along(nano, facing)) * 0.5f * cell);
        const float m = 64.0f;
        if (p.x < m || p.z < m || p.x > float(AiTerrainWidth()) - m || p.z > float(AiTerrainHeight()) - m) return "off the map";
        if (aiTerrainMgr.FlatFraction(centre, facing, halfAcross, halfAlong, Global::RoleSettings::Tech::LayoutBoxMaxSlope)
            < Global::RoleSettings::Tech::FrontMinFlat) return "the ground is not flat";
        if (!aiTerrainMgr.CanReserveBuilding(lab, p, facing)) {
            // which: our own reservations or zones on it, or ground/structures the engine refuses
            int held = 0, cells = 0;
            const int ax = Layout::Across(lab, facing), al = Layout::Along(lab, facing);
            for (int i = 0; i < ax; ++i) for (int j = 0; j < al; ++j) {
                const AIFloat3 q = p + Layout::Side(facing) * ((float(i) - float(ax - 1) * 0.5f) * cell) + Layout::Fwd(facing) * ((float(j) - float(al - 1) * 0.5f) * cell);
                ++cells;
                if (aiTerrainMgr.IsReserved(q)) ++held;
            }
            const float b = aiTerrainMgr.BuildableFraction(lab, p, halfAcross, float(al) * 0.5f * cell, facing);
            return "the footprint is taken or refused (" + held + " of " + cells + " cells reserved by us, " + int(b * 100.0f) + "% buildable)";
        }
        if (!aiTerrainMgr.IsExitClear(lab, p, facing, 320.0f, 32.0f)) return "the exit is blocked";
        return "unknown";
    }
    Cluster@ ExtendRow(CCircuitDef@ lab, CCircuitDef@ nano)
    {
        int cols, rows;
        TurretBlock(1, cols, rows);
        for (uint i = 0; i < spamRows.length(); ++i) {
            Row@ r = spamRows[i];
            if (int(r.labs.length()) >= Global::RoleSettings::Tech::FrontRowMaxLabs) continue;
            for (int s = 0; s < 2; ++s) {
                const int dir = (s == 0) ? 1 : -1;
                const int k = (dir > 0) ? r.maxK + 1 : r.minK - 1;
                const AIFloat3 p = RowSlot(r, lab, nano, k);
                // the end's lane stands on the new place: let it go, try, else hold it again
                const int old = (dir > 0) ? r.laneR : r.laneL;
                if (old > 0) aiTerrainMgr.ReleaseZone(old);
                bool placed = false;
                int id = -1, g = 0, lane = 0;
                string why = "";   // D-119: why a row did not grow (logged once a minute)
                if (Fits(lab, nano, p, r.facing, rows, false)) {
                    id = aiTerrainMgr.ReserveBuilding(lab, p, r.facing);
                    if (id >= 0) {
                        g = aiTerrainMgr.ReserveNanoBlockAt(nano, lab, aiTerrainMgr.GetReservationPos(id), r.facing, cols, rows, 0);
                        if (g > 0 && aiTerrainMgr.GetGroupCount(g, false) >= cols * rows) {
                            lane = HoldLane(lab, nano, aiTerrainMgr.GetReservationPos(id), r.facing, dir);
                            // this end may close only when the other end still holds a lane
                            placed = (lane > 0) || (((dir > 0) ? r.laneL : r.laneR) > 0);
                            if (!placed) why = "no T3 lane would stay open";
                        } else why = "its two turret slots are not free";
                    } else why = "the lab's footprint cannot be reserved";
                } else why = WhyNotFits(lab, nano, p, r.facing, rows);
                const string whyKey = "" + i + ((dir > 0) ? "R" : "L");
                int64 whyAt = -100000;
                rowWhy.get(whyKey, whyAt);
                if (!placed && ai.frame - whyAt >= 60 * SECOND) {
                    rowWhy.set(whyKey, int64(ai.frame));
                    GenericHelpers::LogUtil("[TECH][Factories] spam row " + (i + 1) + " cannot grow " + ((dir > 0) ? "right" : "left")
                        + " at (" + int(p.x) + ", " + int(p.z) + "): " + why + " (D-119)", 1);
                }
                if (!placed) {
                    if (lane > 0) aiTerrainMgr.ReleaseZone(lane);
                    if (g > 0) aiTerrainMgr.ReleaseGroup(g);
                    if (id >= 0) aiTerrainMgr.ReleaseReservation(id);
                    const AIFloat3 edge = RowSlot(r, lab, nano, (dir > 0) ? r.maxK : r.minK);
                    const int back = (old > 0) ? HoldLane(lab, nano, edge, r.facing, dir, true) : 0;
                    if (dir > 0) r.laneR = back; else r.laneL = back;
                    continue;
                }
                if (dir > 0) { r.maxK = k; r.laneR = lane; } else { r.minK = k; r.laneL = lane; }
                Cluster@ c = NewCluster(lab, 1, id, aiTerrainMgr.GetReservationPos(id), r.facing, g, cols * rows, r.labs[0].share);
                @c.row = r;
                c.rowK = k;
                r.labs.insertLast(c);
                GenericHelpers::LogUtil("[TECH][Factories] T1 cluster " + clusters.length() + " for " + lab.GetName() + " joins spam row " + (i + 1)
                    + " (lab " + r.labs.length() + " of up to " + Global::RoleSettings::Tech::FrontRowMaxLabs + ", side by side), 2 turrets behind it; T3 lanes: "
                    + ((r.laneL > 0) ? "left" : "") + ((r.laneL > 0 && r.laneR > 0) ? " and " : "") + ((r.laneR > 0) ? "right" : "") + " (D-117)", 1);
                return c;
            }
        }
        return null;
    }
    Cluster@ NewCluster(CCircuitDef@ lab, int tier, int id, const AIFloat3& in lp, int facing, int g, int slots, float s)
    {
        Cluster@ c = Cluster();
        c.defName = lab.GetName();
        c.tier = tier;
        c.labRes = id;
        c.pos = lp;
        c.facing = facing;
        c.nanoGroup = g;
        c.share = s;
        c.slots = slots;   // turretPos is filled as each slot's turret is ordered
        c.plannedFrame = ai.frame;
        const string key = "tech.cluster." + id;
        c.envelope = aiTerrainMgr.GetLayoutInt(key + ".envelope", 0);
        if (c.envelope == 0) {
            c.envelope = aiTerrainMgr.ReserveClusterEnvelope(id, g);
            aiTerrainMgr.SetLayoutInt(key + ".envelope", c.envelope);
        }
        c.started = aiTerrainMgr.GetLayoutInt(key + ".started", 0) != 0;
        clusters.insertLast(c);
        return c;
    }

    // D-119: a gantry's turret blocks, biggest first (cols, rows): 50, 40, 32, 24, 18, 6
    const array<int> T3Blocks = { 10, 5, 8, 5, 8, 4, 6, 4, 6, 3, 3, 2 };

    // The first spot, at least FrontMinShare of the way toward the front (and no
    // nearer than the furthest cluster), where the cluster fits: along the line
    // from the home centre to the front, FrontShareStep at a time, and across it
    // at each step; roomy spots first (away from other buildings), then any
    Cluster@ Plan(CCircuitDef@ lab, bool ahead = false, bool earlyGantry = false)
    {
        CCircuitDef@ nano = Nano();
        if (lab is null || nano is null) return null;
        int64 t;
        if (searchTry.get(lab.GetName(), t) && ai.frame - t < 10 * SECOND) return null;
        const int tier = TierOf(lab.GetName());
        int cols, rows;
        TurretBlock(tier, cols, rows);
        if (tier == 1 && !ahead) {   // D-117: side by side in a row first
            Cluster@ joined = ExtendRow(lab, nano);
            if (joined !is null) return joined;
        }
        const AIFloat3 home = Layout::HomeCentre();
        const AIFloat3 front = Layout::FrontTarget();
        const float dx = front.x - home.x, dz = front.z - home.z;
        const float dist = sqrt(dx * dx + dz * dz);
        if (dist < 1.0f) return null;
        const float ux = dx / dist, uz = dz / dist;
        const int facing = Layout::LabFacing();
        // one cluster's width (the factory or its turret block, whichever is wider) and a lane
        const int wide = (Layout::Across(lab, facing) > cols * Layout::Across(nano, facing)) ? Layout::Across(lab, facing) : cols * Layout::Across(nano, facing);
        const float pitch = float(wide + Global::RoleSettings::Tech::SpamLabGapCells) * SQUARE_SIZE * 2;
        const float start = (reachShare > Global::RoleSettings::Tech::FrontMinShare) ? reachShare : Global::RoleSettings::Tech::FrontMinShare;
        for (int pass = 0; pass < 2; ++pass) {
            const bool roomy = (pass == 0);
            for (float s = start; s <= Global::RoleSettings::Tech::FrontMaxShare + 0.001f; s += Global::RoleSettings::Tech::FrontShareStep) {
                const float bx = home.x + ux * s * dist, bz = home.z + uz * s * dist;
                for (int k = 0; k <= 2 * Global::RoleSettings::Tech::FrontLateralTries; ++k) {
                    const float off = (k == 0) ? 0.0f : float((k + 1) / 2) * pitch * ((k % 2 == 1) ? 1.0f : -1.0f);
                    const AIFloat3 p(bx - uz * off, home.y, bz + ux * off);
                    // D-119: a gantry needs room for its smallest block; the biggest that fits is taken below
                    if (!Fits(lab, nano, p, facing, (tier >= 3) ? T3Blocks[T3Blocks.length() - 1] : rows, roomy)) continue;
                    if (tier >= 3 && earlyGantry && !TechGantry::ReachableBattlefield(p, facing)) continue;
                    const int id = aiTerrainMgr.ReserveBuilding(lab, p, facing);
                    if (id < 0) continue;
                    const AIFloat3 lp = aiTerrainMgr.GetReservationPos(id);
                    int g = 0;
                    int bc = cols, br = rows;
                    // D-119 (owner): a gantry's block holds up to 50 turrets; where the
                    // ground is smaller, the biggest block that fits
                    for (uint o = 0; o < T3Blocks.length(); o += 2) {
                        if (tier < 3 && o > 0) break;
                        if (tier >= 3) { bc = T3Blocks[o]; br = T3Blocks[o + 1]; }
                        g = aiTerrainMgr.ReserveNanoBlockAt(nano, lab, lp, facing, bc, br, 0);
                        if (g > 0 && aiTerrainMgr.GetGroupCount(g, false) >= bc * br && aiTerrainMgr.GetGroupActivationState(g) == 0) break;
                        if (g > 0) {
                            const int groupZone = aiTerrainMgr.GetGroupZone(g);
                            if (groupZone > 0) aiTerrainMgr.ReleaseZone(groupZone); else aiTerrainMgr.ReleaseGroup(g);
                        }
                        g = 0;
                    }
                    if (g <= 0) {
                        aiTerrainMgr.ReleaseReservation(id);
                        continue;
                    }
                    cols = bc; rows = br;
                    // D-117: a spam lab starts a row, and a row never cramps the
                    // ground: at least one passable T3 lane beside it, held
                    int laneL = 0, laneR = 0;
                    if (tier == 1) {
                        laneL = HoldLane(lab, nano, lp, facing, -1);
                        laneR = HoldLane(lab, nano, lp, facing, 1);
                        if (laneL <= 0 && laneR <= 0) {
                            aiTerrainMgr.ReleaseGroup(g);
                            aiTerrainMgr.ReleaseReservation(id);
                            continue;
                        }
                    }
                    Cluster@ c = NewCluster(lab, tier, id, lp, facing, g, cols * rows, s);
                    c.earlyGantry = earlyGantry;
                    if (tier >= 3 && !ahead) Builder::MarkGantryEnqueued();
                    if (tier == 1) {
                        Row@ r = Row();
                        r.origin = lp;
                        r.facing = facing;
                        r.laneL = laneL;
                        r.laneR = laneR;
                        r.labs.insertLast(c);
                        @c.row = r;
                        spamRows.insertLast(r);
                        GenericHelpers::LogUtil("[TECH][Factories] spam row " + spamRows.length() + " begins; T3 lanes: "
                            + ((laneL > 0) ? "left" : "") + ((laneL > 0 && laneR > 0) ? " and " : "") + ((laneR > 0) ? "right" : "") + " (D-117)", 1);
                    }
                    if (!ahead && s > reachShare) reachShare = s;
                    GenericHelpers::LogUtil("[TECH][Factories] T" + tier + " cluster " + clusters.length() + " for " + lab.GetName() + " at (" + int(lp.x) + ", " + int(lp.z)
                        + "), " + int(s * 100.0f) + "% toward the front, " + (cols * rows) + " turrets behind it" + (roomy ? "" : " (close to other buildings: no roomier spot)") + " (D-114)", 1);
                    return c;
                }
            }
        }
        searchTry.set(lab.GetName(), ai.frame);
        if (ai.frame - searchLog > 60 * SECOND) {
            searchLog = ai.frame;
            GenericHelpers::LogUtil("[TECH][Factories] no spot for a " + lab.GetName() + " cluster between " + int(start * 100.0f) + "% and "
                + int(Global::RoleSettings::Tech::FrontMaxShare * 100.0f) + "% toward the front (D-114)", 1);
        }
        return null;
    }

    // ---------------------------------------------------------------- orders

    int lastOrder = -1;   // INV-039 input (T1 forward work)
    IUnitTask@ OrderPinned(CCircuitUnit@ u, Task::BuildType type, CCircuitDef@ d, int id, const string &in what)
    {
        if (type == Task::BuildType::NANO && Layout::TurretsCapped()) return null;
        // A claimed/framed/retired slot belongs to its existing lifecycle.
        // Avoid allocating a task solely to discover that pinning must fail.
        if (d is null || aiTerrainMgr.GetReservationState(id) != 0) return null;
        const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
        IUnitTask@ t = (type == Task::BuildType::FACTORY)
            ? aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::HIGH, d, p, null, 0.0f, false, true, 300 * SECOND))
            : aiBuilderMgr.Enqueue(TaskB::Common(type, Task::Priority::HIGH, d, p, 0.0f, true, 120 * SECOND));
        if (t is null) return null;
        if (!AiPinReservation(t, id)) {
            GenericHelpers::LogUtil("[TECH][Factories] could not pin " + what + " to slot " + id, 1);
            // Abort only this task; a failed claim may be owned by another task.
            aiBuilderMgr.AbortTask(t);
            return null;
        }
        lastOrder = ai.frame;
        GenericHelpers::LogUtil("[TECH][Factories] " + ((u is null) ? "order" : (u.circuitDef.GetName() + " " + u.id + " orders")) + " " + what
            + " at (" + int(p.x) + ", " + int(p.z) + ") (D-114)", 1);
        return t;
    }

    Cluster@ ReadyCluster(Cluster@ c)
    {
        if (c is null || c.started) return c;
        const int groupState = aiTerrainMgr.GetGroupActivationState(c.nanoGroup);
        const int labState = aiTerrainMgr.GetReservationState(c.labRes);
        if (groupState == 2 || (labState >= 1 && labState <= 3)) {
            c.started = true;
            aiTerrainMgr.SetLayoutInt("tech.cluster." + c.labRes + ".started", 1);
            return c;
        }
        if (groupState == 0 && aiTerrainMgr.IsReservationBuildable(c.labRes)) return c;
        GenericHelpers::LogUtil("[TECH][Expansion] relocate blocked unused " + c.defName + " slot=" + c.labRes, 1);
        const int zone = aiTerrainMgr.GetGroupZone(c.nanoGroup);
        if (zone > 0) aiTerrainMgr.ReleaseZone(zone); else aiTerrainMgr.ReleaseGroup(c.nanoGroup);
        aiTerrainMgr.ReleaseReservation(c.labRes);
        if (c.exitZone > 0) aiTerrainMgr.ReleaseZone(c.exitZone);
        if (c.envelope > 0) aiTerrainMgr.ReleaseZone(c.envelope);
        if (c.row !is null && c.row.labs.length() == 1) {
            if (c.row.laneL > 0) aiTerrainMgr.ReleaseZone(c.row.laneL);
            if (c.row.laneR > 0) aiTerrainMgr.ReleaseZone(c.row.laneR);
            const int rowIndex = spamRows.findByRef(c.row);
            if (rowIndex >= 0) spamRows.removeAt(rowIndex);
        }
        if (c.aheadKey.length() > 0) {
            aiTerrainMgr.SetLayoutInt(c.aheadKey + ".slot", -1);
            aiTerrainMgr.SetLayoutInt(c.aheadKey + ".exit", 0);
            aiTerrainMgr.SetLayoutInt(c.aheadKey + ".left", 0);
            aiTerrainMgr.SetLayoutInt(c.aheadKey + ".right", 0);
        }
        c.labRes = -1; c.nanoGroup = 0; c.envelope = 0; c.exitZone = 0;
        c.ahead = true; // an abandoned plan must not count as an active tier/cooldown
        return Plan(ai.GetCircuitDef(c.defName), false, c.earlyGantry);
    }

    // The cluster a new `def` goes into: one of that def whose factory does not
    // stand yet, else a new one
    Cluster@ OpenCluster(CCircuitDef@ def, bool planNew, bool earlyGantry = false)
    {
        for (uint i = 0; i < clusters.length(); ++i) {
            Cluster@ c = clusters[i];
            if (c.defName == def.GetName() && LabAt(c) is null && c.labRes >= 0) {
                if (c.ahead) {
                    if (!planNew || !MayPlan(def)) continue;
                    if (earlyGantry && !TechGantry::ReachableBattlefield(c.pos, c.facing)) continue;
                    c.earlyGantry = earlyGantry; // preserve the path requirement if an unused plan relocates
                    @c = ReadyCluster(c);
                    if (c is null) return null;
                    c.ahead = false;
                    c.earlyGantry = earlyGantry;
                    c.plannedFrame = ai.frame;
                    if (c.share > reachShare) reachShare = c.share;
                    if (c.tier >= 3) Builder::MarkGantryEnqueued();
                    if (c.aheadKey.length() > 0) {
                        aiTerrainMgr.SetLayoutInt(c.aheadKey + ".slot", -1);
                        aiTerrainMgr.SetLayoutInt(c.aheadKey + ".exit", 0);
                    }
                    GenericHelpers::LogUtil("[TECH][Expansion] activated " + c.defName + " slot=" + c.labRes, 1);
                }
                return c;
            }
        }
        return planNew ? Plan(def, false, earlyGantry) : null;
    }

    // Owner's rule: the turret block first, then the factory. Returns the next
    // piece of work for the cluster of `def` (a turret, the factory, or help on
    // either going up), or null
    IUnitTask@ Work(CCircuitDef@ def, CCircuitUnit@ u, bool planNew = true)
    {
        if (def is null) return null;
        if (UnitHelpers::IsLandGantry(def.GetName()) && TechGantry::RecoveryEnabled()) {
            Cluster@ gantry = ExistingGantry(def.GetName());
            if (gantry is null) @gantry = OpenCluster(def, planNew && MayPlan(def));
            @gantry = ReadyCluster(gantry);
            return TechGantry::Work(gantry, def, u);
        }
        if (TechForward::Recalled(u)) return null;   // its tier is recalled to the eco clusters (D-109)
        CCircuitDef@ nano = Nano();
        if (nano is null) return null;
        Cluster@ c = ReadyCluster(OpenCluster(def, planNew && MayPlan(def)));
        if (c is null) return null;
        const int idx = clusters.findByRef(c) + 1;
        // D-119: a gantry is ordered once FrontT3TurretsFirst of its (up to 50)
        // turrets stand; a builder that can build it takes that order first, the
        // turret orders go on filling the block
        const int first = TurretsBeforeLab(c);
        const bool labDue = c.tier >= 3 && (c.labTask is null || c.labTask.IsDead()) && (u is null || u.circuitDef.CanBuild(def))
            && FinishedTurrets(c) >= first;
        // 1. the turrets
        const int sid = labDue ? -1 : aiTerrainMgr.NextSlotAny(c.nanoGroup, c.pos);
        if (sid >= 0 && (u is null || u.circuitDef.CanBuild(nano))) {
            const AIFloat3 sp = aiTerrainMgr.GetReservationPos(sid);
            bool known = false;
            for (uint q = 0; q < c.turretPos.length(); ++q) if (MapHelpers::SqDist(c.turretPos[q], sp) < 16.0f) known = true;
            if (!known) c.turretPos.insertLast(sp);
            c.turretFrame = ai.frame;
            c.started = true;
            aiTerrainMgr.SetLayoutInt("tech.cluster." + c.labRes + ".started", 1);
            return OrderPinned(u, Task::BuildType::NANO, nano, sid, "a turret for front cluster " + idx + " (" + c.defName + ")");
        }
        CCircuitUnit@ tf = labDue ? null : aiBuilderMgr.FindUnfinishedNear(c.pos, 200.0f, nano);
        if (tf !is null) { c.turretFrame = ai.frame; return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, tf, 30 * SECOND)); }
        // 2. the factory, once its whole turret block stands finished (played: the
        // factory was ordered with the turrets, "its 0 turrets stand"); while a
        // turret is ordered but not started, the cluster waits (INV-045)
        const int done = FinishedTurrets(c);
        if (done < first) {
            // a slot the engine refused (a dead slot) never fills: with no turret
            // work for 240 s, the factory goes up behind the turrets that stand
            if (done == 0 || c.turretFrame < 0 || ai.frame - c.turretFrame < 240 * SECOND) return null;
            if (ai.frame - c.orderedFrame >= 120 * SECOND)
                GenericHelpers::LogUtil("[TECH][Factories] front cluster " + idx + ": " + (c.slots - done) + " turret slot(s) will not fill; the factory goes up behind "
                    + done + " (D-114)", 1);
        }
        if (u !is null && !u.circuitDef.CanBuild(def)) return null;
        // the factory's order still lives: a builder joins it (at most two), never
        // a second order (played: the re-order after 120 s could not pin the slot
        // the first order still held)
        if (c.labTask !is null && !c.labTask.IsDead()
            && ai.frame - c.orderedFrame >= Global::RoleSettings::Tech::FrontClusterStallSeconds * SECOND)
        {
            // the order never became a frame (played on build96: builders cycled
            // round an advanced lab site for 12 minutes): the cluster is given up,
            // its factory ground released; the next order plans another
            aiBuilderMgr.AbortTask(c.labTask);
            @c.labTask = null;
            if (c.labRes >= 0) aiTerrainMgr.ReleaseReservation(c.labRes);
            c.labRes = -1;
            GenericHelpers::LogUtil("[TECH][Factories] front cluster " + idx + " (" + c.defName + "): its factory order made no frame in "
                + Global::RoleSettings::Tech::FrontClusterStallSeconds + " s; given up (D-114)", 1);
            return null;
        }
        if (c.labTask !is null) {
            if (!c.labTask.IsDead()) {
                if (c.labTask.GetUnits().length() < 2) return c.labTask;
                return null;
            }
            @c.labTask = null;
        }
        if (c.tier == 1 && TechBuild::EcoOnline() && !AdvancedLabUp()) return null;   // D-102: the advanced lab first
        if (c.built) {
            // the factory stood and was lost: native forgot its reservation (played:
            // a lab ordered at (-1, 0)); the footprint is reserved again, or the
            // cluster is given up
            const int id = aiTerrainMgr.ReserveBuilding(def, c.pos, c.facing);
            if (id < 0) {
                c.labRes = -1;
                GenericHelpers::LogUtil("[TECH][Factories] front cluster " + idx + " (" + c.defName + ") lost its factory and the ground is taken: given up (D-114)", 1);
                return null;
            }
            c.labRes = id;
            c.built = false;
            c.plannedFrame = ai.frame;
            c.labSeen = false;
        }
        // TECH's start caps: lifted for the spam labs (fwd.t1 counts them) and the
        // advanced lab; never for a gantry (MayPlan kept its cap)
        if (c.tier <= 2 && def.maxThisUnit <= def.count) def.maxThisUnit = def.count + 1;
        IUnitTask@ t = OrderPinned(u, Task::BuildType::FACTORY, def, c.labRes, c.defName + " for front cluster " + idx + " (its " + done + " of " + c.slots + " turrets stand)");
        if (t !is null) { c.orderedFrame = ai.frame; @c.labTask = t; }
        return t;
    }

    // Rule lab.front: the open T2 and T3 clusters (planned, their factory not up)
    // are carried to the end by any constructor that reaches the row (played: the
    // only caller was row lab.t2, far down the table; with the metal floating the
    // T2 constructors never reached it and the block stood half-built for minutes).
    // The T1 clusters are fwd.t1's.
    bool OpenAbove(int tier)
    {
        if (tier <= 2 && NeedAdvancedLab()) return true;
        for (uint i = 0; i < clusters.length(); ++i)
            if (!clusters[i].ahead && clusters[i].tier >= tier && clusters[i].labRes >= 0 && LabAt(clusters[i]) is null) return true;
        return false;
    }
    // A standing factory's lost turret is rebuilt (played: INV-038, a cluster 56%
    // toward the front lost both turrets and nothing rebuilt them while its lab
    // stood). `minTier`/`maxTier` pick the clusters.
    bool RefillWanted(int minTier, int maxTier)
    {
        for (uint i = 0; i < clusters.length(); ++i) {
            Cluster@ c = clusters[i];
            if (c.tier < minTier || c.tier > maxTier || LabAt(c) is null) continue;
            if (aiTerrainMgr.NextSlotAny(c.nanoGroup, c.pos) >= 0) return true;
        }
        return false;
    }
    IUnitTask@ Refill(CCircuitUnit@ u, int minTier, int maxTier)
    {
        if (TechForward::Recalled(u)) return null;   // D-109: its tier is recalled
        CCircuitDef@ nano = Nano();
        if (nano is null || (u !is null && !u.circuitDef.CanBuild(nano))) return null;
        for (uint i = 0; i < clusters.length(); ++i) {
            Cluster@ c = clusters[i];
            if (c.tier < minTier || c.tier > maxTier || LabAt(c) is null) continue;
            const int sid = aiTerrainMgr.NextSlotAny(c.nanoGroup, c.pos);
            if (sid < 0) continue;
            return OrderPinned(u, Task::BuildType::NANO, nano, sid, "a lost turret of front cluster " + (i + 1) + " (" + c.defName + ")");
        }
        return null;
    }
    IUnitTask@ OpenWork(CCircuitUnit@ u)
    {
        IUnitTask@ r = Refill(u, 1, 3);
        if (r !is null) return r;
        if (NeedAdvancedLab()) {
            IUnitTask@ a = Work(AdvancedLabDef(), u, true);   // plans the T2 cluster
            if (a !is null) return a;
        }
        for (uint i = 0; i < clusters.length(); ++i) {
            Cluster@ c = clusters[i];
            if (c.ahead || c.tier < 2 || c.labRes < 0 || LabAt(c) !is null) continue;
            IUnitTask@ t = Work(ai.GetCircuitDef(c.defName), u, false);
            if (t !is null) return t;
        }
        return null;
    }

    // A NEW cluster only when the path it replaces would have ordered the factory
    // (played on build95: four gantry clusters in 20 minutes; the routing had
    // bypassed EnqueueLandGantry's cap and cooldown and Work lifted the cap). The
    // T1 labs: fwd.t1 counts them by income. An advanced lab: available, or none
    // standing after the rezoning. A gantry: available and off the gantry cooldown,
    // which planning it starts.
    bool MayPlan(CCircuitDef@ def)
    {
        const int tier = TierOf(def.GetName());
        if (tier <= 1) return true;
        if (tier == 2) return def.IsAvailable(ai.frame) || NeedAdvancedLab();
        return def.IsAvailable(ai.frame) && Builder::IsGantryOffCooldown();
    }

    // D-114: every land factory order of TECH passes here first. `routed` is true
    // when front placement applies (the caller then returns the result, null
    // included: never the base's placement)
    IUnitTask@ Route(const string &in defName, CCircuitUnit@ u, bool &out routed)
    {
        routed = false;
        if (!IsLandFactory(defName)) return null;
        const bool gantry = UnitHelpers::IsLandGantry(defName);
        if (!GantryMath::ClusterEligible(TechGantry::RecoveryEnabled(), TechBuild::EcoOnline(),
            false, gantry, Active())) return null;
        routed = true;
        return Work(ai.GetCircuitDef(defName), u);
    }

    // The two turrets (or the block) behind a front factory always work for it
    // D-117 (owner's rule): a spam lab's two turrets always assist that lab and
    // nothing else: marked no_disrupt (native keeps them off the reclaim pull),
    // and before the lab exists they wait for it instead of taking other work
    TypeMask NO_DISRUPT = aiAttrMasker.GetTypeMask("no_disrupt");
    Cluster@ ClusterOfTurret(CCircuitUnit@ u)
    {
        if (u is null) return null;
        const AIFloat3 p = u.GetPos(ai.frame);
        for (uint i = 0; i < clusters.length(); ++i) {
            for (uint k = 0; k < clusters[i].turretPos.length(); ++k)
                if (MapHelpers::SqDist(clusters[i].turretPos[k], p) <= Sq(32.0f)) return clusters[i];
        }
        return null;
    }
    // A cluster's turret works for its own factory. Turrets are the native factory
    // manager's assistants (D-119): asked from Tech_FactoryAiMakeTask, they get
    // factory-side tasks (native refuses a task of another manager): the factory
    // frame, else the unit it is producing (unfinished at the lab), else a short
    // wait. A turret a reclaim pull moved to the builder side is asked by the rule
    // turret.spam and gets builder tasks (a guard of the lab).
    IUnitTask@ TurretFocus(CCircuitUnit@ u, bool factorySide = false)
    {
        if (u is null || clusters.length() == 0) return null;
        Cluster@ c = ClusterOfTurret(u);
        if (c is null) return null;
        if (c.tier == 1 && !u.IsAttrAny(NO_DISRUPT.mask)) u.AddAttribute(NO_DISRUPT.type);   // D-117
        CCircuitUnit@ l = LabAt(c);
        if (l is null) {
            if (c.tier != 1) return null;   // the factory is not up yet: other work (its block, its frame)
            // D-117: a spam lab's turrets wait for their lab
            return factorySide ? aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND)) : TechBuild::Wait(5 * SECOND);
        }
        IUnitTask@ t = null;
        if (factorySide) {
            if (l.GetBuildProgress() < 1.0f) @t = aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::HIGH, l));
            else {
                // what the lab is producing: a mobile frame in its yard
                CCircuitUnit@ f = aiBuilderMgr.FindProducedNear(l.GetPos(ai.frame), LabYardRadius);
                if (f !is null)
                    @t = aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::HIGH, f));
                else
                    @t = aiFactoryMgr.Enqueue(TaskS::Wait(false, 2 * SECOND));
            }
        } else {
            if (l.GetBuildProgress() < 1.0f) @t = aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, l, 30 * SECOND));
            else @t = aiBuilderMgr.Enqueue(TaskB::Guard(Task::Priority::HIGH, l, false, 300 * SECOND));   // not interruptible
        }
        if (t !is null) {
            focusOf.set("" + u.id, int64(l.id));   // D-119: for INV-048
            focusFrame.set("" + u.id, int64(ai.frame));
            if (!focusLogged.exists("" + u.id)) {
                focusLogged.set("" + u.id, true);
                GenericHelpers::LogUtil("[TECH][Factories] turret " + u.id + " works for its lab " + l.id + " (" + c.defName + ", "
                    + (factorySide ? "factory side" : "builder side") + ") (D-119)", 1);
            }
        }
        return t;
    }
    const float LabYardRadius = 96.0f;   // D-119: a unit in production stands within this of its lab's centre
    // D-119: the lab each turret last worked for (INV-048: a native guard keeps its
    // target as an id the script cannot read; a wait between two units has none)
    dictionary focusOf;
    dictionary focusFrame;   // D-119: turret id -> frame of its last task for its lab
    dictionary focusLogged;
    // A turret works for `lab` when its last task was for that lab and came within
    // FocusFreshSeconds: a factory-side turret's tasks are seconds long (a unit in
    // production, a 2 s wait), so an instant sample often finds it idle between two
    bool GuardsLab(CCircuitUnit@ t, CCircuitUnit@ lab)
    {
        if (t is null || lab is null) return false;
        int64 id = -1, at = -1;
        if (!focusOf.get("" + t.id, id) || !focusFrame.get("" + t.id, at)) return false;   // D-025
        return id == int64(lab.id) && ai.frame - int(at) <= FocusFreshSeconds * SECOND;
    }
    const int FocusFreshSeconds = 30;

    int aheadTry = -100000;
    void PlanAhead()
    {
        if (!Global::RoleSettings::Tech::ExperimentalBuild || !aiTerrainMgr.IsLayoutEnabled()
            || ai.frame - aheadTry < 5 * SECOND) return;
        aheadTry = ai.frame;
        const string side = Global::AISettings::Side;
        array<string> names = {UnitHelpers::GetT1BotLabForSide(side), UnitHelpers::GetT2BotLabForSide(side), UnitHelpers::GetLandGantryForSide(side)};
        for (uint n = 0; n < names.length(); ++n) {
          for (int future = 0; future < Global::RoleSettings::Tech::PlannedFactoryClustersPerTier; ++future) {
            const string key = "tech.ahead." + names[n] + (future == 0 ? "" : "." + future);
            bool held = false;
            for (uint i = 0; i < clusters.length(); ++i)
                if (clusters[i].ahead && clusters[i].aheadKey == key && clusters[i].labRes >= 0) {
                    if (aiTerrainMgr.GetReservationState(clusters[i].labRes) >= 0) held = true;
                    else clusters[i].labRes = -1;
                    if (clusters[i].labTask !is null || clusters[i].turretFrame >= 0)
                        Invariants::Violation("INV-087", names[n], "future factory reservation acquired active construction work");
                }
            if (held) continue;
            CCircuitDef@ d = ai.GetCircuitDef(names[n]);
            if (d is null) continue;
            const int saved = aiTerrainMgr.GetLayoutInt(key + ".slot", -1);
            Cluster@ c = null;
            if (saved >= 0 && aiTerrainMgr.GetReservationState(saved) >= 0) {
                @c = NewCluster(d, TierOf(names[n]), saved, aiTerrainMgr.GetReservationPos(saved),
                    aiTerrainMgr.GetReservationFacing(saved), aiTerrainMgr.GetLayoutInt(key + ".group", 0),
                    aiTerrainMgr.GetLayoutInt(key + ".count", 0), float(aiTerrainMgr.GetLayoutInt(key + ".share", 0)) / 1000.0f);
                if (c.tier == 1) {
                    Row r; r.origin = c.pos; r.facing = c.facing;
                    r.laneL = aiTerrainMgr.GetLayoutInt(key + ".left", 0); r.laneR = aiTerrainMgr.GetLayoutInt(key + ".right", 0);
                    r.labs.insertLast(c); @c.row = r; spamRows.insertLast(r);
                }
            } else @c = Plan(d, true);
            if (c is null) continue;
            c.ahead = true; c.aheadKey = key;
            c.exitZone = aiTerrainMgr.GetLayoutInt(key + ".exit", 0);
            if (c.exitZone <= 0) {
                const float depth = float(Layout::Along(d, c.facing)) * SQUARE_SIZE;
                const AIFloat3 centre = c.pos + Layout::Fwd(c.facing) * (depth + 176.0f);
                c.exitZone = aiTerrainMgr.ReserveZone(centre, c.facing,
                    float(Layout::Across(d, c.facing)) * SQUARE_SIZE + 32.0f, 160.0f, true);
                aiTerrainMgr.SetLayoutInt(key + ".exit", c.exitZone);
            }
            aiTerrainMgr.SetLayoutInt(key + ".slot", c.labRes);
            aiTerrainMgr.SetLayoutInt(key + ".group", c.nanoGroup);
            aiTerrainMgr.SetLayoutInt(key + ".count", c.slots);
            aiTerrainMgr.SetLayoutInt(key + ".share", int(c.share * 1000.0f));
            if (c.row !is null) {
                aiTerrainMgr.SetLayoutInt(key + ".left", c.row.laneL);
                aiTerrainMgr.SetLayoutInt(key + ".right", c.row.laneR);
            }
            GenericHelpers::LogUtil("[TECH][Expansion] held " + names[n] + " slot=" + c.labRes + " turrets=" + c.slots, 1);
            return;
          }
        }
    }
    // ---------------------------------------------------------------- the base's land factories

    // Owner's rule: with FrontReclaimAtCount land factories on the map, the land
    // factories in reach of the main turret cluster are reclaimed and never
    // rebuilt there; their ground becomes economic ground
    bool baseGroundReleased = false;
    CCircuitUnit@ BaseLandFactory()
    {
        if (LandFactoryCount() < Global::RoleSettings::Tech::FrontReclaimAtCount) return null;
        const AIFloat3 base = Layout::BaseCentre();
        const float r2 = Sq(Global::RoleSettings::Tech::FrontBaseRadius);
        array<string>@ keys = Factory::allFactories.getKeys();
        CCircuitUnit@ best = null;
        float bestSq = 1.0e30f;
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null) continue;
            if (ai.GetTeamUnit(f.id) is null || !IsLandFactory(f.circuitDef) || IsClusterLab(f) || TechFlank::Owns(f)) continue;
            if (TechHeavyRush::ProtectLab(f.id) && UnitHelpers::IsT2BotLab(f.circuitDef.GetName())) continue;
            const float sq = MapHelpers::SqDist(f.GetPos(ai.frame), base);
            if (sq <= r2 && sq < bestSq) { bestSq = sq; @best = f; }
        }
        return best;
    }
    dictionary baseRetired;          // factory id -> frame: retired by the rezoning, not for metal (INV-026)
    IUnitTask@ ReclaimBaseFactory(CCircuitUnit@ u)
    {
        CCircuitUnit@ f = BaseLandFactory();
        if (f is null || f is u) return null;
        if (!Lifecycle::IsRetiring(f)) {
            baseRetired.set("" + f.id, ai.frame);
            // D-216: STOP alone lets a live recruit restart on the resulting
            // idle event. End production ownership before retiring the lab,
            // just as the opening T1/T2 reclaim path does. Shared idle state
            // is not a cancellable job; the reclaim threshold stays unchanged.
            if (f.task !is null && (f.task.GetType() == Task::Type::FACTORY || f.task.GetType() == Task::Type::WAIT))
                aiFactoryMgr.AbortTask(f.task);
            Lifecycle::Retire(f, LandFactoryCount() + " land factories on the map: the base's land factories go back to the economy (D-114)");
            ReleaseBaseFactoryGround();
        }
        if (MapHelpers::SqDist(u.GetPos(ai.frame), f.GetPos(ai.frame)) > Sq(Global::RoleSettings::Tech::ExpAssistRadius)) return null;
        if (!TechReclaim::Allowed(f, "lab.base")) return null;   // D-290: retired now, reclaimed when the refund fits
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, f, 180 * SECOND));
        if (t !is null) { TechReclaim::Track(f, t, "lab.base"); TechBuild::PullTurrets(f); }
        return t;
    }
    // the base's planned factory footprints (the pair's slots, the advanced lab's)
    // go back to the pool: economic ground from now on
    void ReleaseBaseFactoryGround()
    {
        if (baseGroundReleased) return;
        baseGroundReleased = true;
        array<int> ids = { aiTerrainMgr.GetLayoutInt(Layout::FACTORY_ROOT + ".t1_slot", -1), aiTerrainMgr.GetLayoutInt(Layout::FACTORY_ROOT + ".t2_slot", -1), Layout::labSlot };
        int n = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            if (ids[i] < 0) continue;
            aiTerrainMgr.ReleaseReservation(ids[i]);
            ++n;
        }
        Layout::labSlot = -1;
        GenericHelpers::LogUtil("[TECH][Factories] the base's factory ground (" + n + " footprint(s)) is economic ground now (D-114)", 1);
    }
}
