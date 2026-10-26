// A finished lolcannon (FRONT or TECH, systems/construction/lolcannon.as) asks the
// allied AIR for one scout sweep (owner, 2026-10-26): the counts travel with the
// request and replace AIR's ScoutSweep*Count for that one package.
namespace LolCannonRecon {
    const string PREFIX = "lolcannon|recon|";
    void Send(int t1, int radar) {
        array<Team::Roster::Entry@>@ allies=Team::Roster::WithRole(AiRole::AIR);
        int provider=-1;
        for(uint i=0;i<allies.length();++i) if(provider<0 || allies[i].teamId<provider) provider=allies[i].teamId;
        if (provider<0) { GenericHelpers::LogUtil("[LolCannon] no allied AIR to fly the scout sweep",1); return; }
        AiSendMessage(PREFIX+t1+"|"+radar,provider);
        GenericHelpers::LogUtil("[LolCannon] scout sweep asked of AIR="+provider+": "+t1+" T1 scouts, "+radar+" radar/sonar planes",1);
    }
    bool Handle(const string &in msg,int fromTeamId) {
        if (msg.findFirst(PREFIX)!=0) return false;
        array<string>@ parts=msg.split("|");
        Team::Roster::Entry@ sender=Team::Roster::Get(fromTeamId);
        if (parts.length()<4 || sender is null || (sender.role!=AiRole::TECH && sender.role!=AiRole::FRONT)) return true;
        if (AirEconomy::Active()) {
            AirScoutSweep::Request(parseInt(parts[2]),parseInt(parts[3]));
            GenericHelpers::LogUtil("[AIR][ScoutSweep] lolcannon request from "+fromTeamId+": "+parts[2]+" T1, "+parts[3]+" radar",1);
        }
        return true;
    }
}
