// Anti-spam lanes (owner, 2026-10-27): hold the lane enemy spam walks down.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "edge_lanes.as"
#include "../team/roster.as"

/******************************************************************************

ANTI-SPAM LANES

Played 2026-10-27 (Nuclear Winter Bar): a human beat the AIs with dozens of
Grunts walking down one edge lane. This step spots such a stream and holds
its lane.

Spotting (Tick, every 2 s): the shared ground-contact snapshot is walked once;
every contact of a spam unit (Global::AntiSpam::SpamDefs) is remembered by id,
and at most once per 10 s per unit its position is kept as a sighting when it
stands in our half (MinShare..MaxShare along the axis from our starts' centre
to the enemy's). Once TriggerCount different spam units were sighted inside
our half within WindowSeconds, the sightings are binned sideways across the axis; a bin (with
its neighbours) holding LaneMinShare of them and LaneMinUnits different units
is a lane. Its anchor stands AnchorShare along the axis, on the lane's mean
sideways offset, pulled toward the axis until a bot can walk there.

Owner: the lane belongs to the FRONT (ours or an allied SMRTBARb's, from the
roster) whose start is nearest the anchor; without any FRONT, the nearest
SMRTBARb. The owner publishes the lane (antispam|lane|idx|x,z) every
PublishSeconds; the others adopt it. A lane we saw that nobody published
within OwnerWaitSeconds (owner gone, or not a SMRTBARb) we hold ourselves.

The owner's constructors (BuilderTask) build the lane, step by step on the
sustained income (settings LadderLight / LadderDragon / LadderNano): light guns
(Beamer / Twin Guard / Cacophony) in a line GunAlong ahead of the anchor, two
Dragon's teeth (Claw / Maw / Jaw) between them, and 2 to 4 construction turrets
NanoAlong behind. Each kind has its own order, so a gun, a turret and a Dragon
go up together, each joined by up to OrderBuilders constructors (arena
2026-10-27: one order at a time took 34 min to reach step 2 at +131 metal).
A turret counts for the lane only within NanoSlotRadius of a turret slot, so
the AI's ordinary turrets nearby are not mistaken for the lane's.

The lane's turrets (FactoryMakeTask) repair the most damaged lane gun in
reach first, then finish the lane's frames, then fall back to native assist,
which repairs and helps build any friendly unit in reach. (Parked anti-spam
units, made by the factories for each lane, were taken out 2026-10-28: a TECH
gantry kept making Demons.)

Cost: Tick walks the ground contacts once per 2 s (O(C), one dictionary
lookup each); the lane search runs at most every 10 s over the kept sightings
(capped at MaxSamples); the lane census walks our own units once per 2 s only
while a lane exists. Messages: one per owned lane per PublishSeconds.

******************************************************************************/
namespace AntiSpam {
    const string PREFIX = "antispam|";
    const int MaxSamples = 3000;
    const int SampleFrames = 10 * SECOND;

    class Sighting {
        int last = -100000;
        int lastSample = -100000;
    }

    class Lane {
        string key;               // "<owner team>:<index>"
        int ownerTeam = -1;
        AIFloat3 anchor(-1.0f, 0.0f, -1.0f);
        float lateral = 0.0f;
        bool mine = false;
        int publishedFrame = -100000;
        // owner only, from the census
        array<int> standing = { 0, 0, 0 };   // light, dragon, nano
        array<CCircuitUnit@> frames(3);
        array<int> staticIds;     // our guns and nanos of this lane
        array<IUnitTask@> orders(3);         // the live order of each kind
        array<int> orderBefore = { 0, 0, 0 };
        array<bool> orderRepair = { false, false, false };
        int fails = 0;
        int shift = 0;
        int backoffUntil = -1;
        int lastStep = -1;
    }

    class Candidate {
        float lateral = 0.0f;
        AIFloat3 anchor;
        int firstFrame = -1;
    }

    dictionary spamSet;
    bool initDone = false;
    dictionary seen;              // contact id -> Sighting@
    array<float> sx, sz;
    array<int> sframe, sid;
    int sampleHead = 0;
    array<Lane@> lanes;
    array<Candidate@> candidates;
    int lastTick = -100000, lastSearch = -100000, lastPrune = -100000, lastPublish = -100000, lastReport = -100000;
    int detectedFrame = -1;
    int windowCount = 0;
    int ownLaneCount = 0;
    AIFloat3 s0, e0;
    float fx = 0.0f, fz = 0.0f, nx = 0.0f, nz = 0.0f, axisLen = 0.0f;
    bool axisReady = false;

