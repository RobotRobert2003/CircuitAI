// T3 unstick (owner, 2026-10-20): free a T3 unit penned in by our own T1
// porc, T1 eco, T1 construction turrets, T2 flak or T2 pop-up artillery so it
// can go to the enemy.
#include "../../define.as"
#include "../../global.as"
#include "../../task.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../team/ally_clear.as"

/******************************************************************************

T3 UNSTICK

Which units: every finished mobile ground unit we own that is not a builder
and either came out of a gantry or costs at least MinMetal (gifts included).

Stuck, either signal:
  - it has a fighter task and has stayed within StuckRadius for StuckSeconds
    (GraceSeconds after it is finished before the clock starts); the engine's
    own response to a failed move is a 256-elmo radial move, so a penned unit
    jiggles in place and never leaves the radius;
  - the engine gave up on it: after 40 failed moves CircuitAI stops the unit
    and orders it reclaimed (CircuitAI.cpp UnitMoveFailed). That reclaim is
    seen in Builder::AiTaskAdded, aborted on the next tick (AbortSelfReclaim)
    and starts a round at once.

A round: every structure of ours whose footprint lies within PenGap x round of
the unit's footprint is a candidate. Those in Global::Team::AllyClearPorc
(T1 porc), AllyClearEco (T1 eco), a T1 construction turret or ExtraClear (T2
flak, Rattlesnake / Persecutor / Eviscerator) are reclaimed:
one native reclaim each, construction turrets in reach pulled onto it
(TurretsOnReclaim), and mobile T1/T2 constructors within BuilderRange join
from Builder::AiMakeTask (BuildersPerBlocker each). Anything else in the ring
(a fusion, a factory, T2 porc) is logged and left. Allied SMRTBARbs are asked
through Team::AllyClear with the same rectangle; human allies are never asked.
TECH asks its reclaim gate (TechReclaim::Allowed, D-290) for each one.

When the blockers are gone or ReclaimSeconds pass the unit gets one move of
NudgeDistance toward the nearest enemy start, and its task takes over again.
A unit that is still stuck gets another round after RetrySeconds with a wider
ring, MaxRounds in all; moving 4 x StuckRadius resets the count.

Cost: Tick every 2 s is O(T3 units); a round start walks our own units once.

******************************************************************************/
namespace T3Unstick {

    final class Hull {
        int id = -1;
        CCircuitUnit@ unit; // identity survives ID reuse; native graveyard owns lifetime
        int added = 0;
        AIFloat3 anchor;
        int anchorFrame = 0;
        AIFloat3 roundPos;       // where the last round started
        int rounds = 0;
        int nextRound = 0;
        int roundStart = -1;     // >= 0 while a round runs
        int lastPull = -100000;
        bool signalled = false;  // the engine tried to reclaim it
        string allyKey = "";
        array<int> blockers;
        dictionary blockerUnits; // original identities belonging to this round
    }

    array<Hull@> hulls;
    array<IUnitTask@> pendingAbort;
    dictionary reclaimTask;      // blocker id -> IUnitTask@
    dictionary blockerUnit;      // active blocker id -> current CCircuitUnit@
    dictionary blockerUsers;     // matching active rounds per current identity
    array<int> activeBlockers;   // every blocker of every running round
    int lastTick = -100000;

    bool Enabled() { return Global::T3Unstick::Enabled; }

    // Shared blockers can belong to several hulls. O(B) dictionary operations
    // plus the existing active-array removal; ending one round never drops the
    // other round's work or erases a new unit that reused the old blocker's ID.
    void ReleaseBlockers(Hull@ h)
    {
        if (h is null) return;
        for (uint i = 0; i < h.blockers.length(); ++i) {
            const string key = "" + h.blockers[i];
            CCircuitUnit@ original = null, current = null;
            if (!h.blockerUnits.get(key, @original) || !blockerUnit.get(key, @current) || current !is original) continue;
            int users = 0;
            blockerUsers.get(key, users);
            if (users > 1) { blockerUsers.set(key, users - 1); continue; }
            const int index = activeBlockers.find(h.blockers[i]);
            if (index >= 0) activeBlockers.removeAt(uint(index));
            reclaimTask.delete(key);
            blockerUnit.delete(key);
            blockerUsers.delete(key);
        }
        h.blockers.resize(0);
        h.blockerUnits.deleteAll();
    }

