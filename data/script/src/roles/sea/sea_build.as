#include "sea_factories.as"
#include "../../systems/sea/sea_eco_layout.as"
#include "../../systems/sea/sea_lanes.as"
#include "../../systems/sea/sea_expansion.as"

namespace SeaBuild {
    int lastTick=-1;
    // D-342 / INV-231: first frame this AI had a harbor, and whether the
    // economy-progress invariant already reported (once per game).
    int firstHarborFrame=-1; bool economyStallReported=false;
    dictionary supportRetry, siteRetry;
    class SiteProgress { string key; AIFloat3 pos; int since=0; }
    dictionary siteProgress;
    string SiteKey(IBuilderTask@ task) { const AIFloat3 p=task.GetBuildPos(); return ""+task.buildDef.id+":"+int(p.x/32)+":"+int(p.z/32); }
    bool RejectSite(CCircuitUnit@ u,IUnitTask@ task) {
        IBuilderTask@ work=cast<IBuilderTask>(task);
        if (work is null || work.buildDef is null || work.target !is null || work.IsEnemyReclaim() || work.IsExternalControlled()) return false;
        const int kind=work.GetBuildType();
        if (kind!=int(Task::BuildType::GEO) && kind!=int(Task::BuildType::GEOUP)) return false;
        int64 until=0; const string key=SiteKey(work);
        const bool blocked=siteRetry.get(key,until) && ai.frame<until;
        if (!blocked && aiTerrainMgr.CanReachAt(u,work.GetBuildPos(),u.circuitDef.GetBuildDistance())) return false;
        if (work.GetUnits().length()==0) aiBuilderMgr.AbortTask(task);
        return true;
    }
    void ObserveSiteProgress(CCircuitUnit@ u,IBuilderTask@ work) {
        const string unitKey=""+u.id;
        if (work is null || work.buildDef is null || work.target !is null || work.IsExternalControlled()
            || (work.GetBuildType()!=int(Task::BuildType::GEO) && work.GetBuildType()!=int(Task::BuildType::GEOUP))) { siteProgress.delete(unitKey); return; }
        const string key=SiteKey(work); const AIFloat3 p=u.GetPos(ai.frame);
        SiteProgress@ state;
        if (!siteProgress.get(unitKey,@state) || state is null || state.key!=key) {
            @state=SiteProgress(); state.key=key; state.pos=p; state.since=ai.frame; siteProgress.set(unitKey,@state); return;
        }
        if (MapHelpers::SqDist(p,state.pos)>64.0f*64.0f) { state.pos=p; state.since=ai.frame; return; }
        if (ai.frame-state.since<60*SECOND) return;
        siteRetry.set(key,int64(ai.frame+90*SECOND)); siteProgress.delete(unitKey);
        // Release this stalled worker only; frames/other workers retain their
        // native claims. The next ask may choose economy instead of the site.
        aiBuilderMgr.AssignTask(u,Wait());
        GenericHelpers::LogUtil("[SEA][Economy] blocked geo released worker="+u.id,1);
    }
    int placementLog=-100000;
    // D-342: true when the last Place call passed every economic gate and only
    // the water layout had no site. Funding/need refusals are not site
    // failures and never fall back.
    bool placeNoSite=false;
    // D-342: first frame each economy building found no layout site, keyed by
    // name; cleared when the layout places it again. Bounded by the handful
    // of SEA economy definitions.
    dictionary layoutDeferredSince;
    int fallbackLog=-100000;
    bool LayoutFallback(const string &in name, bool placed) {
        // D-344: only a placement resets the clock. A funding or need refusal
        // between asks (converters, often) is no evidence a site exists.
        if (placed) { layoutDeferredSince.delete(name); return false; }
        if (!placeNoSite) return false;
        int since=ai.frame;
        if (!layoutDeferredSince.get(name,since)) { layoutDeferredSince.set(name,ai.frame); since=ai.frame; }
        const int limit=Global::RoleSettings::Sea::LayoutFallbackSeconds;
        return limit>0 && ai.frame-since>=limit*SECOND;
    }
    int techQueueLog=-100000;
    IUnitTask@ Wait() { return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND)); }
    IUnitTask@ OpeningMex(CCircuitUnit@ u) {
        if (SeaExpansion::Active()) return SeaExpansion::Make(u);
        if (u is null || u !is Builder::primaryT1SeaConstructor || !SeaConstructor::IsT1(u.circuitDef)) return null;
        if (u.task !is null && (u.task.IsEnemyReclaim() || u.task.GetType()==int(Task::Type::PLAYER))) return u.task;
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) return current;
        // A ship's safe reachability query rejects routes across land/other
        // ponds and accepts reachable coastal mexes. Native owns spot claims,
        // allied occupancy and duplicate orders; do not duplicate its scan.
        const AIFloat3 home=Factory::primaryT1Shipyard is null ? Global::Map::StartPos : Factory::primaryT1Shipyard.GetPos(ai.frame);
        IUnitTask@ task=aiEconomyMgr.EnqueueMexWithin(u,home,Global::RoleSettings::Sea::NearbyMexRadius,0,true);
        if (task !is null) {
            IBuilderTask@ mex=cast<IBuilderTask>(task);
            if (mex is null || mex.GetBuildType()!=int(Task::BuildType::MEX))
                Invariants::Violation("INV-150",""+u.id,"SEA opening mex priority returned non-mex work");
            GenericHelpers::LogUtil("[SEA][Mex] first ship="+u.id+" takes nearby metal",1);
        }
        return task;
    }
    IUnitTask@ Seaplane(CCircuitUnit@ u) {
        if (u is null || !u.circuitDef.IsMobile()) return null;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        if (!SeaFactories::NeedSeaplane(side)) return null;
        CCircuitDef@ d=ai.GetCircuitDef(UnitHelpers::GetSeaplanePlatformNameForSide(side));
        if (!u.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame) || !SeaEconomy::SeaplaneReady(d)
            || !SeaEconomy::Fund(d,u.circuitDef.GetBuildSpeed(),0,0,
                Global::RoleSettings::Sea::SeaplaneMetalReserve,Global::RoleSettings::Sea::SeaplaneEnergyReserve)) return null;
        IUnitTask@ task=SeaLayout::Enabled() ? SeaLayout::Factory(u,d.GetName())
            : Builder::EnqueueSeaplanePlatform(side,Factory::GetT2ShipyardPos(),SQUARE_SIZE*24,600*SECOND);
        if (task !is null) {
            // The compact census resets admissions; with layouts explicitly
            // disabled native owns the order and its commitment accounting.
            if (SeaLayout::Enabled()) SeaEconomy::Admit(d,false,true);
            GenericHelpers::LogUtil("[SEA][Factory] post-T2 seaplane admitted "+d.GetName()
                +" minM="+Economy::GetMinMetalIncomeLast10s()+" minE="+Economy::GetMinEnergyIncomeLast10s()
                +" bankM="+aiEconomyMgr.metal.current+" bankE="+aiEconomyMgr.energy.current,1);
        }
        return task;
    }
    int SupportFootprint(CCircuitDef@ nano, const AIFloat3 &in centre, int stopAt=0) {
        if (nano is null) return 0;
        int count=0;
        // Placement-only query over reserved slots, never per-unit micro.
        // Include valid consumed slots: completed turrets still own footprint.
        for (uint p=0;p<SeaLayout::patches.length();++p) {
            SeaLayout::Patch@ patch=SeaLayout::patches[p];
            if (patch.name!=nano.GetName()) continue;
            for (uint s=0;s<patch.slots.length();++s) {
                const int state=aiTerrainMgr.GetReservationState(patch.slots[s]);
                if (state>=0 && state<4 && MapHelpers::SqDist(aiTerrainMgr.GetReservationPos(patch.slots[s]),centre)
                    <=nano.GetBuildDistance()*nano.GetBuildDistance()) {
                    ++count;
                    if (stopAt>0 && count>=stopAt) return count;
                }
            }
        }
        return count;
    }
    Task::BuildType PlacementKind(CCircuitDef@ d, int kind) {
        if (d is null) return Task::BuildType(kind);
        const string name=d.GetName(), side=UnitHelpers::GetSideForUnitName(name);
        if (name==UnitHelpers::GetT1NavalNanoNameForSide(side)) return Task::BuildType::NANO;
        if (name==UnitHelpers::GetTidalNameForSide(side) || name==UnitHelpers::GetNavalFusionNameForSide(side)) return Task::BuildType::ENERGY;
        if (SeaEcoLayout::Managed(d)) return Task::BuildType::CONVERT;
        return Task::BuildType(kind);
    }
    bool ControlledEconomy(CCircuitDef@ d) {
        if (d is null) return false;
        const string name=d.GetName(), side=UnitHelpers::GetSideForUnitName(name);
        return SeaEcoLayout::Managed(d) || name==UnitHelpers::GetTidalNameForSide(side)
            || name==UnitHelpers::GetT1NavalNanoNameForSide(side);
    }
    void Leave() {
        @techOrder=null;
        for (uint i=0;i<SeaEconomy::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (u !is null && u.circuitDef.GetBuildSpeed()>0) u.SetBuildPriorityOverride(-1);
        }
        SeaFactories::urgentProducts.deleteAll();
        SeaCoast::Leave();
        SeaExpansion::Reset();
        SeaInvasion::Leave();
        SeaRecovery::Leave();
        SeaCombat::Leave();
        siteRetry.deleteAll(); siteProgress.deleteAll();
        SeaEconomy::projects.resize(0); SeaFactories::draining.deleteAll();
        SeaEconomy::lastProducts.deleteAll(); SeaEconomy::capacityBanks.resize(0);
        SeaEconomy::capacityFrame=-1; SeaEconomy::capacityFull=0; SeaEconomy::capacityPressure=false;
        supportRetry.deleteAll();
        SeaTech::Release();
        SeaEcoLayout::Reset();
        SeaLayout::Leave();
    }
    bool ReserveSupport(CCircuitDef@ nano, const AIFloat3 &in centre, int facing, CCircuitDef@ factory=null, const string &in owner="") {
        if (nano is null || factory is null || owner=="") return false;
        for (uint i=0;i<SeaLayout::patches.length();++i) {
            SeaLayout::Patch@ p=SeaLayout::patches[i];
            if (p.owner!=owner || p.slots.length()==0) continue;
            if (!p.active && LayoutHelpers::ActivationState(p.slots)==1) {
                SeaLayout::ReleaseSupport(owner); break; // untouched blocked bank is replanned
            }
            return false;
        }
        int64 retry=0;
        if (supportRetry.get(owner,retry) && ai.frame<retry) return false;
        supportRetry.set(owner,int64(ai.frame+10*SECOND));
        const int count=AiMax(4,AiMin(128,AiMin(Global::RoleSettings::Sea::MaxSupportPerBerth,Global::RoleSettings::Sea::ReservedSupportPerFactory)));
        const string key="sea.support."+owner;
        const int n=aiTerrainMgr.PlanNavalSupport(key,nano,factory,centre,facing,count,4,Global::RoleSettings::Sea::ExitMargin);
        if (n>0) {
            SeaLayout::Patch plan; plan.name=nano.GetName(); plan.owner=owner; plan.centre=centre; plan.facing=facing;
            for (int s=0;s<n;++s) plan.slots.insertLast(aiTerrainMgr.GetLayoutInt(key+".slot."+s,-1));
            SeaLayout::patches.insertLast(plan); SeaLayout::SavePatch(SeaLayout::patches.length()-1);
            GenericHelpers::LogUtil("[SEA][Capacity] reserved owner="+owner+" slots="+n+" at="+int(centre.x)+","+int(centre.z),1);
        }
        // The caller stops this scan after one transaction. Tick has separate
        // planned-berth and existing-factory scans: at most two attempts/tick.
        return true;
    }
    void Tick() {
        if (!SeaLayout::Enabled() || ai.frame-lastTick<SECOND) return;
        lastTick=ai.frame; SeaEconomy::Tick();
        SeaLanes::Tick(); // D-345: widget visualisation only; no unit reads the lanes
        CCircuitDef@ techYard=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(Global::AISettings::Side));
        if (techYard !is null && techYard.count>0) {
            if (techYard.count>aiBuilderMgr.GetUnfinishedCount(techYard)
                && SeaEconomy::Number(SeaEconomy::Constructor(Global::AISettings::Side,true),true)>0) SeaTech::Release();
            else {
                const AIFloat3 harbor=SeaEcoLayout::Harbor();
                if (harbor.x>=0) SeaTech::Permit(aiBattle.WaterBody(harbor,false),2);
            }
        }
        SeaLayout::RefreshGeometry();
        if (SeaLayout::Active()) { SeaCombat::Tick(); SeaFactories::Tick(); }
        const string side=Global::AISettings::Side;
        // INV-231: a SEA AI with a harbor and a construction ship gets some
        // naval energy within the layout fallback plus a generous grace. O(1).
        if (!economyStallReported && SeaEcoLayout::Harbor().x>=0) {
            if (firstHarborFrame<0) firstHarborFrame=ai.frame;
            const int limit=Global::RoleSettings::Sea::LayoutFallbackSeconds;
            // Only while energy is actually short: cheat/supplied economies and
            // a full bank legitimately need no naval energy yet.
            // D-351: only inside a window after the harbor (the fallback limit
            // plus 5 to 15 minutes). A late dip in a healthy land-energy economy
            // is not a stalled naval economy (Glacial team 4, 1,000 E/s, minute 34).
            if (limit>0 && ai.frame-firstHarborFrame>(limit+300)*SECOND && ai.frame-firstHarborFrame<(limit+900)*SECOND
                && aiEconomyMgr.energy.current<aiEconomyMgr.energy.storage*.5f
                && SeaEconomy::Number(SeaEconomy::Constructor(side,false),true)>0) {
                CCircuitDef@ tidal=ai.GetCircuitDef(UnitHelpers::GetTidalNameForSide(side));
                CCircuitDef@ converter=ai.GetCircuitDef(UnitHelpers::GetNavalEnergyConverterNameForSide(side));
                if ((tidal is null || tidal.count==0) && (converter is null || converter.count==0)) {
                    economyStallReported=true;
                    Invariants::Violation("INV-231",side,"SEA harbor and construction ship but no tidal or naval converter after the layout fallback window");
                }
            }
        }
        for (uint p=0;p<SeaLayout::patches.length();++p) {
            const string owner=SeaLayout::patches[p].owner;
            if (owner.findFirst("unit.")==0 && ai.GetTeamUnit(int(parseInt(owner.substr(5)))) is null) {
                SeaLayout::ReleaseSupport(owner); break; // one lost-owner cleanup per tick
            }
        }
        CCircuitDef@ platform=ai.GetCircuitDef(UnitHelpers::GetSeaplanePlatformNameForSide(side));
        const bool planAir=Global::RoleSettings::Sea::SeaplanesAfterT2 && platform !is null && platform.IsAvailable(ai.frame);
        if (SeaLayout::Active() && SeaLayout::berths.length()==0 && !SeaLayout::hadFactory)
            SeaLayout::Add(UnitHelpers::GetT1ShipyardForSide(side),Global::Map::StartPos);
        Preplan(side,planAir);
        for (uint i=0; i<SeaLayout::berths.length(); ++i) {
            SeaLayout::Validate(SeaLayout::berths[i]);
            if (SeaLayout::berths[i].slot<0 && !SeaLayout::berths[i].active && !SeaLayout::berths[i].retired) { SeaLayout::Search(SeaLayout::berths[i]); break; }
        }
        // Reserve rear support before energy can consume the yard's build reach.
        CCircuitDef@ nano=ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(side));
        if (nano !is null) for (uint b=0; b<SeaLayout::berths.length(); ++b) {
            SeaLayout::Berth@ berth=SeaLayout::berths[b]; if (berth.slot<0 || berth.retired) continue;
            if (ReserveSupport(nano,berth.centre,berth.facing,ai.GetCircuitDef(berth.name),berth.key)) break;
        }
        // Amphibious complexes and other naval production use the same support
        // banks without entering shipyard tech/replacement bookkeeping.
        for (uint i=0; i<SeaEconomy::productionFactories.length(); ++i) {
            CCircuitUnit@ factory=ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
            if (factory is null) continue;
            // D-212 owns the coastal 6/12-pad footprint. Retrying the generic
            // 24-pad rectangle here every second duplicates that search and
            // often cannot fit the same coast. Income-based Support() below
            // remains available to add real build power above the initial pad.
            if (SeaInvasion::OwnsSupport(factory)) continue;
            bool planned=false;
            for (uint b=0;b<SeaLayout::berths.length();++b) if (SeaLayout::berths[b].unit==factory.id) { planned=true; break; }
            if (!planned && ReserveSupport(nano,factory.GetPos(ai.frame),aiTerrainMgr.GetBuildingFacing(factory),ai.GetCircuitDef(factory.circuitDef.id),"unit."+factory.id)) break;
        }
        const array<string> rejectedSites=siteRetry.getKeys();
        for (uint i=0;i<rejectedSites.length();++i) { int64 until=0; if (!siteRetry.get(rejectedSites[i],until) || ai.frame>=until) siteRetry.delete(rejectedSites[i]); }
        const array<string> siteWorkers=siteProgress.getKeys();
        for (uint i=0;i<siteWorkers.length();++i) if (ai.GetTeamUnit(int(parseInt(siteWorkers[i]))) is null) siteProgress.delete(siteWorkers[i]);
        SeaEcoLayout::Tick();
        PlanCapacityExpansion(side);
        bool capacityGuardConsidered=false;
        // Preserve claimed pins while their builders approach the reserved site.
        for (uint i=0; i<SeaEconomy::owned.length(); ++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]); if (u is null) continue;
            ResourcePriority(u);
            IBuilderTask@ t=cast<IBuilderTask>(u.task);
            ObserveSiteProgress(u,t);
            if (u.task !is t) continue;
            // Native dormant chain links are deleted without a removed hook.
            // Inspect live unit ownership instead of retaining those pointers.
            if (t !is null && t.buildDef !is null && t.target is null && !SeaEconomy::OwnsTask(t)) {
                if (ControlledEconomy(t.buildDef) || UnitHelpers::IsSeaplanePlatform(t.buildDef.GetName()) || (SeaLayout::hadFactory && SeaEconomy::Yard(t.buildDef))) {
                    u.CmdStop(); aiBuilderMgr.AbortTask(t); continue;
                }
            }
            if (t is null || t.GetBuildType()!=int(Task::BuildType::GUARD) || UnitHelpers::IsCommander(u.circuitDef)) continue;
            CCircuitUnit@ target=ai.GetTeamUnit(t.GetGuardTargetId());
            IBuilderTask@ targetWork=target is null ? null : cast<IBuilderTask>(target.task);
            const bool productive=target !is null && !Lifecycle::IsRetiring(target)
                && (target.GetBuildProgress()<1 || SeaEconomy::Busy(target.id)
                    || (targetWork !is null && !targetWork.IsDead() && targetWork.target !is null
                        && targetWork.target.GetBuildProgress()<1));
            // A productive factory guard need not go idle to invest a full
            // bank. Consider one eligible T1 assistant during the EXISTING
            // census, and transfer only after real funded work was enqueued.
            // Frames, commander, expansion, recovery and external orders keep
            // ownership. No stop/reassign loop or additional owned-unit scan.
            if (!capacityGuardConsidered && SeaEconomy::capacityPressure && target !is null
                && target.GetBuildProgress()>=1 && SeaEconomy::SupportedFactory(target.circuitDef)
                && SeaConstructor::IsT1(u.circuitDef) && u.id!=SeaEconomy::mexWorker
                && !SeaExpansion::Worker(u) && !t.IsExternalControlled() && !t.IsEnemyReclaim()) {
                capacityGuardConsidered=true;
                IUnitTask@ capacityWork=Support(u);
                if (capacityWork is null) @capacityWork=CapacityFactory(u);
                if (capacityWork !is null) {
                    aiBuilderMgr.AssignTask(u,capacityWork);
                    GenericHelpers::LogUtil("[SEA][Capacity] factory assistant reassigned worker="+u.id,1);
                    continue;
                }
            }
            if (!productive) { aiBuilderMgr.AssignTask(u,Wait()); u.CmdStop(); }
        }
        LayoutHelpers::CheckAlliedPlacements();
    }
    void ResourcePriority(CCircuitUnit@ u) {
        if (u.circuitDef.GetBuildSpeed()<=0 || SeaEconomy::SupportedFactory(u.circuitDef)) return;
        IUnitTask@ task=u.task;
        int overridePriority=-1;
        if (task !is null && !task.IsExternalControlled() && !task.IsEnemyReclaim()
            && task.GetType()!=int(Task::Type::PLAYER) && task.GetType()!=int(Task::Type::RETREAT)) {
            IBuilderTask@ work=cast<IBuilderTask>(task);
            if (work !is null) {
                const int kind=work.GetBuildType();
                if (kind==int(Task::BuildType::ENERGY) || kind==int(Task::BuildType::MEX)
                    || kind==int(Task::BuildType::MEXUP) || kind==int(Task::BuildType::NANO)
                    || kind==int(Task::BuildType::CONVERT)) overridePriority=1;
                if ((UnitHelpers::IsCommander(u.circuitDef) || !u.circuitDef.IsMobile())
                    && (kind==int(Task::BuildType::GUARD) || kind==int(Task::BuildType::REPAIR))) {
                    const int yard=kind==int(Task::BuildType::GUARD) ? work.GetGuardTargetId()
                        : work.target is null ? -1 : work.target.GetProducerId();
                    CCircuitDef@ product=SeaEconomy::Product(yard);
                    int urgent=-1;
                    const bool emergency=SeaFactories::urgentProducts.get(""+yard,urgent) && product !is null && int(product.id)==urgent;
                    overridePriority=SeaMath::AssistPriority(product is null,product !is null && product.GetBuildSpeed()>0,emergency);
                }
            }
        }
        // One pass over the existing census. Native suppresses identical
        // effective priorities even when an old task re-evaluates between ticks.
        u.SetBuildPriorityOverride(overridePriority);
    }
    SeaLayout::Berth@ Planned(const string &in name) {
        for (uint i=0;i<SeaLayout::berths.length();++i)
            if (!SeaLayout::berths[i].retired && SeaLayout::berths[i].name==name) return SeaLayout::berths[i];
        return null;
    }
    void Preplan(const string &in side,bool planAir) {
        if (!SeaLayout::hadFactory) return;
        SeaLayout::Berth@ t2=Planned(UnitHelpers::GetT2ShipyardForSide(side));
        if (t2 is null) {
            AIFloat3 home=SeaEcoLayout::Harbor(); if (home.x<0) home=Global::Map::StartPos;
            @t2=SeaLayout::Add(UnitHelpers::GetT2ShipyardForSide(side),LayoutHelpers::Offset(home,SeaLayout::facing,0,Global::RoleSettings::Sea::FirstPlannedHarborAdvance));
        }
        if (t2.slot<0) return;
        // Separate assist discs, preserving a ship-sized cross passage between
        // clusters. Terrain search may move them; native allied corridors veto
        // candidate footprints. Preplanning does not bypass purchase gates.
        if (planAir && Planned(UnitHelpers::GetSeaplanePlatformNameForSide(side)) is null)
            SeaLayout::Add(UnitHelpers::GetSeaplanePlatformNameForSide(side),LayoutHelpers::Offset(t2.centre,SeaLayout::facing,960,0));
        if (SeaInvasion::gantrySlot<0 && Planned(SeaInvasion::Gantry(side)) is null)
            SeaLayout::Add(SeaInvasion::Gantry(side),LayoutHelpers::Offset(t2.centre,SeaLayout::facing,-960,0));
    }
    bool FreeSupport(CCircuitUnit@ yard) {
        for (uint i=0;i<SeaLayout::patches.length();++i) {
            SeaLayout::Patch@ patch=SeaLayout::patches[i];
            CCircuitDef@ d=ai.GetCircuitDef(patch.name);
            if (d is null || d.GetBuildSpeed()<=0) continue;
            for (uint j=0;j<patch.slots.length();++j) {
                const int slot=patch.slots[j], state=aiTerrainMgr.GetReservationState(slot);
                if (state>=0 && state<=2 && (state!=0 || aiTerrainMgr.IsReservationBuildable(slot))
                    && MapHelpers::SqDist(aiTerrainMgr.GetReservationPos(slot),yard.GetPos(ai.frame))<=d.GetBuildDistance()*d.GetBuildDistance()) return true;
            }
        }
        return false;
    }
    void PlanCapacityExpansion(const string &in side) {
        if (!SeaEconomy::capacityPressure || int(SeaEconomy::productionFactories.length())>=Global::RoleSettings::Sea::MaxProductionYards) return;
        CCircuitUnit@ last=null;
        for (uint i=0;i<SeaEconomy::productionFactories.length();++i) {
            CCircuitUnit@ yard=ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
            if (yard is null || !SeaEconomy::Yard(yard.circuitDef)) continue;
            if (FreeSupport(yard)) return;
            if (last is null || SeaLayout::Along(yard.GetPos(ai.frame))>SeaLayout::Along(last.GetPos(ai.frame))) @last=yard;
        }
        if (last is null) return;
        const string name=UnitHelpers::GetT2ShipyardForSide(side);
        for (uint i=0;i<SeaLayout::berths.length();++i)
            if (SeaLayout::berths[i].name==name && !SeaLayout::berths[i].retired && !SeaLayout::berths[i].active) return;
        SeaLayout::Add(name,LayoutHelpers::Offset(last.GetPos(ai.frame),SeaLayout::facing,960,Global::RoleSettings::Sea::ForwardStep));
        GenericHelpers::LogUtil("[SEA][Capacity] all support occupied; preplan next forward yard",1);
    }
    IUnitTask@ CapacityFactory(CCircuitUnit@ u) {
        if (!Global::RoleSettings::Sea::OverflowFactories || !SeaEconomy::capacityPressure
            || !u.circuitDef.IsMobile() || u.id==SeaEconomy::mexWorker
            || int(SeaEconomy::productionFactories.length())>=Global::RoleSettings::Sea::MaxProductionYards) return null;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        // Pending capacity is already spending the bank; do not create one
        // factory per idle worker. Count live work, not just completed yards.
        for (uint project=0;project<SeaEconomy::projects.length();++project) {
            IBuilderTask@ work=cast<IBuilderTask>(SeaEconomy::projects[project]);
            if (work !is null && !work.IsDead() && (work.GetBuildType()==int(Task::BuildType::FACTORY)
                || work.GetBuildType()==int(Task::BuildType::NANO))) return null;
        }
        CCircuitDef@ nano=ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(side));
        for (uint i=0;i<SeaEconomy::productionFactories.length();++i) {
            CCircuitUnit@ yard=ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
            // An unreachable/blocked reserved pad is not available capacity.
            // Prefer turrets if this worker can actually add them; a T2 worker
            // without that build option can still unlock another funded yard.
            if (yard !is null && nano !is null && u.circuitDef.CanBuild(nano)
                && SeaEconomy::LocalPower(yard)<yard.circuitDef.GetBuildSpeed()+float(Global::RoleSettings::Sea::MaxSupportPerBerth)*nano.GetBuildSpeed()
                && AvailableSupportSlot(u,nano,yard)>=0) return null;
        }
        // Five finite alternatives, on free-builder decisions only. The
        // gantry is admitted only with its entire cost PLUS the configured
        // bank reserve. Failed placements continue to another usable type.
        const array<string> candidates={SeaInvasion::Gantry(side),UnitHelpers::GetSeaplanePlatformNameForSide(side),
            UnitHelpers::GetT2ShipyardForSide(side),SeaInvasion::Lab(side),UnitHelpers::GetT1ShipyardForSide(side)};
        for (uint index=0;index<candidates.length();++index) {
            CCircuitDef@ definition=ai.GetCircuitDef(candidates[index]);
            if (definition is null || !u.circuitDef.CanBuild(definition) || !definition.IsAvailable(ai.frame)
                || !SeaFactories::FactoryAllowed(definition,true)) continue;
            const float reserve=index==0 ? Global::RoleSettings::Sea::OverflowGantryMetalReserve : 0.0f;
            if (aiEconomyMgr.metal.current<definition.costM+reserve
                || !SeaEconomy::Fund(definition,u.circuitDef.GetBuildSpeed(),0,0,reserve,0,0,0,0,
                    Global::RoleSettings::Sea::CapacityUsesConversionEnergy)) continue;
            IUnitTask@ task=SeaLayout::Factory(u,definition.GetName(),-1,AIFloat3(-1,0,-1),true);
            if (task is null) continue;
            SeaEconomy::Admit(definition,false,true);
            GenericHelpers::LogUtil("[SEA][Capacity] overflow factory="+definition.GetName()+" builder="+u.id,1);
            return task;
        }
        return null;
    }
    IUnitTask@ Place(CCircuitUnit@ u, const string &in name, Task::BuildType kind, int size=6) {
        placeNoSite=false;
        CCircuitDef@ d=ai.GetCircuitDef(name);
        if (d is null || SeaEconomy::Pending(d)>=2) return null;
        // All new converter paths, including a native/legacy fallback, use
        // the same live budget. Existing frames/owned tasks return before
        // Place and are never cancelled merely because spending changed.
        if (kind==Task::BuildType::CONVERT) {
            if (!SeaEconomy::NeedsConverter(d)) return null;
            if (!SeaEconomy::Fund(d,u.circuitDef.GetBuildSpeed())) { SeaEconomy::ConversionRefused("unfunded"); return null; }
        }
        if (SeaEcoLayout::Managed(d)) {
            IUnitTask@ packed=SeaEcoLayout::Place(u,d,kind);
            placeNoSite=packed is null;
            IBuilderTask@ order=cast<IBuilderTask>(packed);
            if (order !is null && order.buildDef is d) SeaEconomy::Admit(d,false,true);
            return packed;
        }
        AIFloat3 anchor=LayoutHelpers::Offset(Global::Map::StartPos,SeaLayout::facing,0,-Global::RoleSettings::Sea::RearEconomyDistance);
        const AIFloat3 harbor=SeaEcoLayout::Harbor();
        if (harbor.x>=0) anchor=LayoutHelpers::Offset(harbor,SeaEcoLayout::direction,0,-Global::RoleSettings::Sea::RearEconomyDistance);
        // A coastal commander can start far inland. Anchor naval economy to
        // the first usable harbor so construction ships can reach its modules.
        for (uint i=0; i<SeaLayout::berths.length(); ++i) {
            SeaLayout::Berth@ b=SeaLayout::berths[i];
            if (b.slot>=0 && !b.retired) { anchor=LayoutHelpers::Offset(b.centre,b.facing,0,-Global::RoleSettings::Sea::RearEconomyDistance); break; }
        }
        IUnitTask@ t=SeaLayout::Place(u,d,kind,anchor,size);
        placeNoSite=t is null;
        if (t !is null) SeaEconomy::Admit(d,false,true);
        return t;
    }
    IUnitTask@ Upgrade(CCircuitUnit@ u) {
        if (!SeaConstructor::IsT2(u.circuitDef)) return null;
        if (aiEconomyMgr.IsMetalMap()) return aiEconomyMgr.EnqueueFieldUpgrade(u,Global::Map::StartPos,2000.0f);
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        CCircuitDef@ d=ai.GetCircuitDef(side=="armada" ? "armuwmme" : side=="cortex" ? "coruwmme" : "leganavalmex");
        if (d is null || !d.IsAvailable(ai.frame) || !u.circuitDef.CanBuild(d)) return null;
        AIFloat3 p(-1,0,-1); float distance=2400.0f*2400.0f;
        for (uint i=0; i<SeaEconomy::owned.length(); ++i) {
            CCircuitUnit@ mex=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (mex is null || mex.GetBuildProgress()<1 || mex.circuitDef.GetExtractsMetal()<=0
                || mex.circuitDef.GetExtractsMetal()>=d.GetExtractsMetal()) continue;
            const AIFloat3 at=mex.GetPos(ai.frame);
            const float sq=MapHelpers::SqDist(at,u.GetPos(ai.frame));
            if (sq>=distance || Economy::MexTracker::AnyUpgradeInProgressNear(at,96.0f)
                || !aiTerrainMgr.CanUpgradeTerrain(d,at) || !aiTerrainMgr.CanReachAt(u,at,u.circuitDef.GetBuildDistance())) continue;
            distance=sq; p=at;
        }
        if (p.x<0) return null;
        return aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP,Task::Priority::HIGH,d,p,-1));
    }
    IUnitTask@ Support(CCircuitUnit@ u) {
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        CCircuitDef@ nano=ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(side));
        if (nano is null || !u.circuitDef.CanBuild(nano) || !nano.IsAvailable(ai.frame)) return null;
        // A travelling/unfinished pad counts against the shared bound, but
        // must not serialize every independent harbor behind one slow ship.
        // O(projects + factories * pending pads); pending pads are bounded by
        // SupportParallelProjects. Native pins and Fund close same-frame races.
        array<AIFloat3> pendingSupport;
        for (uint i=0;i<SeaEconomy::projects.length();++i) {
            IBuilderTask@ t=cast<IBuilderTask>(SeaEconomy::projects[i]);
            if (t !is null && !t.IsDead() && t.GetBuildType()==int(Task::BuildType::NANO)) pendingSupport.insertLast(t.GetBuildPos());
        }
        if (!SeaMath::SupportProjectAvailable(int(pendingSupport.length()),Global::RoleSettings::Sea::SupportParallelProjects,false)) return null;
        CCircuitUnit@ selected=null;
        float bestFill=1.0f, selectedLocal=0, selectedTarget=0;
        for (uint i=0; i<SeaEconomy::productionFactories.length(); ++i) {
            CCircuitUnit@ yard=ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
            if (yard is null || yard.GetBuildProgress()<1 || SeaFactories::Hold(yard)) continue;
            bool pendingAtYard=false;
            for (uint project=0;project<pendingSupport.length();++project)
                if (MapHelpers::SqDist(pendingSupport[project],yard.GetPos(ai.frame))<=nano.GetBuildDistance()*nano.GetBuildDistance()) { pendingAtYard=true; break; }
            if (pendingAtYard) continue;
            int64 retry=0;
            if (supportRetry.get(""+yard.id,retry) && ai.frame<retry) continue;
            CCircuitDef@ product=SeaEconomy::Product(yard.id);
            if (product is null || product.GetBuildTime()<=0) continue;
            const float local=SeaEconomy::LocalPower(yard);
            float target=SeaEconomy::SupportTarget(yard,product);
            if (SeaEconomy::capacityPressure) target=AiMax(target,local+nano.GetBuildSpeed());
            if (UnitHelpers::IsT2Shipyard(yard.circuitDef.GetName()) && CompletedSupport(yard)<Global::RoleSettings::Sea::CommanderHandoffTurrets)
                target=AiMax(target,local+nano.GetBuildSpeed()); // mobile assist cannot substitute for four turrets
            if (!SeaMath::SupportNeeded(target,local,yard.circuitDef.GetBuildSpeed(),nano.GetBuildSpeed(),
                Global::RoleSettings::Sea::MaxSupportPerBerth)) continue;
            const float fill=local/target;
            if (fill<bestFill) { @selected=yard; bestFill=fill; selectedLocal=local; selectedTarget=target; }
        }
        if (selected !is null) {
            CCircuitDef@ product=SeaEconomy::Product(selected.id);
            // Sustained gifted-bank pressure can fund one complete turret
            // even at a nominal deficit. Shorten only metal's observation
            // horizon; reserve the full unpaid cost and keep the normal energy
            // horizon. No predicted future donation enters either balance.
            const float horizon=SeaEconomy::capacityPressure && aiEconomyMgr.metal.income<TeamEconomy::OwnMetal(TeamEconomy::USAGE)
                ? float(Global::RoleSettings::Sea::CapacityObservationSeconds) : Global::RoleSettings::Sea::WorkforceHorizon;
            if (!SeaEconomy::Fund(nano,u.circuitDef.GetBuildSpeed(),nano.GetBuildSpeed()*product.costM/product.GetBuildTime(),
                nano.GetBuildSpeed()*product.costE/product.GetBuildTime(),0,0,horizon,0,0,
                Global::RoleSettings::Sea::CapacityUsesConversionEnergy)) return null;
            // Serve only preplanned pads. The generic six-pad fallback could
            // strand turrets or keep searching an already saturated harbor.
            IUnitTask@ t=SupportSlot(u,nano,selected);
            if (t !is null) {
                SeaEconomy::Admit(nano,true,true);
                IBuilderTask@ build=cast<IBuilderTask>(t);
                if (build is null || MapHelpers::SqDist(build.GetBuildPos(),selected.GetPos(ai.frame))>nano.GetBuildDistance()*nano.GetBuildDistance())
                    Invariants::Violation("INV-135",""+selected.id,"SEA support order cannot reach its production factory");
                GenericHelpers::LogUtil("[SEA][Support] factory="+selected.id+" name="+selected.circuitDef.GetName()
                    +" product="+product.GetName()+" local="+selectedLocal+" target="+selectedTarget,1);
                return t;
            }
            supportRetry.set(""+selected.id,int64(ai.frame+5*SECOND)); // blocked placement must not starve other factories
        }
        return null;
    }
    int CompletedSupport(CCircuitUnit@ yard) {
        int count=0;
        for (uint i=0;i<SeaEconomy::owned.length();++i) {
            CCircuitUnit@ nano=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (nano is null || nano.GetBuildProgress()<1 || nano.circuitDef.IsMobile()
                || SeaEconomy::SupportedFactory(nano.circuitDef) || nano.circuitDef.GetBuildSpeed()<=0
                || Lifecycle::IsRetiring(nano)) continue;
            const float reach=nano.circuitDef.GetBuildDistance();
            if (MapHelpers::SqDist(nano.GetPos(ai.frame),yard.GetPos(ai.frame))<=reach*reach) ++count;
        }
        return count;
    }
    int AvailableSupportSlot(CCircuitUnit@ u,CCircuitDef@ nano,CCircuitUnit@ yard) {
        for (uint p=0;p<SeaLayout::patches.length();++p) {
            SeaLayout::Patch@ patch=SeaLayout::patches[p]; if (patch.name!=nano.GetName()) continue;
            for (uint s=0;s<patch.slots.length();++s) {
                const int slot=patch.slots[s];
                if (aiTerrainMgr.GetReservationState(slot)!=0) continue;
                const AIFloat3 at=aiTerrainMgr.GetReservationPos(slot);
                if (MapHelpers::SqDist(at,yard.GetPos(ai.frame))>nano.GetBuildDistance()*nano.GetBuildDistance()
                    || !aiTerrainMgr.IsReservationBuildable(slot) || !aiTerrainMgr.CanReachAt(u,at,u.circuitDef.GetBuildDistance())) continue;
                return slot;
            }
        }
        return -1;
    }
    IUnitTask@ SupportSlot(CCircuitUnit@ u,CCircuitDef@ nano,CCircuitUnit@ yard) {
        const int slot=AvailableSupportSlot(u,nano,yard);
        if (slot<0) return null;
        IUnitTask@ task=SeaLayout::Pinned(nano,slot,Task::BuildType::NANO,Task::Priority::HIGH);
        if (task !is null) for (uint index=0;index<SeaLayout::patches.length();++index) {
            SeaLayout::Patch@ patch=SeaLayout::patches[index];
            if (patch.slots.find(slot)<0) continue;
            patch.active=true; SeaLayout::SavePatch(index); break;
        }
        return task;
    }
    IUnitTask@ Commander(CCircuitUnit@ u) {
        if (!SeaLayout::Enabled() || u is null || !UnitHelpers::IsCommander(u.circuitDef)) return null;
        if (u.task !is null && (u.task.IsEnemyReclaim() || u.task.GetType()==int(Task::Type::PLAYER)
            || u.task.GetType()==int(Task::Type::RETREAT))) return u.task;
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) return current;
        SeaEconomy::Tick();
        CCircuitUnit@ yard=null; CCircuitUnit@ idleYard=null; float distance=1.0e20f, idleDistance=1.0e20f; bool handoff=false; int handoffYard=-1;
        for (uint i=0;i<SeaEconomy::owned.length();++i) {
            CCircuitUnit@ candidate=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (candidate is null || !SeaEconomy::Yard(candidate.circuitDef) || Lifecycle::IsRetiring(candidate)) continue;
            const bool t2=UnitHelpers::IsT2Shipyard(candidate.circuitDef.GetName());
            const int turrets=t2 && candidate.GetBuildProgress()>=1 ? CompletedSupport(candidate) : 0;
            handoff=handoff || SeaMath::CommanderHandoff(t2 && candidate.GetBuildProgress()>=1,turrets,Global::RoleSettings::Sea::CommanderHandoffTurrets);
            if (SeaMath::CommanderHandoff(t2 && candidate.GetBuildProgress()>=1,turrets,Global::RoleSettings::Sea::CommanderHandoffTurrets)) handoffYard=candidate.id;
            const float sq=MapHelpers::SqDist(candidate.GetPos(ai.frame),u.GetPos(ai.frame));
            if (sq<idleDistance) { @idleYard=candidate; idleDistance=sq; }
            if ((SeaEconomy::Busy(candidate.id) || candidate.GetBuildProgress()<1) && sq<distance) { @yard=candidate; distance=sq; }
        }
        if (handoff) {
            CCircuitUnit@ target=null; float best=-1;
            const bool energyLow=aiEconomyMgr.energy.current<aiEconomyMgr.energy.storage*.3f;
            for (uint i=0;i<SeaEconomy::projects.length();++i) {
                IBuilderTask@ project=cast<IBuilderTask>(SeaEconomy::projects[i]);
                if (project is null || project.IsDead() || project.target is null || project.target.GetBuildProgress()>=1) continue;
                const int kind=project.GetBuildType();
                const float priority=kind==int(Task::BuildType::ENERGY) ? (energyLow ? 100.0f : 70.0f)
                    : kind==int(Task::BuildType::MEXUP) || kind==int(Task::BuildType::MEX) ? 90.0f
                    : kind==int(Task::BuildType::NANO) ? 80.0f : kind==int(Task::BuildType::CONVERT) ? 40.0f : 0.0f;
                const float sq=MapHelpers::SqDist(project.target.GetPos(ai.frame),u.GetPos(ai.frame));
                if (priority<=0 || sq>Global::RoleSettings::Sea::CapitalAssistRadius*Global::RoleSettings::Sea::CapitalAssistRadius) continue;
                const float score=priority-sqrt(sq)/1000.0f;
                if (score>best && aiTerrainMgr.CanReachAt(u,project.target.GetPos(ai.frame),u.circuitDef.GetBuildDistance())) { best=score; @target=project.target; }
            }
            if (target !is null) {
                CCircuitUnit@ verified=ai.GetTeamUnit(handoffYard);
                if (verified is null || !SeaMath::CommanderHandoff(verified.GetBuildProgress()>=1,CompletedSupport(verified),Global::RoleSettings::Sea::CommanderHandoffTurrets)) {
                    Invariants::Violation("INV-162",""+u.id,"SEA commander economy handoff without completed T2 and four usable turrets"); return null;
                }
                if (current !is null && !current.IsDead() && current.target is target) return current;
                GenericHelpers::LogUtil("[SEA][Commander] handoff eco="+target.id+" requiredTurrets="+Global::RoleSettings::Sea::CommanderHandoffTurrets,1);
                return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH,target,10*SECOND));
            }
        }
        if (yard !is null) {
            if (current !is null && !current.IsDead() && current.GetGuardTargetId()==yard.id) return current;
            GenericHelpers::LogUtil("[SEA][Commander] assist yard="+yard.id+" handoff="+handoff,1);
            return GuardHelpers::AssignWorkerGuard(u,yard,Task::Priority::HIGH,false,Global::RoleSettings::Sea::CommanderFactoryAssistGuardTimeoutSeconds*SECOND);
        }
        if (!handoff && idleYard !is null && (SeaEconomy::mobilePower>0 || aiEconomyMgr.energy.current>aiEconomyMgr.energy.storage*.2f))
            return Wait(); // a product gap is not permission to walk away
        // No productive yard/workforce/energy: native emergency recovery can
        // restart production rather than keeping a permanently idle guard.
        return null;
    }
    IUnitTask@ Assist(CCircuitUnit@ u) {
        CCircuitUnit@ reclaim=aiBuilderMgr.FindReclaimTargetFor(u);
        if (reclaim !is null) return aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH,reclaim,30*SECOND));
        const float radius=u.circuitDef.IsMobile() ? 800.0f : u.circuitDef.GetBuildDistance();
        CCircuitUnit@ target=aiBuilderMgr.FindUnfinishedNear(u.GetPos(ai.frame),radius,null);
        if (target !is null && !Lifecycle::IsRetiring(target)
            && aiTerrainMgr.CanReachAt(u,target.GetPos(ai.frame),u.circuitDef.GetBuildDistance()))
            return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL,target,30*SECOND));
        for (uint i=0; i<SeaEconomy::productionFactories.length(); ++i) {
            CCircuitUnit@ yard=ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
            if (yard is null || SeaFactories::Hold(yard) || !SeaEconomy::Busy(yard.id)) continue;
            const float reach=u.circuitDef.GetBuildDistance();
            if (MapHelpers::SqDist(yard.GetPos(ai.frame),u.GetPos(ai.frame))>reach*reach) continue;
            return GuardHelpers::AssignWorkerGuard(u,yard,Task::Priority::LOW,true,10*SECOND);
        }
        return null;
    }
    IUnitTask@ CapitalAssist(CCircuitUnit@ u) {
        if (!SeaConstructor::IsT1(u.circuitDef) && !UnitHelpers::IsCommander(u.circuitDef)) return null;
        // Finish a funded tech investment with nearby existing power. T2
        // constructors retain mex-upgrade ownership, and the expansion ship
        // stays available to take metal. No extra workforce is purchased here.
        if (u.id==SeaEconomy::mexWorker || aiEconomyMgr.metal.current<aiEconomyMgr.metal.storage*.35f
            || aiEconomyMgr.energy.current<aiEconomyMgr.energy.storage*.35f) return null;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        const string fusion=UnitHelpers::GetNavalFusionNameForSide(side);
        CCircuitUnit@ target=null; float distance=Global::RoleSettings::Sea::CapitalAssistRadius*Global::RoleSettings::Sea::CapitalAssistRadius;
        for (uint i=0;i<SeaEconomy::owned.length();++i) {
            CCircuitUnit@ candidate=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (candidate is null || candidate.GetBuildProgress()>=1 || Lifecycle::IsRetiring(candidate)
                || (!UnitHelpers::IsT2Shipyard(candidate.circuitDef.GetName()) && candidate.circuitDef.GetName()!=fusion)) continue;
            const float sq=MapHelpers::SqDist(u.GetPos(ai.frame),candidate.GetPos(ai.frame));
            if (sq<distance && aiTerrainMgr.CanReachAt(u,candidate.GetPos(ai.frame),u.circuitDef.GetBuildDistance())) { @target=candidate; distance=sq; }
        }
        if (target is null) return null;
        int assigned=0;
        for (uint i=0;i<SeaEconomy::owned.length();++i) {
            CCircuitUnit@ worker=ai.GetTeamUnit(SeaEconomy::owned[i]); if (worker is null) continue;
            IBuilderTask@ task=cast<IBuilderTask>(worker.task);
            if (task !is null && task.target is target) {
                if (worker is u) return task;
                ++assigned;
            }
        }
        if (assigned>=Global::RoleSettings::Sea::CapitalAssistWorkers) return null;
        const float power=u.circuitDef.GetBuildSpeed(), horizon=Global::RoleSettings::Sea::WorkforceHorizon;
        const float m=BuildPowerMath::Room(aiEconomyMgr.metal.current,0,aiEconomyMgr.metal.income,TeamEconomy::OwnMetal(TeamEconomy::USAGE),0,horizon);
        const float e=BuildPowerMath::Room(aiEconomyMgr.energy.current,0,aiEconomyMgr.energy.income,TeamEconomy::OwnEnergy(TeamEconomy::USAGE),0,horizon);
        if (m<power*target.circuitDef.costM/target.circuitDef.GetBuildTime()
            || e<power*target.circuitDef.costE/target.circuitDef.GetBuildTime()) return null;
        return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH,target,60*SECOND));
    }
    IUnitTask@ NativeTask(CCircuitUnit@ u) {
        // Reuse native path-cost expansion, reclaim, geo, storage, defence and
        // auxiliary factories. Only controlled structures are re-planned here.
        aiBuilderMgr.experimentalBuild=false;
        IUnitTask@ task=aiBuilderMgr.DefaultMakeTask(u);
        aiBuilderMgr.experimentalBuild=true;
        if (RejectSite(u,task)) return null;
        IBuilderTask@ build=cast<IBuilderTask>(task);
        if (build is null || build.buildDef is null || build.target !is null || SeaEconomy::OwnsTask(task)) return task;
        const Task::BuildType kind=PlacementKind(build.buildDef,build.GetBuildType());
        CCircuitDef@ def=build.buildDef;
        const bool controlled=kind==Task::BuildType::ENERGY || kind==Task::BuildType::CONVERT || kind==Task::BuildType::NANO
            || (kind==Task::BuildType::FACTORY && (SeaEconomy::Yard(def) || UnitHelpers::IsSeaplanePlatform(def.GetName()) || !SeaFactories::FactoryAllowed(def)));
        if (!controlled) return task;
        // Never abandon another worker's order. Native queued work is adopted
        // only when this call is its sole prospective assignee.
        if (build.GetUnits().length()>0) return task;
        aiBuilderMgr.AbortTask(task);
        if (kind==Task::BuildType::FACTORY) {
            if (SeaInvasion::Active() && SeaInvasion::Factory(def)) return SeaInvasion::Build(u);
            if (UnitHelpers::IsT2Shipyard(def.GetName()) && !SeaEconomy::TechReady(def)) return null;
            return SeaLayout::Factory(u,def.GetName());
        }
        if (kind==Task::BuildType::NANO) return Support(u);
        if (kind==Task::BuildType::CONVERT && aiEconomyMgr.IsMetalMap()) return null;
        return Place(u,def.GetName(),kind,6);
    }
    IUnitTask@ Resume(CCircuitUnit@ u) {
        const int job=SeaExpansion::Job(u);
        // Recover an admitted factory before admitting more repeatable economy.
        // Native only offers unassigned reachable work; current productive tasks
        // are preserved by the caller. This does not forcibly re-staff a frame.
        array<int> kinds={int(Task::BuildType::FACTORY),int(Task::BuildType::ENERGY),int(Task::BuildType::NANO),int(Task::BuildType::CONVERT)};
        if (job==2) { kinds[1]=int(Task::BuildType::CONVERT); kinds[3]=int(Task::BuildType::ENERGY); }
        for (uint i=0; i<kinds.length(); ++i) {
            IUnitTask@ task=aiBuilderMgr.FindQueuedTask(u,kinds[i]);
            if (task is null) continue;
            IBuilderTask@ build=cast<IBuilderTask>(task);
            if (!SeaEconomy::OwnsTask(task)) {
                if (build !is null && build.target is null && build.buildDef !is null
                    && UnitHelpers::IsT2Shipyard(build.buildDef.GetName())) {
                    // Native fallback can leave an unassigned yard outside our
                    // ledger, permanently blocking TechYard's duplicate guard.
                    // FindQueuedTask proved it unassigned/reachable. Re-admit
                    // through the common lease, completed-support and funding
                    // path; never take over a frame or another worker's task.
                    const string name=build.buildDef.GetName();
                    aiBuilderMgr.AbortTask(task);
                    if (ai.frame-techQueueLog>=30*SECOND) {
                        techQueueLog=ai.frame;
                        GenericHelpers::LogUtil("[SEA][TechSave] reconcile native queued "+name,1);
                    }
                    if (SeaEconomy::TechCommitted()) {
                        @task=SeaLayout::Factory(u,name); if (task !is null) return task;
                    }
                }
                continue;
            }
            if (build !is null && build.buildDef !is null && UnitHelpers::IsT2Shipyard(build.buildDef.GetName())) {
                // Framed work retains CapitalAssist/D-301's funding and recovery
                // policy; only unstarted orders belong to this queue recovery.
                if (build.target !is null || !SeaTech::Permit(aiBattle.WaterBody(build.GetBuildPos(),false),1)) continue;
            }
            return task;
        }
        return null;
    }
    IUnitTask@ HomeEnergy(CCircuitUnit@ u) {
        if (!SeaConstructor::IsT1(u.circuitDef) || (SeaExpansion::Worker(u) && !SeaExpansion::blocked.exists(""+u.id))) return null;
        // With the commander on production, the second ship must grow home
        // energy itself. Following the mex ship leaves both ships offshore
        // and allows factory assistance to consume the entire opening economy.
        const float target=SeaEconomy::HomeEnergyTarget();
        if (aiEconomyMgr.energy.income+SeaEconomy::FundedEnergySoon(30.0f)>=target) return null;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        return Place(u,UnitHelpers::GetTidalNameForSide(side),Task::BuildType::ENERGY);
    }
    IUnitTask@ ConversionWork(CCircuitUnit@ u) {
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        CCircuitDef@ d=ai.GetCircuitDef(SeaConstructor::IsT2(u.circuitDef)
            ? UnitHelpers::GetAdvNavalEnergyConverterNameForSide(side) : UnitHelpers::GetNavalEnergyConverterNameForSide(side));
        if (d is null || !u.circuitDef.CanBuild(d) || !SeaEconomy::NeedsConverter(d)) return null;
        IUnitTask@ task=Place(u,d.GetName(),Task::BuildType::CONVERT);
        if (task is null) SeaEconomy::ConversionRefused("no-reachable-slot-or-native-rejection");
        return task;
    }
    IUnitTask@ GroupWork(CCircuitUnit@ u) {
        const int job=SeaExpansion::Job(u);
        if (job<0) return null;
        // Useful conversion gets a dedicated ask before optional support/T2.
        // Preserve productive frames in the caller; no repeated guard orders.
        IUnitTask@ task=null;
        if (job==2) { @task=ConversionWork(u); if (task !is null) return task; }
        if (job==1 || job==2) {
            if (SeaEconomy::TechSaving()) {
                @task=TechYard(u); if (task !is null) return task;
                if (techFundingWait && aiEconomyMgr.energy.income>=Global::RoleSettings::Sea::TechMinimumEnergyIncome) return Wait();
            }
            @task=HomeEnergy(u); if (task !is null) return task;
        }
        return null;
    }
    // Shared only by SEA's compact and experimental builders. Keep the old
    // helper ladder unchanged for TACTICAL and explicit layout opt-outs.
    IUnitTask@ EconomyGrowth(CCircuitUnit@ u) {
        if (!SeaConstructor::IsT1(u.circuitDef) && !SeaConstructor::IsT2(u.circuitDef)) return null;
        IUnitTask@ task=Upgrade(u); if (task !is null) return task;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        CCircuitDef@ yard=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(side));
        if (yard !is null && u.circuitDef.CanBuild(yard) && SeaEconomy::Have(yard)==0 && SeaEconomy::TechReady(yard)) {
            @task=SeaLayout::Factory(u,yard.GetName());
            if (task !is null) return task;
        }
        int pending=0;
        const float gap=SeaEconomy::ConversionGap(pending);
        CCircuitDef@ converter=ai.GetCircuitDef(SeaConstructor::IsT2(u.circuitDef)
            ? UnitHelpers::GetAdvNavalEnergyConverterNameForSide(side) : UnitHelpers::GetNavalEnergyConverterNameForSide(side));
        const float draw=aiEconomyMgr.GetEnergyUse(converter);
        if (converter !is null && u.circuitDef.CanBuild(converter)
            && SeaMath::ConversionReady(aiEconomyMgr.IsMetalMap(),aiEconomyMgr.energy.current,aiEconomyMgr.energy.storage,
                ai.GetTeamRulesParam("mmLevel",.75f),aiEconomyMgr.energy.income,
                Global::RoleSettings::Sea::BuildT1ConvertersMinimumEnergyIncome,gap,draw,pending,
                Global::RoleSettings::Sea::ConverterParallelProjects)) {
            @task=Place(u,converter.GetName(),Task::BuildType::CONVERT);
            if (task !is null) {
                int after=0; SeaEconomy::ConversionCapacity(after);
                if (!SeaEconomy::OwnsTask(task) || after!=pending+1)
                    Invariants::Violation("INV-177",converter.GetName(),"SEA converter admission missing from live capacity ledger");
                GenericHelpers::LogUtil("[SEA][Conversion] build="+converter.GetName()+" gap="+gap+" draw="+draw+" pending="+pending,1);
                return task;
            }
        }
        CCircuitDef@ fusion=ai.GetCircuitDef(UnitHelpers::GetNavalFusionNameForSide(side));
        // One capital-energy project at a time. Convert existing surplus
        // before growing another reactor; bootstrap the first funded reactor
        // even when tidals already satisfy the old energy/metal ratio.
        if (fusion !is null && u.circuitDef.CanBuild(fusion) && SeaEconomy::Pending(fusion)+aiBuilderMgr.GetUnfinishedCount(fusion)==0
            && (fusion.count==0 || gap<draw*.75f) && SeaEconomy::FusionFunded(fusion) && SeaEconomy::HoldingWater()) {
            @task=Place(u,fusion.GetName(),Task::BuildType::ENERGY,2);
            if (task !is null) return task;
        }
        return null;
    }
    // Keep normal SEA decisions, but use one owner for economy placement.
    IUnitTask@ PriorityGrowth(CCircuitUnit@ u) {
        // Both builder modes must give funded production capacity a turn before
        // repeatable converters/tidals. Otherwise one home ship can build those
        // forever without reaching Support. Support bounds live projects per
        // yard and checks both resource budgets; expansion and other
        // home workers remain free to grow energy. Existing work is retained by
        // the caller. This reorders one existing query, adding no periodic scan.
        IUnitTask@ task=GroupWork(u); if (task !is null) return task;
        if (SeaConstructor::IsT1(u.circuitDef) && !SeaExpansion::Worker(u)) {
            @task=Support(u); if (task !is null) return task;
        }
        @task=CapacityFactory(u); if (task !is null) return task;
        @task=EconomyGrowth(u); if (task !is null) return task;
        @task=SeaEcoLayout::Support(u); if (task !is null) return task;
        return HomeEnergy(u);
    }
    // D-300: once the tech save commits, the first idle T1 construction ship
    // orders the first advanced yard where the legacy ladder would (beside the
    // primary T1 yard). One order: a queued yard task blocks a second.
    int techYardLog=-100000;
    // The one live T2 yard order (D-300). Held across frames like the economy
    // project ledger; an assigned order that is not yet a frame is neither
    // "queued" nor counted, so without this handle a second order went out.
    IUnitTask@ techOrder=null;
    bool techFundingWait=false;
    IUnitTask@ PrepareTech(CCircuitUnit@ u,CCircuitDef@ yard,SeaLayout::Berth@ berth,bool &out ready) {
        ready=false; techFundingWait=false;
        if (berth is null || berth.slot<0) return null;
        const int body=aiBattle.WaterBody(berth.centre,false);
        if (!SeaTech::Permit(body,1)) { TechYardRefused("waiting for shared-sea lease"); return null; }
        CCircuitDef@ nano=ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(UnitHelpers::GetSideForUnitName(yard.GetName())));
        if (nano is null) return null;
        ReserveSupport(nano,berth.centre,berth.facing,yard,berth.key);
        const int wanted=SeaMath::TechSupportCount(yard.GetBuildTime(),Global::RoleSettings::Sea::TechYardTargetSeconds,
            u.circuitDef.GetBuildSpeed(),nano.GetBuildSpeed(),Global::RoleSettings::Sea::TechMinimumTurrets);
        int complete=0, pending=0, available=-1;
        for (uint p=0;p<SeaLayout::patches.length();++p) {
            SeaLayout::Patch@ patch=SeaLayout::patches[p];
            if (patch.name!=nano.GetName() || patch.owner!=berth.key) continue;
            for (uint i=0;i<patch.slots.length();++i) {
                const int slot=patch.slots[i];
                const AIFloat3 at=aiTerrainMgr.GetReservationPos(slot);
                if (MapHelpers::SqDist(at,berth.centre)>nano.GetBuildDistance()*nano.GetBuildDistance()) continue;
                CCircuitUnit@ built=aiTerrainMgr.GetReservationUnit(slot);
                if (built !is null && ai.GetTeamUnit(built.id) !is null && built.GetBuildProgress()>=1) ++complete;
                else if (aiTerrainMgr.GetReservationState(slot)>0 && aiTerrainMgr.GetReservationState(slot)<4) ++pending;
                else if (available<0 && aiTerrainMgr.IsReservationBuildable(slot)
                    && aiTerrainMgr.CanReachAt(u,at,u.circuitDef.GetBuildDistance())) available=slot;
            }
        }
        if (complete<wanted) {
            if (complete+pending<wanted && available>=0 && u.circuitDef.CanBuild(nano)
                && SeaEconomy::Fund(nano,u.circuitDef.GetBuildSpeed())) {
                IUnitTask@ task=SeaLayout::Pinned(nano,available,Task::BuildType::NANO,Task::Priority::HIGH);
                if (task !is null) {
                    SeaEconomy::Admit(nano,false,true);
                    for (uint p=0;p<SeaLayout::patches.length();++p) {
                        if (SeaLayout::patches[p].owner==berth.key) {
                            SeaLayout::patches[p].active=true; SeaLayout::SavePatch(p);
                        }
                    }
                    GenericHelpers::LogUtil("[SEA][TechPrepare] turret completed="+complete+" required="+wanted,1);
                }
                return task;
            }
            TechYardRefused("waiting for completed support "+complete+"/"+wanted); return null;
        }
        CCircuitDef@ constructor=ai.GetCircuitDef(SeaEconomy::Constructor(UnitHelpers::GetSideForUnitName(yard.GetName()),true));
        if (constructor is null) return null;
        // Reserve the first advanced constructor and fund at the target build
        // rate. Reclaim receipts are bank, never promised income.
        float queuedM=0,queuedE=0; SeaEconomy::UnframedCosts(queuedM,queuedE);
        const float horizon=AiMax(1.0f,Global::RoleSettings::Sea::TechYardTargetSeconds);
        const float conversion=AiMax(0.0f,ai.GetTeamRulesParam("mmUse",0.0f));
        float redirect=SeaMath::TechConversionRedirect(aiEconomyMgr.energy.current,0,
            queuedE+SeaEconomy::recruitAdmittedE,aiEconomyMgr.energy.income,TeamEconomy::OwnEnergy(TeamEconomy::USAGE),
            yard.costE+constructor.costE,horizon,conversion);
        if (redirect>0) redirect=AiMin(conversion,redirect+1.0f); // rounding margin at the funding boundary
        // Price only the conversion needed by this yard, including its lost
        // metal. Turning ALL conversion off in the forecast deadlocked a full
        // bank in the prepared-T2 fixture despite ample combined resources.
        const float lostMetal=redirect*AiMax(0.0f,ai.GetTeamRulesParam("mmAvgEffi",0.0f));
        const float metalUsage=TeamEconomy::OwnMetal(TeamEconomy::USAGE)+lostMetal;
        const float metalQueued=queuedM+SeaEconomy::recruitAdmittedM;
        // Pay the whole package within the target window. An up-front cash
        // reserve for the constructor's entire energy cost can exceed natural
        // storage capacity, even when income readily funds it after the yard.
        const bool metalFunded=BuildPowerMath::Funded(aiEconomyMgr.metal.current,0,aiEconomyMgr.metal.income,
            metalUsage,metalQueued,yard.costM+constructor.costM,horizon,0,horizon);
        const bool energyFunded=BuildPowerMath::Funded(aiEconomyMgr.energy.current,0,aiEconomyMgr.energy.income,
            SeaMath::GrowthUsage(TeamEconomy::OwnEnergy(TeamEconomy::USAGE),redirect),queuedE+SeaEconomy::recruitAdmittedE,
            yard.costE+constructor.costE,horizon,0,horizon);
        ready=metalFunded && energyFunded;
        if (ready) return null;
        CCircuitUnit@ old=Factory::primaryT1Shipyard;
        CCircuitDef@ oldDef=old is null ? null : ai.GetCircuitDef(old.circuitDef.id);
        const bool metalShort=!metalFunded;
        const bool queueIdle=old !is null && (old.task is null || old.task.GetType()==int(Task::Type::WAIT)
            || old.task.GetType()==int(Task::Type::IDLE));
        // Reclaim cannot repair an energy deficit or an unaffordable package.
        // The predicted refund admits reclaim only; actual receipts still fund
        // the yard via the same package checks on the next ask.
        const bool reclaimFunds=oldDef !is null && energyFunded
            && BuildPowerMath::Funded(aiEconomyMgr.metal.current+oldDef.costM,0,aiEconomyMgr.metal.income,
                metalUsage,metalQueued,yard.costM+constructor.costM,horizon,0,horizon);
        // Conservative coverage proof: another completed owned T1 yard in this
        // body. Allied production alone is not an enforceable availability promise.
        bool coverage=false;
        for (uint i=0;i<SeaEconomy::productionFactories.length();++i) {
            CCircuitUnit@ other=ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
            if (other !is null && other !is old && UnitHelpers::IsT1Shipyard(other.circuitDef.GetName())
                && aiBattle.WaterBody(other.GetPos(ai.frame),false)==body && !SeaFactories::Hold(other)) coverage=true;
        }
        if (Global::RoleSettings::Sea::TechReclaimT1 && metalShort && coverage && reclaimFunds && queueIdle && oldDef !is null
            && !SeaEconomy::Busy(old.id) && !SeaEconomy::SeaContested()
            && SeaEconomy::Number(SeaEconomy::Constructor(Global::AISettings::Side,false),true)>=3
            && aiTerrainMgr.CanReachAt(u,old.GetPos(ai.frame),u.circuitDef.GetBuildDistance())) {
            if (!Lifecycle::IsRetiring(old)) Lifecycle::Retire(old,"SEA prepared T2 funding with alternate yard");
            GenericHelpers::LogUtil("[SEA][TechReclaim] yard="+old.id+" bank="+aiEconomyMgr.metal.current,1);
            return aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH,old,120*SECOND));
        }
        techFundingWait=true;
        TechYardRefused("support ready; package lacks funding"); return null;
    }
    void TechYardRefused(const string &in reason) {
        if (ai.frame-techYardLog<30*SECOND) return;
        techYardLog=ai.frame; GenericHelpers::LogUtil("[SEA][TechSave] order refused: "+reason,1);
    }
    IUnitTask@ TechYard(CCircuitUnit@ u) {
        if (!SeaConstructor::IsT1(u.circuitDef) || !SeaEconomy::TechCommitted()) return null;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        CCircuitDef@ yard=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(side));
        if (yard is null || !u.circuitDef.CanBuild(yard)) { TechYardRefused("builder cannot build it"); return null; }
        // Never join or re-return a live order here: assignment re-enters
        // role policy synchronously, and a refused assignment recursed until
        // the engine crashed (played, Legion). Other ships assist the frame
        // through CapitalAssist and native assist.
        if (techOrder !is null && !techOrder.IsDead()) {
            techFundingWait=false;
            IBuilderTask@ live=cast<IBuilderTask>(techOrder);
            // Head-to-head play: a started frame was abandoned (no builder on
            // it) and the yard never finished. Re-staff the frame with a fresh
            // repair task on the nanoframe (as CapitalAssist does); never
            // re-return the order itself, which recursed to a crash.
            if (Global::RoleSettings::Sea::TechRestaffFrame && live !is null && live.target !is null && live.GetUnits().length()==0) {
                IUnitTask@ staff=aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH,live.target,60*SECOND));
                if (staff !is null) { GenericHelpers::LogUtil("[SEA][TechSave] restaff frame builder="+u.id,1); return staff; }
            }
            TechYardRefused(live is null ? "ordered" : "ordered at "+int(live.GetBuildPos().x)+","+int(live.GetBuildPos().z)
                +" units="+live.GetUnits().length()+" frame="+(live.target !is null)+" height="+int(aiBattle.Height(live.GetBuildPos())));
            return null;
        }
        if (SeaEconomy::Have(yard)>0 || aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY),yard)>0) { TechYardRefused("framed or queued"); return null; }
        if (Factory::primaryT1Shipyard is null) { TechYardRefused("no primary T1 yard"); return null; }
        // Beside the T1 yard, as the shared ladder did; native placement
        // honours SEA's reservations and exits. The harbor layout is the
        // fallback: its forward/visibility admission is meant for later
        // forward harbors and rejected home sites for minutes in played games.
        IUnitTask@ task=SeaLayout::Factory(u,yard.GetName());
        IBuilderTask@ ordered=cast<IBuilderTask>(task);
        if (ordered is null || ordered.buildDef !is yard) return task; // preparation is a nano/reclaim task, not the yard order
        if (task !is null) { @techOrder=task; GenericHelpers::LogUtil("[SEA][TechSave] order "+yard.GetName()+" builder="+u.id,1); }
        else TechYardRefused("native (placement or 180 s T2 cooldown) and layout found no site allowed="+yard.IsBuildAllowed()+" available="+yard.IsAvailable(ai.frame)+" max="+yard.maxThisUnit+" count="+yard.count);
        return task;
    }
    IUnitTask@ LegacyTask(CCircuitUnit@ u) {
        if (u is null) return null;
        SeaEconomy::Tick();
        if (u.task !is null && (u.task.IsEnemyReclaim() || u.task.GetType()==int(Task::Type::PLAYER))) return u.task;
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)
            && (current.target !is null || SeaEconomy::OwnsTask(current))) return current;
        if (!u.circuitDef.IsMobile()) { IUnitTask@ help=Assist(u); return help is null ? Wait() : help; }
        // The compact mode must also adopt owned unframed orders. Otherwise
        // pending converters consume capacity forever while workers fall back
        // to guards. Job ordering gives the conversion group first claim.
        IUnitTask@ resumed=Resume(u); if (resumed !is null) return resumed;
        IUnitTask@ task=null;
        @task=PriorityGrowth(u); if (task !is null) return task;
        // Not wrapped by LayoutTask: its placement deferral aborted this order.
        @task=TechYard(u); if (task !is null) return task;
        @task=CapitalAssist(u); if (task !is null) return task;
        @task=Seaplane(u); if (task !is null) return task;
        @task=CapacityFactory(u); if (task !is null) return task;
        return LayoutTask(u,RoleSea::Sea_LegacyBuilderTask(u));
    }
    // Also applied to the shared manager's native fallback, which runs after
    // a role returns null. Keep null as null so normal expansion can continue.
    IUnitTask@ LayoutTask(CCircuitUnit@ u, IUnitTask@ task) {
        if (RejectSite(u,task)) return null;
        IBuilderTask@ build=cast<IBuilderTask>(task);
        if (build is null || build.buildDef is null || build.target !is null || SeaEconomy::OwnsTask(task)) return task;
        const Task::BuildType kind=PlacementKind(build.buildDef,build.GetBuildType());
        if (kind==Task::BuildType::MEX && SeaExpansion::Active() && SeaExpansion::Worker(u)
            && (!aiEconomyMgr.IsMexTaskUsable(task) || !SeaExpansion::SafeApproach(u.GetPos(ai.frame),build.GetBuildPos()) || !SeaExpansion::Escorted(build.GetBuildPos()))) {
            if (build.GetUnits().length()==0) aiBuilderMgr.AbortTask(task);
            return Wait();
        }
        if (kind==Task::BuildType::FACTORY && SeaInvasion::Active() && SeaInvasion::Factory(build.buildDef)) {
            // The invasion controller is the only admission/placement owner.
            // Its pinned tasks returned above are already accounted for.
            if (build.GetUnits().length()>0) return task;
            aiBuilderMgr.AbortTask(task);
            IUnitTask@ invasion=SeaInvasion::Build(u);
            return invasion is null ? Wait() : invasion;
        }
        if (kind==Task::BuildType::FACTORY && !SeaFactories::FactoryAllowed(build.buildDef)) {
            // Do not cancel a structure that another builder already started.
            array<CCircuitUnit@>@ workers=build.GetUnits();
            for (uint i=0;i<workers.length();++i) if (workers[i] !is null) workers[i].CmdStop();
            aiBuilderMgr.AbortTask(task);
            IUnitTask@ platform=Seaplane(u); return platform is null ? Wait() : platform;
        }
        // Coastal commanders still need land energy and normal mex expansion.
        // Only naval buildings belong to this water layout.
        const bool yard=SeaEconomy::Yard(build.buildDef) || UnitHelpers::IsSeaplanePlatform(build.buildDef.GetName());
        SeaLayout::RefreshGeometry();
        if (UnitHelpers::IsT1Shipyard(build.buildDef.GetName()) && !SeaLayout::hadFactory) {
            AiPreferFactoryFacing(task,SeaLayout::facing);
            return task; // single-yard exception; prefer forward, opposite last
        }
        if (!ControlledEconomy(build.buildDef) && !yard) return task;
        const string name=build.buildDef.GetName();
        // D-342: ask the layout before cancelling the native order. SEA's
        // Pending counts only its own projects, so the native task does not
        // block the layout. If the water layout has found no site for this
        // economy building for LayoutFallbackSeconds (crowded allied coast,
        // KI-657), keep the native order: tidals and converters must not
        // stall for the whole game because the planned block cannot fit.
        // Yards and nano pads keep their layout-only placement.
        placeNoSite=false;
        IUnitTask@ placed=yard ? SeaLayout::Factory(u,name) : kind==Task::BuildType::NANO ? Support(u) : Place(u,name,kind);
        if (placed is null && !yard && kind!=Task::BuildType::NANO && LayoutFallback(name,false)) {
            if (ai.frame-fallbackLog>30*SECOND) {
                fallbackLog=ai.frame;
                GenericHelpers::LogUtil("[SEA][Placement] fallback native "+name+" builder="+u.circuitDef.GetName()+" no layout site",1);
            }
            // D-351: SEA owns the admitted order, so Tick's economy filter no
            // longer aborts it a second later (the ship stopped and was
            // re-ordered every second and the tidal never started).
            SeaEconomy::Added(task);
            return task;
        }
        if (placed !is null) LayoutFallback(name,true);
        array<CCircuitUnit@>@ workers=build.GetUnits();
        for (uint i=0;i<workers.length();++i) if (workers[i] !is null) workers[i].CmdStop();
        aiBuilderMgr.AbortTask(task);
        @task=placed;
        if (task is null && ai.frame-placementLog>30*SECOND) {
            placementLog=ai.frame;
            CCircuitDef@ definition=ai.GetCircuitDef(name);
            GenericHelpers::LogUtil("[SEA][Placement] deferred "+name+" builder="+u.circuitDef.GetName()+" available="+definition.IsAvailable(ai.frame)
                +" pending="+SeaEconomy::Pending(definition)+" projects="+SeaEconomy::projects.length(),1);
        }
        return task is null ? Wait() : task;
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u) {
        if (u is null) return null;
        SeaEconomy::Tick();
        if (u.task !is null && (u.task.IsEnemyReclaim() || u.task.GetType()==int(Task::Type::PLAYER))) return u.task;
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) return current;
        if (!u.circuitDef.IsMobile()) { IUnitTask@ t=Assist(u); return t is null ? Wait() : t; }
        IUnitTask@ homeEnergy=PriorityGrowth(u); if (homeEnergy !is null) return homeEnergy;
        IUnitTask@ queued=Resume(u); if (queued !is null) return queued;
        @queued=Seaplane(u); if (queued !is null) return queued;
        @queued=SeaEcoLayout::Support(u); if (queued !is null) return queued;
        @queued=CapitalAssist(u); if (queued !is null) return queued;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        CCircuitDef@ t1=ai.GetCircuitDef(UnitHelpers::GetT1ShipyardForSide(side));
        CCircuitDef@ t2=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(side));
        const float mi=aiEconomyMgr.metal.income, ei=aiEconomyMgr.energy.income;
        const bool empty=SeaEconomy::Have(t1)+SeaEconomy::Have(t2)==0;
        IUnitTask@ t=null;
        if (empty && mi<5.0f) @t=aiEconomyMgr.EnqueueMexWithin(u,Global::Map::StartPos,1000.0f,3,true);
        if (t !is null) return t;
        if (empty && t1 !is null) { @t=SeaLayout::Factory(u,t1.GetName()); if (t !is null) return t; }
        // Energy expansion must not indefinitely postpone useful local power
        // while both banks fill. These turrets can help nearby energy frames
        // as well as the yard; Support still checks actual two-resource funding.
        if (!empty && aiEconomyMgr.metal.current>aiEconomyMgr.metal.storage*.5f
            && aiEconomyMgr.energy.current>aiEconomyMgr.energy.storage*.5f
            && ei>TeamEconomy::OwnEnergy(TeamEconomy::USAGE)*1.1f) {
            @t=Support(u); if (t !is null) return t;
        }
        // Factory pull can greatly exceed available income. Keep one expanding
        // ship while the other workers grow reliable energy toward the T2 gate.
        if (SeaConstructor::IsT1(u.circuitDef) && u.id!=SeaEconomy::mexWorker
            && ei<SeaEconomy::HomeEnergyTarget()) {
            @t=Place(u,UnitHelpers::GetTidalNameForSide(side),Task::BuildType::ENERGY);
            if (t !is null) return t;
        }
        // The dedicated expansion ship must try reachable safe metal before
        // native discretionary tasks can assign it a repair or factory guard.
        if (!empty && u.id==SeaEconomy::mexWorker) {
            @t=aiEconomyMgr.EnqueueMexWithin(u,u.GetPos(ai.frame),2400.0f,0,true);
            if (t !is null) return t;
        }
        if (UnitHelpers::IsCommander(u.circuitDef) && !empty && SeaEconomy::Number(SeaEconomy::Constructor(side,false),true)>=2) {
            @t=NativeTask(u); if (t !is null) return t;
        }
        const bool energyLow=aiEconomyMgr.energy.current<aiEconomyMgr.energy.storage*.45f && ei<aiEconomyMgr.energy.pull*1.1f;
        if (!empty && UnitHelpers::IsCommander(u.circuitDef) && SeaEconomy::Number(SeaEconomy::Constructor(side,false),true)<2 && !energyLow) {
            @t=Assist(u); if (t !is null) return t;
        }
        if (energyLow) {
            CCircuitDef@ fus=ai.GetCircuitDef(UnitHelpers::GetNavalFusionNameForSide(side));
            if (fus !is null && u.circuitDef.CanBuild(fus) && mi>=30 && SeaEconomy::Pending(fus)+aiBuilderMgr.GetUnfinishedCount(fus)==0)
                @t=Place(u,fus.GetName(),Task::BuildType::ENERGY,2);
            if (t is null) @t=Place(u,UnitHelpers::GetTidalNameForSide(side),Task::BuildType::ENERGY);
            if (t !is null) return t;
        }
        // A selected, protected relocation must reach an actual builder before
        // native discretionary expansion can claim every free constructor.
        for (uint i=0; i<SeaLayout::berths.length(); ++i) {
            SeaLayout::Berth@ b=SeaLayout::berths[i]; if (b.oldUnit<0) continue;
            CCircuitUnit@ old=ai.GetTeamUnit(b.oldUnit);
            if (old !is null && Lifecycle::IsRetiring(old) && aiTerrainMgr.CanReachAt(u,old.GetPos(ai.frame),u.circuitDef.GetBuildDistance()))
                return aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH,old,120*SECOND));
            if (!b.active && SeaFactories::Safe(b.anchor)) { @t=SeaLayout::Factory(u,b.name,b.oldUnit,b.anchor); if (t !is null) return t; }
        }
        @t=Upgrade(u); if (t !is null) return t;
        if (SeaConstructor::IsT2(u.circuitDef) && mi>=Global::RoleSettings::Sea::MinimumMetalIncomeForFUS
            && ei<mi*Global::RoleSettings::Sea::EnergyPerMetal) {
            CCircuitDef@ reactor=ai.GetCircuitDef(UnitHelpers::GetNavalFusionNameForSide(side));
            if (reactor !is null && SeaEconomy::Pending(reactor)+aiBuilderMgr.GetUnfinishedCount(reactor)==0) {
                @t=Place(u,reactor.GetName(),Task::BuildType::ENERGY,2); if (t !is null) return t;
            }
        }
        if (!empty && t2 !is null && SeaEconomy::Have(t2)==0 && SeaEconomy::TechReady(t2)) {
            @t=SeaLayout::Factory(u,t2.GetName()); if (t !is null) return t;
        }
        if (u.id==SeaEconomy::mexWorker || UnitHelpers::IsCommander(u.circuitDef)) {
            @t=aiEconomyMgr.EnqueueMexWithin(u,u.id==SeaEconomy::mexWorker ? u.GetPos(ai.frame) : Global::Map::StartPos,
                u.id==SeaEconomy::mexWorker ? 2400.0f : 1000.0f,0,true);
            if (t !is null) return t;
        }
        if (SeaConstructor::IsT1(u.circuitDef)) {
            @t=RoleSea::Sea_TryHandleObjective(u,u.GetPos(ai.frame),side,mi,ei);
            if (t !is null) return t;
        }
        @t=Support(u); if (t !is null) return t;
        @t=CapacityFactory(u); if (t !is null) return t;
        // Existing threat-driven tasks retain native placement, which observes
        // the same allied reservations and exit corridors as the new planner.
        const array<int> kinds={int(Task::BuildType::DEFENCE),int(Task::BuildType::SONAR),int(Task::BuildType::RADAR),
            int(Task::BuildType::BUNKER),int(Task::BuildType::GEO),int(Task::BuildType::GEOUP),int(Task::BuildType::REPAIR)};
        for (uint i=0; i<kinds.length(); ++i) { @t=aiBuilderMgr.FindQueuedTask(u,kinds[i]); if (t !is null && !RejectSite(u,t)) return t; }
        @t=NativeTask(u); if (t !is null) return t;
        @t=Place(u,UnitHelpers::GetTidalNameForSide(side),Task::BuildType::ENERGY);
        if (t !is null) return t;
        @t=Assist(u); return t is null ? Wait() : t;
    }
}
