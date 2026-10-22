// SEA policy only. Native queries own legality/reachability and task lifetimes.
#include "../../helpers/math/sea_math.as"
namespace SeaRecovery {
    array<int> subs;
    int nextUpdate=0;
    bool lowMetal=false;
    int opportunityFrame=-100000;
    float safeWreckMetal=0, damagedMetal=0;
    int Demand(const CCircuitDef@ recovery) {
        if (recovery is null || !SeaEconomy::HoldingWater()) return 0;
        if (ai.frame-opportunityFrame>=10*SECOND) {
            opportunityFrame=ai.frame; safeWreckMetal=0; damagedMetal=0;
            CCircuitUnit@ survey=null;
            for (uint i=0;i<SeaCombat::owned.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
                if (u is null || u.GetBuildProgress()<1) continue;
                if (survey is null && SeaEconomy::ConstructorDef(u.circuitDef)) @survey=u;
                if (u.circuitDef.GetBuildSpeed()>0 || u.circuitDef.IsAbleToFly() || !u.circuitDef.IsMobile()) continue;
                const AIFloat3 p=u.GetPos(ai.frame);
                const float radius=Global::RoleSettings::Sea::RecoverySearchRadius;
                if (aiBattle.WaterBody(p,false)>=0 && aiBattle.AmphThreat(p)<=.1f
                    && MapHelpers::SqDist(p,Global::Map::StartPos)<radius*radius && u.GetHealthPercent()<.8f)
                    damagedMetal+=u.circuitDef.costM*(1-u.GetHealthPercent());
            }
            if (survey !is null) safeWreckMetal=aiBuilderMgr.GetRecoveryMetal(survey,Global::RoleSettings::Sea::RecoverySearchRadius);
        }
        return int((safeWreckMetal+damagedMetal)/(AiMax(1.0f,recovery.costM)*Global::RoleSettings::Sea::RecoveryOpportunityMultiple));
    }
    bool IsSub(const CCircuitDef@ d) {
        if (d is null) return false;
        const string n=d.GetName();
        return n=="armrecl" || n=="correcl" || n=="legnavyrezsub";
    }
    bool Protected(CCircuitUnit@ u) {
        return u is null || u.task !is null && (u.task.GetType()==int(Task::Type::PLAYER)
            || u.task.GetType()==int(Task::Type::RETREAT) || u.task.IsEnemyReclaim());
    }
    // D-347: a sub on a resurrection keeps it until the native task ends
    // (wreck raised, gone or aborted), so repair jobs found every 2 s no longer
    // pull it away half done. RecoveryResurrectCommitSeconds bounds a stuck
    // task. Keyed by unit id; O(1) per tick.
    dictionary resurrectSince;
    bool Resurrecting(CCircuitUnit@ u) {
        IBuilderTask@ b=cast<IBuilderTask>(u.task);
        const string key=""+u.id;
        if (b is null || b.IsDead() || b.GetBuildType()!=int(Task::BuildType::RESURRECT)) { resurrectSince.delete(key); return false; }
        int since=ai.frame;
        if (!resurrectSince.get(key,since)) { resurrectSince.set(key,ai.frame); return true; }
        if (ai.frame-since<Global::RoleSettings::Sea::RecoveryResurrectCommitSeconds*SECOND) return true;
        resurrectSince.delete(key);
        GenericHelpers::LogUtil("[SEA][Recovery] sub="+u.id+" resurrection commit expired",1);
        return false;
    }
    IUnitTask@ Make(CCircuitUnit@ u) {
        if (Protected(u)) return u is null ? null : u.task;
        if (Resurrecting(u)) return u.task;
        const float radius=Global::RoleSettings::Sea::RecoverySearchRadius;
        IUnitTask@ t=null;
        // Safe fleet repairs precede resource recovery. Native admission checks
        // current sensor contacts and reach; no repair job follows a fighting
        // ship into a combat zone simply because it used to be safe.
        @t=aiBuilderMgr.FindRecoveryTask(u,1,radius,null,1,false,
            Global::RoleSettings::Sea::RecoveryRepairCombatClearance);
        if (t !is null) return t;
        if (lowMetal) @t=aiBuilderMgr.FindRecoveryTask(u,0,radius,null);
        if (t !is null) return t;
        // Each wreck has one native task shared by a bounded crew, so subs
        // focus their resurrection power without GUARD chains or repeated MOVE.
        // Rank by full vessel cost, not its partially reclaimed scrap value.
        @t=aiBuilderMgr.FindRecoveryTask(u,2,radius,null,
            AiMax(1,Global::RoleSettings::Sea::RecoveryResurrectionGroupSize),true);
        if (t !is null) return t;
        // A short wait is recovery standby, never factory assistance (these
        // subs cannot assist construction). New opportunities interrupt it.
        if (u.task !is null && u.task.GetType()==int(Task::Type::WAIT)) return u.task;
        if (u.task !is null && u.task.GetType()==int(Task::Type::BUILDER)) {
            IBuilderTask@ old=cast<IBuilderTask>(u.task);
            if (old !is null && old.GetBuildType()==int(Task::BuildType::WAIT)) return old;
        }
        return aiBuilderMgr.Enqueue(TaskB::Wait(5*SECOND));
    }
    void Added(CCircuitUnit@ u) {
        if (u !is null && IsSub(u.circuitDef) && subs.find(u.id)<0) subs.insertLast(u.id);
    }
    void Removed(CCircuitUnit@ u) {
        if (u is null) return;
        const int i=subs.find(u.id); if (i>=0) subs.removeAt(i);
        resurrectSince.delete(""+u.id);
    }
    void Reset() {
        subs.resize(0); resurrectSince.deleteAll(); nextUpdate=0; lowMetal=false; opportunityFrame=-100000; safeWreckMetal=0; damagedMetal=0;
        array<Id>@ ids=ai.GetOwnedUnitIds();
        for (uint i=0;i<ids.length();++i) Added(ai.GetTeamUnit(ids[i]));
    }
    void Leave() {
        for (uint i=0;i<subs.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(subs[i]);
            if (!Protected(u)) aiBuilderMgr.AssignTask(u,aiBuilderMgr.Enqueue(TaskB::Wait(SECOND)));
        }
        subs.resize(0);
    }
    void Tick() {
        if (Global::AISettings::Role!=AiRole::SEA || ai.frame<nextUpdate) return;
        nextUpdate=ai.frame+2*SECOND;
        lowMetal=SeaMath::RecoveryLowMetal(lowMetal,aiEconomyMgr.metal.current,aiEconomyMgr.metal.storage,
            Global::RoleSettings::Sea::RecoveryMetalLowFraction,Global::RoleSettings::Sea::RecoveryMetalResumeFraction);
        // IDs survive callbacks; borrowed units/tasks are resolved only while
        // this AI owns the callback. O(S) calls reuse native feature snapshots.
        for (int i=int(subs.length())-1;i>=0;--i) {
            CCircuitUnit@ u=ai.GetTeamUnit(subs[i]);
            if (u is null) { subs.removeAt(i); continue; }
            if (Protected(u) || u.GetBuildProgress()<1) continue;
            IUnitTask@ selected=Make(u);
            if (selected !is null && selected !is u.task) {
                aiBuilderMgr.AssignTask(u,selected);
                IBuilderTask@ b=cast<IBuilderTask>(selected);
                if (b !is null) {
                    const int kind=b.GetBuildType();
                    if (kind==int(Task::BuildType::RESURRECT)) {
                        // Inspect only on a new assignment, not every update.
                        array<CCircuitUnit@>@ crew=selected.GetUnits();
                        if (crew.length()>uint(AiMax(1,Global::RoleSettings::Sea::RecoveryResurrectionGroupSize)))
                            Invariants::Violation("INV-182",""+u.id,"SEA resurrection crew exceeds configured group size");
                        GenericHelpers::LogUtil("[SEA][RecoveryGroup] sub="+u.id+" crew="+crew.length()
                            +" x="+b.GetBuildPos().x+" z="+b.GetBuildPos().z,1);
                    }
                    GenericHelpers::LogUtil("[SEA][Recovery] sub="+u.id+" task="+kind+" lowMetal="+lowMetal,1);
                    if (kind!=int(Task::BuildType::RECLAIM) && kind!=int(Task::BuildType::RESURRECT)
                        && kind!=int(Task::BuildType::REPAIR) && kind!=int(Task::BuildType::WAIT))
                        Invariants::Violation("INV-153",""+u.id,"SEA recovery selected construction/assist instead of recovery");
                }
            }
        }
    }
}
