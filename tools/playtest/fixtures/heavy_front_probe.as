namespace HeavyFrontProbe {
    bool active=false;
    bool Handle(const string& in message) {
        array<string>@ f=message.split("|");
        if (f.length()<2 || f[0]!="heavy-front") return false;
        if (f[1]=="setup") {
            active=true;
            if (!Global::Map::MapResolved) Setup::setupMap(ai.teamId==0?AIFloat3(1000,0,4000)
                :(ai.teamId==1?AIFloat3(1500,0,6000):AIFloat3(7000,0,4000)));
            if (ai.teamId==0) Commands::SwitchRole("TECH");
            if (Builder::commander !is null) {
                aiBuilderMgr.AssignTask(Builder::commander,aiBuilderMgr.Enqueue(TaskB::Wait(15*MINUTE)));
                Builder::commander.CmdStop();
            }
            if (ai.teamId==0) {
                Global::RoleSettings::Tech::StrategyMask=uint(1)<<uint(Strategy::T2_RUSH);
                Global::RoleSettings::Tech::PlanCombatGate=0;
                Global::RoleSettings::Tech::PlanT3RushCombatGate=0;
                Spam::focus=AIFloat3(7000,0,4000); Spam::hasFocus=true; Spam::hasFront=false;
                GenericHelpers::LogUtil("[HeavyFrontTest] policy="+Global::RoleSettings::Tech::HeavyDeliveryFrontEnabled,1);
                array<AIFloat3> test={AIFloat3(0,0,0),AIFloat3(300,0,0),AIFloat3(300,0,400)};
                const AIFloat3 p=DeliveryFrontMath::At(test,500);
                GenericHelpers::LogUtil("[HeavyFrontTest] "+((DeliveryFrontMath::Length(test)==700 && p.x==300 && p.z==200)?"PASS":"FAIL")+" geometry",1);
            }
        } else if (f[1]=="lane" && ai.teamId==0) {
            const int id=parseInt(f[2]);
            Spam::spreadByFactory.set(""+id,float(parseInt(f[3])));
            if (Spam::RouteFor(ai.GetTeamUnit(id)) is null) GenericHelpers::LogUtil("[HeavyFrontTest] FAIL route",1);
        } else if (f[1]=="cargo" && ai.teamId==0) {
            const int id=parseInt(f[2]);
            CCircuitUnit@ cargo=ai.GetTeamUnit(id);
            CFerryTask@ carrier=Team::Ferry::TaskOf(ai.GetTeamUnit(Team::HeavyTransport::Available(cargo)));
            array<AIFloat3> invalid={AIFloat3(-1,0,4000),AIFloat3(4400,0,4000)};
            const bool rejected=carrier !is null && !carrier.SetCargoRoute(id,invalid,1.0f,0.5f,192.0f)
                && carrier.GetState()==0 && carrier.GetCargoId()<0;
            GenericHelpers::LogUtil("[HeavyFrontTest] "+(rejected?"PASS":"FAIL")+" admission",1);
            const int index=TechHeavyRush::completed;
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"gift."+index,id);
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"sent."+index,0);
            TechHeavyDelivery::Delivery@ delivery=TechHeavyDelivery::Record(index,id);
            ++TechHeavyRush::completed;
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"completed",TechHeavyRush::completed);
            array<AIFloat3> lane=Spam::DeliveryLane();
            GenericHelpers::LogUtil("[HeavyFrontTest] "+(lane.length()>1 && abs(lane[lane.length()-1].z-4000)<2?"PASS":"FAIL")+" central lane",1);
            if (f.length()>3 && f[3]=="turns") {
                array<AIFloat3> route; AIFloat3 destination;
                if (!TechDeliveryFront::Plan(cargo,route,destination)) {
                    GenericHelpers::LogUtil("[HeavyFrontTest] FAIL supplied turns planning",1); return true;
                }
                route={AIFloat3(1800,0,2800),AIFloat3(4400,0,2800),destination};
                const int aircraft=Team::HeavyTransport::Available(cargo);
                if (!carrier.SetCargoRoute(id,route,Global::Ferry::DropSurfaceThreat,
                    Global::RoleSettings::Tech::HeavyDeliveryAirThreat,Global::RoleSettings::Tech::HeavyDeliveryAirPadding)) {
                    GenericHelpers::LogUtil("[HeavyFrontTest] FAIL supplied turns admission",1); return true;
                }
                delivery.frontRoute=route;delivery.frontDestination=destination;
                delivery.carrier=aircraft;
                delivery.recipient=TechHeavyRush::Recipient();
                aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey+"carrier."+index,aircraft);
            }
        }
        return true;
    }
}
