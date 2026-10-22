// D-160: advisory beachhead sites and allied claims. No unit commands here.
namespace AmphibiousBeaches {
    class Site { AIFloat3 pos, sea; int region = -1; float assets = 0, naval = 1.0e30f; }
    class Claim { int team = -1, serial = -1, expires = 0; AIFloat3 pos; }
    array<Site@> sites;
    array<Claim@> claims;
    bool mapped = false;
    int scored = -100000;
    const string MESSAGE = "barbamph";

    void Prepare() {
        if (mapped || !StrategicSites::mapped) return;
        mapped = true;
        // Sample a bounded, deterministic set on the existing shared-sea grid.
        // A full wave-sized dry platform leaves room for the retained group.
        array<AIFloat3> directions={AIFloat3(1,0,0),AIFloat3(-1,0,0),AIFloat3(0,0,1),AIFloat3(0,0,-1),
            AIFloat3(0.707f,0,0.707f),AIFloat3(-0.707f,0,0.707f),AIFloat3(0.707f,0,-0.707f),AIFloat3(-0.707f,0,-0.707f)};
        dictionary seen;
        for (uint b=0;b<WaterTheatres::bodies.length();++b) {
            WaterTheatres::Body@ body=WaterTheatres::bodies[b];
            if (body.pond || !body.shared) continue;
            for (uint c=0;c<body.shore.length();c+=4) {
                const AIFloat3 sea=WaterTheatres::Pos(body.shore[c]);
                for (uint d=0;d<directions.length();++d) {
                    const AIFloat3 p=sea+directions[d]*256.0f;
                    if (p.x<0 || p.z<0 || p.x>=AiTerrainWidth() || p.z>=AiTerrainHeight()) continue;
                    const string key=""+int(p.x/256.0f)+":"+int(p.z/256.0f);
                    if (seen.exists(key) || !AmphibiousOps::DryRoom(p)) continue;
                    const int region=StrategicSites::LandAt(p);
                    if (region<0) continue;
                    seen.set(key,true);
                    Site@ s=Site(); s.pos=p; s.sea=sea; s.region=region; sites.insertLast(s);
                    if (sites.length()>=2048) return;
                }
            }
        }
    }
    void Prune() {
        for (int i=int(claims.length())-1;i>=0;--i) if (claims[i].expires<=ai.frame) claims.removeAt(i);
    }
    void Remember(int team, int serial, const AIFloat3& in pos, bool release) {
        for (int i=int(claims.length())-1;i>=0;--i) {
            if (claims[i].team==team && claims[i].serial==serial) claims.removeAt(i);
        }
        if (release || claims.length()>=64) return;
        Claim@ c=Claim(); c.team=team; c.serial=serial; c.pos=pos; c.expires=ai.frame+60*SECOND;
        claims.insertLast(c);
    }
    bool HandleMessage(const string& in msg, int team) {
        if (msg.findFirst(MESSAGE+"|")!=0) return false;
        if (!AmphibiousOps::Active() || team==ai.teamId) return true;
        array<Id>@ allies=ai.GetTeamIds();
        if (allies.find(team)<0) return true;
        array<string>@ parts=msg.split("|");
        if (parts.length()!=5 || (parts[1]!="guard" && parts[1]!="release")) return true;
        const int serial=parseInt(parts[2]);
        const AIFloat3 pos(parseFloat(parts[3]),0,parseFloat(parts[4]));
        if (serial<1 || !(pos.x>=0 && pos.z>=0 && pos.x<AiTerrainWidth() && pos.z<AiTerrainHeight())) return true;
        Prune(); Remember(team,serial,pos,parts[1]=="release"); return true;
    }
    void Publish(int serial, const AIFloat3& in pos, bool release=false) {
        Prune(); Remember(ai.teamId,serial,pos,release);
        AiSendMessage(MESSAGE+"|"+(release?"release":"guard")+"|"+serial+"|"+pos.x+"|"+pos.z);
    }
    bool Claimed(const AIFloat3& in p, int ownSerial=-1, bool winnersOnly=false) {
        for (uint i=0;i<claims.length();++i) {
            Claim@ c=claims[i];
            if (c.expires<=ai.frame || (c.team==ai.teamId && c.serial==ownSerial)
                || c.pos.distance2D(p)>900.0f) continue;
            if (!winnersOnly || AmphibiousMath::ClaimPrecedes(c.team,c.serial,ai.teamId,ownSerial)) return true;
        }
        return false;
    }
    float Assets(const AIFloat3& in p, int region) {
        float value=0;
        const int count=aiBattle.GetAllyAssetCount();
        for (int i=0;i<count;++i) {
            const AIFloat3 asset=aiBattle.GetAllyAssetPos(i);
            const float distance=p.distance2D(asset);
            if (distance>1100.0f || StrategicSites::LandAt(asset)!=region) continue;
            // Even a basic extractor is worth holding; expensive factories do
            // not outweigh every exposed expansion merely through their cost.
            value+=AiMin(1000.0f,100.0f+aiBattle.GetAllyAssetCost(i))/(1.0f+distance/550.0f);
        }
        return value;
    }
    float NavalDistance(const AIFloat3& in p) {
        float distance=1.0e30f;
        for (int i=0;i<aiBattle.GetNavalContactCount();++i)
            distance=AiMin(distance,p.distance2D(aiBattle.GetNavalContactPos(i)));
        return distance;
    }
    AIFloat3 Best(const AIFloat3& in from, int region=-1, int ownSerial=-1) {
        Prepare(); Prune();
        if (ai.frame>=scored+20*SECOND) {
            scored=ai.frame;
            // Refresh observations once per team, not once per wave candidate.
            const int count=aiBattle.GetAllyAssetCount();
            array<AIFloat3> positions; array<float> values; array<int> regions;
            for (int i=0;i<count;++i) {
                const AIFloat3 p=aiBattle.GetAllyAssetPos(i);
                positions.insertLast(p); regions.insertLast(StrategicSites::LandAt(p));
                values.insertLast(AiMin(1000.0f,100.0f+aiBattle.GetAllyAssetCost(i)));
            }
            for (uint i=0;i<sites.length();++i) {
                Site@ s=sites[i]; s.assets=0; s.naval=NavalDistance(s.pos);
                for (uint j=0;j<positions.length();++j) {
                    if (s.region!=regions[j]) continue;
                    const float distance=s.pos.distance2D(positions[j]);
                    if (distance<=1100.0f) s.assets+=values[j]/(1.0f+distance/550.0f);
                }
            }
        }
        AIFloat3 result(-1,0,-1); float best=0;
        for (uint i=0;i<sites.length();++i) {
            Site@ s=sites[i];
            if ((region>=0 && s.region!=region) || Claimed(s.pos,ownSerial)) continue;
            const float score=AmphibiousMath::BeachScore(s.assets,s.naval,from.distance2D(s.pos),aiBattle.SurfThreat(s.pos)*0.02f);
            if (score>best) { best=score; result=s.pos; }
        }
        return result;
    }
}
