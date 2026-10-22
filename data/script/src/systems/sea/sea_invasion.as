// D-212: SEA-only conversion of verified water control into a protected landing.
// Native owns legal sensor samples, reservations and movement. Script owns all
// thresholds/production/mission choices. IDs, not borrowed units, survive ticks.
namespace SeaInvasion {
    class Wave {
        int defId=-1, born=0, phase=0, ordered=-100000;
        array<int> ids;
        AIFloat3 goal;
        CRouteTask@ route;
    }
    array<Wave@> waves;
    array<AIFloat3> beaches, normals;
    int body=-1, tick=-100000, quiet=-1, logAt=-100000, searchAt=0, cursor=0, gantrySearchAt=0, gantryCursor=0, buildLogAt=-100000;
    int labSlot=-1, gantrySlot=-1, labExit=0, gantryExit=0, facing=0;
    bool secured=false, restored=false;
    float coverage=0;
    AIFloat3 site(-1,0,-1), landing(-1,0,-1), seaward;
    bool Active() { return Global::AISettings::Role==AiRole::SEA && Global::RoleSettings::Sea::AmphibiousInvasion && SeaCombat::Active() && SeaLayout::Enabled() && !SeaCoast::Active(); }
    void SuspendWaves() {
        // D-219: losing the sea yields surviving land units to coastal defense.
        // Keep factory reservations/frames intact for a later naval recovery.
        for (uint i=0;i<waves.length();++i) if (waves[i].route !is null && !waves[i].route.IsDead()) waves[i].route.Abort();
        waves.resize(0);
    }
    string Lab(const string &in side) { return side=="armada" ? "armamsub" : side=="cortex" ? "coramsub" : "legamphlab"; }
    string Gantry(const string &in side) { return side=="armada" ? "armshltxuw" : side=="cortex" ? "corgantuw" : "leggantuw"; }
    string Product(const string &in side,bool advanced) {
        // Effective BAR factory edges, not a global role/classification change.
        return advanced ? (side=="armada" ? "armmar" : side=="cortex" ? "corshiva" : "legjav")
            : (side=="armada" ? "armcroc" : side=="cortex" ? "corsala" : "legamphtank");
    }
    bool Factory(const CCircuitDef@ d) {
        if (d is null) return false;
        const string side=UnitHelpers::GetSideForUnitName(d.GetName());
        return d.GetName()==Lab(side) || d.GetName()==Gantry(side);
    }
    bool OwnsSupport(CCircuitUnit@ factory) {
        // O(1) identity lookup: only our two pinned factories have this owner.
        // A donated/ordinary amphibious factory keeps generic SEA planning.
        return Active() && factory !is null
            && ((labSlot>=0 && aiTerrainMgr.GetReservationUnit(labSlot) is factory)
                || (gantrySlot>=0 && aiTerrainMgr.GetReservationUnit(gantrySlot) is factory));
    }
    void Init() {
        Leave();
        if (!Global::RoleSettings::Sea::AmphibiousInvasion) return;
        const array<string> sides={"armada","cortex","legion"};
        for (uint i=0;i<sides.length();++i) {
            // Missing Legion metadata is per-AI and never changes another role.
            CCircuitDef@ d=ai.GetCircuitDef(Lab(sides[i]));
            if (d !is null) aiFactoryMgr.RegisterScriptFactory(d,ai.GetCircuitDef("armamsub"));
            @d=ai.GetCircuitDef(Gantry(sides[i]));
            if (d !is null) aiFactoryMgr.RegisterScriptFactory(d,ai.GetCircuitDef(UnitHelpers::GetLandGantryForSide(sides[i])));
        }
    }
    void Leave() {
        for (uint i=0;i<waves.length();++i) if (waves[i].route !is null && !waves[i].route.IsDead()) waves[i].route.Abort();
        waves.resize(0); beaches.resize(0); normals.resize(0);
        body=-1; tick=-100000; quiet=-1; secured=false; restored=false; coverage=0; searchAt=0; cursor=0; gantrySearchAt=0; gantryCursor=0; buildLogAt=-100000;
        site=AIFloat3(-1,0,-1); landing=site; labSlot=-1; gantrySlot=-1;
        labExit=0; gantryExit=0;
    }
    void Save() {
        aiTerrainMgr.SetLayoutInt("sea.invasion.slot",labSlot);
        aiTerrainMgr.SetLayoutInt("sea.invasion.gantry",gantrySlot);
        aiTerrainMgr.SetLayoutInt("sea.invasion.exit",labExit);
        aiTerrainMgr.SetLayoutInt("sea.invasion.gantryExit",gantryExit);
        aiTerrainMgr.SetLayoutInt("sea.invasion.facing",facing);
        aiTerrainMgr.SetLayoutInt("sea.invasion.landX",int(landing.x));
        aiTerrainMgr.SetLayoutInt("sea.invasion.landZ",int(landing.z));
        aiTerrainMgr.SetLayoutInt("sea.invasion.normalX",int(seaward.x*10000));
        aiTerrainMgr.SetLayoutInt("sea.invasion.normalZ",int(seaward.z*10000));
    }
    void Restore() {
        if (restored) return;
        restored=true;
        labSlot=aiTerrainMgr.GetLayoutInt("sea.invasion.slot",-1);
        gantrySlot=aiTerrainMgr.GetLayoutInt("sea.invasion.gantry",-1);
        labExit=aiTerrainMgr.GetLayoutInt("sea.invasion.exit",0);
        gantryExit=aiTerrainMgr.GetLayoutInt("sea.invasion.gantryExit",0);
        if (labSlot<0 || aiTerrainMgr.GetReservationState(labSlot)<0) { labSlot=-1; return; }
        site=aiTerrainMgr.GetReservationPos(labSlot);
        facing=aiTerrainMgr.GetLayoutInt("sea.invasion.facing",0);
        landing=AIFloat3(float(aiTerrainMgr.GetLayoutInt("sea.invasion.landX",-1)),0,float(aiTerrainMgr.GetLayoutInt("sea.invasion.landZ",-1)));
        seaward=AIFloat3(float(aiTerrainMgr.GetLayoutInt("sea.invasion.normalX",0))/10000,0,float(aiTerrainMgr.GetLayoutInt("sea.invasion.normalZ",0))/10000);
    }
    bool Safe(const AIFloat3 &in p) {
        if (p.x<32 || p.z<32 || p.x>=AiTerrainWidth()-32 || p.z>=AiTerrainHeight()-32
            || aiBattle.WaterBody(p,false)!=body || aiBattle.SurfThreat(p)>.1f || aiBattle.AmphThreat(p)>.1f || aiBattle.AirThreat(p)>.1f) return false;
        // Known shore weapons must not reach the construction site, even if
        // this profile assigned those weapons zero threat weight.
        const int count=aiBattle.GetGroundContactCount();
        for (int i=0;i<count;++i) {
            const CCircuitDef@ d=ai.GetCircuitDef(aiBattle.GetGroundContactDefId(i));
            if (d is null || (!d.HasSurfToLand() && !d.HasSurfToWater() && !d.HasSubToWater())) continue;
            const float reach=AiMax(d.GetMaxRange(1),d.GetMaxRange(2))+Global::RoleSettings::Sea::InvasionWeaponMargin;
            if (MapHelpers::SqDist(p,aiBattle.GetGroundContactPos(i))<reach*reach) return false;
        }
        return true;
    }
    bool Protected(const AIFloat3 &in p) {
        if (!Safe(p)) return false;
        float cover=0; bool surface=false;
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
            // Explicit SEA hull eligibility is authoritative. Some faction
            // profiles omit generic ASSAULT/SKIRM labels on valid warships.
            if (!SeaOperations::Eligible(u) || u.GetBuildProgress()<1 || SeaOperations::Escort(u.circuitDef)
                || aiBattle.WaterBody(u.GetPos(ai.frame),false)!=body || MapHelpers::SqDist(p,u.GetPos(ai.frame))>900*900) continue;
            cover+=u.circuitDef.costM; surface=surface || u.circuitDef.HasSurfToLand();
        }
        return surface && cover>=Global::RoleSettings::Sea::InvasionEscortMetal;
    }
    void Survey() {
        if (body<0) {
            for (uint i=0;i<SeaCombat::owned.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
                if (u !is null && SeaEconomy::Yard(u.circuitDef)) { body=aiBattle.WaterBody(u.GetPos(ai.frame),false); if (body>=0) break; }
            }
        }
        if (body<0) return;
        coverage=aiBattle.GetWaterSurveyCoverage(body,Global::RoleSettings::Sea::InvasionSurveySeconds*SECOND);
        const int enemies=aiBattle.GetWaterEnemyCount(body);
        if (coverage<1 || enemies!=0) quiet=-1;
        else if (quiet<0) quiet=ai.frame;
        const bool next=SeaMath::SeaSecured(body,coverage,enemies,quiet<0 ? -1 : ai.frame-quiet,Global::RoleSettings::Sea::InvasionQuietSeconds*SECOND);
        if (next!=secured || ai.frame-logAt>=60*SECOND) {
            logAt=ai.frame; GenericHelpers::LogUtil("[SEA][Invasion] survey body="+body+" coverage="+coverage+" enemies="+enemies+" secured="+next,1);
            if (site.x>=0) {
                CCircuitDef@ lab=ai.GetCircuitDef(Lab(Global::AISettings::Side));
                GenericHelpers::LogUtil("[SEA][Invasion] site protected="+Protected(site)+" labAvailable="+(lab !is null && lab.IsAvailable(ai.frame))
                    +" labSlot="+aiTerrainMgr.GetReservationState(labSlot)+" gantrySlot="+gantrySlot,1);
                CCircuitDef@ nano=ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(Global::AISettings::Side));
                CCircuitDef@ gantry=ai.GetCircuitDef(Gantry(Global::AISettings::Side));
                GenericHelpers::LogUtil("[SEA][Invasion] support pads="+SeaBuild::SupportFootprint(nano,site)+" gantryProduct="
                    +(gantry !is null && gantry.CanBuild(ai.GetCircuitDef(Product(Global::AISettings::Side,true)))),1);
            }
        }
        secured=next;
    }
    AIFloat3 EnemyGoal(const AIFloat3 &in from) {
        AIFloat3 result=Spam::_MirrorOfStart(); float best=1e30f;
        // A legally observed enemy economic base is stronger evidence than an
        // unoccupied map start. In small games, spare allied-side starts can
        // otherwise pull the staging site toward the middle of the map.
        for (int i=0;i<aiBattle.GetGroundContactCount();++i) {
            if (!aiBattle.IsGroundContactEconomy(i)) continue;
            const AIFloat3 p=aiBattle.GetGroundContactPos(i);
            const float score=MapHelpers::SqDist(from,p);
            if (score<best) { best=score; result=p; }
        }
        if (best<1e30f) return result;
        array<AIFloat3>@ starts=Spam::EnemyStartSpots();
        const AIFloat3 home=Global::Map::StartPos, axis=result-home;
        bool foundBackline=false;
        for (uint i=0;i<starts.length();++i) {
            if ((starts[i].x-home.x)*axis.x+(starts[i].z-home.z)*axis.z<=0) continue;
            const int spot=MapHelpers::NearestSpotIdx(starts[i],Global::Map::Config.StartSpots);
            const bool backline=spot>=0 && (Global::Map::Config.StartSpots[spot].aiRole==AiRole::TECH || Global::Map::Config.StartSpots[spot].aiRole==AiRole::AIR);
            // Prefer the backline category before distance. A weighted nearest
            // start score can stick forever to a cleared front start directly
            // beside the beach after the first known economic targets die.
            if (foundBackline && !backline) continue;
            if (backline && !foundBackline) { foundBackline=true; best=1e30f; }
            const float score=MapHelpers::SqDist(from,starts[i]);
            if (score<best) { best=score; result=starts[i]; }
        }
        return result;
    }
    void Plan() {
        if (!secured || site.x>=0 || ai.frame<searchAt) return;
        searchAt=ai.frame+5*SECOND;
        const string side=Global::AISettings::Side;
        CCircuitDef@ lab=ai.GetCircuitDef(Lab(side));
        CCircuitDef@ product=ai.GetCircuitDef(Product(side,false));
        if (lab is null || product is null || !lab.CanBuild(product)) return;
        if (beaches.length()==0) {
            const AIFloat3 enemy=EnemyGoal(Global::Map::StartPos);
            aiBattle.AnalyseBeaches(enemy,4000);
            // Copy values: other controllers share the native advisory buffer.
            for (int i=0;i<aiBattle.GetBeachCount();++i) {
                if ((aiBattle.GetBeachClass(i)&1)!=0) continue;
                const AIFloat3 p=aiBattle.GetBeachPos(i);
                if (MapHelpers::SqDist(p,enemy)>=MapHelpers::SqDist(p,Global::Map::StartPos)) continue;
                beaches.insertLast(p); normals.insertLast(aiBattle.GetBeachSeaward(i));
            }
        }
        // At most four expensive path/placement queries per five-second tick;
        // a failed beach advances the cursor rather than starving alternatives.
        for (int n=0;n<4 && beaches.length()>0;++n) {
            const uint index=uint(cursor++)%beaches.length();
            const AIFloat3 normal=normals[index], beach=beaches[index];
            const AIFloat3 p=beach+normal*Global::RoleSettings::Sea::InvasionOffshoreDistance;
            const AIFloat3 dry=beach-normal*192.0f;
            if (!Safe(p) || aiBattle.Height(dry)<0) continue;
            array<AIFloat3>@ route=aiBattle.GetUnitTerrainRoute(product,p,dry,false,1,6,8,0);
            if (route.length()<2) continue;
            const int f=LayoutHelpers::FacingToward(p,dry);
            const int slot=aiTerrainMgr.ReservePersistentBuilding(lab,p,f);
            if (slot<0) continue;
            // Explicit empty output corridor; amphibious products are ground
            // MoveDefs, so PlanNavalBerth's ship-only draft check is unsuitable.
            const AIFloat3 snapped=aiTerrainMgr.GetReservationPos(slot);
            const float half=float(lab.GetFootprintZ())*8;
            const AIFloat3 exit=LayoutHelpers::Offset(snapped,f,0,half+160);
            const int zone=aiTerrainMgr.ReserveZone(exit,f,128,160,true);
            if (zone<=0) { aiTerrainMgr.ReleasePersistentBuilding(slot); continue; }
            labSlot=slot; labExit=zone; site=snapped; landing=dry; seaward=normal; facing=f;
            // Reserve the second factory before support pads consume its room.
            // Both remain ordinary allied layout reservations, not exemptions.
            PlanGantry(); Save();
            GenericHelpers::LogUtil("[SEA][Invasion] staging="+int(site.x)+","+int(site.z)+" landing="+int(landing.x)+","+int(landing.z),1);
            return;
        }
    }
    void PlanSupport(CCircuitDef@ nano,const AIFloat3 &in centre,int desired) {
        if (nano is null) return;
        const int have=SeaBuild::SupportFootprint(nano,centre,desired);
        if (have>=desired) return;
        const AIFloat3 rear=LayoutHelpers::Offset(centre,facing,0,-224);
        // A coast may fit enough individual reachable pads but no complete
        // rectangle. Retain successful small patches rather than retrying a
        // large all-or-nothing grid forever. Searches run only each 5s tick.
        if (!SeaLayout::PlanPatch(nano,rear,AiMin(6,desired-have),300,centre))
            SeaLayout::PlanPatch(nano,rear,1,300,centre);
    }
    void PlanGantry() {
        if (site.x<0 || gantrySlot>=0 || !secured || ai.frame<gantrySearchAt) return;
        gantrySearchAt=ai.frame+30*SECOND;
        const string side=Global::AISettings::Side;
        CCircuitDef@ d=ai.GetCircuitDef(Gantry(side)), product=ai.GetCircuitDef(Product(side,true));
        if (d is null || product is null || !d.CanBuild(product)) return;
        // Bounded alternatives on either flank; a fixed single point can be
        // shallow or occupied forever. Planning is per tick, never per worker.
        for (int i=0;i<4;++i) {
            const int candidate=gantryCursor++%12;
            const float offset=float(candidate%2==0 ? 1 : -1)*(384+256*((candidate%4)/2));
            const AIFloat3 p=LayoutHelpers::Offset(site,facing,offset,-128*(candidate/4));
            if (!Safe(p)) continue;
            const int slot=aiTerrainMgr.ReservePersistentBuilding(d,p,facing);
            if (slot<0) continue;
            const AIFloat3 snapped=aiTerrainMgr.GetReservationPos(slot);
            array<AIFloat3>@ route=aiBattle.GetUnitTerrainRoute(product,snapped,landing,false,1,6,8,0);
            if (route.length()<2) { aiTerrainMgr.ReleasePersistentBuilding(slot); continue; }
            const int zone=aiTerrainMgr.ReserveZone(LayoutHelpers::Offset(snapped,facing,0,float(d.GetFootprintZ())*8+160),facing,160,160,true);
            if (zone<=0) { aiTerrainMgr.ReleasePersistentBuilding(slot); continue; }
            gantrySlot=slot; gantryExit=zone; Save();
            // The home reservation guaranteed early space without committing
            // to a backline invasion factory. Replace only untouched home
            // plans once the protected enemy-shore site actually exists.
            for (uint b=0;b<SeaLayout::berths.length();++b) {
                SeaLayout::Berth@ provisional=SeaLayout::berths[b];
                if (provisional.name!=d.GetName() || provisional.active || provisional.retired) continue;
                const int state=aiTerrainMgr.GetReservationState(provisional.slot);
                if (state>=1 && state<=3) continue; // a claim/frame can precede the next census
                SeaLayout::ReleaseSupport(provisional.key);
                aiTerrainMgr.ReleasePersistentBuilding(provisional.slot); aiTerrainMgr.ReleaseZone(provisional.exitZone);
                provisional.slot=-1; provisional.exitZone=0; provisional.retired=true; SeaLayout::Save(provisional);
            }
            return;
        }
    }
    bool Screen(int basin,int defId,AIFloat3 &out goal) {
        goal=site;
        if (!Active() || site.x<0 || basin!=body || !Safe(site)) return false;
        const float offset=float(SeaMath::SpreadIndex(defId%7))*128;
        goal=AIFloat3(site.x-seaward.z*offset,0,site.z+seaward.x*offset);
        return aiBattle.WaterBody(goal,false)==body;
    }
    CCircuitUnit@ At(CCircuitDef@ d,const AIFloat3 &in p) {
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (u !is null && u.circuitDef is d && MapHelpers::SqDist(u.GetPos(ai.frame),p)<700*700) return u;
        }
        return null;
    }
    bool Ready(CCircuitDef@ d,bool advanced) {
        CCircuitUnit@ lab=At(ai.GetCircuitDef(Lab(Global::AISettings::Side)),site);
        return d !is null && SeaMath::InvasionFactoryReady(secured,Protected(site),!advanced || (lab !is null && lab.GetBuildProgress()>=1),Economy::IncomeWindowReady(),
            Economy::GetMinMetalIncomeLast10s(),Economy::GetMinEnergyIncomeLast10s(),
            advanced ? Global::RoleSettings::Sea::InvasionGantryMetal : Global::RoleSettings::Sea::InvasionMinMetal,
            advanced ? Global::RoleSettings::Sea::InvasionGantryEnergy : Global::RoleSettings::Sea::InvasionMinEnergy);
    }
    int Turrets(const AIFloat3 &in p,CCircuitDef@ nano) {
        if (nano is null) return 0;
        int count=0;
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (u !is null && u.circuitDef is nano && u.GetBuildProgress()>=1 && MapHelpers::SqDist(p,u.GetPos(ai.frame))<=nano.GetBuildDistance()*nano.GetBuildDistance()) ++count;
        }
        return count;
    }
    IUnitTask@ Build(CCircuitUnit@ u) {
        if (!Active() || !secured || site.x<0 || u is null || !u.circuitDef.IsMobile() || !Protected(site)
            || !aiTerrainMgr.CanReachAt(u,site,u.circuitDef.GetBuildDistance())) return null;
        const string side=Global::AISettings::Side;
        CCircuitDef@ lab=ai.GetCircuitDef(Lab(side)), gantry=ai.GetCircuitDef(Gantry(side));
        CCircuitDef@ nano=ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(side));
        CCircuitUnit@ first=At(lab,site), second=At(gantry,site);
        // Never compete with the funded post-T2 seaplane purchase.
        if (SeaFactories::NeedSeaplane(side)) return null;
        const bool advanced=first !is null && first.GetBuildProgress()>=1;
        const int desired=second is null ? Global::RoleSettings::Sea::InvasionLabTurrets : Global::RoleSettings::Sea::InvasionGantryTurrets;
        const AIFloat3 supportAt=second is null ? site : second.GetPos(ai.frame);
        if (first !is null && nano !is null && u.circuitDef.CanBuild(nano) && nano.IsAvailable(ai.frame)
            && Turrets(supportAt,nano)<desired && SeaEconomy::Pending(nano)==0
            && SeaEconomy::Fund(nano,u.circuitDef.GetBuildSpeed(),0,0,500,1000)) {
            IUnitTask@ t=SeaLayout::Place(u,nano,Task::BuildType::NANO,LayoutHelpers::Offset(supportAt,facing,0,-224),desired,300,supportAt);
            if (t !is null) { SeaEconomy::Admit(nano,false,true); return t; }
        }
        CCircuitDef@ d=advanced ? gantry : lab;
        if (advanced && second is null && gantry !is null && u.circuitDef.CanBuild(gantry) && ai.frame-buildLogAt>=30*SECOND) {
            buildLogAt=ai.frame;
            GenericHelpers::LogUtil("[SEA][Invasion] gantry gate available="+gantry.IsAvailable(ai.frame)+" ready="+Ready(gantry,true)
                +" turrets="+Turrets(site,nano)+" slot="+gantrySlot+" pending="+SeaEconomy::Pending(gantry),1);
        }
        if (d is null || (advanced && second !is null) || (!advanced && first !is null)
            || SeaEconomy::Pending(d)>0 || !u.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame) || !Ready(d,advanced)
            || (advanced && (nano is null || Turrets(site,nano)<Global::RoleSettings::Sea::InvasionLabTurrets))) return null;
        if (!SeaEconomy::Fund(d,u.circuitDef.GetBuildSpeed(),0,0,advanced ? 1500 : 500,2000)) return null;
        const int slot=advanced ? gantrySlot : labSlot;
        if (slot<0 || !aiTerrainMgr.IsReservationBuildable(slot)
            || !Protected(aiTerrainMgr.GetReservationPos(slot))
            || !aiTerrainMgr.CanReachAt(u,aiTerrainMgr.GetReservationPos(slot),u.circuitDef.GetBuildDistance())) return null;
        const int footprint=advanced ? Global::RoleSettings::Sea::InvasionGantryTurrets : Global::RoleSettings::Sea::InvasionLabTurrets;
        if (SeaBuild::SupportFootprint(nano,aiTerrainMgr.GetReservationPos(slot),footprint)<footprint) return null;
        if (!secured || !Protected(aiTerrainMgr.GetReservationPos(slot))) { Invariants::Violation("INV-154","sea-invasion","amphibious construction without surveyed control and escort"); return null; }
        IUnitTask@ t=SeaLayout::Pinned(d,slot,Task::BuildType::FACTORY,Task::Priority::HIGH);
        if (t !is null) { SeaEconomy::Admit(d,false,true); GenericHelpers::LogUtil("[SEA][Invasion] build "+d.GetName(),1); }
        return t;
    }
    IUnitTask@ Produce(CCircuitUnit@ yard) {
        if (!Active() || yard is null || !Factory(yard.circuitDef)) return null;
        if (Lifecycle::IsRetiring(yard) || SeaFactories::Hold(yard)) return aiFactoryMgr.Enqueue(TaskS::Wait(true,SECOND));
        const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
        CCircuitDef@ d=ai.GetCircuitDef(Product(side,yard.circuitDef.GetName()==Gantry(side)));
        return SeaFactories::Recruit(yard,d,Task::RecruitType::FIREPOWER);
    }
    bool Member(CCircuitUnit@ u) {
        if (u is null || u.GetBuildProgress()<1 || u.task is null || u.task.GetType()==int(Task::Type::PLAYER)
            || u.task.GetType()==int(Task::Type::RETREAT) || u.task.IsExternalControlled()) return false;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        return u.circuitDef.GetName()==Product(side,false) || u.circuitDef.GetName()==Product(side,true);
    }
    bool Order(Wave@ w,const AIFloat3 &in from,const AIFloat3 &in to,bool dry,bool fight) {
        array<AIFloat3>@ points=aiBattle.GetUnitTerrainRoute(ai.GetCircuitDef(w.defId),from,to,dry,1,6,8,0);
        if (points.length()<2) return false;
        if (w.route is null || w.route.IsDead()) {
            @w.route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (w.route is null) return false;
            w.route.SetLanes(3,128,1); w.route.SetHoldPosition(true);
        }
        w.route.SetTraversal(true,128,fight); w.route.SetRoute(points);
        for (uint i=0;i<w.ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(w.ids[i]);
            if (Member(u) && u.task !is w.route) aiMilitaryMgr.TransferUnit(u,w.route);
        }
        w.goal=to; w.ordered=ai.frame; return true;
    }
    void Waves() {
        if (landing.x<0) return;
        dictionary assigned;
        for (int i=int(waves.length())-1;i>=0;--i) {
            Wave@ w=waves[i];
            for (int j=int(w.ids.length())-1;j>=0;--j) {
                if (!Member(ai.GetTeamUnit(w.ids[j]))) w.ids.removeAt(j);
                else assigned.set(""+w.ids[j],true);
            }
            if (w.ids.length()==0) { if (w.route !is null && !w.route.IsDead()) w.route.Abort(); waves.removeAt(i); }
        }
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (!Member(u) || assigned.exists(""+u.id)) continue;
            Wave@ w=null;
            for (uint j=0;j<waves.length();++j) if (waves[j].defId==u.circuitDef.id && waves[j].phase==0 && int(waves[j].ids.length())<Global::RoleSettings::Sea::InvasionWaveSize) { @w=waves[j]; break; }
            if (w is null) { @w=Wave(); w.defId=u.circuitDef.id; w.born=ai.frame; waves.insertLast(w); }
            w.ids.insertLast(u.id);
            // Keep new products on an actual group staging task while their
            // wave assembles; native attack must not launch singletons early.
            if (w.route is null || w.route.IsDead()) {
                @w.route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                if (w.route !is null) {
                    // Clear the factory before forming up. Holding exactly
                    // at UnitFinished can cancel the engine's exit movement.
                    array<AIFloat3> hold={u.GetPos(ai.frame),LayoutHelpers::Offset(site,facing,0,350)};
                    w.route.SetHoldPosition(true); w.route.SetLanes(3,128,1);
                    w.route.SetTraversal(true,128,false); w.route.SetRoute(hold);
                }
            }
            if (w.route !is null && u.task !is w.route) aiMilitaryMgr.TransferUnit(u,w.route);
        }
        int searches=0;
        for (uint i=0;i<waves.length() && searches<2;++i) {
            Wave@ w=waves[i]; CCircuitUnit@ lead=ai.GetTeamUnit(w.ids[0]);
            if (lead is null) continue;
            const AIFloat3 here=lead.GetPos(ai.frame);
            if (w.phase==0) {
                if (!secured || !SeaMath::ReleaseFleet(int(w.ids.length()),ai.frame-w.born,Global::RoleSettings::Sea::InvasionWaveSize,Global::RoleSettings::Sea::InvasionWaveSeconds*SECOND)) continue;
                if (ai.frame-w.ordered<15*SECOND) continue;
                ++searches; w.ordered=ai.frame;
                if (Order(w,here,landing,false,false)) { w.phase=1; GenericHelpers::LogUtil("[SEA][Invasion] launch "+lead.circuitDef.GetName()+" n="+w.ids.length(),1); }
                continue;
            }
            if (ai.frame-w.ordered<15*SECOND) continue;
            if (w.route !is null && !w.route.IsDead() && !w.route.IsAtEnd(lead) && ai.frame-w.ordered<90*SECOND) continue;
            // Stay dry after landing. Prefer observed backline economy, then
            // enemy start hypotheses; no hidden positions or underwater chase.
            if (aiBattle.Height(here)<0) { ++searches; Order(w,here,landing,false,false); continue; }
            AIFloat3 goal=EnemyGoal(here); float score=1e30f;
            for (int c=0;c<aiBattle.GetGroundContactCount();++c) {
                const AIFloat3 p=aiBattle.GetGroundContactPos(c);
                if (aiBattle.Height(p)<0) continue;
                const float rank=MapHelpers::SqDist(here,p)/(aiBattle.IsGroundContactEconomy(c) ? 8.0f : 1.0f);
                if (rank<score) { score=rank; goal=p; }
            }
            // Arriving at a cleared hypothesis is not a reason to resend the
            // same route every tick. Keep firing in position while awaiting
            // new legal contacts; the 90-second renewal remains a fallback.
            if (w.phase==2 && MapHelpers::SqDist(goal,w.goal)<128*128 && ai.frame-w.ordered<90*SECOND) continue;
            ++searches; w.ordered=ai.frame;
            if (Order(w,here,goal,true,true)) { w.phase=2; GenericHelpers::LogUtil("[SEA][Invasion] backline "+lead.circuitDef.GetName()+" goal="+int(goal.x)+","+int(goal.z),1); }
        }
    }
    void Tick() {
        if (!Active() || ai.frame-tick<5*SECOND) return;
        tick=ai.frame; Restore(); Survey();
        // Revalidate untouched reservations before their first building. Never
        // move a committed factory/frame or destroy structures on a lost beach.
        if (labSlot>=0 && SeaMath::ReplanInvasionSlot(aiTerrainMgr.GetReservationState(labSlot),
            aiTerrainMgr.IsReservationBuildable(labSlot),aiTerrainMgr.IsZoneClear(labExit))) {
            aiTerrainMgr.ReleasePersistentBuilding(labSlot); aiTerrainMgr.ReleaseZone(labExit);
            labSlot=-1; labExit=0; site=AIFloat3(-1,0,-1);
            if (gantrySlot>=0 && (aiTerrainMgr.GetReservationState(gantrySlot)<=0 || aiTerrainMgr.GetReservationState(gantrySlot)==4)) {
                aiTerrainMgr.ReleasePersistentBuilding(gantrySlot); aiTerrainMgr.ReleaseZone(gantryExit); gantrySlot=-1; gantryExit=0;
            }
            Save();
        }
        if (gantrySlot>=0 && SeaMath::ReplanInvasionSlot(aiTerrainMgr.GetReservationState(gantrySlot),
            aiTerrainMgr.IsReservationBuildable(gantrySlot),aiTerrainMgr.IsZoneClear(gantryExit))) {
            aiTerrainMgr.ReleasePersistentBuilding(gantrySlot); aiTerrainMgr.ReleaseZone(gantryExit);
            gantrySlot=-1; gantryExit=0; Save();
        }
        if (!secured || (site.x>=0 && !Protected(site))) {
            // Cancellation callbacks mutate projects; snapshot only on this
            // exceptional path. Started frames remain repairable investments.
            array<IUnitTask@> work=SeaEconomy::projects;
            for (uint i=0;i<work.length();++i) {
                IBuilderTask@ t=cast<IBuilderTask>(work[i]);
                if (t is null || t.IsDead() || t.target !is null || !Factory(t.buildDef)) continue;
                // Overflow factories belong to their own harbor berth. During
                // travel the native served reservation can still be -1; it
                // must not match an unplanned invasion lab/gantry's -1 ID.
                if (SeaMath::MatchesFactoryReservation(AiTaskReservationId(t),labSlot,gantrySlot)) aiBuilderMgr.AbortTask(t);
            }
        }
        Plan(); PlanGantry();
        if (site.x>=0) {
            CCircuitDef@ nano=ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(Global::AISettings::Side));
            PlanSupport(nano,site,Global::RoleSettings::Sea::InvasionLabTurrets);
            if (gantrySlot>=0) PlanSupport(nano,aiTerrainMgr.GetReservationPos(gantrySlot),Global::RoleSettings::Sea::InvasionGantryTurrets);
        }
        Waves();
    }
}
