// Edge lane forward porc (owner, 2026-10-19): the two edge-lane FRONTs drop
// porc clusters on their own edge, toward the enemy, where spam walks.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "edge_lanes.as"

/******************************************************************************

EDGE PORC

The FRONT that EdgeLanes::Decide gives the left (or right) lane also holds
that edge with guns, in two clusters: EdgePorcShares (25 % and 40 %) of the
way from our starts' centre to the enemy's. Each anchor is the playable edge
point there (EdgeLanes::EdgePoint, the spam lanes' own geometry), moved
EdgePorcInset in from the edge so the guns cover the strip the enemy's edge
spam walks through.

Each cluster climbs the same ladder (settings/shared/edge_porc.as):

  step  gun      stands  metal  energy income (10 s minimum)
  1     light    1        25     250
  2     light    2        35     400
  3     mid      1        50     700
  4     light    3        60     800
  5     mid      2        75    1100
  6     heavy    1        95    1500
  7     mid      3       115    1800
  8     heavy    2       140    2400
  9     flak     2       160    3000

light = Beamer / Twin Guard / Cacophony, mid = Pit Bull / Scorpion / Chimera
(T2), heavy = Rattlesnake / Persecutor / Eviscerator (T2), flak = the T2 flak of
each faction (armflak / corflak / legflak). The steps are walked in order, and
at each step the 25 % cluster goes first, then the 40 % one. "Stands" counts
our guns of that kind within EdgePorcRadius of a cluster's centre (each gun
counts for the nearer cluster only; finished or not), so a lost gun is simply
rebuilt and nothing drifts. The first step whose income is not there stops the
walk; a step the asking constructor cannot build (a T2 gun for a T1
constructor) is left to another one, and later steps go on. One order lives at
a time, joined by at most one more constructor. Light guns stand in front
(toward the enemy), the pop-ups in the middle, the flak behind them, the
long-range plasma last. An order that dies with no gun moves that cluster's
next order to the following slot with a wider search; after three in a row the
cluster waits 90 s.

******************************************************************************/
namespace EdgePorc {
    class Cluster {
        float share = 0.0f;
        AIFloat3 centre(-1.0f, 0.0f, -1.0f);
        array<int> standing = { 0, 0, 0, 0 };
        array<CCircuitUnit@> frames(4);   // an unfinished gun of each tier near the centre
        int fails = 0;      // orders in a row that died with no gun
        int shift = 0;      // slots skipped after such orders
        int backoffUntil = -1;
        int lastStep = -1;  // the last step logged as reached
    }
    bool planned = false;
    array<Cluster@> clusters;
    float fx = 0.0f, fz = 0.0f;   // toward the enemy
    float ox = 0.0f, oz = 0.0f;   // out toward our edge
    IUnitTask@ order;
    Cluster@ orderCluster;
    int orderTier = -1;
    int orderBefore = 0;
    bool orderRepair = false;
    int planFrame = -100000;

    bool Enabled()
    {
        return Global::Spam::EdgePorcEnabled && Global::AISettings::Role == AiRole::FRONT;
    }

    string Name(int tier)
    {
        string n = "";
        if (tier == 0) Global::Spam::EdgePorcLight.get(Global::AISettings::Side, n);
        else if (tier == 1) Global::Spam::EdgePorcMid.get(Global::AISettings::Side, n);
        else if (tier == 2) Global::Spam::EdgePorcHeavy.get(Global::AISettings::Side, n);
        else Global::Spam::EdgePorcFlak.get(Global::AISettings::Side, n);
        return n;
    }
    CCircuitDef@ Def(int tier)
    {
        const string n = Name(tier);
        return (n == "") ? null : ai.GetCircuitDef(n);
    }
    string Pct(Cluster@ c) { return "" + int(c.share * 100.0f + 0.5f) + "%"; }

