// SEA-only anti-nuke ownership. Route tasks provide passive guard movement:
// the native stockpile manager keeps ammunition ownership. Never use the
// ordinary fighter Guard task here: its engage branch can chase a radar blip.
namespace SeaProtection {
    class Ship {
        int id=-1, flagship=-1, seen=-1;
        AIFloat3 goal;
        CRouteTask@ route;
    }
    array<Ship@> ships;
    array<int> flagships;
    dictionary index;
    int baseShip=-1;
    AIFloat3 baseHome(-1,0,-1);
    bool Handles(const CCircuitDef@ d) {
        if (d is null) return false;
        const string n=d.GetName();
        return n=="armantiship" || n=="corantiship" || n=="leganavyantinukecarrier";
    }
    bool Flagship(const CCircuitDef@ d) {
        const string n=d.GetName();
        return n=="armepoch" || n=="corblackhy" || n=="leganavyflagship";
    }
    bool Available(CCircuitUnit@ u) {
        return u !is null && u.GetBuildProgress()>=1 && Handles(u.circuitDef)
            && (u.task is null || (u.task.GetType()!=int(Task::Type::PLAYER)
                && u.task.GetType()!=int(Task::Type::RETREAT) && !u.task.IsExternalControlled()));
    }
    void Leave() {
        for (uint i=0;i<ships.length();++i)
            if (ships[i].route !is null && !ships[i].route.IsDead()) ships[i].route.Abort();
        ships.resize(0); flagships.resize(0); index.deleteAll(); baseShip=-1; baseHome=AIFloat3(-1,0,-1);
    }
    int Demand() { return 1+int(flagships.length()); }
    void Tick() {
        if (!Global::RoleSettings::Sea::FleetOperations) { Leave(); return; }
        flagships.resize(0);
        // Reuse the one-second owned census; O(U + A*F), where A is the small
        // anti-nuke support population. IDs are reacquired after every transfer.
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (u is null || u.GetBuildProgress()<1) continue;
            if (Flagship(u.circuitDef)) flagships.insertLast(u.id);
            if (!Available(u)) continue;
            int at=-1;
            if (!index.get(""+u.id,at)) {
                Ship@ s=Ship(); s.id=u.id; at=int(ships.length()); ships.insertLast(s); index.set(""+u.id,at);
            }
            ships[at].seen=ai.frame;
        }
        uint live=0;
        for (uint i=0;i<ships.length();++i) {
            Ship@ s=ships[i];
            if (s.seen!=ai.frame) {
                if (s.id==baseShip) baseShip=-1;
                if (s.route !is null && !s.route.IsDead()) s.route.Abort();
                continue;
            }
            @ships[live++]=s;
        }
        ships.resize(live); index.deleteAll();
        for (uint i=0;i<ships.length();++i) index.set(""+ships[i].id,int(i));
        if (baseShip<0 && ships.length()>0) baseShip=ships[0].id;
        dictionary assigned;
        for (uint i=0;i<ships.length();++i) {
            Ship@ s=ships[i]; CCircuitUnit@ u=ai.GetTeamUnit(s.id); if (!Available(u)) continue;
            const AIFloat3 here=u.GetPos(ai.frame);
            if (s.id==baseShip && baseHome.x>=0 && s.route !is null && !s.route.IsDead() && u.task is s.route
                && s.route.IsAtEnd(u) && MapHelpers::SqDist(here,baseHome)>(Global::RoleSettings::Sea::AntiNukeBaseRadius+128)*(Global::RoleSettings::Sea::AntiNukeBaseRadius+128))
                Invariants::Violation("INV-178",""+s.id,"base anti-nuke settled outside its home radius");
            const int body=aiBattle.WaterBody(here,false);
            if (baseHome.x<0) {
                // A future reserved forward yard is not the home base. Anchor
                // to the nearest completed real yard, once; retirement never
                // drags the designated base interceptor toward the frontline.
                baseHome=here; float closest=1e30f;
                for (uint j=0;j<SeaEconomy::productionFactories.length();++j) {
                    CCircuitUnit@ yard=ai.GetTeamUnit(SeaEconomy::productionFactories[j]);
                    if (yard is null || yard.GetBuildProgress()<1 || !SeaEconomy::Yard(yard.circuitDef)) continue;
                    const float distance=MapHelpers::SqDist(yard.GetPos(ai.frame),Global::Map::StartPos);
                    if (distance<closest) { closest=distance; baseHome=yard.GetPos(ai.frame); }
                }
            }
            const AIFloat3 home=baseHome;
            int escort=-1; float best=1e30f;
            if (s.id!=baseShip) for (uint j=0;j<flagships.length();++j) {
                CCircuitUnit@ f=ai.GetTeamUnit(flagships[j]);
                if (f is null || assigned.exists(""+f.id) || aiBattle.WaterBody(f.GetPos(ai.frame),false)!=body) continue;
                const float distance=MapHelpers::SqDist(here,f.GetPos(ai.frame))*(s.flagship==f.id ? .5f : 1.0f);
                if (distance<best) { best=distance; escort=f.id; }
            }
            AIFloat3 goal=home;
            if (escort>=0) {
                assigned.set(""+escort,true);
                const AIFloat3 p=ai.GetTeamUnit(escort).GetPos(ai.frame);
                const float length=AiMax(1.0f,sqrt(MapHelpers::SqDist(p,home)));
                goal=AIFloat3(p.x+(home.x-p.x)*256/length,0,p.z+(home.z-p.z)*256/length);
            }
            // Select a legal nearby water point, never a shared land fallback.
            AIFloat3 selected(-1,0,-1); best=1e30f;
            for (int j=0;j<17;++j) {
                const float a=float(j)*.785398f, r=j==0 ? 0 : j<=8 ? 160.0f : 320.0f;
                const AIFloat3 p=Spam::_Clamp(AIFloat3(goal.x+cos(a)*r,0,goal.z+sin(a)*r));
                if (escort<0 && MapHelpers::SqDist(p,home)>Global::RoleSettings::Sea::AntiNukeBaseRadius*Global::RoleSettings::Sea::AntiNukeBaseRadius) continue;
                const float score=MapHelpers::SqDist(p,goal);
                if (score>=best || aiBattle.WaterBody(p,false)!=body || !aiTerrainMgr.CanMoveTo(u,p)
                    || aiBattle.AmphThreat(p)>.1f || aiBattle.SurfThreat(p)>.1f) continue;
                best=score; selected=p;
            }
            if (selected.x<0) continue;
            if (s.id==baseShip && escort>=0) Invariants::Violation("INV-178",""+s.id,"base anti-nuke assigned away from home");
            if (s.route !is null && !s.route.IsDead() && u.task is s.route && escort==s.flagship
                && MapHelpers::SqDist(selected,s.goal)<192.0f*192.0f) continue;
            array<AIFloat3>@ points=aiBattle.GetTerrainRoute(here,selected,5,10,1,3,1000000);
            if (points.length()<2) { if (MapHelpers::SqDist(here,selected)>128*128) continue; points.resize(0); points.insertLast(selected); }
            if (s.route is null || s.route.IsDead()) @s.route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (s.route is null) continue;
            s.route.SetSeaControl(true); s.route.SetHoldPosition(true); s.route.SetTraversal(true,64,false);
            s.route.SetRoute(points);
            if (u.task !is s.route && !aiMilitaryMgr.TransferUnit(u,s.route)) {
                s.route.Abort(); @s.route=null; continue;
            }
            s.goal=selected; s.flagship=escort;
            GenericHelpers::LogUtil("[SEA][AntiNuke] id="+s.id+" base="+(s.id==baseShip)+" flagship="+escort,1);
        }
    }
}
