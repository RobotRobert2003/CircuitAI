#include "sea_layout.as"
#include "../../helpers/math/build_power_math.as"
#include "../../helpers/math/sea_math.as"
#include "../../manager/economy.as"
#include "../team/team_economy.as"

namespace SeaEconomy {
    array<int> owned;
    array<int> productionFactories;
    // Once-per-second membership remains unchanged. The local power index is
    // rebuilt lazily for CURRENT cached positions each frame, and immediately
    // after ownership changes (including same-frame engine ID reuse).
    class PowerCell { array<int> ids; }
    dictionary powerCellIds;
    array<PowerCell@> powerCells;
    array<int> powerTouched, powerCandidates;
    int powerFrame=-1;
    uint powerOwnership=0;
    float powerReach=0;
    dictionary powerSeen;
    array<int> supportedDefinitions;
    void IndexPower() {
        const uint revision=ai.GetOwnedUnitRevision();
        if (powerFrame==ai.frame && powerOwnership==revision) return;
        powerFrame=ai.frame; powerOwnership=revision; powerReach=0;
        for (uint i=0;i<powerTouched.length();++i) powerCells[powerTouched[i]].ids.resize(0);
        powerTouched.resize(0);
        for (uint i=0;i<owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]);
            if (u is null || u.circuitDef.GetBuildSpeed()<=0) continue;
            const AIFloat3 p=u.GetPos(ai.frame);
            const string key=int(floor(p.x/512.0f))+":"+int(floor(p.z/512.0f));
            int cell=-1;
            if (!powerCellIds.get(key,cell)) {
                cell=int(powerCells.length()); powerCells.insertLast(PowerCell()); powerCellIds.set(key,cell);
            }
            if (powerCells[cell].ids.length()==0) powerTouched.insertLast(cell);
            powerCells[cell].ids.insertLast(u.id);
            powerReach=AiMax(powerReach,u.circuitDef.GetBuildDistance());
        }
    }
    array<IUnitTask@> projects;
    array<CCircuitDef@> conversionDefs;
    void InitConversionDefs() {
        if (conversionDefs.length()>0) return;
        const array<string> sides={"armada","cortex","legion"};
        for (uint i=0;i<sides.length();++i) {
            const array<string> names={UnitHelpers::GetEnergyConverterNameForSide(sides[i]),
                UnitHelpers::GetAdvEnergyConverterNameForSide(sides[i]),
                UnitHelpers::GetNavalEnergyConverterNameForSide(sides[i]),
                UnitHelpers::GetAdvNavalEnergyConverterNameForSide(sides[i])};
            for (uint j=0;j<names.length();++j) {
                CCircuitDef@ d=ai.GetCircuitDef(names[j]);
                if (d !is null) conversionDefs.insertLast(d);
            }
        }
    }
    float ConversionCapacity(int &out pending) {
        InitConversionDefs();
        float capacity=0; pending=0;
        // Twelve immutable definitions, O(1) native lifecycle counts. Include
        // donated land converters and frames immediately, not a stale census.
        for (uint i=0;i<conversionDefs.length();++i) {
            CCircuitDef@ d=conversionDefs[i];
            capacity+=float(d.count)*aiEconomyMgr.GetEnergyUse(d);
            pending+=aiBuilderMgr.GetUnfinishedCount(d);
        }
        // Only unframed orders are extra: a task with a frame is already in
        // d.count. Read the live ledger so simultaneous workers cannot all
        // spend the same gap; no scan over the growing owned-unit population.
        for (uint i=0;i<projects.length();++i) {
            IBuilderTask@ t=cast<IBuilderTask>(projects[i]);
            if (t is null || t.IsDead() || t.target !is null) continue;
            const float draw=aiEconomyMgr.GetEnergyUse(t.buildDef);
            if (draw>0) { capacity+=draw; ++pending; }
        }
        return capacity;
    }
    float ConversionGap(int &out pending) {
        return SeaMath::ConversionGap(aiEconomyMgr.energy.income,TeamEconomy::OwnEnergy(TeamEconomy::USAGE),
            ai.GetTeamRulesParam("mmUse",0.0f),ConversionCapacity(pending),Global::RoleSettings::Sea::ConverterEnergyReserve);
    }
    int conversionLog=-100000;
    void ConversionRefused(const string &in reason) {
        if (ai.frame-conversionLog<30*SECOND) return;
        conversionLog=ai.frame;
        GenericHelpers::LogUtil("[SEA][ConversionWait] reason="+reason,1);
    }
    bool NeedsConverter(CCircuitDef@ d) {
        if (d is null) return false;
        int pending=0;
        const float gap=ConversionGap(pending), draw=aiEconomyMgr.GetEnergyUse(d);
        const bool ready=SeaMath::ConversionReady(aiEconomyMgr.IsMetalMap(),aiEconomyMgr.energy.current,aiEconomyMgr.energy.storage,
            ai.GetTeamRulesParam("mmLevel",.75f),aiEconomyMgr.energy.income,
            Global::RoleSettings::Sea::BuildT1ConvertersMinimumEnergyIncome,gap,draw,pending,
            Global::RoleSettings::Sea::ConverterParallelProjects);
        if (aiEconomyMgr.metal.storage>0 && aiEconomyMgr.metal.current>=aiEconomyMgr.metal.storage*.95f) {
            ConversionRefused("metal-full"); return false;
        }
        if (!ready) ConversionRefused(aiEconomyMgr.IsMetalMap() ? "metal-map" : pending>=Global::RoleSettings::Sea::ConverterParallelProjects
            ? "pending-capacity" : gap<draw*.75f ? "no-surplus" : "income-or-storage");
        return ready;
    }
    bool FusionFunded(CCircuitDef@ d) {
        if (d is null || !Economy::IncomeWindowReady()) return false;
        float queuedM=0,queuedE=0; UnframedCosts(queuedM,queuedE);
        return SeaMath::CapitalEnergyReady(Economy::GetMinMetalIncomeLast10s(),Economy::GetMinEnergyIncomeLast10s(),
            aiEconomyMgr.metal.current-queuedM-recruitAdmittedM,aiEconomyMgr.energy.current-queuedE-recruitAdmittedE,
            d.costM,d.costE,Global::RoleSettings::Sea::FusionBudgetSeconds,Global::RoleSettings::Sea::EconomyIncomeShare,
            Global::RoleSettings::Sea::MinimumMetalIncomeForFUS,Global::RoleSettings::Sea::MinimumEnergyIncomeForFUS);
    }
    dictionary counts, finished, busy, support, products, lastProducts;
    array<float> capacityBanks;
    int capacityFrame=-1, capacityFull=0;
    bool capacityPressure=false;
    float productionBasePower=0;
    int frame=-1, logFrame=-100000, mexWorker=-1;
    float mobilePower=0, pendingPower=0, idlePower=0, committedM=0, committedE=0;
    // Home capacity is tier/job local; expansion/upgrade/production workers
    // are not credited to tidal/fusion work merely because they exist.
    array<float> homePower(2,0), homeIdle(2,0), homePending(2,0);
    float productionEnergyPerMetal=0;
    float admittedM=0, admittedE=0;
    float recruitAdmittedM=0, recruitAdmittedE=0;
    int fundedFrame=-1; string fundedName;
    int Number(const string &in name, bool complete=false) {
        int64 n=0; if (complete) finished.get(name,n); else counts.get(name,n); return int(n);
    }
    void Increment(dictionary &inout values, const string &in key) {
        int64 n=0; values.get(key,n); values.set(key,n+1);
    }
    void Added(IUnitTask@ task) {
        if (!SeaLayout::Enabled()) return;
        IBuilderTask@ t=cast<IBuilderTask>(task);
        if (t !is null && t.buildDef !is null && t.GetBuildType()<int(Task::BuildType::REPAIR)
            && projects.findByRef(t)<0) projects.insertLast(t);
    }
    void Removed(IUnitTask@ task) {
        const int index=projects.findByRef(task);
        if (index>=0) projects.removeAt(index);
    }
    bool OwnsTask(IUnitTask@ task) {
        // Native reservationId is set only when the builder reaches/serves its
        // slot. A claimed pin is already ours throughout the approach journey.
        return task !is null && (projects.findByRef(task)>=0 || AiTaskReservationId(task)>=0);
    }
    int Pending(CCircuitDef@ d) {
        if (d is null) return 0;
        int n=0;
        for (uint i=0; i<projects.length(); ++i) {
            IBuilderTask@ t=cast<IBuilderTask>(projects[i]);
            if (t !is null && !t.IsDead() && t.buildDef is d && t.target is null) ++n;
        }
        return n;
    }
    int Have(CCircuitDef@ d) { return d is null ? 0 : d.count+Pending(d); }
    string Constructor(const string &in side, bool advanced) {
        if (advanced) return side=="armada" ? "armacsub" : side=="cortex" ? "coracsub" : "leganavyconsub";
        return side=="armada" ? "armcs" : side=="cortex" ? "corcs" : "legnavyconship";
    }
    bool Yard(const CCircuitDef@ d) { return d !is null && (UnitHelpers::IsT1Shipyard(d.GetName()) || UnitHelpers::IsT2Shipyard(d.GetName())); }
    // Support eligibility is broader than shipyard tech and relocation policy.
    bool SupportedFactory(const CCircuitDef@ d) {
        if (d is null) return false;
        const uint id=d.id;
        if (id<supportedDefinitions.length() && supportedDefinitions[id]!=0) return supportedDefinitions[id]==2;
        const string name=d.GetName();
        const bool supported=Yard(d) || UnitHelpers::IsSeaplanePlatform(name) || name=="armamsub" || name=="coramsub" || name=="legamphlab"
            || UnitHelpers::IsFloatingHoverPlant(name) || UnitHelpers::IsWaterGantry(name);
        if (supportedDefinitions.length()<=id) supportedDefinitions.resize(id+1);
        supportedDefinitions[id]=supported ? 2 : 1; // name-based classification is immutable
        return supported;
    }
    CCircuitDef@ Product(int factoryId) {
        int id=-1;
        if (products.get(""+factoryId,id) || lastProducts.get(""+factoryId,id)) return ai.GetCircuitDef(id);
        CCircuitUnit@ yard=ai.GetTeamUnit(factoryId);
        if (yard is null) return null;
        const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
        CCircuitDef@ fallback=ai.GetCircuitDef(Yard(yard.circuitDef) ? Constructor(side,UnitHelpers::IsT2Shipyard(yard.circuitDef.GetName()))
            : SeaInvasion::Factory(yard.circuitDef) ? SeaInvasion::Product(side,UnitHelpers::IsWaterGantry(yard.circuitDef.GetName())) : "");
        return fallback !is null && yard.circuitDef.CanBuild(fallback) ? fallback : null;
    }
    bool ConstructorDef(const CCircuitDef@ d) { return d !is null && (SeaConstructor::IsT1(d) || SeaConstructor::IsT2(d)); }
    string SiteKey(const string &in name, const AIFloat3 &in p) { return name+":"+int(p.x)+":"+int(p.z); }
    bool Busy(int id) { return busy.exists(""+id); }
    void Tick() {
        if (!SeaLayout::Enabled() || ai.frame-frame<SECOND) return;
        const int window=AiMax(2,Global::RoleSettings::Sea::CapacityObservationSeconds);
        if (capacityFrame<0 || ai.frame-capacityFrame>2*SECOND) { capacityBanks.resize(0); capacityFull=0; }
        capacityFrame=ai.frame;
        const float bank=aiEconomyMgr.metal.current, storage=aiEconomyMgr.metal.storage;
        capacityBanks.insertLast(bank);
        if (int(capacityBanks.length())>window) capacityBanks.removeAt(0);
        capacityFull=storage>0 && bank>=storage*Global::RoleSettings::Sea::CapacityHighMetal ? AiMin(window,capacityFull+1) : 0;
        // Bounded 10-value observation, once per second. Gifts are already in
        // bank; a received-metal rate is not added to income a second time.
        const bool pressure=BuildPowerMath::Pressure(bank,storage,capacityBanks[0],int(capacityBanks.length()),window,
            capacityFull,Global::RoleSettings::Sea::CapacityHighMetal,AiMax(100.0f,storage*.1f))
            || BuildPowerMath::Refilling(capacityBanks,storage,.60f,Global::RoleSettings::Sea::CapacityHighMetal);
        capacityPressure=SeaMath::CapacityPressure(aiEconomyMgr.metal.income,TeamEconomy::OwnMetal(TeamEconomy::USAGE),bank,storage,pressure);
        frame=ai.frame; owned.resize(0); counts.deleteAll(); finished.deleteAll(); busy.deleteAll(); support.deleteAll(); mexWorker=-1;
        powerFrame=-1;
        productionFactories.resize(0); products.deleteAll(); productionBasePower=0;
        for (uint tier=0;tier<2;++tier) { homePower[tier]=0; homeIdle[tier]=0; homePending[tier]=0; }
        mobilePower=0; pendingPower=0; idlePower=0; committedM=0; committedE=0; admittedM=0; admittedE=0; recruitAdmittedM=0; recruitAdmittedE=0;
        dictionary berthSites, berthProducers;
        for (uint b=0; b<SeaLayout::berths.length(); ++b) {
            SeaLayout::Berth@ berth=SeaLayout::berths[b];
            if (berth.slot>=0) berthSites.set(SiteKey(berth.name,berth.centre),int64(b));
            if (berth.unit>=0) berthProducers.set(""+berth.unit,int64(b));
        }
        array<Id>@ ids=ai.GetOwnedUnitIds();
        for (uint i=0; i<ids.length(); ++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(ids[i]); if (u is null) continue;
            owned.insertLast(u.id); const CCircuitDef@ d=u.circuitDef;
            const string name=d.GetName();
            const int producer=u.GetProducerId();
            const float progress=u.GetBuildProgress(); Increment(counts,name);
            // Unit handles borrowed from tasks can outlive a transfer. Account
            // framed work only through the currently owned, validated units.
            if (progress<1.0f) { committedM+=d.costM*(1-progress); committedE+=d.costE*(1-progress); }
            if (progress>=1.0f) Increment(finished,name);
            // Engine unit IDs are not creation order. Share the role's first
            // construction ship identity; builder lifecycle promotes on loss.
            if (progress>=1 && u is Builder::primaryT1SeaConstructor) mexWorker=u.id;
            if (producer>=0 && progress<1.0f) {
                busy.set(""+producer,true);
                products.set(""+producer,int(d.id));
            }
            if (progress>=1 && SupportedFactory(d) && !Lifecycle::IsRetiring(u)) productionFactories.insertLast(u.id);
            // A shore commander is not a naval expansion worker. Count its
            // actual yard assistance in LocalPower, not in mobile capacity.
            if (ConstructorDef(d)) {
                const uint tier=SeaConstructor::IsT2(d) ? 1 : 0;
                if (progress<1.0f) { pendingPower+=d.GetBuildSpeed(); homePending[tier]+=d.GetBuildSpeed(); }
                else {
                    mobilePower+=d.GetBuildSpeed();
                    IBuilderTask@ work=cast<IBuilderTask>(u.task);
                    const bool protectedTask=u.task !is null && (u.task.IsExternalControlled() || u.task.IsEnemyReclaim()
                        || u.task.GetType()==int(Task::Type::PLAYER) || u.task.GetType()==int(Task::Type::RETREAT));
                    const int kind=work is null ? -1 : work.GetBuildType();
                    const bool remoteJob=kind==int(Task::BuildType::MEX) || kind==int(Task::BuildType::MEXUP);
                    const int guarded=work !is null && kind==int(Task::BuildType::GUARD) ? work.GetGuardTargetId() : -1;
                    CCircuitUnit@ assist=guarded>=0 ? ai.GetTeamUnit(guarded) : work is null ? null : work.target;
                    const bool productionJob=assist !is null && (SupportedFactory(assist.circuitDef) || assist.GetProducerId()>=0);
                    IBuilderTask@ assisted=assist is null ? null : cast<IBuilderTask>(assist.task);
                    IBuilderTask@ economic=kind==int(Task::BuildType::GUARD) ? assisted : work;
                    const bool producingEconomy=economic !is null && economic.target !is null
                        && (economic.GetBuildType()==int(Task::BuildType::ENERGY) || economic.GetBuildType()==int(Task::BuildType::CONVERT))
                        && MapHelpers::SqDist(u.GetPos(ai.frame),economic.target.GetPos(ai.frame))<=d.GetBuildDistance()*d.GetBuildDistance();
                    const bool home=producingEconomy || MapHelpers::SqDist(u.GetPos(ai.frame),Global::Map::StartPos)
                        <=Global::RoleSettings::Sea::GrowthHomeRadius*Global::RoleSettings::Sea::GrowthHomeRadius;
                    const float useful=SeaMath::LocalWorkPower(d.GetBuildSpeed(),SeaExpansion::Worker(u)||remoteJob||productionJob,true,home,protectedTask);
                    homePower[tier]+=useful;
                    if (u.task is null || kind==int(Task::BuildType::WAIT) || u.task.GetType()==int(Task::Type::WAIT) || u.task.GetType()==int(Task::Type::IDLE)) homeIdle[tier]+=useful;
                    if (u.task is null || u.task.GetType()==int(Task::Type::WAIT) || u.task.GetType()==int(Task::Type::IDLE)) idlePower+=d.GetBuildSpeed();
                }
            }
            // Re-associate completed yards after reload, transfer or frame creation.
            int64 berthIndex=-1;
            if (SupportedFactory(d) && berthSites.get(SiteKey(name,u.GetPos(ai.frame)),berthIndex)) {
                SeaLayout::Berth@ berth=SeaLayout::berths[uint(berthIndex)];
                if (berth.unit!=u.id) { berth.unit=u.id; berth.active=true; SeaLayout::Save(berth); }
                berthProducers.set(""+u.id,berthIndex);
            }
            // A real ordinary product must leave: a completed building is not proof.
            if (progress>=1.0f && d.IsMobile() && !d.IsAbleToFly() && producer>=0
                && berthProducers.get(""+producer,berthIndex)) {
                SeaLayout::Berth@ berth=SeaLayout::berths[uint(berthIndex)];
                if (!berth.exited && MapHelpers::SqDist(u.GetPos(ai.frame),berth.centre)>Global::RoleSettings::Sea::ExitLength*Global::RoleSettings::Sea::ExitLength) {
                    berth.exited=true; SeaLayout::Save(berth);
                    GenericHelpers::LogUtil("[SEA][Harbor] exit verified yard="+berth.unit+" ship="+u.id,1);
                }
            }
        }
        dictionary remembered;
        for (uint i=0; i<productionFactories.length(); ++i) {
            CCircuitUnit@ factory=ai.GetTeamUnit(productionFactories[i]);
            if (factory is null) continue;
            productionBasePower+=factory.circuitDef.GetBuildSpeed();
            int defId=-1;
            const string key=""+factory.id;
            if (products.get(key,defId) || lastProducts.get(key,defId)) remembered.set(key,defId);
        }
        productionEnergyPerMetal=0;
        float nominalMetal=0, nominalEnergy=0;
        const array<string> productKeys=remembered.getKeys();
        for (uint i=0;i<productKeys.length();++i) {
            int id=-1; if (!remembered.get(productKeys[i],id)) continue;
            CCircuitDef@ product=ai.GetCircuitDef(id);
            if (product is null || product.GetBuildTime()<=0) continue;
            nominalMetal+=product.costM/product.GetBuildTime(); nominalEnergy+=product.costE/product.GetBuildTime();
        }
        if (nominalMetal>0) productionEnergyPerMetal=nominalEnergy/nominalMetal;
        lastProducts=remembered; // prune dead/transferred factories, retain gaps between products
        const array<string> urgentKeys=SeaFactories::urgentProducts.getKeys();
        for (uint i=0;i<urgentKeys.length();++i)
            if (ai.GetTeamUnit(int(parseInt(urgentKeys[i]))) is null) SeaFactories::urgentProducts.delete(urgentKeys[i]);
        for (int i=int(projects.length())-1; i>=0; --i) {
            IBuilderTask@ t=cast<IBuilderTask>(projects[i]);
            if (t is null || t.IsDead()) { projects.removeAt(i); continue; }
            if (t.target is null) { committedM+=t.buildDef.costM; committedE+=t.buildDef.costE; }
        }
        const array<string> constructors=UnitHelpers::GetAllT1SeaConstructors();
        const array<string> advanced=UnitHelpers::GetAllT2SeaConstructors();
        for (uint i=0; i<constructors.length()+advanced.length(); ++i) {
            CCircuitDef@ d=ai.GetCircuitDef(i<constructors.length() ? constructors[i] : advanced[i-constructors.length()]);
            if (d !is null) {
                const float pending=float(aiFactoryMgr.GetPendingRecruitCount(d))*d.GetBuildSpeed();
                pendingPower+=pending; homePending[i<constructors.length() ? 0 : 1]+=pending;
            }
        }
        if (ai.frame-logFrame>=30*SECOND) {
            logFrame=ai.frame;
            int convertersPending=0;
            const float conversion=ConversionCapacity(convertersPending);
            GenericHelpers::LogUtil("[SEA][Economy] M="+aiEconomyMgr.metal.income+" E="+aiEconomyMgr.energy.income
                +" bank="+aiEconomyMgr.metal.current+" workers="+mobilePower+" homeT1="+homePower[0]+" homeT2="+homePower[1]+" pending="+pendingPower+" committed="+committedM
                +" Ebank="+aiEconomyMgr.energy.current+" Euse="+TeamEconomy::OwnEnergy(TeamEconomy::USAGE)
                +" converted="+ai.GetTeamRulesParam("mmUse",0.0f)+" convertCapacity="+conversion+" convertPending="+convertersPending,1);
            CCircuitDef@ yard=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(Global::AISettings::Side));
            if (yard !is null && Have(yard)==0)
                GenericHelpers::LogUtil("[SEA][TechGate] minM="+Economy::GetMinMetalIncomeLast10s()+" minE="+Economy::GetMinEnergyIncomeLast10s()
                    +" bank="+aiEconomyMgr.metal.current+" ready="+TechReady(yard)+" water="+HoldingWater(),1);
        }
    }
    // D-300: the first advanced yard is wanted once the income gates pass and
    // stays wanted until it is finished. O(1): two def counts and the shared
    // income window, called from factory decisions only. Lifecycle: the save
    // clock starts once, expires after TechSaveMaxSeconds, and resets only
    // when a finished yard is later lost.
    int techSaveSince=-1, techRetryAfter=-1;
    bool techSaveExpired=false, techCommitted=false;
    bool TechSaving() {
        if (!Global::RoleSettings::Sea::TechSave) return false;
        CCircuitDef@ yard=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(Global::AISettings::Side));
        if (yard is null) return false;
        if (yard.count>aiBuilderMgr.GetUnfinishedCount(yard)) {
            if (techSaveSince>=0) GenericHelpers::LogUtil("[SEA][TechSave] done seconds="+((ai.frame-techSaveSince)/SECOND),1);
            techSaveSince=-1; techSaveExpired=false; techCommitted=false; return false;
        }
        // Wanting T2 needs only the income gates: a contested sea must not
        // block the order (head-to-head: Armada never reached T2). Only the
        // production pause (TechHold) needs held, uncontested water.
        if (techSaveExpired && ai.frame>=techRetryAfter) { techSaveExpired=false; techSaveSince=-1; techCommitted=false; }
        if (techSaveExpired || !Economy::IncomeWindowReady()) return false;
        // A started frame keeps the save going whatever a dip in income does.
        if (yard.count==0 && (Economy::GetMinMetalIncomeLast10s()<Global::RoleSettings::Sea::TechMinimumMetalIncome
            || Economy::GetMinEnergyIncomeLast10s()<Global::RoleSettings::Sea::TechMinimumEnergyIncome)) return false;
        const AIFloat3 harbor=SeaEcoLayout::Harbor();
        if (harbor.x<0 || !SeaTech::Permit(aiBattle.WaterBody(harbor,false),yard.count>0 ? 2 : 1)) return false;
        if (techSaveSince<0) {
            techSaveSince=ai.frame;
            GenericHelpers::LogUtil("[SEA][TechSave] start M="+aiEconomyMgr.metal.income+" E="+aiEconomyMgr.energy.income+" bank="+aiEconomyMgr.metal.current,1);
        }
        // Unframed: TechSaveMaxSeconds to get the yard placed. Framed: the
        // same again to finish it. Either cap resumes ordinary production.
        if (ai.frame-techSaveSince>int(Global::RoleSettings::Sea::TechSaveMaxSeconds*SECOND*(yard.count>0 ? 2 : 1))) {
            techSaveExpired=true; techRetryAfter=ai.frame+60*SECOND; SeaTech::Release();
            GenericHelpers::LogUtil("[SEA][TechSave] expired framed="+(yard.count>0)+" bank="+aiEconomyMgr.metal.current,1);
            return false;
        }
        return true;
    }
    // A running save is the commitment: the frame is placed at once and the
    // paused T1 production funds it from income, as a player would. The
    // bank-based TechReady gate is momentary and constructors ask only when
    // idle, so in natural games it never coincided with an ask (D-300).
    bool TechCommitted() {
        if (!TechSaving()) return false;
        if (!techCommitted) {
            techCommitted=true;
            GenericHelpers::LogUtil("[SEA][TechSave] commit bank="+aiEconomyMgr.metal.current+" M="+Economy::GetMinMetalIncomeLast10s(),1);
        }
        return true;
    }
    bool TechReady(CCircuitDef@ yard, bool saving=false) {
        if (yard is null || !Economy::IncomeWindowReady() || !HoldingWater()) return false;
        CCircuitDef@ con=ai.GetCircuitDef(Constructor(UnitHelpers::GetSideForUnitName(yard.GetName()),true));
        if (con is null) return false;
        return SeaMath::TechReady(Economy::GetMinMetalIncomeLast10s(),Economy::GetMinEnergyIncomeLast10s(),
            saving ? yard.costM+con.costM+800.0f : AiMax(0.0f,aiEconomyMgr.metal.current-admittedM),aiEconomyMgr.energy.current,
            Global::RoleSettings::Sea::TechMinimumMetalIncome,Global::RoleSettings::Sea::TechMinimumEnergyIncome,
            SeaMath::TechStartupBank(Economy::GetMinMetalIncomeLast10s(),Global::RoleSettings::Sea::FirstT2BankSeconds,
                Global::RoleSettings::Sea::RequiredMetalCurrentForT2Shipyard,Have(yard)==0),yard.costM+con.costM+800.0f,yard.costE+con.costE+8000.0f,
            Global::RoleSettings::Sea::TechPackageSeconds,Global::RoleSettings::Sea::TechPackageIncomeShare);
    }
    void UnframedCosts(float &out queuedM, float &out queuedE) {
        // Existing usage already pays framed work. Unframed commitments reserve bank.
        queuedM=0; queuedE=0;
        for (uint i=0; i<projects.length(); ++i) {
            IBuilderTask@ t=cast<IBuilderTask>(projects[i]);
            if (t !is null && !t.IsDead() && t.target is null) { queuedM+=t.buildDef.costM; queuedE+=t.buildDef.costE; }
        }
    }
    bool SeaplaneReady(const CCircuitDef@ d) {
        if (d is null || !Economy::IncomeWindowReady()) return false;
        const float mi=Economy::GetMinMetalIncomeLast10s(), ei=Economy::GetMinEnergyIncomeLast10s();
        if (mi<Global::RoleSettings::Sea::SeaplaneMinimumMetalIncome || ei<Global::RoleSettings::Sea::SeaplaneMinimumEnergyIncome) return false;
        // Reuse the income window (amortized O(1)); inspect queued projects
        // only on factory decisions after the cheap gate passes, never scan
        // owned units here. Read live commitments so same-frame work counts.
        float queuedM=0, queuedE=0; UnframedCosts(queuedM,queuedE);
        return SeaMath::SeaplaneEconomyReady(true,mi,ei,
            aiEconomyMgr.metal.current-queuedM-recruitAdmittedM,aiEconomyMgr.energy.current-queuedE-recruitAdmittedE,
            d.costM,d.costE,Global::RoleSettings::Sea::SeaplaneMinimumMetalIncome,Global::RoleSettings::Sea::SeaplaneMinimumEnergyIncome,
            Global::RoleSettings::Sea::SeaplaneMetalReserve,Global::RoleSettings::Sea::SeaplaneEnergyReserve);
    }
    bool Fund(CCircuitDef@ d, float buildPower, float extraM=0, float extraE=0, float reserveM=0, float reserveE=0, float horizon=0, float redirectM=0, float redirectE=0, bool useConversionEnergy=false) {
        fundedFrame=-1; fundedName="";
        if (d is null || buildPower<=0) return false;
        const float seconds=AiMax(1.0f,d.GetBuildTime()/buildPower);
        const float budgetHorizon=horizon>0 ? horizon : Global::RoleSettings::Sea::WorkforceHorizon;
        float queuedM=0, queuedE=0; UnframedCosts(queuedM,queuedE);
        // Conversion is discretionary expenditure. For funded capacity only,
        // price the conservative case where it ALL stops: remove its energy
        // use and the corresponding metal income together. Gifts are already
        // in the bank, never added as predicted future income. O(1) callbacks.
        const float conversionEnergy=useConversionEnergy ? AiMax(0.0f,ai.GetTeamRulesParam("mmUse",0.0f)) : 0.0f;
        const float conversionMetal=conversionEnergy>0 ? conversionEnergy*AiMax(0.0f,ai.GetTeamRulesParam("mmAvgEffi",0.0f)) : 0.0f;
        const bool funded=BuildPowerMath::Funded(aiEconomyMgr.metal.current,reserveM,AiMax(0.0f,aiEconomyMgr.metal.income-conversionMetal),SeaMath::GrowthUsage(TeamEconomy::OwnMetal(TeamEconomy::USAGE),redirectM),
            queuedM+recruitAdmittedM,d.costM,seconds,extraM,budgetHorizon)
            && BuildPowerMath::Funded(aiEconomyMgr.energy.current,reserveE,aiEconomyMgr.energy.income,SeaMath::GrowthUsage(TeamEconomy::OwnEnergy(TeamEconomy::USAGE),redirectE+conversionEnergy),
            queuedE+recruitAdmittedE,d.costE,seconds,extraE,Global::RoleSettings::Sea::WorkforceHorizon);
        if (funded) { fundedFrame=ai.frame; fundedName=d.GetName(); }
        return funded;
    }
    void Admit(CCircuitDef@ d, bool funded=false, bool pinnedProject=false) {
        if (d is null) return;
        if (funded && (fundedFrame!=ai.frame || fundedName!=d.GetName()))
            Invariants::Violation("INV-129",d.GetName(),"SEA workforce lacks same-frame funding");
        admittedM+=d.costM; admittedE+=d.costE;
        // Pinned construction is already present in the live projects ledger
        // used by Fund. Only factory admissions need a separate bank reserve.
        if (!pinnedProject) { recruitAdmittedM+=d.costM; recruitAdmittedE+=d.costE; }
    }
    bool FundGrowth(CCircuitUnit@ yard,CCircuitDef@ worker,CCircuitDef@ project) {
        if (yard is null || worker is null || project is null) return false;
        CCircuitDef@ old=Product(yard.id);
        int urgent=-1;
        if (SeaFactories::urgentProducts.get(""+yard.id,urgent) && old !is null && urgent==int(old.id)) return false;
        const float bp=LocalPower(yard), share=Global::RoleSettings::Sea::GrowthReserveShare;
        // The requesting yard changes from discretionary hulls to this worker.
        // Credit only that replaceable spending, bounded by the growth budget;
        // never subtract all military usage or anticipate future donations.
        const float rm=old is null ? 0 : AiMin(aiEconomyMgr.metal.income*share,bp*old.costM/AiMax(1.0f,old.GetBuildTime()));
        const float re=old is null ? 0 : AiMin(aiEconomyMgr.energy.income*share,bp*old.costE/AiMax(1.0f,old.GetBuildTime()));
        // Model budget-limited completion, not instant feeding of nominal BP.
        // Otherwise even a funded worker is rejected on a fully spent economy.
        const float financed=BuildPowerMath::Power(rm,re,worker.GetBuildTime(),worker.costM,worker.costE);
        return Fund(worker,AiMin(bp,financed),worker.GetBuildSpeed()*project.costM/project.GetBuildTime(),
            worker.GetBuildSpeed()*project.costE/project.GetBuildTime(),0,0,0,rm,re);
    }
    float FundedEnergySoon(float horizon) {
        // Planning only: never credit this forecast to Fund or converter income.
        // O(P+B) over owned projects and their assigned builders, on job asks.
        // Requiring cash for all current commitments avoids promising the same
        // future income to a reactor and its converters simultaneously.
        float queuedM=0,queuedE=0; UnframedCosts(queuedM,queuedE);
        if (aiEconomyMgr.metal.current<committedM+queuedM+recruitAdmittedM
            || aiEconomyMgr.energy.current<committedE+queuedE+recruitAdmittedE) return 0;
        float energy=0;
        for (uint i=0;i<projects.length();++i) {
            IBuilderTask@ work=cast<IBuilderTask>(projects[i]);
            if (work is null || work.IsDead() || work.buildDef is null || work.GetBuildType()!=int(Task::BuildType::ENERGY)) continue;
            const float make=aiEconomyMgr.GetEnergyMake(work.buildDef);
            if (make<=0) continue;
            const float progress=work.target is null ? 0 : work.target.GetBuildProgress();
            if (progress>=1) continue;
            float power=0;
            array<CCircuitUnit@>@ builders=work.GetUnits();
            for (uint b=0;b<builders.length();++b) {
                CCircuitUnit@ unit=builders[b];
                if (unit is null || ai.GetTeamUnit(unit.id) is null || unit.task !is work) continue;
                if (MapHelpers::SqDist(unit.GetPos(ai.frame),work.GetBuildPos())
                    <=unit.circuitDef.GetBuildDistance()*unit.circuitDef.GetBuildDistance()) power+=unit.circuitDef.GetBuildSpeed();
            }
            if (power>0 && work.buildDef.GetBuildTime()*(1-progress)<=power*horizon) energy+=make;
        }
        return energy;
    }
    float HomeEnergyTarget() {
        // Product-aware floor plus growth and a recoverable energy buffer.
        // Preserve the growth floor even when cheap hulls use little energy;
        // observed energy-hungry products may raise it, never remove expansion.
        const float ratio=AiMax(Global::RoleSettings::Sea::EnergyPerMetal,productionEnergyPerMetal+4.0f);
        const float mi=aiEconomyMgr.metal.income;
        const float needed=mi*ratio+80.0f+AiMax(0.0f,aiEconomyMgr.energy.storage*.1f-aiEconomyMgr.energy.current)/AiMax(1.0f,Global::RoleSettings::Sea::EnergyBufferSeconds);
        const float opening=AiMin(Global::RoleSettings::Sea::TidalEnergyIncomeMinimum,AiMax(250.0f,needed));
        // Conversion is a continuing consumer. Grow one funded energy increment
        // after existing capacity can absorb it, instead of stopping at 1200 E/s.
        int pending=0;
        const float capacity=ConversionCapacity(pending);
        const float nonConversion=AiMax(0.0f,TeamEconomy::OwnEnergy(TeamEconomy::USAGE)-ai.GetTeamRulesParam("mmUse",0.0f));
        const bool metalRoom=aiEconomyMgr.metal.current<aiEconomyMgr.metal.storage*.90f;
        return metalRoom ? AiMax(opening,nonConversion+capacity+Global::RoleSettings::Sea::ConverterEnergyReserve
            +Global::RoleSettings::Sea::ConversionGrowthStep) : opening;
    }
    // Head-to-head play: pausing T1 production while the enemy navy contests
    // our water lost the sea. O(E) over the SEA snapshot, factory asks only.
    bool SeaContested() {
        const int body=aiBattle.WaterBody(Global::Map::StartPos,false);
        const int count=aiBattle.GetSeaForceCount();
        float enemy=0,cover=0;
        for (int i=0;i<count;++i) {
            if (body>=0 && aiBattle.GetSeaForceBody(i)!=body) continue;
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&(8|128))!=0) continue;
            const int contactDef=aiBattle.GetSeaForceDefId(i);
            CCircuitDef@ d=contactDef>=0 ? ai.GetCircuitDef(contactDef) : null;
            if (d is null || d.GetBuildSpeed()>0) continue;
            if ((flags&1)!=0) cover+=aiBattle.GetSeaForceCost(i); else enemy+=aiBattle.GetSeaForceCost(i);
        }
        return enemy>cover*Global::RoleSettings::Sea::TechSaveContestRatio;
    }
    int techSaveAsks=0;
    // Every TechSaveTrickle-th held ask still builds a T1 hull.
    bool TechHold() {
        if (!TechSaving() || !HoldingWater() || SeaContested()) return false;
        const int trickle=Global::RoleSettings::Sea::TechSaveTrickle;
        return trickle<=0 || (++techSaveAsks%trickle)!=0;
    }
    bool HoldingWater() {
        const int count=aiBattle.GetSeaForceCount();
        float enemy=0,cover=0;
        const int body=aiBattle.WaterBody(Global::Map::StartPos,false);
        for (int i=0;i<count;++i) {
            if (body>=0 && aiBattle.GetSeaForceBody(i)!=body) continue;
            if (MapHelpers::SqDist(aiBattle.GetSeaForcePos(i),Global::Map::StartPos)>2400.0f*2400.0f) continue;
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&(8|128))!=0) continue;
            const int contactDef=aiBattle.GetSeaForceDefId(i);
            CCircuitDef@ d=contactDef>=0 ? ai.GetCircuitDef(contactDef) : null;
            if (d !is null && d.GetBuildSpeed()>0) continue;
            if ((flags&1)!=0) cover+=aiBattle.GetSeaForceCost(i);
            else enemy+=(flags&16)!=0 ? Global::RoleSettings::Sea::UnknownSubContactMetal : aiBattle.GetSeaForceCost(i);
        }
        return enemy<=0 || cover>=enemy*Global::RoleSettings::Sea::FleetScreenRatio;
    }
    float UsefulPower(CCircuitDef@ work, float share) {
        if (work is null) return 0;
        const float m=aiEconomyMgr.metal.income*share+AiMax(0.0f,aiEconomyMgr.metal.current-committedM-admittedM)/Global::RoleSettings::Sea::WorkforceHorizon;
        const float e=aiEconomyMgr.energy.income*share+AiMax(0.0f,aiEconomyMgr.energy.current-committedE-admittedE)/Global::RoleSettings::Sea::WorkforceHorizon;
        return BuildPowerMath::Power(m,e,work.GetBuildTime(),work.costM,work.costE);
    }
    float LocalPower(CCircuitUnit@ yard) {
        IndexPower();
        float value=yard.circuitDef.GetBuildSpeed();
        const AIFloat3 p=yard.GetPos(ai.frame);
        powerCandidates.resize(0); powerSeen.deleteAll();
        for (int z=int(floor((p.z-powerReach)/512.0f));z<=int(floor((p.z+powerReach)/512.0f));++z)
            for (int x=int(floor((p.x-powerReach)/512.0f));x<=int(floor((p.x+powerReach)/512.0f));++x) {
                int cell=-1; if (!powerCellIds.get(x+":"+z,cell)) continue;
                for (uint j=0;j<powerCells[cell].ids.length();++j) powerCandidates.insertLast(powerCells[cell].ids[j]);
            }
        // Restore the original owned-ID summation order. Local queries cost
        // O(cells + K log K), not O(all ships); eligibility stays live below.
        // This function's native getters do not call script, so scratch cannot
        // alias a reentrant decision. Never cache the floating-point result.
        powerCandidates.sortAsc();
        for (uint i=0; i<powerCandidates.length(); ++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(powerCandidates[i]);
            if (u is null || u is yard || SupportedFactory(u.circuitDef) || Factory::userData[u.circuitDef.id].attr!=0
                || u.circuitDef.GetBuildSpeed()<=0 || Lifecycle::IsRetiring(u)) continue;
            if (u.circuitDef.IsMobile()) {
                if (u.GetBuildProgress()<1) continue;
                IBuilderTask@ assist=cast<IBuilderTask>(u.task);
                if (assist is null || (assist.target !is yard && assist.GetGuardTargetId()!=yard.id)) continue;
            }
            const float reach=u.circuitDef.GetBuildDistance();
            if (MapHelpers::SqDist(u.GetPos(ai.frame),p)<=reach*reach) {
                value+=u.circuitDef.GetBuildSpeed(); powerSeen.set(""+u.id,true);
            }
        }
        for (uint i=0; i<projects.length(); ++i) {
            IBuilderTask@ t=cast<IBuilderTask>(projects[i]);
            if (t is null || t.IsDead() || t.GetBuildType()!=int(Task::BuildType::NANO)) continue;
            // A just-framed turret may not be in the once-per-second census yet.
            if (t.target !is null && (powerSeen.exists(""+t.target.id) || ai.GetTeamUnit(t.target.id) is null)) continue;
            const float reach=t.buildDef.GetBuildDistance();
            if (MapHelpers::SqDist(t.GetBuildPos(),p)<=reach*reach) value+=t.buildDef.GetBuildSpeed();
        }
        if (Global::RoleSettings::Sea::VerifyPowerIndex && value!=LegacyLocalPower(yard))
            Invariants::Violation("INV-175",""+yard.id,"local factory power index differs from live scan");
        return value;
    }
    float LegacyLocalPower(CCircuitUnit@ yard) {
        float value=yard.circuitDef.GetBuildSpeed();
        const AIFloat3 p=yard.GetPos(ai.frame);
        dictionary seen;
        for (uint i=0; i<owned.length(); ++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]);
            if (u is null || u is yard || SupportedFactory(u.circuitDef) || Factory::userData[u.circuitDef.id].attr!=0
                || u.circuitDef.GetBuildSpeed()<=0 || Lifecycle::IsRetiring(u)) continue;
            if (u.circuitDef.IsMobile()) {
                if (u.GetBuildProgress()<1) continue;
                IBuilderTask@ assist=cast<IBuilderTask>(u.task);
                if (assist is null || (assist.target !is yard && assist.GetGuardTargetId()!=yard.id)) continue;
            }
            const float reach=u.circuitDef.GetBuildDistance();
            if (MapHelpers::SqDist(u.GetPos(ai.frame),p)<=reach*reach) {
                value+=u.circuitDef.GetBuildSpeed(); seen.set(""+u.id,true);
            }
        }
        for (uint i=0; i<projects.length(); ++i) {
            IBuilderTask@ t=cast<IBuilderTask>(projects[i]);
            if (t is null || t.IsDead() || t.GetBuildType()!=int(Task::BuildType::NANO)) continue;
            // A just-framed turret may not be in the once-per-second census yet.
            if (t.target !is null && (seen.exists(""+t.target.id) || ai.GetTeamUnit(t.target.id) is null)) continue;
            const float reach=t.buildDef.GetBuildDistance();
            if (MapHelpers::SqDist(t.GetBuildPos(),p)<=reach*reach) value+=t.buildDef.GetBuildSpeed();
        }
        return value;
    }
    float SupportTarget(CCircuitUnit@ yard, CCircuitDef@ work) {
        if (yard is null || work is null) return 0;
        const float fraction=SeaMath::ProductionShare(yard.circuitDef.GetBuildSpeed(),productionBasePower);
        const float share=1.0f-Global::RoleSettings::Sea::EconomyIncomeShare;
        const float horizon=AiMax(1.0f,Global::RoleSettings::Sea::WorkforceHorizon);
        const float m=(aiEconomyMgr.metal.income*share+AiMax(0.0f,aiEconomyMgr.metal.current-committedM-admittedM)/horizon)*fraction;
        const float e=(aiEconomyMgr.energy.income*share+AiMax(0.0f,aiEconomyMgr.energy.current-committedE-admittedE)/horizon)*fraction;
        return BuildPowerMath::Power(m,e,work.GetBuildTime(),work.costM,work.costE);
    }
}