    // The cluster centres from the lane's side; once, with a ground builder's movement
    bool Plan(CCircuitUnit@ u)
    {
        if (planned) return true;
        if (ai.frame - planFrame < 30 * SECOND) return false;
        planFrame = ai.frame;
        const int lane = EdgeLanes::Decide();
        AIFloat3 s0, e0;
        if (lane == 0 || !EdgeLanes::Ends(s0, e0)) return false;
        float ax, az, nx, nz;
        EdgeLanes::Axis(s0, e0, ax, az, nx, nz);
        const AIFloat3 home = Global::Map::StartPos;
        CCircuitDef@ walker = ai.GetCircuitDef(u.circuitDef.GetName());   // the lanes' geometry wants a mutable def
        if (walker is null) return false;
        fx = ax; fz = az;
        ox = nx * float(lane); oz = nz * float(lane);
        array<Cluster@> found;
        for (uint i = 0; i < Global::Spam::EdgePorcShares.length(); ++i) {
            Cluster c;
            c.share = Global::Spam::EdgePorcShares[i];
            const AIFloat3 edge = EdgeLanes::EdgePoint(walker, home, s0, e0, lane, c.share);
            if (edge.x < 0.0f) {
                GenericHelpers::LogUtil("[EdgePorc] no playable " + EdgeLanes::Name(lane) + " edge point at " + Pct(c) + "; that cluster is skipped", 1);
                continue;
            }
            // in from the edge, while the ground stays reachable
            AIFloat3 p = edge;
            for (float inset = Global::Spam::EdgePorcInset; inset >= 0.0f; inset -= 100.0f) {
                const AIFloat3 q(edge.x - ox * inset, 0.0f, edge.z - oz * inset);
                if (EdgeLanes::InBounds(q) && aiTerrainMgr.CanTraverse(walker, home, q)) { p = q; break; }
            }
            c.centre = p;
            found.insertLast(c);
            GenericHelpers::LogUtil("[EdgePorc] " + EdgeLanes::Name(lane) + " edge porc " + Pct(c) + " centre (" + int(p.x) + "," + int(p.z)
                + "), edge point (" + int(edge.x) + "," + int(edge.z) + "), " + int(sqrt(MapHelpers::SqDist(home, p))) + " from our start", 1);
        }
        if (found.length() == 0) return false;
        clusters = found;
        planned = true;
        return true;
    }

    // Slot `k` of a tier: light in front, mid in the middle, flak behind it, heavy last
    AIFloat3 Slot(Cluster@ c, int tier, int k)
    {
        const array<float> lightOut = { 0.0f, -180.0f, 180.0f, -360.0f, 360.0f };
        const array<float> midOut = { -100.0f, 100.0f, -300.0f, 300.0f };
        const array<float> heavyOut = { -130.0f, 130.0f, -390.0f };
        const array<float> flakOut = { -260.0f, 260.0f, 0.0f };
        float along = 0.0f, side = 0.0f;
        if (tier == 0) { along = 140.0f; side = lightOut[k % lightOut.length()]; }
        else if (tier == 1) { along = 0.0f; side = midOut[k % midOut.length()]; }
        else if (tier == 2) { along = -280.0f; side = heavyOut[k % heavyOut.length()]; }
        else { along = -140.0f; side = flakOut[k % flakOut.length()]; }
        return AIFloat3(c.centre.x + fx * along + ox * side, 0.0f, c.centre.z + fz * along + oz * side);
    }