    bool IsT3(CCircuitUnit@ u)
    {
        if (!ai.IsOwnedUnit(u)) return false;
        const CCircuitDef@ d = u.circuitDef;
        if (!d.IsMobile() || d.IsAbleToFly() || d.IsRoleAny(Unit::Role::BUILDER.mask)) return false;
        if (d.costM >= Global::T3Unstick::MinMetal) return true;
        if (u.GetProducerId() < 0) return false;
        CCircuitUnit@ producer = ai.GetTeamUnit(u.GetProducerId());
        return ai.IsOwnedUnit(producer) && UnitHelpers::IsGantryLab(producer.circuitDef.GetName());
    }

    Hull@ Find(int id)
    {
        for (uint i = 0; i < hulls.length(); ++i) if (hulls[i] !is null && hulls[i].id == id) return hulls[i];
        return null;
    }

    // Military::AiUnitAdded
    void UnitAdded(CCircuitUnit@ unit)
    {
        if (!Enabled() || !IsT3(unit)) return;
        Hull@ previous = Find(unit.id);
        if (previous !is null) {
            if (previous.unit is unit) return;
            // A recycled engine ID is a fresh hull, not a continuation of the
            // previous unit's stuck timer or pending blocker work.
            ReleaseBlockers(previous);
            const int index = hulls.findByRef(previous);
            if (index >= 0) hulls.removeAt(uint(index));
        }
        Hull h;
        h.id = unit.id;
        @h.unit = unit;
        h.added = ai.frame;
        h.anchor = unit.GetPos(ai.frame);
        h.anchorFrame = ai.frame;
        hulls.insertLast(h);
        GenericHelpers::LogUtil("[T3Unstick] watching " + unit.circuitDef.GetName() + " " + unit.id, 2);
    }

    // Builder::AiTaskAdded: the engine's "stuck, reclaim it" order for a T3
    void TaskAdded(IUnitTask@ task)
    {
        if (!Enabled() || !Global::T3Unstick::AbortSelfReclaim || task is null || task.IsDead()) return;
        IBuilderTask@ bt = cast<IBuilderTask>(task);
        if (bt is null || Task::BuildType(bt.GetBuildType()) != Task::BuildType::RECLAIM) return;
        CCircuitUnit@ target = bt.target;
        if (!ai.IsOwnedUnit(target)) return;
        Hull@ h = Find(target.id);
        if (h is null || h.unit !is target) return;
        pendingAbort.insertLast(task);
        h.signalled = true;
        GenericHelpers::LogUtil("[T3Unstick] engine ordered stuck " + target.circuitDef.GetName() + " " + target.id
            + " reclaimed; aborting that and clearing round it instead", 1);
    }

    // A blocker is one of the kinds the owner allows us to clear
    bool Clearable(const string &in name)
    {
        return Global::Team::AllyClearPorc.find(name) >= 0 || Global::Team::AllyClearEco.find(name) >= 0
            || UnitHelpers::IsT1Nano(name) || Global::T3Unstick::ExtraClear.find(name) >= 0;
    }

    float HalfSize(const CCircuitDef@ d)   // half the footprint, elmos (as WallHelpers)
    {
        if (d is null) return 0.0f;
        return float(AiMax(d.GetFootprintX(), d.GetFootprintZ())) * SQUARE_SIZE * 0.5f;
    }

