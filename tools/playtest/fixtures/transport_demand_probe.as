namespace TransportDemandProbe {
    bool active = false;
    void Check(bool ok, const string& in label) {
        GenericHelpers::LogUtil("[TransportDemandTest] " + (ok ? "PASS " : "FAIL ") + label, 1);
    }
    void Configure() {
        Global::RoleSettings::Tech::StrategyMask = 0;
        Global::RoleSettings::Tech::EndgamePlan = "auto";
        Global::RoleSettings::Tech::HeavyTransportAdditionalIncomeStart = 100000.f;
        Global::Ferry::RequestMinMetalIncome = 0.f;
        Global::Ferry::RequestCooldownSeconds = 10.f;
        TechHeavyRush::targetCount = 3;
        TechHeavyRush::completed = 0;
        TechHeavyRush::engineUnitLimit = 100;
        active = true;
    }
    bool Handle(const string& in message) {
        if (message == "transport-demand-init") {
            Commands::SwitchRole(ai.teamId==0 ? "TECH" : (ai.teamId==1 ? "AIR" : "FRONT"));
            Configure();
            if (ai.teamId == 1) {
                Team::Ferry::HandleMessage("barbferry|req|1000|4000|light", 0);
                Team::Ferry::HandleMessage("barbferry|req|1000|4000|heavy", 0);
                Team::Ferry::HandleMessage("barbferry|cancel|heavy", 0);
                Check(Team::Ferry::requestPending && !Team::Ferry::requestHeavy
                    && Team::Ferry::QueuedRequest(0,true)<0, "cancel keeps light");
                Team::Ferry::requestPending = false;
                Team::Ferry::HandleMessage("barbferry|req|1000|4000|heavy", 0);
                Team::Ferry::HandleMessage("barbferry|req|1000|4000|light", 0);
                const string heavy = Team::Ferry::TransportForSide(Global::AISettings::Side);
                Team::Ferry::_OpenSlot(heavy);
                Team::Ferry::HandleMessage("barbferry|cancel|heavy", 0);
                Check(Team::Ferry::requestPending && !Team::Ferry::requestHeavy
                    && ai.GetCircuitDef(heavy).maxThisUnit==0, "cancel closes heavy slot");
                // Clear the fixture's synthetic light; the requester must send
                // its real directed request and AIR must physically build it.
                Team::Ferry::requestPending = false;
                Team::Ferry::requestTeam = -1;
            }
            if (ai.teamId != 0) return true;
            bool passed = true;
            for (uint mask=0; mask<16; ++mask) {
                Global::RoleSettings::Tech::StrategyMask = mask;
                for (uint i=0; i<Global::Ferry::HeavyTransportDefs.length(); ++i) {
                    CCircuitDef@ carrier = ai.GetCircuitDef(Global::Ferry::HeavyTransportDefs[i]);
                    passed = (TechTransport::WantsCarrier(carrier) == StrategyUtil::Has(mask,Strategy::T2_RUSH)) && passed;
                }
            }
            Check(passed, "strategy matrix");
            Global::RoleSettings::Tech::StrategyMask = StrategyUtil::Bit(Strategy::T2_RUSH);
            CCircuitDef@ carrier = ai.GetCircuitDef(Team::HeavyTransport::OwnDefinition());
            string original;
            Global::RoleSettings::Tech::HeavyRushUnits.get(Global::AISettings::Side,original);
            Global::RoleSettings::Tech::HeavyRushUnits.set(Global::AISettings::Side,"armbanth");
            Check(!TechTransport::WantsCarrier(carrier),"uncarryable T2 override");
            Global::RoleSettings::Tech::HeavyRushUnits.set(Global::AISettings::Side,original);
            TechHeavyRush::engineUnitLimit=0;
            Check(!TechTransport::WantsCarrier(carrier),"restricted cargo");
            TechHeavyRush::engineUnitLimit=100;
            TechHeavyRush::completed=3;
            Check(!TechTransport::WantsCarrier(carrier),"finished rush");
            TechHeavyRush::completed=0;
            Global::RoleSettings::Tech::StrategyMask=0;
            // A persisted high-water mark from the old policy must not survive.
            Team::HeavyTransport::reconstructed=false;
            aiTerrainMgr.SetLayoutInt(Team::HeavyTransport::TargetKey,7);
            Team::HeavyTransport::Update();
            Check(Team::HeavyTransport::desired==0,"stale target cleared");
            return true;
        }
        array<string>@ fields=message.split("|");
        if (fields.length()==2 && fields[0]=="transport-demand-ledger" && ai.teamId==0) {
            const int id=parseInt(fields[1]);
            CCircuitUnit@ cargo=ai.GetTeamUnit(id);
            if (cargo is null) { Check(false,"delivery ledger"); return true; }
            Global::RoleSettings::Tech::StrategyMask=StrategyUtil::Bit(Strategy::T2_RUSH);
            TechHeavyRush::completed=TechHeavyRush::targetCount;
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"gift.0",id);
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"sent.0",0);
            CCircuitDef@ carrier=ai.GetCircuitDef(Team::HeavyTransport::OwnDefinition());
            bool passed=TechTransport::WantsCarrier(carrier); // persisted gift before record reconstruction
            TechHeavyDelivery::Delivery@ delivery=TechHeavyDelivery::Record(0,id);
            passed=TechTransport::WantsCarrier(carrier) && passed;
            delivery.landed=true;
            passed=!TechTransport::WantsCarrier(carrier) && passed;
            delivery.landed=false;
            delivery.removed=true;
            passed=!TechTransport::WantsCarrier(carrier) && passed;
            delivery.removed=false;
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"sent.0",1);
            passed=!TechTransport::WantsCarrier(carrier) && passed;
            Check(passed,"delivery ledger");
            TechHeavyDelivery::deliveries.delete(""+id);
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"gift.0",-1);
            TechHeavyRush::completed=0;
            Global::RoleSettings::Tech::StrategyMask=0;
            return true;
        }
        if (message == "transport-demand-rush" && ai.teamId==0) {
            Global::RoleSettings::Tech::StrategyMask = StrategyUtil::Bit(Strategy::T2_RUSH);
            Team::HeavyTransport::Update();
            Check(Team::HeavyTransport::desired==1,"rush target");
            return true;
        }
        if (message == "transport-demand-stop" && ai.teamId==0) {
            Global::RoleSettings::Tech::StrategyMask=0;
            Team::HeavyTransport::Update();
            Check(Team::HeavyTransport::desired==0,"rush target released");
            return true;
        }
        return false;
    }
    IUnitTask@ FactoryTask(CCircuitUnit@ unit) {
        if (!active) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));
        IUnitTask@ result = Team::Ferry::FactoryMakeTask(unit);
        if (result is null) @result = Team::HeavyTransport::FactoryTask(unit);
        return result is null ? aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND)) : result;
    }
}
