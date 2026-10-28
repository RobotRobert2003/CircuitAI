// TECH's first completed silo requests one allied AIR reconnaissance package.
// The external AI ABI has a stockpile count but no fractional build progress.
// Use the owner's nominal half-stockpile timer from completion: 60s Armada,
// 90s Cortex/Legion (BAR stockpiletime=120/180/180, firing reloadtime=30).
// Resource starvation can delay the actual missile beyond this nominal point.
namespace NukeRecon {
    int siloId=-1, completed=-1, checked=-SECOND;
    bool sent=false;
    void Finished(CCircuitUnit@ u) {
        if (sent || (siloId>=0 && ai.GetTeamUnit(siloId) !is null)
            || Global::AISettings::Role!=AiRole::TECH || u is null || u.GetBuildProgress()<1.0f) return;
        const string name=u.circuitDef.GetName();
        if (name!="armsilo" && name!="corsilo" && name!="legsilo") return;
        siloId=u.id; completed=ai.frame;
    }
    void Tick() {
        if (sent || Global::AISettings::Role!=AiRole::TECH || ai.frame-checked<SECOND) return;
        checked=ai.frame;
        CCircuitUnit@ silo=ai.GetTeamUnit(siloId);
        if (silo is null) { siloId=-1; completed=-1; return; }
        const int halfSeconds=silo.circuitDef.GetName()=="armsilo" ? 60 : 90;
        if (ai.frame-completed<halfSeconds*SECOND && silo.GetStockpile()==0) return;
        array<Team::Roster::Entry@>@ allies=Team::Roster::WithRole(AiRole::AIR);
        int provider=-1;
        for(uint i=0;i<allies.length();++i) if(provider<0 || allies[i].teamId<provider) provider=allies[i].teamId;
        if (provider<0) return; // late AIR announcements retry, no broadcast storm
        AiSendMessage("nukerecon|first",provider);
        sent=true;
        GenericHelpers::LogUtil("[TECH][NukeRecon] nominal half stockpile silo="+siloId+" AIR="+provider+" seconds="+halfSeconds,1);
    }
    bool Handle(const string &in msg,int fromTeamId) {
        if (msg!="nukerecon|first") return false;
        Team::Roster::Entry@ sender=Team::Roster::Get(fromTeamId);
        if (sender !is null && sender.role==AiRole::TECH && AirEconomy::Active()) {
            AirScoutSweep::Request();
            GenericHelpers::LogUtil("[AIR][ScoutSweep] nuke request TECH="+fromTeamId,1);
        }
        return true;
    }
}

// Overnuke scouting (owner 2026-10-28). With 3+ silos every silo fires at one
// target (CSuperTask::SelectNuclearTarget); every 10th launch at it the engine
// raises its scout count and we ask AIR for the lolcannon-style package: each
// plane to its own point spread over the blast, not all onto the centre
// (LolCannonRecon::Route). Any role that owns silos asks; AIR flies it.
namespace OvernukeRecon {
    const int T1Scouts = 10, RadarScouts = 3;
    int seen = 0, checked = -SECOND;
    void Tick() {
        if (ai.frame - checked < SECOND) return;
        checked = ai.frame;
        const int scouts = aiMilitaryMgr.GetOvernukeScouts();
        if (scouts <= seen) return;
        seen = scouts;
        const AIFloat3 at = aiMilitaryMgr.GetOvernukePos();
        if (at.x < 0.0f) return;
        LolCannonRecon::Send(T1Scouts, RadarScouts, at, aiMilitaryMgr.GetOvernukeRadius(), "overnuke");
    }
}
