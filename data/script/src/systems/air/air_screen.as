#include "air_economy.as"
#include "air_perimeter.as"
#include "../team/roster.as"
#include "../world/lanes.as"
namespace AirScreen {
    dictionary routes, cellByUnit, registeredFrames;
    array<CRouteTask@> groups;
    array<int> interceptIds;
    int updated=-100000, screenLog=-100000;
    bool responding=false, changed=true;
    dictionary fighterDefs;
    bool IsFighter(const CCircuitDef@ d)
    {
        if (d is null) return false;
        if (fighterDefs.isEmpty()) {
            array<string> names = UnitHelpers::GetAllT2Fighters();
            const array<string> basic = {"armfig", "corveng", "legfig", "armsfig", "corsfig", "legspfighter"};
            for (uint i = 0; i < basic.length(); ++i) names.insertLast(basic[i]);
            for (uint i = 0; i < names.length(); ++i) fighterDefs.set(names[i], true);
        }
        return fighterDefs.exists(d.GetName());
    }
    AIFloat3 Clamp(const AIFloat3 &in p) {
        return AIFloat3(AiMax(128.0f,AiMin(float(AiTerrainWidth())-128.0f,p.x)),0,AiMax(128.0f,AiMin(float(AiTerrainHeight())-128.0f,p.z)));
    }
    int CountOther(const string &in name) {
        int count=0; array<string>@ ids=routes.getKeys();
        for (uint i=0;i<ids.length();++i) { CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i])); if (u !is null && u.circuitDef.GetName()!=name) ++count; }
        return count;
    }
    float HomeValue() {
        float value=0; array<string>@ ids=routes.getKeys();
        for (uint i=0;i<ids.length();++i) { CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i])); if (u !is null && u.GetBuildProgress()>=1.0f) value+=u.circuitDef.costM; }
        return value;
    }
    float IntrusionCost() {
        float cost=0;
        for (int i=0;i<aiBattle.GetAirContactCount();++i) if (aiBattle.IsAirContactArmed(i) && AirHome::Friendly(aiBattle.GetAirContactPos(i))) cost+=aiBattle.GetAirContactCost(i);
        return cost;
    }
    AIFloat3 Anchor() {
        AIFloat3 anchor=Global::Map::StartPos; float nearest=1.0e20f;
        array<Team::Roster::Entry@>@ allies=Team::Roster::WithRole(AiRole::TECH);
        for (uint i=0;i<allies.length();++i) {
            const float sq=MapHelpers::SqDist(Global::Map::StartPos,allies[i].startPos);
            if (sq<nearest) { nearest=sq; anchor=allies[i].startPos; }
        }
        return anchor;
    }
    AIFloat3 Enemy(const AIFloat3 &in anchor) {
        AIFloat3 enemy(float(AiTerrainWidth())-anchor.x,0,float(AiTerrainHeight())-anchor.z); float nearest=1.0e20f;
        array<AIFloat3> starts=Lanes::ScriptStarts(true);
        for (uint i=0;i<starts.length();++i) { const float sq=MapHelpers::SqDist(anchor,starts[i]); if (sq<nearest) { nearest=sq; enemy=starts[i]; } }
        return enemy;
    }
    void Tick() {
        if (!changed && ai.frame-updated<Global::RoleSettings::Air::InterceptUpdateSeconds*SECOND) return;
        array<string>@ ids=routes.getKeys();
        for (uint i=0;i<ids.length();++i) {
            CRouteTask@ task=null;
            CCircuitUnit@ unit=ai.GetTeamUnit(parseInt(ids[i]));
            int registered=-1;
            const bool arriving=registeredFrames.get(ids[i],registered) && registered==ai.frame;
            // TaskFor is called before native assignment. Only that same-frame
            // handoff may temporarily differ; subsequent ownership changes prune
            // the ledger instead of leaving phantom fighters in the screen.
            if (unit is null || !routes.get(ids[i],@task) || task is null || task.IsDead()
                || (!arriving && unit.task !is task)) {
                routes.delete(ids[i]); cellByUnit.delete(ids[i]); registeredFrames.delete(ids[i]);
            }
        }
        updated=ai.frame; changed=false; @ids=routes.getKeys(); if (ids.length()==0) return;
        const int cells=AiMax(1,Global::RoleSettings::Air::ScreenCells);
        const AIFloat3 anchor=Anchor(), enemy=Enemy(anchor);
        AirPerimeter::Plan(anchor,enemy,int(ids.length()),cells);
        const float width=AirPerimeter::span;
        const AIFloat3 centre=AirPerimeter::vertices[cells/2];
        array<float> value(cells,0);
        for (uint i=0;i<ids.length();++i) { int c=0; cellByUnit.get(ids[i],c); CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i])); if (u !is null && c>=0 && c<cells) value[c]+=u.circuitDef.costM; }
        array<float> remaining; array<int> contacts, contactIds;
        for (int i=0;i<aiBattle.GetAirContactCount();++i) {
            if (!aiBattle.IsAirContactArmed(i) || !AirHome::Friendly(aiBattle.GetAirContactPos(i))) continue;
            contacts.insertLast(i); contactIds.insertLast(aiBattle.GetAirContactId(i));
            remaining.insertLast(aiBattle.GetAirContactCost(i)*Global::RoleSettings::Air::InterceptCostRatio);
        }
        if (int(interceptIds.length())!=cells) { interceptIds.resize(cells); for(int c=0;c<cells;++c) interceptIds[c]=-1; }
        array<int> selected(cells,-1);
        // Preserve engaged groups before spending the response budget on new
        // contacts. Moving/reordered contacts must not churn all 200 fighters.
        for (int c=0;c<cells && c<int(groups.length());++c) {
            if (groups[c] is null || groups[c].IsDead() || value[c]<=0) { interceptIds[c]=-1; continue; }
            const int kept=AirMath::RetainedContact(interceptIds[c],contactIds,remaining);
            if (kept>=0) { selected[c]=kept; remaining[kept]-=value[c]; }
        }
        responding=false;
        for (int c=0;c<cells && c<int(groups.length());++c) {
            CRouteTask@ task=groups[c]; if (task is null || task.IsDead() || value[c]<=0) continue;
            array<AIFloat3> points={AirPerimeter::vertices[c],AirPerimeter::vertices[c+1]};
            for (uint p=0;p<points.length();++p)
                if (!ProductionMath::Inside(points[p].x,points[p].z,float(AiTerrainWidth()),float(AiTerrainHeight()),0))
                    Invariants::Violation("INV-080","AIR","fighter wall endpoint outside map");
            int target=selected[c]; float best=1.0e20f;
            for (uint j=0;selected[c]<0 && j<contacts.length();++j) {
                if (remaining[j]<=0) continue;
                const float sq=MapHelpers::SqDist(points[0],aiBattle.GetAirContactPos(contacts[j]));
                if (sq<best) { best=sq; target=int(j); }
            }
            // Commit only the final desired mission: never patrol-then-intercept.
            if (target>=0) {
                if (!AirHome::Friendly(aiBattle.GetAirContactPos(contacts[target])))
                    Invariants::Violation("INV-093", "AIR", "defensive interception selected outside friendly territory");
                interceptIds[c]=contactIds[target]; task.SetAirTarget(interceptIds[c]);
                if (selected[c]<0) remaining[target]-=value[c]; responding=true;
            }
            else { interceptIds[c]=-1; task.SetAirTarget(-1); task.SetRoute(points); }
        }
        if (ai.frame-screenLog>=10*SECOND) {
            screenLog=ai.frame;
            GenericHelpers::LogUtil("[AIR][Screen] fighters="+ids.length()+" cells="+cells+" centre="+int(centre.x)+","+int(centre.z)+" width="+int(width)+" maturity="+AirPerimeter::lastProgress+" responding="+responding,1);
        }
    }
    IUnitTask@ TaskFor(CCircuitUnit@ u) {
        const string key=""+u.id; CRouteTask@ task=null;
        int registered=-1;
        if (routes.get(key,@task) && task !is null && !task.IsDead()
            && (u.task is task || (registeredFrames.get(key,registered) && registered==ai.frame))) return task;
        Removed(u.id);
        const int cells=AiMax(1,Global::RoleSettings::Air::ScreenCells);
        if (int(groups.length())!=cells) groups.resize(cells);
        array<int> count(cells,0); array<string>@ ids=cellByUnit.getKeys();
        for (uint i=0;i<ids.length();++i) { int c=0; if (cellByUnit.get(ids[i],c) && c>=0 && c<cells) ++count[c]; }
        int cell=0; for (int c=1;c<cells;++c) if (count[c]<count[cell]) cell=c;
        if (groups[cell] is null || groups[cell].IsDead()) {
            @groups[cell]=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route())); if (groups[cell] is null) return null;
            groups[cell].SetAirControl(true); groups[cell].SetPatrol(true);
        }
        u.SetIdleMode(0); u.SetFireState(2); @task=groups[cell];
        routes.set(key,@task); cellByUnit.set(key,cell); registeredFrames.set(key,ai.frame); changed=true; Tick(); return task;
    }
    void Removed(int id) { routes.delete(""+id); cellByUnit.delete(""+id); registeredFrames.delete(""+id); changed=true; }
    void Reset() { routes.deleteAll(); cellByUnit.deleteAll(); registeredFrames.deleteAll(); AirPerimeter::Reset(); groups.resize(0); interceptIds.resize(0); updated=-100000; screenLog=-100000; responding=false; changed=true; }
}
