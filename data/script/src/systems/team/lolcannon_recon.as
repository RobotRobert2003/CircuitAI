// Scouting for the lolcannons (owner 2026-10-26, targeted 2026-10-27). A
// FRONT or TECH cannon (systems/construction/lolcannon.as) asks for a scout
// package at its first strike's area, then at its highest-rated area every
// ReScoutSeconds, so the roster learns which remembered targets are gone. The
// allied AIR flies it (systems/air/air_scout_sweep.as); with no AIR on the map
// the request goes to TECH, which builds and flies it itself
// (systems/construction/lolcannon_scouts.as). The counts travel with the
// request and replace AIR's ScoutSweep*Count for that one package.
namespace LolCannonRecon {
    const string PREFIX = "lolcannon|recon|";

    int Provider(AiRole role) {
        array<Team::Roster::Entry@>@ allies=Team::Roster::WithRole(role);
        int provider=-1;
        for(uint i=0;i<allies.length();++i) if(provider<0 || allies[i].teamId<provider) provider=allies[i].teamId;
        return provider;
    }

    // the package's make-up and where: at (x, z), spread over `spread` round it
    void Send(int t1, int radar, const AIFloat3 &in at, float spread, const string &in why) {
        int provider=Provider(AiRole::AIR);
        string who="AIR";
        if (provider<0) {
            // no AIR: TECH builds them, ourselves when we are TECH (the roster may hold allies only)
            who="TECH";
            provider=(Global::AISettings::Role==AiRole::TECH) ? ai.teamId : Provider(AiRole::TECH);
        }
        if (provider<0) { GenericHelpers::LogUtil("[LolCannon] no allied AIR or TECH to scout ("+why+")",1); return; }
        const string msg=PREFIX+t1+"|"+radar+"|"+int(at.x)+"|"+int(at.z)+"|"+int(spread);
        GenericHelpers::LogUtil("[LolCannon] scouts asked of "+who+"="+provider+" ("+why+"): "+t1+" T1 scouts, "+radar
            +" radar planes to ("+int(at.x)+","+int(at.z)+") spread "+int(spread)+", then on to the far edge",1);
        if (provider==ai.teamId) Handle(msg,ai.teamId);
        else AiSendMessage(msg,provider);
    }

    bool Handle(const string &in msg,int fromTeamId) {
        if (msg.findFirst(PREFIX)!=0) return false;
        array<string>@ parts=msg.split("|");
        Team::Roster::Entry@ sender=Team::Roster::Get(fromTeamId);
        const bool self=(fromTeamId==ai.teamId);
        if (parts.length()<4 || (!self && (sender is null || (sender.role!=AiRole::TECH && sender.role!=AiRole::FRONT)))) return true;
        const int t1=parseInt(parts[2]), radar=parseInt(parts[3]);
        AIFloat3 at(-1,0,-1);
        float spread=0.0f;
        if (parts.length()>=7) { at=AIFloat3(parseFloat(parts[4]),0,parseFloat(parts[5])); spread=parseFloat(parts[6]); }
        if (AirEconomy::Active()) {
            AirScoutSweep::Request(t1,radar,at,spread);
            GenericHelpers::LogUtil("[AIR][ScoutSweep] lolcannon request from "+fromTeamId+": "+t1+" T1, "+radar+" radar to ("
                +int(at.x)+","+int(at.z)+")",1);
        } else if (Global::AISettings::Role==AiRole::TECH) {
            LolCannonScouts::Request(t1,radar,at,spread);
        }
        return true;
    }

    // How far from `p` along (dx, dz), a unit vector, before the map edge less `margin`.
    float ToEdge(const AIFloat3 &in p, float dx, float dz, float margin) {
        float length=1.0e9f;
        if (dx>0.0001f) length=AiMin(length,(float(AiTerrainWidth())-margin-p.x)/dx);
        if (dx<-0.0001f) length=AiMin(length,(margin-p.x)/dx);
        if (dz>0.0001f) length=AiMin(length,(float(AiTerrainHeight())-margin-p.z)/dz);
        if (dz<-0.0001f) length=AiMin(length,(margin-p.z)/dz);
        return AiMax(0.0f,length);
    }

    // Scout i of n (owner 2026-10-27): a point spread over a disc of `spread`
    // round the target (golden angle, even over the area, not its centre), then
    // on in the heading from `from` to the far edge of the map.
    array<AIFloat3>@ Route(const AIFloat3 &in from, const AIFloat3 &in at, int i, int n, float spread) {
        const float margin=128.0f;
        const float r=(n>1) ? spread*sqrt((float(i)+0.5f)/float(n)) : 0.0f;
        const float a=float(i)*2.39996323f;
        AIFloat3 p(at.x+cos(a)*r,0,at.z+sin(a)*r);
        p.x=AiMax(margin,AiMin(float(AiTerrainWidth())-margin,p.x));
        p.z=AiMax(margin,AiMin(float(AiTerrainHeight())-margin,p.z));
        array<AIFloat3> route={p};
        const float dx=p.x-from.x, dz=p.z-from.z, length=sqrt(dx*dx+dz*dz);
        if (length<1.0f) return route;
        const float reach=ToEdge(p,dx/length,dz/length,margin);
        if (reach>256.0f) route.insertLast(AIFloat3(p.x+dx/length*reach,0,p.z+dz/length*reach));
        return route;
    }
}
