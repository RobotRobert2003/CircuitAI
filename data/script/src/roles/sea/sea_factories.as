#include "../../systems/sea/sea_economy.as"
#include "../../systems/sea/sea_combat.as"

namespace SeaFactories {
    bool T2Finished(const string &in side) {
        CCircuitDef@ d=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(side));
        return d !is null && d.count>aiBuilderMgr.GetUnfinishedCount(d);
    }
    bool NeedSeaplane(const string &in side) {
        CCircuitDef@ d=ai.GetCircuitDef(UnitHelpers::GetSeaplanePlatformNameForSide(side));
        return d !is null && d.IsAvailable(ai.frame) && SeaMath::SeaplaneNext(Global::RoleSettings::Sea::SeaplanesAfterT2,
            T2Finished(side),d.count,aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY),d));
    }
    bool FactoryAllowed(const CCircuitDef@ d, bool capacityExpansion=false) {
        // Explicit SEA overflow admission only. Ordinary native switching and
        // invasion objectives retain their previous gates. Placement still
        // requires a surveyed forward berth, allied reservations and an exit.
        if (capacityExpansion && d !is null && Global::RoleSettings::Sea::OverflowFactories
            && SeaEconomy::capacityPressure) {
            const string side=UnitHelpers::GetSideForUnitName(d.GetName());
            if (UnitHelpers::IsSeaplanePlatform(d.GetName())) return T2Finished(side) && SeaEconomy::SeaplaneReady(ai.GetCircuitDef(d.id));
            if (UnitHelpers::IsT2Shipyard(d.GetName())) return T2Finished(side) || SeaEconomy::TechCommitted() || SeaEconomy::TechReady(ai.GetCircuitDef(d.id));
            return UnitHelpers::IsT1Shipyard(d.GetName()) || (SeaInvasion::Active() && SeaInvasion::Factory(d) && T2Finished(side));
        }
        // Native switching must not bypass SEA's surveyed forward staging.
        if (SeaInvasion::Active() && SeaInvasion::Factory(d)) return false;
        if (d is null || !Global::RoleSettings::Sea::SeaplanesAfterT2) return true;
        const string side=UnitHelpers::GetSideForUnitName(d.GetName());
        if (UnitHelpers::IsT2Shipyard(d.GetName()) && d.count==0 && !SeaEconomy::TechCommitted() && !SeaEconomy::TechReady(ai.GetCircuitDef(d.id))) return false;
        if (UnitHelpers::IsSeaplanePlatform(d.GetName())) return T2Finished(side) && SeaEconomy::SeaplaneReady(d);
        // A lost opening yard must remain recoverable. Other discretionary
        // factory purchases wait for the post-T2 platform commitment.
        return (UnitHelpers::IsT1Shipyard(d.GetName()) && d.count==0) || !NeedSeaplane(side);
    }
    int nextForward=0, stableSince=-1;
    AIFloat3 forwardSite(-1,0,-1);
    dictionary draining;
    dictionary urgentProducts;
    bool CombatHull(const CCircuitDef@ d) {
        // Profiles intentionally zero naval threat weights. Combat role masks
        // remain valid for friendly cover; threat weights are enemy valuation.
        return d !is null && d.IsMobile() && !d.IsAbleToFly() && d.GetBuildSpeed()<=0
            && d.IsRoleAny(Unit::Role::ASSAULT.mask | Unit::Role::SKIRM.mask | Unit::Role::RAIDER.mask
                | Unit::Role::RIOT.mask | Unit::Role::ARTY.mask | Unit::Role::AS.mask);
    }
    bool Hold(CCircuitUnit@ u) { return SeaLayout::Active() && u !is null && (Lifecycle::IsRetiring(u) || draining.exists(""+u.id)); }
    IUnitTask@ Recruit(CCircuitUnit@ yard, CCircuitDef@ d, Task::RecruitType type, bool funded=false, bool urgent=false) {
        if (d is null || !d.IsAvailable(ai.frame) || !yard.circuitDef.CanBuild(d)) return null;
        IUnitTask@ t=aiFactoryMgr.Enqueue(TaskS::Recruit(type,Task::Priority::HIGH,d,yard.GetPos(ai.frame),64.0f));
        if (t !is null) {
            if (urgent) urgentProducts.set(""+yard.id,int(d.id)); else urgentProducts.delete(""+yard.id);
        }
        if (t !is null && funded) SeaEconomy::Admit(d,true);
        return t;
    }
    IUnitTask@ Utility(CCircuitUnit@ yard) {
        if (!SeaCombat::Active() || yard is null) return null;
        const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
        const bool advanced=UnitHelpers::IsT2Shipyard(yard.circuitDef.GetName());
        array<string> names;
        if (!advanced && Global::RoleSettings::Sea::EnableEarlyRezSub) {
            CCircuitDef@ rez=ai.GetCircuitDef(side=="armada" ? "armrecl" : side=="cortex" ? "correcl" : "legnavyrezsub");
            const int target=AiMax(SeaRecovery::Demand(rez),SeaMath::RecoveryCount(aiEconomyMgr.metal.income,SeaCombat::fleet,
                Global::RoleSettings::Sea::MetalIncomePerRezSub,Global::RoleSettings::Sea::FleetMetalPerRezSub));
            if (rez !is null && rez.count+aiFactoryMgr.GetPendingRecruitCount(rez)<target
                && aiFactoryMgr.GetPendingRecruitCount(rez)==0) {
                // A free requesting yard is available capacity. Fund both the
                // hull and energy before allocating this discretionary support.
                SeaEconomy::Tick();
                if (SeaEconomy::Fund(rez,AiMax(yard.circuitDef.GetBuildSpeed(),SeaEconomy::LocalPower(yard)))) {
                    IUnitTask@ t=Recruit(yard,rez,Task::RecruitType::BUILDPOWER,true);
                    if (t !is null) { GenericHelpers::LogUtil("[SEA][Recovery] recruit "+rez.GetName()+" target="+target,1); return t; }
                }
            }
        }
        if (advanced && SeaCombat::fleet>=5000) {
            CCircuitDef@ protection=ai.GetCircuitDef(UnitHelpers::GetNavalAntiNukeShipNameForSide(side));
            if (protection !is null && protection.count+aiFactoryMgr.GetPendingRecruitCount(protection)<SeaProtection::Demand()) {
                IUnitTask@ task=Recruit(yard,protection,Task::RecruitType::FIREPOWER);
                if (task !is null) return task;
            }
            names.insertLast(UnitHelpers::GetNavalJammerShipNameForSide(side));
        }
        for (uint i=0;i<names.length();++i) {
            CCircuitDef@ d=ai.GetCircuitDef(names[i]);
            if (d !is null && d.count+aiFactoryMgr.GetPendingRecruitCount(d)==0) {
                IUnitTask@ t=Recruit(yard,d,Task::RecruitType::FIREPOWER);
                if (t !is null) return t;
            }
        }
        return null;
    }
    IUnitTask@ Workforce(CCircuitUnit@ yard) {
        if (!SeaLayout::Enabled() || yard is null || !SeaEconomy::Yard(yard.circuitDef)) return null;
        SeaEconomy::Tick();
        const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
        const bool advanced=UnitHelpers::IsT2Shipyard(yard.circuitDef.GetName());
        CCircuitDef@ con=ai.GetCircuitDef(SeaEconomy::Constructor(side,advanced));
        if (con is null || !yard.circuitDef.CanBuild(con)) return null;
        const int pending=aiFactoryMgr.GetPendingRecruitCount(con), have=con.count+pending;
        if (have<2) return Recruit(yard,con,Task::RecruitType::BUILDPOWER);
        if (!advanced && have<3 && pending==0) {
            CCircuitDef@ opening=ai.GetCircuitDef(UnitHelpers::GetTidalNameForSide(side));
            if (opening !is null && aiEconomyMgr.energy.income>=Global::RoleSettings::Sea::BuildT1ConvertersMinimumEnergyIncome
                && SeaEconomy::FundGrowth(yard,con,opening)) return Recruit(yard,con,Task::RecruitType::BUILDPOWER,true);
        }
        const float energyGoal=advanced ? aiEconomyMgr.metal.income*Global::RoleSettings::Sea::EnergyPerMetal : SeaEconomy::HomeEnergyTarget();
        // Every extra worker must have growth work, not just an absent local
        // assistant. This prevents reclassifying factory guards from causing
        // an unlimited queue of constructors with nothing useful to build.
        if (aiEconomyMgr.energy.income>=energyGoal && !SeaEconomy::capacityPressure) return null;
        CCircuitDef@ project=ai.GetCircuitDef(advanced ? UnitHelpers::GetNavalFusionNameForSide(side) : UnitHelpers::GetTidalNameForSide(side));
        if (project is null) return null;
        const uint tier=advanced ? 1 : 0;
        const float shortage=BuildPowerMath::Shortage(SeaEconomy::UsefulPower(project,Global::RoleSettings::Sea::EconomyIncomeShare),SeaEconomy::homePower[tier],SeaEconomy::homePending[tier]);
        if (shortage<con.GetBuildSpeed()*.5f || SeaEconomy::homeIdle[tier]>=con.GetBuildSpeed() || pending>0 || project is null) return null;
        if (!SeaEconomy::FundGrowth(yard,con,project)) return null;
        IUnitTask@ task=Recruit(yard,con,Task::RecruitType::BUILDPOWER,true);
        if (task !is null) GenericHelpers::LogUtil("[SEA][Workforce] recruit "+con.GetName()+" shortage="+shortage,1);
        return task;
    }
    IUnitTask@ Produce(CCircuitUnit@ yard) {
        if (yard is null || !SeaEconomy::Yard(yard.circuitDef)) return aiFactoryMgr.MakeFactoryTask(yard,true,Global::RoleSettings::Sea::KeepFactoriesQueued);
        if (Hold(yard)) return aiFactoryMgr.Enqueue(TaskS::Wait(true,SECOND));
        SeaEconomy::Tick();
        const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
        const bool advanced=UnitHelpers::IsT2Shipyard(yard.circuitDef.GetName());
        CCircuitDef@ con=ai.GetCircuitDef(SeaEconomy::Constructor(side,advanced));
        if (con !is null && con.count+aiFactoryMgr.GetPendingRecruitCount(con)>=1) {
            CCircuitDef@ counter=SeaCombat::Select(yard,true);
            if (counter !is null) { SeaComposition::Pending(yard,true); IUnitTask@ response=Recruit(yard,counter,Task::RecruitType::FIREPOWER,false,true); if (response !is null) return response; }
        }
        if (!advanced && SeaEconomy::TechHold()) {
            // D-300: bank for the first advanced yard. Threat counters above
            // still run; keep the two constructors that build and assist it.
            if (con !is null && con.count+aiFactoryMgr.GetPendingRecruitCount(con)<2) {
                IUnitTask@ worker=Recruit(yard,con,Task::RecruitType::BUILDPOWER); if (worker !is null) return worker;
            }
            return aiFactoryMgr.Enqueue(TaskS::Wait(false,3*SECOND));
        }
        IUnitTask@ workforce=Workforce(yard); if (workforce !is null) { SeaComposition::Pending(yard,true); return workforce; }
        if (SeaCombat::Active()) {
            // Single recruits keep scout replacement responsive and stop the
            // stream when coverage is complete; do not hide it behind batches.
            CCircuitDef@ priority=SeaCombat::T1Priority(yard);
            if (priority !is null) {
                SeaComposition::Pending(yard,true);
                IUnitTask@ task=Recruit(yard,priority,Task::RecruitType::FIREPOWER);
                if (task !is null) return task;
            }
            // Shared by both economic implementations; counter emergencies
            // above retain precedence over discretionary utility hulls.
            IUnitTask@ utility=Utility(yard); if (utility !is null) return utility;
            IUnitTask@ pending=SeaComposition::Pending(yard); if (pending !is null) return pending;
            CCircuitDef@ selected=SeaCombat::Select(yard);
            if (selected !is null) {
                IUnitTask@ combat=Global::RoleSettings::Sea::BalancedFleetComposition
                    ? SeaComposition::Enqueue(yard,selected) : Recruit(yard,selected,Task::RecruitType::FIREPOWER);
                if (combat !is null) return combat;
            }
        }
        if (!advanced && !SeaCombat::Active() && Global::RoleSettings::Sea::UseDynamicFactoryProduction) {
            IUnitTask@ task=FactoryProduction::MakeTask(yard); if (task !is null) return task;
        }
        if (!advanced && Global::RoleSettings::Sea::EnableEarlyRezSub) {
            CCircuitDef@ rez=ai.GetCircuitDef(side=="armada" ? "armrecl" : side=="cortex" ? "correcl" : "legnavyrezsub");
            if (rez !is null && EconomyHelpers::ShouldBuildT1ResurrectionSub(aiEconomyMgr.metal.income,
                rez.count+aiFactoryMgr.GetPendingRecruitCount(rez),Global::RoleSettings::Sea::MetalIncomePerRezSub,true)) {
                IUnitTask@ task=Recruit(yard,rez,Task::RecruitType::FIREPOWER); if (task !is null) return task;
            }
        }
        if (advanced && !SeaCombat::Active()) {
            // Preserve the existing fleet mix; queue-aware deficits avoid overshoot.
            const array<string> names={UnitHelpers::GetNavalT2DestroyerNameForSide(side),UnitHelpers::GetNavalAAShipNameForSide(side),
                UnitHelpers::GetNavalJammerShipNameForSide(side),UnitHelpers::GetNavalRadarShipNameForSide(side),
                UnitHelpers::GetNavalMissileShipNameForSide(side),UnitHelpers::GetNavalAntiNukeShipNameForSide(side),
                side=="armada" ? "armepoch" : side=="cortex" ? "corblackhy" : "leganavyflagship"};
            const array<int> goals={Global::RoleSettings::Sea::MinT2DestroyerCount,2,1,1,5,1,1};
            for (uint i=0; i<names.length(); ++i) {
                CCircuitDef@ d=ai.GetCircuitDef(names[i]);
                if (d is null || !yard.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame)) continue;
                if (SeaMath::Missing(goals[i],d.count,aiFactoryMgr.GetPendingRecruitCount(d),1)>0) {
                    IUnitTask@ t=Recruit(yard,d,Task::RecruitType::FIREPOWER); if (t !is null) return t;
                }
            }
        }
        return aiFactoryMgr.MakeFactoryTask(yard,true,Global::RoleSettings::Sea::KeepFactoriesQueued);
    }
    bool Safe(const AIFloat3 &in p) {
        if (aiBattle.AmphThreat(p)>Global::RoleSettings::Sea::HarborMaxThreat || aiBattle.AirThreat(p)>Global::RoleSettings::Sea::HarborMaxThreat) return false;
        // Current nearby naval presence supplies vision and protects the site.
        float cover=0;
        for (uint i=0; i<SeaEconomy::owned.length(); ++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (u is null || u.GetBuildProgress()<1 || !CombatHull(u.circuitDef)
                || aiBattle.WaterBody(u.GetPos(ai.frame),false)<0) continue;
            if (MapHelpers::SqDist(p,u.GetPos(ai.frame))<600.0f*600.0f) {
                cover+=u.circuitDef.costM;
                if (cover>=1500.0f) return true;
            }
        }
        return cover>=1500.0f;
    }
    void Tick() {
        if (!SeaLayout::Active()) return;
        // Complete the handover before considering another replacement.
        for (uint i=0; i<SeaLayout::berths.length(); ++i) {
            SeaLayout::Berth@ b=SeaLayout::berths[i];
            if (b.oldUnit<0) continue;
            CCircuitUnit@ old=ai.GetTeamUnit(b.oldUnit);
            CCircuitUnit@ fresh=ai.GetTeamUnit(b.unit);
            if (old is null) { b.oldUnit=-1; SeaLayout::Save(b); continue; }
            if (Lifecycle::IsRetiring(old)) continue;
            if (fresh is null && !Safe(b.anchor)) {
                array<IUnitTask@> work=SeaEconomy::projects;
                for (uint j=0; j<work.length(); ++j) {
                    IBuilderTask@ task=cast<IBuilderTask>(work[j]);
                    if (task is null || task.IsDead() || task.target !is null || AiTaskReservationId(task)!=b.slot) continue;
                    array<CCircuitUnit@>@ workers=task.GetUnits();
                    for (uint w=0; w<workers.length(); ++w) if (workers[w] !is null && workers[w].task is task) workers[w].CmdStop();
                    aiBuilderMgr.AbortTask(task);
                }
                draining.delete(""+old.id); b.oldUnit=-1; b.retired=true; SeaLayout::Save(b);
                GenericHelpers::LogUtil("[SEA][Harbor] cancelled unsafe unstarted replacement",1);
                continue;
            }
            const bool ready=fresh !is null && fresh.GetBuildProgress()>=1 && b.exited && Safe(b.centre);
            if (!ready) { draining.delete(""+old.id); continue; }
            draining.set(""+old.id,true);
            const bool busy=SeaEconomy::Busy(old.id);
            if (SeaMath::RetireReady(true,b.exited,true,old.circuitDef is fresh.circuitDef,busy,
                aiEconomyMgr.metal.storage-aiEconomyMgr.metal.current,old.circuitDef.costM)) {
                if (old.task !is null && !old.task.IsDead()) aiFactoryMgr.AbortTask(old.task);
                Lifecycle::Retire(old,"SEA replacement "+fresh.id+" has produced an exiting ship");
                for (uint j=0; j<SeaLayout::berths.length(); ++j) if (SeaLayout::berths[j].unit==old.id) {
                    SeaLayout::berths[j].retired=true; SeaLayout::Save(SeaLayout::berths[j]);
                }
                if (!b.exited) Invariants::Violation("INV-130",b.key,"SEA retired before verified egress");
            }
        }
        if (!Global::RoleSettings::Sea::ForwardHarbors || ai.frame<nextForward) return;
        nextForward=ai.frame+5*SECOND;
        for (uint i=0; i<SeaLayout::berths.length(); ++i) if (SeaLayout::berths[i].oldUnit>=0) return;
        CCircuitUnit@ old=null;
        for (uint i=0; i<SeaEconomy::owned.length(); ++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (u !is null && SeaEconomy::Yard(u.circuitDef) && u.GetBuildProgress()>=1 && !Lifecycle::IsRetiring(u)
                && (old is null || MapHelpers::SqDist(u.GetPos(ai.frame),Global::Map::StartPos)<MapHelpers::SqDist(old.GetPos(ai.frame),Global::Map::StartPos))) @old=u;
        }
        if (old is null || SeaEconomy::mobilePower<500.0f || aiEconomyMgr.metal.income<60) return;
        AIFloat3 best(-1,0,-1); float gain=Global::RoleSettings::Sea::ForwardMinimumGain;
        const AIFloat3 target=LayoutHelpers::TerrainCentre(), from=old.GetPos(ai.frame);
        array<AIFloat3> candidates;
        array<float> gains;
        for (uint i=0; i<SeaEconomy::owned.length(); ++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (u is null || !CombatHull(u.circuitDef) || aiBattle.WaterBody(u.GetPos(ai.frame),false)<0) continue;
            const AIFloat3 ship=u.GetPos(ai.frame);
            const float dist=sqrt(MapHelpers::SqDist(ship,from));
            if (dist<Global::RoleSettings::Sea::ForwardStep) continue;
            const float f=AiMin(Global::RoleSettings::Sea::ForwardStep*2.0f,AiMax(Global::RoleSettings::Sea::ForwardStep,dist-400.0f))/dist;
            const AIFloat3 p(from.x+(ship.x-from.x)*f,0,from.z+(ship.z-from.z)*f);
            const float saved=sqrt(MapHelpers::SqDist(from,target))-sqrt(MapHelpers::SqDist(p,target));
            if (saved<=gain) continue;
            bool duplicate=false;
            for (uint j=0; j<candidates.length(); ++j) if (MapHelpers::SqDist(p,candidates[j])<256.0f*256.0f) { duplicate=true; break; }
            if (duplicate) continue;
            if (candidates.length()<16) { candidates.insertLast(p); gains.insertLast(saved); }
            else {
                uint lowest=0; for (uint j=1; j<gains.length(); ++j) if (gains[j]<gains[lowest]) lowest=j;
                if (saved>gains[lowest]) { candidates[lowest]=p; gains[lowest]=saved; }
            }
        }
        // At most sixteen full cover checks, independent of fleet size.
        for (uint i=0; i<candidates.length(); ++i) if (gains[i]>gain && Safe(candidates[i])) { best=candidates[i]; gain=gains[i]; }
        if (best.x<0) { stableSince=-1; return; }
        if (SeaMath::RestartStability(stableSince,forwardSite.x<0 || MapHelpers::SqDist(best,forwardSite)>256.0f*256.0f)) { forwardSite=best; stableSince=ai.frame; return; }
        if (stableSince<0 || ai.frame-stableSince<Global::RoleSettings::Sea::ForwardStableSeconds*SECOND) return;
        CCircuitDef@ def=ai.GetCircuitDef(old.circuitDef.GetName());
        if (!SeaEconomy::Fund(def,SeaEconomy::mobilePower*.5f)) return;
        SeaLayout::Add(def.GetName(),forwardSite,old.id);
        nextForward=ai.frame+Global::RoleSettings::Sea::ForwardRecheckSeconds*SECOND;
        GenericHelpers::LogUtil("[SEA][Harbor] replacement candidate old="+old.id+" at="+int(forwardSite.x)+","+int(forwardSite.z),1);
    }
}
