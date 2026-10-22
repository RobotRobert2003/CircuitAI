// Test-only demand and hostile reservation attempts. Never deployed.
namespace SeaBaseProbe {
    bool seeded=false;
    dictionary sent;
    int next=0;
    void Check(bool ok, const string &in what) {
        GenericHelpers::LogUtil("[BaseProbe] "+(ok ? "PASS " : "FAIL ")+what,1);
    }
    void SendSite(const string &in kind, int slot) {
        if (slot<0 || sent.exists(kind) || aiTerrainMgr.GetReservationState(slot)!=0) return;
        const AIFloat3 p=aiTerrainMgr.GetReservationPos(slot);
        const string role=Team::Roster::RoleName(Global::AISettings::Role);
        sent.set(kind,true);
        AiSendMessage("baseprobe|"+role+"|"+kind+"|"+p.x+"|"+p.z+"|"+ai.teamId);
        GenericHelpers::LogUtil("[BaseProbe] exported "+role+" "+kind+" team="+ai.teamId,1);
    }
    void Message(const string &in msg) {
        if (msg.substr(0,10)!="baseprobe|") return;
        array<string>@ p=msg.split("|"); if (p.length()!=6 || parseInt(p[5])==ai.teamId) return;
        CCircuitDef@ wall=ai.GetCircuitDef("armdrag");
        const AIFloat3 at(parseFloat(p[3]),0,parseFloat(p[4]));
        const bool blocked=aiTerrainMgr.IsAllyLayoutBlocked(wall,at,0);
        const int attempted=aiTerrainMgr.ReservePersistentBuilding(wall,at,0);
        Check(blocked && attempted<0,p[1]+"->"+Team::Roster::RoleName(Global::AISettings::Role)+" "+p[2]+" excluded");
        if (attempted>=0) aiTerrainMgr.ReleasePersistentBuilding(attempted);
    }
    void Tick() {
        if (ai.frame<20*SECOND || ai.frame<next) return;
        next=ai.frame+SECOND;
        if (SUPPLIED && !seeded && Global::AISettings::Role==AiRole::SEA) {
            const string side=Global::AISettings::Side;
            SeaEconomy::Tick();
            if (SeaEconomy::productionFactories.length()==0) return;
            CCircuitUnit@ opening=ai.GetTeamUnit(SeaEconomy::productionFactories[0]);
            if (opening is null) return;
            const AIFloat3 p=opening.GetPos(ai.frame);
            const AIFloat3 crew=LayoutHelpers::Offset(p,aiTerrainMgr.GetBuildingFacing(opening),0,300);
            seeded=true;
            WidgetLink::Send("baseprobe","give|"+SeaEconomy::Constructor(side,false)+"|"+crew.x+"|"+crew.z+"|5");
            WidgetLink::Send("baseprobe","give|"+SeaEconomy::Constructor(side,true)+"|"+crew.x+"|"+crew.z+"|2");
            ai.GetCircuitDef(UnitHelpers::GetT1ShipyardForSide(side)).maxThisUnit=20;
            ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(side)).maxThisUnit=20;
            ai.GetCircuitDef(UnitHelpers::GetNavalFusionNameForSide(side)).maxThisUnit=20;
        }
        if (ai.frame<90*SECOND) return;
        if (Global::AISettings::Role==AiRole::SEA) {
            for (uint i=0;i<SeaLayout::patches.length();++i) {
                SeaLayout::Patch@ patch=SeaLayout::patches[i];
                const string key="patch"+i;
                if (!patch.active || patch.slots.length()<48 || sent.exists(key)) continue;
                sent.set(key,true);
                CCircuitDef@ d=ai.GetCircuitDef(patch.name);
                const float hx=float(d.GetFootprintX())*16.0f*3.0f, hz=float(d.GetFootprintZ())*16.0f*4.0f;
                WidgetLink::Send("baseprobe","claim|"+patch.centre.x+"|"+patch.centre.z+"|"
                    +(patch.facing%2==0 ? hx : hz)+"|"+(patch.facing%2==0 ? hz : hx));
            }
            for (uint i=0;i<SeaEcoLayout::blocks.length();++i) SendSite("economy",SeaEcoLayout::blocks[i].fusion);
            for (uint i=0;i<SeaLayout::patches.length();++i)
                for (uint j=0;j<SeaLayout::patches[i].slots.length();++j) SendSite("tidal",SeaLayout::patches[i].slots[j]);
            if (!sent.exists("factory")) {
                SeaLayout::Berth@ b=null;
                for (uint i=0;i<SeaLayout::berths.length();++i) if (!SeaLayout::berths[i].active) { @b=SeaLayout::berths[i]; break; }
                if (b is null) @b=SeaLayout::Add(UnitHelpers::GetT2ShipyardForSide(Global::AISettings::Side),SeaEcoLayout::Harbor());
                SeaLayout::Search(b); SendSite("factory",b.slot);
            }
        } else if (Global::AISettings::Role==AiRole::AIR) {
            for (uint i=0;i<AirLayout::bays.length();++i) SendSite("factory",AirLayout::bays[i].slot);
            for (uint i=0;i<AirEcoLayout::modules.length();++i)
                if (AirEcoLayout::modules[i].slots.length()>0) SendSite("economy",AirEcoLayout::modules[i].slots[0]);
        } else if (Global::AISettings::Role==AiRole::TECH) {
            for (uint i=0;i<TechFactories::clusters.length();++i) SendSite("factory",TechFactories::clusters[i].labRes);
            SendSite("economy",aiTerrainMgr.NextSlotAny(Layout::nanoGroup,Global::Map::StartPos));
        }
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u) {
        if (!seeded) return SeaBuild::LegacyTask(u);
        if (UnitHelpers::IsCommander(u.circuitDef)) return SeaBuild::Wait();
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) return current;
        SeaEconomy::Tick(); SeaLayout::RefreshGeometry();
        if (!u.circuitDef.IsMobile()) return SeaBuild::Assist(u);
        IUnitTask@ t=null;
        const string side=Global::AISettings::Side;
        const array<string> names={UnitHelpers::GetTidalNameForSide(side),UnitHelpers::GetNavalEnergyConverterNameForSide(side),
            UnitHelpers::GetNavalFusionNameForSide(side),UnitHelpers::GetAdvNavalEnergyConverterNameForSide(side)};
        // Exercise a later yard after real economy exists, without making this
        // placement fixture depend on capital-energy completion/assist policy.
        CCircuitDef@ yard=ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(side));
        if (SeaEconomy::Number(names[0],true)>=6 && SeaEconomy::Have(yard)<1) {
            // The ordinary role recomputes this cap from income, independently
            // of the supplied capital. This fixture explicitly requests a yard.
            yard.maxThisUnit=20;
            @t=SeaLayout::Factory(u,yard.GetName()); if (t !is null) return t;
        }
        @t=SeaBuild::Resume(u); if (t !is null) return t;
        @t=SeaEcoLayout::Support(u); if (t !is null) return t;
        const array<int> goals={18,12,1,4};
        for (uint i=0;i<names.length();++i) {
            CCircuitDef@ d=ai.GetCircuitDef(names[i]);
            if (d !is null && u.circuitDef.CanBuild(d) && SeaEconomy::Have(d)<goals[i]) {
                @t=SeaBuild::Place(u,names[i],i==0 || i==2 ? Task::BuildType::ENERGY : Task::BuildType::CONVERT);
                if (t !is null) return t;
            }
        }
        @t=SeaBuild::Assist(u); return t is null ? SeaBuild::Wait() : t;
    }
}
