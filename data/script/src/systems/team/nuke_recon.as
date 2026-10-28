// TECH's first completed silo requests one allied AIR reconnaissance package.
// The external AI ABI has a stockpile count but no fractional build progress.
// Use the owner's nominal half-stockpile timer from completion: 60s Armada,
// 90s Cortex/Legion (BAR stockpiletime=120/180/180, firing reloadtime=30).
// Resource starvation can delay the actual missile beyond this nominal point.
// The request carries the silo's latest aim (owner 2026-10-28) and AIR flies it
// at once, T1 scouts only before its T2 plant (AirScoutSweep::Urgent).
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
        const AIFloat3 at=aiMilitaryMgr.GetNuclearAim();
        const string where=(at.x<0.0f) ? "" : "|"+int(at.x)+"|"+int(at.z)+"|"+int(aiMilitaryMgr.GetNuclearAimRadius());
        AiSendMessage("nukerecon|first"+where,provider);
        sent=true;
        GenericHelpers::LogUtil("[TECH][NukeRecon] nominal half stockpile silo="+siloId+" AIR="+provider+" seconds="+halfSeconds
            +(at.x<0.0f ? " aim=none" : " aim=("+int(at.x)+","+int(at.z)+")"),1);
    }
    bool Handle(const string &in msg,int fromTeamId) {
        if (msg.findFirst("nukerecon|first")!=0) return false;
        Team::Roster::Entry@ sender=Team::Roster::Get(fromTeamId);
        if (sender !is null && sender.role==AiRole::TECH && AirEconomy::Active()) {
            // nukerecon|first[|x|z|spread]: without an aim the package sweeps the lanes
            array<string>@ parts=msg.split("|");
            AIFloat3 at(-1,0,-1);
            float spread=0.0f;
            if (parts.length()>=5) { at=AIFloat3(parseFloat(parts[2]),0,parseFloat(parts[3])); spread=parseFloat(parts[4]); }
            AirScoutSweep::Urgent(at,spread);
            GenericHelpers::LogUtil("[AIR][ScoutSweep] nuke request TECH="+fromTeamId+" at=("+int(at.x)+","+int(at.z)+") spread="+int(spread),1);
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
