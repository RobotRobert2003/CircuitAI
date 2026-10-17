// Supplied opening: real income, banks, reservations and build tasks thereafter.
namespace AirTransitionProbe {
    bool active = false;
    bool defenceOrdered = false;
    int logFrame = -100000;
    void Check(bool ok, const string& in label) {
        GenericHelpers::LogUtil("[AirTransitionTest] " + (ok ? "PASS " : "FAIL ") + label, 1);
    }
    bool Handle(const string& in message) {
        if (message == "air-transition-finished" && ai.teamId == 0) {
            Check(AirBuild::FundedLab() is null && AirBuild::LabReserve(false)==0
                && AirBuild::LabReserve(true)==0,"completion releases reserve");
            return true;
        }
        if (message == "air-transition-progress" && ai.teamId == 0) {
            IBuilderTask@ lab=AirBuild::FundedLab();
            if (lab is null || lab.GetUnits().length()==0) { Check(false,"started project survives recovery"); return true; }
            CCircuitUnit@ owner=lab.GetUnits()[0];
            const bool recovery=AirEconomy::recovery;
            const int frame=AirEconomy::sampleFrame;
            AirEconomy::sampleFrame=ai.frame; AirEconomy::recovery=true;
            Check(AirRules::MakeTask(owner) is lab && !lab.IsDead(),"started project survives recovery");
            AirEconomy::recovery=recovery; AirEconomy::sampleFrame=frame;
            return true;
        }
        if (message != "air-transition-init" || ai.teamId != 0) return false;
        Global::RoleSettings::Air::TransitionEarliestSeconds = 0;
        Global::RoleSettings::Air::OpeningNanoCount = 0;
        Global::RoleSettings::Air::OpeningAirConstructors = 1;
        aiTerrainMgr.SetLayoutInt("air.screen.established", 1);
        aiTerrainMgr.SetLayoutInt("air.scout.finished", 1);
        AirEconomy::Tick();
        CCircuitUnit@ worker;
        array<Id>@ owned = ai.GetOwnedUnitIds();
        for (uint i=0; i<owned.length(); ++i) {
            CCircuitUnit@ unit = ai.GetTeamUnit(owned[i]);
            if (unit !is null && AirBuild::EconomyAircraft(unit)) { @worker=unit; break; }
        }
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
        if (worker is null || lab is null) { Check(false,"fixture loaded"); return true; }
        Check(true,"fixture loaded");
        const bool enabled=Global::RoleSettings::Air::FundFirstLab;
        const float oldM=AirWorkforce::incomeM, oldE=AirWorkforce::incomeE;
        const float oldUsageM=AirWorkforce::usageM, oldUsageE=AirWorkforce::usageE;
        const bool oldRecovery=AirEconomy::recovery;
        const int oldT2=AirEconomy::t2;
        array<float> samples=AirWorkforce::metalRates;
        AirWorkforce::metalRates.resize(10);
        AirWorkforce::incomeM=13; AirWorkforce::incomeE=450;
        AirWorkforce::usageM=0; AirWorkforce::usageE=0; AirEconomy::recovery=false;
        GenericHelpers::LogUtil("[AirTransitionTest] inputs bank="+int(TeamEconomy::OwnMetal(TeamEconomy::CURRENT))
            +" cost="+int(lab.costM)+" work="+int(lab.GetBuildTime())+" power="+int(worker.circuitDef.GetBuildSpeed()),1);
        Check(AirBuild::FirstLabFunded(worker,lab)==(enabled && __INITIAL_FUNDING__),"profile admission");
        Global::RoleSettings::Air::FundFirstLab=false;
        Check(!AirBuild::FirstLabFunded(worker,lab),"legacy gate");
        Global::RoleSettings::Air::FundFirstLab=enabled;
        AirEconomy::recovery=true;
        Check(!AirBuild::FirstLabFunded(worker,lab),"recovery gate");
        AirEconomy::recovery=false; AirWorkforce::incomeE=0;
        Check(!AirBuild::FirstLabFunded(worker,lab),"wind drop");
        AirWorkforce::incomeE=450; AirWorkforce::incomeM=0;
        Check(!AirBuild::FirstLabFunded(worker,lab),"future gifts excluded");
        AirWorkforce::incomeM=13; AirEconomy::t2=1;
        Check(!AirBuild::FirstLabFunded(worker,lab),"later lab gate");
        AirEconomy::t2=oldT2; AirWorkforce::incomeM=oldM; AirWorkforce::incomeE=oldE;
        AirWorkforce::usageM=oldUsageM; AirWorkforce::usageE=oldUsageE;
        AirEconomy::recovery=oldRecovery; AirWorkforce::metalRates=samples;
        if (enabled && __INITIAL_FUNDING__) {
            IUnitTask@ trial=AirBuild::Factory(worker,true);
            if (trial !is null) {
                AirBuild::Record(trial,"fixture.admission",worker);
                Check(AirBuild::LabReserve(false)>0 && AirBuild::LabReserve(true)>0
                    && AirBuild::Factory(worker,true) is null,"single funded obligation");
                AirBuild::CancelUnstarted(cast<IBuilderTask>(trial));
                Check(AirBuild::FundedLab() is null && AirBuild::LabReserve(false)==0,"cancel releases reserve");
            } else Check(false,"single funded obligation");
        }
        active=true;
        return true;
    }
    IUnitTask@ BuilderTask(CCircuitUnit@ worker) {
        if (!active || ai.teamId!=0 || !AirBuild::EconomyAircraft(worker))
            return aiBuilderMgr.Enqueue(TaskB::Wait(3*SECOND));
        if (ai.frame-logFrame>=10*SECOND) {
            logFrame=ai.frame;
            CCircuitDef@ lab=ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
            GenericHelpers::LogUtil("[AirTransitionTest] gate can="+AirBuild::Can(worker,lab)
                +" income="+AirEconomy::Transition(lab)+" funded="+AirBuild::FirstLabFunded(worker,lab)
                +" busy="+AirBuild::Busy(lab,Task::BuildType::FACTORY)+" support="+AirEconomy::ExistingT2SupportReady(),1);
        }
        return AirRules::MakeTask(worker);
    }
    IUnitTask@ FactoryTask(CCircuitUnit@ plant) {
        if (active && ai.teamId==0 && AirBuild::FundedLab() !is null && !defenceOrdered
            && UnitHelpers::IsT1AircraftPlant(plant.circuitDef.GetName())) {
            IUnitTask@ task=AirProduction::MakeTask(plant);
            IBuilderTask@ recruit=cast<IBuilderTask>(task);
            const bool fighter=recruit !is null && recruit.buildDef !is null
                && recruit.buildDef.GetName()==AirEconomy::Fighter(false,Global::AISettings::Side);
            Check(fighter,"defence during funded lab");
            defenceOrdered=true;
            return task;
        }
        return aiFactoryMgr.Enqueue(TaskS::Wait(false,3*SECOND));
    }
}
