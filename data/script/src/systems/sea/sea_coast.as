#include "../../helpers/math/sea_coast_math.as"

// D-219: SEA's land recovery owner. It is dormant during the naval opening and
// while any useful, safe shipyard/constructor/combat hull holds the home sea.
// Native reservations, pathfinding, task lifecycle and combat remain mechanism;
// admission, beach ownership, build order and hysteresis are script policy.
namespace SeaCoast {
    class Sector {
        AIFloat3 beach, sea;
    }
    class Project {
        IUnitTask@ task;
        int slot=-1;
    }
    class Screen {
        int unit=-1, sector=-1, ordered=-100000;
        AIFloat3 goal;
        CRouteTask@ route;
    }
    array<Sector@> sectors;
    array<Project@> projects;
    array<Screen@> screens;
    dictionary screenById;
    array<int> owned;
    dictionary caps, openedCaps;
    bool held=false, fallback=false, loaded=false;
    int body=-1, tick=-100000, absent=-1, present=-1, planAt=0, searchAt=0, cursor=0, sectorCursor=0;
    int orderAt=-1;
    int economyWorker=-1, workers=0;
    int energyCursor=0;
    AIFloat3 depot(-1,0,-1);
    bool Enabled() { return Global::AISettings::Role==AiRole::SEA && Global::RoleSettings::Sea::CoastalFallback; }
    bool Active() { return Enabled() && fallback; }
    bool ProtectedTask(CCircuitUnit@ u) {
        return u.task !is null && (u.task.IsEnemyReclaim() || u.task.IsExternalControlled()
            || u.task.GetType()==int(Task::Type::PLAYER) || u.task.GetType()==int(Task::Type::RETREAT));
    }
    bool OnMap(const AIFloat3 &in p) {
        return p.x>=32 && p.z>=32 && p.x<AiTerrainWidth()-32 && p.z<AiTerrainHeight()-32;
    }
    bool Safe(const AIFloat3 &in p) {
        if (!OnMap(p) || aiBattle.SurfThreat(p)>.1f || aiBattle.AmphThreat(p)>.1f) return false;
        // Zero profile threat weights must not hide a known ship's guns.
        for (int i=0;i<aiBattle.GetSeaForceCount();++i) {
            if ((aiBattle.GetSeaForceFlags(i)&1)!=0) continue;
            const int id=aiBattle.GetSeaForceDefId(i);
            const CCircuitDef@ d=id>0 ? ai.GetCircuitDef(id) : null;
            if (d !is null && !d.HasSurfToLand()) continue;
            const float reach=(d is null ? 600 : d.GetMaxRange())+192;
            if (MapHelpers::SqDist(p,aiBattle.GetSeaForcePos(i))<reach*reach) return false;
        }
        return true;
    }
    bool DryWorker(CCircuitUnit@ u) {
        if (u is null || !u.circuitDef.IsMobile() || u.circuitDef.GetBuildSpeed()<=0) return false;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        return u.circuitDef.CanBuild(ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(side)))
            || u.circuitDef.CanBuild(ai.GetCircuitDef(UnitHelpers::GetStaticT2MediumTurretNameForSide(side)))
            || u.circuitDef.CanBuild(ai.GetCircuitDef(side=="armada" ? "armmine2" : side=="cortex" ? "cormine2" : "legmine2"));
    }
    void Open(CCircuitDef@ d) {
        if (d is null) return;
        const string key=""+d.id;
        if (!caps.exists(key)) caps.set(key,int64(d.maxThisUnit));
        d.maxThisUnit=AiMax(d.maxThisUnit,d.count+2);
        openedCaps.set(key,int64(d.maxThisUnit));
    }
    void ReleaseCaps() {
        array<string>@ keys=caps.getKeys();
        for (uint i=0;i<keys.length();++i) {
            CCircuitDef@ d=ai.GetCircuitDef(parseInt(keys[i])); int64 old=0, last=0;
            if (d !is null && caps.get(keys[i],old) && openedCaps.get(keys[i],last) && d.maxThisUnit==last) d.maxThisUnit=int(old);
        }
        caps.deleteAll(); openedCaps.deleteAll();
    }
    void StopScreens() {
        for (uint i=0;i<screens.length();++i)
            if (screens[i].route !is null && !screens[i].route.IsDead()) screens[i].route.Abort();
        screens.resize(0); screenById.deleteAll();
    }
    void Leave() {
        ReleaseCaps(); StopScreens();
        // Frames are never abandoned on a role change. Only our unstarted
        // proposals can be cancelled; native owns their pin/task teardown.
        for (uint i=0;i<projects.length();++i) {
            IBuilderTask@ b=cast<IBuilderTask>(projects[i].task);
            if (b !is null && !b.IsDead() && b.target is null) aiBuilderMgr.AbortTask(b);
        }
        projects.resize(0); sectors.resize(0); owned.resize(0);
        held=false; fallback=false; loaded=false; body=-1; tick=-100000;
        absent=-1; present=-1; planAt=0; searchAt=0; cursor=0; sectorCursor=0; energyCursor=0; depot=AIFloat3(-1,0,-1);
    }
    void Save() {
        aiTerrainMgr.SetLayoutInt("sea.coast.held",held ? 1 : 0);
        aiTerrainMgr.SetLayoutInt("sea.coast.active",fallback ? 1 : 0);
        aiTerrainMgr.SetLayoutInt("sea.coast.body",body);
        aiTerrainMgr.SetLayoutInt("sea.coast.x",int(depot.x));
        aiTerrainMgr.SetLayoutInt("sea.coast.z",int(depot.z));
    }
    void Survey() {
        sectors.resize(0);
        array<Team::Roster::Entry@>@ allies=Team::Roster::WithRole(AiRole::SEA);
        array<AIFloat3> enemies=Lanes::ScriptStarts(true);
        aiBattle.AnalyseBeaches(Global::Map::StartPos,AiTerrainWidth()+AiTerrainHeight());
        // Copy the shared advisory buffer. A second role/controller may replace
        // it later in this frame. This O(beaches * allied starts) work runs only
        // on fallback entry or a one-minute replan; never once per builder.
        for (int i=0;i<aiBattle.GetBeachCount();++i) {
            if ((aiBattle.GetBeachClass(i)&1)!=0) continue;
            const AIFloat3 p=aiBattle.GetBeachPos(i), sea=aiBattle.GetBeachSeaward(i);
            if (body>=0 && aiBattle.WaterBody(p+sea*192,false)!=body) continue;
            const float own=MapHelpers::SqDist(p,Global::Map::StartPos);
            bool ours=true;
            for (uint j=0;j<allies.length();++j) {
                if (allies[j].teamId==ai.teamId) continue;
                if (!SeaCoastMath::OwnBeach(own,MapHelpers::SqDist(p,allies[j].startPos),ai.teamId,allies[j].teamId)) { ours=false; break; }
            }
            for (uint j=0;j<enemies.length() && ours;++j) if (MapHelpers::SqDist(p,enemies[j])<own) ours=false;
            if (!ours) continue;
            bool close=false;
            for (uint j=0;j<sectors.length();++j) if (MapHelpers::SqDist(p,sectors[j].beach)<320*320) { close=true; break; }
            if (close) continue;
            Sector@ s=Sector(); s.beach=p; s.sea=sea; sectors.insertLast(s);
        }
        // Stable nearest-first sweep, including edge beaches. Size is coastal
        // sectors (tens), not units. Subsequent placement uses a cyclic cursor.
        for (uint i=1;i<sectors.length();++i) {
            Sector@ s=sectors[i]; uint j=i;
            while (j>0 && MapHelpers::SqDist(s.beach,Global::Map::StartPos)<MapHelpers::SqDist(sectors[j-1].beach,Global::Map::StartPos)) { @sectors[j]=sectors[j-1]; --j; }
            @sectors[j]=s;
        }
        GenericHelpers::LogUtil("[SEA][Coast] survey sectors="+sectors.length()+" body="+body,1);
    }
    void Tick() {
        if (!Enabled() || ai.frame-tick<SECOND) return;
        tick=ai.frame;
        SeaCombat::Init(); // also establish hull definitions when AdaptiveFleet is disabled
        if (!loaded) {
            loaded=true; held=aiTerrainMgr.GetLayoutInt("sea.coast.held",0)!=0;
            fallback=aiTerrainMgr.GetLayoutInt("sea.coast.active",0)!=0;
            body=aiTerrainMgr.GetLayoutInt("sea.coast.body",-1);
            depot=AIFloat3(aiTerrainMgr.GetLayoutInt("sea.coast.x",-1),0,aiTerrainMgr.GetLayoutInt("sea.coast.z",-1));
        }
        // Reuse SEA's one-second legal owned-ID snapshot. AdaptiveFleet=false
        // retains support with one local census, not one scan per constructor.
        owned=SeaCombat::owned;
        if (!SeaCombat::Active()) { array<Id>@ ids=ai.GetOwnedUnitIds(); owned.resize(0); for (uint i=0;i<ids.length();++i) owned.insertLast(ids[i]); }
        bool foothold=false;
        for (uint i=0;i<owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]); if (u is null || u.GetBuildProgress()<1) continue;
            const bool yard=SeaEconomy::Yard(u.circuitDef);
            const bool con=SeaConstructor::IsT1(u.circuitDef) || SeaConstructor::IsT2(u.circuitDef);
            bool combat=false;
            // Retreat/player ownership changes a task, not physical sea control.
            // Count live combat hull definitions independently of their orders.
            for (uint j=0;j<SeaCombat::roster.length();++j)
                if (SeaCombat::roster[j].def is u.circuitDef && (SeaCombat::roster[j].surface>0 || SeaCombat::roster[j].underwater>0)) { combat=true; break; }
            if (!yard && !con && !combat) continue;
            const AIFloat3 p=u.GetPos(ai.frame); const int water=aiBattle.WaterBody(p,false);
            if (water<0) continue;
            if (body<0 && (yard || con)) body=water;
            if (water!=body) continue;
            held=true;
            // An armed fleet can contest threatened water; an isolated unarmed
            // builder/yard under enemy gun coverage is not a viable foothold.
            if (combat || Safe(p)) { foothold=true; break; }
        }
        if (foothold) { absent=-1; if (present<0) present=ai.frame; }
        else { present=-1; if (absent<0) absent=ai.frame; }
        const bool was=fallback;
        if (!fallback && SeaCoastMath::Lost(held,foothold,absent<0 ? -1 : ai.frame-absent,Global::RoleSettings::Sea::CoastLossSeconds*SECOND)) fallback=true;
        else if (fallback && SeaCoastMath::Retaken(foothold,present<0 ? -1 : ai.frame-present,Global::RoleSettings::Sea::CoastRetakeSeconds*SECOND)) fallback=false;
        if (was!=fallback) {
            GenericHelpers::LogUtil("[SEA][Coast] fallback="+fallback+" body="+body,1);
            if (!fallback) {
                ReleaseCaps(); StopScreens();
                for (uint i=0;i<projects.length();++i) {
                    IBuilderTask@ b=cast<IBuilderTask>(projects[i].task);
                    if (b !is null && !b.IsDead() && b.target is null) aiBuilderMgr.AbortTask(b);
                }
            } else { planAt=0; SeaInvasion::SuspendWaves(); }
        }
        for (int i=int(projects.length())-1;i>=0;--i) if (projects[i].task is null || projects[i].task.IsDead()) projects.removeAt(i);
        if (Active() && ai.frame>=planAt) { Survey(); planAt=ai.frame+60*SECOND; }
        if (Active()) {
            economyWorker=-1; workers=0;
            for (uint i=0;i<owned.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(owned[i]); if (!DryWorker(u) || UnitHelpers::IsCommander(u.circuitDef)) continue;
                ++workers;
                if (u.circuitDef.CanBuild(ai.GetCircuitDef(UnitHelpers::GetSolarNameForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName()))))
                    && (economyWorker<0 || u.id<economyWorker)) economyWorker=u.id;
            }
            Garrison();
        }
        Save();
    }
    bool Present(CCircuitDef@ d,const AIFloat3 &in p,float radius) {
        if (d is null) return true;
        if (aiBuilderMgr.FindOwnNear(p,radius,d) !is null || aiBuilderMgr.FindUnfinishedNear(p,radius,d) !is null) return true;
        for (uint i=0;i<projects.length();++i) {
            IBuilderTask@ t=cast<IBuilderTask>(projects[i].task);
            if (t !is null && !t.IsDead() && t.buildDef is d && MapHelpers::SqDist(p,t.GetBuildPos())<=radius*radius) return true;
        }
        return false;
    }
    bool Approach(CCircuitUnit@ u,const AIFloat3 &in p) {
        if (!Safe(p) || !aiTerrainMgr.CanReachAt(u,p,u.circuitDef.GetBuildDistance())) return false;
        // Screen the native route, not a straight segment over an unrelated
        // hostile bay. At most one admitted placement is issued per second.
        if (u.circuitDef.IsAbleToFly()) return true;
        array<AIFloat3>@ route=aiBattle.GetUnitTerrainRoute(u.circuitDef,u.GetPos(ai.frame),p,true,1,6,8,0);
        if (route.length()<2) return MapHelpers::SqDist(u.GetPos(ai.frame),p)<u.circuitDef.GetBuildDistance()*u.circuitDef.GetBuildDistance();
        for (uint i=0;i<route.length();++i) if (!Safe(route[i])) return false;
        return true;
    }
    IUnitTask@ Order(CCircuitUnit@ u,const string &in name,Task::BuildType kind,const AIFloat3 &in anchor,float radius=160,float duplicate=180,bool bootstrap=false) {
        CCircuitDef@ d=ai.GetCircuitDef(name);
        if (d is null || !u.circuitDef.CanBuild(d) || !d.IsBuildAllowed() || Present(d,anchor,duplicate) || ai.frame<orderAt) return null;
        if (!bootstrap && (aiEconomyMgr.metal.current+aiEconomyMgr.metal.income*12<d.costM*.5f
            || aiEconomyMgr.energy.current+aiEconomyMgr.energy.income*12<d.costE*.5f)) return null;
        Open(d); if (!d.IsAvailable(ai.frame)) return null;
        const int facing=LayoutHelpers::FacingToward(anchor,Global::Map::StartPos);
        for (int k=0;k<9;++k) {
            const float a=float(k)*.785398f;
            const AIFloat3 p= k==0 ? anchor : AIFloat3(anchor.x+cos(a)*radius,0,anchor.z+sin(a)*radius);
            if (!OnMap(p) || aiBattle.Height(p)<0 || aiBattle.IsFriendlyLane(p) || !Safe(p)
                || !aiTerrainMgr.CanReserveBuilding(d,p,facing) || !Approach(u,p)) continue;
            const int slot=aiTerrainMgr.ReserveBuilding(d,p,facing); if (slot<0) continue;
            const AIFloat3 at=aiTerrainMgr.GetReservationPos(slot);
            IUnitTask@ t=kind==Task::BuildType::FACTORY
                ? aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::HIGH,d,at,null,0,false,true,600*SECOND))
                : aiBuilderMgr.Enqueue(TaskB::Common(kind,Task::Priority::HIGH,d,at,0,true,180*SECOND));
            if (t is null || !AiPinReservation(t,slot)) {
                if (t !is null) aiBuilderMgr.AbortTask(t);
                aiTerrainMgr.ReleaseReservation(slot); continue;
            }
            Project@ project=Project(); @project.task=t; project.slot=slot; projects.insertLast(project);
            orderAt=ai.frame+SECOND;
            if (!Active() || aiBattle.Height(at)<0) Invariants::Violation("INV-160",name,"SEA coastal order outside lost-sea dry-land policy");
            GenericHelpers::LogUtil("[SEA][Coast] build="+name+" worker="+u.id+" x="+int(at.x)+" z="+int(at.z),1);
            return t;
        }
        return null;
    }
    bool Depot(CCircuitUnit@ u) {
        if (depot.x>=0 && Safe(depot)) return true;
        if (ai.frame<searchAt || sectors.length()==0) return false;
        searchAt=ai.frame+5*SECOND;
        CCircuitDef@ lab=ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName())));
        for (int k=0;k<8;++k) {
            const int index=cursor++;
            Sector@ s=sectors[uint(index)%sectors.length()];
            const float distance=Global::RoleSettings::Sea::CoastDepotDistance+float((index/int(sectors.length()))%5)*256;
            const AIFloat3 p=s.beach-s.sea*distance;
            bool inland=true;
            for (uint j=0;j<sectors.length();++j) if (MapHelpers::SqDist(p,sectors[j].beach)<Global::RoleSettings::Sea::CoastDepotDistance*Global::RoleSettings::Sea::CoastDepotDistance) { inland=false; break; }
            if (!inland || !OnMap(p) || aiBattle.Height(p)<0 || !Safe(p) || !aiTerrainMgr.CanReserveBuilding(lab,p,0) || !Approach(u,p)) continue;
            depot=p; Save(); GenericHelpers::LogUtil("[SEA][Coast] depot x="+int(p.x)+" z="+int(p.z),1); return true;
        }
        return false;
    }
    string T1(const string &in side) { return side=="armada" ? "armhlt" : side=="cortex" ? "corhlt" : "legmg"; }
    string Wall(const string &in side) { return side=="armada" ? "armfort" : side=="cortex" ? "corfort" : "legforti"; }
    IUnitTask@ Metal(CCircuitUnit@ u) {
        IUnitTask@ t=aiEconomyMgr.EnqueueMexWithin(u,depot,1400,0,true);
        IBuilderTask@ mex=cast<IBuilderTask>(t);
        if (mex !is null && aiBattle.Height(mex.GetBuildPos())>=0 && Approach(u,mex.GetBuildPos())) return t;
        if (mex !is null && mex.target is null && mex.GetUnits().length()==0) aiBuilderMgr.AbortTask(mex);
        return null;
    }
    IUnitTask@ Perimeter(CCircuitUnit@ u) {
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        // Each pass covers all sectors before adding another layer. A blocked
        // pad cannot hold the entire coast; failed candidates are revisited.
        for (int layer=0;layer<6;++layer) for (uint n=0;n<sectors.length();++n) {
            const uint index=(uint(sectorCursor)+n)%sectors.length(); Sector@ s=sectors[index];
            string name; float inland=160, dup=260; int offsets=1;
            if (layer==0) name=T1(side);
            else if (layer==1) { name=UnitHelpers::GetStaticRadarNameForSide(side); inland=400; dup=900; }
            else if (layer==2) { name=side=="armada" ? "armdl" : side=="cortex" ? "cordl" : "legctl"; inland=32; dup=450; }
            else if (layer==3) { name=UnitHelpers::GetStaticT2MediumTurretNameForSide(side); inland=224; }
            else if (layer==4) { name=UnitHelpers::GetStaticJammerNameForSide(side); inland=360; dup=600; }
            else { name=Wall(side); inland=32; dup=20; offsets=6;
                if (!Present(ai.GetCircuitDef(UnitHelpers::GetStaticT2MediumTurretNameForSide(side)),s.beach-s.sea*224,260)) continue;
            }
            for (int o=0;o<offsets;++o) {
                // Two flanks, three staggered rows, open firing/traffic centre.
                const float across=offsets==1 ? 0 : (o%2==0 ? -128 : 128);
                const AIFloat3 p=s.beach-s.sea*(inland+float(o/2)*40)+AIFloat3(-s.sea.z*across,0,s.sea.x*across);
                IUnitTask@ t=Order(u,name,Task::BuildType::DEFENCE,p,layer==5 ? 16 : 64,dup);
                if (t !is null) { sectorCursor=int(index+1); return t; }
            }
        }
        // Only real minelayers/engineers can build medium mines. Never invent
        // a bot-constructor build edge or divert into another factory for it.
        const string mine=side=="armada" ? "armmine2" : side=="cortex" ? "cormine2" : "legmine2";
        for (uint n=0;n<sectors.length();++n) for (int k=0;k<3;++k) {
            Sector@ s=sectors[n]; const float across=192+float(k)*96;
            const AIFloat3 p=s.beach-s.sea*96+AIFloat3(-s.sea.z*across,0,s.sea.x*across);
            IUnitTask@ t=Order(u,mine,Task::BuildType::DEFENCE,p,16,40); if (t !is null) return t;
        }
        return null;
    }
    IUnitTask@ Sensors(CCircuitUnit@ u,const string &in side) {
        for (uint i=0;i<sectors.length();++i) {
            Sector@ s=sectors[i];
            // Extend warning coverage as soon as this beach has protection;
            // do not wait for every distant T1 turret to finish first.
            if (!Present(ai.GetCircuitDef(T1(side)),s.beach-s.sea*160,360)
                && !Present(ai.GetCircuitDef(UnitHelpers::GetStaticT2MediumTurretNameForSide(side)),s.beach-s.sea*224,360)) continue;
            IUnitTask@ t=Order(u,UnitHelpers::GetStaticRadarNameForSide(side),Task::BuildType::DEFENCE,s.beach-s.sea*400,64,900);
            if (t !is null) return t;
            @t=Order(u,side=="armada" ? "armdl" : side=="cortex" ? "cordl" : "legctl",Task::BuildType::DEFENCE,s.beach-s.sea*32,64,450);
            if (t !is null) return t;
            @t=Order(u,UnitHelpers::GetStaticJammerNameForSide(side),Task::BuildType::DEFENCE,s.beach-s.sea*360,64,600);
            if (t !is null) return t;
        }
        return null;
    }
    IUnitTask@ Build(CCircuitUnit@ u) {
        if (!Active() || u is null) return null;
        if (ProtectedTask(u)) return u.task;
        if (!u.circuitDef.IsMobile() && u.circuitDef.GetBuildSpeed()>0) {
            // Naval assistance only enumerates naval factories. Recovery nanos
            // need this local land-product path or they sit beside a busy lab.
            const AIFloat3 from=u.GetPos(ai.frame); const float reach=u.circuitDef.GetBuildDistance();
            CCircuitUnit@ frame=aiBuilderMgr.FindUnfinishedNear(from,reach,null);
            if (frame !is null && !Lifecycle::IsRetiring(frame)) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL,frame,10*SECOND));
            for (uint i=0;i<owned.length();++i) {
                CCircuitUnit@ product=ai.GetTeamUnit(owned[i]);
                if (product is null || product.GetBuildProgress()>=1 || product.GetProducerId()<0) continue;
                CCircuitUnit@ lab=ai.GetTeamUnit(product.GetProducerId());
                if (lab !is null && !Lifecycle::IsRetiring(lab) && MapHelpers::SqDist(from,lab.GetPos(ai.frame))<=reach*reach)
                    return GuardHelpers::AssignWorkerGuard(u,lab,Task::Priority::LOW,true,10*SECOND);
            }
            return aiBuilderMgr.Enqueue(TaskB::Wait(2*SECOND));
        }
        if (!DryWorker(u)) return null;
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) {
            if (current.target !is null) return current;
            for (uint i=0;i<projects.length();++i) if (projects[i].task is current) return current;
            // Switching strategy may leave a walk toward an unstarted naval
            // economy task. Detach this worker only; other actors keep theirs.
            if (current.GetUnits().length()<=1) aiBuilderMgr.AbortTask(current);
        }
        if (!Depot(u)) return aiBuilderMgr.Enqueue(TaskB::Wait(5*SECOND));
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        IUnitTask@ t=Order(u,UnitHelpers::GetT1BotLabForSide(side),Task::BuildType::FACTORY,depot,128,650,true); if (t !is null) return t;
        @t=Order(u,UnitHelpers::GetMetalStorageNameForSide(side),Task::BuildType::STORE,depot+AIFloat3(240,0,0),128,650,true); if (t !is null) return t;
        @t=Order(u,UnitHelpers::GetEnergyStorageNameForSide(side),Task::BuildType::STORE,depot+AIFloat3(-240,0,0),128,650,true); if (t !is null) return t;
        const bool economic=workers>1 && economyWorker==u.id;
        if (economic) { @t=Metal(u); if (t !is null) return t; }
        // Storage does not generate resources. A drained recovery must still
        // grow energy and claim safe dry mexes instead of endlessly porcing.
        if (aiEconomyMgr.energy.income<(economic ? AiMax(150.0f,aiEconomyMgr.metal.income*35) : 100.0f)
            || aiEconomyMgr.energy.current<aiEconomyMgr.energy.storage*.25f) {
            const AIFloat3 sea=sectors.length()>0 ? sectors[0].sea : AIFloat3(0,0,1);
            const AIFloat3 across(-sea.z,0,sea.x);
            // Advance through rear rows, rather than revisiting a fixed twelve
            // pads forever below the T2 energy-income gate. Four candidates per
            // ask bounds blocked-coast search; terrain/reservations stay native.
            for (int k=0;k<4;++k) {
                const int index=(energyCursor++)%144;
                const AIFloat3 p=depot-sea*(400+float(index/12)*144)+across*(float(index%12-6)*144);
                @t=Order(u,UnitHelpers::GetSolarNameForSide(side),Task::BuildType::ENERGY,p,64,80,true);
                if (t !is null) return t;
            }
        }
        const CCircuitDef@ firstDefense=ai.GetCircuitDef(T1(side));
        if (firstDefense !is null && firstDefense.count==0
            && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::DEFENCE),firstDefense)==0) {
            int nearest=-1; float best=1e30f;
            for (uint i=0;i<sectors.length();++i) {
                const float distance=MapHelpers::SqDist(u.GetPos(ai.frame),sectors[i].beach);
                if (distance<best) { best=distance; nearest=int(i); }
            }
            if (nearest>=0) {
                Sector@ s=sectors[uint(nearest)];
                @t=Order(u,T1(side),Task::BuildType::DEFENCE,s.beach-s.sea*160,64,260);
                if (t !is null) return t;
            }
        }
        CCircuitDef@ advanced=ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(side));
        if (advanced !is null && firstDefense !is null && firstDefense.count>aiBuilderMgr.GetUnfinishedCount(firstDefense)
            && SeaCoastMath::TechFunded(aiEconomyMgr.metal.income,aiEconomyMgr.energy.income,
            aiEconomyMgr.metal.current,aiEconomyMgr.energy.current,advanced.costM,advanced.costE,
            Global::RoleSettings::Sea::CoastT2MetalIncome,Global::RoleSettings::Sea::CoastT2EnergyIncome)) {
            @t=Order(u,advanced.GetName(),Task::BuildType::FACTORY,depot+AIFloat3(0,0,400),160,800); if (t !is null) return t;
        }
        @t=Order(u,UnitHelpers::GetT1NanoNameForSide(side),Task::BuildType::NANO,depot+AIFloat3(0,0,192),96,160); if (t !is null) return t;
        if (SeaCombat::air>0) {
            @t=Order(u,UnitHelpers::GetStaticT2AAFlakNameForSide(side),Task::BuildType::DEFENCE,depot+AIFloat3(192,0,192),96,500);
            if (t !is null) return t;
            @t=Order(u,UnitHelpers::GetStaticAAHeavyNameForSide(side),Task::BuildType::DEFENCE,depot+AIFloat3(-192,0,192),96,500);
            if (t !is null) return t;
        }
        @t=Sensors(u,side); if (t !is null) return t;
        @t=Perimeter(u); if (t !is null) return t;
        @t=Metal(u); if (t !is null) return t;
        return aiBuilderMgr.Enqueue(TaskB::Wait(5*SECOND));
    }
    IUnitTask@ Produce(CCircuitUnit@ factory) {
        if (!Active() || factory is null) return null;
        const string side=UnitHelpers::GetSideForUnitName(factory.circuitDef.GetName());
        const bool t1=factory.circuitDef.GetName()==UnitHelpers::GetT1BotLabForSide(side);
        const bool t2=factory.circuitDef.GetName()==UnitHelpers::GetT2BotLabForSide(side);
        if (!t1 && !t2) return null;
        const string con=t1 ? (side=="armada" ? "armck" : side=="cortex" ? "corck" : "legck")
            : (side=="armada" ? "armack" : side=="cortex" ? "corack" : "legack");
        CCircuitDef@ product=ai.GetCircuitDef(con);
        Task::RecruitType kind=Task::RecruitType::BUILDPOWER;
        const int desired=t1 ? AiMin(8,3+int(aiEconomyMgr.metal.income/30)) : 2;
        if (product is null || product.count+aiFactoryMgr.GetPendingRecruitCount(product)>=desired) {
            array<string> combat;
            if (t1) { combat.insertLast(side=="armada" ? "armham" : side=="cortex" ? "corthud" : "legcen"); combat.insertLast(side=="armada" ? "armrock" : side=="cortex" ? "corstorm" : "legbal"); }
            else { combat.insertLast(side=="armada" ? "armmav" : side=="cortex" ? "corcan" : "leginc"); combat.insertLast(side=="armada" ? "armfido" : side=="cortex" ? "cormort" : "legshot"); }
            @product=null; int count=100000;
            for (uint i=0;i<combat.length();++i) {
                CCircuitDef@ d=ai.GetCircuitDef(combat[i]); if (d is null || !factory.circuitDef.CanBuild(d) || !d.IsBuildAllowed()) continue;
                const int number=d.count+aiFactoryMgr.GetPendingRecruitCount(d);
                if (number<count) { count=number; @product=d; }
            }
            kind=Task::RecruitType::FIREPOWER;
        }
        if (product !is null && product.IsBuildAllowed() && factory.circuitDef.CanBuild(product)) {
            Open(product); IUnitTask@ task=SeaFactories::Recruit(factory,product,kind);
            if (task !is null) return task;
        }
        return aiFactoryMgr.Enqueue(TaskS::Wait(false,2*SECOND));
    }
    void Garrison() {
        if (sectors.length()==0 || ai.frame% (5*SECOND)!=0) return;
        array<AIFloat3> goals(sectors.length());
        for (uint i=0;i<sectors.length();++i) {
            Sector@ s=sectors[i]; goals[i]=s.beach-s.sea*224;
            float closest=1000*1000;
            for (int j=0;j<aiBattle.GetGroundContactCount();++j) {
                const AIFloat3 p=aiBattle.GetGroundContactPos(j); if (aiBattle.Height(p)<0) continue;
                const float dist=MapHelpers::SqDist(p,s.beach);
                if (dist<closest) { closest=dist; goals[i]=p-s.sea*128; }
            }
        }
        // O(U + S*E) every five seconds: one contact selection per sector,
        // dictionary identity lookup per soldier; no army-square matching.
        // Persistent slots only issue orders on changed goals or interruption.
        for (uint n=0;n<owned.length();++n) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[n]);
            if (u is null || u.GetBuildProgress()<1 || !u.circuitDef.IsMobile() || u.circuitDef.IsAbleToFly()
                || u.circuitDef.GetBuildSpeed()>0 || !u.circuitDef.HasSurfToLand() || aiBattle.Height(u.GetPos(ai.frame))<0 || ProtectedTask(u)) continue;
            Screen@ screen=null;
            screenById.get(""+u.id,@screen);
            if (screen is null) { @screen=Screen(); screen.unit=u.id; screen.sector=int(screens.length()%sectors.length()); screens.insertLast(screen); screenById.set(""+u.id,@screen); }
            Sector@ s=sectors[uint(screen.sector)%sectors.length()];
            const float across=float((u.id%5)-2)*96;
            AIFloat3 goal=goals[uint(screen.sector)%sectors.length()]+AIFloat3(-s.sea.z*across,0,s.sea.x*across);
            if (!OnMap(goal) || aiBattle.Height(goal)<0 || ai.frame-screen.ordered<10*SECOND) continue;
            if (screen.route !is null && !screen.route.IsDead() && u.task is screen.route && MapHelpers::SqDist(goal,screen.goal)<96*96) continue;
            array<AIFloat3>@ route=aiBattle.GetUnitTerrainRoute(u.circuitDef,u.GetPos(ai.frame),goal,true,1,6,8,0);
            screen.ordered=ai.frame; if (route.length()<2) continue;
            if (screen.route is null || screen.route.IsDead()) @screen.route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (screen.route is null) continue;
            screen.route.SetHoldPosition(true); screen.route.SetLanes(1,96,1); screen.route.SetTraversal(true,96,true); screen.route.SetRoute(route);
            aiMilitaryMgr.TransferUnit(u,screen.route); screen.goal=goal;
        }
        uint live=0;
        for (uint i=0;i<screens.length();++i) {
            Screen@ s=screens[i];
            if (ai.GetTeamUnit(s.unit) is null) { if (s.route !is null && !s.route.IsDead()) s.route.Abort(); screenById.delete(""+s.unit); }
            else @screens[live++]=s;
        }
        screens.resize(live);
    }
}
