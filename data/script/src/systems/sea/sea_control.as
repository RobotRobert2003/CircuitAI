// Shared provisional basin/shore snapshot. Five-second publication, no orders.
// O(A + G + S*localAssets + C) for allied assets, cohorts, shore sectors and
// legal contacts. Spatial buckets bound ordinary shore queries; dense buckets
// still cost their actual occupancy. Values/IDs only; rebuilt on publication.
namespace SeaControl {
    class Basin {
        int body=-1, state=0, lastThreat=-1, shores=0, surveyed=0, uncovered=0, total=0;
        float enemy=0, friendly=0;
    }
    array<Basin@> basins;
    array<bool> held;
    array<int> seen;
    dictionary assets, stations;
    int frame=-100000;
    const float BucketSize=640.0f;
    string Key(int body,int x,int z) { return ""+body+":"+x+":"+z; }
    void Add(dictionary &inout buckets,const AIFloat3 &in p,int body=-1) {
        const string key=Key(body,int(p.x/BucketSize),int(p.z/BucketSize));
        array<AIFloat3>@ points;
        if (!buckets.get(key,@points) || points is null) { @points=array<AIFloat3>(); buckets.set(key,@points); }
        points.insertLast(p);
    }
    bool Near(dictionary &inout buckets,const AIFloat3 &in p,float radius,bool sameLand=false,int body=-1) {
        const int x=int(p.x/BucketSize), z=int(p.z/BucketSize);
        int n=int(radius/BucketSize); if (float(n)*BucketSize<radius) ++n;
        const int land=sameLand ? StrategicSites::LandAt(p) : -1;
        for (int dz=-n;dz<=n;++dz) for (int dx=-n;dx<=n;++dx) {
            array<AIFloat3>@ points;
            if (!buckets.get(Key(body,x+dx,z+dz),@points) || points is null) continue;
            for (uint i=0;i<points.length();++i) if (MapHelpers::SqDist(p,points[i])<=radius*radius
                && (!sameLand || (land>=0 && StrategicSites::LandAt(points[i])==land))) return true;
        }
        return false;
    }
    Basin@ Get(int body) {
        for (uint i=0;i<basins.length();++i) if (basins[i].body==body) return basins[i];
        Basin@ b=Basin(); b.body=body; b.lastThreat=ai.frame; basins.insertLast(b); return b;
    }
    void Reset() { basins.resize(0); held.resize(0); seen.resize(0); assets.deleteAll(); stations.deleteAll(); frame=-100000; }
    bool NeedsGuard(int sector) { return sector>=0 && sector<int(held.length()) && !held[sector]; }
    bool Surveyed(int sector) {
        return sector>=0 && sector<int(seen.length()) && seen[sector]>=0
            && ai.frame-seen[sector]<=Global::RoleSettings::Sea::SeaControlSurveySeconds*SECOND;
    }
    bool NeedSubs(int body) {
        Basin@ b=Get(body); return b.state!=3 || b.uncovered>0;
    }
    void Tick() {
        if (ai.frame-frame<5*SECOND) return;
        frame=ai.frame; SeaPatrol::Grid(); SeaShorelines::Init();
        if (!SeaShorelines::ready) return;
        assets.deleteAll(); stations.deleteAll();
        const int count=aiBattle.GetAllyAssetCount();
        for (int i=0;i<count;++i) Add(assets,aiBattle.GetAllyAssetPos(i));
        // Station coverage requires physical arrival, not merely a leased goal.
        for (uint i=0;i<SeaOperations::groups.length();++i) {
            SeaOperations::Cohort@ g=SeaOperations::groups[i];
            if (g.target!=-7 || g.coastTarget<0 || g.coastTarget>=int(SeaPatrol::sectors.length())
                || g.ids.length()==0 || g.route is null || g.route.IsDead()
                || MapHelpers::SqDist(g.centre,g.coastGoal)>256.0f*256.0f) continue;
            Add(stations,SeaPatrol::sectors[g.coastTarget].pos,g.body);
        }
        for (uint i=0;i<basins.length();++i) {
            Basin@ b=basins[i]; b.shores=0; b.surveyed=0; b.uncovered=0; b.total=0; b.enemy=0; b.friendly=0;
        }
        const uint size=SeaPatrol::sectors.length(), old=seen.length();
        held.resize(size); seen.resize(size);
        for (uint i=old;i<size;++i) seen[i]=-100000;
        for (uint i=0;i<size;++i) {
            SeaPatrol::Sector@ s=SeaPatrol::sectors[i]; held[i]=true;
            if (!s.shore || s.landAnchor.x<0) continue;
            Basin@ b=Get(s.body);
            ++b.total;
            const bool visible=aiBattle.InLos(s.landAnchor);
            // A passing scout is not ownership. Only visible occupied coastline
            // is released, never an entire connected continent from one mex.
            held[i]=visible && Near(assets,s.landAnchor,Global::RoleSettings::Sea::ShoreAlliedAssetRadius,true);
            if (visible || s.visited>seen[i]) seen[i]=visible ? ai.frame : s.visited;
            if (held[i]) continue;
            ++b.shores;
            if (Surveyed(int(i))) ++b.surveyed;
            if (!Near(stations,s.pos,Global::RoleSettings::Sea::ShoreStationCoverageRadius,false,s.body)) ++b.uncovered;
        }
        const int contacts=aiBattle.GetSeaForceCount();
        for (int i=0;i<contacts;++i) {
            const int body=aiBattle.GetSeaForceBody(i), flags=aiBattle.GetSeaForceFlags(i);
            if (body<0) continue;
            Basin@ b=Get(body);
            const int id=aiBattle.GetSeaForceDefId(i);
            const CCircuitDef@ d=id>=0 ? ai.GetCircuitDef(id) : null;
            const bool armed=d !is null && (d.HasSurfToLand() || d.HasSurfToWater() || d.HasSubToWater());
            if ((flags&1)!=0) {
                if (armed && (flags&8)==0) b.friendly+=aiBattle.GetSeaForceCost(i);
            } else if (armed || (flags&(16|32))!=0) {
                // Remembered contacts remain uncertainty, not fresh sightings.
                b.enemy+=(flags&16)!=0 ? Global::RoleSettings::Sea::UnknownSubContactMetal : AiMax(1.0f,aiBattle.GetSeaForceCost(i));
                if ((flags&128)==0) b.lastThreat=ai.frame;
            }
        }
        for (uint i=0;i<basins.length();++i) {
            Basin@ b=basins[i]; const int before=b.state;
            b.state=SeaMath::ControlState(b.enemy,b.friendly,ai.frame-b.lastThreat,
                Global::RoleSettings::Sea::SeaControlQuietSeconds*SECOND,
                b.shores==0 ? b.total : b.surveyed,b.shores==0 ? b.total : b.shores,
                Global::RoleSettings::Sea::SeaControlSurveyFraction,Global::RoleSettings::Sea::SeaControlMinimumFleet);
            if (before!=b.state || ai.frame%(30*SECOND)<5*SECOND)
                GenericHelpers::LogUtil("[SEA][Control] body="+b.body+" state="+b.state+" enemy="+b.enemy
                    +" friendly="+b.friendly+" shores="+b.shores+" surveyed="+b.surveyed+" uncovered="+b.uncovered,1);
        }
    }
}