    bool Enabled() { return Global::AntiSpam::Enabled; }
    float Abs(float v) { return v < 0.0f ? -v : v; }

    void Init()
    {
        if (initDone) return;
        initDone = true;
        for (uint i = 0; i < Global::AntiSpam::SpamDefs.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(Global::AntiSpam::SpamDefs[i]);
            if (d !is null) spamSet.set("" + int(d.id), 1);
        }
        sx.resize(MaxSamples); sz.resize(MaxSamples); sframe.resize(MaxSamples); sid.resize(MaxSamples);
        for (int i = 0; i < MaxSamples; ++i) sframe[i] = -100000;
    }

    bool Axis()
    {
        if (axisReady) return true;
        // the ends need our start, the allies' and the enemy's: kept for the game, so not
        // before a minute in (Baryon Tar Lake 2026-10-27: taken at frame 0 they were the
        // map's corners, and every lane anchor landed in the enemy half)
        if (!Global::Map::HasStart || ai.frame < 60 * SECOND) return false;
        if (!EdgeLanes::Ends(s0, e0)) return false;
        EdgeLanes::Axis(s0, e0, fx, fz, nx, nz);
        axisLen = sqrt(MapHelpers::SqDist(s0, e0));
        axisReady = axisLen > 1.0f;
        if (axisReady) GenericHelpers::LogUtil("[AntiSpam] axis from (" + int(s0.x) + "," + int(s0.z) + ") to (" + int(e0.x) + ","
            + int(e0.z) + "), " + int(axisLen) + " elmos", 1);
        return axisReady;
    }
    float Along(const AIFloat3 &in p) { return ((p.x - s0.x) * fx + (p.z - s0.z) * fz) / axisLen; }
    float Side(const AIFloat3 &in p) { return (p.x - s0.x) * nx + (p.z - s0.z) * nz; }
    AIFloat3 At(const AIFloat3 &in base, float along, float side)
    {
        return AIFloat3(base.x + fx * along + nx * side, 0.0f, base.z + fz * along + nz * side);
    }

    bool IsSpam(int defId)
    {
        if (spamSet.exists("" + defId)) return true;
        if (!Global::AntiSpam::CountCheapArmed) return false;
        const CCircuitDef@ d = ai.GetCircuitDef(defId);
        return d !is null && d.IsMobile() && !d.IsAbleToFly() && d.HasSurfToLand() && d.GetBuildSpeed() <= 0.0f
            && d.costM <= Global::AntiSpam::MaxSpamCost;
    }

    /**************************************************************************
     Spotting
     **************************************************************************/
    void Scan()
    {
        const int contacts = aiBattle.GetGroundContactCount();
        for (int i = 0; i < contacts; ++i) {
            if (!IsSpam(aiBattle.GetGroundContactDefId(i))) continue;
            const int id = aiBattle.GetGroundContactId(i);
            const string k = "" + id;
            Sighting@ s;
            if (!seen.get(k, @s) || s is null) { @s = Sighting(); seen.set(k, @s); }
            s.last = ai.frame;
            if (ai.frame - s.lastSample < SampleFrames) continue;
            const AIFloat3 p = aiBattle.GetGroundContactPos(i);
            const float a = Along(p);
            if (a < Global::AntiSpam::MinShare || a > Global::AntiSpam::MaxShare) continue;
            s.lastSample = ai.frame;
            sx[sampleHead] = p.x; sz[sampleHead] = p.z; sframe[sampleHead] = ai.frame; sid[sampleHead] = id;
            sampleHead = (sampleHead + 1) % MaxSamples;
        }
    }

    void Prune()
    {
        const int window = Global::AntiSpam::WindowSeconds * SECOND;
        array<string>@ keys = seen.getKeys();
        int fresh = 0;
        for (uint i = 0; i < keys.length(); ++i) {
            Sighting@ s;
            if (!seen.get(keys[i], @s) || s is null || ai.frame - s.last > window) seen.delete(keys[i]);
            else if (ai.frame - s.lastSample <= window) ++fresh;   // only units sighted inside our half count
        }
        windowCount = fresh;
    }

