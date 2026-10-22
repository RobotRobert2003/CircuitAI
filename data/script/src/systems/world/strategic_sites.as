// Advisory data only. The widget projects these results; it makes no strategic decisions.
namespace StrategicSites {
    class Geo { AIFloat3 pos; int use = 0; float coverage = 0; bool friendly = false; }
    class Island { AIFloat3 pos; float radius = 0; int cells = 0; }
    class Beach { array<AIFloat3> points; array<AIFloat3> normals; int use = 0; }
    array<Geo@> geos;
    array<Island@> islands;
    array<Beach@> beaches;
    array<int> land;
    bool mapped = false;
    // D-287: assault (use == 1) beach fronts of the last survey. Read-only for
    // consumers (TechHeavyChoice); counted once per survey, O(beaches).
    int assaultBeaches = 0;

    int LandAt(const AIFloat3& in p) {
        const int x = int(p.x) / 64, z = int(p.z) / 64;
        if (p.x < 0 || p.z < 0 || x >= WaterTheatres::width || z >= WaterTheatres::height) return -1;
        return land[z * WaterTheatres::width + x];
    }
    void Islands(const array<AIFloat3>& in ours, const array<AIFloat3>& in theirs) {
        if (mapped) return;
        mapped = true;
        const int w = WaterTheatres::width, h = WaterTheatres::height;
        land.resize(w*h);
        for (int c=0; c<w*h; ++c) land[c] = aiBattle.Height(WaterTheatres::Pos(c)) >= 0 ? -2 : -1;
        int id=0;
        const int minimum = AiMax(1, aiSetupMgr.ConfigInt("lanes/island_min_cells", 3));
        for (int seed=0; seed<w*h; ++seed) {
            if (land[seed] != -2) continue;
            array<int> queue = {seed}; land[seed]=id;
            AIFloat3 centre;
            bool edge=false;
            for (uint k=0; k<queue.length(); ++k) {
                const int c=queue[k], x=c%w, z=c/w;
                centre = centre + WaterTheatres::Pos(c);
                if (x==0 || z==0 || x==w-1 || z==h-1) edge=true;
                array<int> next = {x>0?c-1:-1,x<w-1?c+1:-1,z>0?c-w:-1,z<h-1?c+w:-1};
                for (uint j=0; j<next.length(); ++j) {
                    const int n=next[j];
                    if (n>=0 && land[n]==-2) { land[n]=id; queue.insertLast(n); }
                }
            }
            bool spawn=false;
            for (uint j=0;j<ours.length();++j) if (LandAt(ours[j])==id) spawn=true;
            for (uint j=0;j<theirs.length();++j) if (LandAt(theirs[j])==id) spawn=true;
            if (!edge && !spawn && int(queue.length())>=minimum && queue.length()<uint(w*h/50)) {
                centre = centre / float(queue.length());
                float best=1e20f;
                Island@ item=Island(); item.cells=int(queue.length());
                for (uint j=0;j<queue.length();++j) {
                    const AIFloat3 p=WaterTheatres::Pos(queue[j]);
                    const float d=p.distance2D(centre);
                    if (d<best) { best=d; item.pos=p; }
                    item.radius=AiMax(item.radius,d+32);
                }
                // A small land component must border a shared sea, not a pond or map-edge fragment.
                bool sea=false;
                for (uint j=0;j<queue.length();++j) {
                    const int c=queue[j], x=c%w, z=c/w;
                    array<int> wet={WaterTheatres::At(x-1,z),WaterTheatres::At(x+1,z),WaterTheatres::At(x,z-1),WaterTheatres::At(x,z+1)};
                    for (uint k=0;k<wet.length();++k)
                        if (wet[k]>=0 && WaterTheatres::bodies[wet[k]].shared) sea=true;
                }
                if (sea) islands.insertLast(item);
            }
            ++id;
        }
    }
    void Geothermal(const array<AIFloat3>& in ours, const array<AIFloat3>& in theirs) {
        geos.resize(0);
        const CCircuitDef@ battery=ai.GetCircuitDef("corbhmth");
        const float threshold=aiSetupMgr.ConfigFloat("lanes/geo_battery_coverage",0.6f);
        for (int i=0;i<ai.GetGeoSpotCount();++i) {
            Geo@ g=Geo(); g.pos=ai.GetGeoSpot(i);
            const float a=WaterTheatres::Distance(g.pos,ours), e=WaterTheatres::Distance(g.pos,theirs);
            g.friendly=a<e*WaterTheatres::territoryRatio;
            AIFloat3 target(-1,0,-1); float nearest=1e20f;
            for (uint j=0;j<theirs.length();++j) {
                const float d=g.pos.distance2D(theirs[j]);
                if (d<nearest) { nearest=d; target=theirs[j]; }
            }
            if (battery !is null && target.x>=0 && nearest>1) {
                const AIFloat3 dir=(target-g.pos)/nearest;
                const float range=aiBattle.MainRange(battery);
                int clear=0, total=0;
                // Forward fan, three radii. Straight terrain visibility is a conservative
                // screening heuristic, not a claim to simulate the cannon's ballistic arc.
                for (int k=-3;k<=3;++k) {
                    const float angle=float(k)*0.26f;
                    const float dx=dir.x*cos(angle)-dir.z*sin(angle), dz=dir.x*sin(angle)+dir.z*cos(angle);
                    for (int r=1;r<=3;++r) {
                        AIFloat3 p(g.pos.x+dx*range*float(r)/3,0,g.pos.z+dz*range*float(r)/3);
                        if (p.x<0 || p.z<0 || p.x>=AiTerrainWidth() || p.z>=AiTerrainHeight()) continue;
                        ++total;
                        if (g.pos.distance2D(p)<=aiBattle.EffectiveRange(battery,g.pos,p) && aiBattle.LineOfFire(g.pos,p,40)) ++clear;
                    }
                }
                g.coverage=total>0 ? float(clear)/total : 0;
                float laneDistance=1e20f;
                for (int l=0;l<aiBattle.GetLaneCount();++l) {
                    if (aiBattle.GetLaneClass(l)>4) continue;
                    for (int j=1;j<20;++j) laneDistance=AiMin(laneDistance,g.pos.distance2D(aiBattle.GetLanePoint(l,float(j)/20)));
                }
                const float share=a/AiMax(1.0f,a+e);
                g.use=g.coverage>=threshold && laneDistance<range && share>0.25f && share<0.75f ? 1 : 0;
            }
            geos.insertLast(g);
            GenericHelpers::LogUtil("[Strategic] geo " + i + " at " + int(g.pos.x) + "," + int(g.pos.z)
                + " " + (g.use==1?"BATTERY":"POWER") + " forward visibility=" + int(g.coverage*100) + "%",1);
        }
    }
    void Beaches(const array<AIFloat3>& in ours, const array<AIFloat3>& in theirs) {
        beaches.resize(0);
        array<AIFloat3> starts, ends, normals; array<int> uses;
        const float grade=aiSetupMgr.ConfigFloat("lanes/beach_max_grade",0.3f);
        for (uint i=0;i<WaterTheatres::bodies.length();++i) {
            WaterTheatres::Body@ body=WaterTheatres::bodies[i];
            if (!body.shared || body.pond) continue;
            for (uint j=0;j<body.shore.length();++j) {
                const int c=body.shore[j], x=c%WaterTheatres::width, z=c/WaterTheatres::width;
                array<int> dx={-1,1,0,0}, dz={0,0,-1,1};
                for (int k=0;k<4;++k) {
                    if (WaterTheatres::At(x+dx[k],z+dz[k])>=0) continue;
                    const AIFloat3 wet=WaterTheatres::Pos(c), normal(float(dx[k]),0,float(dz[k]));
                    const AIFloat3 mid=wet+normal*32;
                    const AIFloat3 inland=mid+normal*128;
                    if (inland.x<0 || inland.z<0 || inland.x>=AiTerrainWidth() || inland.z>=AiTerrainHeight()) continue;
                    if (aiBattle.Height(inland)<0 || (aiBattle.Height(inland)-aiBattle.Height(wet))/160>grade) continue;
                    const int component=LandAt(inland);
                    bool mainland=false;
                    for (uint q=0;q<ours.length();++q) if (LandAt(ours[q])==component) mainland=true;
                    for (uint q=0;q<theirs.length();++q) if (LandAt(theirs[q])==component) mainland=true;
                    if (!mainland || component<0) continue;
                    const float a=WaterTheatres::Distance(mid,ours), e=WaterTheatres::Distance(mid,theirs);
                    const int use=a<e*WaterTheatres::territoryRatio?0:(e<a*WaterTheatres::territoryRatio?1:2);
                    if (use==2) continue;
                    const AIFloat3 tangent(-normal.z*32,0,normal.x*32);
                    starts.insertLast(mid-tangent); ends.insertLast(mid+tangent); normals.insertLast(normal); uses.insertLast(use);
                }
            }
        }
        array<bool> used(starts.length(),false);
        for (uint i=0;i<starts.length();++i) {
            if (used[i]) continue;
            Beach@ b=Beach(); b.use=uses[i]; used[i]=true;
            b.points.insertLast(starts[i]); b.points.insertLast(ends[i]); b.normals.insertLast(normals[i]);
            bool extended=true;
            while (extended) {
                extended=false;
                for (uint j=0;j<starts.length();++j) {
                    if (used[j] || uses[j]!=b.use) continue;
                    if (b.points[b.points.length()-1].distance2D(starts[j])<1) {
                        b.points.insertLast(ends[j]); b.normals.insertLast(normals[j]); used[j]=true; extended=true;
                    } else if (b.points[0].distance2D(ends[j])<1) {
                        b.points.insertAt(0,starts[j]); b.normals.insertAt(0,normals[j]); used[j]=true; extended=true;
                    }
                }
            }
            if (b.normals.length()*64>=uint(AiMax(64,aiSetupMgr.ConfigInt("lanes/beach_min_length",384)))) beaches.insertLast(b);
        }
        assaultBeaches = 0;
        for (uint i=0;i<beaches.length();++i) if (beaches[i].use==1) ++assaultBeaches;
    }
    void Analyse(const array<AIFloat3>& in ours, const array<AIFloat3>& in theirs) {
        Islands(ours,theirs); Geothermal(ours,theirs); Beaches(ours,theirs);
        GenericHelpers::LogUtil("[Strategic] survey: " + geos.length() + " geos, " + islands.length() + " air-first islands, " + beaches.length() + " beach fronts (" + assaultBeaches + " assault); advisory only",1);
    }
}
