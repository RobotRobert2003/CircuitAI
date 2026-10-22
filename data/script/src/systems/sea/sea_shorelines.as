// SEA terrain intelligence shared by patrol and submarine station selection.
// Bounded work per census, no per-boat terrain searches. The rotating survey
// refreshes terrain feasibility rather than caching it forever after deformation.
namespace SeaShorelines {
    array<int> shoreline;
    array<AIFloat3> starts;
    array<AIFloat3> enemyBox, friendlyBox;
    array<array<AIFloat3>@> coast;
    int coastWidth=0, coastHeight=0;
    bool boxed=false;
    // Immutable public start regions: at most 16*16 samples once per AI.
    // Overlapping/full-map default boxes carry no side information.
    void PrepareBoxes() {
        const float step=float(AiMax(AiTerrainWidth(),AiTerrainHeight()))/16.0f;
        for (float z=step*.5f;z<AiTerrainHeight();z+=step)
            for (float x=step*.5f;x<AiTerrainWidth();x+=step) {
                const AIFloat3 p(x,0,z);
                const int enemy=aiSetupMgr.EnemyStartBoxAt(p), friendly=aiSetupMgr.FriendlyStartBoxAt(p);
                if (enemy==1 && friendly==0) enemyBox.insertLast(p);
                if (friendly==1 && enemy==0) friendlyBox.insertLast(p);
            }
        boxed=enemyBox.length()>0 && friendlyBox.length()>0;
        GenericHelpers::LogUtil("[SEA][StartBoxes] usable="+boxed+" enemy="+enemyBox.length()+" friendly="+friendlyBox.length(),1);
    }
    void BuildCoast() {
        // Trace edges of the existing 64-elmo connected-land grid once. Rays
        // across a whole survey cell can hit an intervening metal rock; adjacent
        // dry/wet cells keep the waterline on the chosen meaningful component.
        const int width=WaterTheatres::width;
        for (uint index=0;index<StrategicSites::land.length();++index) {
            if (StrategicSites::land[index]<0) continue;
            const AIFloat3 anchor=WaterTheatres::Pos(int(index));
            if (!Guardable(anchor)) continue;
            const int column=int(index)%width;
            for (int direction=0;direction<4;++direction) {
                const int neighbor=direction==0 ? (column>0 ? int(index)-1 : -1)
                    : direction==1 ? (column<width-1 ? int(index)+1 : -1)
                    : direction==2 ? int(index)-width : int(index)+width;
                if (neighbor<0 || neighbor>=int(StrategicSites::land.length()) || StrategicSites::land[neighbor]>=0) continue;
                AIFloat3 wet=WaterTheatres::Pos(neighbor), dry=anchor;
                for (int step=0;step<8;++step) {
                    const AIFloat3 middle=(wet+dry)*.5f;
                    if (aiBattle.Height(middle)>=0) dry=middle; else wet=middle;
                }
                const int key=int(dry.z/SeaPatrol::cell)*coastWidth+int(dry.x/SeaPatrol::cell);
                array<AIFloat3>@ points=coast[key];
                if (points is null) { @points=array<AIFloat3>(); @coast[key]=points; }
                points.insertLast(dry);
            }
        }
    }
    AIFloat3 NearestCoast(const AIFloat3 &in p,float radius) {
        const int x=int(p.x/SeaPatrol::cell), z=int(p.z/SeaPatrol::cell);
        const int span=int(radius/SeaPatrol::cell)+1;
        float best=radius*radius; AIFloat3 found(-1,0,-1);
        for (int dz=-span;dz<=span;++dz) for (int dx=-span;dx<=span;++dx) {
            const int cx=x+dx, cz=z+dz;
            if (cx<0 || cz<0 || cx>=coastWidth || cz>=coastHeight) continue;
            // Dense nullable bucket index avoids allocating dictionary keys in
            // contour searches; points share the initial terrain-cache lifetime.
            array<AIFloat3>@ points=coast[cz*coastWidth+cx];
            if (points is null) continue;
            for (uint i=0;i<points.length();++i) {
                const float distance=MapHelpers::SqDist(p,points[i]);
                if (distance<best) { best=distance; found=points[i]; }
            }
        }
        return found;
    }
    AIFloat3 Contour(const AIFloat3 &in seed,float range) {
        AIFloat3 p=seed;
        // Local buckets, three projections only on station assignment. Actual
        // hull depth/reachability and observed weapon safety remain separate.
        for (int i=0;i<3;++i) {
            const AIFloat3 shore=NearestCoast(p,range+2*SeaPatrol::cell);
            if (shore.x<0) return AIFloat3(-1,0,-1);
            const AIFloat3 away=p-shore;
            const float length=sqrt(away.x*away.x+away.z*away.z);
            if (length<1) return AIFloat3(-1,0,-1);
            p=shore+away*(range/length);
        }
        return p;
    }
    array<CCircuitDef@> commanders, constructors, yards;
    int cursor=0, nextCycle=0;
    bool ready=false;
    bool landReady=false;
    array<int> landCells, interiorCells;
    array<bool> factoryLand;
    array<bool> factoryAccess;
    array<AIFloat3> factoryPads;
    bool FactoryPad(const AIFloat3 &in centre,int component) {
        // Terrain only: occupancy and reservations must not erase an existing
        // enemy base's strategic value. Loaded factory footprints plus clearance
        // are sampled at 16 elmos; grades are checked along both grid axes.
        const float step=16.0f;
        for (uint pad=0;pad<factoryPads.length();++pad) {
            const AIFloat3 size=factoryPads[pad];
            array<float> previous(int(2*size.x/step)+1);
            float low=1e30f, high=-1e30f; bool valid=true;
            for (int row=0;row<=int(2*size.z/step) && valid;++row) {
                const float z=-size.z+float(row)*step;
                float left=0;
                for (int column=0;column<=int(2*size.x/step);++column) {
                    const float x=-size.x+float(column)*step;
                    const AIFloat3 p(centre.x+x,0,centre.z+z);
                    const float height=aiBattle.Height(p);
                    if (height<0 || StrategicSites::LandAt(p)!=component) { valid=false; break; }
                    low=AiMin(low,height); high=AiMax(high,height);
                    const float grade=Global::RoleSettings::Sea::ShoreFactoryMaximumGrade*step;
                    if (high-low>Global::RoleSettings::Sea::ShoreFactoryHeightVariation
                        || (column>0 && abs(height-left)>grade) || (row>0 && abs(height-previous[column])>grade)) { valid=false; break; }
                    previous[column]=height; left=height;
                }
            }
            if (valid) {
                if (Global::RoleSettings::Sea::ScoutDiagnostics && !factoryLand[component])
                    GenericHelpers::LogUtil("[SEA][FactoryPad] component="+component+" x="+int(centre.x)+" z="+int(centre.z),1);
                return true;
            }
        }
        return false;
    }
    array<bool> enemyLand;
    // Reuse the public connected-land map: one O(map cells) pass, no engine
    // callbacks or flood fills per boat. IDs share StrategicSites::land's
    // immutable lifetime. Live threat and movement checks remain mandatory.
    bool PrepareLand() {
        if (landReady) return true;
        // Do not depend on lane generation/overlay being enabled. Analyse the
        // shared water map first: Islands also reads its shore affiliation.
        if (!StrategicSites::mapped) {
            const array<AIFloat3> allies=Lanes::AllyStarts(), enemies=Lanes::EnemyStarts();
            WaterTheatres::Analyse(allies,enemies);
            StrategicSites::Islands(allies,enemies);
        }
        if (StrategicSites::land.length()==0) return false;
        const int width=WaterTheatres::width;
        for (uint index=0;index<StrategicSites::land.length();++index) {
            const int component=StrategicSites::land[index];
            if (component<0) continue;
            if (component>=int(landCells.length())) {
                landCells.resize(component+1); interiorCells.resize(component+1);
            }
            ++landCells[component];
            const int column=int(index)%width;
            if (column>0 && column<width-1 && int(index)>=width && int(index)+width<int(StrategicSites::land.length())
                && StrategicSites::land[index-1]==component && StrategicSites::land[index+1]==component
                && StrategicSites::land[index-width]==component && StrategicSites::land[index+width]==component)
                ++interiorCells[component];
        }
        for (uint i=0;i<Global::RoleSettings::Sea::ShoreFactoryDefinitions.length();++i) {
            CCircuitDef@ factory=ai.GetCircuitDef(Global::RoleSettings::Sea::ShoreFactoryDefinitions[i]);
            if (factory is null) continue;
            const float margin=Global::RoleSettings::Sea::ShoreFactoryClearance;
            const AIFloat3 size(factory.GetFootprintX()*8.0f+margin,0,factory.GetFootprintZ()*8.0f+margin);
            bool duplicate=false;
            for (uint j=0;j<factoryPads.length();++j) if (factoryPads[j].x==size.x && factoryPads[j].z==size.z) duplicate=true;
            if (!duplicate) factoryPads.insertLast(size);
        }
        factoryLand.resize(landCells.length());
        factoryAccess.resize(StrategicSites::land.length());
        // Initial 128-elmo pad lattice, with local access stamped into the
        // existing 64-elmo grid. O(cells * footprint samples + pads * radius^2)
        // once per terrain lifetime; subsequent Guardable queries are O(1).
        const int reach=int(Global::RoleSettings::Sea::ShoreFactoryAccessRadius/64.0f);
        for (uint index=0;index<StrategicSites::land.length();++index) {
            const int component=StrategicSites::land[index];
            const int x=int(index)%width, z=int(index)/width;
            if (component<0 || x%2!=0 || z%2!=0
                || !SeaMath::GuardableLand(landCells[component],interiorCells[component],
                    Global::RoleSettings::Sea::ShoreMinimumLandCells,Global::RoleSettings::Sea::ShoreMinimumInteriorCells)) continue;
            if (!FactoryPad(WaterTheatres::Pos(int(index)),component)) continue;
            factoryLand[component]=true;
            for (int dz=-reach;dz<=reach;++dz) for (int dx=-reach;dx<=reach;++dx) {
                const int cx=x+dx, cz=z+dz;
                if (dx*dx+dz*dz>reach*reach || cx<0 || cx>=width || cz<0 || cz>=WaterTheatres::height) continue;
                const int cell=cz*width+cx;
                if (StrategicSites::land[cell]==component) factoryAccess[cell]=true;
            }
        }
        int supported=0, rejected=0;
        for (uint i=0;i<factoryLand.length();++i) {
            if (factoryLand[i]) ++supported;
            else if (SeaMath::GuardableLand(landCells[i],interiorCells[i],
                Global::RoleSettings::Sea::ShoreMinimumLandCells,Global::RoleSettings::Sea::ShoreMinimumInteriorCells)) ++rejected;
        }
        GenericHelpers::LogUtil("[SEA][FactoryShore] supported="+supported+" rejected="+rejected,1);
        landReady=true; return true;
    }
    bool Guardable(const AIFloat3 &in position) {
        if (!landReady) return false;
        const int component=StrategicSites::LandAt(position);
        const int cell=int(position.z)/64*WaterTheatres::width+int(position.x)/64;
        return component>=0 && component<int(landCells.length()) && factoryLand[component] && factoryAccess[cell]
            && SeaMath::GuardableLand(landCells[component],interiorCells[component],
                Global::RoleSettings::Sea::ShoreMinimumLandCells,Global::RoleSettings::Sea::ShoreMinimumInteriorCells);
    }
    bool MeaningfulShore(SeaPatrol::Sector@ sector, float radius, bool enemyOnly=false) {
        for (int direction=0;direction<Directions;++direction) {
            const float angle=direction*AngleStep;
            for (int sample=1;sample<=EdgeSamples;++sample) {
                const float distance=radius*float(sample)/EdgeSamples;
                const AIFloat3 land= AIFloat3(sector.pos.x+cos(angle)*distance,0,sector.pos.z+sin(angle)*distance);
                if (!Guardable(land)) continue;
                if (!enemyOnly) return true;
                const int component=StrategicSites::LandAt(land);
                if (component>=0 && component<int(enemyLand.length()) && enemyLand[component]) return true;
            }
        }
        return false;
    }
    const int Directions=8;
    const int EdgeSamples=8;
    const float AngleStep=0.785398163f;
    const float MinimumDepth=-20.0f;
    const int RefreshSeconds=300;
    const float OpeningYardRadius=1200.0f;
    void Init() {
        if (ready || !PrepareLand()) return;
        ready=true; starts=Lanes::EnemyStarts(); PrepareBoxes();
        coastWidth=int(AiTerrainWidth()/SeaPatrol::cell)+1;
        coastHeight=int(AiTerrainHeight()/SeaPatrol::cell)+1;
        coast.resize(coastWidth*coastHeight);
        const array<AIFloat3> allies=Lanes::AllyStarts();
        const float scoutRadius=AiMax(SeaPatrol::cell,Global::RoleSettings::Sea::ScoutShoreProbeRadius);
        // Same per-AI lifetime as StrategicSites::land and the public initial
        // starts. Proximity alone must not promote an unoccupied rock island.
        enemyLand.resize(landCells.length());
        for (uint i=0;i<starts.length();++i) {
            const int component=StrategicSites::LandAt(starts[i]);
            if (component>=0 && component<int(enemyLand.length())) enemyLand[component]=true;
        }
        if (boxed && Global::Map::Config.StartSpots !is null) {
            // Include every supported starting approach inside the enemy box,
            // not only the spot selected by a currently playing team. Keep the
            // terrain component filter: box water is not itself an approach.
            for (uint i=0;i<Global::Map::Config.StartSpots.length();++i) {
                const AIFloat3 p=Global::Map::Config.StartSpots[i].pos;
                if (aiSetupMgr.EnemyStartBoxAt(p)!=1 || aiSetupMgr.FriendlyStartBoxAt(p)==1) continue;
                const int component=StrategicSites::LandAt(p);
                if (component>=0 && component<int(enemyLand.length())) enemyLand[component]=true;
            }
        }
        const array<string> commanderNames={"armcom","corcom","legcom"};
        const array<string> constructorNames={"armck","corck","legck","armcv","corcv","legcv"};
        const array<string> yardNames={"armsy","corsy","legsy"};
        for (uint i=0;i<commanderNames.length();++i) commanders.insertLast(ai.GetCircuitDef(commanderNames[i]));
        for (uint i=0;i<constructorNames.length();++i) constructors.insertLast(ai.GetCircuitDef(constructorNames[i]));
        for (uint i=0;i<yardNames.length();++i) yards.insertLast(ai.GetCircuitDef(yardNames[i]));
        for (uint i=0;i<SeaPatrol::sectors.length();++i) {
            SeaPatrol::Sector@ sector=SeaPatrol::sectors[i];
            sector.enemyDistance=WaterTheatres::Distance(sector.pos,boxed ? enemyBox : starts);
            // Public water starts also permit an opening commander shipyard
            // away from land. Cover that disk, not only the adjacent beaches.
            sector.shore=MeaningfulShore(sector,SeaPatrol::cell);
            // Once per map: at most 128 additional cached terrain probes per
            // sector and O(allied starts) distance comparisons. No new periodic
            // scan or command-emission path. Keep submarine classification.
            // Supreme's edge yards sit beyond the first 320-elmo shore band;
            // treating them as interior also redirected their survey goals.
            // Physical regression: supreme-edge-scouts (delayed edge yard).
            sector.scoutShore=sector.shore || MeaningfulShore(sector,scoutRadius);
            // One public-terrain anchor per shoreline sector, including islands.
            // Live occupation/visibility is evaluated separately by SeaControl.
            if (sector.scoutShore) for (int sample=1;sample<=EdgeSamples && sector.landAnchor.x<0;++sample)
                for (int direction=0;direction<Directions;++direction) {
                    const float a=direction*AngleStep, r=scoutRadius*float(sample)/EdgeSamples;
                    const AIFloat3 p(sector.pos.x+cos(a)*r,0,sector.pos.z+sin(a)*r);
                    if (Guardable(p) && aiBattle.Height(p)>=0) { sector.landAnchor=p; break; }
                }
            // Compare whole public start regions, not a single chosen player
            // position. Terrain/yard feasibility still determines approaches.
            const int enemy=aiSetupMgr.EnemyStartBoxAt(sector.landAnchor);
            const int friendly=aiSetupMgr.FriendlyStartBoxAt(sector.landAnchor);
            sector.enemyScoutShore=sector.scoutShore && MeaningfulShore(sector,scoutRadius,true) && (boxed
                ? (enemy==1 && friendly!=1) || (friendly!=1 && sector.enemyDistance<WaterTheatres::Distance(sector.pos,friendlyBox))
                : sector.enemyDistance<WaterTheatres::Distance(sector.pos,allies));
            sector.enemyEdgeShore=sector.enemyScoutShore
                && (sector.pos.x<scoutRadius || sector.pos.z<scoutRadius
                    || sector.pos.x>AiTerrainWidth()-scoutRadius || sector.pos.z>AiTerrainHeight()-scoutRadius);
            sector.priority=WaterTheatres::Distance(sector.pos,starts)<=OpeningYardRadius ? 2 : sector.shore ? 1 : 0;
            if (sector.shore) shoreline.insertLast(int(i));

        }
        BuildCoast();
        GenericHelpers::LogUtil("[SEA][ShoreClassification] components="+landCells.length()
            +" meaningfulSectors="+shoreline.length()+" waterSectors="+SeaPatrol::sectors.length(),1);
    }
    bool Reachable(CCircuitDef@ definition,const AIFloat3 &in position) {
        if (definition is null) return false;
        for (uint i=0;i<starts.length();++i)
            if (aiTerrainMgr.CanTraverse(definition,starts[i],position)) return true;
        return false;
    }
    bool YardFits(const AIFloat3 &in water) {
        for (uint i=0;i<yards.length();++i) if (yards[i] !is null)
            for (int facing=0;facing<4;++facing)
                if (aiTerrainMgr.BuildableFraction(yards[i],water,0,0,facing)>=1.0f) return true;
        return false;
    }
    bool ConstructionAccess(SeaPatrol::Sector@ sector) {
        for (int direction=0;direction<Directions;++direction) {
            const float angle=direction*AngleStep;
            const AIFloat3 land=Spam::_Clamp(AIFloat3(sector.pos.x+cos(angle)*SeaPatrol::cell,0,
                sector.pos.z+sin(angle)*SeaPatrol::cell));
            if (!Guardable(land) || aiBattle.Height(land)<0) continue;
            // Sample the water side of the coast, not just the centre of a
            // coarse water cell that may be beyond a constructor's build range.
            for (int sample=1;sample<=EdgeSamples;++sample) {
                const float fraction=float(sample)/EdgeSamples;
                const AIFloat3 water=land+(sector.pos-land)*fraction;
                if (aiBattle.Height(water)>MinimumDepth || !YardFits(water)) continue;
                const float height=aiBattle.Height(land)-aiBattle.Height(water);
                // Global water connectivity alone does not make this cliff a
                // land-to-sea approach. Rank a local descent, not a commander
                // reaching the water by walking around a distant peninsula.
                const float horizontal=sqrt(MapHelpers::SqDist(land,water));
                if (height<=horizontal*Global::RoleSettings::Sea::ShoreApproachGrade)
                    for (uint i=0;i<commanders.length();++i)
                        if (Reachable(commanders[i],land) && Reachable(commanders[i],water)) return true;
                const float distance=MapHelpers::SqDist(land,water)+height*height;
                for (uint i=0;i<constructors.length();++i) {
                    CCircuitDef@ builder=constructors[i];
                    if (builder !is null && distance<=builder.GetBuildDistance()*builder.GetBuildDistance()
                        && Reachable(builder,land)) return true;
                }
                // Further samples only move away from this dry build position.
                break;
            }
        }
        return false;
    }
    void Tick() {
        Init();
        if (ai.frame<nextCycle || shoreline.length()==0) return;
        const int budget=AiMin(int(shoreline.length()),AiMax(1,Global::RoleSettings::Sea::ShoreAccessCandidatesPerTick));
        for (int work=0;work<budget;++work) {
            SeaPatrol::Sector@ sector=SeaPatrol::sectors[shoreline[cursor]];
            sector.priority=WaterTheatres::Distance(sector.pos,starts)<=OpeningYardRadius || ConstructionAccess(sector) ? 2 : 1;
            sector.enemyDistance=WaterTheatres::Distance(sector.pos,boxed ? enemyBox : starts);
            if (++cursor>=int(shoreline.length())) { cursor=0; nextCycle=ai.frame+RefreshSeconds*SECOND; break; }
        }
    }
    int ScoutPriority(SeaPatrol::Sector@ sector) {
        if (!sector.enemyScoutShore) return sector.priority;
        return Global::RoleSettings::Sea::EnemyShoreScoutPriority+2*sector.priority
            + (sector.enemyEdgeShore ? AiMax(0,Global::RoleSettings::Sea::EnemyShoreEdgeBonus) : 0);
    }
    int Interval(SeaPatrol::Sector@ sector) {
        return AiMax(1,sector.enemyScoutShore ? Global::RoleSettings::Sea::EnemyShoreRevisitSeconds
            : sector.priority==2 ? Global::RoleSettings::Sea::ConstructorShoreRevisitSeconds
            : sector.scoutShore ? Global::RoleSettings::Sea::OtherShoreRevisitSeconds
            : Global::RoleSettings::Sea::InteriorRevisitSeconds)*SECOND;
    }
}