    // Lanes from the sightings in the window, strongest first
    void Search()
    {
        const int window = Global::AntiSpam::WindowSeconds * SECOND;
        const float bin = AiMax(100.0f, Global::AntiSpam::LaneBin);
        array<bool> used(MaxSamples, false);
        int total = 0;
        for (int i = 0; i < MaxSamples; ++i) if (ai.frame - sframe[i] <= window) ++total;
        if (total == 0) return;
        for (int pass = 0; pass < Global::AntiSpam::MaxLanes; ++pass) {
            dictionary bins;
            for (int i = 0; i < MaxSamples; ++i) {
                if (used[i] || ai.frame - sframe[i] > window) continue;
                const string b = "" + int(floor(Side(AIFloat3(sx[i], 0.0f, sz[i])) / bin));
                int n = 0;
                bins.get(b, n);
                bins.set(b, n + 1);
            }
            array<string>@ keys = bins.getKeys();
            int bestBin = 0, bestN = 0;
            for (uint j = 0; j < keys.length(); ++j) {
                const int b = int(parseInt(keys[j]));
                int n0 = 0, n1 = 0, n2 = 0;
                bins.get("" + (b - 1), n0); bins.get(keys[j], n1); bins.get("" + (b + 1), n2);
                if (n0 + n1 + n2 > bestN) { bestN = n0 + n1 + n2; bestBin = b; }
            }
            if (float(bestN) < Global::AntiSpam::LaneMinShare * float(total)) return;
            dictionary ids;
            float sum = 0.0f;
            int n = 0;
            for (int i = 0; i < MaxSamples; ++i) {
                if (used[i] || ai.frame - sframe[i] > window) continue;
                const float t = Side(AIFloat3(sx[i], 0.0f, sz[i]));
                const int b = int(floor(t / bin));
                if (b < bestBin - 1 || b > bestBin + 1) continue;
                used[i] = true;
                ids.set("" + sid[i], 1);
                sum += t; ++n;
            }
            if (n == 0 || int(ids.getSize()) < Global::AntiSpam::LaneMinUnits) return;
            Offer(sum / float(n), int(ids.getSize()), n, total);
        }
    }

    Lane@ LaneNear(float lateral)
    {
        for (uint i = 0; i < lanes.length(); ++i)
            if (Abs(lanes[i].lateral - lateral) < Global::AntiSpam::LaneSeparation) return lanes[i];
        return null;
    }

    // The anchor on a lane: AnchorShare along, pulled toward the axis until a bot can walk there
    AIFloat3 AnchorFor(float lateral)
    {
        CCircuitDef@ walker = ai.GetCircuitDef(UnitHelpers::GetT1BotScoutForSide(Global::AISettings::Side));
        const AIFloat3 home = Global::Map::StartPos;
        const float along = Global::AntiSpam::AnchorShare * axisLen;
        const float step = 128.0f;
        float t = lateral;
        for (int k = 0; k < 64; ++k) {
            const AIFloat3 q = At(s0, along, t);
            if (EdgeLanes::InBounds(q) && (walker is null || aiTerrainMgr.CanTraverse(walker, home, q))) return q;
            if (Abs(t) < step) break;
            t -= (t > 0.0f) ? step : -step;
        }
        return AIFloat3(-1.0f, 0.0f, -1.0f);
    }

    // Our start or an allied one: whose is nearest the anchor among FRONTs (any role without one)
    bool WeOwn(const AIFloat3 &in anchor)
    {
        array<Team::Roster::Entry@>@ fronts = Team::Roster::WithRole(AiRole::FRONT);
        const bool iFront = Global::AISettings::Role == AiRole::FRONT;
        array<Team::Roster::Entry@>@ pool = fronts;
        if (fronts.length() == 0 && !iFront) @pool = Team::Roster::All();
        const float mine = MapHelpers::SqDist(Global::Map::StartPos, anchor);
        if (!iFront && fronts.length() > 0) return false;
        for (uint i = 0; i < pool.length(); ++i) {
            const float d = MapHelpers::SqDist(pool[i].startPos, anchor);
            if (d < mine || (d == mine && pool[i].teamId < ai.teamId)) return false;
        }
        return true;
    }

