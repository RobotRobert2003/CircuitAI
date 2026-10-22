#include "../world/lanes.as"
#include "../../helpers/math/amphibious_math.as"
#include "amphibious_beaches.as"
#include "amphibious_formation.as"

// D-158: role-scoped waves. Native code supplies geometry and commands only.
namespace AmphibiousOps {
    enum Phase { ASSEMBLE, ADVANCE, SECURE, HOLD, GUARD }
    class Wave {
        int serial = 0, kind = 0, phase = ASSEMBLE, born = 0, changed = 0, quiet = 0, retry = 0;
        int launched = 0, region = -1, checked = 0;
        bool secured = false;
        AIFloat3 beachGoal(-1,0,-1);
        array<Id> members;
        CRouteTask@ task;
        AIFloat3 anchor, goal, destination;
        array<AIFloat3> leg;
        array<Id> slotIds;
        array<AIFloat3> slots;
        int formationAt = -100000;
    }
    array<Wave@> waves;
    bool loaded = false, enabled = true;
    int nextSerial = 0, lastTick = -100000, maxWaves = 6, telSize = 6, marSize = 4, minimum = 3;
    int assembleSeconds = 90, secureSeconds = 18, raidSeconds = 5, retrySeconds = 20, stallSeconds = 180;
    float quorum = 0.8f, radius = 240.0f, secureRadius = 1000.0f, landCost = 2.5f, waterCost = 1.0f;
    float threatWeight = 8.0f, maxWaterThreat = 0.0f, minMetal = 200.0f;
    float landingInland = 128.0f, landingWidth = 160.0f, stagingDetour = 1.35f;
    float telMinMetal = 80.0f, telReserve = 300.0f, telMetalShare = 0.15f, telEnergyShare = 0.2f;
    int guardSize = 3, guardGroups = 2, telLimit = 18, telNext = 0;
    float telWaterCost = 6.0f, shoreSpacing = 192.0f, attackSpacing = 96.0f;