    void StartRound(Hull@ h, CCircuitUnit@ u, const AIFloat3 &in pos)
    {
        if (h is null || !ai.IsOwnedUnit(u) || h.unit !is u) return;
        const float ring = Global::T3Unstick::PenGap * float(h.rounds + 1);
        const float self = HalfSize(u.circuitDef);
        const bool tech = Global::AISettings::Role == AiRole::TECH;
        ReleaseBlockers(h);
        string kept = "", cleared = "";
        array<Id>@ own = ai.GetOwnedUnitIds();
        for (uint i = 0; i < own.length(); ++i) {
            CCircuitUnit@ b = ai.GetTeamUnit(own[i]);
            if (!ai.IsOwnedUnit(b) || b.circuitDef.IsMobile()) continue;
            const AIFloat3 p = b.GetPos(ai.frame);
            const float reach = self + HalfSize(b.circuitDef) + ring;
            if (abs(p.x - pos.x) > reach || abs(p.z - pos.z) > reach) continue;
            const string name = b.circuitDef.GetName();
            if (!Clearable(name) || aiBuilderMgr.IsReclaimProtected(b.circuitDef) || (tech && !TechReclaim::Allowed(b, "t3unstick"))) {
                kept += " " + name;
                continue;
            }
            IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, b, int(Global::T3Unstick::ReclaimSeconds) * SECOND));
            if (!ai.IsOwnedUnit(u) || h.unit !is u) return;
            if (t is null || t.IsDead() || !ai.IsOwnedUnit(b)) { kept += " " + name; continue; }
            if (tech) TechReclaim::Track(b, t, "t3unstick");
            reclaimTask.set("" + b.id, @t);
            const string key = "" + b.id;
            CCircuitUnit@ previousBlocker = null;
            int users = 0;
            if (blockerUnit.get(key, @previousBlocker) && previousBlocker is b) blockerUsers.get(key, users);
            blockerUnit.set(key, @b);
            blockerUsers.set(key, users + 1);
            h.blockerUnits.set(key, @b);
            h.blockers.insertLast(b.id);
            if (activeBlockers.find(b.id) < 0) activeBlockers.insertLast(b.id);
            cleared += " " + name;
        }
        h.allyKey = "t3." + u.id + "." + h.rounds;
        const bool asked = Team::AllyClear::Hold(h.allyKey, pos, self + ring, self + ring);
        h.rounds++;
        h.roundStart = ai.frame;
        h.roundPos = pos;
        h.lastPull = -100000;
        GenericHelpers::LogUtil("[T3Unstick] " + u.circuitDef.GetName() + " " + u.id + " stuck at (" + int(pos.x) + "," + int(pos.z)
            + ")" + (h.signalled ? " (engine gave up on it)" : " for " + ((ai.frame - h.anchorFrame) / SECOND) + " s")
            + ", round " + h.rounds + " ring " + int(ring) + ": reclaiming [" + cleared + " ] kept [" + kept + " ]"
            + (asked ? ", allied SMRTBARbs asked" : ""), 1);
        h.signalled = false;
    }

    bool RoundBusy(Hull@ h)
    {
        if (h is null || !ai.IsOwnedUnit(h.unit)) return false;
        if (ai.frame - h.roundStart >= int(Global::T3Unstick::ReclaimSeconds) * SECOND) return false;
        bool any = false;
        for (uint i = 0; i < h.blockers.length(); ++i) {
            CCircuitUnit@ b = null;
            if (!h.blockerUnits.get("" + h.blockers[i], @b) || !ai.IsOwnedUnit(b)) continue;
            any = true;
            if (ai.frame - h.lastPull >= 10 * SECOND)
                aiBuilderMgr.TurretsOnReclaim(h.blockers[i], Global::T3Unstick::TurretMargin, true, false);
        }
        if (any && ai.frame - h.lastPull >= 10 * SECOND) h.lastPull = ai.frame;
        // the allied SMRTBARbs' answer and their given buildings (reclaimed via AllyClear::BuilderTask)
        if (Team::AllyClear::Busy(h.allyKey)) any = true;
        return any;
    }

    void EndRound(Hull@ h, CCircuitUnit@ u, const AIFloat3 &in pos)
    {
        if (h is null) return;
        ReleaseBlockers(h);
        h.roundStart = -1;
        h.nextRound = ai.frame + int(Global::T3Unstick::RetrySeconds) * SECOND;
        h.anchor = pos;
        h.anchorFrame = ai.frame;
        Nudge(u, pos);
    }

    void Nudge(CCircuitUnit@ u, const AIFloat3 &in pos)
    {
        if (!ai.IsOwnedUnit(u)) return;
        array<AIFloat3> starts = Lanes::EnemyStarts();
        float best = 1.0e30f;
        int bi = -1;
        for (uint i = 0; i < starts.length(); ++i) {
            const float sq = pos.SqDistance2D(starts[i]);
            if (sq < best) { best = sq; bi = int(i); }
        }
        if (bi < 0) return;
        const float dist = sqrt(best);
        AIFloat3 goal = starts[bi];
        if (dist > Global::T3Unstick::NudgeDistance) {
            const float f = Global::T3Unstick::NudgeDistance / dist;
            goal = AIFloat3(pos.x + (goal.x - pos.x) * f, pos.y, pos.z + (goal.z - pos.z) * f);
        }
        u.CmdMoveTo(goal);
        GenericHelpers::LogUtil("[T3Unstick] " + u.circuitDef.GetName() + " " + u.id + " sent toward (" + int(goal.x) + "," + int(goal.z) + ")", 2);
    }

    // Main::AiUpdate (every 30 frames); self-limited to every 2 s
    void Tick()
    {
        if (!Enabled()) return;
        array<IUnitTask@> abortNow = pendingAbort;
        pendingAbort.resize(0); // callbacks may enqueue next-tick work
        for (uint i = 0; i < abortNow.length(); ++i)
            if (abortNow[i] !is null && !abortNow[i].IsDead()) aiBuilderMgr.AbortTask(abortNow[i]);
        if (ai.frame < lastTick + 2 * SECOND) return;
        lastTick = ai.frame;
        const float stuckSq = Global::T3Unstick::StuckRadius * Global::T3Unstick::StuckRadius;
        for (int i = int(hulls.length()) - 1; i >= 0; --i) {
            Hull@ h = hulls[i];
            if (h is null) { hulls.removeAt(uint(i)); continue; }
            CCircuitUnit@ u = h.unit;
            if (!ai.IsOwnedUnit(u)) {
                ReleaseBlockers(h);
                hulls.removeAt(uint(i));
                continue;
            }
            const AIFloat3 pos = u.GetPos(ai.frame);
            if (h.roundStart >= 0) {
                if (!RoundBusy(h)) EndRound(h, u, pos);
                continue;
            }
            if (pos.SqDistance2D(h.anchor) > stuckSq) {
                if (h.rounds > 0 && pos.SqDistance2D(h.roundPos) > 16.0f * stuckSq) h.rounds = 0;
                h.anchor = pos;
                h.anchorFrame = ai.frame;
                continue;
            }
            if (ai.frame < h.added + int(Global::T3Unstick::GraceSeconds) * SECOND) { h.anchorFrame = ai.frame; continue; }
            if (h.rounds >= Global::T3Unstick::MaxRounds || ai.frame < h.nextRound) continue;
            if (!h.signalled) {
                const bool fighting = u.task !is null && u.task.GetType() == Task::Type::FIGHTER;
                if (!fighting) { h.anchorFrame = ai.frame; continue; }
                if (ai.frame - h.anchorFrame < int(Global::T3Unstick::StuckSeconds) * SECOND) continue;
            }
            StartRound(h, u, pos);
        }
    }

    // Builder::AiMakeTask: a mobile T1/T2 constructor near a blocker reclaims it
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || activeBlockers.length() == 0 || !ai.IsOwnedUnit(u)) return null;
        if (!u.circuitDef.IsMobile() || UnitHelpers::IsCommander(u.circuitDef)) return null;
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) return null;
        const AIFloat3 upos = u.GetPos(ai.frame);
        const float rangeSq = Global::T3Unstick::BuilderRange * Global::T3Unstick::BuilderRange;
        CCircuitUnit@ best = null;
        float bestSq = rangeSq;
        for (uint i = 0; i < activeBlockers.length(); ++i) {
            CCircuitUnit@ b = null;
            if (!blockerUnit.get("" + activeBlockers[i], @b) || !ai.IsOwnedUnit(b) || b is u) continue;
            const AIFloat3 bpos = b.GetPos(ai.frame);
            const float sq = upos.SqDistance2D(bpos);
            if (sq > bestSq) continue;
            IUnitTask@ live = null;
            if (reclaimTask.get("" + b.id, @live) && Team::AllyClear::LiveReclaim(live, b)
                && int(live.GetUnits().length()) >= Global::T3Unstick::BuildersPerBlocker) continue;
            if (!aiTerrainMgr.CanReachAt(u, bpos, u.circuitDef.GetBuildDistance())) continue;
            bestSq = sq;
            @best = b;
        }
        if (best is null) return null;
        IUnitTask@ live = null;
        if (reclaimTask.get("" + best.id, @live) && Team::AllyClear::LiveReclaim(live, best)) return live;
        if (Global::AISettings::Role == AiRole::TECH && !TechReclaim::Allowed(best, "t3unstick")) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, best, int(Global::T3Unstick::ReclaimSeconds) * SECOND));
        if (!ai.IsOwnedUnit(u) || !ai.IsOwnedUnit(best) || t is null || t.IsDead()) return null;
        if (t !is null) {
            if (Global::AISettings::Role == AiRole::TECH) TechReclaim::Track(best, t, "t3unstick");
            reclaimTask.set("" + best.id, @t);
            blockerUnit.set("" + best.id, @best);
        }
        return t;
    }
}  // namespace T3Unstick