    void Offer(float lateral, int units, int samples, int total)
    {
        if (LaneNear(lateral) !is null) return;
        if (int(lanes.length()) >= Global::AntiSpam::MaxLanes) return;
        Candidate@ c = null;
        for (uint i = 0; i < candidates.length(); ++i)
            if (Abs(candidates[i].lateral - lateral) < Global::AntiSpam::LaneSeparation) { @c = candidates[i]; break; }
        if (c is null) {
            const AIFloat3 a = AnchorFor(lateral);
            if (a.x < 0.0f) {
                GenericHelpers::LogUtil("[AntiSpam] lane at " + int(lateral) + " sideways has no reachable anchor", 1);
                return;
            }
            @c = Candidate();
            c.lateral = lateral; c.anchor = a; c.firstFrame = ai.frame;
            candidates.insertLast(c);
            GenericHelpers::LogUtil("[AntiSpam] spam lane seen: " + units + " units (" + samples + " of " + total + " sightings, "
                + windowCount + " spam units in " + Global::AntiSpam::WindowSeconds + " s), " + int(lateral) + " sideways, anchor ("
                + int(a.x) + "," + int(a.z) + ")" + (WeOwn(a) ? ", ours to hold" : ", for the nearest FRONT"), 1);
        }
        const bool own = WeOwn(c.anchor);
        if (own || ai.frame - c.firstFrame >= Global::AntiSpam::OwnerWaitSeconds * SECOND) {
            Lane@ l = Lane();
            l.key = ai.teamId + ":" + ownLaneCount;
            ++ownLaneCount;
            l.ownerTeam = ai.teamId;
            l.anchor = c.anchor;
            l.lateral = c.lateral;
            l.mine = true;
            lanes.insertLast(l);
            GenericHelpers::LogUtil("[AntiSpam] holding lane " + l.key + " at (" + int(l.anchor.x) + "," + int(l.anchor.z) + ")"
                + (own ? " (nearest FRONT)" : " (nobody published it)"), 1);
            Publish(true);
        }
    }

    /**************************************************************************
     The lane's turrets
     **************************************************************************/
    // The lane of one of our construction turrets, or null
    Lane@ NanoLane(CCircuitUnit@ u)
    {
        for (uint i = 0; i < lanes.length(); ++i) {
            if (!lanes[i].mine) continue;
            if (lanes[i].staticIds.find(u.id) >= 0) return lanes[i];
        }
        return null;
    }

