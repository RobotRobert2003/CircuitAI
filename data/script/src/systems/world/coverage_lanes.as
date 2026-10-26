// Strategic inspection rollout: fixed corridors drive FRONT commanders only.
// Assistance and dead-seat recovery are advisory proposals; they never replace
// the native commander route or issue unit orders. See KI-670.
#include "lanes.as"
#include "../presentation/widget_link.as"

namespace CoverageLanes {
    bool loaded=false, enabled=false, frontPublished=false;
    float tolerance=.2f, spacingWeight=32.f, resourceWeight=2.f, halfWidth=384.f;
    float minWidth=64.f;    // D-358: coverage.json min_width, the narrowest corridor a seat may take
    // D-356: the corridor consumers' levers (coverage.json), pushed natively
    // once; D-357: whether this AI's corridor is also its mex territory claim.
    float advance=512.f, rangeSlack=256.f, baseRadius=1200.f;
    bool defendFollows=false, claim=true;
    // D-359: assistance levers (coverage.json): whether seats help each other,
    // the surface threat (the commander's front_threat scale) on the lane ahead
    // of the commander that makes a seat ask, how far ahead it looks, and how
    // long a helper keeps the fork after the last request.
    bool assistEnabled=true;
    float assistThreat=3.f, assistAhead=1200.f;
    int assistSeconds=90;
    int nextTick=0;
    string frontKey;
    string routeStatus="waiting", proposalStatus="none";
    // D-357: the corridor this AI last announced to its allies (re-sent when
    // the roster grows), and the message grammar:
    //   corridor|<version>|teamId|halfWidth|x,z,x,z,...   (no points: cleared)
    array<AIFloat3> published;
    int rosterSeen=-1;
    const string CorridorPrefix="corridor|";
    const int CorridorVersion=1;
    // D-359: the fixed seat and lane. The seat (rank among the side's FRONT
    // roster entries, dead or alive, by start position along the team axis)
    // changes only on explicit roster/terrain revisions, not pressure polls.
    // Assistance never modifies this executed commander lane.
    int fixedRank=-1, fixedCount=0, fixedClass=-1, fixedCorridor=-1;
    array<int> classCorridors;          // the class's corridors in lateral order at assignment
    array<AIFloat3> fixedPoints;        // the published fixed lane
    // D-359: assistance state and the message grammar:
    //   assist|<version>|teamId|corridor|progress|helperTeam|<1 asking, 0 released>
    const string AssistPrefix="assist|";
    const int AssistVersion=1;
    int helpingTeam=-1, helpingCorridor=-1, helpingUntil=-1;
    bool helpingDead=false;             // a dead seat's corridor: kept while it is dead
    array<AIFloat3> forkPoints;         // the routed link from the fork point to the helped corridor
    bool requesting=false;
    int requestedHelper=-1;
    dictionary requests;                // team id string -> frame of its last request (a seat under pressure does not help)
    void Load() {
        if(loaded)return;loaded=true;
        enabled=aiSetupMgr.ConfigBool("coverage/enabled",false);
        tolerance=aiSetupMgr.ConfigFloat("coverage/tolerance",.2f);
        spacingWeight=aiSetupMgr.ConfigFloat("coverage/spacing_weight",32.f);
        resourceWeight=aiSetupMgr.ConfigFloat("coverage/resource_weight",2.f);
        halfWidth=aiSetupMgr.ConfigFloat("coverage/half_width",384.f);
        minWidth=aiSetupMgr.ConfigFloat("coverage/min_width",64.f);
        advance=aiSetupMgr.ConfigFloat("coverage/advance",512.f);
        rangeSlack=aiSetupMgr.ConfigFloat("coverage/range_slack",256.f);
        baseRadius=aiSetupMgr.ConfigFloat("coverage/base_radius",1200.f);
        defendFollows=aiSetupMgr.ConfigBool("coverage/defend_follows_lane",false);
        claim=aiSetupMgr.ConfigBool("coverage/claim",true);
        assistEnabled=aiSetupMgr.ConfigBool("coverage/assist_enabled",true);
        assistThreat=aiSetupMgr.ConfigFloat("coverage/assist_threat",3.f);
        assistAhead=AiMax(0.f,AiMin(4096.f,aiSetupMgr.ConfigFloat("coverage/assist_ahead",1200.f)));
        assistSeconds=aiSetupMgr.ConfigInt("coverage/assist_seconds",90);
        laneSpacing=aiSetupMgr.ConfigFloat("field/corridors/lane_spacing",768.f);
        aiBattle.SetFrontLaneOptions(advance,rangeSlack,baseRadius,defendFollows);
        GenericHelpers::LogUtil("[CoverageLane] enabled="+enabled+" advance="+int(advance)+" range_slack="+int(rangeSlack)
            +" base_radius="+int(baseRadius)+" defend_follows_lane="+defendFollows+" claim="+claim
            +" assist="+assistEnabled+" assist_threat="+assistThreat+" assist_ahead="+int(assistAhead)+" assist_seconds="+assistSeconds,1);
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
    // Roster::WithRole contains remote instances. Add this instance exactly
    // once so all observers rank the same set; never mutate roster-owned entries.
    array<Team::Roster::Entry@>@ Seats(AiRole role) {
        array<Team::Roster::Entry@>@ result=Team::Roster::WithRole(role);
        bool found=false;
        for(uint i=0;i<result.length();++i)if(result[i].teamId==ai.teamId)found=true;
        if(!found && Global::AISettings::Role==role) {
            Team::Roster::Entry@ self=Team::Roster::Entry();
            self.teamId=ai.teamId;self.role=role;self.startPos=Global::Map::StartPos;
            self.startFactory=Global::AISettings::StartFactory;
            result.insertLast(self);
        }
        return result;
    }
    // Every ally sorts the same FRONT roster, dead entries included (D-359:
    // income-loss suspects retain their seats; recovery is advisory).
    // Team id breaks equal starts.
    void SeatOf(int teamId,const AIFloat3& in startPos,AiRole role,const AIFloat3& in a,const AIFloat3& in b,int& out rank,int& out count) {
        rank=0;count=1;const float own=Side(startPos,a,b);
        array<Team::Roster::Entry@>@ entries=Seats(role);
        for(uint i=0;i<entries.length();++i) {
            if(entries[i].teamId==teamId)continue;
            ++count;const float side=Side(entries[i].startPos,a,b);
            if(side<own || (side==own && entries[i].teamId<teamId))++rank;
        }
    }
    void Seat(AiRole role,const AIFloat3& in a,const AIFloat3& in b,int& out rank,int& out count) {
        SeatOf(ai.teamId,Global::Map::StartPos,role,a,b,rank,count);
    }
    // The corridor a seat holds: the class's corridors in lateral order shared
    // by rank (distinct while there are at least as many corridors as seats).
    int CorridorForRank(int rank,int count) {
        const int n=int(classCorridors.length());
        if(n==0 || count<=0)return -1;
        return classCorridors[uint(AiMin(n-1,int((float(rank)+.5f)/float(count)*float(n))))];
    }
    // D-361: the side's seats matched to the physical lanes in front of them.
    // Physical lanes are every class's corridors in lateral order, lanes of
    // different classes within half a lane spacing of each other being the
    // same ground. Seats in lateral order are matched to distinct physical
    // lanes minimising total lateral displacement (Hungarian assignment,
    // O(seats squared x lanes)); a seat may
    // only take a lane with a corridor of its class. Every ally computes the
    // same table from the same roster and field, so no message is needed.
    // With more seats than lanes, or without the table, the rank share applies.
    dictionary seatCorridor;            // team id string -> corridor id of the seat's fixed lane
    int seatRevision=-1, assignmentRevision=0;
    string seatRoster;
    bool seatsMatched=false;
    float laneSpacing=768.f;            // field.json corridors/lane_spacing
    float LateralOf(const AIFloat3& in p,const AIFloat3& in a,const AIFloat3& in b) {
        return Side(p,a,b)/AiMax(1.f,sqrt(a.SqDistance2D(b)));
    }
    int ClassOfFactory(const string &in factory) { return UnitHelpers::IsT1VehicleLab(factory)?Lanes::LAND:Lanes::BOT; }
    bool ComputeSeats(const AIFloat3& in a,const AIFloat3& in b) {
        seatCorridor.deleteAll();
        array<Team::Roster::Entry@>@ entries=Seats(AiRole::FRONT);
        array<int> seatTeam,seatCls;array<float> seatLat;
        // the roster may hold only the others: this seat is added from its own settings
        array<int> teams;array<AIFloat3> starts;array<string> factories;
        bool self=false;
        for(uint i=0;i<entries.length();++i) {
            teams.insertLast(entries[i].teamId);starts.insertLast(entries[i].startPos);factories.insertLast(entries[i].startFactory);
            if(entries[i].teamId==ai.teamId)self=true;
        }
        if(!self){teams.insertLast(ai.teamId);starts.insertLast(Global::Map::StartPos);factories.insertLast(Global::AISettings::StartFactory);}
        for(uint i=0;i<teams.length();++i) {
            const float lat=LateralOf(starts[i],a,b);
            seatTeam.insertLast(teams[i]);seatLat.insertLast(lat);seatCls.insertLast(ClassOfFactory(factories[i]));
            for(uint j=seatTeam.length()-1;j>0 && (seatLat[j-1]>seatLat[j] || (seatLat[j-1]==seatLat[j] && seatTeam[j-1]>seatTeam[j]));--j) {
                const int t=seatTeam[j];seatTeam[j]=seatTeam[j-1];seatTeam[j-1]=t;
                const int c=seatCls[j];seatCls[j]=seatCls[j-1];seatCls[j-1]=c;
                const float l=seatLat[j];seatLat[j]=seatLat[j-1];seatLat[j-1]=l;
            }
        }
        if(seatTeam.length()==0)return false;
        // every class's corridors, sorted by lateral position
        array<float> allLat;array<int> allCls,allId;
        array<int> classes={Lanes::LAND,Lanes::BOT};
        for(uint k=0;k<2;++k) {
            array<int>@ ids=aiBattle.CorridorsForClass(classes[k],a,b,minWidth);
            if(ids is null)continue;
            for(uint i=0;i<ids.length();++i) {
                const AIFloat3 mid=aiBattle.CorridorPoint(ids[i],.5f);
                if(mid.x<0)continue;
                allLat.insertLast(LateralOf(mid,a,b));allCls.insertLast(classes[k]);allId.insertLast(ids[i]);
                for(uint j=allLat.length()-1;j>0 && allLat[j-1]>allLat[j];--j) {
                    const float l=allLat[j];allLat[j]=allLat[j-1];allLat[j-1]=l;
                    const int c=allCls[j];allCls[j]=allCls[j-1];allCls[j-1]=c;
                    const int d=allId[j];allId[j]=allId[j-1];allId[j-1]=d;
                }
            }
        }
        // physical lanes: the bot corridors (the finest list), each vehicle
        // corridor joining the nearest bot lane within half a spacing that has
        // no vehicle corridor yet, or standing as a lane of its own; no corridor
        // is lost to a chain of near neighbours
        array<float> laneLat;array<int> laneLand,laneBot;
        for(uint i=0;i<allLat.length();++i)if(allCls[i]==Lanes::BOT){laneLat.insertLast(allLat[i]);laneLand.insertLast(-1);laneBot.insertLast(allId[i]);}
        for(uint i=0;i<allLat.length();++i) {
            if(allCls[i]!=Lanes::LAND)continue;
            int best=-1;float bestD=laneSpacing*.5f;
            for(uint j=0;j<laneLat.length();++j) {
                const float d=abs(laneLat[j]-allLat[i]);
                if(laneLand[j]<0 && d<=bestD){bestD=d;best=int(j);}
            }
            if(best>=0){laneLand[uint(best)]=allId[i];continue;}
            uint j=laneLat.length();
            laneLat.insertLast(allLat[i]);laneLand.insertLast(allId[i]);laneBot.insertLast(-1);
            for(;j>0 && laneLat[j-1]>laneLat[j];--j) {
                const float l=laneLat[j];laneLat[j]=laneLat[j-1];laneLat[j-1]=l;
                const int x=laneLand[j];laneLand[j]=laneLand[j-1];laneLand[j-1]=x;
                const int y=laneBot[j];laneBot[j]=laneBot[j-1];laneBot[j-1]=y;
            }
        }
        const int m=int(seatTeam.length()),L=int(laneLat.length());
        if(L==0 || m>L)return false;
        // minimum-cost assignment of seats to distinct lanes (Hungarian method,
        // O(m^2 L)); the cost is the lateral displacement, a lane without a
        // corridor of the seat's class is unusable. Lanes may cross near the
        // bases: two neighbouring bases a few hundred elmos apart are not forced
        // onto lanes in their own order when the nearer lanes lie the other way.
        const float Unusable=1e9f;
        array<float> u(uint(m+1),0.f),v(uint(L+1),0.f),minv(uint(L+1),0.f);
        array<int> p(uint(L+1),0),way(uint(L+1),0);
        array<bool> used(uint(L+1),false);
        for(int i=1;i<=m;++i) {
            p[0]=i;int j0=0;
            for(int j=0;j<=L;++j){minv[uint(j)]=1e30f;used[uint(j)]=false;}
            do {
                used[uint(j0)]=true;const int i0=p[uint(j0)];float delta=1e30f;int j1=0;
                for(int j=1;j<=L;++j) {
                    if(used[uint(j)])continue;
                    const int id=seatCls[uint(i0-1)]==Lanes::LAND?laneLand[uint(j-1)]:laneBot[uint(j-1)];
                    const float cost=(id>=0?abs(seatLat[uint(i0-1)]-laneLat[uint(j-1)]):Unusable)-u[uint(i0)]-v[uint(j)];
                    if(cost<minv[uint(j)]){minv[uint(j)]=cost;way[uint(j)]=j0;}
                    if(minv[uint(j)]<delta){delta=minv[uint(j)];j1=j;}
                }
                for(int j=0;j<=L;++j) {
                    if(used[uint(j)]){u[uint(p[uint(j)])]+=delta;v[uint(j)]-=delta;}
                    else minv[uint(j)]-=delta;
                }
                j0=j1;
            } while(p[uint(j0)]!=0);
            do {const int j1=way[uint(j0)];p[uint(j0)]=p[uint(j1)];j0=j1;} while(j0!=0);
        }
        for(int j=1;j<=L;++j) {
            const int i=p[uint(j)];
            if(i<=0)continue;
            const int id=seatCls[uint(i-1)]==Lanes::LAND?laneLand[uint(j-1)]:laneBot[uint(j-1)];
            if(id<0){seatCorridor.deleteAll();return false;}   // only an unusable lane was left for a seat
            seatCorridor.set(""+seatTeam[uint(i-1)],int64(id));
        }
        GenericHelpers::LogUtil("[CoverageLane] seats matched: "+m+" seats over "+L+" physical lanes ("+allLat.length()+" corridors)",1);
        return true;
    }
    int CorridorOfTeam(int teamId) {
        int64 id=-1;
        if(seatsMatched && seatCorridor.get(""+teamId,id))return int(id);
        return -1;
    }
    // The enemy start a seat heads for: the lateral match of its share.
    AIFloat3 EndFor(int rank,int count,const AIFloat3& in a,const AIFloat3& in b) {
        array<AIFloat3> enemies=Lanes::EnemyStarts();
        if(enemies.length()==0 || count<=0)return AIFloat3(-1,0,-1);
        for(uint i=1;i<enemies.length();++i)for(uint j=i;j>0 && Side(enemies[j],a,b)<Side(enemies[j-1],a,b);--j) {
            AIFloat3 swap=enemies[j];enemies[j]=enemies[j-1];enemies[j-1]=swap;
        }
        const float share=(float(rank)+.5f)/float(count);
        return enemies[uint(AiMin(int(enemies.length())-1,int(share*float(enemies.length()))))];
    }
    // D-358: a seat takes a corridor of the field's table (the planner's
    // obstacle-separated lanes, lateral order along the team axis, corridors
    // narrower than a formation excluded). Seats share the corridors by rank
    // when there are fewer corridors than seats. Until the table exists, or
    // on a profile without the field, the area-quantile solver remains the
    // fallback (KI-668 retires it once the corridor path is Played).
    int lastCorridor=-1;
    // INV-237: a published front corridor is passable for its class along
    // every segment, sampled every 32 elmos on the field's own open-cell
    // raster (CorridorOpen, no snapping). The first and the last segment join
    // the snapped endpoints and are not sampled.
    void CheckPassable(const array<AIFloat3>& in centre,int cls,int corridor) {
        for(uint i=2;i+1<centre.length();++i) {
            const AIFloat3 a=centre[i-1],b=centre[i];
            const float len=sqrt(a.SqDistance2D(b));
            const int steps=AiMax(1,int(len/32.f));
            for(int k=0;k<=steps;++k) {
                const float t=float(k)/float(steps);
                const AIFloat3 p(a.x+(b.x-a.x)*t,0,a.z+(b.z-a.z)*t);
                if(!aiBattle.CorridorOpen(cls,p)) {
                    Invariants::Violation("INV-237", ""+corridor, "front corridor segment "+(i-1)+" crosses closed ground at ("+int(p.x)+","+int(p.z)+") for class "+cls);
                    return;
                }
            }
        }
    }
    array<AIFloat3>@ Route(const AIFloat3& in from,const AIFloat3& in to,const AIFloat3& in a,
            const AIFloat3& in b,int cls,float share,int seats,int matched=-1) {
        lastCorridor=-1;
        array<int>@ corridors=aiBattle.CorridorsForClass(cls,a,b,minWidth);
        if(cls!=Lanes::NAVAL)classCorridors.resize(0);   // the sea lanes (sea_lanes.as) route here too; the FRONT list is the land one
        if(corridors !is null && corridors.length()>0) {
            if(cls!=Lanes::NAVAL)for(uint i=0;i<corridors.length();++i)classCorridors.insertLast(corridors[i]);
            // D-361: the matched lane when the seats were matched, else the rank share
            int pick=AiMin(int(corridors.length())-1,int(share*float(corridors.length())));
            for(uint i=0;i<corridors.length();++i)if(corridors[i]==matched)pick=int(i);
            lastCorridor=corridors[uint(pick)];
            array<AIFloat3>@ centre=aiBattle.CorridorCentre(lastCorridor,from,to);
            if(centre !is null && centre.length()>=2) {
                CheckPassable(centre,cls,lastCorridor);
                GenericHelpers::LogUtil("[CoverageLane] corridor "+lastCorridor+" of "+corridors.length()+" class="+cls
                    +" rank-share="+share+" width="+int(aiBattle.CorridorWidth(lastCorridor))+" length="+int(aiBattle.CorridorLength(lastCorridor)),1);
                return centre;
            }
            lastCorridor=-1;
        }
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
    // ---- polyline geometry on the fixed lane (O(vertices), once per poll)
    float Length(const array<AIFloat3>& in points) {
        float total=0;for(uint i=1;i<points.length();++i)total+=sqrt(points[i].SqDistance2D(points[i-1]));
        return total;
    }
    // Progress (elmos from the first vertex) of the nearest point of the
    // polyline to p, and the distance to it.
    float Progress(const array<AIFloat3>& in points,const AIFloat3& in p,float& out distance) {
        float best=1e30f,at=0,walked=0;
        for(uint i=1;i<points.length();++i) {
            const AIFloat3 a=points[i-1],b=points[i];
            const float dx=b.x-a.x,dz=b.z-a.z,len2=dx*dx+dz*dz,len=sqrt(len2);
            float u=len2>0?((p.x-a.x)*dx+(p.z-a.z)*dz)/len2:0;u=AiMax(0.f,AiMin(1.f,u));
            const float px=a.x+dx*u-p.x,pz=a.z+dz*u-p.z,d=sqrt(px*px+pz*pz);
            if(d<best){best=d;at=walked+len*u;}
            walked+=len;
        }
        distance=best;return at;
    }
    // The point at a progress, and the index of the last vertex at or before it.
    AIFloat3 PointAt(const array<AIFloat3>& in points,float progress,int& out index) {
        index=0;
        if(points.length()==0)return AIFloat3(-1,0,-1);
        float walked=0;
        for(uint i=1;i<points.length();++i) {
            const float len=sqrt(points[i].SqDistance2D(points[i-1]));
            if(walked+len>=progress) {
                const float u=len>0?AiMax(0.f,AiMin(1.f,(progress-walked)/len)):0;
                index=int(i)-1;
                AIFloat3 p=points[i-1]+(points[i]-points[i-1])*u;p.y=aiBattle.Height(p);return p;
            }
            walked+=len;
        }
        index=int(points.length())-1;return points[points.length()-1];
    }
    AIFloat3 CommanderPos() {
        CCircuitUnit@ c=Builder::commander;
        return c is null?AIFloat3(-1,0,-1):c.GetPos(ai.frame);
    }
    // ---- publication
    // frontlanes state: 1;frame;<factory,kind,contact,x,z,...>;... Record 0 kind 2
    // is the fixed lane; contact is the first vertex of its unsupplied section
    // (-1: all supplied). Record 1 kind 3 is the fork link while assisting.
    string Record(int factory,int kind,int contact,const array<AIFloat3>& in points) {
        string payload=""+factory+","+kind+","+contact;
        array<AIFloat3>@ thin=Thin(points);
        for(uint i=0;i<thin.length();++i) payload+=","+int(thin[i].x)+","+int(thin[i].z);
        return payload;
    }
    void PublishWidget() {
        if(!frontPublished || fixedPoints.length()<2) {
            WidgetLink::SetState("frontlanes",WidgetLink::Line("frontlanes","1;"+ai.frame));return;
        }
        string payload="1;"+ai.frame+";"+Record(0,2,-1,fixedPoints);
        // Proposals are published separately; legacy lane renderers cannot
        // accidentally show an advisory fork as an executed movement plan.
        WidgetLink::SetState("frontlanes",WidgetLink::Line("frontlanes",payload));
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
    // ---- assistance (D-359)
    dictionary deadSince;               // team id string -> first frame its income read zero
    // The engine's team income, read on demand (UpdateTeamEconomy fills the
    // entry); a dead team has none. A seat counts as dead only after two polls
    // without income, and never in the first minute while incomes settle.
    bool Dead(int teamId) {
        const bool noIncome=aiEconomyMgr.UpdateTeamEconomy(teamId) && !aiEconomyMgr.IsTeamAlive(teamId);
        const string k=""+teamId;
        if(!noIncome){deadSince.delete(k);return false;}
        int64 since=-1;
        if(!deadSince.get(k,since)){deadSince.set(k,int64(ai.frame));return false;}
        return ai.frame>=60*SECOND && ai.frame-int(since)>=20*SECOND;
    }
    bool RecentlyAsked(int teamId) {
        int64 frame=-1;
        return requests.get(""+teamId,frame) && ai.frame-int(frame)<=assistSeconds*SECOND;
    }
    // The seat under pressure picks its helper so exactly one answers: the
    // laterally adjacent living seat whose own corridor's choke carries the
    // lower surface threat, not one that is asking itself; the lower team id
    // breaks ties. -1 when no neighbour can help.
    int ChooseHelper(const AIFloat3& in a,const AIFloat3& in b) {
        array<Team::Roster::Entry@>@ entries=Seats(AiRole::FRONT);
        int best=-1;float bestThreat=1e30f;
        for(uint i=0;i<entries.length();++i) {
            Team::Roster::Entry@ e=entries[i];
            if(e.teamId==ai.teamId || RecentlyAsked(e.teamId) || Dead(e.teamId))continue;
            int rank,count;SeatOf(e.teamId,e.startPos,AiRole::FRONT,a,b,rank,count);
            if(rank!=fixedRank-1 && rank!=fixedRank+1)continue;
            int corridor=CorridorOfTeam(e.teamId);
            if(corridor<0)corridor=CorridorForRank(rank,count);
            if(corridor<0 || corridor==fixedCorridor)continue;
            const float threat=aiBattle.SurfThreat(aiBattle.CorridorChoke(corridor));
            if(threat<bestThreat || (threat==bestThreat && e.teamId<best)){bestThreat=threat;best=e.teamId;}
        }
        return best;
    }
    // The lane ahead of the commander (assist_ahead elmos, 128-elmo steps) is
    // held by surface threat above assist_threat.
    bool NeedsHelp() {
        const AIFloat3 c=CommanderPos();
        if(c.x<0 || fixedPoints.length()<2)return false;
        float distance;const float from=Progress(fixedPoints,c,distance);
        const float to=AiMin(Length(fixedPoints),from+assistAhead);
        int index;
        for(float d=from;d<=to;d+=128.f)if(aiBattle.SurfThreat(PointAt(fixedPoints,d,index))>assistThreat)return true;
        return false;
    }
    // Who merges a dead seat's corridor: the living seat nearest by rank, the
    // lower rank on a tie. Every ally evaluates the same roster.
    int MergerFor(int deadRank,const AIFloat3& in a,const AIFloat3& in b) {
        array<Team::Roster::Entry@>@ entries=Seats(AiRole::FRONT);
        int best=-1,bestGap=1<<30,bestRank=1<<30;
        for(uint i=0;i<entries.length();++i) {
            Team::Roster::Entry@ e=entries[i];
            if(e.teamId!=ai.teamId && Dead(e.teamId))continue;
            int rank,count;SeatOf(e.teamId,e.startPos,AiRole::FRONT,a,b,rank,count);
            const int gap=AiMax(rank-deadRank,deadRank-rank);
            if(gap>0 && (gap<bestGap || (gap==bestGap && rank<bestRank))){bestGap=gap;bestRank=rank;best=e.teamId;}
        }
        return best;
    }
    void BeginHelp(int team,int corridor,bool dead,const AIFloat3& in a,const AIFloat3& in b) {
        if(fixedPoints.length()<2 || corridor<0 || fixedClass<0)return;
        if(helpingTeam==team && helpingCorridor==corridor) {   // renewed
            helpingUntil=ai.frame+assistSeconds*SECOND;helpingDead=helpingDead || dead;return;
        }
        array<int>@ compatible=aiBattle.CorridorsForClass(fixedClass,a,b,minWidth);
        bool legal=false;
        if(compatible !is null)for(uint i=0;i<compatible.length();++i)if(compatible[i]==corridor)legal=true;
        if(!legal){proposalStatus="movement-class mismatch";return;} // Never route vehicles on bot-only ground.
        const AIFloat3 c=CommanderPos();
        float distance;const float progress=c.x<0?0.f:Progress(fixedPoints,c,distance);
        int index;const AIFloat3 fork=PointAt(fixedPoints,progress,index);
        array<AIFloat3>@ link=aiBattle.CorridorLink(corridor,fork);
        if(link is null || link.length()<2) {
            proposalStatus="no passable helper link";
            GenericHelpers::LogUtil("[CoverageLane] assist refused: no link from progress "+int(progress)+" to corridor "+corridor,1);return;
        }
        Team::Roster::Entry@ e=Team::Roster::Get(team);
        int rank,count;
        if(e !is null)SeatOf(e.teamId,e.startPos,AiRole::FRONT,a,b,rank,count);else{rank=fixedRank;count=fixedCount;}
        const AIFloat3 theirEnd=Nearby(EndFor(rank,count,a,b),fixedClass);
        array<AIFloat3> merged;
        for(int i=0;i<=index;++i)merged.insertLast(fixedPoints[uint(i)]);
        for(uint i=0;i<link.length();++i)merged.insertLast(link[i]);
        if(theirEnd.x>=0) {
            array<AIFloat3>@ rest=aiBattle.CorridorCentre(corridor,link[link.length()-1],theirEnd);
            if(rest !is null)for(uint i=1;i<rest.length();++i)merged.insertLast(rest[i]);
        }
        if(merged.length()<2)return;
        proposalStatus=dead?"income-loss suspect":"observed lane pressure";
        helpingTeam=team;helpingCorridor=corridor;helpingDead=dead;
        helpingUntil=ai.frame+assistSeconds*SECOND;
        forkPoints=merged;
        PublishWidget();
        GenericHelpers::LogUtil("[CoverageLane] proposed assistance for team "+team+" corridor "+corridor+(dead?" (dead seat)":"")
            +" fork at progress "+int(progress)+" link points="+link.length()+" merged points="+merged.length(),1);
    }
    void EndHelp(const string &in why) {
        if(helpingTeam<0)return;
        GenericHelpers::LogUtil("[CoverageLane] assist ended for team "+helpingTeam+": "+why,1);
        helpingTeam=-1;helpingCorridor=-1;helpingUntil=-1;helpingDead=false;proposalStatus="none";
        forkPoints.resize(0);
        PublishWidget();
    }
    void Assist(const AIFloat3& in a,const AIFloat3& in b) {
        if(!assistEnabled || fixedPoints.length()<2)return;
        // expiry of a request-driven fork; a dead seat's merge ends when it lives again
        if(helpingTeam>=0) {
            if(helpingDead && !Dead(helpingTeam))EndHelp("the seat is alive again");
            else if(!helpingDead && ai.frame>helpingUntil)EndHelp("the requests stopped");
        }
        // a dead seat's corridor is merged by its nearest living neighbour
        if(helpingTeam<0) {
            array<Team::Roster::Entry@>@ entries=Seats(AiRole::FRONT);
            for(uint i=0;i<entries.length() && helpingTeam<0;++i) {
                Team::Roster::Entry@ e=entries[i];
                if(e.teamId==ai.teamId || !Dead(e.teamId))continue;
                int rank,count;SeatOf(e.teamId,e.startPos,AiRole::FRONT,a,b,rank,count);
                int corridor=CorridorOfTeam(e.teamId);
                if(corridor<0)corridor=CorridorForRank(rank,count);
                if(corridor<0 || corridor==fixedCorridor || MergerFor(rank,a,b)!=ai.teamId)continue;
                BeginHelp(e.teamId,corridor,true,a,b);
            }
        }
        // own need: ask the chosen neighbour while the lane ahead is held
        const bool need=NeedsHelp();
        if(need) {
            const int helper=ChooseHelper(a,b);
            if(helper>=0) {
                float distance;const float progress=Progress(fixedPoints,CommanderPos(),distance);
                AiSendMessage(AssistPrefix+AssistVersion+"|"+ai.teamId+"|"+fixedCorridor+"|"+int(progress)+"|"+helper+"|1");
                if(!requesting || helper!=requestedHelper)
                    GenericHelpers::LogUtil("[CoverageLane] asking team "+helper+" for assistance on corridor "+fixedCorridor+" at progress "+int(progress),1);
                requesting=true;requestedHelper=helper;
            }
        } else if(requesting) {
            AiSendMessage(AssistPrefix+AssistVersion+"|"+ai.teamId+"|"+fixedCorridor+"|0|"+requestedHelper+"|0");
            GenericHelpers::LogUtil("[CoverageLane] assistance released on corridor "+fixedCorridor,1);
            requesting=false;requestedHelper=-1;
        }
        // INV-238: advisory proposals never mutate the executed fixed lane.
        if(abs(aiBattle.GetFrontLaneLength()-Length(fixedPoints))>1.f)
            Invariants::Violation("INV-238", ""+fixedCorridor, "advisory proposal changed the commander lane");
    }
    // Team::HandleMessage: an ally's corridor claim or assistance request.
    // Returns true when the message was one of ours. Bounded by the sender's
    // point count.
    bool HandleMessage(const string &in msg,int fromTeamId) {
        if(msg.length()>=AssistPrefix.length() && msg.substr(0,AssistPrefix.length())==AssistPrefix) {
            Load();
            array<string>@ parts=msg.split("|");
            if(parts.length()<7 || int(parseInt(parts[1]))!=AssistVersion)return true;
            const int team=int(parseInt(parts[2])),corridor=int(parseInt(parts[3])),helper=int(parseInt(parts[5]));
            const bool asking=parts[6]=="1";
            if(team!=fromTeamId || team==ai.teamId)return true;
            if(asking)requests.set(""+team,int64(ai.frame));else requests.delete(""+team);
            if(!assistEnabled || helper!=ai.teamId || Global::AISettings::Role!=AiRole::FRONT || !frontPublished)return true;
            AIFloat3 a,b;if(!Axis(a,b))return true;
            if(asking)BeginHelp(team,corridor,false,a,b);
            else if(helpingTeam==team && !helpingDead)EndHelp("released by the requester");
            return true;
        }
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
    // Immutable snapshot, one publication per ten-second strategic poll.
    // Terrain routes remain revision-driven; threat sampling is bounded to 33
    // points and never scans units. Values are this AI's legal observations.
    void PublishStrategy() {
        const AIFloat3 c=CommanderPos();
        string payload="1;"+ai.frame+";"+assignmentRevision+";"+fixedClass+";"+fixedCorridor+";"+fixedRank+";"+fixedCount
            +";"+int(c.x)+","+int(c.z)+";"+int(c.x>=0?aiBattle.GetFrontLaneProgress(c):-1.f)
            +";"+helpingTeam+","+helpingCorridor+","+(helpingDead?1:0)+";"+requestedHelper+";"+seatRevision;
        payload+=";"+Record(0,2,-1,fixedPoints)+";"+Record(1,3,-1,forkPoints);
        payload+=";";
        const float length=Length(fixedPoints);
        for(int i=0;i<=32 && length>0;++i) {
            int index;const AIFloat3 p=PointAt(fixedPoints,length*float(i)/32.f,index);
            payload+=(i>0?"|":"")+int(p.x)+","+int(p.z)+","+aiBattle.SurfThreat(p);
        }
        payload+=";"+aiBuilderMgr.DescribeCommanderFront(Builder::commander is null?-1:Builder::commander.id);
        payload+=";"+routeStatus+";"+proposalStatus;
        WidgetLink::SetState("strategy",WidgetLink::Line("strategy",payload));
    }
    void Clear() {
        aiBuilderMgr.SetCommanderCombatOption("front_corridor",-1.f);
        aiBuilderMgr.SetCommanderCombatOption("front_corridor_class",-1.f);
        array<AIFloat3> empty;aiBattle.SetFrontLane(empty,halfWidth);
        frontPublished=false;frontKey="";
        helpingTeam=-1;helpingCorridor=-1;helpingUntil=-1;helpingDead=false;forkPoints.resize(0);
        fixedPoints.resize(0);fixedCorridor=-1;routeStatus="disabled";
        PublishWidget();PublishStrategy();
        Unclaim();
    }
    void Tick() {
        Load();
        if(!enabled || Global::AISettings::Role!=AiRole::FRONT) {
            if(frontPublished)Clear();
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
        array<Team::Roster::Entry@>@ roster=Seats(AiRole::FRONT);
        array<string> signatures;
        for(uint i=0;i<roster.length();++i)signatures.insertLast(""+roster[i].teamId+":"+roster[i].startFactory+":"+int(roster[i].startPos.x)+":"+int(roster[i].startPos.z));
        signatures.sortAsc();string signature;
        for(uint i=0;i<signatures.length();++i)signature+=signatures[i]+";";
        if(seatRevision!=aiBattle.CorridorRevision() || signature!=seatRoster) {
            seatRevision=aiBattle.CorridorRevision();seatRoster=signature;++assignmentRevision;
            Seat(AiRole::FRONT,a,b,fixedRank,fixedCount);
            seatsMatched=ComputeSeats(a,b);
        }
        const int rank=fixedRank,count=fixedCount;
        const int cls=ClassOfFactory(Global::AISettings::StartFactory);
        const int matched=CorridorOfTeam(ai.teamId);
        const float share=(float(rank)+.5f)/float(count);
        const AIFloat3 start=Global::Map::StartPos,end=EndFor(rank,count,a,b);
        if(end.x<0)return;
        const string key=""+rank+":"+count+":"+cls+":"+int(start.x)+":"+int(start.z)+":"+int(end.x)+":"+int(end.z)+":"+int(a.x)+":"+int(a.z)+":"+int(b.x)+":"+int(b.z)+":"+aiBattle.CorridorRevision()+":"+assignmentRevision;
        if(key==frontKey) {
            if(frontPublished){Assist(a,b);PublishStrategy();}
            return;
        }
        // Terrain and these strategic endpoints are immutable for this key.
        // Cache failures too; retry only after a table/endpoint change, and
        // never keep an obsolete seat while its replacement is unreachable.
        frontKey=key;routeStatus="routing";fixedClass=cls;fixedCorridor=-1;
        aiBuilderMgr.SetCommanderCombatOption("front_corridor",-1.f);
        aiBuilderMgr.SetCommanderCombatOption("front_corridor_class",-1.f);
        if(frontPublished) {
            EndHelp("the lane was re-routed");
            array<AIFloat3> empty;aiBattle.SetFrontLane(empty,halfWidth);
            frontPublished=false;fixedPoints.resize(0);
            PublishWidget();
            Unclaim();
        }
        const AIFloat3 from=Nearby(start,cls),to=Nearby(end,cls);
        if(from.x<0 || to.x<0) {
            routeStatus="endpoint unreachable";PublishStrategy();
            GenericHelpers::LogUtil("[CoverageLane] endpoint unreachable rank="+rank+" seats="+count,1);return;
        }
        array<AIFloat3>@ points=Route(from,to,a,b,cls,share,count,matched);
        if(points is null || points.length()<2) {
            routeStatus="route unreachable";PublishStrategy();
            GenericHelpers::LogUtil("[CoverageLane] front unreachable rank="+rank+" seats="+count,1);return;
        }
        if(!aiBattle.SetFrontLane(points,halfWidth)){routeStatus="native route rejected";PublishStrategy();return;}
        // The native lane ends (own start, enemy starts) otherwise exist only
        // once TECH's lane survey runs; the corridor sweep's enemy-home rule
        // (front_mex_enemy_home, CBattleAnalysis::EnemyEndDistance) reads them.
        // Lanes::Compute sets the same values when it runs.
        aiBattle.ClearLaneEnds();
        aiBattle.AddAllyEnd(Global::Map::StartPos);
        array<AIFloat3> enemies=Lanes::EnemyStarts();
        for(uint i=0;i<enemies.length();++i)aiBattle.AddEnemyEnd(enemies[i]);
        frontKey=key;frontPublished=true;routeStatus=lastCorridor>=0?"field corridor":"fallback route";
        fixedPoints=points;fixedClass=cls;fixedCorridor=lastCorridor;
        aiBuilderMgr.SetCommanderCombatOption("front_corridor",float(lastCorridor));
        aiBuilderMgr.SetCommanderCombatOption("front_corridor_class",float(cls));
        PublishWidget();
        Claim(points);
        GenericHelpers::LogUtil("[CoverageLane] front assigned rank="+rank+" seats="+count+" class="+cls+" points="+points.length()+" corridor="+lastCorridor+(matched>=0?" matched":" by share")+" (revision-stable)",1);
        Assist(a,b);
        PublishStrategy();
    }
}
