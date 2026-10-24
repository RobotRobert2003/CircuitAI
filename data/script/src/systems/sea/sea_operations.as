// SEA policy owns objectives; native routes own path traversal and formations.
// O(U + G*E + S*G) policy work per second (hulls U, cohorts G, contacts E,
// utility cohorts S); native snapshot sorting and path searches are separate.
// Expensive path searches occur only on objective changes/expiry. No borrowed
// unit handles survive a callback, and no orders are issued by the census.
#include "sea_submarines.as"
#include "sea_retreat.as"
namespace SeaOperations {
    class Cohort {
        string key;
        int defId=-1, body=-1, created=0, ordered=-100000, target=-999, nativeUntil=0;
        int search=0, retry=0, serial=0, sampleFrame=0, sampleTarget=-1, pursuitStart=0;
        bool released=false;
        bool holdingFireline=false;
        int replacementReleased=-1, replacementSince=-1;
        // D-351: the last route was cut to a leg; the flags to continue it.
        bool legCut=false, legWithdrawing=false, legScout=false, legHold=false, legTransit=false, legCautious=true;
        bool perimeterAdvancing=false;
        bool perimeterAligned=false;
        int avoidUntil=0;
        AIFloat3 avoidCentre;
        int capacity=0;
        int coastSearch=0, coastTarget=-1;
        int reportedSubmarineTarget=-1;
        AIFloat3 coastGoal;
        int repairCheck=-100000;
        bool repairAccess=false;
        float health=1, sampleHealth=1, sampleDistance=0;
        AIFloat3 anchor, samplePos, previousCentre;
        array<int> failedIds, failedUntil;
        array<int> ids;
        AIFloat3 centre, goal;
        CRouteTask@ route;
    }
    array<Cohort@> groups;
    array<AIFloat3> repairSites;
    dictionary byKey, memberGroup;
    int nextSerial=0;
    string Cell(int body, int defId, int x, int z) { return ""+body+":"+defId+":"+x+":"+z; }
    bool Failed(Cohort@ g,int id) {
        for (int i=int(g.failedIds.length())-1;i>=0;--i) {
            if (ai.frame>=g.failedUntil[i]) { g.failedIds.removeAt(i); g.failedUntil.removeAt(i); }
            else if (g.failedIds[i]==id) return true;
        }
        return false;
    }
    void Fail(Cohort@ g,int id) {
        if (id<0 || Failed(g,id)) return;
        if (g.failedIds.length()>=16) { g.failedIds.removeAt(0); g.failedUntil.removeAt(0); }
        g.failedIds.insertLast(id); g.failedUntil.insertLast(ai.frame+Global::RoleSettings::Sea::FleetFailureSeconds*SECOND);
    }
    bool Escort(const CCircuitDef@ d) {
        // Builders (including naval engineers/recovery subs) retain economy
        // ownership. This is the finite ordinary naval sensor/ABM roster.
        const string name=d.GetName();
        return name=="armsjam" || name=="corsjam" || name=="leganavyradjamship"
            || name=="armantiship" || name=="corantiship" || name=="leganavyantinukecarrier"
            || (Global::RoleSettings::Sea::FleetAAEscort && FleetAA(d));
    }
    // D-301: fleet AA sits inside the fleet (meta: Dragonslayer/Arrow Storm/
    // Notus behind the cruiser line, Iapetus 200-300 behind it), not on a
    // home patrol 2400 from the start. Skater/Herring stay scouts.
    bool FleetAA(const CCircuitDef@ d) {
        const string name=d.GetName();
        return name=="armaas" || name=="corarch" || name=="leganavyaaship" || name=="legnavyaaship";
    }
    bool Siege(const CCircuitDef@ d) {
        for (uint i=0;i<SeaCombat::roster.length();++i)
            if (SeaCombat::roster[i].def is d) return SeaCombat::roster[i].siege || d.IsRoleAny(Unit::Role::ARTY.mask);
        return false;
    }
    bool Eligible(CCircuitUnit@ u) {
        if (u is null || u.GetBuildProgress()<1 || !u.circuitDef.IsMobile()
            || u.circuitDef.IsAbleToFly() || u.circuitDef.GetBuildSpeed()>0
            || u.GetRulesParam("carrier_host_unit_id",-1)>=0) return false;
        const CCircuitDef@ d=u.circuitDef;
        if (SeaProtection::Handles(d)) return false;
        if (SeaPatrol::Handles(d)) return false;
        // Explicit roster membership excludes amphibious land. Siege hulls
        // participate only in emergency screening, then regain native artillery.
        bool member=false;
        for (uint i=0;i<SeaCombat::roster.length();++i)
            if (SeaCombat::roster[i].def is d) { member=true; break; }
        if (!Escort(d) && (!member
            || (!d.HasSurfToLand() && !d.HasSubToLand() && !d.HasSurfToWater() && !d.HasSubToWater()))) return false;
        if (u.task is null) return true;
        if (u.task.GetType()==int(Task::Type::PLAYER) || u.task.GetType()==int(Task::Type::RETREAT) || u.task.IsExternalControlled()) return false;
        IFighterTask@ f=cast<IFighterTask>(u.task);
        // Native AA tasks stay native, except the fleet AA escort (D-301).
        if (f !is null && f.GetFightType()==int(Task::FightType::AA)
            && !(Global::RoleSettings::Sea::FleetAAEscort && FleetAA(d))) return false;
        return f !is null;
    }
    void Leave() {
        SeaSubmarines::Reset();
        // Abort returns members through normal manager task selection after
        // role change; do not retain a route or borrowed native unit handle.
        for (uint i=0;i<groups.length();++i)
            if (groups[i].route !is null && !groups[i].route.IsDead()) groups[i].route.Abort();
        groups.resize(0); repairSites.resize(0); byKey.deleteAll(); memberGroup.deleteAll(); nextSerial=0;
    }
    void Census() {
        // Persistent unit->cohort leases avoid reshuffling every second. A
        // spatial bucket index considers nine nearby cells for new/dispersed
        // ships only, not every ship against every group. O(U + G + local joins),
        // with bounded cohort size; dense bucket occupancy is still explicit.
        dictionary cells, nextMembers;
        repairSites.resize(0);
        const float radius=Global::RoleSettings::Sea::FleetCohortRadius;
        for (uint i=0;i<groups.length();++i) {
            Cohort@ g=groups[i]; g.previousCentre=g.centre; g.capacity=int(g.ids.length());
            g.ids.resize(0); g.centre=AIFloat3(0,0,0); g.health=0;
            const string cell=Cell(g.body,g.defId,int(g.previousCentre.x/radius),int(g.previousCentre.z/radius));
            array<int>@ bucket;
            if (!cells.get(cell,@bucket) || bucket is null) { @bucket=array<int>(); cells.set(cell,@bucket); }
            bucket.insertLast(int(i));
        }
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (u !is null && u.GetBuildProgress()>=1 && u.circuitDef.GetBuildSpeed()>0
                && !SeaEconomy::SupportedFactory(u.circuitDef) && !u.circuitDef.IsAbleToFly()
                && !SeaRecovery::Protected(u) && aiBattle.AmphThreat(u.GetPos(ai.frame))<=.1f)
                repairSites.insertLast(u.GetPos(ai.frame));
            if (!Eligible(u)) continue;
            const AIFloat3 p=u.GetPos(ai.frame);
            const int body=aiBattle.WaterBody(p,false); if (body<0) continue;
            const string member=""+u.id; string oldKey;
            int index=-1;
            if (!memberGroup.get(member,oldKey) || !byKey.get(oldKey,index)) index=-1;
            if (index>=0 && (groups[index].body!=body || groups[index].defId!=int(u.circuitDef.id)
                || MapHelpers::SqDist(p,groups[index].previousCentre)>radius*radius*4)) index=-1;
            const int membershipLimit=Global::RoleSettings::Sea::CoordinatedFleet && SeaSubmarines::Handles(u.circuitDef)
                ? AiMax(1,Global::RoleSettings::Sea::SubmarinePerimeterGroupSize) : Global::RoleSettings::Sea::FleetCohortMaximum;
            // Split idle patrols once through the existing lifecycle census.
            // Combat leases stay intact; submarine focus and the surface task
            // force (D-300) share targets across cohorts.
            if (index>=0 && groups[index].target<0 && int(groups[index].ids.length())>=membershipLimit) index=-1;
            bool joining=index<0;
            if (index<0) {
                float best=radius*radius;
                const int cx=int(p.x/radius), cz=int(p.z/radius);
                for (int z=cz-1;z<=cz+1;++z) for (int x=cx-1;x<=cx+1;++x) {
                    array<int>@ bucket;
                    if (!cells.get(Cell(body,u.circuitDef.id,x,z),@bucket) || bucket is null) continue;
                    for (uint j=0;j<bucket.length();++j) {
                        Cohort@ candidate=groups[bucket[j]];
                        const float dist=MapHelpers::SqDist(p,candidate.previousCentre);
                        const bool settled=candidate.route is null || candidate.route.IsDead() || dist<radius*radius*.16f;
                        if (!candidate.holdingFireline && dist<best && SeaMath::JoinCohort(dist,radius,candidate.capacity,
                            membershipLimit,candidate.released,settled)) { index=bucket[j]; best=dist; }
                    }
                }
            }
            if (index<0) {
                index=int(groups.length()); Cohort@ g=Cohort();
                g.serial=++nextSerial; g.key=""+g.serial; g.defId=u.circuitDef.id; g.body=body;
                g.created=ai.frame; g.previousCentre=p; g.anchor=p;
                groups.insertLast(g);
                const string cell=Cell(body,g.defId,int(p.x/radius),int(p.z/radius));
                array<int>@ bucket;
                if (!cells.get(cell,@bucket) || bucket is null) { @bucket=array<int>(); cells.set(cell,@bucket); }
                bucket.insertLast(index);
            }
            Cohort@ g=groups[index];
            if (joining) { ++g.capacity; g.perimeterAligned=false; }
            g.ids.insertLast(u.id); nextMembers.set(member,g.key);
            g.centre.x+=p.x; g.centre.z+=p.z; g.health+=u.GetHealthPercent();
        }
        for (int i=int(groups.length())-1;i>=0;--i)
            if (groups[i].ids.length()==0 && groups[i].route !is null && !groups[i].route.IsDead()) groups[i].route.Abort();
        uint live=0; byKey.deleteAll();
        for (uint i=0;i<groups.length();++i) {
            Cohort@ g=groups[i]; if (g.ids.length()==0) continue;
            const float count=float(g.ids.length()); g.centre.x/=count; g.centre.z/=count; g.health/=count;
            @groups[live]=g; byKey.set(g.key,int(live)); ++live;
        }
        groups.resize(live); memberGroup=nextMembers;
    }
    AIFloat3 Search(Cohort@ g) {
        // Different scouts sweep different bearings. Destinations are advisory
        // known start geometry, not omniscient enemy unit positions.
        array<AIFloat3>@ starts=Spam::EnemyStartSpots();
        AIFloat3 anchor=Spam::_MirrorOfStart();
        const AIFloat3 home=Global::Map::StartPos;
        float fx=anchor.x-home.x, fz=anchor.z-home.z;
        const float bearing=atan2(fz,fx);
        float best=1e30f;
        for (uint i=0;i<starts.length();++i) {
            // Unoccupied configured starts can still be on our half of the
            // map (especially small fixtures). Scout forward, not the nearest
            // unused allied-side spawn, while treating starts as hypotheses.
            if ((starts[i].x-home.x)*fx+(starts[i].z-home.z)*fz<=0) continue;
            const float dist=MapHelpers::SqDist(g.centre,starts[i]);
            if (dist<best) { best=dist; anchor=starts[i]; }
        }
        const float angle=bearing+float((g.ids[0]+g.search)%5-2)*.3f;
        const float ring=384.0f+float((g.search/8)%3)*384.0f;
        AIFloat3 p(anchor.x+cos(angle)*ring,0,anchor.z+sin(angle)*ring);
        p=Spam::_Clamp(p);
        if (aiBattle.WaterBody(p,false)==g.body) return p;
        // A land start does not justify a ship climbing a beach. Explore local
        // water in increasing rings when the enemy start is not navigable.
        p=Spam::_Clamp(AIFloat3(g.centre.x+cos(angle)*1200,0,g.centre.z+sin(angle)*1200));
        return aiBattle.WaterBody(p,false)==g.body ? p : g.centre;
    }
    int FormationColumns(const CCircuitDef@ definition) {
        if (Global::RoleSettings::Sea::CoordinatedFleet && SeaSubmarines::Handles(definition))
            return AiMax(1,Global::RoleSettings::Sea::FleetCohortMaximum);
        return AiMin(12,AiMax(3,int(definition.GetMaxRange()*.9f/Global::RoleSettings::Sea::FleetLaneSpacing)));
    }
    // D-300 surface task force. Cohorts stay per hull (formation lanes, ASW
    // slots, fireline and siege owners need one definition); the task force
    // only shares an objective. One O(G) pass per Tick builds one lead per
    // water body; followers read it in O(1). Rebuilt every Tick from the
    // previous objectives, so no lifetime beyond one census.
    class TaskForce { int lead=-1, target=-1, ships=0; float value=0; AIFloat3 centre, goal; }
    dictionary taskForces;
    bool SurfaceCombat(Cohort@ g) {
        const CCircuitDef@ d=ai.GetCircuitDef(g.defId);
        return d !is null && !SeaSubmarines::Handles(d) && !SeaSubmarines::HoldsFireline(d) && !Siege(d) && !Escort(d)
            && !d.IsRoleAny(Unit::Role::SCOUT.mask) && d.HasSurfToLand();
    }
    void BuildTaskForces() {
        taskForces.deleteAll();
        if (!Global::RoleSettings::Sea::SurfaceTaskForce) return;
        for (uint i=0;i<groups.length();++i) {
            Cohort@ g=groups[i];
            if (g.ids.length()==0 || !SurfaceCombat(g)) continue;
            const string key=""+g.body;
            TaskForce@ force;
            if (!taskForces.get(key,@force) || force is null) { @force=TaskForce(); taskForces.set(key,@force); }
            force.ships+=int(g.ids.length());
            // Lead: a released cohort with a real target, most metal first,
            // then the lower serial (deterministic). Withdrawal/bait states
            // (-2, -5, -6) never lead.
            if (!g.released || g.target<0) continue;
            const float value=ai.GetCircuitDef(g.defId).costM*float(g.ids.length());
            if (value>force.value || (value==force.value && force.lead>=0 && g.serial<force.lead)) {
                force.value=value; force.lead=g.serial; force.target=g.target; force.centre=g.centre; force.goal=g.goal;
            }
        }
    }
    TaskForce@ Follows(Cohort@ g) {
        if (!Global::RoleSettings::Sea::SurfaceTaskForce || !SurfaceCombat(g)) return null;
        TaskForce@ force;
        if (!taskForces.get(""+g.body,@force) || force is null || force.lead<0 || force.lead==g.serial) return null;
        const float radius=Global::RoleSettings::Sea::TaskForceRadius;
        return MapHelpers::SqDist(g.centre,force.centre)<=radius*radius ? force : null;
    }
    int TaskForceShips(Cohort@ g) {
        if (!Global::RoleSettings::Sea::SurfaceTaskForce || !SurfaceCombat(g)) return int(g.ids.length());
        TaskForce@ force;
        if (!taskForces.get(""+g.body,@force) || force is null) return int(g.ids.length());
        return AiMax(int(g.ids.length()),force.ships);
    }
    bool Route(Cohort@ g, const AIFloat3 &in goal, bool withdrawing, bool scout, bool hold=false, bool transit=false, bool cautious=true) {
        CCircuitUnit@ lead=ai.GetTeamUnit(g.ids[0]); if (lead is null) return false;
        // GetUnitTerrainRoute is explicitly a ground/amphibious MoveDef API.
        // The naval lane graph supplies water waypoints; the engine executes
        // each segment with the ship's actual MoveDef and native offsets are
        // checked against its movement area. Do not route ships via AMPH.
        array<AIFloat3>@ points=aiBattle.GetTerrainRoute(g.centre,goal,5,10,1,3,1000000);
        if (points.length()<2) {
            if (!withdrawing) return false;
            // Failed escape must still cancel the old advance. A zero-length
            // MOVE at the current legal position is a hold, not a fabricated
            // path through terrain. The next threat census can choose again.
            points.resize(0); points.insertLast(g.centre);
        }
        // The intended destination, before any leg cut (g.goal; objective
        // comparisons use it, so a cut leg does not look like a moved goal).
        const AIFloat3 intent=points[points.length()-1];
        g.legCut=false;
        g.legWithdrawing=withdrawing; g.legScout=scout; g.legHold=hold; g.legTransit=transit; g.legCautious=cautious;
        // D-351: a submarine route is issued one leg at a time. A full route
        // across the map was 100+ MOVEs per sub, replaced whenever the target
        // changed (owner's lag report, Glacial 8v8: queues of 164-173 points).
        // Unseen cautious transit keeps the shorter SubmarineAdvanceStep; every
        // other submarine route (chase, station, perimeter, line) gets
        // SubmarineLegLength. ContinueLeg issues the next leg when this one is
        // walked. Surface routes use FleetLegLength (0 = whole route).
        float maximum=0;
        if (SeaSubmarines::Handles(lead.circuitDef)) {
            const bool unseen=Global::RoleSettings::Sea::CoordinatedFleet && cautious && transit && !withdrawing && !aiTerrainMgr.IsAreaVisible(goal,128);
            maximum=unseen ? AiMax(128.0f,Global::RoleSettings::Sea::SubmarineAdvanceStep) : Global::RoleSettings::Sea::SubmarineLegLength;
        } else maximum=Global::RoleSettings::Sea::FleetLegLength;
        if (maximum>0) {
            float travelled=0; AIFloat3 previous=g.centre;
            for (uint point=0;point<points.length();++point) {
                const float length=sqrt(MapHelpers::SqDist(previous,points[point]));
                if (travelled+length>maximum && length>0) {
                    points[point]=previous+(points[point]-previous)*((maximum-travelled)/length);
                    points.resize(point+1); g.legCut=true; break;
                }
                travelled+=length; previous=points[point];
            }
        }
        if (g.route is null || g.route.IsDead()) {
            @g.route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (g.route is null) return false;
            g.route.SetSeaControl(true);
            g.route.SetCombatRetreat(!SeaSubmarines::HoldsFireline(lead.circuitDef));
            // Fixed per hull type, not the number present on its first tick.
            // A one-ship assembly route must not lock future recruits into a
            // single column. Width leaves room to share one useful firing band.
            const int columns=FormationColumns(lead.circuitDef);
            g.route.SetLanes(columns,SeaSubmarines::Handles(lead.circuitDef) && Global::RoleSettings::Sea::CoordinatedFleet
                ? Global::RoleSettings::Sea::SubmarineLineSpacing : Global::RoleSettings::Sea::FleetLaneSpacing,1.0f);
            g.route.SetRowSpacing(Global::RoleSettings::Sea::FleetRowSpacing);
        }
        // MOVE for scouting/withdrawal prevents engine FIGHT from chasing a
        // contact into the very sub field that caused the withdrawal.
        // A previous invasion screen may have requested HOLD. Other goals
        // retain their original movement state when that screen is interrupted.
        // SEA movement owns pursuit. HOLD permits weapons to fire but forbids
        // engine auto-chase; priority fire is separate from the MOVE queue.
        g.route.SetHoldPosition(true);
        // Engine goal-radius/steering can change even on a collinear path, so
        // a close targeted approach (transit=false with a target: cautious is
        // false only there) keeps every waypoint for firing adjustments.
        // D-340: every other route is untargeted (withdrawal, hold, screen,
        // escort, assembly, coast, perimeter). Native compaction only merges
        // collinear per-hull legs whose footprint corridor is clear, so these
        // keep their geometry; the 2026-10-19 Supreme replay showed 66-75% of
        // their 64-elmo waypoints were collinear (KI-583). Cost: one native
        // O(waypoints x footprint) clearance pass per dispatch, which replaces
        // as many engine MOVE commands. CompactUntargetedRoutes=false restores
        // the D-243 transit-only gate.
        const bool closeApproach=!transit && !cautious;
        g.route.SetMoveCompaction(Global::RoleSettings::Sea::CompactMoveRoutes
            && (Global::RoleSettings::Sea::CompactUntargetedRoutes ? !closeApproach
                : transit && !withdrawing && (!hold || !cautious)));
        RepairPolicy(g);
        g.route.SetTraversal(true,64,false);
        g.route.SetRoute(points);
        g.perimeterAligned=false; // SetRoute clears the per-member shoreline overrides.
        for (uint i=0;i<g.ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(g.ids[i]); if (!Eligible(u) || u.task is g.route) continue;
            if (!aiMilitaryMgr.TransferUnit(u,g.route))
                Invariants::Violation("INV-145",""+u.id,"SEA route handover failed");
        }
        g.goal=intent; g.ordered=ai.frame;
        return true;
    }
    array<AIFloat3> coverPos; array<float> coverReach;
    // KI-611: drone carriers (BAR carried_unit = legdrone). Definition IDs are
    // resolved once; the per-contact test is O(list) over a handful of IDs.
    array<int> carrierIds; bool carriersResolved=false;
    bool DroneCarrier(int defId) {
        if (!carriersResolved) {
            carriersResolved=true;
            for (uint k=0;k<Global::RoleSettings::Sea::DroneCarrierHulls.length();++k) {
                CCircuitDef@ d=ai.GetCircuitDef(Global::RoleSettings::Sea::DroneCarrierHulls[k]);
                if (d !is null) carrierIds.insertLast(d.id);
            }
        }
        return carrierIds.find(defId)>=0;
    }
    // True when a gathered armed ground contact other than the target itself
    // reaches p (the target's own reach already sets the station radius).
    bool CoveredByGround(const AIFloat3 &in p,const AIFloat3 &in target) {
        for (uint k=0;k<coverPos.length();++k) {
            if (MapHelpers::SqDist(coverPos[k],target)<1.0f) continue;
            if (MapHelpers::SqDist(coverPos[k],p)<coverReach[k]) return true;
        }
        return false;
    }
    bool Coast(Cohort@ g, const CCircuitDef@ def, bool reserve) {
        // Known reachable coastal targets need not wait for whole-sea survey
        // completion. Water contacts and landing-site protection still preempt
        // this branch; each station must lie outside observed weapon coverage.
        if ((!Global::RoleSettings::Sea::FleetAttackKnownBases && (reserve || !SeaInvasion::secured || SeaInvasion::body!=g.body))
            || !(def.HasSurfToLand() || def.HasSubToLand())) return false;
        if (ai.frame>=g.coastSearch) {
            g.coastSearch=ai.frame+10*SECOND; g.coastTarget=-1;
            float best=-1;
            CCircuitUnit@ lead=ai.GetTeamUnit(g.ids[0]);
            const float range=def.GetMaxRange(1)*.85f;
            // Head-to-head play (s30): stations beside the target sat inside a
            // neighbouring shore unit's reach (leginc, 725) and SurfThreat did
            // not reject them. Gather every armed ground contact's reach once
            // per search: O(contacts) here, O(8 x targets x armed) below,
            // every 10 s per coast cohort; arrays reused per cohort search.
            coverPos.resize(0); coverReach.resize(0);
            const float gatherSq=(4000.0f+1200.0f)*(4000.0f+1200.0f);
            for (int i=0;i<aiBattle.GetGroundContactCount();++i) {
                CCircuitDef@ shooter=ai.GetCircuitDef(aiBattle.GetGroundContactDefId(i));
                if (shooter is null || shooter.IsAbleToFly() || !shooter.HasSurfToLand()) continue;
                const AIFloat3 q=aiBattle.GetGroundContactPos(i);
                if (MapHelpers::SqDist(q,g.centre)>gatherSq) continue;
                const float reach=AiMax(shooter.GetMaxRange(1),UnitHelpers::IsCommander(shooter) ? Global::RoleSettings::Sea::CoastCommanderReach : 0.0f)
                    +Global::RoleSettings::Sea::CoastStandoffMargin;
                coverPos.insertLast(q); coverReach.insertLast(reach*reach);
            }
            for (int i=0;i<aiBattle.GetGroundContactCount();++i) {
                const int id=aiBattle.GetGroundContactId(i);
                if (Failed(g,id)) continue;
                CCircuitDef@ enemy=ai.GetCircuitDef(aiBattle.GetGroundContactDefId(i));
                if (enemy is null || enemy.IsAbleToFly()) continue;
                // D-301 (played vs stock BARb): ships doing coast support died
                // mostly to the enemy commander and shore turrets they could not
                // outrange. Bombard only what the station outranges; a commander
                // also gets its D-gun reach (CoastCommanderReach).
                const float enemyReach=AiMax(enemy.GetMaxRange(1),UnitHelpers::IsCommander(enemy) ? Global::RoleSettings::Sea::CoastCommanderReach : 0.0f)
                    +Global::RoleSettings::Sea::CoastStandoffMargin;
                // Head-to-head play: discarding every target the 0.85 station
                // could not outrange removed most shore kills. Stand just
                // outside the target's reach when our own range allows it.
                const float station=AiMax(range,enemyReach);
                if (station>def.GetMaxRange(1)*.98f) continue;
                const AIFloat3 target=aiBattle.GetGroundContactPos(i);
                if (MapHelpers::SqDist(target,g.centre)>4000.0f*4000.0f) continue;
                // Eight bounded shoreline candidates, movement-area checked.
                // Full path search is deferred until the chosen intent changes.
                for (int j=0;j<8;++j) {
                    const float angle=float(j)*.78539816f;
                    const AIFloat3 p=Spam::_Clamp(AIFloat3(target.x+cos(angle)*station,0,target.z+sin(angle)*station));
                    if (aiBattle.WaterBody(p,false)!=g.body || aiBattle.SurfThreat(p)>.1f
                        || !aiTerrainMgr.CanReachAt(lead,p,64)) continue;
                    if (Global::RoleSettings::Sea::CoastAllCover && CoveredByGround(p,target)) continue;
                    const float score=(aiBattle.IsGroundContactEconomy(i) ? 3000.0f : 1800.0f)
                        /(1.0f+sqrt(MapHelpers::SqDist(g.centre,p))/1600.0f+aiBattle.SurfThreat(p));
                    if (score>best) { best=score; g.coastTarget=id; g.coastGoal=p; }
                }
            }
        }
        if (g.coastTarget<0) return false;
        if (SeaMath::NewObjective(g.target,g.coastTarget,MapHelpers::SqDist(g.goal,g.coastGoal),ai.frame-g.ordered,30*SECOND)) {
            if (!Route(g,g.coastGoal,false,false,true)) { Fail(g,g.coastTarget); g.coastTarget=-1; return false; }
            g.target=g.coastTarget;
            GenericHelpers::LogUtil("[SEA][CoastSupport] cohort="+g.serial+" target="+g.target
                +" x="+int(g.coastGoal.x)+" z="+int(g.coastGoal.z),1);
        }
        if (g.route !is null) g.route.SetNavalTarget(g.coastTarget);
        return true;
    }
    void AntiSubFormation(Cohort@ g,const AIFloat3 &in target) {
        const CCircuitDef@ d=ai.GetCircuitDef(g.defId);
        const string name=d.GetName();
        // These surfaced ASW hulls must use depth-charge/torpedo range, not
        // the 700-elmo surface cannon. Legion destroyers have no ASW weapon.
        // D-301: the T2 cruisers carry depth charges too (450).
        if (g.route is null || (name!="armroy" && name!="corroy" && name!="legnavyfrigate"
            && name!="armcrus" && name!="corcrus" && name!="leganavycruiser")) return;
        // Legion's 460-range torpedo exceeds its 400-radius own sonar. Its
        // script lever retains self-detection when the forward sonar is lost;
        // Armada/Cortex destroyers can use their normal firing margin.
        const float range=d.GetMaxRange(2)*(name=="legnavyfrigate"
            ? Global::RoleSettings::Sea::AntiSubFrigateRangeFraction : Global::RoleSettings::Sea::AntiSubRangeFraction);
        if (range<=0 || MapHelpers::SqDist(g.centre,target)>(range+600)*(range+600)) return;
        const float bearing=atan2(g.centre.z-target.z,g.centre.x-target.x);
        // Do not squeeze a large cohort into overlapping arc slots. Its native
        // spaced rows remain preferable when one firing band cannot hold it.
        if (g.ids.length()>1 && 2*range*sin(Global::RoleSettings::Sea::AntiSubArcRadians/(2*float(g.ids.length()-1)))
            <Global::RoleSettings::Sea::FleetLaneSpacing) return;
        array<int> ordered=g.ids;
        array<float> lateral(ordered.length());
        const float tx=-sin(bearing),tz=cos(bearing);
        for (uint i=0;i<ordered.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(ordered[i]);
            const AIFloat3 p=u is null ? g.centre : u.GetPos(ai.frame);
            lateral[i]=(p.x-target.x)*tx+(p.z-target.z)*tz;
        }
        // Stable spatial order prevents routes crossing through neighboring
        // hulls. Insertion sort is bounded by FleetCohortMaximum (24), and runs
        // only on a new combat intent; endpoints are then O(cohort size).
        for (uint i=1;i<ordered.length();++i) {
            const int id=ordered[i]; const float rank=lateral[i]; uint j=i;
            while (j>0 && (lateral[j-1]>rank || (lateral[j-1]==rank && ordered[j-1]>id))) {
                lateral[j]=lateral[j-1]; ordered[j]=ordered[j-1]; --j;
            }
            lateral[j]=rank; ordered[j]=id;
        }
        // A concave line puts every member inside the same firing band. Invalid coast
        // slots retain the native, movement-area-tested formation, never stack
        // all ships on one forced destination. No per-frame MOVE micro.
        for (uint i=0;i<ordered.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(ordered[i]); if (u is null || u.task !is g.route) continue;
            const float angle=bearing+SeaMath::AntiSubAngle(int(i),int(ordered.length()),Global::RoleSettings::Sea::AntiSubArcRadians);
            const AIFloat3 p=Spam::_Clamp(AIFloat3(target.x+cos(angle)*range,0,target.z+sin(angle)*range));
            if (aiBattle.WaterBody(p,false)!=g.body || !aiTerrainMgr.CanMoveTo(u,p)) continue;
            array<AIFloat3> points={u.GetPos(ai.frame),p};
            if (!g.route.SetUnitRoute(u,points,32)) Invariants::Violation("INV-179",""+u.id,"SEA ASW formation route rejected");
        }
        GenericHelpers::LogUtil("[SEA][ASWFormation] cohort="+g.serial+" n="+g.ids.length()+" range="+range,1);
    }
    bool RepairApproachSafe(const AIFloat3 &in from,const AIFloat3 &in haven) {
        if (!SeaExpansion::ClearOfEnemies(haven)) return false;
        array<AIFloat3>@ route=aiBattle.GetTerrainRoute(from,haven,5,10,1,3,1000000);
        if (route.length()<2) return MapHelpers::SqDist(from,haven)<128.0f*128.0f;
        // Retreat starts under fire. The builder's zero-threat approach rule
        // would reject that first sample and disable early repair every time.
        // Admit escape through no worse exposure into a clear destination;
        // do not grant permission to cross a stronger defensive line.
        const float ceiling=AiMax(.1f,aiBattle.AmphThreat(from));
        for (uint leg=1;leg<route.length();++leg) {
            const AIFloat3 a=route[leg-1], b=route[leg];
            const int samples=AiMax(1,int(sqrt(MapHelpers::SqDist(a,b))/128.0f)+1);
            for (int i=0;i<=samples;++i) {
                const float fraction=float(i)/samples;
                if (aiBattle.AmphThreat(AIFloat3(a.x+(b.x-a.x)*fraction,0,a.z+(b.z-a.z)*fraction))>ceiling) return false;
            }
        }
        return true;
    }
    // D-351: a cut leg has been walked and the destination is still ahead:
    // issue the next leg with the same flags. One IsAtEnd query per cohort
    // per census; the route itself is the same cached native search.
    bool ContinueLeg(Cohort@ g) {
        if (!g.legCut || g.route is null || g.route.IsDead()) return false;
        CCircuitUnit@ lead=ai.GetTeamUnit(g.ids[0]);
        if (lead is null || !g.route.IsAtEnd(lead)) return false;
        if (MapHelpers::SqDist(g.centre,g.goal)<=256.0f*256.0f) { g.legCut=false; return false; }
        const int target=g.target;
        if (Route(g,g.goal,g.legWithdrawing,g.legScout,g.legHold,g.legTransit,g.legCautious)) {
            g.target=target; // Route keeps the objective; only the queue is new
            return true;
        }
        return false;
    }
    void RepairPolicy(Cohort@ g) {
        if (g.route is null || g.route.IsDead()) return;
        if (SeaSubmarines::HoldsFireline(ai.GetCircuitDef(g.defId))) {
            g.route.SetCombatRetreat(false);
            g.route.SetRepairThreshold(0);
            return;
        }
        if (ai.frame-g.repairCheck>=15*SECOND) {
            g.repairCheck=ai.frame; g.repairAccess=false;
            CCircuitUnit@ lead=ai.GetTeamUnit(g.ids[0]);
            float best=1600.0f*1600.0f; AIFloat3 haven;
            for (uint i=0;i<repairSites.length();++i) {
                const float distance=MapHelpers::SqDist(g.centre,repairSites[i]);
                if (distance<best && aiTerrainMgr.CanReachAt(lead,repairSites[i],128)) {
                    best=distance; haven=repairSites[i]; g.repairAccess=true;
                }
            }
            // One terrain/threat route test per cohort per 15 seconds, not
            // a worker path search for every damaged ship on every hit.
            if (g.repairAccess) g.repairAccess=RepairApproachSafe(g.centre,haven);
        }
        const float elapsed=AiMax(1.0f,float(ai.frame-g.sampleFrame)/SECOND);
        const float lossRate=AiMax(0.0f,g.sampleHealth-g.health)/elapsed;
        // Allow a short exit under the recently observed damage rate. Native
        // retreat retains destination/path/repair ownership. Without safe
        // repair access, reserve withdrawal for critically damaged hulls.
        // D-346: with forward repair a damaged ship heals just outside enemy
        // reach, so it may withdraw without a reachable repair site.
        const bool canWithdraw=g.repairAccess || Global::RoleSettings::Sea::ForwardRepair;
        const float threshold=canWithdraw ? AiMin(.7f,Global::RoleSettings::Sea::FleetRepairHealth+lossRate*4) : .2f;
        g.route.SetRepairThreshold(threshold);
    }
    // Diagnostic (2026-10-19, sub response review): once a minute, where the
    // combat ships are and what they are doing. Per kind (sub/surface): ships
    // near home (HomeRadius of the start), ships not in any cohort, retreating
    // ships, and cohort target codes for ships near home. O(ships + cohort
    // members) once a minute; no orders.
    int stateLog=0;
    int routeBudget=0, routeOffset=0;
    // D-348: merge small cohorts of one hull chasing the same live target in
    // one body (within ChaseMergeRadius) up to FleetCohortMaximum, so one
    // route order serves the whole pack. O(groups) with a dictionary keyed by
    // body, hull and target. New members are transferred once by the census.
    void MergeChasing() {
        if (!Global::RoleSettings::Sea::MergeChasingCohorts) return;
        dictionary leaders;
        const float radius=Global::RoleSettings::Sea::ChaseMergeRadius;
        const uint maximum=uint(AiMax(1,Global::RoleSettings::Sea::FleetCohortMaximum));
        for (uint i=0;i<groups.length();++i) {
            Cohort@ g=groups[i];
            if (g.ids.length()==0 || g.target<0 || g.route is null || g.route.IsDead()) continue;
            const string key=""+g.body+":"+g.defId+":"+g.target;
            int64 index=-1;
            if (!leaders.get(key,index) || index<0) { leaders.set(key,int64(i)); continue; }
            Cohort@ lead=groups[uint(index)];
            if (lead.ids.length()+g.ids.length()>maximum || MapHelpers::SqDist(lead.centre,g.centre)>radius*radius) {
                if (g.ids.length()>lead.ids.length()) leaders.set(key,int64(i));
                continue;
            }
            for (uint m=0;m<g.ids.length();++m) {
                lead.ids.insertLast(g.ids[m]);
                memberGroup.set(""+g.ids[m],lead.key);
            }
            g.ids.resize(0);
        }
    }
    void LogState() {
        if (ai.frame<stateLog) return;
        stateLog=ai.frame+60*SECOND;
        dictionary targetOf;
        for (uint k=0;k<groups.length();++k)
            for (uint j=0;j<groups[k].ids.length();++j) targetOf.set(""+groups[k].ids[j],int64(groups[k].target));
        const float home=Global::RoleSettings::Sea::DiagnosticHomeRadius;
        array<int> total={0,0}, nearHome={0,0}, loose={0,0}, retreat={0,0};
        array<string> codes={"",""};
        dictionary homeCodes;
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (u is null || !u.circuitDef.IsMobile() || u.circuitDef.IsAbleToFly() || u.circuitDef.GetBuildSpeed()>0) continue;
            const int kind=SeaSubmarines::Handles(u.circuitDef) ? 0 : 1;
            ++total[kind];
            const bool atHome=MapHelpers::SqDist(u.GetPos(ai.frame),Global::Map::StartPos)<home*home;
            if (atHome) ++nearHome[kind];
            if (u.task !is null && u.task.GetType()==int(Task::Type::RETREAT)) { ++retreat[kind]; continue; }
            int64 target=-999;
            if (!targetOf.get(""+u.id,target)) { ++loose[kind]; target=-1000; }
            if (atHome) {
                const string key=(kind==0 ? "sub" : "surf")+":"+target;
                homeCodes.set(key,DictIntOr(homeCodes,key)+1);
            }
        }
        string atHomeCodes="";
        array<string>@ keys=homeCodes.getKeys();
        for (uint i=0;i<keys.length();++i) atHomeCodes+=" "+keys[i]+"="+DictIntOr(homeCodes,keys[i]);
        // Sub cohorts at home that never received an objective: why.
        for (uint k=0;k<groups.length();++k) {
            Cohort@ g=groups[k];
            if (g.ids.length()==0 || g.target!=-999 || !SeaSubmarines::Handles(ai.GetCircuitDef(g.defId))) continue;
            if (MapHelpers::SqDist(g.centre,Global::Map::StartPos)>home*home) continue;
            GenericHelpers::LogUtil("[SEA][StateIdle] cohort="+g.serial+" n="+g.ids.length()+" released="+g.released
                +" route="+(g.route !is null && !g.route.IsDead())+" retryIn="+(g.retry-ai.frame)/SECOND
                +" age="+(ai.frame-g.created)/SECOND+" fireline="+g.holdingFireline+" replacement="+g.replacementReleased
                +" search="+g.search+" coast="+g.coastTarget,1);
        }
        GenericHelpers::LogUtil("[SEA][State] subs="+total[0]+" home="+nearHome[0]+" loose="+loose[0]+" retreat="+retreat[0]
            +" surface="+total[1]+" home="+nearHome[1]+" loose="+loose[1]+" retreat="+retreat[1]
            +" repairPoints="+SeaRetreat::repairEntries.length()+" repairRetreating="+SeaRetreat::RetreatingToPoint()
            +" homeTargets="+atHomeCodes,1);
    }
    void Tick() {
        if (!SeaCombat::Active() || !Global::RoleSettings::Sea::FleetOperations) return;
        Census();
        LogState();
        if (Global::RoleSettings::Sea::CoordinatedFleet) SeaSubmarines::MergeSettled();
        MergeChasing();
        if (Global::RoleSettings::Sea::CoordinatedFleet) SeaRetreat::Publish();
        SeaSubmarines::BeginDecisions();
        SeaSubmarines::PrepareReplacements();
        dictionary reserves;
        // One pass rather than an extra fleet scan for every coastal mission.
        for (uint i=0;i<groups.length();++i) {
            const CCircuitDef@ hull=ai.GetCircuitDef(groups[i].defId);
            if (Escort(hull) || Siege(hull) || !(hull.HasSurfToLand() || hull.HasSubToLand())) continue;
            const string bodyKey=""+groups[i].body;
            if (!reserves.exists(bodyKey)) reserves.set(bodyKey,groups[i].serial);
        }
        BuildTaskForces();
        const int contacts=aiBattle.GetSeaForceCount(); // legal SEA extension; AIR snapshot unchanged
        int reroutes=0; // working-copy same-target cap; the rotating total-route budget also remains
        // D-348: at most FleetRoutesPerTick combat re-routes per census, and the
        // loop starts at a rotating offset so the budget never starves the same
        // groups. Skipped groups are reconsidered on the next census (1 s).
        routeBudget=Global::RoleSettings::Sea::FleetRoutesPerTick;
        const uint groupCount=groups.length();
        const uint groupOffset=groupCount>0 ? uint(routeOffset++)%groupCount : 0;
        for (uint visit=0;visit<groupCount;++visit) {
            const uint k=(visit+groupOffset)%groupCount;
            Cohort@ g=groups[k]; if (g.ids.length()==0) continue;
            if (int(g.ids.length())>Global::RoleSettings::Sea::FleetCohortMaximum)
                Invariants::Violation("INV-171",g.key,"SEA local cohort exceeded configured capacity");
            // Joining a settled line need not change its objective. Transfer
            // only new members here, otherwise they could inherit a released
            // cohort's ID while retaining a native attack/idle task forever.
            if (g.route !is null && !g.route.IsDead()) for (uint j=0;j<g.ids.length();++j) {
                CCircuitUnit@ recruit=ai.GetTeamUnit(g.ids[j]);
                if (Eligible(recruit) && recruit.task !is g.route && !aiMilitaryMgr.TransferUnit(recruit,g.route))
                    Invariants::Violation("INV-145",""+recruit.id,"SEA reinforcement handover failed");
            }
            RepairPolicy(g);
            if (ContinueLeg(g)) continue;
            CCircuitDef@ def=ai.GetCircuitDef(g.defId);
            const bool scout=def.IsRoleAny(Unit::Role::SCOUT.mask);
            const bool siege=Siege(def);
            const bool subWeapon=def.HasSurfToWater() || def.HasSubToWater();
            const bool submarine=SeaSubmarines::Handles(def);
            const bool fireline=SeaSubmarines::HoldsFireline(def);
            TaskForce@ force=Follows(g);
            // Submarines prefer the flagship focus; surface followers prefer
            // the task force lead's target, if it passes their own filters.
            const int preferredFlagship=submarine && Global::RoleSettings::Sea::CoordinatedFleet ? SeaSubmarines::Preferred(g)
                : force !is null ? force.target : -1;
            int bestTargetRank=-1;
            float nearest=1e30f, enemySubs=0, cover=0, bestScore=-1, enemyCost=0, localEnemy=0, localAlly=0;
            CCircuitDef@ targetDef=null; int targetFlags=0;
            bool scoutExposed=false;
            // D-341: armed enemy hovers in the screen radius, and whether one is
            // inside this hull's evade reach. Decided after the pass, against
            // the cohort's local strength, so one hover cannot move a fleet.
            float hoverPower=0; bool hoverExposed=false;
            bool combatContact=false;
            int target=-1; bool targetSub=false, targetUrgent=false;
            AIFloat3 goal=g.centre, targetPosition=g.centre;
            const float radius=Global::RoleSettings::Sea::FleetScreenRadius;
            const bool hoverBlind=Global::RoleSettings::Sea::HoverBlindHulls.find(def.GetName())>=0;
            // KI-611: hulls that cannot out-trade a hover step away from one;
            // gun hulls that outrange it kite instead (HoverKite below).
            const bool hoverEvade=Global::RoleSettings::Sea::HoverEvade && !scout && !submarine;
            for (int i=0;i<contacts;++i) {
                if (aiBattle.GetSeaForceBody(i)!=g.body) continue;
                const int flags=aiBattle.GetSeaForceFlags(i);
                const AIFloat3 p=aiBattle.GetSeaForcePos(i);
                const float dist=MapHelpers::SqDist(g.centre,p);
                if ((flags&1)!=0) {
                    const int allyId=aiBattle.GetSeaForceDefId(i);
                    const CCircuitDef@ friendly=allyId>=0 ? ai.GetCircuitDef(allyId) : null;
                    if (friendly !is null && friendly.IsMobile() && friendly.GetBuildSpeed()<=0
                        && friendly.HasSurfToLand() && (flags&2)==0 && dist<radius*radius)
                        localAlly+=aiBattle.GetSeaForceCost(i);
                    if ((flags&4)!=0 && (flags&8)==0 && dist<radius*radius) {
                        // Mixed surface armament is not all anti-sub power.
                        CCircuitDef@ allyDef=ai.GetCircuitDef(aiBattle.GetSeaForceDefId(i));
                        const bool dedicated=(flags&2)!=0 || (allyDef !is null && !allyDef.HasSurfToLand());
                        cover+=aiBattle.GetSeaForceCost(i)*(dedicated ? 1.0f : Global::RoleSettings::Sea::HybridSubCoverWeight);
                    }
                    continue;
                }
                if ((flags&2)!=0 && (flags&8)==0 && dist<radius*radius) enemySubs+=(flags&16)!=0 ? Global::RoleSettings::Sea::UnknownSubContactMetal : aiBattle.GetSeaForceCost(i);
                if (scout) {
                    const int enemyDefId=aiBattle.GetSeaForceDefId(i);
                    const CCircuitDef@ enemy=enemyDefId>=0 ? ai.GetCircuitDef(enemyDefId) : null;
                    if (enemy !is null && (enemy.HasSurfToLand() || enemy.HasSubToLand())) {
                        const float safeRange=enemy.GetMaxRange(1)+128.0f;
                        if (dist<safeRange*safeRange) scoutExposed=true;
                    }
                }
                if ((flags&(1|8|512))==512) {
                    const int hoverDefId=aiBattle.GetSeaForceDefId(i);
                    const CCircuitDef@ hover=hoverDefId>=0 ? ai.GetCircuitDef(hoverDefId) : null;
                    if (hover !is null && hover.HasSurfToLand()) {
                        if (dist<radius*radius) hoverPower+=aiBattle.GetSeaForceCost(i);
                        if (hoverEvade) {
                            const float hoverRange=hover.GetMaxRange(1);
                            const bool outTrades=def.HasSurfToLand() && !hoverBlind && !siege
                                && def.GetMaxRange(1)>hoverRange+2*Global::RoleSettings::Sea::HoverKiteMargin;
                            const float reach=hoverRange+Global::RoleSettings::Sea::HoverEvadeMargin;
                            if (!outTrades && dist<reach*reach) hoverExposed=true;
                        }
                    }
                }
                if ((flags&2)!=0 && !subWeapon) continue;
                // D-301: torpedoes cannot hit hovers; only surface guns engage them.
                if ((flags&512)!=0 && (hoverBlind || !def.HasSurfToLand())) continue;
                // A surfaced ship is still a torpedo target. LAND capability
                // is not required for torpedo-only submarines in this water census.
                if ((flags&2)==0 && !subWeapon && !def.HasSurfToLand() && !def.HasSubToLand()) continue;
                const int id=aiBattle.GetSeaForceId(i);
                // Sonar may identify a contact without a UnitDef (-1). The
                // native integer getter requires a validated definition ID.
                const int contactDef=aiBattle.GetSeaForceDefId(i);
                CCircuitDef@ candidate=contactDef>=0 ? ai.GetCircuitDef(contactDef) : null;
                const bool intercept=subWeapon && (flags&256)!=0 && SeaMath::AmphibiousIntercept(flags,aiBattle.GetSeaForceCost(i),dist,
                    Global::RoleSettings::Sea::AmphibiousInterceptMinimumMetal,Global::RoleSettings::Sea::AmphibiousInterceptRadius);
                // Reuse this cohort's existing contact pass: no per-unit scan
                // or timer. Observed amphibious crossings preempt patrol,
                // assembly and old pursuit exclusions on the next normal tick.
                const int targetRank=intercept ? SeaMath::SubmarineFlagshipTarget+1 : submarine ? SeaSubmarines::TargetRank(candidate,flags,def) : 0;
                if (submarine && targetRank==0) continue;
                if (submarine && (flags&8)!=0 && aiBattle.Height(p)>=0) continue;
                // Current attackable contacts keep combat ahead of territorial
                // duty even while a losing pursuit is in its safety cooldown.
                // Reuse the existing legal-contact pass; no extra enemy scan.
                if (submarine && (flags&128)==0 && ((flags&8)==0
                    || (candidate !is null && (candidate.HasSurfToWater() || candidate.HasSubToWater())))) combatContact=true;
                const bool mobile=candidate !is null && candidate.IsMobile();
                if (mobile && candidate.GetBuildSpeed()<=0 && candidate.HasSurfToLand()
                    && (flags&(2|128))==0 && dist<radius*radius) localEnemy+=aiBattle.GetSeaForceCost(i);
                if (Failed(g,id) && !intercept) continue;
                const float homeSq=MapHelpers::SqDist(p,Global::Map::StartPos);
                const bool urgent=intercept || mobile && homeSq<1600.0f*1600.0f && dist<2400.0f*2400.0f;
                // A nearby second bait is the same rejected fight. Do not
                // alternate IDs and immediately cancel the escape route.
                if (mobile && !urgent && ai.frame<g.avoidUntil
                    && MapHelpers::SqDist(p,g.avoidCentre)<radius*radius) continue;
                float score=SeaMath::ObjectiveScore(flags,candidate !is null && candidate.GetBuildSpeed()>0,
                    aiBattle.GetSeaForceCost(i),sqrt(dist),urgent,id==g.target);
                if (mobile && candidate.GetBuildSpeed()<=0) {
                    // D-301: an armed warship inside either side's reach is the
                    // fight in front of us; it outranks a distant yard.
                    const float reach=AiMax(def.GetMaxRange(subWeapon && (flags&2)!=0 ? 2 : 1),candidate.GetMaxRange(1))
                        +Global::RoleSettings::Sea::EngagedTargetMargin;
                    const bool armed=candidate.HasSurfToLand() || candidate.HasSubToLand() || candidate.HasSurfToWater() || candidate.HasSubToWater();
                    score=SeaMath::EngagedObjectiveScore(score,armed && dist<reach*reach,Global::RoleSettings::Sea::EngagedTargetMultiplier);
                }
                // Drones are 15-metal respawns; the carrier is the target.
                if (contactDef>=0 && DroneCarrier(contactDef)) score*=Global::RoleSettings::Sea::DroneCarrierMultiplier;
                // D-351: the current target is kept unless a rival of the same
                // rank scores TargetHoldRatio times higher; objective flips were
                // 3-9 a minute per sub cohort, each one a new route for every sub.
                if (id==g.target && Global::RoleSettings::Sea::TargetHoldRatio>1) score*=Global::RoleSettings::Sea::TargetHoldRatio;
                if (targetRank>bestTargetRank || (targetRank==bestTargetRank
                    && (id==preferredFlagship || (target!=preferredFlagship && score>bestScore)))) {
                    bestTargetRank=targetRank;
                    bestScore=score; nearest=dist; target=id; goal=p; targetPosition=p; targetSub=(flags&2)!=0;
                    @targetDef=candidate; targetFlags=flags; enemyCost=aiBattle.GetSeaForceCost(i);
                    targetUrgent=urgent;
                }
            }
            const bool danger=SeaMath::NeedsScreen(enemySubs,cover,Global::RoleSettings::Sea::FleetScreenRatio);
            // D-341: a gun cohort that clearly outclasses the local enemy
            // (hovers included) stands against hovers: no evade, no kite-back,
            // no escape from an uncatchable hover. Spam must not herd a fleet.
            // Hulls that cannot hit hovers keep stepping away. O(1) here; the
            // sums come from the existing contact pass.
            const bool hoverSuperior=SeaMath::HoverSuperior(def.HasSurfToLand() && !hoverBlind && !submarine,
                AiMax(localAlly,def.costM*float(g.ids.length())),AiMax(localEnemy,hoverPower),hoverPower,
                Global::RoleSettings::Sea::HoverHoldAdvantage);
            if (hoverExposed && !hoverSuperior) scoutExposed=true;
            if (hoverExposed && hoverSuperior && scoutExposed && !scout)
                Invariants::Violation("INV-230",g.key,"SEA gun cohort withdrew from hovers while holding the local advantage");
            if (submarine && (target>=0 || combatContact)) SeaSubmarines::ReleaseGuard(g);
            if (submarine && bestTargetRank==SeaMath::SubmarineFlagshipTarget && target>=0)
                SeaSubmarines::Publish(g,target);
            if (submarine && target!=g.reportedSubmarineTarget) {
                g.reportedSubmarineTarget=target;
                GenericHelpers::LogUtil("[SEA][SubTarget] cohort="+g.serial+" target="+target
                    +" definition="+(targetDef is null ? "unknown" : targetDef.GetName())+" rank="+bestTargetRank
                    +" urgent="+targetUrgent+" flags="+targetFlags,1);
            }
            if ((danger && !subWeapon) || scoutExposed) {
                // Retain the selected escape leg while travelling. Rebuilding
                // a goal 600 elmos behind a moving centroid every second
                // needlessly replaces every member's queue and overshoots home.
                if (g.target==-2 && g.route !is null && !g.route.IsDead()
                    && !g.route.IsAtEnd(ai.GetTeamUnit(g.ids[0]))) continue;
                AIFloat3 home=Global::Map::StartPos;
                // Start may be dry: walk toward it only as far as navigable.
                float dx=home.x-g.centre.x, dz=home.z-g.centre.z;
                const float length=sqrt(dx*dx+dz*dz);
                if (length>1) { dx/=length; dz/=length; }
                const float step=AiMin(600.0f,length);
                goal=AIFloat3(g.centre.x+dx*step,0,g.centre.z+dz*step);
                if (aiBattle.WaterBody(goal,false)!=g.body) goal=g.centre;
                if (SeaMath::NewObjective(g.target,-2,MapHelpers::SqDist(goal,g.goal),ai.frame-g.ordered,10*SECOND)) {
                    if (Route(g,goal,true,scout)) {
                        g.target=-2; if (g.route !is null) g.route.SetNavalTarget(-1); GenericHelpers::LogUtil("[SEA][Screen] hold "+def.GetName()+" subs="+enemySubs+" cover="+cover,1);
                    }
                }
                continue;
            }
            if (siege && (!Global::RoleSettings::Sea::FleetAttackKnownBases
                || (target<0 && !Coast(g,def,false)))) {
                // With no shared reachable objective, native artillery retains
                // its normal task. A known naval/base target instead uses this
                // hull's own weapon range under the common SEA owner.
                if (g.target==-2 && g.route !is null && !g.route.IsDead()) {
                    for (uint j=0;j<g.ids.length();++j) {
                        CCircuitUnit@ u=ai.GetTeamUnit(g.ids[j]);
                        if (!Eligible(u) || u.task !is g.route) continue;
                        IUnitTask@ native=aiMilitaryMgr.DefaultMakeTask(u);
                        if (native !is null && !aiMilitaryMgr.TransferUnit(u,native)) native.Abort();
                    }
                    g.route.Abort(); @g.route=null; g.target=-999;
                }
                continue;
            }
            if (siege && target<0) continue; // Coast owns this ranged firing station.
            if (Escort(def)) {
                // Native SupportTask selects ATTACK/DEFEND squads only; it
                // cannot follow a fleet while that fleet owns a route. Follow
                // a same-water combat cohort behind its line without changing
                // shared support behavior. One O(G) pass per utility cohort.
                Cohort@ anchor=null; float best=0;
                for (uint j=0;j<groups.length();++j) {
                    Cohort@ candidate=groups[j];
                    if (candidate is g || candidate.body!=g.body || candidate.ids.length()==0) continue;
                    const CCircuitDef@ hull=ai.GetCircuitDef(candidate.defId);
                    // D-301: anchor on surface warships only, never a sub line
                    // or a siege cohort that went native.
                    if (Escort(hull) || hull.IsRoleAny(Unit::Role::SCOUT.mask) || !SurfaceCombat(candidate)) continue;
                    const float value=hull.costM*float(candidate.ids.length())/(1.0f+sqrt(MapHelpers::SqDist(g.centre,candidate.centre))/1600.0f);
                    if (value>best) { best=value; @anchor=candidate; }
                }
                if (anchor !is null) {
                    const AIFloat3 home=Global::Map::StartPos;
                    float dx=home.x-anchor.centre.x, dz=home.z-anchor.centre.z;
                    const float length=sqrt(dx*dx+dz*dz);
                    if (length>1) { dx/=length; dz/=length; }
                    goal=AIFloat3(anchor.centre.x+dx*256,0,anchor.centre.z+dz*256);
                    if (aiBattle.WaterBody(goal,false)!=g.body) goal=anchor.centre;
                    if (SeaMath::NewObjective(g.target,-3,MapHelpers::SqDist(goal,g.goal),ai.frame-g.ordered,45*SECOND)
                        && Route(g,goal,false,true)) {
                        g.target=-3; GenericHelpers::LogUtil("[SEA][Escort] "+def.GetName()+" follows "+anchor.key,1);
                    }
                }
                continue;
            }
            if (ai.frame<g.retry && !targetUrgent && (!submarine || (target<0 && !combatContact))) continue;
            const float contactRange=targetDef is null ? def.GetMaxRange(2) : AiMax(def.GetMaxRange(2),targetDef.GetMaxRange(2));
            const bool engaged=fireline && target>=0 && (targetFlags&128)==0
                && (nearest<(contactRange+128)*(contactRange+128) || g.sampleHealth-g.health>.01f);
            if (!engaged) g.holdingFireline=false;
            if (fireline && !engaged && target<0 && !combatContact && SeaSubmarines::Replacement(g)) continue;
            if (!g.released) {
                // Assembly is not permission to sit under fire. A local
                // weapon-range contact or damage releases this cohort now;
                // pursuit admission below can still choose to disengage.
                const float immediateRange=targetDef is null ? 0 : AiMax(def.GetMaxRange(targetSub || submarine ? 2 : 1),targetDef.GetMaxRange(targetSub ? 2 : 1))+128;
                g.released=targetUrgent || g.health<.95f || target>=0 && nearest<immediateRange*immediateRange
                    || SeaMath::ReleaseFleet(TaskForceShips(g),ai.frame-g.created,
                        submarine && Global::RoleSettings::Sea::CoordinatedFleet ? Global::RoleSettings::Sea::SubmarineDepartureCount : Global::RoleSettings::Sea::FleetReleaseCount,
                        (submarine && Global::RoleSettings::Sea::CoordinatedFleet ? Global::RoleSettings::Sea::SubmarineDepartureSeconds : Global::RoleSettings::Sea::FleetReleaseSeconds)*SECOND);
                if (!g.released) {
                    if (g.route is null || g.route.IsDead()) Route(g,g.previousCentre,false,true,true);
                    continue;
                }
            }
            if (target>=0 && !scout) {
                const float range=def.GetMaxRange(targetSub || submarine ? 2 : 1), distance=sqrt(nearest);
                if (submarine && range<=0)
                    Invariants::Violation("INV-180",g.key,"SEA submarine naval objective has no water firing range");
                const bool mobile=targetDef !is null && targetDef.IsMobile();
                if (target!=g.sampleTarget) {
                    g.sampleTarget=target; g.sampleFrame=ai.frame; g.pursuitStart=0;
                    g.sampleDistance=distance; g.sampleHealth=g.health; g.samplePos=goal; g.anchor=g.centre;
                }
                const float elapsed=float(ai.frame-g.sampleFrame)/SECOND;
                const float enemySpeed=elapsed>0 ? sqrt(MapHelpers::SqDist(goal,g.samplePos))/elapsed : 0;
                const float advantage=AiMax(localAlly,def.costM*float(g.ids.length()))/AiMax(1.0f,AiMax(localEnemy,enemyCost));
                // Crossing an empty sea toward a contact is transit, not a
                // losing range trade. Start the leash at first engagement.
                const bool enemyCanFire=mobile && (targetSub ? (submarine ? targetDef.HasSubToWater() : targetDef.HasSubToLand() || targetDef.HasSubToWater())
                    : (submarine ? targetDef.HasSurfToWater() : targetDef.HasSurfToLand()));
                const float enemyRange=targetDef is null ? 0 : targetDef.GetMaxRange(submarine ? 2 : 1);
                if (enemyCanFire && g.pursuitStart==0 && SeaMath::Engagement(distance,enemyRange,g.sampleHealth-g.health)) {
                    g.pursuitStart=ai.frame; g.anchor=g.centre;
                }
                const float beyond=sqrt(MapHelpers::SqDist(g.centre,g.anchor))-Global::RoleSettings::Sea::FleetPursuitLeash;
                const bool bait=enemyCanFire && g.pursuitStart>0 && elapsed>=2 && SeaMath::PursuitBad(distance-range,def.GetSpeed(),enemySpeed,
                    g.health,advantage,elapsed,g.sampleDistance-distance,g.sampleHealth-g.health,
                    Global::RoleSettings::Sea::FleetClosingSeconds,beyond);
                if (fireline && engaged && (bait || distance<range*.95f)) {
                    // Forward-only torpedoes cannot cover a turn. Keep the
                    // engaged owners firing; fresh hulls build a separate line.
                    if (bait || g.health<.7f || advantage<.85f)
                        SeaSubmarines::OpenReplacement(g,targetPosition,AiMax(enemyCost,localEnemy+enemySubs));
                    SeaSubmarines::HoldFireline(g,target);
                    continue;
                }
                if (bait && hoverSuperior && (targetFlags&512)!=0) {
                    // D-341: an uncatchable hover is not a lost fight. Stop the
                    // chase at the engagement anchor without excluding the hover
                    // or avoiding its area, so it is shot when it closes again.
                    if (Route(g,g.anchor,false,false,true)) {
                        g.target=-10; // D-341 superior hover hold if (g.route !is null) g.route.SetNavalTarget(-1);
                    }
                    g.pursuitStart=0; g.retry=ai.frame+2*SECOND;
                    GenericHelpers::LogUtil("[SEA][Pursuit] hold cohort="+g.serial+" target="+target+" superior hover chase",1);
                    continue;
                }
                if (bait) {
                    Fail(g,target);
                    // A short legal withdrawal cancels the chase immediately;
                    // next census can choose a different territorial objective.
                    const float length=AiMax(1.0f,distance);
                    const float step=AiMax(240.0f,targetDef.GetMaxRange(1)+192.0f-distance);
                    AIFloat3 escape=Spam::_Clamp(AIFloat3(g.centre.x+(g.centre.x-goal.x)*step/length,0,
                        g.centre.z+(g.centre.z-goal.z)*step/length));
                    Route(g,escape,true,true,true); g.target=-5;
                    g.anchor=escape; g.avoidCentre=goal;
                    g.avoidUntil=ai.frame+Global::RoleSettings::Sea::FleetFailureSeconds*SECOND;
                    if (g.route !is null) g.route.SetNavalTarget(-1);
                    g.retry=ai.frame+2*SECOND;
                    GenericHelpers::LogUtil("[SEA][Pursuit] break cohort="+g.serial+" target="+target+" gap="+(distance-range),1);
                    continue;
                }
                if (elapsed>=6) { g.sampleFrame=ai.frame; g.sampleDistance=distance; g.sampleHealth=g.health; g.samplePos=goal; }
                // Range margin lets the entire shallow line fire. Do not
                // continually move a firing fleet merely because a target drifts.
                const bool remembered=(targetFlags&128)!=0;
                const float desired=AiMax(64.0f,SeaMath::ApproachRange(range,def.GetLosRadius(),remembered));
                const float slack=fireline && engaged ? AiMin(distance,desired) : desired;
                if (distance>1) goal=AIFloat3(goal.x+(g.centre.x-goal.x)*slack/distance,0,
                    goal.z+(g.centre.z-goal.z)*slack/distance);
                // KI-611: a hover closing inside its own reach is not a held band; kite it below.
                const bool hoverClose=(targetFlags&512)!=0 && targetDef !is null
                    && distance<targetDef.GetMaxRange(1)+Global::RoleSettings::Sea::HoverKiteMargin;
                const bool inBand=!remembered && !hoverClose && distance<range*.98f && distance>range*.72f;
                if (inBand && g.target==target && g.route !is null && !g.route.IsDead()
                    && (!submarine || SeaSubmarines::OutsideStaticTorpedoes(g.centre))) {
                    g.route.SetNavalTarget((targetFlags&128)!=0 ? -1 : target); continue;
                }
                // D-301: kiting generalised from the Riptide to the Ellysaw and
                // Syracusia; it only applies against shorter-ranged targets.
                const string hullName=def.GetName();
                // KI-611: every gun hull that outranges a hover kites it. A
                // T1 assault hover (corhal: 4,350 HP, 300 range) wins a close
                // trade against any T1 hull, so stay outside its reach.
                const float targetReach=targetDef is null ? 0 : targetDef.GetMaxRange(1);
                // D-341: kiting trades ground for range against an equal or
                // stronger hover force; a superior cohort stands and fires.
                const bool hoverKite=Global::RoleSettings::Sea::HoverKite && !hoverSuperior && (targetFlags&512)!=0 && targetDef !is null
                    && def.HasSurfToLand() && range>targetReach+2*Global::RoleSettings::Sea::HoverKiteMargin;
                if (Global::RoleSettings::Sea::CoordinatedFleet && (hoverKite || hullName=="corpship" || hullName=="armpship" || hullName=="legnavydestro")
                    && !targetSub && !remembered) {
                    // Stable movement intent, independent responsive fire. The
                    // short commitment only applies to range corrections for
                    // the SAME target; danger/ownership/target changes bypass it.
                    const bool immediateDanger=g.sampleHealth-g.health>.03f || g.health<.5f;
                    if (!immediateDanger && g.target==target && g.route !is null && !g.route.IsDead()
                        && ai.frame-g.ordered<Global::RoleSettings::Sea::FrigateMovementCommitSeconds*SECOND) {
                        g.route.SetNavalTarget(target); continue;
                    }
                    const float kiteAt=hoverKite ? AiMax(range*Global::RoleSettings::Sea::FrigateKiteRangeFraction,targetReach+Global::RoleSettings::Sea::HoverKiteMargin)
                        : range*Global::RoleSettings::Sea::FrigateKiteRangeFraction;
                    if (targetDef !is null && targetReach<range && distance<kiteAt) {
                        const float firingDistance=hoverKite ? AiMin(range*.95f,AiMax(range*Global::RoleSettings::Sea::FrigateFiringRangeFraction,targetReach+2*Global::RoleSettings::Sea::HoverKiteMargin))
                            : range*Global::RoleSettings::Sea::FrigateFiringRangeFraction;
                        goal=Spam::_Clamp(AIFloat3(targetPosition.x+(g.centre.x-targetPosition.x)*firingDistance/AiMax(1.0f,distance),0,
                            targetPosition.z+(g.centre.z-targetPosition.z)*firingDistance/AiMax(1.0f,distance)));
                    }
                }
            } else {
                if (submarine && combatContact) {
                    // Do not resume a shore route during a rejected-fight
                    // cooldown. Hold under combat ownership until re-evaluation;
                    // existing retreat/target selection still governs safety.
                    if (g.target!=-9 || g.route is null || g.route.IsDead()) {
                        if (Route(g,g.centre,true,true,true)) { g.target=-9; g.route.SetNavalTarget(-1); }
                    }
                    continue;
                }
                // Only untargeted submarines secure shores. Observed ships,
                // then naval factories, preempt the perimeter on the next tick.
                if (submarine && SeaSubmarines::Perimeter(g,def)) continue;
                AIFloat3 screen;
                if (!scout && SeaInvasion::Screen(g.body,g.defId,screen)) {
                    // A blocked untouched factory can move its reservation.
                    // Escort follows the new site once, not an obsolete anchor.
                    if (g.target!=-4 || g.route is null || g.route.IsDead() || MapHelpers::SqDist(g.goal,screen)>SQUARE_SIZE*SQUARE_SIZE) {
                        if (Route(g,screen,false,true,true)) g.target=-4;
                        else g.retry=ai.frame+10*SECOND;
                    }
                    if (g.route !is null && !g.route.IsDead()) for (uint member=0;member<g.ids.length();++member) {
                        CCircuitUnit@ reinforcement=ai.GetTeamUnit(g.ids[member]);
                        if (Eligible(reinforcement) && reinforcement.task !is g.route) aiMilitaryMgr.TransferUnit(reinforcement,g.route);
                    }
                    continue;
                }
                int reserve=-1; reserves.get(""+g.body,reserve);
                if (!scout && Coast(g,def,reserve==g.serial)) continue;
                Failed(g,-1); // expire exclusions even when contacts vanish
                if (!scout && g.failedIds.length()>0) {
                    // No alternative objective: finish the withdrawal. A new
                    // forward search must not immediately recreate the chase
                    // that was rejected as bait on the previous census.
                    if (g.target!=-6 && Route(g,g.anchor,true,true,true)) {
                        g.target=-6; g.route.SetNavalTarget(-1);
                    }
                    continue;
                }
                target=-1;
                if (force !is null) {
                    // Join the lead's fight instead of an independent search.
                    if (aiBattle.WaterBody(force.goal,false)!=g.body) {
                        Invariants::Violation("INV-228",g.key,"SEA task force goal outside the follower's water body");
                    } else if (MapHelpers::SqDist(g.goal,force.goal)>384.0f*384.0f || g.route is null || g.route.IsDead()) {
                        goal=force.goal;
                        if (Route(g,goal,false,false,false,true,true)) {
                            g.target=-7; g.route.SetNavalTarget(-1);
                            GenericHelpers::LogUtil("[SEA][TaskForce] cohort="+g.serial+" "+def.GetName()+" joins lead="+force.lead+" target="+force.target,1);
                        }
                        continue;
                    } else continue;
                }
                if (ai.frame-g.ordered<Global::RoleSettings::Sea::FleetSearchSeconds*SECOND
                    && g.route !is null && !g.route.IsDead() && !g.route.IsAtEnd(ai.GetTeamUnit(g.ids[0]))) continue;
                ++g.search; goal=Search(g);
            }
            const bool rangeCorrection=target>=0 && target==g.target && sqrt(nearest)<def.GetMaxRange(targetSub || submarine ? 2 : 1)*.72f
                && MapHelpers::SqDist(goal,g.goal)>96.0f*96.0f;
            if (!rangeCorrection && !SeaMath::NewObjective(g.target,target,MapHelpers::SqDist(goal,g.goal),ai.frame-g.ordered,
                Global::RoleSettings::Sea::FleetSearchSeconds*SECOND)) continue;
            if (submarine && target>=0 && !SeaSubmarines::OutsideStaticTorpedoes(goal)) {
                if (fireline && engaged) {
                    SeaSubmarines::OpenReplacement(g,targetPosition,AiMax(enemyCost,localEnemy+enemySubs));
                    SeaSubmarines::HoldFireline(g,target); continue;
                }
                // Reject the exposed firing approach, not the entire sea.
                // The next census can select another eligible ship or yard.
                Fail(g,target);
                if (Route(g,g.anchor,true,true,true)) { g.target=-6; g.route.SetNavalTarget(-1); }
                continue;
            }
            // Far approach is ordinary MOVE transit, not combat micro. The
            // selected target is still reevaluated each tick and priority fire
            // is independent of the queue. Preserve close firing corrections.
            const float engagementRange=AiMax(def.GetMaxRange(targetSub || submarine ? 2 : 1),
                targetDef is null ? 0.0f : targetDef.GetMaxRange(submarine ? 2 : 1))+128.0f;
            const bool transit=target<0 || nearest>engagementRange*engagementRange;
            // D-348 (2026-10-19 online lag: 59 small sub groups re-routed on one
            // frame, 509 route orders a minute): chasing the SAME target is
            // re-routed at most every FleetRerouteSeconds; a new target is
            // immediate. Firing never waits on the queue (priority fire is
            // independent), so this only thins MOVE orders, not reactions.
            if (target>=0 && target==g.target && ai.frame-g.ordered<Global::RoleSettings::Sea::FleetRerouteSeconds*SECOND) continue;
            // Working-copy cap applies only to same-target route attempts.
            // Keep the existing fair total-route budget and count after the
            // existing admission checks, so rejected goals do not consume it.
            const bool sameTarget = target>=0 && target==g.target;
            if (sameTarget && Global::RoleSettings::Sea::FleetReroutesPerTick>0
                && reroutes>=Global::RoleSettings::Sea::FleetReroutesPerTick) continue;
            if (routeBudget<=0) continue;
            --routeBudget;
            if (sameTarget) ++reroutes;
            if (Route(g,goal,false,scout,false,transit,target<0)) {
                g.target=target;
                if (target>=0 && targetSub && (targetFlags&128)==0) AntiSubFormation(g,targetPosition);
                if (g.route !is null) g.route.SetNavalTarget(target>=0 && (targetFlags&128)==0 ? target : -1);
                GenericHelpers::LogUtil("[SEA][Fleet] "+def.GetName()+" n="+g.ids.length()+" target="+target+" goal="+int(goal.x)+","+int(goal.z),1);
            } else {
                Fail(g,target); g.ordered=ai.frame; g.retry=ai.frame+SECOND; ++g.search;
                GenericHelpers::LogUtil("[SEA][Fleet] route unavailable "+def.GetName()+"; select another water objective",3);
            }
        }
    }
}
