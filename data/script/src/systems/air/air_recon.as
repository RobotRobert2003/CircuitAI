// Safe, distinct waiting patrols; shared cohorts retain straight MOVE sweeps.
namespace AirRecon {
    dictionary waiting, placed, assembled, sweeping, destinations, surveying, originalCaps;
    array<AIFloat3> slots;
    AIFloat3 direction;
    float spacing = 0.0f;
    int columns = 0, nextCycle = 0;
    int waitingSince = -1;
    CRouteTask@ wall;
    class Patrol {
        AIFloat3 centre;
        array<AIFloat3> route;
        float escapeRisk=0;
    }
    dictionary patrols, patrolBlocked, fallbacks;
    int patrolChecked = -100000;
    Patrol@ Around(const AIFloat3 &in p) {
        Patrol@ result = Patrol(); result.centre = p;
        const float r = AiMax(128.0f, Global::RoleSettings::Air::RadarPatrolRadius);
        result.route = {AIFloat3(p.x-r,p.y,p.z-r*0.6f), AIFloat3(p.x+r,p.y,p.z-r*0.6f), AIFloat3(p.x,p.y,p.z+r)};
        return result;
    }
    bool Safe(Patrol@ p) {
        if (p is null) return false;
        for (uint i=0;i<p.route.length();++i) {
            if (!AirHome::Friendly(p.route[i]) || aiBattle.AirThreatAlong(p.route[i],p.route[(i+1)%p.route.length()],
                Global::RoleSettings::Air::RadarThreatPadding)>Global::RoleSettings::Air::RadarSafeThreat) return false;
        }
        return true;
    }
    void Fallback(CCircuitUnit@ u,const array<Patrol@> &in choices) {
        // No verified safe approach: leave the invalid old patrol for the least
        // exposed friendly holding route. This is explicitly not a safety claim.
        array<Patrol@> sites=choices;
        for(uint i=0;i<WallHelpers::starts.length();++i) {
            AIFloat3 p=WallHelpers::starts[i];
            const float margin=Global::RoleSettings::Air::RadarThreatPadding+Global::RoleSettings::Air::RadarPatrolRadius+128;
            p.x=AiMax(margin,AiMin(float(AiTerrainWidth())-margin,p.x));
            p.z=AiMax(margin,AiMin(float(AiTerrainHeight())-margin,p.z));
            if(AirHome::Friendly(p))sites.insertLast(Around(p));
        }
        Patrol@ best;float score=1.0e30f;
        const AIFloat3 here=u.GetPos(ai.frame);
        for(uint i=0;i<sites.length();++i) {
            bool friendly=true;
            for(uint j=0;j<sites[i].route.length();++j)if(!AirHome::Friendly(sites[i].route[j]))friendly=false;
            if(!friendly)continue;
            float danger=aiBattle.AirThreatAlong(here,sites[i].route[0],0);
            for(uint j=0;j<sites[i].route.length();++j)danger=AiMax(danger,aiBattle.AirThreatAlong(sites[i].route[j],sites[i].route[(j+1)%3],Global::RoleSettings::Air::RadarThreatPadding));
            if(!AirMath::Valid(danger))continue;
            const float rank=danger*1000000000.0f+MapHelpers::SqDist(here,sites[i].centre);
            if(rank<score) {score=rank;@best=sites[i];}
        }
        if(best is null)return;
        const string key=""+u.id;AIFloat3 previous;
        if(fallbacks.get(key,previous) && MapHelpers::SqDist(previous,best.centre)<128.0f*128.0f)return;
        if(wall.SetUnitRoute(u,best.route,128)) {
            fallbacks.set(key,best.centre);
            GenericHelpers::LogUtil("[AIR][Recon] least-exposed fallback plane="+u.id,1);
        }
    }
    void Patrols() {
        if (wall is null || wall.IsDead() || ai.frame-patrolChecked < AiMax(1,Global::RoleSettings::Air::RadarPatrolCheckSeconds)*SECOND) return;
        patrolChecked=ai.frame;
        array<string>@ keys=waiting.getKeys();
        array<int> ids;
        bool replan=false;
        for (uint i=0;i<keys.length();++i) {
            const int id=parseInt(keys[i]); ids.insertLast(id);
            CCircuitUnit@ u=ai.GetTeamUnit(id); Patrol@ p; patrols.get(keys[i],@p);
            const float risk=u is null ? 0 : aiBattle.AirThreatAlong(u.GetPos(ai.frame),u.GetPos(ai.frame),0);
            if (u is null || !Safe(p) || (p !is null && risk>AiMax(p.escapeRisk,Global::RoleSettings::Air::RadarSafeThreat))) {
                patrols.delete(keys[i]); replan=true;
            } else if(p !is null) p.escapeRisk=AiMin(p.escapeRisk,risk);
        }
        if (!replan) return;
        ids.sortAsc(); // stable allocation even when native unit enumeration changes
        array<Patrol@> choices;
        const int grid=AiMax(4,AiMin(20,Global::RoleSettings::Air::RadarPatrolGrid));
        const float margin=AiMax(128.0f,Global::RoleSettings::Air::RadarPatrolRadius)+Global::RoleSettings::Air::RadarThreatPadding+96.0f;
        const float width=float(AiTerrainWidth())-2*margin, height=float(AiTerrainHeight())-2*margin;
        if (width>0 && height>0) for (int z=0;z<grid;++z) for (int x=0;x<grid;++x) {
            Patrol@ p=Around(AIFloat3(margin+width*float(x)/float(grid-1),0,margin+height*float(z)/float(grid-1)));
            if (Safe(p)) choices.insertLast(p);
        }
        const AIFloat3 enemy=AirScreen::Enemy(Global::Map::StartPos);
        array<float> separations(choices.length(),1.0e10f);
        array<string>@ assigned=patrols.getKeys();
        for(uint j=0;j<assigned.length();++j) {
            Patrol@ other;patrols.get(assigned[j],@other);if(other is null)continue;
            for(uint c=0;c<choices.length();++c)separations[c]=AiMin(separations[c],MapHelpers::SqDist(choices[c].centre,other.centre));
        }
        for (uint i=0;i<ids.length();++i) {
            const string key=""+ids[i];
            if (patrols.exists(key)) continue;
            CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
            if (u is null || u.task !is wall) continue;
            const AIFloat3 here=u.GetPos(ai.frame);
            // Compare padded origin risk with padded travel risk. Comparing a
            // single safe cell against a padded corridor can trap a plane on
            // the edge of newly observed AA coverage indefinitely.
            const float danger=aiBattle.AirThreatAlong(here,here,Global::RoleSettings::Air::RadarThreatPadding);
            int selected=-1;
            array<bool> rejected(choices.length(),false);
            for(uint attempt=0;attempt<choices.length();++attempt) {
                int candidate=-1;float best=-1.0e30f;
                for (uint c=0;c<choices.length();++c) {
                    if(rejected[c] || separations[c]<128.0f*128.0f)continue;
                    const float enemyDistance=MapHelpers::SqDist(choices[c].centre,enemy);
                    const float score=AiMin(separations[c],16000000.0f)-enemyDistance*0.03f-MapHelpers::SqDist(here,choices[c].centre)*0.01f;
                    if(score>best) {best=score;candidate=int(c);}
                }
                if(candidate<0)break;
                const float risk=aiBattle.AirThreatAlong(here,choices[candidate].route[0],Global::RoleSettings::Air::RadarThreatPadding);
                if(AirMath::Valid(risk) && risk<=AiMax(danger,Global::RoleSettings::Air::RadarSafeThreat)) {selected=candidate;break;}
                rejected[candidate]=true;
            }
            if (selected<0) {
                if (!patrolBlocked.exists(key)) GenericHelpers::LogUtil("[AIR][Recon] patrol unavailable plane="+ids[i]+" candidates="+choices.length(),1);
                patrolBlocked.set(key,true); Fallback(u,choices); continue;
            }
            Patrol@ p=choices[selected];
            if (wall.SetUnitRoute(u,p.route,128.0f)) {
                p.escapeRisk=danger;
                patrols.set(key,@p); placed.set(key,true); patrolBlocked.delete(key); fallbacks.delete(key);
                for(uint c=0;c<choices.length();++c)separations[c]=AiMin(separations[c],MapHelpers::SqDist(choices[c].centre,p.centre));
                GenericHelpers::LogUtil("[AIR][Recon] patrol plane="+ids[i]+" x="+int(p.centre.x)+" z="+int(p.centre.z)+" knownThreat=0",1);
            } else Invariants::Violation("INV-141",key,"waiting radar rejected its distinct patrol route");
        }
    }

