// SEA-owned fleet procurement. SeaOperations selects objectives; native tasks
// retain path traversal, contact combat and repair. No per-unit orders here.
#include "sea_economy.as"
#include "sea_operations.as"
#include "sea_patrol.as"
#include "sea_protection.as"
#include "sea_composition.as"
#include "sea_control.as"
namespace SeaCombat {
    class Hull {
        CCircuitDef@ def;
        float surface=0, underwater=0, air=0;
        bool siege=false;
        Hull(const string &in name, float s, float w, float a, bool artillery=false) {
            @def=ai.GetCircuitDef(name); surface=s; underwater=w; air=a; siege=artillery;
        }
    }
    array<Hull@> roster;
    array<int> owned;
    int frame=-100000;
    int subSeen=-100000, airSeen=-100000;
    float surface=0, underwater=0, air=0, shore=0, fleet=0;
    bool Active() { return Global::AISettings::Role==AiRole::SEA && Global::RoleSettings::Sea::AdaptiveFleet; }
    // D-300 small-boat budget. O(1) per call: one def count and pending count.
    int scoutRecruited=-100000;
    bool SmallBoat(const CCircuitDef@ d) {
        if (d is null) return false;
        const string name=d.GetName();
        return name=="armpt" || name=="corpt" || name=="legnavyscout";
    }
    // Every channel shares one budget and one replacement clock: beyond the
    // first live boat, a new one waits ScoutReplacementSeconds after the last.
    bool SmallBoatFull(CCircuitDef@ d) {
        if (!SmallBoat(d)) return false;
        const int cap=AiMin(Global::RoleSettings::Sea::SmallBoatMax,Global::RoleSettings::Sea::SmallBoatBase
            +int(fleet/AiMax(1.0f,Global::RoleSettings::Sea::SmallBoatFleetMetal)));
        const int boats=d.count+aiFactoryMgr.GetPendingRecruitCount(d);
        return boats>=cap || (boats>0 && ai.frame-scoutRecruited<int(Global::RoleSettings::Sea::ScoutReplacementSeconds*SECOND));
    }
    // D-301 (played vs stock BARb: gunships were the top killer of ships).
    // When air is the counter layer, the T1 AA boat answers it from its own,
    // larger budget with no replacement delay; scouting stays capped.
    int SmallBoatAirCap() {
        return AiMin(Global::RoleSettings::Sea::SmallBoatAirMax,Global::RoleSettings::Sea::SmallBoatBase
            +int(fleet/AiMax(1.0f,Global::RoleSettings::Sea::SmallBoatAirFleetMetal)));
    }
    bool SmallBoatAirFull(CCircuitDef@ d) {
        return SmallBoat(d) && d.count+aiFactoryMgr.GetPendingRecruitCount(d)>=SmallBoatAirCap();
    }
    CCircuitDef@ NoteSmallBoat(CCircuitDef@ d, bool air=false) {
        if (!SmallBoat(d)) return d;
        const int cap=air ? SmallBoatAirCap() : AiMin(Global::RoleSettings::Sea::SmallBoatMax,Global::RoleSettings::Sea::SmallBoatBase
            +int(fleet/AiMax(1.0f,Global::RoleSettings::Sea::SmallBoatFleetMetal)));
        // INV-229: every channel respects the one small-boat budget.
        if (d.count+aiFactoryMgr.GetPendingRecruitCount(d)>=cap)
            Invariants::Violation("INV-229",d.GetName(),"SEA small boat selected over budget "+cap);
        scoutRecruited=ai.frame; return d;
    }
    void MilitaryRemoved(CCircuitUnit@ u, Unit::UseAs usage) {
        // The next owned census releases the ID and its route/sector lease.
    }
    IUnitTask@ MilitaryTask(CCircuitUnit@ u) {
        if (u is null) return null;
        if (Active() && Global::RoleSettings::Sea::RespectCarrierControl
            && u.GetRulesParam("carrier_host_unit_id",-1)>=0) {
            if (u.task !is null && u.task.IsExternalControlled()) return u.task;
            return aiMilitaryMgr.EnqueueExternalControl("carrier_host_unit_id");
        }
        return aiMilitaryMgr.DefaultMakeTask(u);
    }
    void CarrierControl() {
        if (!Global::RoleSettings::Sea::RespectCarrierControl) return;
        // Host ownership is assigned after the engine's creation callback.
        // Adopt on the next SEA census as well as at normal task assignment.
        for (uint i=0;i<owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]);
            if (u is null || u.task is null || u.task.IsExternalControlled()
                || u.task.GetType()==int(Task::Type::PLAYER) || !u.circuitDef.IsMobile()
                || u.circuitDef.GetBuildSpeed()>0 || u.GetRulesParam("carrier_host_unit_id",-1)<0) continue;
            IUnitTask@ task=aiMilitaryMgr.EnqueueExternalControl("carrier_host_unit_id");
            if (task !is null && aiMilitaryMgr.TransferUnit(u,task))
                GenericHelpers::LogUtil("[SEA][Carrier] game owns "+u.circuitDef.GetName()+"("+u.id+")",1);
            else if (task !is null) {
                task.Abort();
                Invariants::Violation("INV-132",""+u.id,"SEA could not yield a carrier-owned military unit");
            }
        }
    }
    void Leave() {
        for (uint i=0;i<owned.length();++i) {
            CCircuitUnit@ unit=ai.GetTeamUnit(owned[i]);
            if (unit !is null) unit.SetRetreatWaypoint(AIFloat3(0,0,0),-1,-1);
        }
        SeaOperations::Leave();
        SeaComposition::Prune();
        SeaPatrol::Leave();
        SeaControl::Reset();
        SeaProtection::Leave();
        for (uint i=0;i<owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]);
            if (u is null || u.task is null) continue;
            if (!u.task.IsExternalControlled()) continue;
            // Attachment belongs to the game, not to the SEA role. A role
            // transition must not briefly fight the gadget for its live queue.
            // The native external task resumes AI control after owner release.
            if (u.GetRulesParam("carrier_host_unit_id",-1)>=0) continue;
            IUnitTask@ old=u.task;
            IUnitTask@ task=aiMilitaryMgr.DefaultMakeTask(u);
            if (task !is null && !aiMilitaryMgr.TransferUnit(u,task)) task.Abort();
            if (old.IsExternalControlled()) old.Abort();
        }
        frame=-100000;
        subSeen=-100000; airSeen=-100000; surface=0; underwater=0; air=0; shore=0;
    }
    void Add(const string &in name,float s,float w,float a,bool siege=false) { roster.insertLast(Hull(name,s,w,a,siege)); }
    void Init() {
        if (roster.length()>0) return;
        const float hybrid=Global::RoleSettings::Sea::HybridSubCoverWeight;
        Add("armdecade",1,0,0); Add("armpt",.25f,0,.5f); Add("armpship",1,0,0); Add("armroy",1,hybrid,0); Add("armsub",0,1,0);
        Add("coresupp",1,0,0); Add("corpt",.25f,0,.7f); Add("corpship",1,0,0); Add("corroy",1,hybrid,0); Add("corsub",0,1,0);
        Add("legnavyscout",1,0,0); Add("legnavyaaship",0,0,1); Add("legnavyfrigate",0,1,0); Add("legnavydestro",1,0,0); Add("legnavysub",0,1,0); Add("legnavyartyship",1,0,0,true);
        Add("armcrus",1,1,0); Add("armsubk",0,1,0); Add("armserp",0,1.25f,0); Add("armaas",0,0,1); Add("armbats",1,0,0); Add("armmship",1,0,.2f,true); Add("armepoch",1,0,.15f,true); Add("armlship",1,0,.25f);
        Add("corcrus",1,1,0); Add("corshark",0,1,0); Add("corssub",0,1.25f,0); Add("corarch",0,0,1); Add("corbats",1,0,0); Add("cormship",1,0,.2f,true); Add("corblackhy",1,0,.15f,true); Add("corfship",1,0,.25f);
        Add("leganavycruiser",1,1,0); Add("leganavybattlesub",0,1,0); Add("leganavyheavysub",0,1.25f,0); Add("leganavyaaship",0,0,1); Add("leganavybattleship",1,0,0); Add("leganavymissileship",1,0,.2f,true); Add("leganavyartyship",1,0,0,true); Add("leganavyflagship",1,0,0,true); Add("leganavyantiswarm",1,0,.25f);
    }
    void Tick() {
        if (!Active() || ai.frame-frame<SECOND) return;
        frame=ai.frame; Init();
        SeaComposition::Prune();
        // Independent of builder/layout census; IDs are owned by this policy
        // and reacquired inside each consumer, including transfer/role exit.
        array<Id>@ ids=ai.GetOwnedUnitIds(); owned.resize(0);
        for (uint i=0;i<ids.length();++i) owned.insertLast(ids[i]);
        CarrierControl(); fleet=0;
        for (uint i=0;i<roster.length();++i) if (roster[i].def !is null) fleet+=roster[i].def.costM*float(roster[i].def.count);
        AIFloat3 origin=Global::Map::StartPos;
        for (uint i=0;i<SeaLayout::berths.length();++i) if (SeaLayout::berths[i].slot>=0 && !SeaLayout::berths[i].retired) { origin=SeaLayout::berths[i].centre; break; }
        aiBattle.SampleNavalThreat(origin,Global::RoleSettings::Sea::ThreatResponseRadius);
        float nextSub=aiBattle.GetNavalThreatCost(1);
        const float nextAir=aiBattle.GetNavalThreatCost(2);
        const int contacts=aiBattle.GetSeaForceCount(), basin=aiBattle.WaterBody(origin,false);
        for (int i=0;i<contacts;++i) {
            if ((aiBattle.GetSeaForceFlags(i)&16)==0 || (basin>=0 && aiBattle.GetSeaForceBody(i)!=basin)) continue;
            const float radius=Global::RoleSettings::Sea::ThreatResponseRadius;
            if (MapHelpers::SqDist(origin,aiBattle.GetSeaForcePos(i))<=radius*radius)
                nextSub+=Global::RoleSettings::Sea::UnknownSubContactMetal;
        }
        if ((nextSub>0 && underwater==0) || (nextAir>0 && air==0))
            GenericHelpers::LogUtil("[SEA][Threat] submarine="+nextSub+" aircraft="+nextAir,1);
        if (nextSub>0) subSeen=ai.frame;
        if (nextAir>0) airSeen=ai.frame;
        const int memory=Global::RoleSettings::Sea::FleetThreatMemorySeconds*SECOND;
        surface=aiBattle.GetNavalThreatCost(0);
        // Sonar coverage can blink while a hull moves or a scout dies. Forget
        // its cost after a bounded policy interval, not at the next factory
        // ask. This retains no hidden positions and never issues a blind shot.
        // D-347: submarines hide between sonar pings. The 2026-10-19 Glacial
        // log showed the sub threat dropping to 0 thirty seconds after each
        // contact, so counters were never queued. Remember their cost longer
        // (cost only; no hidden position is kept).
        underwater=SeaMath::RememberThreat(underwater,nextSub,ai.frame-subSeen,
            AiMax(memory,Global::RoleSettings::Sea::SubThreatMemorySeconds*SECOND));
        air=SeaMath::RememberThreat(air,nextAir,ai.frame-airSeen,memory);
        shore=aiBattle.GetNavalThreatCost(3);
        SeaPatrol::Tick();
        SeaControl::Tick();
        SeaProtection::Tick();
        // Avoid the legacy map-wide army/per-player comparison. The native
        // reachable-group gate and damage-triggered response remain active.
        aiMilitaryMgr.quota.attack=Global::RoleSettings::Sea::MilitaryAttackThreshold;
        aiMilitaryMgr.quota.attackWait=Global::RoleSettings::Sea::FleetAssemblySeconds;
        SeaOperations::Tick();
    }
    float Coverage(Hull@ h,int kind) {
        const CCircuitDef@ d=h.def;
        if (d is null) return 0;
        if (kind==2) return d.HasSurfToAir() ? h.air : 0;
        if (kind==1) return d.HasSurfToWater() || d.HasSubToWater() ? h.underwater : 0;
        return d.HasSurfToLand() ? h.surface : 0;
    }
    CCircuitDef@ T1Priority(CCircuitUnit@ yard) {
        if (!Active()) return null;
        Tick();
        if (UnitHelpers::IsT1Shipyard(yard.circuitDef.GetName())) {
            const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
            CCircuitDef@ scout=ai.GetCircuitDef(side=="armada" ? "armpt" : side=="cortex" ? "corpt" : "legnavyscout");
            const int desired=fleet<1000 ? 1 : Global::RoleSettings::Sea::FleetScouts;
            const int scouts=scout is null ? 0 : scout.count+aiFactoryMgr.GetPendingRecruitCount(scout);
            // One live scout is always replaced; further losses wait out the
            // cooldown instead of re-queuing every death at once (D-300).
            if (scout !is null && scouts<desired && !SmallBoatFull(scout)
                && scout.IsAvailable(ai.frame) && yard.circuitDef.CanBuild(scout)) return NoteSmallBoat(scout);
            // The T2 yard supplies advanced surface/AA hulls. Keep the T1 yard
            // useful as a submarine screen/raiding stream. This is after the
            // caller's workforce, recovery and urgent air/sub counter checks.
            if (Global::RoleSettings::Sea::T1SubmarinesAfterT2 && SeaFactories::T2Finished(side)
                && SeaControl::NeedSubs(aiBattle.WaterBody(yard.GetPos(ai.frame),false))) {
                CCircuitDef@ sub=ai.GetCircuitDef(side=="armada" ? "armsub" : side=="cortex" ? "corsub" : "legnavysub");
                if (sub !is null && sub.IsAvailable(ai.frame) && yard.circuitDef.CanBuild(sub)) {
                    GenericHelpers::LogUtil("[SEA][SubStream] recruit="+sub.GetName(),1);
                    return sub;
                }
            }
        }
        return null;
    }
    CCircuitDef@ Select(CCircuitUnit@ yard,bool urgentOnly=false) {
        if (!Active()) return null;
        Tick();
        if (!urgentOnly) { CCircuitDef@ priority=T1Priority(yard); if (priority !is null) return priority; }
        array<float> have(3,0.0f);
        dictionary localCounts;
        const int body=aiBattle.WaterBody(yard.GetPos(ai.frame),false);
        // One owned pass, then O(R) roster arithmetic. A fleet in another sea
        // cannot repay this yard's underwater deficit. Native pending recruits
        // count UNFRAMED tasks only. Include owned frames here exactly once;
        // otherwise a second yard over-orders while the first hull is building.
        for (uint i=0;i<owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]);
            if (u is null || aiBattle.WaterBody(u.GetPos(ai.frame),false)!=body) continue;
            const string key=""+u.circuitDef.id;
            // dictionary.get uses an out parameter: on a missing key its
            // temporary need not retain our initializer. Always reset on
            // failure or phantom coverage can suppress emergency production.
            const int count=DictIntOr(localCounts,key);
            localCounts.set(key,count+1);
        }
        for (uint i=0;i<roster.length();++i) {
            Hull@ h=roster[i]; if (h.def is null) continue;
            const int count=DictIntOr(localCounts,""+h.def.id);
            const float value=h.def.costM*float(count+aiFactoryMgr.GetPendingRecruitCount(h.def));
            for (int k=0;k<3;++k) have[k]+=value*Coverage(h,k);
        }
        const float needAir=SeaMath::Deficit(air*Global::RoleSettings::Sea::AirCounterRatio,have[2],0);
        const float needSub=SeaMath::Deficit(underwater*Global::RoleSettings::Sea::SubCounterRatio,have[1],0);
        int kind=-1; float deficit=0;
        if (needAir>0) { kind=2; deficit=needAir; }
        if (needSub>deficit) { kind=1; deficit=needSub; }
        if (kind<0 && urgentOnly) return null;
        if (kind<0 && Global::RoleSettings::Sea::BalancedFleetComposition) {
            CCircuitDef@ baseline=SeaComposition::Select(yard,localCounts);
            if (baseline !is null) return baseline;
        }
        if (kind<0) {
            if (have[2]<fleet*Global::RoleSettings::Sea::FleetAirCoverShare) { kind=2; deficit=fleet*Global::RoleSettings::Sea::FleetAirCoverShare-have[2]; }
            else if (have[1]<fleet*Global::RoleSettings::Sea::FleetSubCoverShare) { kind=1; deficit=fleet*Global::RoleSettings::Sea::FleetSubCoverShare-have[1]; }
            else { kind=0; deficit=AiMax(1000.0f,surface); }
        }
        CCircuitDef@ best=null; float score=0;
        const float power=SeaLayout::Enabled() ? SeaEconomy::LocalPower(yard) : yard.circuitDef.GetBuildSpeed();
        for (uint i=0;i<roster.length();++i) {
            Hull@ h=roster[i]; CCircuitDef@ d=h.def;
            if (d is null || !d.IsAvailable(ai.frame) || !yard.circuitDef.CanBuild(d)) continue;
            if (kind==2 ? SmallBoatAirFull(d) : SmallBoatFull(d)) continue; // D-300/D-301 small-boat budgets
            if (h.siege && (urgentOnly || kind!=0 || fleet<Global::RoleSettings::Sea::SiegeFleetMetal || shore<=0)) continue;
            // Preserve a screen; expensive siege never fills the entire queue.
            if (h.siege && float(d.count+aiFactoryMgr.GetPendingRecruitCount(d))*d.costM>fleet*.25f) continue;
            const float weight=Coverage(h,kind);
            float rank=SeaMath::CounterScore(deficit,d.costM*weight,d.GetBuildTime()/AiMax(1.0f,power),weight>0);
            if (kind==0) {
                // Longer range is useful in fleet combat; cheap fast raiders
                // still appear at the opening, before a battle line exists.
                const float range=d.GetMaxRange(1); // CCircuitDef::RangeType::LAND
                rank*=1.0f+range/400.0f;
                if (range<400 && fleet>600) rank*=.3f;
                if (h.siege) rank*=1.5f;
            }
            if (rank>score) { @best=d; score=rank; }
        }
        // D-301: a capped or unbuildable counter layer (e.g. the Skater as the
        // only T1 AA) must not hand the yard to native production.
        if (best is null && !urgentOnly && Global::RoleSettings::Sea::BalancedFleetComposition) {
            CCircuitDef@ baseline=SeaComposition::Select(yard,localCounts);
            if (baseline !is null) return baseline;
        }
        if (best !is null) GenericHelpers::LogUtil("[SEA]["+(urgentOnly ? "Response" : "Production")+"] layer="+kind+" deficit="+deficit+" observedSub="+underwater+" subCover="+have[1]+" recruit="+best.GetName(),1);
        if (best !is null && ((kind==2 && !best.HasSurfToAir())
            || (kind==1 && !best.HasSurfToWater() && !best.HasSubToWater())
            || (kind==0 && !best.HasSurfToLand()))) {
            Invariants::Violation("INV-131",best.GetName(),"SEA counter lacks target-layer weapon");
            return null;
        }
        return NoteSmallBoat(best,kind==2);
    }
}
