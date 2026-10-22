// Defensive naval relief. Facts are native; selection, budgets and orders are AIR policy.
namespace AirNavalSupport {
    const array<string> names={"armlance","cortitan","legatorpbomber"};
    class Sector {
        AIFloat3 centre;
        int body=-1;
        float enemy=0, friendly=0, subs=0, antiSub=0;
        bool anchor=false;
        int samples=0;
        array<int> enemies;
    }
    dictionary held, active;
    CRouteTask@ reserve, wave, escort;
    int checked=-100000, waitingSince=-1, target=-1, phase=0, contactSeen=-100000;
    int desired=0, targetIndex=-1, launchSize=0;
    float deficit=0;
    string sectorKey="";
    AIFloat3 aim, ingress, escortAim;
    bool routeReady=false, routeBlocked=false;
    bool Enabled() { return AirEconomy::Active() && Global::RoleSettings::Air::NavalSupportEnabled; }
    bool IsTorpedo(const CCircuitDef@ d) { return d !is null && names.find(d.GetName())>=0; }
    string Name(const string &in side) { return side=="cortex" ? names[1] : side=="legion" ? names[2] : names[0]; }
    int Required(const CCircuitDef@ d) {
        return d is null ? 0 : AirMath::NavalWave(deficit,Global::RoleSettings::Air::NavalSupportMinDeficit,
            Global::RoleSettings::Air::NavalSupportReserveFactor,d.costM,
            Global::RoleSettings::Air::NavalSupportMinWave,Global::RoleSettings::Air::NavalSupportMaxWave);
    }
    IUnitTask@ TaskFor(CCircuitUnit@ u) {
        if (!Enabled() || u is null || !IsTorpedo(u.circuitDef) || !AirBaseResponse::Free(u)) return null;
        const string key=""+u.id;
        if (active.exists(key) && wave !is null && !wave.IsDead()) return wave;
        active.delete(key);
        if (reserve is null || reserve.IsDead()) {
            @reserve=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (reserve is null) return null;
            array<AIFloat3> route={AirScreen::Anchor()};
            reserve.SetAirControl(true); reserve.SetTraversal(true,256,false); reserve.SetRoute(route);
        }
        held.set(key,true); u.SetIdleMode(0); u.SetFireState(0);
        return reserve;
    }
    void Census() {
        array<string>@ keys=held.getKeys();
        for (uint i=0;i<keys.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(keys[i]));
            if (!AirBaseResponse::Free(u) || reserve is null || u.task !is reserve) held.delete(keys[i]);
        }
        @keys=active.getKeys();
        for (uint i=0;i<keys.length();++i) {
            if(held.exists(keys[i]))Invariants::Violation("INV-142",keys[i],"torpedo aircraft is both held and launched");
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(keys[i]));
            if (!AirBaseResponse::Free(u) || wave is null || u.task !is wave) active.delete(keys[i]);
        }
        if (held.isEmpty()) waitingSince=-1;
        else if (waitingSince<0) waitingSince=ai.frame;
    }
    void Assess() {
        dictionary sectors;
        const float radius=AiMax(800.0f,AiMin(6000.0f,Global::RoleSettings::Air::NavalSupportRadius));
        // Centre sectors on actual enemy concentrations, not empty grid points:
        // overlapping synthetic circles otherwise manufacture fleet deficits.
        const float friendlyRadius=radius*AiMax(1.0f,AiMin(2.0f,Global::RoleSettings::Air::NavalSupportFriendlyRadiusFactor));
        const int count=aiBattle.GetNavalForceCount();
        for(int i=0;i<count;++i) {
            if((aiBattle.GetNavalForceFlags(i)&9)!=0)continue;
            const AIFloat3 p=aiBattle.GetNavalForcePos(i);
            const string key=aiBattle.GetNavalForceBody(i)+":"+int(p.x/radius)+":"+int(p.z/radius);
            Sector@ s;
            if(!sectors.get(key,@s)) { @s=Sector();s.centre=AIFloat3(0,0,0);s.body=aiBattle.GetNavalForceBody(i);sectors.set(key,@s); }
            s.centre.x+=p.x;s.centre.z+=p.z;++s.samples;
        }
        array<string>@ keys=sectors.getKeys();keys.sortAsc();
        for(uint i=0;i<keys.length();++i) {
            Sector@ s;sectors.get(keys[i],@s);s.centre.x/=float(s.samples);s.centre.z/=float(s.samples);
        }
        for (int i=0;i<count;++i) {
            const int flags=aiBattle.GetNavalForceFlags(i), body=aiBattle.GetNavalForceBody(i);
            const bool friendly=(flags&1)!=0, factory=(flags&8)!=0;
            if (factory && !friendly) continue;
            const AIFloat3 p=aiBattle.GetNavalForcePos(i);
            const int col=int(p.x/radius), row=int(p.z/radius);
            const float cost=aiBattle.GetNavalForceCost(i);
            const int reach=friendly?2:1;
            const float includeRadius=friendly?friendlyRadius:radius;
            for (int z=row-reach;z<=row+reach;++z) for (int x=col-reach;x<=col+reach;++x) {
                if (x<0 || z<0) continue;
                const string key=body+":"+x+":"+z;
                Sector@ s;
                if (!sectors.get(key,@s) || !AirMath::NavalSectorContains(MapHelpers::SqDist(p,s.centre),includeRadius)) continue;
                if (friendly) {
                    s.anchor=true;
                    if (!factory) { s.friendly+=cost; if ((flags&4)!=0) s.antiSub+=cost; }
                } else {
                    s.enemy+=cost; if ((flags&2)!=0) s.subs+=cost;
                    s.enemies.insertLast(i);
                }
            }
        }
        Sector@ selected; string next=""; float best=0;
        for (uint i=0;i<keys.length();++i) {
            Sector@ s; sectors.get(keys[i],@s);
            if (!s.anchor || s.enemies.length()==0) continue;
            const float gap=AirMath::NavalDeficit(s.enemy,s.friendly,s.subs,s.antiSub);
            const float score=gap*(keys[i]==sectorKey ? 1.1f : 1.0f);
            if (gap>=Global::RoleSettings::Air::NavalSupportMinDeficit && score>best) { @selected=s;best=score;next=keys[i]; }
        }
        deficit=0;targetIndex=-1;
        if (selected is null) return;
        deficit=AirMath::NavalDeficit(selected.enemy,selected.friendly,selected.subs,selected.antiSub);
        float rank=-1;
        for (uint i=0;i<selected.enemies.length();++i) {
            const int index=selected.enemies[i], id=aiBattle.GetNavalForceId(index);
            const CCircuitDef@ d=ai.GetCircuitDef(aiBattle.GetNavalForceDefId(index));
            if (d is null) continue;
            const float score=d.costM*(d.HasSurfToAir() ? 1.5f : 1.0f)+(id==target ? 100000.0f : 0.0f);
            if (score>rank) {rank=score;targetIndex=index;}
        }
        if (sectorKey!=next) GenericHelpers::LogUtil("[AIR][Naval] theatre="+next+" enemy="+int(selected.enemy)
            +" friendly="+int(selected.friendly)+" subs="+int(selected.subs)+" antiSub="+int(selected.antiSub)+" deficit="+int(deficit),1);
        sectorKey=next;
    }
    bool WaterRun(const AIFloat3 &in from,const AIFloat3 &in to,int body) {
        const float dx=to.x-from.x,dz=to.z-from.z,len=sqrt(dx*dx+dz*dz);
        if (len<1) return false;
        const int steps=AiMax(1,int(len/64)+1);
        for (int i=0;i<=steps;++i) {
            const float t=float(i)/float(steps);
            for (int side=-1;side<=1;++side) {
                const AIFloat3 p(from.x+dx*t-dz/len*float(side)*64,0,from.z+dz*t+dx/len*float(side)*64);
                if (!AirLayout::Inside(p,64) || aiBattle.Depth(p)<8 || aiBattle.WaterBody(p,false)!=body) return false;
            }
        }
        return true;
    }
    bool Approach(const AIFloat3 &in from,AIFloat3 &out result) {
        result=AIFloat3(-1,0,-1);
        if (targetIndex<0) return false;
        const AIFloat3 p=aiBattle.GetNavalForcePos(targetIndex);
        const int body=aiBattle.GetNavalForceBody(targetIndex);
        const float length=AiMax(600.0f,Global::RoleSettings::Air::NavalSupportApproach);
        float best=1.0e30f;
        for (int i=0;i<16;++i) {
            const float angle=float(i)*0.3926990817f;
            const AIFloat3 candidate(p.x+cos(angle)*length,0,p.z+sin(angle)*length);
            if (!WaterRun(candidate,p,body)) continue;
            const float approachRisk=aiBattle.AirThreatAlong(from,candidate,128);
            const float runRisk=aiBattle.AirThreatAlong(candidate,p,128);
            const float risk=AiMax(approachRisk,runRisk);
            if (risk>Global::RoleSettings::Air::NavalSupportMaxThreat) continue;
            const float score=MapHelpers::SqDist(from,candidate)+risk*100000;
            if (score<best) {best=score;result=candidate;}
        }
        return result.x>=0;
    }
    AIFloat3 Centre(dictionary &in members) {
        array<string>@ keys=members.getKeys(); AIFloat3 centre(0,0,0);int n=0;
        for (uint i=0;i<keys.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(keys[i])); if(u is null)continue;
            const AIFloat3 p=u.GetPos(ai.frame);centre.x+=p.x;centre.z+=p.z;++n;
        }
        if(n==0)return AirScreen::Anchor();centre.x/=float(n);centre.z/=float(n);return centre;
    }
    void Return() {
        array<string>@ keys=active.getKeys();active.deleteAll();
        for(uint i=0;i<keys.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(keys[i]));if(!AirBaseResponse::Free(u))continue;
            IUnitTask@ task=TaskFor(u);
            if(task !is null)aiMilitaryMgr.TransferUnit(u,task);
        }
        if(wave !is null && !wave.IsDead())wave.Abort();@wave=null;phase=0;target=-1;
        if(escort !is null && !escort.IsDead())escort.Abort();@escort=null;
    }
    void Escort(bool launching=false) {
        const AIFloat3 destination=phase==1?ingress:aim;
        const float dx=aim.x-ingress.x,dz=aim.z-ingress.z,len=sqrt(dx*dx+dz*dz);
        const float lead=AiMax(128.0f,Global::RoleSettings::Air::StrikeEscortLead);
        const AIFloat3 point=AirScreen::Clamp(len>1?AIFloat3(destination.x+dx/len*lead,0,destination.z+dz/len*lead):destination);
        if(launching) {
            @escort=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));if(escort is null)return;
            escort.SetAirControl(true);escort.SetTraversal(true,256,true);
        }
        if(escort is null || escort.IsDead())return;
        if(launching || MapHelpers::SqDist(point,escortAim)>384.0f*384.0f) {
            array<AIFloat3> route;if(phase==1)route.insertLast(ingress);route.insertLast(point);escort.SetRoute(route);escortAim=point;
        }
        if(launching) GenericHelpers::LogUtil("[AIR][Naval] escorts="+AirOperations::AttachAvailableFighters(escort),1);
    }
    void Tick() {
        if(!Enabled() || ai.frame-checked<AiMax(1,Global::RoleSettings::Air::NavalSupportCheckSeconds)*SECOND)return;
        checked=ai.frame;Census();Assess();
        // Adopt donations and aircraft previously owned by native generic tasks.
        array<Id>@ owned=ai.GetOwnedUnitIds();
        for(uint i=0;i<owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]);
            if(u is null || !IsTorpedo(u.circuitDef) || held.exists(""+u.id) || active.exists(""+u.id))continue;
            IUnitTask@ task=TaskFor(u);if(task !is null)aiMilitaryMgr.TransferUnit(u,task);
        }
        Census();
        if(AirBaseResponse::Emergency()) {if(!active.isEmpty())Return();routeReady=false;return;}
        CCircuitDef@ def=ai.GetCircuitDef(Name(Global::AISettings::Side));desired=Required(def);
        routeReady=false;
        if(targetIndex>=0)contactSeen=ai.frame;
        if(active.isEmpty()) {
            if(wave !is null && !wave.IsDead())wave.Abort();@wave=null;phase=0;target=-1;
            if(escort !is null && !escort.IsDead())escort.Abort();@escort=null;
            routeReady=Approach(Centre(held),ingress);
            const bool blocked=desired>0 && targetIndex>=0 && !routeReady;
            if(blocked && !routeBlocked)GenericHelpers::LogUtil("[AIR][Naval] hold: no acceptable open-water/AA approach; reserve deadline retained",1);
            routeBlocked=blocked;
            if(!AirMath::NavalRelease(int(held.getSize()),desired,waitingSince<0?0:ai.frame-waitingSince,
                Global::RoleSettings::Air::NavalSupportMaxWaitSeconds*SECOND,routeReady))return;
            @wave=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if(wave is null) {Invariants::Violation("INV-142","naval release","eligible wave task creation failed");return;}
            array<AIFloat3> route={ingress};wave.SetAirControl(true);wave.SetTraversal(true,256,false);wave.SetRoute(route);
            array<string>@ keys=held.getKeys(); keys.sortAsc();launchSize=0;
            for(uint i=0;i<keys.length() && launchSize<desired;++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(parseInt(keys[i]));
                if(!AirBaseResponse::Free(u))continue;
                if(aiMilitaryMgr.TransferUnit(u,wave)) {u.SetIdleMode(0);u.SetFireState(0);active.set(keys[i],true);held.delete(keys[i]);++launchSize;}
            }
            if(launchSize==0) {Invariants::Violation("INV-142","naval release","no available torpedo aircraft transferred");wave.Abort();@wave=null;return;}
            target=aiBattle.GetNavalForceId(targetIndex);aim=aiBattle.GetNavalForcePos(targetIndex);phase=1;
            Escort(true);
            GenericHelpers::LogUtil("[AIR][Naval] launch="+launchSize+" wanted="+desired+" target="+target+" reason="+(launchSize>=desired?"full":"deadline")+" ingress="+int(ingress.x)+","+int(ingress.z),1);
            waitingSince=held.isEmpty()?-1:ai.frame;return;
        }
        if(targetIndex<0) {
            // Stop shooting a contact that has vanished; search its last water
            // position briefly, then return. Never keep attacking a memory ID.
            if(wave !is null && target>=0) {
                wave.SetAirTarget(-1);array<AIFloat3> search={aim};wave.SetRoute(search);target=-1;
            }
            if(ai.frame-contactSeen>=Global::RoleSettings::Air::NavalSupportSearchSeconds*SECOND) {
                GenericHelpers::LogUtil("[AIR][Naval] return survivors="+active.getSize(),1);Return();
            }
            return;
        }
        const int next=aiBattle.GetNavalForceId(targetIndex);
        const AIFloat3 observed=aiBattle.GetNavalForcePos(targetIndex);
        if(aiBattle.AirThreat(observed)>Global::RoleSettings::Air::NavalSupportMaxThreat) {Return();return;}
        if(next!=target || (phase==1 && MapHelpers::SqDist(aim,observed)>384.0f*384.0f)) {
            AIFloat3 approach;
            if(!Approach(Centre(active),approach)) {Return();return;}
            target=next;aim=aiBattle.GetNavalForcePos(targetIndex);ingress=approach;phase=1;
            array<AIFloat3> route={ingress};wave.SetAirTarget(-1);wave.SetRoute(route);
        }
        if(phase==1) {
            int ready=0;array<string>@ keys=active.getKeys();
            for(uint i=0;i<keys.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(parseInt(keys[i]));
                if(u !is null && MapHelpers::SqDist(u.GetPos(ai.frame),ingress)<650.0f*650.0f)++ready;
            }
            if(ready>0 && ready*2>=int(active.getSize())) {
                phase=2;wave.SetAirTarget(target);
                for(uint i=0;i<keys.length();++i) {CCircuitUnit@ u=ai.GetTeamUnit(parseInt(keys[i]));if(u !is null)u.SetFireState(2);}
                GenericHelpers::LogUtil("[AIR][Naval] attack="+active.getSize()+" target="+target,1);
            }
        }
        aim=observed;Escort();
    }
    IUnitTask@ Produce(CCircuitUnit@ plant) {
        if(!Enabled() || AirBaseResponse::Emergency() || !active.isEmpty() || !routeReady || targetIndex<0)return null;
        const string name=Name(UnitHelpers::GetSideForUnitName(plant.circuitDef.GetName()));
        CCircuitDef@ def=ai.GetCircuitDef(name);
        if(def is null || !plant.circuitDef.CanBuild(def))return null;
        const int goal=Required(def);if(goal<=0)return null;
        AirRecon::Unlock(def);
        // Count available reserve plus frames and pending orders; player-owned
        // aircraft never satisfy this controller's production requirement.
        int ready=0, frames=0, queued=0;
        array<Id>@ owned=ai.GetOwnedUnitIds();
        for(uint i=0;i<owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(owned[i]);if(u is null || !IsTorpedo(u.circuitDef))continue;
            if(u.GetBuildProgress()<1)++frames;else if(AirBaseResponse::Free(u))++ready;
        }
        for(uint i=0;i<names.length();++i) {CCircuitDef@ d=ai.GetCircuitDef(names[i]);if(d !is null)queued+=aiFactoryMgr.GetPendingRecruitCount(d);}
        if(AirMath::DefenceDeficit(goal,ready,frames,queued)==0)return null;
        return AirProduction::Recruit(plant,name,AirProduction::Projected(def)+1,"naval.relief",Task::Priority::HIGH);
    }
    void Reset() {
        held.deleteAll();active.deleteAll();
        if(reserve !is null && !reserve.IsDead())reserve.Abort();
        if(wave !is null && !wave.IsDead())wave.Abort();
        if(escort !is null && !escort.IsDead())escort.Abort();
        @reserve=null;@wave=null;@escort=null;checked=-100000;waitingSince=-1;target=-1;phase=0;desired=0;deficit=0;routeReady=false;routeBlocked=false;sectorKey="";
    }
}