    string Name(const string &in side) { return side == "cortex" ? "corawac" : side == "legion" ? "legwhisper" : "armawac"; }
    bool Controlled(CCircuitUnit@ u) { return u !is null && (u.task is null || u.task.GetType() != int(Task::Type::PLAYER)); }
    void Unlock(CCircuitDef@ def)
    {
        if (def is null) return;
        if (!originalCaps.exists(def.GetName())) originalCaps.set(def.GetName(), int(def.maxThisUnit));
        def.maxThisUnit = 2147483647;
    }
    int FighterPlant()
    {
        int selected = -1, count = 0;
        const int prior = aiTerrainMgr.GetLayoutInt("air.fighterPlant", -1);
        bool retained = false;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.GetBuildProgress() < 1.0f || Lifecycle::IsRetiring(u)
                || !UnitHelpers::IsT2AircraftPlant(u.circuitDef.GetName())) continue;
            ++count;
            if (u.id == prior) retained = true;
            if (selected < 0 || u.id < selected) selected = u.id;
        }
        if (count < 2) return -1;
        if (retained) return prior;
        aiTerrainMgr.SetLayoutInt("air.fighterPlant", selected);
        return selected;
    }
    int ProductionTarget(CCircuitDef@ def)
    {
        if (def is null || ai.frame < nextCycle) return 0;
        int unavailable = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef.GetName() != def.GetName()) continue;
            CRouteTask@ task;
            if (!Controlled(u) || (sweeping.get("" + u.id, @task) && task !is null && !task.IsDead() && u.task is task)) ++unavailable;
        }
        return unavailable + AiMax(1, Global::RoleSettings::Air::RadarWaveSize);
    }
    float Extent(const AIFloat3 &in at, float dx, float dz)
    {
        const float margin = AiMax(128.0f, Global::RoleSettings::Air::RadarBacklineInset);
        float length = 1.0e9f;
        if (dx > 0.0001f) length = AiMin(length, (float(AiTerrainWidth()) - margin - at.x) / dx);
        if (dx < -0.0001f) length = AiMin(length, (margin - at.x) / dx);
        if (dz > 0.0001f) length = AiMin(length, (float(AiTerrainHeight()) - margin - at.z) / dz);
        if (dz < -0.0001f) length = AiMin(length, (margin - at.z) / dz);
        return AiMax(0.0f, length);
    }
    bool Plan(const CCircuitDef@ def)
    {
        const int count = AiMax(1, Global::RoleSettings::Air::RadarWaveSize);
        array<AIFloat3> allies = Lanes::ScriptStarts(false), enemies = Lanes::ScriptStarts(true);
        AIFloat3 home = Global::Map::StartPos, enemy = AirScreen::Enemy(home);
        if (allies.length() > 0) {
            home = AIFloat3(0,0,0);
            for (uint i = 0; i < allies.length(); ++i) { home.x += allies[i].x; home.z += allies[i].z; }
            home.x /= float(allies.length()); home.z /= float(allies.length());
        }
        if (enemies.length() > 0) {
            enemy = AIFloat3(0,0,0);
            for (uint i = 0; i < enemies.length(); ++i) { enemy.x += enemies[i].x; enemy.z += enemies[i].z; }
            enemy.x /= float(enemies.length()); enemy.z /= float(enemies.length());
        }
        const float dx = enemy.x - home.x, dz = enemy.z - home.z;
        const float distance = sqrt(dx*dx + dz*dz);
        if (distance < 1.0f) return false;
        direction = AIFloat3(dx/distance, 0, dz/distance);
        spacing = AiMax(64.0f, AirMath::RadarSpacing(def.GetLosRadius(), Global::RoleSettings::Air::RadarSightOverlap));
        // Fit all members; clamping them individually would pile them onto edges.
        for (int attempt = 0; attempt < 24; ++attempt) {
          // Try deeper friendly staging before sacrificing the requested overlap.
          for (int site = 0; site < 8; ++site) {
            const float advance = 0.25f + float(site%4)*0.05f;
            AIFloat3 centre = AirScreen::Clamp(AIFloat3(home.x + direction.x*distance*advance, 0, home.z + direction.z*distance*advance));
            // A start near a side edge must not collapse the whole team's wall
            // into that corner. First centre its transverse axis on the map.
            if (site < 4) {
                const float across = (float(AiTerrainWidth())*0.5f-centre.x)*(-direction.z)
                    + (float(AiTerrainHeight())*0.5f-centre.z)*direction.x;
                centre.x -= direction.z*across; centre.z += direction.x*across;
            }
            const float span = 2.0f * AiMin(Extent(centre, -direction.z, direction.x), Extent(centre, direction.z, -direction.x));
            columns = AirMath::RadarColumns(count, span, spacing);
            slots.resize(0);
            bool valid = columns > 0;
            for (int i = 0; valid && i < count; ++i) {
                const int rank = i / columns;
                const int rowCount = AiMin(columns, count - rank*columns);
                const float across = (float(i%columns) - float(rowCount-1)*0.5f)*spacing;
                const float back = float(rank)*spacing;
                const AIFloat3 point(centre.x-direction.z*across-direction.x*back, 0, centre.z+direction.x*across-direction.z*back);
                valid = AirLayout::Inside(point, 256.0f) && AirHome::Friendly(point);
                slots.insertLast(point);
            }
            if (valid) {
                GenericHelpers::LogUtil("[AIR][Recon] formation slots=" + count + " columns=" + columns + " spacing=" + int(spacing) + " sight=" + int(def.GetLosRadius()), 1);
                return true;
            }
          }
            spacing *= 0.9f;
        }
        slots.resize(0);
        return false;
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!AirEconomy::Active() || !Controlled(u) || u.circuitDef.GetName() != Name(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName()))) return null;
        const string key = "" + u.id;
        CRouteTask@ active;
        if (sweeping.get(key, @active) && active !is null && !active.IsDead()) return active;
        sweeping.delete(key); destinations.delete(key); surveying.delete(key);
        if (slots.length() == 0 && !Plan(u.circuitDef)) return null;
        if (wall is null || wall.IsDead()) {
            @wall = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (wall is null) return null;
            array<AIFloat3> route = {AirScreen::Anchor()};
            wall.SetAirControl(true); wall.SetPatrol(true); wall.SetTraversal(true, 128.0f, false); wall.SetRoute(route);
            placed.deleteAll(); assembled.deleteAll();
        }
        // Excess donations wait for the next cohort; they never disappear from
        // the controller when the first twenty transfer to their sweep task.
        if (!waiting.exists(key)) waiting.set(key, -1);
        u.SetIdleMode(0); u.SetFireState(0);
        return wall;
    }
    void ScoutBases(CCircuitUnit@ u, CRouteTask@ task)
    {
        array<AIFloat3> bases = Lanes::ScriptStarts(true), route;
        AIFloat3 from = u.GetPos(ai.frame);
        for (int n = 0; n < 3 && bases.length() > 0; ++n) {
            int best = 0; float sq = 1.0e20f;
            for (uint b = 0; b < bases.length(); ++b) {
                const float distance = MapHelpers::SqDist(from, bases[b]);
                if (distance < sq) { best = int(b); sq = distance; }
            }
            from = AirScreen::Clamp(bases[best]); route.insertLast(from); bases.removeAt(best);
        }
        if (route.length() == 0) route.insertLast(AirScreen::Enemy(from));
        if (route.length() == 1) route.insertLast(AirScreen::Clamp(AIFloat3(route[0].x-direction.z*spacing*0.5f, 0, route[0].z+direction.x*spacing*0.5f)));
        task.SetPatrol(true);
        if (task.SetUnitRoute(u, route, Global::RoleSettings::Air::RadarAssemblyRadius)) {
            surveying.set("" + u.id, true);
            GenericHelpers::LogUtil("[AIR][Recon] nearby bases plane=" + u.id + " bases=" + route.length(), 1);
        }
    }
    void Tick()
    {
        array<string>@ away = sweeping.getKeys();
        for (uint i = 0; i < away.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(away[i])); CRouteTask@ task; sweeping.get(away[i], @task);
            if (!Controlled(u) || task is null || task.IsDead() || u.task !is task) {
                sweeping.delete(away[i]); destinations.delete(away[i]); surveying.delete(away[i]); continue;
            }
            AIFloat3 point;
            if (!surveying.exists(away[i]) && destinations.get(away[i], point)
                && MapHelpers::SqDist(u.GetPos(ai.frame), point) <= Global::RoleSettings::Air::RadarAssemblyRadius*Global::RoleSettings::Air::RadarAssemblyRadius) ScoutBases(u, task);
        }
        array<string>@ ids = waiting.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (!Controlled(u) || wall is null || wall.IsDead() || u.task !is wall) {
                waiting.delete(ids[i]); placed.delete(ids[i]); assembled.delete(ids[i]);
                patrols.delete(ids[i]); patrolBlocked.delete(ids[i]); fallbacks.delete(ids[i]);
            }
        }
        @ids = waiting.getKeys();
        if (ids.length() == 0) { waitingSince = -1; return; }
        if (waitingSince < 0) waitingSince = ai.frame;
        if (slots.length() == 0 && !Plan(ai.GetTeamUnit(parseInt(ids[0])).circuitDef)) return;
        Patrols();
        array<bool> used(slots.length(), false);
        for (uint i = 0; i < ids.length(); ++i) {
            int slot = -1; waiting.get(ids[i], slot);
            if (slot >= 0 && slot < int(used.length())) used[slot] = true;
        }
        uint available = 0;
        int ready = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i])); int slot = -1; waiting.get(ids[i], slot);
            if (slot < 0 || slot >= int(slots.length())) {
                while (available < used.length() && used[available]) ++available;
                if (available >= used.length()) continue;
                slot = int(available); used[available] = true; waiting.set(ids[i], slot);
            }
            Patrol@ patrol; patrols.get(ids[i],@patrol);
            const float distance = patrol is null ? 1.0e20f : MapHelpers::SqDist(u.GetPos(ai.frame), patrol.centre);
            const float radiusSq = Global::RoleSettings::Air::RadarAssemblyRadius*Global::RoleSettings::Air::RadarAssemblyRadius;
            if (placed.exists(ids[i]) && distance <= radiusSq) assembled.set(ids[i], true);
            // Fixed-wing aircraft orbit a reached position. Do not wait several
            // minutes for twenty orbit phases to coincide inside the inner disc.
            if (AirMath::RadarReady(assembled.exists(ids[i]), distance, Global::RoleSettings::Air::RadarAssemblyRadius)) ++ready;
        }
        const int wanted = AiMax(1, Global::RoleSettings::Air::RadarWaveSize);
        const bool timedOut = ai.frame-waitingSince >= AiMax(1, Global::RoleSettings::Air::RadarMaxWaitSeconds)*SECOND;
        if (!AirMath::ReconRelease(int(ids.length()), ready, wanted, ai.frame-waitingSince,
            AiMax(1, Global::RoleSettings::Air::RadarMaxWaitSeconds)*SECOND)) return;
        CRouteTask@ sweep = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        if (sweep is null) {
            if (timedOut) Invariants::Violation("INV-139", "recon deadline", "could not create timed scout sweep");
            return;
        }
        array<AIFloat3> initial = {AirScreen::Enemy(Global::Map::StartPos)};
        sweep.SetAirControl(true); sweep.SetTraversal(true, Global::RoleSettings::Air::RadarAssemblyRadius, false); sweep.SetRoute(initial);
        @ids = waiting.getKeys(); int sent = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i])); int slot = -1; waiting.get(ids[i], slot);
            if (!Controlled(u) || slot < 0 || slot >= int(slots.length())) continue;
            const AIFloat3 start = slots[slot];
            const float travel = Extent(start, direction.x, direction.z);
            const AIFloat3 end(start.x+direction.x*travel, 0, start.z+direction.z*travel);
            if (aiMilitaryMgr.TransferUnit(u, sweep)) {
                array<AIFloat3> route = {end};
                if (!sweep.SetUnitRoute(u, route, Global::RoleSettings::Air::RadarAssemblyRadius))
                    Invariants::Violation("INV-123", "" + u.id, "recon member rejected straight MOVE route");
                sweeping.set(ids[i], @sweep); destinations.set(ids[i], end); waiting.delete(ids[i]); placed.delete(ids[i]); assembled.delete(ids[i]); ++sent;
                patrols.delete(ids[i]); patrolBlocked.delete(ids[i]); fallbacks.delete(ids[i]);
            }
        }
        if (sent == 0) {
            if (timedOut) Invariants::Violation("INV-139", "recon deadline", "no eligible scout transferred at deadline");
            sweep.Abort(); return;
        }
        if (sent > wanted || (!timedOut && sent != wanted))
            Invariants::Violation("INV-123", "radar cohort", "full recon launch differs from assembled cohort");
        waitingSince = -1;
        slots.resize(0); placed.deleteAll(); assembled.deleteAll();
        if (waiting.isEmpty()) @wall = null;
        else {
            @ids = waiting.getKeys();
            for (uint i = 0; i < ids.length(); ++i) waiting.set(ids[i], -1);
        }
        nextCycle = ai.frame + AiMax(1, Global::RoleSettings::Air::RadarWaveIntervalSeconds)*SECOND;
        GenericHelpers::LogUtil("[AIR][Recon] synchronized sweep=" + sent + " formed=" + ready + " spacing=" + int(spacing)
            + " reason=" + (timedOut ? "deadline" : "full"), 1);
    }
    void Reset()
    {
        if (wall !is null && !wall.IsDead()) wall.Abort();
        array<string>@ ids = sweeping.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CRouteTask@ task; sweeping.get(ids[i], @task);
            if (task !is null && !task.IsDead()) task.Abort();
        }
        @wall = null; waiting.deleteAll(); placed.deleteAll(); assembled.deleteAll(); sweeping.deleteAll(); destinations.deleteAll(); surveying.deleteAll(); slots.resize(0); nextCycle = 0; waitingSince = -1;
        patrols.deleteAll(); patrolBlocked.deleteAll(); fallbacks.deleteAll(); patrolChecked=-100000;
        @ids = originalCaps.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(ids[i]); int cap = 0;
            if (def !is null && originalCaps.get(ids[i], cap)) def.maxThisUnit = cap;
        }
        originalCaps.deleteAll();
    }
}