    void Load() {
        if (loaded) return;
        loaded = true;
        enabled = aiSetupMgr.ConfigBool("lanes/amph_enabled", true);
        maxWaves = AiMax(1, AiMin(12, aiSetupMgr.ConfigInt("lanes/amph_max_waves", 6)));
        telSize = AiMax(1, aiSetupMgr.ConfigInt("lanes/amph_telchine_wave", 6));
        marSize = AiMax(1, aiSetupMgr.ConfigInt("lanes/amph_marauder_wave", 4));
        minimum = AiMax(1, aiSetupMgr.ConfigInt("lanes/amph_min_wave", 3));
        assembleSeconds = AiMax(10, aiSetupMgr.ConfigInt("lanes/amph_assemble_seconds", 90));
        secureSeconds = AiMax(1, aiSetupMgr.ConfigInt("lanes/amph_secure_seconds", 18));
        raidSeconds = AiMax(1, aiSetupMgr.ConfigInt("lanes/amph_raid_seconds", 5));
        retrySeconds = AiMax(5, aiSetupMgr.ConfigInt("lanes/amph_retry_seconds", 20));
        stallSeconds = AiMax(30, aiSetupMgr.ConfigInt("lanes/amph_stall_seconds", 180));
        quorum = AiMax(0.5f, AiMin(1.0f, aiSetupMgr.ConfigFloat("lanes/amph_quorum", 0.8f)));
        radius = AiMax(96.0f, AiMin(400.0f, aiSetupMgr.ConfigFloat("lanes/amph_gather_radius", 240.0f)));
        secureRadius = AiMax(radius, aiSetupMgr.ConfigFloat("lanes/amph_secure_radius", 1000.0f));
        landCost = AiMax(1.0f, aiSetupMgr.ConfigFloat("lanes/amph_land_cost", 2.5f));
        waterCost = AiMax(0.1f, aiSetupMgr.ConfigFloat("lanes/amph_water_cost", 1.0f));
        threatWeight = AiMax(0.0f, aiSetupMgr.ConfigFloat("lanes/amph_threat_weight", 8.0f));
        maxWaterThreat = AiMax(0.0f, aiSetupMgr.ConfigFloat("lanes/amph_max_water_threat", 0.0f));
        minMetal = AiMax(0.0f, aiSetupMgr.ConfigFloat("lanes/amph_min_metal", 200.0f));
        landingInland = AiMax(64.0f, aiSetupMgr.ConfigFloat("lanes/amph_landing_inland", 128.0f));
        landingWidth = AiMax(64.0f, aiSetupMgr.ConfigFloat("lanes/amph_landing_half_width", 160.0f));
        stagingDetour = AiMax(1.0f, aiSetupMgr.ConfigFloat("lanes/amph_staging_detour", 1.35f));
        telMinMetal = AiMax(0.0f,aiSetupMgr.ConfigFloat("lanes/amph_telchine_min_metal",80.0f));
        telReserve = AiMax(0.0f,aiSetupMgr.ConfigFloat("lanes/amph_telchine_reserve_metal",300.0f));
        telMetalShare = AiMax(0.01f,AiMin(1.0f,aiSetupMgr.ConfigFloat("lanes/amph_telchine_metal_share",0.15f)));
        telEnergyShare = AiMax(0.01f,AiMin(1.0f,aiSetupMgr.ConfigFloat("lanes/amph_telchine_energy_share",0.2f)));
        guardSize = AiMax(1,aiSetupMgr.ConfigInt("lanes/amph_guard_size",3));
        guardGroups = AiMax(0,AiMin(4,aiSetupMgr.ConfigInt("lanes/amph_guard_groups",2)));
        telLimit = AiMax(telSize,aiSetupMgr.ConfigInt("lanes/amph_telchine_limit",18));
        telWaterCost=AiMax(1.0f,aiSetupMgr.ConfigFloat("lanes/amph_telchine_water_cost",6.0f));
        shoreSpacing=AiMax(96.0f,AiMin(256.0f,aiSetupMgr.ConfigFloat("lanes/amph_shore_spacing",192.0f)));
        attackSpacing=AiMax(64.0f,AiMin(160.0f,aiSetupMgr.ConfigFloat("lanes/amph_attack_spacing",96.0f)));
    }
    bool Active() {
        Load();
        const bool tech = Global::AISettings::Role == AiRole::TECH, air = Global::AISettings::Role == AiRole::AIR;
        return enabled && Lanes::Enabled() && AmphibiousMath::Scope(tech, air, (tech && Global::RoleSettings::Tech::ExperimentalBuild)
            || (air && Global::RoleSettings::Air::ExperimentalBuild));
    }
    int Kind(const CCircuitDef@ d) {
        if (d is null) return -1;
        return d.GetName() == "legamph" ? 0 : (d.GetName() == "armmar" ? 1 : -1);
    }
    bool TelchineStartAllowed() {
        return AmphibiousMath::TelchineStartAllowed(Global::AISettings::Role == AiRole::TECH, Global::Map::LandLocked);
    }
    int Size(int kind) { return kind == 0 ? telSize : marSize; }
    int Guards() {
        int count=0;
        for (uint i=0;i<waves.length();++i) if (waves[i].phase==GUARD && waves[i].task !is null && !waves[i].task.IsDead()) ++count;
        return count;
    }
    CRouteTask@ NewRoute() {
        IUnitTask@ task=aiMilitaryMgr.Enqueue(TaskF::Route());
        CRouteTask@ route=cast<CRouteTask>(cast<IFighterTask>(task));
        if (route !is null) {
            route.SetTraversal(true,48.0f,false);
            route.SetHoldPosition(true);
            route.SetLanes(1,0,0);
        }
        return route;
    }
    void Say(Wave@ w, const string &in event) {
        GenericHelpers::LogUtil("[AMPH] wave=" + w.serial + " kind=" + w.kind + " " + event
            + " alive=" + w.members.length() + " at=(" + int(w.destination.x) + "," + int(w.destination.z) + ")", 1);
    }
    void Order(Wave@ w, const array<AIFloat3>& in points) {
        w.slotIds.resize(0); w.slots.resize(0); w.formationAt=-100000;
        w.leg = points;
        if (points.length() == 0 || w.task is null) return;
        w.destination = points[points.length()-1];
        w.task.SetRoute(points);
        w.changed = ai.frame;
    }
    int Arrived(Wave@ w) {
        int count = 0;
        for (uint i=0; i<w.members.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(w.members[i]);
            if (u !is null) {
                const AIFloat3 p = u.GetPos(ai.frame);
                // Once landed, allow modest dry dispersal from allied traffic.
                // Requiring the original tight circle forever stranded waves
                // pushed aside by another landing or a retained guard (D-160).
                const int slot=w.slotIds.find(w.members[i]);
                const float reach=slot>=0 ? 128.0f : (w.phase==SECURE ? radius*1.5f : radius);
                const AIFloat3 destination=slot>=0 ? w.slots[slot] : w.destination;
                if (aiBattle.Height(p) >= 0.0f && p.distance2D(destination) <= reach
                    && (w.phase!=SECURE || StrategicSites::LandAt(p)==w.region)) ++count;
            }
        }
        return count;
    }
    AIFloat3 Leader(Wave@ w) {
        // A living member nearest the destination; never average across sea/land.
        AIFloat3 result = w.destination;
        float best = 1.0e30f;
        for (uint i=0; i<w.members.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(w.members[i]);
            if (u is null) continue;
            const AIFloat3 p = u.GetPos(ai.frame);
            const float distance = p.distance2D(w.destination);
            if (distance < best) { best = distance; result = p; }
        }
        return result;
    }
    AIFloat3 Objective(Wave@ w, bool local) {
        AIFloat3 best(-1,0,-1);
        float score = -1.0f;
        for (int i=0; i<aiBattle.GetGroundContactCount(); ++i) {
            if (!local && !aiBattle.IsGroundContactEconomy(i)) continue;
            const AIFloat3 p = aiBattle.GetGroundContactPos(i);
            if (!local && !DryRoom(p)) continue;
            const float distance = p.distance2D(w.destination);
            if (local && (distance > secureRadius || StrategicSites::LandAt(p) != w.region)) continue;
            // Telchines clear their foothold; Marauders prefer valuable economy on the same landmass.
            if (!local && w.kind == 1 && w.region >= 0 && StrategicSites::LandAt(p) != w.region) continue;
            const float value = AmphibiousMath::TargetScore(w.kind == 1, aiBattle.IsGroundContactEconomy(i),
                aiBattle.GetGroundContactCost(i), distance, aiBattle.SurfThreat(p) * 0.02f);
            if (value > score) { score = value; best = p; }
        }
        return best;
    }
    AIFloat3 Goal(Wave@ w) {
        AIFloat3 goal = Objective(w, false);
        if (goal.x >= 0) return goal;
        array<AIFloat3> starts = Lanes::EnemyStarts();
        float nearest = 1.0e30f;
        for (uint i=0; i<starts.length(); ++i) {
            const float distance = w.destination.distance2D(starts[i]);
            if (distance < nearest && aiBattle.Height(starts[i]) >= 0) { nearest=distance; goal=starts[i]; }
        }
        return goal;
    }
    bool Recover(Wave@ w) {
        const AIFloat3 from=Leader(w);
        // After load/donation under water or on a coarse-grid cliff cell, find a dry
        // assembly point without pretending that the inaccessible origin has a route.
        AIFloat3 point(-1,0,-1); float best=1.0e30f;
        for (uint c=0;c<StrategicSites::land.length();++c) {
            if (StrategicSites::land[c]<0) continue;
            const AIFloat3 p=WaterTheatres::Pos(c);
            const float distance=p.distance2D(from);
            if (distance<best && DryRoom(p)) {best=distance;point=p;}
        }
        if (point.x<0) return false;
        // Only the small local engine escape is direct; the strategic route never snaps.
        if (best<=192.0f && w.kind!=0) {
            array<AIFloat3> points={point}; Order(w,points); w.anchor=point;
            return true;
        }
        array<AIFloat3>@ path=Travel(w,from,point,false);
        if (path is null || path.length()<2) return false;
        Order(w,path); w.anchor=point;
        Say(w,"recover dry assembly");
        return true;
    }
    AIFloat3 Staging(Wave@ w, const AIFloat3& in goal) {
        if (goal.x<0 || !StrategicSites::mapped) return goal;
        if (w.kind==0 && StrategicSites::LandAt(goal)==StrategicSites::LandAt(w.destination)) return goal;
        const float direct=w.destination.distance2D(goal);
        AIFloat3 chosen=goal;
        float best=1.0e30f;
        for (uint i=0;i<StrategicSites::islands.length();++i) {
            const AIFloat3 p=StrategicSites::islands[i].pos;
            if (StrategicSites::LandAt(p)==StrategicSites::LandAt(w.destination) || !DryRoom(p)) continue;
            const float onward=p.distance2D(goal), travel=p.distance2D(w.destination);
            if (onward+256.0f>=direct || travel<256.0f || travel+onward>direct*stagingDetour) continue;
            if (travel<best) { best=travel; chosen=p; }
        }
        return chosen;
    }
    bool DryRoom(const AIFloat3& in p) {
        array<AIFloat3> offsets={AIFloat3(0,0,0),AIFloat3(landingWidth,0,0),AIFloat3(-landingWidth,0,0),AIFloat3(0,0,landingWidth),AIFloat3(0,0,-landingWidth),
            AIFloat3(landingWidth,0,landingWidth),AIFloat3(-landingWidth,0,landingWidth),AIFloat3(landingWidth,0,-landingWidth),AIFloat3(-landingWidth,0,-landingWidth)};
        for (uint i=0;i<offsets.length();++i) {
            const AIFloat3 q=p+offsets[i];
            if (q.x<0 || q.z<0 || aiBattle.Height(q)<0 || !aiBattle.IsPassable(q,Lanes::AMPH)) return false;
        }
        return true;
    }
    AIFloat3 DryTarget(const AIFloat3& in target) {
        const AIFloat3 centre(float(int(target.x/64.0f)*64+32),0,float(int(target.z/64.0f)*64+32));
        if (DryRoom(centre)) return centre;
        AIFloat3 best(-1,0,-1); float distance=1.0e30f;
        for (int x=-256;x<=256;x+=64) for (int z=-256;z<=256;z+=64) {
            const AIFloat3 p=centre+AIFloat3(float(x),0,float(z));
            const float d=p.distance2D(target);
            if (d<distance && d<=300.0f && DryRoom(p)) {distance=d;best=p;}
        }
        return best;
    }
    array<AIFloat3>@ Travel(Wave@ w, const AIFloat3& in from, const AIFloat3& in to, bool dry, float threatLimit=-1.0f) {
        const float ceiling=threatLimit<0 ? maxWaterThreat : threatLimit;
        if (w.kind!=0) return aiBattle.GetTerrainRoute(from,to,dry?Lanes::BOT:Lanes::AMPH,dry?1.0f:landCost,waterCost,threatWeight,ceiling);
        CCircuitDef@ def=ai.GetCircuitDef("legamph");
        array<AIFloat3>@ route=aiBattle.GetUnitTerrainRoute(def,from,to,true,1,telWaterCost,threatWeight,ceiling);
        if (dry || (route !is null && route.length()>0)) return route;
        return aiBattle.GetUnitTerrainRoute(def,from,to,false,1,telWaterCost,threatWeight,ceiling);
    }
    array<AIFloat3>@ ApproachRoute(Wave@ w, const AIFloat3& in from, const AIFloat3& in target, bool dry) {
        array<AIFloat3>@ route=Travel(w,from,target,dry);
        if (w.kind!=0 || (route !is null && route.length()>0)) return route;
        // A strategic asset/coast point can be occupied. Keep the objective,
        // but find a reachable approach on the same dry component.
        const int region=StrategicSites::LandAt(target);
        for (int ring=64;ring<=256;ring+=64) {
            for (int x=-1;x<=1;++x) for (int z=-1;z<=1;++z) {
                if (x==0 && z==0) continue;
                const AIFloat3 p=target+AIFloat3(float(x*ring),0,float(z*ring));
                if (!DryRoom(p) || StrategicSites::LandAt(p)!=region) continue;
                @route=Travel(w,from,p,dry);
                if (route !is null && route.length()>0) return route;
            }
        }
        return null;
    }
    bool Plan(Wave@ w, const AIFloat3& in target, bool landOnly = false, bool regroup = false) {
        if (target.x < 0) return false;
        AIFloat3 aim=target;
        if (w.kind==0 && landOnly) {
            const AIFloat3 from=Leader(w);
            const float distance=from.distance2D(target);
            if (distance>1.0f) aim=target+(from-target)*(AiMin(280.0f,distance)/distance);
        }
        const AIFloat3 approach=DryTarget(aim);
        if (approach.x<0) return false;
        AIFloat3 from = Leader(w);
        if (regroup) {
            float far=-1;
            for (uint i=0;i<w.members.length();++i) {
                CCircuitUnit@ unit=ai.GetTeamUnit(w.members[i]);
                if (unit is null) continue;
                const AIFloat3 p=unit.GetPos(ai.frame);
                const float distance=p.distance2D(target);
                if (distance>far) {far=distance;from=p;}
            }
        }
        array<AIFloat3>@ path = ApproachRoute(w,from,approach,landOnly);
        if (path is null || path.length() < 2) {
            Say(w,"route rejected from="+int(from.x)+","+int(from.z)+" pass="+aiBattle.IsPassable(from,Lanes::AMPH)
                +" target="+int(target.x)+","+int(target.z)+" pass="+aiBattle.IsPassable(target,Lanes::AMPH));
            return false;
        }
        array<AIFloat3> leg;
        bool water = false, landing = false;
        float inland = 0.0f;
        for (uint i=0; i<path.length(); ++i) {
            const AIFloat3 p = path[i];
            if (landOnly && p.y<0.0f) return false;
            // Regroup on each intermediate dry component with room for the wave.
            leg.insertLast(p);
            if (p.y < 0.0f) {water = true; landing=false; inland=0;}
            if (AmphibiousMath::Landing(water, p.y)) {
                if (landing && i>0) inland += p.distance2D(path[i-1]);
                landing = true;
                // A wet shoreline sliver cannot physically hold a wave. Continue to
                // a usable dry patch rather than strand its trailing units underwater.
                if (inland >= landingInland && DryRoom(p)) break;
            }
        }
        if (leg.length() < 2 || !DryRoom(leg[leg.length()-1])) return false;
        w.goal = target;
        Order(w, leg);
        w.phase = ADVANCE;
        w.secured = false;
        w.quiet = ai.frame;
        if (w.kind==0) {
            float wet=0, dry=0;
            for (uint p=1;p<leg.length();++p) {
                const float distance=leg[p].distance2D(leg[p-1]);
                if (leg[p].y<0 || leg[p-1].y<0) wet+=distance; else dry+=distance;
            }
            Say(w,"travel dry="+int(dry)+" water="+int(wet));
            if (wet==0) AmphibiousFormation::Form(w);
        }
        Say(w, landOnly ? "exploit/clear" : "depart waypoints=" + leg.length());
        return true;
    }
    bool Onward(Wave@ w) {
        if (!AmphibiousMath::MayAdvance(w.phase==ASSEMBLE,w.secured)) return false;
        if (w.kind==0 && w.phase==ASSEMBLE && AmphibiousMath::GuardAllocation(int(w.members.length()),guardSize,minimum,Guards(),guardGroups)>0)
            w.beachGoal=AmphibiousBeaches::Best(w.destination);
        if (w.beachGoal.x>=0) {
            if (w.destination.distance2D(w.beachGoal)>radius && Plan(w,w.beachGoal)) return true;
            w.beachGoal=AIFloat3(-1,0,-1);
        }
        const AIFloat3 goal=Goal(w), stage=Staging(w,goal);
        // A blocked island must not veto a reachable safe final approach.
        return Plan(w,stage) || (stage.distance2D(goal)>64.0f && Plan(w,goal));
    }
    void CheckCrossing(Wave@ w) {
        if (ai.frame<w.checked+retrySeconds*SECOND) return;
        w.checked=ai.frame;
        const AIFloat3 here=Leader(w);
        int nearest=0; float distance=1.0e30f;
        for (uint i=0;i<w.leg.length();++i) {
            const float d=here.distance2D(w.leg[i]);
            if (d<distance) {distance=d;nearest=int(i);}
        }
        bool unsafe=false;
        for (uint i=uint(nearest);i<w.leg.length();++i)
            if (w.leg[i].y<0 && aiBattle.AmphThreat(w.leg[i])>maxWaterThreat) {unsafe=true;break;}
        if (!unsafe || Plan(w,w.destination)) return;
        // Threat appeared after departure: escape onto reachable dry ground instead of stopping submerged.
        AIFloat3 escape=w.anchor;
        if (here.distance2D(w.destination)<here.distance2D(escape)) escape=w.destination;
        array<AIFloat3>@ route=Travel(w,here,escape,false,1.0e9f);
        if (route !is null && route.length()>0 && route[route.length()-1].y>=0) {
            Order(w,route); Say(w,"emergency landfall: threat discovered");
        }
    }
    void Hold(Wave@ w, const string &in reason) {
        w.phase = HOLD; w.retry = ai.frame + retrySeconds * SECOND;
        Say(w, "hold " + reason);
    }
    array<AIFloat3>@ GuardRoute(Wave@ w, const AIFloat3& in target) {
        if (target.x<0 || !DryRoom(target) || StrategicSites::LandAt(target)!=w.region) return null;
        array<AIFloat3>@ route=ApproachRoute(w,Leader(w),target,true);
        if (route is null || route.length()==0) return null;
        for (uint i=0;i<route.length();++i)
            if (aiBattle.Height(route[i])<0 || StrategicSites::LandAt(route[i])!=w.region) return null;
        return route;
    }
    void RetainGuard(Wave@ w) {
        if (w.kind!=0 || !w.secured || int(waves.length())>=maxWaves) return;
        const int desired=AmphibiousMath::GuardAllocation(int(w.members.length()),guardSize,minimum,Guards(),guardGroups);
        if (desired==0) return;
        const AIFloat3 target=AmphibiousBeaches::Best(w.destination,w.region);
        array<AIFloat3>@ route=GuardRoute(w,target);
        if (route is null) return;
        // Transfer only dry, assembled members. A quorum may leave one straggler.
        array<Id> chosen;
        for (uint i=0;i<w.members.length() && int(chosen.length())<desired;++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(w.members[i]);
            if (u !is null && aiBattle.Height(u.GetPos(ai.frame))>=0
                && StrategicSites::LandAt(u.GetPos(ai.frame))==w.region
                && u.GetPos(ai.frame).distance2D(w.destination)<=radius*1.5f)
                chosen.insertLast(u.id);
        }
        if (int(chosen.length())!=desired) return;
        Wave@ g=Wave(); g.serial=++nextSerial; g.kind=0; g.phase=GUARD; g.region=w.region;
        g.anchor=target; g.destination=target; g.born=ai.frame; g.quiet=ai.frame; g.secured=true;
        @g.task=NewRoute(); if (g.task is null) return;
        Order(g,route); waves.insertLast(g);
        for (uint i=0;i<chosen.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(chosen[i]);
            if (u is null || !aiMilitaryMgr.TransferUnit(u,g.task)) continue;
            w.members.removeAt(w.members.find(chosen[i])); g.members.insertLast(chosen[i]);
        }
        if (g.members.length()==0) { g.task.Abort(); return; }
        if (int(w.members.length())<minimum) Invariants::Violation("INV-097","amph","guard split consumed assault minimum");
        w.beachGoal=AIFloat3(-1,0,-1);
        AmphibiousBeaches::Publish(g.serial,g.anchor);
        Say(g,"guard retained assets="+int(AmphibiousBeaches::Assets(target,g.region))+" assault="+w.members.length());
        AmphibiousFormation::Form(g);
    }
    void GuardTick(Wave@ w) {
        AmphibiousFormation::Maintain(w);
        for (uint p=0;p<w.leg.length();++p) if (aiBattle.Height(w.leg[p])<0)
            Invariants::Violation("INV-097","amph","guard route enters water");
        for (uint i=0;i<w.members.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(w.members[i]);
            if (u !is null && aiBattle.Height(u.GetPos(ai.frame))<0)
                Invariants::Violation("INV-097","amph","retained guard submerged id="+u.id);
        }
        if (ai.frame<w.checked+retrySeconds*SECOND) return;
        w.checked=ai.frame;
        const bool assets=AmphibiousBeaches::Assets(w.anchor,w.region)>0;
        if (assets) w.quiet=ai.frame;
        if (AmphibiousMath::GuardRelease(assets,ai.frame-w.quiet,60*SECOND,AmphibiousBeaches::Claimed(w.anchor,w.serial,true))) {
            AmphibiousBeaches::Publish(w.serial,w.anchor,true);
            w.phase=ASSEMBLE; w.born=ai.frame; w.beachGoal=AIFloat3(-1,0,-1); Say(w,"guard released"); return;
        }
        AmphibiousBeaches::Publish(w.serial,w.anchor);
        const AIFloat3 target=AmphibiousBeaches::Best(w.anchor,w.region,w.serial);
        // Retain the economic beachhead, rather than following a ship around an
        // island. Reposition locally only if a current naval approach is closer.
        if (target.x>=0 && target.distance2D(w.anchor)<=800.0f && target.distance2D(w.destination)>128.0f
            && AmphibiousBeaches::NavalDistance(target)+128.0f<AmphibiousBeaches::NavalDistance(w.destination)) {
            array<AIFloat3>@ route=GuardRoute(w,target);
            if (route !is null) { Order(w,route); Say(w,"guard dry reposition"); }
        }
        Say(w,"guard maintained assets="+int(AmphibiousBeaches::Assets(w.anchor,w.region)));
    }
    IUnitTask@ MilitaryTask(CCircuitUnit@ u) {
        if (!Active() || u is null || Kind(u.circuitDef) < 0) return null;
        const int kind = Kind(u.circuitDef);
        Wave@ wave;
        for (uint i=0; i<waves.length(); ++i) {
            Wave@ w=waves[i];
            if (w.task is null || w.task.IsDead()) continue;
            if (w.members.find(u.id)>=0) return w.task;
            if (w.kind==kind && w.phase==ASSEMBLE && int(w.members.length())<Size(kind)
                && u.GetPos(ai.frame).distance2D(w.anchor)<1200.0f) @wave=w;
        }
        if (wave is null) {
            // maxWaves bounds production; donated units still need safe command ownership.
            @wave=Wave(); wave.kind=kind; wave.serial=++nextSerial; wave.born=ai.frame;
            wave.anchor=DryTarget(u.GetPos(ai.frame));
            if (wave.anchor.x<0) wave.anchor=u.GetPos(ai.frame);
            wave.destination=wave.anchor;
            @wave.task=NewRoute();
            if (wave.task is null) return null;
            array<AIFloat3> hold={wave.anchor};
            Order(wave, hold);
            waves.insertLast(wave);
            Say(wave,"assemble");
        }
        wave.members.insertLast(u.id);
        return wave.task;
    }
    void TaskRemoved(IUnitTask@ task) {
        for (uint i=0; i<waves.length(); ++i) if (waves[i].task is task) {
            if (waves[i].phase==GUARD) AmphibiousBeaches::Publish(waves[i].serial,waves[i].anchor,true);
            @waves[i].task=null;
        }
    }
    void UnitRemoved(CCircuitUnit@ unit) {
        if (unit is null) return;
        for (uint i=0;i<waves.length();++i) {
            const int index=waves[i].members.find(unit.id);
            if (index>=0) waves[i].members.removeAt(index);
        }
    }
    void Reset() {
        array<Wave@> old=waves; waves.resize(0);
        for (uint i=0; i<old.length(); ++i) {
            if (old[i].phase==GUARD) AmphibiousBeaches::Publish(old[i].serial,old[i].anchor,true);
            if (old[i].task !is null && !old[i].task.IsDead()) old[i].task.Abort();
        }
    }
    void Tick() {
        if (ai.frame < lastTick + SECOND) return;
        lastTick=ai.frame;
        if (!Active()) { Reset(); return; }
        if (!StrategicSites::mapped) return;
        for (int i=int(waves.length())-1; i>=0; --i) {
            Wave@ w=waves[i];
            for (int j=int(w.members.length())-1; j>=0; --j) {
                CCircuitUnit@ u=ai.GetTeamUnit(w.members[j]);
                if (u is null || u.task !is w.task) w.members.removeAt(j);
            }
            if (w.members.length()==0 || w.task is null || w.task.IsDead()) {
                if (w.phase==GUARD) AmphibiousBeaches::Publish(w.serial,w.anchor,true);
                CRouteTask@ task=w.task; waves.removeAt(i);
                if (task !is null && !task.IsDead()) task.Abort();
                continue;
            }
            const int alive=int(w.members.length());
            int arrived=Arrived(w);
            if (w.phase==GUARD) { GuardTick(w); continue; }
            if (w.phase==ASSEMBLE) {
                if (ai.frame>=w.retry && (aiBattle.Height(w.destination)<0 || !aiBattle.IsPassable(Leader(w),Lanes::AMPH))) {
                    w.retry=ai.frame+retrySeconds*SECOND;
                    Recover(w); continue;
                }
                if (!AmphibiousMath::Release(alive,arrived,Size(w.kind),AiMin(minimum,Size(w.kind)),
                    ai.frame-w.born,assembleSeconds*SECOND,quorum)) continue;
                if (ai.frame<w.retry) continue;
                w.launched=alive;
                if (!Onward(w)) { w.retry=ai.frame+retrySeconds*SECOND; Say(w,"no safe route"); }
            } else if (w.phase==ADVANCE) {
                CheckCrossing(w);
                if (AmphibiousMath::Gathered(alive,Arrived(w),quorum)) {
                    w.phase=SECURE; w.region=StrategicSites::LandAt(w.destination); w.quiet=ai.frame;
                    Say(w,"landed/regroup");
                    AmphibiousFormation::Form(w);
                } else if (ai.frame-w.changed>stallSeconds*SECOND) {
                    // Re-query from the straggler; never declare a timed-out landing secure.
                    if (!Plan(w,w.destination,false,true)) Hold(w,"stalled");
                }
            } else if (w.phase==SECURE) {
                AmphibiousFormation::Maintain(w);
                arrived=Arrived(w);
                if (ai.frame% (60*SECOND)==0) Say(w,"regroup arrived="+arrived+" slots="+w.slots.length());
                AIFloat3 contact=Objective(w,w.kind==0);
                if (contact.x<0 && w.kind==1) contact=Objective(w,true);
                if (contact.x>=0 && ai.frame>=w.retry && ai.frame-w.changed>retrySeconds*SECOND) {
                    w.retry=ai.frame+retrySeconds*SECOND;
                    w.quiet=ai.frame;
                    // A land-only route cannot dive after a retreating ship or cross the next channel early.
                    if (Plan(w,contact,true)) continue;
                    // A cliff on this same island may require a safe coastal flank.
                    // The next dry landing still has to pass regroup/security checks.
                    if (Plan(w,contact)) continue;
                }
                if (contact.x>=0 || !AmphibiousMath::Gathered(alive,arrived,quorum)) { w.quiet=ai.frame; continue; }
                if (!AmphibiousMath::Secured(alive,arrived,quorum,false,ai.frame-w.quiet,
                    (w.kind==0?secureSeconds:raidSeconds)*SECOND)) continue;
                Say(w,"secured");
                w.secured=true;
                if (aiBattle.Height(w.destination)<0 || !AmphibiousMath::Gathered(alive,Arrived(w),quorum))
                    Invariants::Violation("INV-096","amph","departure without dry regrouped foothold");
                if (alive < AiMin(minimum,w.launched)) { Hold(w,"losses"); continue; }
                RetainGuard(w);
                const AIFloat3 target=Goal(w);
                w.anchor=w.destination;
                if (target.x<0 || target.distance2D(w.destination)<radius || !Onward(w)) Hold(w,"coastal guard");
            } else if (ai.frame>=w.retry && alive>=AiMin(minimum,w.launched)) {
                AmphibiousFormation::Maintain(w);
                w.retry=ai.frame+retrySeconds*SECOND;
                if (!w.secured) { Plan(w,w.destination,false,true); continue; }
                const AIFloat3 goal=Goal(w), contact=Objective(w,true);
                if (contact.x>=0) { w.phase=SECURE; w.quiet=ai.frame; }
                else if (goal.x>=0 && goal.distance2D(w.destination)>radius && !Onward(w)) Say(w,"hold no safe onward route");
            }
        }
    }
    // D-287: Marauder-class defs the native chooser must not pick for a late
    // TECH (corshiva/legjav enter only through factory.json weights). Namespace
    // constant: no per-ask allocation for the name list.
    const array<string> LATE_MASK={"armmar","corshiva","legjav"};
    IUnitTask@ DefaultFactoryTask(CCircuitUnit@ f) {
        const bool active = Active();
        // O(1) gate; true for every non-TECH role, so AIR is unchanged (KI-572).
        const bool late = !TechHeavyChoice::MarauderAllowed();
        if (!active && TelchineStartAllowed() && !late) return aiFactoryMgr.DefaultMakeTask(f);
        // The ordinary chooser may still build other units and constructors,
        // but cannot bypass the shared amphibious budget with its own batch.
        array<string> names={"legamph","armmar"};
        array<CCircuitDef@> defs; array<int> limits;
        for (uint i=0;i<names.length();++i) {
            // Preserve the TECH start restriction even with amphibious waves disabled.
            if (!active && i!=0) continue;
            if (i==0 && !active && TelchineStartAllowed()) continue;   // reached only when late
            CCircuitDef@ d=ai.GetCircuitDef(names[i]);
            if (d is null) continue;
            defs.insertLast(d); limits.insertLast(d.maxThisUnit); d.maxThisUnit=0;
        }
        if (late) {
            // Save -> zero -> DefaultMakeTask -> restore, as above; armmar may
            // already be masked by the amphibious budget (skip the duplicate).
            for (uint i=0;i<LATE_MASK.length();++i) {
                CCircuitDef@ d=ai.GetCircuitDef(LATE_MASK[i]);
                if (d is null || defs.findByRef(d)>=0) continue;
                defs.insertLast(d); limits.insertLast(d.maxThisUnit); d.maxThisUnit=0;
            }
        }
        IUnitTask@ task=aiFactoryMgr.DefaultMakeTask(f);
        // Restore in reverse so a def recorded twice would end at its original cap.
        for (int i=int(defs.length())-1;i>=0;--i) defs[i].maxThisUnit=limits[i];
        return task;
    }
    IUnitTask@ Produce(CCircuitUnit@ f, float roleGate) {
        if (!Active() || f is null || f.circuitDef is null
            || int(waves.length())>=maxWaves) return null;
        array<string> names={"legamph","armmar"};
        for (uint k=0;k<names.length();++k) {
            if (k==0 && !TelchineStartAllowed()) continue;
            CCircuitDef@ d=ai.GetCircuitDef(names[k]);
            int limit=k==0 ? telLimit : Size(k)*2;
            // D-287: a late TECH recruits no Marauders, except the optional single
            // mass batch on an amphibious map. Before the cap raise below, so a
            // refused Marauder never lifts maxThisUnit. O(1); AIR unaffected.
            if (k==1 && !TechHeavyChoice::MarauderAllowed()) {
                limit=TechHeavyChoice::MassBatchLimit(d);
                if (limit<=0) continue;
            }
            if (d is null || !f.circuitDef.CanBuild(d) || d.count+aiFactoryMgr.GetPendingRecruitCount(d)>=limit
                || aiEconomyMgr.metal.current<d.costM) continue;
            float seconds=0;
            if (k==0) {
                const float buffer=AiMin(d.costE*0.2f,aiEconomyMgr.energy.storage*0.5f);
                if (ai.frame<telNext || !AmphibiousMath::RecruitReady(Economy::GetMinMetalIncomeLast10s(),telMinMetal,Economy::IncomeWindowReady()?10*SECOND:0,10*SECOND,
                    aiEconomyMgr.metal.current,d.costM,telReserve,aiEconomyMgr.energy.current,buffer,aiEconomyMgr.isEnergyStalling)) continue;
                seconds=AmphibiousMath::RecruitSeconds(d.costM,d.costE,Economy::GetMinMetalIncomeLast10s(),Economy::GetMinEnergyIncomeLast10s(),telMetalShare,telEnergyShare);
                if (seconds<0) continue;
            } else if (aiEconomyMgr.metal.income<AiMax(roleGate,minMetal)) continue;
            // Bounded standing force, not a new factory build order or an override of economy prerequisites.
            if (d.maxThisUnit<limit) d.maxThisUnit=limit;
            if (!d.IsAvailable(ai.frame)) continue;
            IUnitTask@ task=aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER,
                Task::Priority::NORMAL,d,f.GetPos(ai.frame),64.0f));
            if (task !is null && k==0) {
                telNext=ai.frame+int(seconds*SECOND)+1;
                GenericHelpers::LogUtil("[AMPH] recruit legamph income="+aiEconomyMgr.metal.income+" bank="+aiEconomyMgr.metal.current+" interval="+seconds,1);
            }
            return task;
        }
        return null;
    }
}
