// Shared strategic coverage: lateral seats are role policy; native code owns
// terrain routing. No per-unit path solve. Recompute only when the roster,
// start/factory class or endpoints change, with a staggered ten-second poll.
#include "lanes.as"
#include "../presentation/widget_link.as"

namespace CoverageLanes {
    bool loaded=false, enabled=false, frontPublished=false;
    float tolerance=.2f, spacingWeight=32.f, resourceWeight=2.f, halfWidth=384.f;
    // D-356: the corridor consumers' levers (coverage.json), pushed natively
    // once; D-357: whether this AI's corridor is also its mex territory claim.
    float advance=512.f, rangeSlack=256.f, baseRadius=1200.f;
    bool defendFollows=false, claim=true;
    int nextTick=0;
    string frontKey;
    // D-357: the corridor this AI last announced to its allies (re-sent when
    // the roster grows), and the message grammar:
    //   corridor|<version>|teamId|halfWidth|x,z,x,z,...   (no points: cleared)
    array<AIFloat3> published;
    int rosterSeen=-1;
    const string CorridorPrefix="corridor|";
    const int CorridorVersion=1;
    void Load() {
        if(loaded)return;loaded=true;
        enabled=aiSetupMgr.ConfigBool("coverage/enabled",false);
        tolerance=aiSetupMgr.ConfigFloat("coverage/tolerance",.2f);
        spacingWeight=aiSetupMgr.ConfigFloat("coverage/spacing_weight",32.f);
        resourceWeight=aiSetupMgr.ConfigFloat("coverage/resource_weight",2.f);
        halfWidth=aiSetupMgr.ConfigFloat("coverage/half_width",384.f);
        advance=aiSetupMgr.ConfigFloat("coverage/advance",512.f);
        rangeSlack=aiSetupMgr.ConfigFloat("coverage/range_slack",256.f);
        baseRadius=aiSetupMgr.ConfigFloat("coverage/base_radius",1200.f);
        defendFollows=aiSetupMgr.ConfigBool("coverage/defend_follows_lane",false);
        claim=aiSetupMgr.ConfigBool("coverage/claim",true);
        aiBattle.SetFrontLaneOptions(advance,rangeSlack,baseRadius,defendFollows);
        GenericHelpers::LogUtil("[CoverageLane] enabled="+enabled+" advance="+int(advance)+" range_slack="+int(rangeSlack)
            +" base_radius="+int(baseRadius)+" defend_follows_lane="+defendFollows+" claim="+claim,1);
    }
    AIFloat3 Centre(const array<AIFloat3>& in points) {
        AIFloat3 p(0,0,0);for(uint i=0;i<points.length();++i)p+=points[i];
        return p/float(AiMax(1,int(points.length())));
    }
    bool Axis(AIFloat3& out ours,AIFloat3& out theirs) {
        array<AIFloat3> a=Lanes::AllyStarts(),b=Lanes::EnemyStarts();
        if(a.length()==0 || b.length()==0)return false;
        ours=Centre(a);theirs=Centre(b);return ours.SqDistance2D(theirs)>4096.f;
    }
    float Side(const AIFloat3& in p,const AIFloat3& in a,const AIFloat3& in b) {
        return -(p.x-a.x)*(b.z-a.z)+(p.z-a.z)*(b.x-a.x);
    }
    // Every ally sorts the same FRONT/SEA roster. Team id breaks equal starts;
    // exclude dead teams explicitly because the roster retains their entries.
    void Seat(AiRole role,const AIFloat3& in a,const AIFloat3& in b,int& out rank,int& out count) {
        rank=0;count=1;const float own=Side(Global::Map::StartPos,a,b);
        array<Team::Roster::Entry@>@ entries=Team::Roster::WithRole(role);
        for(uint i=0;i<entries.length();++i) {
            if(entries[i].teamId==ai.teamId || !aiEconomyMgr.IsTeamAlive(entries[i].teamId))continue;
            ++count;const float side=Side(entries[i].startPos,a,b);
            if(side<own || (side==own && entries[i].teamId<ai.teamId))++rank;
        }
    }
    array<AIFloat3>@ Route(const AIFloat3& in from,const AIFloat3& in to,const AIFloat3& in a,
            const AIFloat3& in b,int cls,float share,int seats) {
        return aiBattle.GetDistributedRoute(from,to,a,b,cls,share,seats,tolerance,spacingWeight,resourceWeight);
    }
    // Snap only within the requested movement class. Native routing still
    // requires connectivity and refuses missing connections.
    AIFloat3 Nearby(const AIFloat3& in point,int cls) {
        for(int ring=0;ring<=16;++ring)for(int k=0;k<16;++k) {
            const float angle=float(k)*6.2831853f/16.f;
            AIFloat3 p(point.x+cos(angle)*float(ring)*64.f,0,point.z+sin(angle)*float(ring)*64.f);
            if(p.x<0 || p.z<0 || p.x>=AiTerrainWidth() || p.z>=AiTerrainHeight())continue;
            if(aiBattle.IsPassable(p,cls)){p.y=aiBattle.Height(p);return p;}
        }
        return AIFloat3(-1,0,-1);
    }
    // Collinear interior points are dropped from both encodings; the corridor
    // distance and progress are the same on the thinned polyline.
    array<AIFloat3>@ Thin(const array<AIFloat3>& in points) {
        array<AIFloat3> thinned;
        for(uint i=0;i<points.length();++i) {
            if(i>0 && i+1<points.length()) {
                const AIFloat3 a=points[i]-points[i-1],b=points[i+1]-points[i];
                if(abs(a.x*b.z-a.z*b.x)<1.f)continue;
            }
            thinned.insertLast(points[i]);
        }
        return thinned;
    }
    string Encode(const array<AIFloat3>& in points) {
        string payload="1;"+ai.frame+";0,2,-1";
        array<AIFloat3>@ thin=Thin(points);
        for(uint i=0;i<thin.length();++i) payload+=","+int(thin[i].x)+","+int(thin[i].z);
        return payload;
    }
    // D-357: this AI's corridor as its allies' mex territory input. Applied
    // natively here and broadcast once per publication; a grown roster re-sends.
    string EncodeCorridor(const array<AIFloat3>& in points) {
        string payload=CorridorPrefix+CorridorVersion+"|"+ai.teamId+"|"+int(halfWidth)+"|";
        array<AIFloat3>@ thin=Thin(points);
        for(uint i=0;i<thin.length();++i) payload+=(i>0?",":"")+int(thin[i].x)+","+int(thin[i].z);
        return payload;
    }
    void Claim(const array<AIFloat3>& in points) {
        if(!claim)return;
        array<AIFloat3>@ thin=Thin(points);
        aiEconomyMgr.SetMexCorridor(ai.teamId,thin,halfWidth);
        published=thin;
        rosterSeen=Team::Roster::Count();
        AiSendMessage(EncodeCorridor(points));
    }
    void Unclaim() {
        if(published.length()==0)return;
        array<AIFloat3> empty;
        aiEconomyMgr.SetMexCorridor(ai.teamId,empty,halfWidth);
        published.resize(0);
        AiSendMessage(EncodeCorridor(empty));
    }
    // Team::HandleMessage: an ally's corridor claim. Returns true when the
    // message was a corridor line. Bounded by the sender's point count.
    bool HandleMessage(const string &in msg,int fromTeamId) {
        if(msg.length()<CorridorPrefix.length() || msg.substr(0,CorridorPrefix.length())!=CorridorPrefix)return false;
        Load();
        array<string>@ parts=msg.split("|");
        if(parts.length()<5 || int(parseInt(parts[1]))!=CorridorVersion)return true;
        const int team=int(parseInt(parts[2]));
        if(team!=fromTeamId || team==ai.teamId)return true;
        const float width=float(parseInt(parts[3]));
        array<AIFloat3> points;
        if(parts[4].length()>0) {
            array<string>@ values=parts[4].split(",");
            for(uint i=0;i+1<values.length();i+=2) {
                const float x=float(parseInt(values[i])),z=float(parseInt(values[i+1]));
                if(x<0 || z<0 || x>=AiTerrainWidth() || z>=AiTerrainHeight())continue;
                points.insertLast(AIFloat3(x,0,z));
            }
        }
        if(claim)aiEconomyMgr.SetMexCorridor(team,points,width>0.f?width:halfWidth);
        GenericHelpers::LogUtil("[CoverageLane] corridor from team "+team+" points="+points.length()+(claim?"":" (claim off)"),1);
        return true;
    }
    void Tick() {
        Load();
        if(!enabled || Global::AISettings::Role!=AiRole::FRONT) {
            if(frontPublished) {
                array<AIFloat3> empty;aiBattle.SetFrontLane(empty,halfWidth);
                WidgetLink::SetState("frontlanes",WidgetLink::Line("frontlanes","1;"+ai.frame));
                frontPublished=false;frontKey="";
                Unclaim();
            }
            return;
        }
        if(ai.frame<nextTick || ai.frame<(2+ai.teamId%16)*SECOND)return;
        nextTick=ai.frame+10*SECOND;
        if(!Team::Roster::IsComplete() && ai.frame<30*SECOND)return;
        // A late ally learns this corridor too (the roster grew since the claim).
        if(frontPublished && published.length()>0 && Team::Roster::Count()!=rosterSeen) {
            rosterSeen=Team::Roster::Count();
            AiSendMessage(EncodeCorridor(published));
        }
        AIFloat3 a,b;if(!Axis(a,b))return;
        int rank,count;Seat(AiRole::FRONT,a,b,rank,count);
        const int cls=UnitHelpers::IsT1VehicleLab(Global::AISettings::StartFactory)?Lanes::LAND:Lanes::BOT;
        array<AIFloat3> enemies=Lanes::EnemyStarts();
        // Match the lateral seat to the corresponding enemy-side destination.
        for(uint i=1;i<enemies.length();++i)for(uint j=i;j>0 && Side(enemies[j],a,b)<Side(enemies[j-1],a,b);--j) {
            AIFloat3 swap=enemies[j];enemies[j]=enemies[j-1];enemies[j-1]=swap;
        }
        const float share=(float(rank)+.5f)/float(count);
        const int destination=AiMin(int(enemies.length())-1,int(share*float(enemies.length())));
        if(destination<0)return;
        const AIFloat3 start=Global::Map::StartPos,end=enemies[uint(destination)];
        const string key=""+rank+":"+count+":"+cls+":"+int(start.x)+":"+int(start.z)+":"+int(end.x)+":"+int(end.z)+":"+int(a.x)+":"+int(a.z)+":"+int(b.x)+":"+int(b.z);
        if(key==frontKey)return;
        // Terrain and these strategic endpoints are immutable for this key.
        // Cache failures too; retry only after a roster/endpoint change, and
        // never keep an obsolete seat while its replacement is unreachable.
        frontKey=key;
        if(frontPublished) {
            array<AIFloat3> empty;aiBattle.SetFrontLane(empty,halfWidth);
            WidgetLink::SetState("frontlanes",WidgetLink::Line("frontlanes","1;"+ai.frame));
            frontPublished=false;
            Unclaim();
        }
        const AIFloat3 from=Nearby(start,cls),to=Nearby(end,cls);
        if(from.x<0 || to.x<0) {
            GenericHelpers::LogUtil("[CoverageLane] endpoint unreachable rank="+rank+" seats="+count,1);return;
        }
        array<AIFloat3>@ points=Route(from,to,a,b,cls,share,count);
        if(points is null || points.length()<2) {
            GenericHelpers::LogUtil("[CoverageLane] front unreachable rank="+rank+" seats="+count,1);return;
        }
        if(!aiBattle.SetFrontLane(points,halfWidth))return;
        // The native lane ends (own start, enemy starts) otherwise exist only
        // once TECH's lane survey runs; the corridor sweep's enemy-home rule
        // (front_mex_enemy_home, CBattleAnalysis::EnemyEndDistance) reads them.
        // Lanes::Compute sets the same values when it runs.
        aiBattle.ClearLaneEnds();
        aiBattle.AddAllyEnd(Global::Map::StartPos);
        for(uint i=0;i<enemies.length();++i)aiBattle.AddEnemyEnd(enemies[i]);
        frontKey=key;frontPublished=true;
        WidgetLink::SetState("frontlanes",WidgetLink::Line("frontlanes",Encode(points)));
        Claim(points);
        GenericHelpers::LogUtil("[CoverageLane] front assigned rank="+rank+" seats="+count+" class="+cls+" points="+points.length(),1);
    }
}
