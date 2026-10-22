#include "../../helpers/math/sea_math.as"

// SEA-only frontier policy. Native mex tasks still own spot claims, allied
// occupancy, terrain reachability, travel and damage retreat. No direct MOVE
// micro and no terrain-graph rebuild is needed at a builder decision.
namespace SeaExpansion {
    dictionary retryAt;
    dictionary blocked;
    dictionary withdrawing;
    dictionary fortAfterMex;
    array<IUnitTask@> forts;
    array<AIFloat3> enemyStarts;
    array<int> ships;
    bool seeded=false;
    int tickFrame=-100000;
    bool Active() {
        return Global::AISettings::Role==AiRole::SEA && Global::RoleSettings::Sea::ExpandMexClusters
            && !aiEconomyMgr.IsMetalMap();
    }
    // Stable jobs are owned by the constructor lifecycle, not unit-ID order.
    // O(1) asks; O(B) assignment/removal for the small constructor roster only.
    dictionary jobs;
    array<int> jobCounts(3,0);
    int Job(CCircuitUnit@ u) {
        int job=-1;
        if (u is null || !jobs.get(""+u.id,job)) return -1;
        return job;
    }
    bool Worker(CCircuitUnit@ u) {
        return u !is null && SeaConstructor::IsT1(u.circuitDef) && Job(u)==0;
    }
    void Added(CCircuitUnit@ u) {
        if (u is null || !SeaConstructor::IsT1(u.circuitDef) || u.GetBuildProgress()<1 || ships.find(u.id)>=0) return;
        ships.insertLast(u.id);
        const string key="sea.worker."+u.id;
        int job=aiTerrainMgr.GetLayoutInt(key,-1);
        if (job<0 || job>2) {
            job=SeaMath::WorkerGroup(jobCounts[0],jobCounts[1],jobCounts[2]);
        }
        jobs.set(""+u.id,job); ++jobCounts[job];
        aiTerrainMgr.SetLayoutInt(key,job);
        GenericHelpers::LogUtil("[SEA][Worker] ship="+u.id+" job="+job,1);
    }
    bool SafeApproach(const AIFloat3 &in from, const AIFloat3 &in to) {
        if (!ClearOfEnemies(to)) return false;
        // Follow the cached water graph rather than testing a straight line
        // through an island. The engine still validates the worker MoveDef.
        array<AIFloat3>@ route=aiBattle.GetTerrainRoute(from,to,5,10,1,3,1000000);
        if (route.length()<2) return MapHelpers::SqDist(from,to)<128.0f*128.0f;
        for (uint leg=1;leg<route.length();++leg) {
            const AIFloat3 a=route[leg-1], b=route[leg];
            const int samples=AiMax(1,int(sqrt(MapHelpers::SqDist(a,b))/128.0f)+1);
            for (int i=0;i<=samples;++i) {
                const float fraction=float(i)/samples;
                const AIFloat3 p(a.x+(b.x-a.x)*fraction,0,a.z+(b.z-a.z)*fraction);
                if (!SeaMath::ExpansionThreatSafe(aiBattle.AmphThreat(p),Global::RoleSettings::Sea::ExpansionMaxThreat)) return false;
            }
        }
        return true;
    }
    bool ClearOfEnemies(const AIFloat3 &in p) {
        if (!SeaMath::ExpansionThreatSafe(aiBattle.AmphThreat(p),Global::RoleSettings::Sea::ExpansionMaxThreat)) return false;
        const int count=aiBattle.GetSeaForceCount();
        for (int i=0;i<count;++i) {
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&1)!=0) continue;
            const int defId=aiBattle.GetSeaForceDefId(i);
            const CCircuitDef@ d=defId>0 ? ai.GetCircuitDef(defId) : null;
            if (d !is null && !d.HasSurfToLand() && !d.HasSurfToWater() && !d.HasSubToWater()) continue;
            // Known sonar blips are dangerous too; never query a hidden def.
            const float range=(d is null ? 600.0f : d.GetMaxRange())+Global::RoleSettings::Sea::ExpansionThreatBuffer;
            if (MapHelpers::SqDist(p,aiBattle.GetSeaForcePos(i))<range*range) return false;
        }
        return true;
    }
    bool Escorted(const AIFloat3 &in p) {
        float enemySq=1e30f;
        for (uint i=0;i<enemyStarts.length();++i) enemySq=AiMin(enemySq,MapHelpers::SqDist(p,enemyStarts[i]));
        if (!SeaMath::ExpansionNeedsEscort(MapHelpers::SqDist(p,Global::Map::StartPos),enemySq)) return true;
        const int body=aiBattle.WaterBody(p,false), count=aiBattle.GetSeaForceCount();
        float cover=0;
        for (int i=0;i<count;++i) {
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&1)==0 || (flags&8)!=0 || aiBattle.GetSeaForceBody(i)!=body
                || MapHelpers::SqDist(p,aiBattle.GetSeaForcePos(i))>1000.0f*1000.0f) continue;
            const int defId=aiBattle.GetSeaForceDefId(i);
            const CCircuitDef@ d=defId>0 ? ai.GetCircuitDef(defId) : null;
            if (d !is null && (d.HasSurfToLand() || d.HasSurfToWater() || d.HasSubToWater())) cover+=aiBattle.GetSeaForceCost(i);
        }
        return cover>=Global::RoleSettings::Sea::ExpansionEscortMetal;
    }
    void Tick() {
        if (!Active() || ai.frame-tickFrame<SECOND) return;
        tickFrame=ai.frame; enemyStarts=Lanes::ScriptStarts(true);
        if (!seeded) {
            // One adoption pass covers save/load and a mid-game role switch.
            // Later additions/removals maintain IDs; never retain unit handles.
            array<Id>@ ids=ai.GetOwnedUnitIds();
            for (uint i=0;i<ids.length();++i) Added(ai.GetTeamUnit(ids[i]));
            seeded=true;
        }
        // One shared sea-force snapshot, O(B*C) for B construction ships and C
        // known sea contacts, once a second. No fleet-wide callback census here.
        // Include support ships: native assist can follow a frame into danger.
        // Reassignment occurs only on entering danger; no repeated MOVE micro.
        for (uint i=0;i<ships.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(ships[i]);
            if (u is null || u.GetBuildProgress()<1.0f) continue;
            const string key=""+u.id;
            IUnitTask@ task=u.task;
            if (task !is null && (task.IsEnemyReclaim() || task.IsExternalControlled()
                || task.GetType()==int(Task::Type::PLAYER) || task.GetType()==int(Task::Type::RETREAT))) continue;
            int64 until=0;
            if (withdrawing.get(key,until) && ai.frame<until) continue;
            withdrawing.delete(key);
            if (ClearOfEnemies(u.GetPos(ai.frame))) continue;
            CCircuitUnit@ yard=Factory::primaryT1Shipyard;
            if (yard is null) continue;
            const AIFloat3 safe=yard.GetPos(ai.frame);
            if (!ClearOfEnemies(safe) || !aiTerrainMgr.CanReachAt(u,safe,u.circuitDef.GetBuildDistance())) continue;
            withdrawing.set(key,int64(ai.frame+30*SECOND));
            // AssignTask detaches only this worker; an abandoned frame remains
            // native-owned and recoverable. WAIT(false) preserves this one MOVE.
            aiBuilderMgr.AssignTask(u,aiBuilderMgr.Enqueue(TaskB::Wait(30*SECOND)));
            u.CmdMoveTo(safe);
            GenericHelpers::LogUtil("[SEA][Expansion] withdraw ship="+u.id+" x="+int(safe.x)+" z="+int(safe.z),1);
        }
    }
    void Reset() { retryAt.deleteAll(); blocked.deleteAll(); withdrawing.deleteAll(); fortAfterMex.deleteAll(); forts.resize(0); enemyStarts.resize(0); ships.resize(0); jobs.deleteAll(); for (uint j=0;j<3;++j) jobCounts[j]=0; seeded=false; tickFrame=-100000; }
    void Removed(CCircuitUnit@ u) {
        if (u is null) return;
        const string key=""+u.id;
        const int job=Job(u); if (job>=0) --jobCounts[job];
        jobs.delete(key); aiTerrainMgr.SetLayoutInt("sea.worker."+u.id,-1);
        retryAt.delete(key); blocked.delete(key); withdrawing.delete(key);
        fortAfterMex.delete(key);
        const int index=ships.find(u.id); if (index>=0) ships.removeAt(index);
    }
    IUnitTask@ Fortify(CCircuitUnit@ u) {
        for (int i=int(forts.length())-1;i>=0;--i)
            if (forts[i] is null || forts[i].IsDead()) forts.removeAt(i);
        const AIFloat3 from=u.GetPos(ai.frame);
        const float clusterRadius=Global::RoleSettings::Sea::ExpansionClusterRadius;
        AIFloat3 centre(-1,0,-1); float best=900.0f*900.0f;
        // Read the maintained mex ledger, not another whole-army callback scan.
        // Choose one local anchor before the bounded three-definition coverage
        // queries. Nearby mexes share a defense instead of porcing each spot.
        for (uint i=0;i<Economy::MexTracker::myMexes.length();++i) {
            const AIFloat3 p=Economy::MexTracker::myMexes[i].pos;
            const float sq=MapHelpers::SqDist(from,p);
            if (sq>=best || aiBattle.Height(p)>=0) continue;
            centre=p; best=sq;
        }
        if (centre.x<0 || !SafeApproach(from,centre) || !Escorted(centre)) return null;
        int mexes=0;
        for (uint i=0;i<Economy::MexTracker::myMexes.length();++i)
            if (MapHelpers::SqDist(centre,Economy::MexTracker::myMexes[i].pos)<=clusterRadius*clusterRadius) ++mexes;
        if (mexes<1) return null;
        const string side=UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        const array<string> names={side=="armada" ? "armfrad" : side=="cortex" ? "corfrad" : "legfrad",
            side=="armada" ? "armtl" : side=="cortex" ? "cortl" : "legtl",
            UnitHelpers::GetFloatingAALightNameForSide(side),UnitHelpers::GetFloatingHeavyLaserNameForSide(side)};
        for (uint i=0;i<names.length();++i) {
            if (i==3 && aiEconomyMgr.metal.income<Global::RoleSettings::Sea::ExpansionSurfaceIncome) continue;
            CCircuitDef@ d=ai.GetCircuitDef(names[i]);
            if (d is null || !d.IsAvailable(ai.frame) || !u.circuitDef.CanBuild(d)) continue;
            const float radius=i==0 ? Global::RoleSettings::Sea::ExpansionRadarSpacing : AiMin(clusterRadius,d.GetMaxRange()*.85f);
            if (aiBuilderMgr.FindOwnNear(centre,radius,d) !is null || aiBuilderMgr.FindUnfinishedNear(centre,radius,d) !is null) continue;
            bool pending=false;
            for (uint j=0;j<forts.length();++j) {
                IBuilderTask@ order=cast<IBuilderTask>(forts[j]);
                if (order !is null && order.buildDef is d && MapHelpers::SqDist(order.GetBuildPos(),centre)<=radius*radius) pending=true;
            }
            if (pending) continue;
            if (!SeaMath::ExpansionFortFunded(aiEconomyMgr.metal.current,aiEconomyMgr.metal.income,
                aiEconomyMgr.energy.current,aiEconomyMgr.energy.income,d.costM,d.costE)) continue;
            IUnitTask@ task=aiBuilderMgr.Enqueue(TaskB::Common(i==0 ? Task::BuildType::RADAR : Task::BuildType::DEFENCE,Task::Priority::NORMAL,
                d,centre,128.0f,true,90*SECOND));
            if (task !is null) {
                forts.insertLast(task);
                GenericHelpers::LogUtil("[SEA][Expansion] fort="+d.GetName()+" ship="+u.id+" x="+int(centre.x)+" z="+int(centre.z),1);
                return task;
            }
        }
        return null;
    }
    IUnitTask@ Make(CCircuitUnit@ u) {
        if (!Active() || u is null || !SeaConstructor::IsT1(u.circuitDef)) return null;
        if (u.task !is null && (u.task.IsEnemyReclaim() || u.task.IsExternalControlled()
            || u.task.GetType()==int(Task::Type::PLAYER) || u.task.GetType()==int(Task::Type::RETREAT))) return u.task;
        int64 until=0;
        if (withdrawing.get(""+u.id,until) && ai.frame<until && u.task !is null) return u.task;
        if (!Worker(u)) return null;
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) return current;
        const string key=""+u.id;
        int64 next=0;
        if (retryAt.get(key,next) && ai.frame<next)
            return null; // blocked expansion may use home work throughout the retry window
        blocked.delete(key);
        // Alternate one funded local defense with expansion, rather than
        // waiting until every reachable mex has been exhausted. Current tasks
        // above retain ownership; construction never interrupts a live mex.
        if (fortAfterMex.exists(key)) {
            fortAfterMex.delete(key);
            IUnitTask@ fort=Fortify(u); if (fort !is null) return fort;
        }
        // Failed searches get a short per-worker backoff, not an order limiter.
        // Completion immediately permits the next mex in a cluster.
        retryAt.set(key,int64(ai.frame+Global::RoleSettings::Sea::ExpansionRetrySeconds*SECOND));
        const AIFloat3 from=u.GetPos(ai.frame);
        // Preserve the proven nearby opening before widening the search. Native
        // EnqueueMexWithin adopts pending work before opening a fresh spot, so a
        // single wide query can adopt distant work ahead of unclaimed home mexes.
        // This extra query is only needed while the worker is still near home.
        const AIFloat3 home=Factory::primaryT1Shipyard is null ? Global::Map::StartPos : Factory::primaryT1Shipyard.GetPos(ai.frame);
        IUnitTask@ task=null;
        IBuilderTask@ mex=null;
        array<AIFloat3> excluded;
        const float nearby=Global::RoleSettings::Sea::NearbyMexRadius;
        // D-352: the owned-spot list in value-per-second order is the candidate
        // set first (section 3.6 of the proposal): the yard's own shelf before
        // the far middle of the sea, whatever radius the ship happens to be in.
        // A spot whose enemy clock is earlier than our arrival is still taken,
        // under the same escort and safe-approach admission, after the rest.
        if (Team::MexClaim::Enabled()) {
            array<AIFloat3> owned; array<float> value;
            const int spotCount=ai.GetMetalSpotCount();
            for (int i=0;i<spotCount;++i) {
                const AIFloat3 p=ai.GetMetalSpot(i);
                if (p.x<0 || aiEconomyMgr.MexSpotOwner(p)!=ai.teamId || (aiEconomyMgr.MexTheatre(p)&2)==0) continue;
                float v=aiEconomyMgr.MexSpotValue(p,ai.teamId);
                if (aiEconomyMgr.MexSpotEnemySeconds(p)*SECOND<float(ai.frame)) v*=0.5f;  // contested water after the home shelf
                owned.insertLast(p); value.insertLast(v);
            }
            // insertion sort, descending value; a few dozen spots at most
            for (uint a=1;a<owned.length();++a) { uint b=a; while (b>0 && value[b-1]<value[b]) { const float tv=value[b]; value[b]=value[b-1]; value[b-1]=tv; const AIFloat3 tp=owned[b]; owned[b]=owned[b-1]; owned[b-1]=tp; --b; } }
            int tried=0;
            for (uint i=0;i<owned.length() && tried<Global::RoleSettings::Sea::ExpansionCandidates;++i) {
                @task=aiEconomyMgr.EnqueueMexAvoiding(u,owned[i],SQUARE_SIZE*8,true,excluded);
                @mex=cast<IBuilderTask>(task);
                if (mex is null) continue;
                ++tried;
                const AIFloat3 candidate=mex.GetBuildPos();
                const bool usable=aiEconomyMgr.IsMexTaskUsable(task);
                if (usable && aiTerrainMgr.CanReachAt(u,candidate,u.circuitDef.GetBuildDistance())
                    && SafeApproach(from,candidate) && Escorted(candidate)) break;
                excluded.insertLast(candidate);
                if (mex.target is null && mex.GetUnits().length()==0) aiBuilderMgr.AbortTask(task);
                @mex=null; @task=null;
            }
        }
        // Bounded candidate attempts. Exclusion applies to adoption as well as
        // new spot claims, so an unsafe unfinished mex cannot mask another site.
        // Rejected unassigned tasks are released; another worker's task is not.
        for (int attempt=0;mex is null && attempt<Global::RoleSettings::Sea::ExpansionCandidates;++attempt) {
            if (MapHelpers::SqDist(from,home)<=nearby*nearby)
                @task=aiEconomyMgr.EnqueueMexAvoiding(u,home,nearby,true,excluded);
            if (task is null) @task=aiEconomyMgr.EnqueueMexAvoiding(u,from,Global::RoleSettings::Sea::ExpansionMexRadius,true,excluded);
            @mex=cast<IBuilderTask>(task);
            if (mex is null) break;
            const AIFloat3 candidate=mex.GetBuildPos();
            const bool usable=aiEconomyMgr.IsMexTaskUsable(task);
            if (usable && aiTerrainMgr.CanReachAt(u,candidate,u.circuitDef.GetBuildDistance())
                && SafeApproach(from,candidate) && Escorted(candidate)) break;
            if (!usable) GenericHelpers::LogUtil("[SEA][Expansion] stale mex skipped ship="+u.id+" x="+int(candidate.x)+" z="+int(candidate.z),2);
            excluded.insertLast(candidate);
            if (mex.target is null && mex.GetUnits().length()==0) aiBuilderMgr.AbortTask(task);
            @mex=null; @task=null;
        }
        if (mex is null) {
            IUnitTask@ fort=Fortify(u); if (fort !is null) { retryAt.delete(key); return fort; }
            // No safe expansion job: permit home work during the short retry,
            // rather than making the first constructor permanently WAIT.
            GenericHelpers::LogUtil("[SEA][Expansion] no safe candidate ship="+u.id+" rejected="+excluded.length(),2);
            blocked.set(key,true); return null;
        }
        if (mex.GetBuildType()!=int(Task::BuildType::MEX))
            Invariants::Violation("INV-158",""+u.id,"SEA frontier claim is not a mex task");
        retryAt.delete(key);
        fortAfterMex.set(key,true);
        GenericHelpers::LogUtil("[SEA][Expansion] mex ship="+u.id+" x="+int(mex.GetBuildPos().x)+" z="+int(mex.GetBuildPos().z)
            +" distance="+int(sqrt(MapHelpers::SqDist(from,mex.GetBuildPos()))),1);
        return task;
    }
}
