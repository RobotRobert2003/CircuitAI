// Supplied acceptance fixture only. Never included by production scripts.
namespace SeaHarborProbe {
    int blockedSlot=-1, originalYard=-1;
    bool blockSent=false, replanned=false, seeded=false, adopted=false, held=false;
    bool retired=false, reclaimed=false;
    void Tick() {
        if (ai.teamId!=0 || !SeaLayout::Active()) return;
        if (!adopted && ai.frame>60*SECOND && SeaLayout::berths.length()>=3) {
            const int first=SeaLayout::berths[0].slot;
            SeaLayout::Init(Global::AISettings::Side);
            adopted=true;
            GenericHelpers::LogUtil("[SeaProbe] "+(SeaLayout::berths[0].slot==first ? "PASS" : "FAIL")+" named-state adoption",1);
        }
        if (!blockSent && ai.frame>75*SECOND) {
            for (uint i=0; i<SeaLayout::berths.length(); ++i) {
                SeaLayout::Berth@ b=SeaLayout::berths[i];
                if (b.slot>=0 && !b.active && UnitHelpers::IsT2Shipyard(b.name)) {
                    blockSent=true; blockedSlot=b.slot;
                    WidgetLink::Send("seaprobe","give|armtide|"+b.centre.x+"|"+b.centre.z+"|1");
                    break;
                }
            }
        }
        if (blockSent && !replanned && ai.frame>95*SECOND) {
            bool old=false, replacement=false;
            for (uint i=0; i<SeaLayout::berths.length(); ++i) {
                SeaLayout::Berth@ b=SeaLayout::berths[i];
                if (b.slot==blockedSlot) old=true;
                if (b.slot>=0 && b.slot!=blockedSlot && UnitHelpers::IsT2Shipyard(b.name)) replacement=true;
            }
            if (!old && replacement) { replanned=true; GenericHelpers::LogUtil("[SeaProbe] PASS physical blocker replanned unused berth",1); }
        }
        if (!seeded && ai.frame>120*SECOND && SeaLayout::berths.length()>0 && SeaLayout::berths[0].unit>=0) {
            seeded=true; originalYard=SeaLayout::berths[0].unit;
            WidgetLink::Send("seaprobe","watchold|"+originalYard);
            const AIFloat3 start=SeaLayout::berths[0].centre;
            WidgetLink::Send("seaprobe","give|armuwfus|600|4700|6");
            WidgetLink::Send("seaprobe","give|armuwmmm|850|4850|12");
            WidgetLink::Send("seaprobe","give|armuwms|650|4900|4");
            WidgetLink::Send("seaprobe","give|armuwes|950|4950|4");
            WidgetLink::Send("seaprobe","give|armacsub|"+start.x+"|"+(start.z+250)+"|4");
            WidgetLink::Send("seaprobe","give|armcrus|"+(start.x+1800)+"|"+start.z+"|8");
            GenericHelpers::LogUtil("[SeaProbe] supplied harbor case old="+originalYard,1);
        }
        if (seeded && ai.frame<150*SECOND) {
            for (uint i=0; i<SeaEconomy::owned.length(); ++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]);
                if (u !is null && u.circuitDef.GetName()=="armcrus" && u.GetProducerId()<0
                    && (u.task is null || u.task.GetType()!=int(Task::Type::PLAYER))) { ai.UnitControl(u,false); u.CmdStop(); }
            }
            held=true;
        }
        if (seeded && ai.frame%(30*SECOND)<SECOND) {
            for (uint b=0; b<SeaLayout::berths.length(); ++b) {
                SeaLayout::Berth@ berth=SeaLayout::berths[b]; if (berth.oldUnit<0) continue;
                CCircuitDef@ d=ai.GetCircuitDef(berth.name);
                GenericHelpers::LogUtil("[SeaProbe] replacement unit="+berth.unit+" active="+berth.active+" slot="+berth.slot
                    +" state="+aiTerrainMgr.GetReservationState(berth.slot)+" available="+d.IsAvailable(ai.frame)+" count="+d.count,1);
                for (uint w=0; w<SeaEconomy::owned.length(); ++w) {
                    CCircuitUnit@ worker=ai.GetTeamUnit(SeaEconomy::owned[w]);
                    if (worker is null || !SeaConstructor::IsT2(worker.circuitDef)) continue;
                    GenericHelpers::LogUtil("[SeaProbe] worker="+worker.id+" canBuild="+worker.circuitDef.CanBuild(d)
                        +" reachable="+aiTerrainMgr.CanReachAt(worker,berth.centre,worker.circuitDef.GetBuildDistance()),1); break;
                }
            }
            GenericHelpers::LogUtil("[SeaProbe] forward stable="+SeaFactories::stableSince+" site="+SeaFactories::forwardSite.x+","+SeaFactories::forwardSite.z
                +" next="+SeaFactories::nextForward+" bankE="+aiEconomyMgr.energy.current+" committedE="+SeaEconomy::committedE,1);
            for (uint i=0; i<SeaEconomy::owned.length(); ++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]);
                if (u is null || u.circuitDef.GetName()!="armcrus") continue;
                const AIFloat3 p=u.GetPos(ai.frame);
                GenericHelpers::LogUtil("[SeaProbe] cover pos="+p.x+","+p.z+" body="+aiBattle.WaterBody(p,false)
                    +" power="+u.circuitDef.GetWaterThreat()+"/"+u.circuitDef.GetSurfThreat()+" safe="+SeaFactories::Safe(p)
                    +" threats="+aiBattle.AmphThreat(p)+"/"+aiBattle.AirThreat(p)+" bp="+SeaEconomy::mobilePower,1);
                break;
            }
        }
        if (!retired && originalYard>=0) {
            CCircuitUnit@ old=ai.GetTeamUnit(originalYard);
            if (old !is null && Lifecycle::IsRetiring(old)) {
                retired=true;
                GenericHelpers::LogUtil("[SeaProbe] PASS original yard entered retirement",1);
            }
        }
        if (retired && !reclaimed && ai.GetTeamUnit(originalYard) is null) {
            reclaimed=true; GenericHelpers::LogUtil("[SeaProbe] PASS original yard physically removed",1);
        }
    }
}
