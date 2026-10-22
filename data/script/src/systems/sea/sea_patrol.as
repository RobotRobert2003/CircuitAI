// D-202: SEA owns scout/AA movement separately from surface attack cohorts.
// Stable unit IDs, sector leases and per-boat routes prevent native AA merging.
// Contact census is O(A*B); boat selection O(U*A). The bounded water grid is
// built once; O(P) patrol selection occurs on assignment/expiry, never per frame.
// Naval danger costs O(K*E) for distinct candidate cells K, sea contacts E;
// at most 49 candidates/boat, with cached overlapping formation candidates.
#include "sea_scout_raids.as"
#include "sea_shorelines.as"
namespace SeaPatrol {
    // Test-only event counts; disabled policy adds no per-event strings or logs.
    array<int> diagnosticCounts(7,0);
    void Count(int reason) { if (Global::RoleSettings::Sea::ScoutDiagnostics) ++diagnosticCounts[reason]; }
    void Report() {
        if (!Global::RoleSettings::Sea::ScoutDiagnostics || ai.frame%(60*SECOND)!=0) return;
        GenericHelpers::LogUtil("[SEA][ScoutOrders] new="+diagnosticCounts[0]+" arrival="+diagnosticCounts[1]+" expiry="+diagnosticCounts[2]+" recovery="+diagnosticCounts[3]+" escape="+diagnosticCounts[4]+" raid="+diagnosticCounts[5]+" route_points="+diagnosticCounts[6],1);
        for (uint i=0;i<diagnosticCounts.length();++i) diagnosticCounts[i]=0;
    }
    class Sector {
        AIFloat3 pos;
        AIFloat3 landAnchor=AIFloat3(-1,0,-1);
        int body=-1, owner=-1, visited=-100000, priority=0;
        bool shore=false, scoutShore=false, enemyScoutShore=false, enemyEdgeShore=false;
        float enemyDistance=0;
    }
    class Boat {
        int id=-1, body=-1, sector=-1, until=0, seen=0, slot=-1, retry=0;
        int mode=-1, target=-1;
        bool overwatch=false;
        int overwatchSector=-1, overwatchUntil=0;
        int failedSector=-1, failedUntil=0;
        AIFloat3 goal;
        CRouteTask@ route;
    }
    class Raid {
        int body=-1, target=-1, seen=-100000, candidate=-1, nextSlot=0;
        AIFloat3 pos, velocity, centre, direction;
        float range=100000, speed=100000, distance=100000;
        bool present=false;
    }
    array<Sector@> sectors;
    array<Boat@> boats;
    array<Raid@> raids;
    array<int> contactBodies;
    dictionary boatIndex;
    dictionary navalSafety;
    float cell=640;
    bool gridReady=false;
    int seaContacts=0;
    bool Scout(const CCircuitDef@ d) {
        const string name=d.GetName();
        return name=="armpt" || name=="corpt" || name=="coresupp" || name=="legnavyscout";
    }
    bool AA(const CCircuitDef@ d) {
        // A broad target mask is not an AA role: Legion's scout gun can hit
        // aircraft for tiny damage. Including it would shrink the entire
        // screen to that gun's short range and sacrifice the scouting fleet.
        const string name=d.GetName();
        // JSON role[1..] describes enemy response categories, not this hull's
        // own roles (FactoryManager::ReadConfig). Iapetus is scout-first there.
        // D-301: fleet AA hulls escort the fleet (SeaOperations::FleetAA).
        if (Global::RoleSettings::Sea::FleetAAEscort && SeaOperations::FleetAA(d)) return false;
        return d.HasSurfToAir() && (name=="armpt" || name=="corpt" || name=="armaas" || name=="corarch"
            || name=="legnavyaaship" || name=="leganavyaaship" || d.IsRoleAny(Unit::Role::AA.mask));
    }
    bool Handles(const CCircuitDef@ d) {
        if (!Global::RoleSettings::Sea::FleetOperations) return false;
        bool naval=false;
        for (uint i=0;i<SeaCombat::roster.length();++i)
            if (SeaCombat::roster[i].def is d) { naval=true; break; }
        return naval && (Scout(d) || AA(d));
    }
    bool Available(CCircuitUnit@ u) {
        if (u is null || u.GetBuildProgress()<1 || !Handles(u.circuitDef)
            || u.GetRulesParam("carrier_host_unit_id",-1)>=0) return false;
        if (u.task is null) return true;
        return u.task.GetType()!=int(Task::Type::PLAYER) && u.task.GetType()!=int(Task::Type::RETREAT)
            && !u.task.IsExternalControlled();
    }
    void Release(Boat@ b) {
        b.overwatch=false;
        if (b.sector>=0 && sectors[b.sector].owner==b.id) sectors[b.sector].owner=-1;
        b.sector=-1;
        if (b.route !is null && !b.route.IsDead()) { b.route.SetSeaTarget(-1); b.route.Abort(); }
        @b.route=null;
    }
    void Leave() {
        for (uint i=0;i<boats.length();++i) Release(boats[i]);
        boats.resize(0); boatIndex.deleteAll(); raids.resize(0);
        SeaScoutRaids::groups.resize(0);
    }
    void Grid() {
        if (gridReady) return;
        gridReady=true;
        // At most 64*64 cells, built once; eight height probes classify shores.
        // Terrain is public, enemy buildings are not. Visits require arrival,
        // never just an assigned destination. Live threat checks stay at admission.
        cell=AiMax(Global::RoleSettings::Sea::ShoreSurveyCell,float(AiMax(AiTerrainWidth(),AiTerrainHeight()))/64.0f);
        for (float z=cell*.5f;z<AiTerrainHeight();z+=cell) for (float x=cell*.5f;x<AiTerrainWidth();x+=cell) {
            AIFloat3 p(x,0,z); const int body=aiBattle.WaterBody(p,false);
            if (body<0 || aiBattle.Height(p)>-20) continue;
            Sector@ s=Sector(); s.pos=p; s.body=body;
            for (int j=0;j<8;++j) {
                const float a=float(j)*.785398f;
                AIFloat3 edge=Spam::_Clamp(AIFloat3(x+cos(a)*cell,0,z+sin(a)*cell));
                if (aiBattle.Height(edge)>=-8) { s.shore=true; break; }
            }
            s.priority=s.shore ? 1 : 0;
            sectors.insertLast(s);
        }
    }
    Raid@ Basin(int body) {
        for (uint i=0;i<raids.length();++i) if (raids[i].body==body) return raids[i];
        Raid@ r=Raid(); r.body=body; raids.insertLast(r); return r;
    }
    // KI-610 (D-301): profiles give naval hulls zero threat weight, so the
    // threat map is blind to enemy gunboats and scouts sailed into them. Add
    // SEA's own legal contact snapshot: inside any known armed enemy ship's
    // weapon range plus ScoutShipMargin is unsafe. O(E) per check; checks run
    // on survey choice and on exposure, never per frame.
    bool ShipCovered(const AIFloat3 &in p) {
        if (!Global::RoleSettings::Sea::ScoutAvoidShips) return false;
        const int count=aiBattle.GetSeaForceCount();
        for (int i=0;i<count;++i) {
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&1)!=0) continue;
            const int defId=aiBattle.GetSeaForceDefId(i);
            const CCircuitDef@ d=defId>=0 ? ai.GetCircuitDef(defId) : null;
            if (d is null || (!d.HasSurfToLand() && !d.HasSurfToWater() && !d.HasSubToWater())) continue;
            const float radius=AiMax(d.GetMaxRange(1),d.GetMaxRange(2))+Global::RoleSettings::Sea::ScoutShipMargin;
            if (MapHelpers::SqDist(p,aiBattle.GetSeaForcePos(i))<radius*radius) return true;
        }
        return false;
    }
    bool ThreatSafe(const AIFloat3 &in p) {
        return aiBattle.SurfThreat(p)<=Global::RoleSettings::Sea::ScoutMaximumThreat
            && aiBattle.AmphThreat(p)<=Global::RoleSettings::Sea::ScoutMaximumThreat
            && !ShipCovered(p);
    }
    bool Safe(CCircuitUnit@ u,const AIFloat3 &in p,int body) {
        return aiBattle.WaterBody(p,false)==body && aiTerrainMgr.CanMoveTo(u,p) && ThreatSafe(p);
    }
    bool InterceptionSite(CCircuitUnit@ u,const AIFloat3 &in p,int body,const string &in cellKey) {
        if (aiBattle.WaterBody(p,false)!=body || !aiTerrainMgr.CanMoveTo(u,p)) return false;
        bool safe=false;
        if (navalSafety.get(cellKey,safe)) return safe;
        // The ordinary threat map includes aircraft damage. An AA screen must
        // deliberately engage that layer, while retaining naval/sub avoidance.
        // Cache same-grid candidates within this census only: live contacts,
        // formation origin and orientation invalidate every answer next tick.
        safe=true;
        for (int i=0;i<seaContacts;++i) {
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&1)!=0 || aiBattle.GetSeaForceBody(i)!=body) continue;
            const int defId=aiBattle.GetSeaForceDefId(i);
            const CCircuitDef@ d=defId>=0 ? ai.GetCircuitDef(defId) : null;
            float radius=Global::RoleSettings::Sea::FleetScreenRadius; // unidentified sonar contact
            if (d !is null) {
                if (!d.HasSurfToLand() && !d.HasSurfToWater() && !d.HasSubToLand() && !d.HasSubToWater()) continue;
                radius=AiMax(d.GetMaxRange(1),d.GetMaxRange(2))+128;
            } else if ((flags&16)==0) continue;
            if (MapHelpers::SqDist(p,aiBattle.GetSeaForcePos(i))<radius*radius) { safe=false; break; }
        }
        navalSafety.set(cellKey,safe); return safe;
    }
    int NearbyBody(const AIFloat3 &in p) {
        int body=aiBattle.WaterBody(p,false);
        if (body>=0) return body;
        // Shore transits can already be in naval AA range while over a beach.
        for (int i=0;i<8;++i) {
            const float a=float(i)*.785398f;
            body=aiBattle.WaterBody(AIFloat3(p.x+cos(a)*384,0,p.z+sin(a)*384),false);
            if (body>=0) return body;
        }
        return -1;
    }
    void Contacts() {
        for (uint i=0;i<raids.length();++i) { raids[i].present=false; raids[i].candidate=-1; raids[i].range=100000; raids[i].speed=100000; raids[i].distance=100000; }
        const int count=aiBattle.GetAirContactCount();
        contactBodies.resize(count);
        for (int i=0;i<count;++i) {
            const AIFloat3 p=aiBattle.GetAirContactPos(i);
            const int body=NearbyBody(p); contactBodies[i]=body; if (body<0) continue;
            Raid@ r=Basin(body);
            // Respond to scouts/transports too. Prefer the contact nearest our
            // protected coast. Commit once after selection so iteration order
            // cannot corrupt the previous observation used for velocity.
            const float score=MapHelpers::SqDist(p,Global::Map::StartPos);
            if (r.candidate>=0 && score>=MapHelpers::SqDist(aiBattle.GetAirContactPos(r.candidate),Global::Map::StartPos)) continue;
            r.candidate=i;
        }
        for (uint i=0;i<raids.length();++i) {
            Raid@ r=raids[i]; if (r.candidate<0) continue;
            const int id=aiBattle.GetAirContactId(r.candidate);
            const AIFloat3 p=aiBattle.GetAirContactPos(r.candidate);
            const float dt=float(ai.frame-r.seen)/float(SECOND);
            r.velocity=(id==r.target && dt>0 && dt<=2) ? AIFloat3((p.x-r.pos.x)/dt,0,(p.z-r.pos.z)/dt) : AIFloat3(0,0,0);
            r.pos=p; r.present=true; r.target=id; r.seen=ai.frame;
        }
    }
    int FireTarget(Boat@ b,CCircuitUnit@ u) {
        const AIFloat3 p=u.GetPos(ai.frame);
        const float range=u.circuitDef.GetMaxRange(0);
        float best=range*range; int target=-1;
        for (uint i=0;i<contactBodies.length();++i) {
            if (contactBodies[i]!=b.body) continue;
            const int id=aiBattle.GetAirContactId(i);
            const float distance=MapHelpers::SqDist(p,aiBattle.GetAirContactPos(i));
            if (id==b.target && distance<=range*range) return id;
            if (distance<best) { best=distance; target=id; }
        }
        // Out of weapon range keep moving to the screen, with autonomous fire
        // available. Never pin every ship to one far plane over a nearer one.
        return target;
    }
    bool Order(Boat@ b,CCircuitUnit@ u,const array<AIFloat3>@ points,bool patrol,bool survey=false) {
        if (b.route is null || b.route.IsDead()) {
            @b.route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (b.route is null) return false;
            b.route.SetSeaControl(true); b.route.SetHoldPosition(true);
        }
        // D-340: scout and AA screen routes have no ship target; compact them
        // before SetRoute so a new route dispatches once (setting it after
        // SetRoute bumped the version and re-sent the whole queue). PATROL
        // queues are never compacted natively.
        b.route.SetMoveCompaction(Global::RoleSettings::Sea::CompactMoveRoutes
            && (Scout(u.circuitDef) || survey || Global::RoleSettings::Sea::CompactUntargetedRoutes));
        if (Global::RoleSettings::Sea::ScoutDiagnostics) diagnosticCounts[6]+=int(points.length());
        b.route.SetTraversal(true,48,false); b.route.SetPatrol(patrol); b.route.SetRoute(points);
        if (u.task !is b.route && !aiMilitaryMgr.TransferUnit(u,b.route)) {
            Invariants::Violation("INV-146",""+u.id,"SEA scout/AA route handover failed"); return false;
        }
        return true;
    }
    // One terrain search per new scout destination, never per census while a
    // valid route is retained. Native route buffers are publication-versioned.
    // Keep bends around islands/corners; compaction validates ship offsets.
    bool SurveyOrder(Boat@ b,CCircuitUnit@ u,const AIFloat3 &in goal) {
        const AIFloat3 origin=u.GetPos(ai.frame);
        const float distance=sqrt(MapHelpers::SqDist(origin,goal));
        // Most coverage steps are straight. Validate the segment
        // first: avoids graph searches and lets a shallow-draft scout leave a
        // legal position whose coarse naval grid cell is blocked. Curved trips
        // use the graph, particularly around Sulphur's turning coast. Sampling
        // has a map-size bound; the engine still uses the actual ship MoveDef.
        {
            const int samples=AiMax(1,int(distance/AiMax(16.0f,Global::RoleSettings::Sea::ScoutRouteSampleSpacing))+1); bool clear=true;
            for (int i=1;i<=samples;++i) {
                AIFloat3 point=origin+(goal-origin)*(float(i)/float(samples));
                if (!Safe(u,point,b.body) || aiBattle.Height(point)>-Global::RoleSettings::Sea::ScoutRouteMinimumDepth) { clear=false; break; }
            }
            if (clear) { array<AIFloat3> direct={goal}; return Order(b,u,direct,false); }
        }
        array<AIFloat3>@ points=aiBattle.GetTerrainRoute(u.GetPos(ai.frame),goal,5,10,1,
            Global::RoleSettings::Sea::ScoutRouteThreatWeight,Global::RoleSettings::Sea::ScoutMaximumThreat);
        if (points.length()==0) {
            if (Global::RoleSettings::Sea::ScoutDiagnostics && ai.frame%(10*SECOND)==0)
                GenericHelpers::LogUtil("[SEA][ScoutRoute] empty id="+b.id+" from="+int(origin.x)+","+int(origin.z)+" goal="+int(goal.x)+","+int(goal.z),1);
            return false;
        }
        uint kept=0;
        for (uint i=0;i<points.length();++i) {
            // The native graph includes its origin. Do not issue a MOVE back
            // to the start cell before following the forward route.
            if (i==0 && MapHelpers::SqDist(origin,points[i])<cell*cell) continue;
            if (i>0 && (aiBattle.SurfThreat(points[i])>Global::RoleSettings::Sea::ScoutMaximumThreat
                || aiBattle.AmphThreat(points[i])>Global::RoleSettings::Sea::ScoutMaximumThreat)) return false;
            // Lane cells describe a coarse water graph, not this hull's engine
            // movement area. Never order an unreachable intermediate cell.
            // Preserve reachable bends; the engine joins them with its actual
            // MoveDef. Reject threats above rather than filtering them away.
            if (aiBattle.WaterBody(points[i],false)==b.body && aiTerrainMgr.CanMoveTo(u,points[i]))
                points[kept++]=points[i];
        }
        points.resize(kept);
        points.insertLast(goal);
        return Order(b,u,points,false,true);
    }
    bool Evade(Boat@ boat,CCircuitUnit@ unit) {
        const AIFloat3 here=unit.GetPos(ai.frame);
        // A ship can traverse a legal engine cell that the coarser planning
        // grid rejects as a destination. That is not enemy fire. Only actual
        // threat starts an escape; still validate geometry at its destination.
        if (ThreatSafe(here)) return false;
        if (boat.mode==4 && boat.route !is null && !boat.route.IsDead() && unit.task is boat.route
            && Safe(unit,boat.goal,boat.body)) return true;
        // A newly exposed scout must be allowed to leave a threatened origin;
        // a zero-threat graph route may not exist until outside weapon range.
        // Choose the nearest legal safe sector, then let engine movement escape.
        // Scan only on exposure/new escape intent, not during a retained escape.
        int best=-1; float distance=1e30f;
        for (uint i=0;i<sectors.length();++i) {
            if (sectors[i].body!=boat.body) continue;
            const float candidate=MapHelpers::SqDist(here,sectors[i].pos);
            if (candidate>=distance || !Safe(unit,sectors[i].pos,boat.body)) continue;
            best=int(i); distance=candidate;
        }
        if (best<0) return false;
        array<AIFloat3> points={sectors[best].pos};
        if (!Order(boat,unit,points,false)) return false;
        if (boat.sector>=0 && sectors[boat.sector].owner==boat.id) sectors[boat.sector].owner=-1;
        Count(4);
        boat.overwatch=false; boat.sector=-1; boat.mode=4; boat.goal=sectors[best].pos; boat.target=-1;
        boat.route.SetSeaTarget(-1);
        GenericHelpers::LogUtil("[SEA][ScoutEvade] id="+boat.id+" goal="+int(boat.goal.x)+","+int(boat.goal.z),1);
        return true;
    }
    void Patrol(Boat@ b,CCircuitUnit@ u) {
        if (ai.frame<b.retry) return;
        const AIFloat3 here=u.GetPos(ai.frame);
        const bool scout=Scout(u.circuitDef);
        const float sight=u.circuitDef.GetLosRadius()*.5f;
        const float visibleDistanceSquared=sight*sight*4.0f;
        // Sight is evidence of coverage, not movement completion. Retain the
        // useful route to its destination instead of turning at half LOS.
        const float arrivalRadius=Global::RoleSettings::Sea::ScoutArrivalRadius;
        const bool arrived=MapHelpers::SqDist(here,b.goal)<arrivalRadius*arrivalRadius;
        const bool routeEnded=b.route !is null && !b.route.IsDead() && b.route.IsAtEnd(u);
        if (scout && b.mode==0 && b.sector>=0 && routeEnded && !arrived) {
            b.failedSector=b.sector; b.failedUntil=ai.frame+Global::RoleSettings::Sea::ScoutFailedSectorSeconds*SECOND;
        }
        if (b.mode==0 && b.sector>=0 && arrived) sectors[b.sector].visited=ai.frame;
        bool observedYard=false;
        if (scout && arrived && b.mode==0 && b.sector>=0) {
            // Only arrived scouts inspect the shared legal-contact snapshot;
            // O(arrived scouts * contacts) at the existing fleet cadence.
            // An observed yard outranks a coarse terrain access classification.
            const float vision=u.circuitDef.GetLosRadius();
            for (int j=0;j<seaContacts;++j) {
                const int flags=aiBattle.GetSeaForceFlags(j);
                if ((flags&(1|128))!=0 || (flags&32)==0 || aiBattle.GetSeaForceBody(j)!=b.body) continue;
                if (MapHelpers::SqDist(here,aiBattle.GetSeaForcePos(j))<=vision*vision) { observedYard=true; break; }
            }
        }
        if (scout && Global::RoleSettings::Sea::ScoutEdgeOverwatch && b.mode==0 && b.sector>=0
            && (observedYard || (sectors[b.sector].enemyEdgeShore && sectors[b.sector].priority==2)) && arrived && Safe(u,b.goal,b.body)
            && b.route !is null && !b.route.IsDead() && u.task is b.route) {
            int scouts=0, watching=0;
            for (uint j=0;j<boats.length();++j) {
                CCircuitUnit@ other=ai.GetTeamUnit(boats[j].id);
                if (boats[j].body!=b.body || !Available(other) || !Scout(other.circuitDef)) continue;
                ++scouts; if (boats[j] !is b && boats[j].overwatch) ++watching;
            }
            // Retain one roaming scout even when multiple edge approaches need
            // persistent vision. Live threat/retreat always preempts overwatch.
            if (b.overwatchSector!=b.sector) {
                b.overwatchSector=b.sector;
                b.overwatchUntil=ai.frame+SeaShorelines::Interval(sectors[b.sector]);
            }
            // Empty sites rotate; only a currently observed yard renews.
            if (observedYard) b.overwatchUntil=ai.frame+SeaShorelines::Interval(sectors[b.sector]);
            if (watching<scouts-1 && ai.frame<b.overwatchUntil) {
                if (!b.overwatch) GenericHelpers::LogUtil("[SEA][ScoutOverwatch] id="+b.id+" sector="+b.sector,1);
                b.overwatch=true; b.until=ai.frame+SeaShorelines::Interval(sectors[b.sector]); return;
            }
        }
        b.overwatch=false;
        if ((b.mode==0 || b.mode==2) && SeaMath::RetainScoutTravel(
            b.route !is null && !b.route.IsDead() && u.task is b.route,
            ai.frame<b.until, ThreatSafe(here), Safe(u,b.goal,b.body),
            b.mode!=2 && scout && (arrived || routeEnded))) return;
        Count(b.mode<0 ? 0 : (b.route is null || b.route.IsDead() || u.task !is b.route) ? 3 : arrived ? 1 : 2);
        if (b.sector>=0 && sectors[b.sector].owner==b.id) sectors[b.sector].owner=-1;
        b.sector=-1;
        if (scout) for (uint i=0;i<SeaLayout::berths.length();++i) {
            SeaLayout::Berth@ berth=SeaLayout::berths[i];
            if (berth.slot<0 || berth.active || berth.retired
                || aiTerrainMgr.GetReservationState(berth.slot)!=0) continue;
            CCircuitDef@ d=ai.GetCircuitDef(berth.name);
            // Reuse the existing bounded berth pass and scout leases. A full
            // bank can need a surveyed platform/amphibious overflow site too;
            // production must never relax the forward fog buffer to spend it.
            const bool overflow=SeaEconomy::capacityPressure && SeaFactories::FactoryAllowed(d,true);
            const bool technology=UnitHelpers::IsT2Shipyard(berth.name) && SeaEconomy::TechReady(d,true);
            if ((!overflow && !technology) || SeaLayout::VisibleBuffer(d,berth.centre,berth.facing)) continue;
            const AIFloat3 goal=SeaLayout::SurveyPoint(d,berth.centre,berth.facing);
            bool leased=false;
            for (uint j=0;j<boats.length();++j) if (boats[j] !is b && boats[j].mode==2
                && ai.frame<boats[j].until && MapHelpers::SqDist(boats[j].goal,goal)<cell*cell) { leased=true; break; }
            if (leased || !Safe(u,goal,b.body)) continue;
            if (SurveyOrder(b,u,goal)) {
                b.mode=2; b.goal=goal; b.until=ai.frame+Global::RoleSettings::Sea::HarborSurveySeconds*SECOND;
                b.route.SetSeaTarget(-1);
                GenericHelpers::LogUtil("[SEA][HarborScout] id="+b.id+" berth="+berth.key,1); return;
            }
        }
        // Lease distinct sectors; oldest first with travel cost as tie-breaker.
        // Search cost is bounded by Grid, and no index survives a unit transfer.
        int best=-1; float score=-1e30f;
        for (uint i=0;i<sectors.length();++i) {
            Sector@ s=sectors[i];
            if (s.body!=b.body || (s.owner>=0 && s.owner!=b.id)) continue;
            if (scout) {
                bool reserved=false;
                const float separation=Global::RoleSettings::Sea::ScoutShoreSeparation;
                // O(S*U) only on assignment; do not give neighboring shoreline
                // cells to several boats merely because their cell IDs differ.
                for (uint j=0;j<boats.length();++j) {
                    Boat@ other=boats[j];
                    if (other is b || other.body!=b.body || other.sector<0 || other.route is null || other.route.IsDead()) continue;
                    if (MapHelpers::SqDist(s.pos,other.goal)<separation*separation) { reserved=true; break; }
                }
                if (reserved) continue;
            }
            if (int(i)==b.failedSector && ai.frame<b.failedUntil) continue;
            // Credit actual nearby LOS, not every tiny grid destination. This
            // shares discoveries and skips already-visible neighboring cells,
            // reducing MOVE churn without delaying a newly observed threat.
            // The distance prefilter bounds LOS callbacks to the local disc;
            // this runs inside the existing renewal scan, never per frame.
            if (scout && MapHelpers::SqDist(here,s.pos)<visibleDistanceSquared
                && aiTerrainMgr.IsAreaVisible(s.pos,cell*.4f)) s.visited=ai.frame;
            // Dedicated AA covers the friendly coast; expendable T1 scouts
            // alone explore the whole connected sea.
            if (!Scout(u.circuitDef) && MapHelpers::SqDist(s.pos,Global::Map::StartPos)>2400*2400) continue;
            // Newly surveyed coasts cool down so the nearest shore does not
            // win forever. Unvisited enemy shores precede open-sea coverage.
            const int interval=Global::RoleSettings::Sea::CoordinatedFleet ? SeaShorelines::Interval(s) : Global::RoleSettings::Sea::ScoutPatrolSeconds*SECOND;
            if (scout && s.visited>=0 && ai.frame-s.visited<interval) continue;
            const float travel=sqrt(MapHelpers::SqDist(here,s.pos));
            const float rank=Global::RoleSettings::Sea::CoordinatedFleet && scout
                ? SeaMath::SurveyPriority(SeaShorelines::ScoutPriority(s),s.visited<0,s.visited<0 ? 0 : ai.frame-s.visited,interval,
                    travel+s.enemyDistance*Global::RoleSettings::Sea::ShoreEnemyDistanceWeight,
                    Global::RoleSettings::Sea::ShoreTravelScoreScale)
                : SeaMath::ScoutScore(scout && s.shore,s.visited<0,ai.frame-s.visited,travel);
            if (rank<=score || !Safe(u,s.pos,b.body)) continue;
            score=rank; best=int(i);
        }
        if (best<0) { b.retry=ai.frame+5*SECOND; return; }
        Sector@ s=sectors[best]; s.owner=b.id;
        if (b.sector!=best) b.overwatchSector=-1;
        b.sector=best; b.goal=s.pos;
        if (!s.shore && !s.scoutShore && SeaInvasion::Active() && scout) {
            // Arriving matters, not assigning a sector. Fill actual legal
            // LOS/sonar holes; this native O(W_body) scan runs only at renewal.
            AIFloat3 hole=aiBattle.GetWaterScoutGoal(b.body,Global::RoleSettings::Sea::InvasionSurveySeconds*SECOND,here,b.id);
            // A coarse native visibility hole can remain behind a shoreline
            // occluder while the boat is already within its arrival disc.
            // Reissuing that same goal every census neither explores nor
            // improves LOS; keep the distinct leased sector in that case.
            if (hole.x>=0 && MapHelpers::SqDist(here,hole)>sight*sight && Safe(u,hole,b.body)) {
                b.goal=hole;
                // A native survey hole is not evidence of visiting this grid
                // sector. Release its lease and leave its age unchanged.
                s.owner=-1; b.sector=-1;
            }
        }
        // MOVE to the sector before queuing its patrol. Including the current
        // base position in that loop would make every scout revisit the yard.
        array<AIFloat3> points;
        if (scout) points.insertLast(b.goal);
        for (int i=0;!scout && i<3;++i) {
            const float a=float(i)*2.094395f;
            AIFloat3 p(b.goal.x+cos(a)*cell*.3f,0,b.goal.z+sin(a)*cell*.3f);
            if (Safe(u,p,b.body)) points.insertLast(p);
        }
        if (points.length()==0) points.insertLast(b.goal);
        if (scout ? SurveyOrder(b,u,b.goal) : Order(b,u,points,true)) {
            b.route.SetSeaTarget(-1); b.mode=0; b.target=-1;
            b.until=ai.frame+(scout ? AiMax(Global::RoleSettings::Sea::ShoreSurveySeconds,int(sqrt(MapHelpers::SqDist(here,b.goal))/AiMax(1.0f,u.circuitDef.speed))+15) : Global::RoleSettings::Sea::ScoutPatrolSeconds)*SECOND;
            GenericHelpers::LogUtil("[SEA][Patrol] id="+b.id+" sector="+best+" shore="+s.shore+" goal="+int(b.goal.x)+","+int(b.goal.z),1);
        } else if (scout) {
            // A safe endpoint does not prove a safe route around a peninsula.
            // Reject only this boat's candidate; another hull may reach it.
            b.failedSector=best; b.failedUntil=ai.frame+Global::RoleSettings::Sea::ScoutFailedSectorSeconds*SECOND;
            s.owner=-1; b.sector=-1; b.until=0;
        }
    }
    void Tick() {
        if (!Global::RoleSettings::Sea::FleetOperations) { Leave(); return; }
        Report();
        Grid(); Contacts(); navalSafety.deleteAll(); seaContacts=aiBattle.GetSeaForceCount();
        if (Global::RoleSettings::Sea::CoordinatedFleet) SeaShorelines::Tick();
        // Build occupancy once; monotonically scan free slots per basin.
        // Birth bursts are O(U), not one full boat scan per new hull.
        dictionary usedSlots;
        for (uint i=0;i<raids.length();++i) raids[i].nextSlot=0;
        for (uint i=0;i<boats.length();++i) if (boats[i].slot>=0) usedSlots.set(""+boats[i].body+":"+boats[i].slot,true);
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaCombat::owned[i]); if (!Available(u)) continue;
            const int body=aiBattle.WaterBody(u.GetPos(ai.frame),false); if (body<0) continue;
            int index=-1;
            if (!boatIndex.get(""+u.id,index)) {
                index=int(boats.length()); Boat@ fresh=Boat(); fresh.id=u.id; fresh.body=body;
                // Lowest free slot preserves survivors' spacing after losses.
                if (AA(u.circuitDef)) {
                    Raid@ basin=Basin(body);
                    while (usedSlots.exists(""+body+":"+basin.nextSlot)) ++basin.nextSlot;
                    fresh.slot=basin.nextSlot++;
                    usedSlots.set(""+body+":"+fresh.slot,true);
                }
                boats.insertLast(fresh); boatIndex.set(""+u.id,index);
            }
            Boat@ b=boats[index]; b.seen=ai.frame; b.body=body;
            Raid@ r=Basin(body);
            if (AA(u.circuitDef)) {
                r.range=AiMin(r.range,u.circuitDef.GetMaxRange(0)); // AIR layer, not surface missile range
                r.speed=AiMin(r.speed,u.circuitDef.speed);
                r.distance=AiMin(r.distance,sqrt(MapHelpers::SqDist(u.GetPos(ai.frame),r.pos)));
            }
        }
        uint live=0;
        for (uint i=0;i<boats.length();++i) {
            Boat@ b=boats[i];
            if (b.seen!=ai.frame) { Release(b); continue; }
            @boats[live++]=b;
        }
        boats.resize(live); boatIndex.deleteAll();
        for (uint i=0;i<boats.length();++i) boatIndex.set(""+boats[i].id,int(i));
        SeaScoutRaids::Update();
        for (uint i=0;i<raids.length();++i) {
            Raid@ r=raids[i]; if (!r.present) continue;
            // Use the nearest screen member, not the commander's start. A
            // plane already in AA reach needs fire now, not a far-ahead chase.
            const float lead=SeaMath::InterceptLead(r.distance,r.speed,r.range,Global::RoleSettings::Sea::NavalAAInterceptSeconds);
            AIFloat3 predicted=Spam::_Clamp(AIFloat3(r.pos.x+r.velocity.x*lead,0,r.pos.z+r.velocity.z*lead));
            if (r.centre.x<=0 || MapHelpers::SqDist(r.centre,predicted)>r.range*r.range*.16f) {
                r.centre=predicted;
                float dx=r.velocity.x,dz=r.velocity.z;
                if (dx*dx+dz*dz<1) { dx=Global::Map::StartPos.x-r.pos.x; dz=Global::Map::StartPos.z-r.pos.z; }
                const float length=AiMax(1.0f,sqrt(dx*dx+dz*dz));
                r.direction=AIFloat3(dx/length,0,dz/length);
            }
        }
        dictionary claimed;
        for (uint i=0;i<boats.length();++i) {
            Boat@ b=boats[i]; CCircuitUnit@ u=ai.GetTeamUnit(b.id); if (!Available(u)) continue;
            Raid@ r=Basin(b.body);
            const bool alarm=Global::RoleSettings::Sea::HybridScoutAirResponse && !Scout(u.circuitDef) && AA(u.circuitDef)
                && ai.frame-r.seen<Global::RoleSettings::Sea::NavalAAContactMemorySeconds*SECOND;
            if (!alarm) {
                if (Scout(u.circuitDef) && Evade(b,u)) continue;
                if (!SeaScoutRaids::Control(b,u)) Patrol(b,u);
                continue;
            }
            const float spacing=AiMax(96.0f,SeaMath::AASpacing(Global::RoleSettings::Sea::NavalAAFormationSpacing,r.range));
            const float dx=r.direction.x,dz=r.direction.z;
            const int columns=Global::RoleSettings::Sea::NavalAAColumns;
            AIFloat3 goal=u.GetPos(ai.frame); float best=1e30f; string bestKey;
            // Fixed candidate budget; never collapse invalid coastal slots to
            // one shared centre. All candidates use the SAME rotated integer
            // grid: distinct keys therefore guarantee at least spacing elmos
            // between assigned destinations, unlike rounded world coordinates.
            for (int j=0;j<49;++j) {
                const int col=SeaMath::AAColumn(b.slot,columns)+j%7-3;
                const int row=SeaMath::AARow(b.slot,columns)+j/7-3;
                const float ox=float(j%7-3)*spacing, oz=float(j/7-3)*spacing;
                AIFloat3 p(r.centre.x-dz*col*spacing+dx*row*spacing,0,r.centre.z+dx*col*spacing+dz*row*spacing);
                const string key=""+b.body+":"+col+":"+row;
                const float dist=ox*ox+oz*oz;
                if (dist>=best || claimed.exists(key) || !InterceptionSite(u,p,b.body,key)) continue;
                best=dist; goal=p; bestKey=key;
            }
            if (bestKey.length()==0) {
                // An unreachable coast/hostile fleet must not pin reinforcements
                // in their factory-exit ball. Keep individual safe coverage,
                // with immediate AA fire, until a screen position is available.
                Patrol(b,u); b.target=FireTarget(b,u);
                if (b.route !is null && !b.route.IsDead()) b.route.SetSeaTarget(b.target);
                continue;
            }
            claimed.set(bestKey,true);
            if (b.sector>=0 && sectors[b.sector].owner==b.id) sectors[b.sector].owner=-1;
            b.sector=-1;
            if (b.mode!=1 || MapHelpers::SqDist(goal,b.goal)>96*96 || b.route is null || b.route.IsDead()) {
                array<AIFloat3> points={u.GetPos(ai.frame),goal};
                if (Order(b,u,points,false)) {
                    b.mode=1; b.goal=goal;
                    GenericHelpers::LogUtil("[SEA][AAFormation] id="+b.id+" body="+b.body+" slot="+b.slot+" target="+r.target+" goal="+int(goal.x)+","+int(goal.z)+" unit="+u.circuitDef.GetName(),1);
                }
            }
            b.target=FireTarget(b,u);
            if (b.route !is null && !b.route.IsDead()) b.route.SetSeaTarget(b.target);
        }
    }
}
