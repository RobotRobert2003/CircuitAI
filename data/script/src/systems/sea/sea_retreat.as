// Publish optional native withdrawal waypoints, never take over RETREAT tasks.
// One local bucket index per SEA census: O(groups + ships + local candidates),
// with dense-bucket worst case explicit. Native code revalidates anchor/expiry.
namespace SeaRetreat {
    const float BehindLine=192.0f;
    const float WithdrawalSpacing=48.0f;
    const int WithdrawalSlots=9;
    const int WaypointSeconds=45;
    string Cell(int body,int x,int z) { return ""+body+":"+x+":"+z; }
    // D-346: forward repair points. A damaged naval ship (below
    // ForwardRepairHealth, or already retreating) is given a point just outside
    // the reach of every known enemy near it, plus ForwardRepairBuffer, on the
    // same water body and never farther from home than the ship is now. The
    // native RETREAT task stops there and waits to be healed (idle heal plus
    // the mobile repair task) instead of sailing to base; it falls back to
    // the base when the point is threatened or expires.
    // Cost per census: O(contacts) to bucket enemies by 1024-elmo cell, then
    // for each damaged ship O(local contacts x 5 candidate directions).
    const float HoldCell=1024.0f;
    // Each ship's current hold, reused while it stays clear: a point moved
    // every census made the RETREAT task re-path every few frames (D-348 test:
    // ~2.7x the chase-phase orders). Keyed by unit id, pruned with the ship.
    dictionary holds;
    bool Clear(const AIFloat3 &in p, const array<float>@ local, float buffer) {
        for (uint k=0;k+2<local.length();k+=3) {
            const float r=local[k+2]+buffer;
            if (MapHelpers::SqDist(p,AIFloat3(local[k],0,local[k+1]))<r*r) return false;
        }
        return true;
    }
    // D-349: the repair points for the widget's Tactics overlay, as the
    // state key "searepair": 1;<frame>;<ship>,<x>,<z>,<retreating 0/1>;...
    // Positions rounded to 32 elmos; published at most every 2 s and only
    // when the text changes (holds are stable, so writes are rare).
    string repairPublished; int repairNext=0;
    array<string> repairEntries;
    void Note(CCircuitUnit@ ship, const AIFloat3 &in p, bool retreating) {
        repairEntries.insertLast(""+ship.id+","+(int(p.x/32)*32)+","+(int(p.z/32)*32)+","+(retreating ? 1 : 0));
    }
    int RetreatingToPoint() {
        int n=0;
        for (uint i=0;i<repairEntries.length();++i) if (repairEntries[i].findLast(",1")==int(repairEntries[i].length())-2) ++n;
        return n;
    }
    void PublishRepair() {
        if (ai.frame<repairNext) return;
        repairNext=ai.frame+2*SECOND;
        repairEntries.sortAsc();
        string text="1";
        for (uint i=0;i<repairEntries.length();++i) text+=";"+repairEntries[i];
        if (text==repairPublished) return;
        repairPublished=text;
        WidgetLink::SetState("searepair",WidgetLink::Line("searepair",text));
    }
    void ForwardHolds() {
        repairEntries.resize(0);
        if (!Global::RoleSettings::Sea::ForwardRepair) { PublishRepair(); return; }
        // Prune holds of dead ships once the table outgrows the fleet: O(H).
        if (holds.getSize()>SeaCombat::owned.length()*2+16) {
            array<string>@ keys=holds.getKeys();
            for (uint k=0;k<keys.length();++k) if (ai.GetTeamUnit(int(parseInt(keys[k]))) is null) holds.delete(keys[k]);
        }
        dictionary enemies;
        const int contacts=aiBattle.GetSeaForceCount();
        for (int i=0;i<contacts;++i) {
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&1)!=0) continue;
            const int defId=aiBattle.GetSeaForceDefId(i);
            const CCircuitDef@ d=defId>=0 ? ai.GetCircuitDef(defId) : null;
            float reach=d is null ? Global::RoleSettings::Sea::UnknownContactRange
                : AiMax(d.GetMaxRange(1),d.GetMaxRange(2));
            if (reach<=0) continue;
            const AIFloat3 p=aiBattle.GetSeaForcePos(i);
            const string key=Cell(aiBattle.GetSeaForceBody(i),int(p.x/HoldCell),int(p.z/HoldCell));
            array<float>@ bucket;
            if (!enemies.get(key,@bucket) || bucket is null) { @bucket=array<float>(); enemies.set(key,@bucket); }
            bucket.insertLast(p.x); bucket.insertLast(p.z); bucket.insertLast(reach);
        }
        const float buffer=Global::RoleSettings::Sea::ForwardRepairBuffer;
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ ship=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (ship is null || !ship.circuitDef.IsMobile() || ship.circuitDef.IsAbleToFly() || ship.circuitDef.GetBuildSpeed()>0) continue;
            const bool retreating=ship.task !is null && ship.task.GetType()==int(Task::Type::RETREAT);
            if (!retreating && ship.GetHealthPercent()>=Global::RoleSettings::Sea::ForwardRepairHealth) continue;
            const AIFloat3 position=ship.GetPos(ai.frame);
            const int body=aiBattle.WaterBody(position,false);
            if (body<0) continue;
            // Local enemies (3x3 cells) and the one whose reach is closest to us.
            array<float> local;
            const int cx=int(position.x/HoldCell), cz=int(position.z/HoldCell);
            float worst=1e30f; AIFloat3 from(-1,0,-1);
            for (int dz=-1;dz<=1;++dz) for (int dx=-1;dx<=1;++dx) {
                array<float>@ bucket;
                if (!enemies.get(Cell(body,cx+dx,cz+dz),@bucket) || bucket is null) continue;
                for (uint k=0;k+2<bucket.length();k+=3) {
                    local.insertLast(bucket[k]); local.insertLast(bucket[k+1]); local.insertLast(bucket[k+2]);
                    const float gap=sqrt(MapHelpers::SqDist(position,AIFloat3(bucket[k],0,bucket[k+1])))-bucket[k+2];
                    if (gap<worst) { worst=gap; from=AIFloat3(bucket[k],0,bucket[k+1]); }
                }
            }
            const string id=""+ship.id;
            if (from.x<0) { if (!retreating) { ship.ClearRetreatHold(); holds.delete(id); } continue; }
            // Keep a previous hold while it is still clear of every local reach.
            AIFloat3 previous;
            if (holds.get(id,previous) && Clear(previous,local,buffer)
                && aiBattle.SurfThreat(previous)<=aiBattle.SurfThreat(position)) {
                ship.SetRetreatHold(previous,ai.frame+Global::RoleSettings::Sea::ForwardRepairSeconds*SECOND);
                Note(ship,previous,retreating);
                continue;
            }
            // Already clear of every reach plus the buffer: hold right here.
            if (Clear(position,local,buffer)) {
                holds.set(id,position);
                ship.SetRetreatHold(position,ai.frame+Global::RoleSettings::Sea::ForwardRepairSeconds*SECOND);
                Note(ship,position,retreating);
                continue;
            }
            AIFloat3 away=position-from;
            float length=sqrt(away.x*away.x+away.z*away.z);
            if (length<1) { away=Global::Map::StartPos-position; length=AiMax(1.0f,sqrt(away.x*away.x+away.z*away.z)); }
            away=away/length;
            const float homeSq=MapHelpers::SqDist(position,Global::Map::StartPos);
            bool found=false; AIFloat3 hold;
            const array<float> turns={0.0f,0.5236f,-0.5236f,1.0472f,-1.0472f};
            for (uint t=0;t<turns.length() && !found;++t) {
                const float c=cos(turns[t]), s=sin(turns[t]);
                const AIFloat3 dir(away.x*c-away.z*s,0,away.x*s+away.z*c);
                // Step out until clear of every local enemy's reach plus buffer.
                for (float step=AiMax(0.0f,worst<0 ? -worst : 0.0f)+buffer*.5f;step<=Global::RoleSettings::Sea::ForwardRepairMaxDistance;step+=128.0f) {
                    const AIFloat3 p=position+dir*step;
                    if (!ProductionMath::Inside(p.x,p.z,float(AiTerrainWidth()),float(AiTerrainHeight()),0)) break;
                    if (aiBattle.Height(p)>-8.0f || aiBattle.WaterBody(p,false)!=body) break;
                    bool clear=true;
                    for (uint k=0;k+2<local.length() && clear;k+=3) {
                        const float r=local[k+2]+buffer;
                        if (MapHelpers::SqDist(p,AIFloat3(local[k],0,local[k+1]))<r*r) clear=false;
                    }
                    if (!clear) continue;
                    if (MapHelpers::SqDist(p,Global::Map::StartPos)>homeSq+1.0f) break; // never farther from home
                    if (aiBattle.SurfThreat(p)>aiBattle.SurfThreat(position) || !aiTerrainMgr.CanReachAt(ship,p,128)) break;
                    hold=p; found=true; break;
                }
            }
            if (found) { holds.set(id,hold); ship.SetRetreatHold(hold,ai.frame+Global::RoleSettings::Sea::ForwardRepairSeconds*SECOND); Note(ship,hold,retreating); }
            else if (!retreating) { ship.ClearRetreatHold(); holds.delete(id); }
        }
        PublishRepair();
    }
    void Publish() {
        ForwardHolds();
        dictionary cells;
        const float radius=AiMax(1.0f,Global::RoleSettings::Sea::SubmarineRetreatRadius);
        for (uint i=0;i<SeaOperations::groups.length();++i) {
            SeaOperations::Cohort@ group=SeaOperations::groups[i];
            if (group.ids.length()==0 || !SeaSubmarines::Handles(ai.GetCircuitDef(group.defId))) continue;
            const string key=Cell(group.body,int(group.centre.x/radius),int(group.centre.z/radius));
            array<int>@ bucket;
            if (!cells.get(key,@bucket) || bucket is null) { @bucket=array<int>(); cells.set(key,@bucket); }
            bucket.insertLast(int(i));
        }
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ ship=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (ship is null || !ship.circuitDef.IsMobile() || ship.circuitDef.IsAbleToFly()
                || ship.circuitDef.GetBuildSpeed()>0 || SeaSubmarines::Handles(ship.circuitDef)) continue;
            // Explicit fixed-size naval roster avoids changing amphibious land
            // invasion retreats merely because those units entered water.
            bool naval=false;
            for (uint hull=0;hull<SeaCombat::roster.length();++hull)
                if (SeaCombat::roster[hull].def is ship.circuitDef) { naval=true; break; }
            if (!naval) continue;
            if (ship.task !is null && (ship.task.GetType()==int(Task::Type::RETREAT)
                || ship.task.GetType()==int(Task::Type::PLAYER) || ship.task.IsExternalControlled())) continue;
            const AIFloat3 position=ship.GetPos(ai.frame);
            const int body=aiBattle.WaterBody(position,false);
            if (body<0) continue;
            const int x=int(position.x/radius), z=int(position.z/radius);
            int anchor=-1; AIFloat3 goal; float nearest=radius*radius;
            const float currentThreat=aiBattle.SurfThreat(position);
            for (int dz=-1;dz<=1;++dz) for (int dx=-1;dx<=1;++dx) {
                array<int>@ bucket;
                if (!cells.get(Cell(body,x+dx,z+dz),@bucket) || bucket is null) continue;
                for (uint candidate=0;candidate<bucket.length();++candidate) {
                    SeaOperations::Cohort@ group=SeaOperations::groups[bucket[candidate]];
                    // Cohorts have a bounded membership. Select a real nearby
                    // anchor so wide lines do not fail the native drift check.
                    CCircuitUnit@ closest=null; float anchorDistance=radius*radius;
                    for (uint member=0;member<group.ids.length();++member) {
                        CCircuitUnit@ submarine=ai.GetTeamUnit(group.ids[member]);
                        if (submarine is null) continue;
                        const float separation=MapHelpers::SqDist(position,submarine.GetPos(ai.frame));
                        if (separation<anchorDistance) { anchorDistance=separation; @closest=submarine; }
                    }
                    if (closest is null) continue;
                    const AIFloat3 anchorPosition=closest.GetPos(ai.frame);
                    AIFloat3 direction=Global::Map::StartPos-anchorPosition;
                    const float length=AiMax(1.0f,sqrt(direction.x*direction.x+direction.z*direction.z));
                    const AIFloat3 tangent(-direction.z/length,0,direction.x/length);
                    const float offset=float(ship.id%WithdrawalSlots-WithdrawalSlots/2)*WithdrawalSpacing;
                    const AIFloat3 point=anchorPosition+direction*(BehindLine/length)+tangent*offset;
                    // WaterBody clamps its cell lookup to the map; it cannot
                    // validate a world position. Offset edge anchors may leave
                    // the map, whereas CanReachAt requires a valid sector.
                    // Reject before terrain/threat callbacks (O(1), no query or
                    // allocation); retain normal retreat when no valid hint fits.
                    if (!ProductionMath::Inside(point.x,point.z,float(AiTerrainWidth()),float(AiTerrainHeight()),0)) continue;
                    const float distance=MapHelpers::SqDist(position,point);
                    // Withdraw toward friendly depth, not a more forward sub.
                    if (distance>=nearest || MapHelpers::SqDist(point,Global::Map::StartPos)>=MapHelpers::SqDist(position,Global::Map::StartPos)
                        || aiBattle.SurfThreat(point)>currentThreat || aiBattle.WaterBody(point,false)!=body) continue;
                    nearest=distance; goal=point; anchor=closest.id;
                }
            }
            if (anchor>=0 && !ProductionMath::Inside(goal.x,goal.z,float(AiTerrainWidth()),float(AiTerrainHeight()),0)) {
                Invariants::Violation("INV-188","SEA","retreat waypoint outside map");
                anchor=-1;
            }
            if (anchor>=0 && !aiTerrainMgr.CanReachAt(ship,goal,128)) anchor=-1;
            ship.SetRetreatWaypoint(goal,anchor,ai.frame+WaypointSeconds*SECOND);
        }
    }
}
