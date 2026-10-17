// TECH D-109: the land constructors leave the base once the air constructors
// carry it. T2 land constructors defend the mex clusters (long-range AA and
// flak first); T1 land constructors go forward to a spam cluster (T1 bot labs,
// each with two construction turrets directly behind it) and build its
// defences and small turret pads. A tier whose air constructors go down calls
// its land constructors back to the eco clusters.
// Design and evidence: doc/decisions.md D-109; how it fits the base:
// doc/roles/tech-layout-and-sequence.md.
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
#include "tech_build.as"
#include "tech_factories.as"

namespace TechForward {

    // ---------------------------------------------------------------- release

    float Sq(float v) { return v * v; }

    int T1AirCons() { return UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1AirConstructors()); }

    // T2: the air constructors hold both dedicated roles (D-107/D-108)
    bool T2Released()
    {
        return TechBuild::airConvId >= 0 && TechBuild::airAfusId >= 0
            && ai.GetTeamUnit(TechBuild::airConvId) !is null && ai.GetTeamUnit(TechBuild::airAfusId) !is null;
    }
    // T1: more than T1AirReleaseAbove T1 air constructors carry the base
    bool T1Released() { return T1AirCons() > Global::RoleSettings::Tech::T1AirReleaseAbove; }

    bool IsLand(CCircuitUnit@ u) { return u !is null && u.circuitDef !is null && !UnitHelpers::IsAirConstructor(u.circuitDef); }
    int Tier(CCircuitUnit@ u) { return (u is null || u.circuitDef is null) ? 0 : UnitHelpers::GetConstructorTier(u.circuitDef); }
    bool Released(int tier) { return (tier >= 2) ? T2Released() : T1Released(); }

    bool wasT1 = false;
    bool wasT2 = false;
    bool everT1 = false;
    bool everT2 = false;
    int sinceT1 = -1, sinceT2 = -1;          // released since (INV-039)
    int recallT1 = -1, recallT2 = -1;        // recalled at (INV-040)
    int lastOrderT1 = -1, lastOrderT2 = -1;  // the last forward order of each tier (INV-039)
    // From TechBuild::Tick: the transitions, said once each
    void Tick()
    {
        const bool r1 = T1Released();
        const bool r2 = T2Released();
        const bool recallChanged = (wasT1 && !r1) || (wasT2 && !r2);
        if (r1 != wasT1) {
            GenericHelpers::LogUtil("[TECH][Forward] T1 land constructors " + (r1 ? "released: " : "recalled to the eco clusters: ")
                + T1AirCons() + " T1 air constructors (release above " + Global::RoleSettings::Tech::T1AirReleaseAbove + ") (D-109)", 1);
            wasT1 = r1;
            everT1 = everT1 || r1;
            sinceT1 = r1 ? ai.frame : -1;
            if (!r1) recallT1 = ai.frame;
        }
        if (r2 != wasT2) {
            GenericHelpers::LogUtil("[TECH][Forward] T2 land constructors " + (r2 ? "released to the mex clusters" : "recalled to the eco clusters: a dedicated air role is open")
                + " (D-109)", 1);
            wasT2 = r2;
            everT2 = everT2 || r2;
            sinceT2 = r2 ? ai.frame : -1;
            if (!r2) recallT2 = ai.frame;
        }
        // A productive forward task need not ask for new work. Recall once
        // on the release transition, not with a repeated per-tick unit scan.
        if (recallChanged) {
            array<int>@ workers = ai.GetOwnedUnitIds();
            for (uint i = 0; i < workers.length(); ++i) {
                CCircuitUnit@ worker = ai.GetTeamUnit(workers[i]);
                if (worker is null || Tier(worker) == 0) continue;
                IUnitTask@ home = Recall(worker);
                if (home !is null) aiBuilderMgr.AssignTask(worker, home);
            }
        }
        TickSpam();   // D-111
    }

    // A forward job: a construction whose site is beyond ForwardHomeRadius of the base
    bool IsForwardJob(CCircuitUnit@ u)
    {
        if (u is null || u.task is null) return false;
        IBuilderTask@ bt = cast<IBuilderTask>(u.task);
        if (bt is null) return false;
        // economy work is not forward work, wherever it is (played on build96: a
        // far mex expansion was aborted and handed out again in a loop)
        const Task::BuildType kind = Task::BuildType(bt.GetBuildType());
        if (kind == Task::BuildType::MEX || kind == Task::BuildType::MEXUP) return false;
        const AIFloat3 p = bt.GetBuildPos();
        if (p.x < 0.0f) return false;
        return MapHelpers::SqDist(p, Layout::BaseCentre()) > Sq(Global::RoleSettings::Tech::ForwardHomeRadius);
    }
    // Owner's rule: a tier whose air constructors went down sends its land
    // constructors back to an eco cluster first: a forward job is dropped and the
    // eco rows below take the builder (null: the table continues)
    // A land constructor whose tier was released once and is recalled now: no
    // forward work (D-114: lab.front handed a recalled constructor a front turret,
    // land.recall aborted it in the same re-evaluation, and native crashed)
    bool Recalled(CCircuitUnit@ u)
    {
        if (u is null || !IsLand(u)) return false;
        const int tier = Tier(u);
        return tier >= 1 && !Released(tier) && ((tier >= 2) ? everT2 : everT1);
    }
    dictionary recallAborted;   // unit id -> frame of its last recall abort
    IUnitTask@ Recall(CCircuitUnit@ u)
    {
        if (!Recalled(u) || TechGantry::OwnsWork(u)) return null; // D-281: finish a committed gantry bootstrap
        const int tier = Tier(u);
        if (!IsForwardJob(u)) return null;
        // one abort per unit per 30 s: a recall never churns a constructor
        int64 last;
        if (recallAborted.get("" + u.id, last) && ai.frame - last < 30 * SECOND) return null;
        recallAborted.set("" + u.id, ai.frame);
        // INV-040 (D-109): a recalled land constructor drops its forward job within 60 s
        const int since = (tier >= 2) ? recallT2 : recallT1;
        if (since >= 0 && ai.frame - since > 60 * SECOND)
            Invariants::Violation("INV-040", "recall", u.circuitDef.GetName() + " " + u.id + " still on a forward job " + int((ai.frame - since) / SECOND) + " s after its tier was recalled");
        GenericHelpers::LogUtil("[TECH][Forward] " + u.circuitDef.GetName() + " " + u.id + " recalled: its tier's air constructors are down (D-109)", 1);
        // Returning a replacement detaches this worker through native task
        // assignment. Aborting the old task also stopped its other workers.
        return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
    }

    // ---------------------------------------------------------------- mex clusters (T2)

    class MexCluster {
        AIFloat3 c;
        int n;
        MexCluster(const AIFloat3& in p) { c = p; n = 1; }
    }
    // our mexes, grouped greedily: a mex within MexClusterRadius of a cluster's
    // centre joins it
    array<MexCluster@> Clusters()
    {
        array<MexCluster@> cls;
        const float r2 = Sq(Global::RoleSettings::Tech::MexClusterRadius);
        for (uint i = 0; i < Economy::MexTracker::myMexes.length(); ++i) {
            const AIFloat3 p = Economy::MexTracker::myMexes[i].pos;
            bool joined = false;
            for (uint k = 0; k < cls.length(); ++k) {
                if (MapHelpers::SqDist(cls[k].c, p) <= r2) {
                    const float w = float(cls[k].n);
                    cls[k].c = AIFloat3((cls[k].c.x * w + p.x) / (w + 1.0f), cls[k].c.y, (cls[k].c.z * w + p.z) / (w + 1.0f));
                    cls[k].n += 1;
                    joined = true;
                    break;
                }
            }
            if (!joined) cls.insertLast(MexCluster(p));
        }
        return cls;
    }

    dictionary orderAt;   // "x:z:def" -> frame of the last order there
    array<int> orderBuilders;   // D-109: who carries each recent mex defence order (the others follow)
    string OrderKey(const AIFloat3& in p, const string &in def) { return "" + int(p.x / 64.0f) + ":" + int(p.z / 64.0f) + ":" + def; }
    bool RecentlyOrdered(const AIFloat3& in p, const string &in def)
    {
        int f;
        return orderAt.get(OrderKey(p, def), f) && (ai.frame - f < Global::RoleSettings::Tech::ForwardOrderHoldSeconds * SECOND);
    }
    void NoteOrder(const AIFloat3& in p, const string &in def) { orderAt.set(OrderKey(p, def), ai.frame); }

    // Is def (standing or going up) within radius of p?
    bool Stands(const AIFloat3& in p, float radius, CCircuitDef@ def)
    {
        return aiBuilderMgr.FindOwnNear(p, radius, def) !is null || aiBuilderMgr.FindUnfinishedNear(p, radius, def) !is null;
    }
    // D-108's lesson: TECH's start caps pin defences at 0; the owner asks for these
    bool Buildable(CCircuitUnit@ u, CCircuitDef@ d)
    {
        if (d is null || !d.IsBuildAllowed() || !u.circuitDef.CanBuild(d)) return false;
        if (d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;
        return d.IsAvailable(ai.frame);
    }

    IUnitTask@ OrderDefence(CCircuitUnit@ u, CCircuitDef@ d, const AIFloat3& in at, float shake, const string &in why)
    {
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::NORMAL, d, at, shake, true,
            Global::RoleSettings::Tech::ForwardOrderHoldSeconds * SECOND));
        if (t is null) return null;
        NoteOrder(at, d.GetName());
        if (Tier(u) >= 2) lastOrderT2 = ai.frame; else lastOrderT1 = ai.frame;
        GenericHelpers::LogUtil("[TECH][Forward] " + u.circuitDef.GetName() + " " + u.id + " orders " + d.GetName() + " at (" + int(at.x) + ", " + int(at.z) + "): " + why + " (D-109)", 1);
        return t;
    }

    // Owner's rule: once the T2 air constructors are up, every T2 land
    // constructor defends the mex clusters, long-range AA and flak first. The
    // nearest cluster outside the base missing one of them.
    IUnitTask@ DefendMexes(CCircuitUnit@ u)
    {
        const string side = Global::AISettings::Side;
        array<CCircuitDef@> defs = {
            ai.GetCircuitDef(UnitHelpers::GetStaticT2AARangeNameForSide(side)),
            ai.GetCircuitDef(UnitHelpers::GetStaticT2AAFlakNameForSide(side))
        };
        array<MexCluster@> cl = Clusters();
        const AIFloat3 from = u.GetPos(ai.frame);
        const AIFloat3 base = Layout::BaseCentre();
        const float clear2 = Sq(Global::RoleSettings::Tech::MexDefenceBaseClear);
        const float r = Global::RoleSettings::Tech::MexDefenceRadius;
        for (uint k = 0; k < defs.length(); ++k) {   // every cluster gets the first before any gets the second
            CCircuitDef@ d = defs[k];
            if (!Buildable(u, d)) continue;
            int best = -1;
            float bestSq = 1.0e30f;
            for (uint i = 0; i < cl.length(); ++i) {
                if (MapHelpers::SqDist(cl[i].c, base) < clear2) continue;   // the base is the eco layout's ground
                // Expansion economy banks may be outside the original base.
                // Their perimeter owner also owns flak admission and its cap.
                if (k == 1 && EcoFlak::OwnsArea(cl[i].c)) continue;
                if (Stands(cl[i].c, r, d) || RecentlyOrdered(cl[i].c, d.GetName())) continue;
                const float sq = MapHelpers::SqDist(cl[i].c, from);
                if (sq < bestSq) { bestSq = sq; best = int(i); }
            }
            if (best < 0) continue;
            IUnitTask@ t = OrderDefence(u, d, cl[best].c, Global::RoleSettings::Tech::MexDefenceShake,
                "mex cluster of " + cl[best].n + ", " + int(sqrt(bestSq)) + " away");
            if (t !is null && orderBuilders.find(u.id) < 0) orderBuilders.insertLast(u.id);
            return t;
        }
        // D-109 (played: one T2 bot walked to each cluster alone while the rest went
        // back to the eco rows; 1 of 26 defences stood by 36 min): every released
        // T2 land constructor stays on the defences: a defence going up at a
        // cluster first, else follow a constructor carrying a defence order
        CCircuitUnit@ frame = null;
        float frameSq = 1.0e30f;
        for (uint k = 0; k < defs.length(); ++k) {
            if (defs[k] is null) continue;
            for (uint i = 0; i < cl.length(); ++i) {
                CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedNear(cl[i].c, r, defs[k]);
                if (f is null) continue;
                const float sq = MapHelpers::SqDist(f.GetPos(ai.frame), from);
                if (sq < frameSq) { frameSq = sq; @frame = f; }
            }
        }
        if (frame !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL, frame, 60 * SECOND));
        CCircuitUnit@ lead = null;
        float leadSq = 1.0e30f;
        for (int i = int(orderBuilders.length()) - 1; i >= 0; --i) {
            CCircuitUnit@ b = ai.GetTeamUnit(orderBuilders[i]);
            IBuilderTask@ bt = (b is null || b.task is null) ? null : cast<IBuilderTask>(b.task);
            if (bt is null || Task::BuildType(bt.GetBuildType()) != Task::BuildType::DEFENCE) {
                if (b is null) orderBuilders.removeAt(i);
                continue;
            }
            if (b.id == u.id) continue;
            const float sq = MapHelpers::SqDist(b.GetPos(ai.frame), from);
            if (sq < leadSq) { leadSq = sq; @lead = b; }
        }
        if (lead !is null) return GuardHelpers::AssignWorkerGuard(u, lead, Task::Priority::NORMAL, true, 60 * SECOND);
        return null;
    }

    // ---------------------------------------------------------------- the spam cluster (T1)

    // D-109 / D-114: a spam lab is a T1 front factory cluster (TechFactories): the lab
    // with two construction turrets directly behind it, turrets built first,
    // placed at least FrontMinShare of the way toward the front. The clusters of
    // this file: the T1 ones.
    array<TechFactories::Cluster@> SpamClusters()
    {
        array<TechFactories::Cluster@> res;
        for (uint i = 0; i < TechFactories::clusters.length(); ++i)
            if (!TechFactories::clusters[i].ahead && TechFactories::clusters[i].tier == 1) res.insertLast(TechFactories::clusters[i]);
        return res;
    }
    array<int> padGroups;
    int padTryFrame = -100000;   // the last pad reservation attempt
    array<AIFloat3> padCentres;

    // D-216: construction and production share one sustained-income budget.
    // Keeping a second TECH formula here could build idle, unfunded pumps.
    // The argument remains for existing rule/invariant callers.
    int SpamLabsWanted(float mi)
    {
        return Spam::IsActive() ? Spam::LabsWanted() : 0;
    }

    // The released T1 land constructor's work, in order: the spam clusters (an
    // open one's turrets, then its lab; a new one while income asks for it); the
    // cluster's AA; idle: a small turret pad; else assist what goes up forward,
    // else guard a spam lab.
    IUnitTask@ ForwardT1(CCircuitUnit@ u, float mi)
    {
        const string side = Global::AISettings::Side;
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(side));
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
        if (lab is null || nano is null) return null;
        array<TechFactories::Cluster@> spam = SpamClusters();

        // 1. the spam clusters: turrets first, then the lab (TechFactories::Work)
        const bool gate = Spam::IsActive();
        if (gate && u.circuitDef.CanBuild(lab)) {
            const bool more = int(spam.length()) < SpamLabsWanted(mi) && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), lab) == 0
                && TechFactories::AdvancedLabUp();   // D-102: the advanced lab first
            IUnitTask@ t = TechFactories::Work(lab, u, more);
            if (t !is null) { lastOrderT1 = ai.frame; return t; }
        }
        // 1b. a standing spam lab's lost turret (D-114, INV-038)
        {
            IUnitTask@ rt = TechFactories::Refill(u, 1, 1);
            if (rt !is null) { lastOrderT1 = ai.frame; return rt; }
        }
        // 2. the cluster's AA: one per standing lab, behind its turrets
        CCircuitDef@ aa = ai.GetCircuitDef(UnitHelpers::GetStaticAAHeavyNameForSide(side));
        if (Buildable(u, aa)) {
            for (uint i = 0; i < spam.length(); ++i) {
                TechFactories::Cluster@ c = spam[i];
                if (TechFactories::LabAt(c) is null) continue;
                const AIFloat3 at = c.pos - Layout::Fwd(c.facing) * (float(Layout::Along(lab, c.facing) + 2 * Layout::Along(nano, c.facing) + 2) * SQUARE_SIZE);
                if (Stands(at, 160.0f, aa) || RecentlyOrdered(at, aa.GetName())) continue;
                IUnitTask@ t = OrderDefence(u, aa, at, 64.0f, "spam lab " + (i + 1) + "'s AA, behind its turrets");
                if (t !is null) return t;
            }
        }
        // 3. idle: a small pad of turrets behind an end cluster
        IUnitTask@ pad = PadTurret(u, lab, nano, spam);
        if (pad !is null) return pad;
        // 4. help a STRUCTURE going up at a spam cluster (D-119, owner: a spam lab is
        // never assisted by constructors: not guarded, and no help on the units it
        // produces, which are unfinished units too)
        for (uint i = 0; i < spam.length(); ++i) {
            CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedNear(spam[i].pos, Global::RoleSettings::Tech::SpamClusterRadius, null);
            if (f !is null && f.circuitDef !is null && !f.circuitDef.IsMobile())
                return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL, f, 30 * SECOND));
        }
        return null;
    }

    // Owner's rule: T1 constructors sent out and idle build small clusters of
    // construction turrets near the front to assist, not on a lane: a 2x2 pad
    // behind the first and the last spam cluster's turrets, a cell of walking room
    // between (D-109: never on the lab line)
    IUnitTask@ PadTurret(CCircuitUnit@ u, CCircuitDef@ lab, CCircuitDef@ nano, array<TechFactories::Cluster@>@ spam)
    {
        if (spam.length() < 2) return null;
        for (uint i = 0; i < padGroups.length(); ++i) {
            const int id = aiTerrainMgr.NextSlotAny(padGroups[i], padCentres[i]);
            if (id >= 0) { lastOrderT1 = ai.frame; return TechFactories::OrderPinned(u, Task::BuildType::NANO, nano, id, "a turret on forward pad " + (i + 1)); }
        }
        if (int(padGroups.length()) >= Global::RoleSettings::Tech::SpamPadsMax) return null;
        TechFactories::Cluster@ c = (padGroups.length() % 2 == 0) ? spam[0] : spam[spam.length() - 1];
        const float back = (float(Layout::Along(lab, c.facing)) * 0.5f + float(2 * Layout::Along(nano, c.facing)) + 1.0f) * SQUARE_SIZE * 2;
        const AIFloat3 fc = c.pos - Layout::Fwd(c.facing) * back;
        if (ai.frame - padTryFrame < 60 * SECOND) return null;
        padTryFrame = ai.frame;
        const int g = aiTerrainMgr.ReserveGrid(nano, fc, c.facing, 2, 2, 0);
        // a pad the ground cannot hold is not kept (played on build98: two empty
        // pads filled SpamPadsMax, so no pad ever went up)
        if (g > 0 && aiTerrainMgr.GetGroupCount(g, false) < 4) { aiTerrainMgr.ReleaseGroup(g); return null; }
        if (g <= 0) return null;
        padGroups.insertLast(g);
        padCentres.insertLast(fc);
        GenericHelpers::LogUtil("[TECH][Forward] forward turret pad " + padGroups.length() + " reserved at (" + int(fc.x) + ", " + int(fc.z) + "), behind a spam cluster (D-109)", 1);
        const int id = aiTerrainMgr.NextSlotAny(g, fc);
        if (id < 0) return null;
        lastOrderT1 = ai.frame;
        return TechFactories::OrderPinned(u, Task::BuildType::NANO, nano, id, "a turret on forward pad " + padGroups.length());
    }

    // D-216: repeat ownership and lanes are shared across roles. Native repeat
    // recruitment now survives UnitFinished; the D-119 repeat-off workaround
    // must not overwrite that state.
    void TickSpam() {}
}