    // Main::AiUpdate (via Spam::Update), every 30 frames: count what stands
    void Update()
    {
        if (!Enabled() || !planned) return;
        const array<string> names = { Name(0), Name(1), Name(2), Name(3) };
        for (uint j = 0; j < clusters.length(); ++j) {
            for (int t = 0; t < 4; ++t) {
                clusters[j].standing[t] = 0;
                @clusters[j].frames[t] = null;
            }
        }
        const float r2 = Global::Spam::EdgePorcRadius * Global::Spam::EdgePorcRadius;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null) continue;
            const string dn = u.circuitDef.GetName();
            int t = 0;
            while (t < 4 && dn != names[t]) ++t;
            if (t == 4) continue;
            // the nearer cluster only
            const AIFloat3 q = u.GetPos(ai.frame);
            Cluster@ best = null;
            float bestSq = r2;
            for (uint j = 0; j < clusters.length(); ++j) {
                const float sq = MapHelpers::SqDist(q, clusters[j].centre);
                if (sq <= bestSq) { bestSq = sq; @best = clusters[j]; }
            }
            if (best is null) continue;
            best.standing[t] += 1;
            if (u.GetBuildProgress() < 1.0f) @best.frames[t] = u;
        }
        // the live order died: did it leave a gun?
        if (order !is null && order.IsDead()) {
            Cluster@ c = orderCluster;
            if (c !is null) {
                if (c.standing[orderTier] > orderBefore || (orderRepair && c.standing[orderTier] >= orderBefore)) { c.fails = 0; c.shift = 0; }
                else {
                    c.shift += 1;
                    c.fails += 1;
                    if (c.fails >= 3) {
                        c.backoffUntil = ai.frame + 90 * SECOND;
                        GenericHelpers::LogUtil("[EdgePorc] " + Pct(c) + ": three orders died with no " + names[orderTier] + "; waiting 90 s", 1);
                        c.fails = 0;
                    }
                }
            }
            @order = null;
            @orderCluster = null;
        }
    }

    // Builder::AiMakeTask asks here after EdgeLanes
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || u is null || !u.circuitDef.IsMobile() || UnitHelpers::IsCommander(u.circuitDef)) return null;
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) return null;
        if (order !is null && !order.IsDead()) {
            if (orderCluster !is null && order.GetUnits().length() < 2 && aiTerrainMgr.CanReachAt(u, orderCluster.centre, u.circuitDef.GetBuildDistance())) {
                IBuilderTask@ b = cast<IBuilderTask>(order);
                if (b is null || b.buildDef is null || u.circuitDef.CanBuild(b.buildDef)) return order;
            }
            return null;
        }
        if (!Plan(u)) return null;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();
        const uint steps = Global::Spam::EdgePorcTier.length();
        for (uint s = 0; s < steps; ++s) {
            const int tier = Global::Spam::EdgePorcTier[s];
            const int want = Global::Spam::EdgePorcCount[s];
            bool due = false;
            for (uint j = 0; j < clusters.length() && !due; ++j) due = clusters[j].standing[tier] < want;
            if (!due) continue;
            if (mi < Global::Spam::EdgePorcMetal[s] || ei < Global::Spam::EdgePorcEnergy[s]) return null;
            CCircuitDef@ d = Def(tier);
            if (d is null || !u.circuitDef.CanBuild(d)) continue;   // left to a constructor that can
            for (uint j = 0; j < clusters.length(); ++j) {
                Cluster@ c = clusters[j];
                if (c.standing[tier] >= want || ai.frame < c.backoffUntil) continue;
                if (!aiTerrainMgr.CanReachAt(u, c.centre, u.circuitDef.GetBuildDistance())) continue;
                if (int(s) != c.lastStep) {
                    c.lastStep = int(s);
                    GenericHelpers::LogUtil("[EdgePorc] " + Pct(c) + " step " + (s + 1) + " of " + steps + ": " + d.GetName() + " " + want
                        + " (stand: light " + c.standing[0] + ", mid " + c.standing[1] + ", heavy " + c.standing[2] + ", flak " + c.standing[3]
                        + "; mi=" + int(mi) + " ei=" + int(ei) + ", threat " + int(aiBattle.SurfThreat(c.centre)) + ")", 1);
                }
                // a frame of that gun already there: finish it
                if (c.frames[tier] !is null && ai.GetTeamUnit(c.frames[tier].id) !is null) {
                    @order = aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL, c.frames[tier], 120 * SECOND));
                } else {
                    if (d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;
                    if (!d.IsAvailable(ai.frame)) return null;
                    const int k0 = c.standing[tier] + c.shift;
                    AIFloat3 p = Slot(c, tier, k0);
                    // keep our own spam lanes open: try the tier's other slots first
                    for (int k = 1; k < 5 && aiBattle.IsFriendlyLane(p); ++k) p = Slot(c, tier, k0 + k);
                    const float shake = Global::Spam::EdgePorcShake + 80.0f * float(AiMin(c.shift, 4));
                    @order = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::NORMAL, d, p, shake, true, 180 * SECOND));
                    if (order !is null) GenericHelpers::LogUtil("[EdgePorc] " + u.circuitDef.GetName() + " " + u.id + " orders "
                        + d.GetName() + " " + (c.standing[tier] + 1) + " of the " + Pct(c) + " cluster at (" + int(p.x) + "," + int(p.z) + ")", 1);
                }
                if (order is null) return null;
                @orderCluster = c;
                orderTier = tier;
                orderBefore = c.standing[tier];
                orderRepair = c.frames[tier] !is null;
                return order;
            }
        }
        return null;
    }
}  // namespace EdgePorc