    IUnitTask@ NanoTask(CCircuitUnit@ nano, Lane@ l)
    {
        const AIFloat3 p = nano.GetPos(ai.frame);
        const float reach = nano.circuitDef.GetBuildDistance() + 40.0f;
        const float r2 = reach * reach;
        CCircuitUnit@ worst = null;
        float worstHp = 0.995f;
        for (uint i = 0; i < l.staticIds.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(l.staticIds[i]);
            if (u is null || u is nano || u.GetBuildProgress() < 1.0f) continue;
            const float hp = u.GetHealthPercent();
            if (hp >= worstHp || MapHelpers::SqDist(p, u.GetPos(ai.frame)) > r2) continue;
            worstHp = hp; @worst = u;
        }
        if (worst !is null) {
            GenericHelpers::LogUtil("[AntiSpam] nano " + nano.id + " repairs " + worst.circuitDef.GetName() + " " + worst.id
                + " at " + int(worstHp * 100.0f) + "% (lane " + l.key + ")", 2);
            return aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::HIGH, worst));
        }
        for (int k = 0; k < 3; ++k) {
            CCircuitUnit@ f = l.frames[k];
            if (f is null || ai.GetTeamUnit(f.id) is null || MapHelpers::SqDist(p, f.GetPos(ai.frame)) > r2) continue;
            return aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::NORMAL, f));
        }
        // native assist also repairs (and helps build) friendly units in reach
        return aiFactoryMgr.DefaultMakeTask(nano);
    }

    // Factory::AiMakeTask asks here first: our lane turrets
    IUnitTask@ FactoryMakeTask(CCircuitUnit@ u)
    {
        if (!Enabled() || lanes.length() == 0 || u is null || u.circuitDef is null) return null;
        if (!UnitHelpers::IsT1Nano(u.circuitDef.GetName())) return null;
        Lane@ l = NanoLane(u);
        return (l is null) ? null : NanoTask(u, l);
    }

    /**************************************************************************
     The owner's guns and turrets
     **************************************************************************/
    string KindName(int kind)
    {
        string n = "";
        if (kind == 0) Global::AntiSpam::LightGun.get(Global::AISettings::Side, n);
        else if (kind == 1) Global::AntiSpam::DragonGun.get(Global::AISettings::Side, n);
        else n = UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side);
        return n;
    }

    AIFloat3 GunSlot(Lane@ l, int kind, int k)
    {
        const array<float> lightSide = { -110.0f, 110.0f, -330.0f, 330.0f, -550.0f, 550.0f, 0.0f };
        const array<float> dragonSide = { 0.0f, -440.0f, 440.0f, -220.0f };
        const array<float> nanoSide = { -150.0f, 150.0f, -420.0f, 420.0f, 0.0f };
        if (kind == 0) return At(l.anchor, Global::AntiSpam::GunAlong, lightSide[k % lightSide.length()]);
        if (kind == 1) return At(l.anchor, Global::AntiSpam::GunAlong + 20.0f, dragonSide[k % dragonSide.length()]);
        return At(l.anchor, Global::AntiSpam::NanoAlong, nanoSide[k % nanoSide.length()]);
    }

    void Census()
    {
        bool any = false;
        for (uint j = 0; j < lanes.length(); ++j) {
            if (!lanes[j].mine) continue;
            any = true;
            for (int t = 0; t < 3; ++t) { lanes[j].standing[t] = 0; @lanes[j].frames[t] = null; }
            lanes[j].staticIds.resize(0);
        }
        if (!any) return;
        const array<string> names = { KindName(0), KindName(1), KindName(2) };
        const float r2 = Global::AntiSpam::ClusterRadius * Global::AntiSpam::ClusterRadius;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef.IsMobile()) continue;
            const string dn = u.circuitDef.GetName();
            int t = 0;
            while (t < 3 && dn != names[t]) ++t;
            // other guns of ours near the lane are repaired too
            if (t == 3 && !u.circuitDef.HasSurfToLand()) continue;
            const AIFloat3 q = u.GetPos(ai.frame);
            Lane@ best = null;
            float bestSq = r2;
            for (uint j = 0; j < lanes.length(); ++j) {
                if (!lanes[j].mine) continue;
                const float sq = MapHelpers::SqDist(q, lanes[j].anchor);
                if (sq <= bestSq) { bestSq = sq; @best = lanes[j]; }
            }
            if (best is null) continue;
            if (t == 2 && !NearNanoSlot(best, q)) continue;   // an ordinary turret near the lane
            best.staticIds.insertLast(int(u.id));
            if (t == 3) continue;
            best.standing[t] += 1;
            if (u.GetBuildProgress() < 1.0f) @best.frames[t] = u;
        }
        for (uint j = 0; j < lanes.length(); ++j) {
            Lane@ l = lanes[j];
            if (!l.mine) continue;
            for (int k = 0; k < 3; ++k) {
                if (l.orders[k] is null || !l.orders[k].IsDead()) continue;
                if (l.standing[k] > l.orderBefore[k] || (l.orderRepair[k] && l.standing[k] >= l.orderBefore[k])) { l.fails = 0; l.shift = 0; }
                else {
                    l.shift += 1;
                    l.fails += 1;
                    if (l.fails >= 3) {
                        l.backoffUntil = ai.frame + 90 * SECOND;
                        l.fails = 0;
                        GenericHelpers::LogUtil("[AntiSpam] lane " + l.key + ": three orders died with no " + names[k] + "; waiting 90 s", 1);
                    }
                }
                @l.orders[k] = null;
            }
        }
    }

    bool NearNanoSlot(Lane@ l, const AIFloat3 &in q)
    {
        const float r2 = Global::AntiSpam::NanoSlotRadius * Global::AntiSpam::NanoSlotRadius;
        for (int k = 0; k < 5; ++k)
            if (MapHelpers::SqDist(q, GunSlot(l, 2, k)) <= r2) return true;
        return false;
    }

    int Want(int kind, int step)
    {
        if (kind == 0) return Global::AntiSpam::LadderLight[step];
        if (kind == 1) return Global::AntiSpam::LadderDragon[step];
        return Global::AntiSpam::LadderNano[step];
    }

    // Builder::AiMakeTask asks here before the edge lanes
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || lanes.length() == 0 || u is null || !u.circuitDef.IsMobile() || UnitHelpers::IsCommander(u.circuitDef)) return null;
        // native re-asks busy builders and swaps them onto any other kind of task: one on a lane order keeps it
        // (arena 2026-10-27: FRONT's lab turrets took the gun order's armcv the same frame; the order sat unbuilt 9 min)
        if (u.task !is null) {
            for (uint j = 0; j < lanes.length(); ++j)
                for (int k = 0; k < 3; ++k)
                    if (lanes[j].orders[k] is u.task && !u.task.IsDead()) return u.task;
        }
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) return null;
        // join a live lane order first
        for (uint j = 0; j < lanes.length(); ++j) {
            Lane@ l = lanes[j];
            if (!l.mine) continue;
            for (int k = 0; k < 3; ++k) {
                IUnitTask@ o = l.orders[k];
                if (o is null || o.IsDead() || int(o.GetUnits().length()) >= Global::AntiSpam::OrderBuilders) continue;
                if (!aiTerrainMgr.CanReachAt(u, l.anchor, u.circuitDef.GetBuildDistance() + 200.0f)) break;
                IBuilderTask@ b = cast<IBuilderTask>(o);
                if (b is null || b.buildDef is null || u.circuitDef.CanBuild(b.buildDef)) return o;
            }
        }
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();
        const int steps = AiMin(int(Global::AntiSpam::LadderLight.length()), AiMin(int(Global::AntiSpam::LadderNano.length()),
            AiMin(int(Global::AntiSpam::LadderDragon.length()), AiMin(int(Global::AntiSpam::LadderMetal.length()), int(Global::AntiSpam::LadderEnergy.length())))));
        const array<int> kinds = { 0, 2, 1 };   // light guns, then turrets, then dragons
        for (uint j = 0; j < lanes.length(); ++j) {
            Lane@ l = lanes[j];
            if (!l.mine || ai.frame < l.backoffUntil) continue;
            if (!aiTerrainMgr.CanReachAt(u, l.anchor, u.circuitDef.GetBuildDistance() + 200.0f)) continue;
            for (int s = 0; s < steps; ++s) {
                bool due = false;
                // a dead order waits for Census to count it (the slot shift and back-off), so no new one before then
                for (int t = 0; t < 3 && !due; ++t) due = l.standing[t] < Want(t, s) && l.orders[t] is null;
                if (!due) continue;
                if (mi < Global::AntiSpam::LadderMetal[s] || ei < Global::AntiSpam::LadderEnergy[s]) break;
                for (uint m = 0; m < kinds.length(); ++m) {
                    const int kind = kinds[m];
                    if (l.standing[kind] >= Want(kind, s) || l.orders[kind] !is null) continue;
                    CCircuitDef@ d = ai.GetCircuitDef(KindName(kind));
                    if (d is null || !u.circuitDef.CanBuild(d)) continue;   // left to a constructor that can
                    if (s != l.lastStep) {
                        l.lastStep = s;
                        GenericHelpers::LogUtil("[AntiSpam] lane " + l.key + " step " + (s + 1) + " of " + steps + " (stand: light " + l.standing[0]
                            + ", dragon " + l.standing[1] + ", nano " + l.standing[2] + "; mi=" + int(mi) + " ei=" + int(ei) + ")", 1);
                    }
                    IUnitTask@ order = null;
                    if (l.frames[kind] !is null && ai.GetTeamUnit(l.frames[kind].id) !is null) {
                        @order = aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, l.frames[kind], 120 * SECOND));
                    } else {
                        if (d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;
                        if (!d.IsAvailable(ai.frame)) continue;
                        const AIFloat3 p = GunSlot(l, kind, l.standing[kind] + l.shift);
                        const float shake = Global::AntiSpam::Shake + 80.0f * float(AiMin(l.shift, 4));
                        @order = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::HIGH, d, p, shake, true, 180 * SECOND));
                        if (order !is null) GenericHelpers::LogUtil("[AntiSpam] " + u.circuitDef.GetName() + " " + u.id + " orders " + d.GetName()
                            + " " + (l.standing[kind] + 1) + " of lane " + l.key + " at (" + int(p.x) + "," + int(p.z) + ")", 1);
                    }
                    if (order is null) return null;
                    @l.orders[kind] = order;
                    l.orderBefore[kind] = l.standing[kind];
                    l.orderRepair[kind] = l.frames[kind] !is null;
                    return order;
                }
                break;   // this step is due but this constructor builds none of it
            }
        }
        return null;
    }

    /**************************************************************************
     Allies
     **************************************************************************/
    Lane@ Find(const string &in key)
    {
        for (uint i = 0; i < lanes.length(); ++i) if (lanes[i].key == key) return lanes[i];
        return null;
    }

    void Publish(bool force)
    {
        if (!force && ai.frame - lastPublish < Global::AntiSpam::PublishSeconds * SECOND) return;
        lastPublish = ai.frame;
        for (uint i = 0; i < lanes.length(); ++i) {
            Lane@ l = lanes[i];
            if (!l.mine) continue;
            const array<string>@ parts = l.key.split(":");
            AiSendMessage(PREFIX + "lane|" + parts[1] + "|" + int(l.anchor.x) + "," + int(l.anchor.z));
        }
    }

    // Team::HandleMessage
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        if (msg.findFirst(PREFIX) != 0) return false;
        array<string>@ parts = msg.split("|");
        if (parts.length() < 4) return true;
        if (parts[1] == "lane") {
            const string key = fromTeamId + ":" + parts[2];
            array<string>@ xz = parts[3].split(",");
            if (xz.length() != 2) return true;
            Lane@ l = Find(key);
            if (l is null) {
                if (!Axis()) return true;
                @l = Lane();
                l.key = key;
                l.ownerTeam = fromTeamId;
                lanes.insertLast(l);
                l.anchor = AIFloat3(float(parseInt(xz[0])), 0.0f, float(parseInt(xz[1])));
                l.lateral = Side(l.anchor);
                GenericHelpers::LogUtil("[AntiSpam] team " + fromTeamId + " holds lane " + key + " at (" + xz[0] + "," + xz[1] + ")", 1);
            }
            l.publishedFrame = ai.frame;
            return true;
        }
        return true;
    }

    // A published lane whose owner fell silent, on a lane we saw ourselves: we hold it
    void TakeOverSilent()
    {
        const int stale = 3 * Global::AntiSpam::PublishSeconds * SECOND + Global::AntiSpam::OwnerWaitSeconds * SECOND;
        for (uint i = 0; i < lanes.length(); ++i) {
            Lane@ l = lanes[i];
            if (l.mine || ai.frame - l.publishedFrame < stale) continue;
            for (uint j = 0; j < candidates.length(); ++j) {
                if (Abs(candidates[j].lateral - l.lateral) >= Global::AntiSpam::LaneSeparation) continue;
                l.mine = true;
                GenericHelpers::LogUtil("[AntiSpam] lane " + l.key + ": its owner is silent; we hold it", 1);
                break;
            }
        }
    }

    /**************************************************************************
     Main::AiUpdate, every 30 frames; the work runs every 2 s
     **************************************************************************/
    void Update()
    {
        if (!Enabled() || ai.frame - lastTick < 2 * SECOND) return;
        lastTick = ai.frame;
        Init();
        if (!Axis()) return;
        Scan();
        if (ai.frame - lastPrune >= 10 * SECOND) {
            lastPrune = ai.frame;
            Prune();
            if (windowCount >= Global::AntiSpam::TriggerCount) {
                if (detectedFrame < 0) {
                    detectedFrame = ai.frame;
                    GenericHelpers::LogUtil("[AntiSpam] spam detected: " + windowCount + " spam units seen in " + Global::AntiSpam::WindowSeconds + " s", 1);
                }
                Search();
            }
            TakeOverSilent();
        }
        if (lanes.length() == 0) return;
        Census();
        Publish(false);
        if (ai.frame - lastReport >= Global::AntiSpam::ReportSeconds * SECOND) {
            lastReport = ai.frame;
            for (uint i = 0; i < lanes.length(); ++i) {
                Lane@ l = lanes[i];
                GenericHelpers::LogUtil("[AntiSpam] lane " + l.key + (l.mine ? " (ours)" : "") + ": light " + l.standing[0] + ", dragon " + l.standing[1] + ", nano " + l.standing[2] + "; spam seen " + windowCount, 1);
            }
        }
    }
}  // namespace AntiSpam
