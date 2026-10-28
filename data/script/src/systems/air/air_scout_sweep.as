// Mixed reconnaissance packages reuse native per-unit MOVE routes and the
// existing spawn geometry, income window, recruitment and allied roster APIs.
namespace AirScoutSweep {
    bool requested = false, forming = false, dispatching = false;
    int firstPlantFrame = -1, nextPeriodic = -1, checked = -SECOND, planAfter = 0;
    dictionary excluded, members, arrived, flying, endpoints, expires, caps;
    array<AIFloat3> starts, goals;
    const array<string> scoutDefs={"armpeep","corfink","legfig"};
    const array<string> radarDefs={"armawac","corawac","legwhisper"};
    CRouteTask@ assembly;

    bool Enabled() { return Global::RoleSettings::Air::ScoutSweepEnabled; }
    bool Gate() {
        return Economy::IncomeWindowReady()
            && Economy::GetMinMetalIncomeLast10s() >= Global::RoleSettings::Air::ScoutSweepMetal
            && Economy::GetMinEnergyIncomeLast10s() >= Global::RoleSettings::Air::ScoutSweepEnergy;
    }
    int Kind(const string &in name) {
        const string side = UnitHelpers::GetSideForUnitName(name);
        return name == UnitHelpers::GetT1AirScoutForSide(side) ? 0 : name == AirRecon::Name(side) ? 1 : -1;
    }
    // A requested package's own counts (lolcannon, owner 2026-10-26): pending until the
    // package begins, in force while it forms, -1 for the settings.
    int pendT1 = -1, pendRadar = -1, wantT1 = -1, wantRadar = -1;
    // and its target (owner 2026-10-27): each plane to its own point spread round
    // the target, then on to the far edge (LolCannonRecon::Route); x < 0 none.
    AIFloat3 pendAt(-1,0,-1), wantAt(-1,0,-1);
    float pendSpread = 0.0f, wantSpread = 0.0f;
    bool Targeted() { return wantAt.x >= 0.0f; }
    // The nuke rush's request (owner 2026-10-28) skips the T2-plant and income
    // gates: T1 scouts at once, radar planes only once a T2 plant is up.
    bool pendUrgent = false, wantUrgent = false;
    int Wanted(int kind) {
        if (kind == 0) return wantT1 >= 0 ? wantT1 : Global::RoleSettings::Air::ScoutSweepT1Count;
        return wantRadar >= 0 ? wantRadar : Global::RoleSettings::Air::ScoutSweepRadarCount;
    }
    void Exclude(CCircuitUnit@ u) {
        if(forming && u !is null && Kind(u.circuitDef.GetName())>=0) excluded.set(""+u.id,true);
    }
    int Count(int kind) {
        int count = 0;
        array<string>@ ids = members.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null && Kind(u.circuitDef.GetName()) == kind) ++count;
        }
        return count;
    }
    void PlantFinished(CCircuitUnit@ u) {
        if (!Enabled() || !AirEconomy::Active() || firstPlantFrame >= 0 || u is null
            || u.GetBuildProgress() < 1.0f || !UnitHelpers::IsT2AircraftPlant(u.circuitDef.GetName())) return;
        firstPlantFrame = ai.frame;
        nextPeriodic = ai.frame + Global::RoleSettings::Air::ScoutSweepFirstSeconds * SECOND;
        GenericHelpers::LogUtil("[AIR][ScoutSweep] first T2 plant=" + u.id + " due=" + nextPeriodic, 1);
    }
    void Request() { if (Enabled() && AirEconomy::Active()) requested = true; }
    void Request(int t1, int radar, const AIFloat3 &in at, float spread) {
        if (!Enabled() || !AirEconomy::Active()) return;
        if (forming && !dispatching && Targeted() && at.x >= 0.0f) {
            // the targeted package still forming flies to the newest area instead
            wantAt = at; wantSpread = spread;
            GenericHelpers::LogUtil("[AIR][ScoutSweep] forming package retargeted x="+int(at.x)+" z="+int(at.z),1);
            return;
        }
        pendT1 = AiMax(0, t1); pendRadar = AiMax(0, radar); pendAt = at; pendSpread = spread; requested = true;
    }
    void Urgent(const AIFloat3 &in at, float spread) {
        if (!Enabled() || !AirEconomy::Active()) return;
        if (forming && !dispatching) {
            // the package already forming takes the nuke's target and loses its gates
            if (at.x >= 0.0f) { wantAt = at; wantSpread = spread; }
            wantUrgent = true;
            GenericHelpers::LogUtil("[AIR][ScoutSweep] forming package takes the nuke request x="+int(at.x)+" z="+int(at.z),1);
            return;
        }
        pendT1 = Global::RoleSettings::Air::ScoutSweepT1Count; pendRadar = Global::RoleSettings::Air::ScoutSweepRadarCount;
        pendAt = at; pendSpread = spread; pendUrgent = true; requested = true;
    }

    AIFloat3 Mean(const array<AIFloat3> &in points, const AIFloat3 &in fallback) {
        if (points.isEmpty()) return fallback;
        AIFloat3 result(0,0,0);
        for (uint i = 0; i < points.length(); ++i) { result.x += points[i].x; result.z += points[i].z; }
        result.x /= float(points.length()); result.z /= float(points.length());
        return result;
    }
    bool Plan() {
        const AIFloat3 home = Mean(Lanes::ScriptStarts(false), Global::Map::StartPos);
        const AIFloat3 enemy = Mean(Lanes::ScriptStarts(true), AirScreen::Enemy(home));
        const float dx = enemy.x-home.x, dz = enemy.z-home.z;
        const float length = sqrt(dx*dx+dz*dz);
        if (length < 1.0f) return false;
        const AIFloat3 forward(dx/length,0,dz/length), across(-dz/length,0,dx/length);
        const AIFloat3 centre((home.x+enemy.x)*0.5f,0,(home.z+enemy.z)*0.5f);
        const float left = AirRecon::Extent(centre,-across.x,-across.z);
        const float right = AirRecon::Extent(centre,across.x,across.z);
        CCircuitDef@ ground = ai.GetCircuitDef("armllt");
        CCircuitDef@ water = ai.GetCircuitDef("armtide");
        if (ground is null) return false;
        array<AIFloat3> staging, targets;
        // At most 56 * 12 terrain samples per side, once per package (not per
        // aircraft/tick). Quantiles of valid strips spread over buildable ground
        // without collapsing individual points onto the same map edge.
        for (int lane = 0; lane < 56; ++lane) {
            const float offset = -left+(left+right)*(float(lane)+0.5f)/56.0f;
            AIFloat3 start(-1,0,0), goal(-1,0,0);
            for (int depth = 0; depth < 12; ++depth) {
                const float along = 0.12f+float(depth)*0.025f;
                const AIFloat3 a(home.x+forward.x*length*along+across.x*offset,0,home.z+forward.z*length*along+across.z*offset);
                const AIFloat3 b(enemy.x-forward.x*length*along+across.x*offset,0,enemy.z-forward.z*length*along+across.z*offset);
                if (start.x < 0 && AirLayout::Inside(a,128) && AirHome::Friendly(a)
                    && (aiTerrainMgr.CanUpgradeTerrain(ground,a) || (water !is null && aiTerrainMgr.CanUpgradeTerrain(water,a)))) start=a;
                if (goal.x < 0 && AirLayout::Inside(b,128) && !AirHome::Friendly(b)
                    && (aiTerrainMgr.CanUpgradeTerrain(ground,b) || (water !is null && aiTerrainMgr.CanUpgradeTerrain(water,b)))) goal=b;
            }
            if (start.x >= 0 && (goal.x >= 0 || Targeted())) { staging.insertLast(start); targets.insertLast(goal); }
        }
        const int total = Wanted(0)+Wanted(1);
        if (total <= 0 || int(staging.length()) < total) return false;
        starts.resize(0); goals.resize(0);
        for (int i = 0; i < total; ++i) {
            const int index = AiMin(int(staging.length())-1,int((float(i)+0.5f)*float(staging.length())/float(total)));
            starts.insertLast(staging[index]); goals.insertLast(targets[index]);
        }
        return true;
    }
    void Begin() {
        if (ai.frame<planAfter) return;
        wantT1=pendT1; wantRadar=pendRadar; wantAt=pendAt; wantSpread=pendSpread; wantUrgent=pendUrgent;
        if (wantUrgent && firstPlantFrame<0) wantRadar=0;  // radar planes need the T2 plant
        if (!Plan()) { wantT1=-1; wantRadar=-1; wantAt=AIFloat3(-1,0,-1); wantUrgent=false; planAfter=ai.frame+10*SECOND; return; }
        pendT1=-1; pendRadar=-1; pendAt=AIFloat3(-1,0,-1); pendUrgent=false;
        excluded.deleteAll(); members.deleteAll(); arrived.deleteAll();
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i=0;i<ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
            // Existing units, including unfinished frames, are not the new
            // package. Never steal the opening scout or a player's aircraft.
            if (u !is null && Kind(u.circuitDef.GetName()) >= 0) excluded.set(""+u.id,true);
        }
        @assembly=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        if (assembly is null) return;
        assembly.SetAirControl(true); assembly.SetPatrol(true); assembly.SetTraversal(true,128,false);
        assembly.SetRoute(array<AIFloat3> = {starts[0]});
        forming=true; requested=false; dispatching=false;
        GenericHelpers::LogUtil("[AIR][ScoutSweep] package requested scouts="+Wanted(0)+" radar="+Wanted(1)+(wantUrgent ? " (nuke, ungated)" : ""),1);
    }
    IUnitTask@ TaskFor(CCircuitUnit@ u) {
        if (!Enabled() || !AirEconomy::Active() || !AirRecon::Controlled(u)) return null;
        CRouteTask@ task;
        const string key=""+u.id;
        if (flying.get(key,@task) && task !is null && !task.IsDead()) return task;
        if (!forming || assembly is null || assembly.IsDead() || excluded.exists(key) || u.GetBuildProgress()<1.0f) return null;
        const int kind=Kind(u.circuitDef.GetName());
        if (kind<0) return null;
        if (!members.exists(key)) {
            if (Count(kind)>=Wanted(kind)) return null;
            members.set(key,-1);
        }
        u.SetIdleMode(0); u.SetFireState(0);
        return assembly;
    }
    IUnitTask@ Produce(CCircuitUnit@ plant) {
        if (!Enabled() || !AirEconomy::Active() || !forming || dispatching || !AirRecon::Controlled(plant)
            || Lifecycle::IsRetiring(plant) || (!wantUrgent && !Gate())) return null;
        const string side=UnitHelpers::GetSideForUnitName(plant.circuitDef.GetName());
        const int kind=UnitHelpers::IsT1AircraftPlant(plant.circuitDef.GetName()) ? 0 : 1;
        CCircuitDef@ def=ai.GetCircuitDef(kind==0 ? UnitHelpers::GetT1AirScoutForSide(side) : AirRecon::Name(side));
        if (def is null || !plant.circuitDef.CanBuild(def)) return null;
        // Native definition counts cover finished aircraft and factory frames;
        // the pending index covers orders without frames. Only the small
        // pre-package scout ledger is reread, never the whole late-game army.
        int outside=0, projected=0;
        for(uint i=0;i<scoutDefs.length();++i) {
            CCircuitDef@ candidate=ai.GetCircuitDef(kind==0 ? scoutDefs[i] : radarDefs[i]);
            if(candidate !is null) projected+=candidate.count+aiFactoryMgr.GetPendingRecruitCount(candidate);
        }
        array<string>@ ids=excluded.getKeys();
        for (uint i=0;i<ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null && Kind(u.circuitDef.GetName())==kind) ++outside;
        }
        const int missing=Wanted(kind)-(projected-outside);
        if (missing<=0) return null;
        if (!caps.exists(def.GetName())) caps.set(def.GetName(),int(def.maxThisUnit));
        def.maxThisUnit=2147483647;
        return AirProduction::Recruit(plant,def.GetName(),AirProduction::Projected(def)+missing,"scout.sweep",Task::Priority::HIGH);
    }
    void Tick() {
        if (!Enabled() || !AirEconomy::Active() || ai.frame-checked<SECOND) return;
        checked=ai.frame;
        // Lifecycle factory list: O(F) only until the first completed T2 plant.
        if (firstPlantFrame<0) for (uint i=0;i<Factory::factoryList.length();++i) PlantFinished(Factory::factoryList[i]);
        if (nextPeriodic>=0 && ai.frame>=nextPeriodic) {
            GenericHelpers::LogUtil("[AIR][ScoutSweep] periodic due="+nextPeriodic,1);
            requested=true;
            do { nextPeriodic+=AiMax(1,Global::RoleSettings::Air::ScoutSweepIntervalSeconds)*SECOND; } while(nextPeriodic<=ai.frame);
        }
        array<string>@ away=flying.getKeys();
        for (uint i=0;i<away.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(away[i])); CRouteTask@ task; flying.get(away[i],@task);
            AIFloat3 end; endpoints.get(away[i],end); int deadline=0; expires.get(away[i],deadline);
            if (u !is null && u.task is task && task !is null && !task.IsDead()
                && ai.frame<deadline && MapHelpers::SqDist(u.GetPos(ai.frame),end)>256.0f*256.0f) continue;
            if (u !is null && u.task is task && task !is null && !task.IsDead()
                && MapHelpers::SqDist(u.GetPos(ai.frame),end)<=256.0f*256.0f)
                GenericHelpers::LogUtil("[AIR][ScoutSweep] arrived unit="+u.id,1);
            if (u !is null && u.task is task) { u.SetIdleMode(1); u.SetFireState(u.circuitDef.GetFireState()); }
            flying.delete(away[i]); endpoints.delete(away[i]); expires.delete(away[i]);
            if (task !is null && !task.IsDead()) task.Abort();
        }
        if (!forming && requested && ((firstPlantFrame>=0 && Gate()) || pendUrgent)) Begin();
        if (!forming) return;
        if (assembly is null || assembly.IsDead()) {
            if (Targeted() && pendAt.x < 0.0f) { pendT1=wantT1; pendRadar=wantRadar; pendAt=wantAt; pendSpread=wantSpread; }
            if (wantUrgent) pendUrgent=true;
            forming=false; requested=true; return;
        }
        array<string>@ ids=members.getKeys(); ids.sortAsc();
        array<bool> used(starts.length(),false);
        for (uint i=0;i<ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i])); int slot=-1; members.get(ids[i],slot);
            if (!AirRecon::Controlled(u) || u.task !is assembly) {
                if (u !is null) excluded.set(ids[i],true);
                members.delete(ids[i]); arrived.delete(ids[i]); continue;
            }
            if (slot>=0 && slot<int(used.length())) used[slot]=true;
        }
        @ids=members.getKeys(); ids.sortAsc();
        for (uint i=0;i<ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i])); int slot=-1; members.get(ids[i],slot);
            if (slot<0) {
                const int kind=Kind(u.circuitDef.GetName());
                for (uint n=0;n<used.length();++n) {
                    const int slotKind = (int(n+1)*Wanted(1)/int(used.length()) != int(n)*Wanted(1)/int(used.length())) ? 1 : 0;
                    if (!used[n] && kind==slotKind) { slot=int(n); used[n]=true; break; }
                }
                if (slot<0) continue;
                if (!assembly.SetUnitRoute(u,array<AIFloat3> = {starts[slot]},128)) continue;
                members.set(ids[i],slot);
            }
            if (MapHelpers::SqDist(u.GetPos(ai.frame),starts[slot])<=480.0f*480.0f) arrived.set(ids[i],true);
        }
        if (!dispatching && ((!wantUrgent && !Gate()) || Count(0)!=Wanted(0) || Count(1)!=Wanted(1) || arrived.getSize()!=members.getSize())) return;
        dispatching=true;
        // One task per aircraft lets a surviving route be released independently.
        for (uint i=0;i<ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i])); int slot=-1; members.get(ids[i],slot);
            if (slot<0) continue;
            CRouteTask@ task=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (task is null) continue;
            array<AIFloat3>@ route = null;
            if (Targeted()) @route = LolCannonRecon::Route(starts[slot],wantAt,slot,int(starts.length()),wantSpread);
            else { @route = array<AIFloat3>(); route.insertLast(goals[slot]); }
            const AIFloat3 end=route[route.length()-1];
            task.SetAirControl(true); task.SetTraversal(true,256,false); task.SetRoute(route);
            if (!aiMilitaryMgr.TransferUnit(u,task)) { task.Abort(); continue; }
            flying.set(ids[i],@task); endpoints.set(ids[i],end); expires.set(ids[i],ai.frame+Global::RoleSettings::Air::ScoutSweepTimeoutSeconds*SECOND);
            members.delete(ids[i]); arrived.delete(ids[i]);
            GenericHelpers::LogUtil("[AIR][ScoutSweep] crossing unit="+u.id+" def="+u.circuitDef.GetName()+" x="+int(route[0].x)+" z="+int(route[0].z)
                +(route.length()>1 ? " then x="+int(end.x)+" z="+int(end.z) : ""),1);
        }
        if (members.isEmpty()) { assembly.Abort(); @assembly=null; forming=false; excluded.deleteAll(); wantT1=-1; wantRadar=-1; wantAt=AIFloat3(-1,0,-1); wantUrgent=false; }
    }
    void Reset() {
        array<string>@ controlled=members.getKeys();
        array<string>@ flights=flying.getKeys();
        for(uint i=0;i<flights.length();++i) controlled.insertLast(flights[i]);
        for(uint i=0;i<controlled.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(controlled[i])); CRouteTask@ task;
            if(!flying.get(controlled[i],@task)) @task=assembly;
            if(u !is null && u.task is task) { u.SetIdleMode(1); u.SetFireState(u.circuitDef.GetFireState()); }
        }
        if (assembly !is null && !assembly.IsDead()) assembly.Abort();
        array<string>@ ids=flying.getKeys();
        for(uint i=0;i<ids.length();++i) { CRouteTask@ task; flying.get(ids[i],@task); if(task !is null && !task.IsDead()) task.Abort(); }
        @ids=caps.getKeys();
        for(uint i=0;i<ids.length();++i) { CCircuitDef@ def=ai.GetCircuitDef(ids[i]); int cap=0; if(def !is null && caps.get(ids[i],cap)) def.maxThisUnit=cap; }
        pendT1=-1; pendRadar=-1; wantT1=-1; wantRadar=-1; pendAt=AIFloat3(-1,0,-1); wantAt=AIFloat3(-1,0,-1); pendUrgent=false; wantUrgent=false;
        @assembly=null; forming=false; dispatching=false; requested=false; firstPlantFrame=-1; nextPeriodic=-1; checked=-SECOND; planAfter=0;
        excluded.deleteAll(); members.deleteAll(); arrived.deleteAll(); flying.deleteAll(); endpoints.deleteAll(); expires.deleteAll(); caps.deleteAll(); starts.resize(0); goals.resize(0);
    }
}
