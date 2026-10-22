// SEA scouts temporarily combine against exposed targets, then release back to
// sector leases. One objective per occupied basin; no persistent enemy handles.
// O(B*E + B*U) per SEA census, B occupied basins, E legal contacts, U scouts.
// Route searches occur only on a changed intent/goal or dead task, not each tick.
namespace SeaScoutRaids {
    class Group {
        int body=-1, target=-1, started=0, cooldown=0;
        bool attacking=false;
        int formationSize=0;
        AIFloat3 position, assembly, direction;
        array<int> members;
        dictionary memberSlots;
    }
    array<Group@> groups;
    Group@ Basin(int body) {
        for (uint i=0;i<groups.length();++i) if (groups[i].body==body) return groups[i];
        Group@ group=Group(); group.body=body; groups.insertLast(group); return group;
    }
    bool Eligible(CCircuitUnit@ unit) {
        return SeaPatrol::Available(unit) && SeaPatrol::Scout(unit.circuitDef)
            && unit.circuitDef.HasSurfToLand()
            && unit.GetHealthPercent()>=Global::RoleSettings::Sea::ScoutRaidMinimumHealth;
    }
    bool Vulnerable(const CCircuitDef@ definition,int flags,float range) {
        // No underwater targets or unidentified sonar contacts. Surface scouts
        // cannot answer submarines; range superiority is required over guns.
        if (definition is null) return false;
        const bool armed=definition.HasSurfToLand() || definition.HasSubToLand()
            || definition.HasSurfToWater() || definition.HasSubToWater();
        return SeaMath::ScoutRaidTarget(flags,true,armed,range,
            AiMax(definition.GetMaxRange(1),definition.GetMaxRange(2)),Global::RoleSettings::Sea::ScoutRaidRangeMargin);
    }
    void Clear(Group@ group) {
        group.target=-1; group.members.resize(0); group.memberSlots.deleteAll(); group.attacking=false;
        group.cooldown=ai.frame+Global::RoleSettings::Sea::ScoutFailedSectorSeconds*SECOND;
    }
    void Update() {
        if (!Global::RoleSettings::Sea::ScoutSurfaceRaids) { groups.resize(0); return; }
        for (uint i=0;i<SeaPatrol::boats.length();++i) Basin(SeaPatrol::boats[i].body);
        for (uint g=0;g<groups.length();++g) {
            Group@ group=groups[g];
            SeaPatrol::Raid@ air=SeaPatrol::Basin(group.body);
            if (air.present) { Clear(group); continue; }
            float range=1e30f; int eligible=0; AIFloat3 centre(0,0,0);
            for (uint i=0;i<SeaPatrol::boats.length();++i) {
                SeaPatrol::Boat@ boat=SeaPatrol::boats[i];
                if (boat.body!=group.body) continue;
                CCircuitUnit@ unit=ai.GetTeamUnit(boat.id); if (!Eligible(unit)) continue;
                range=AiMin(range,unit.circuitDef.GetMaxRange(1));
                centre=centre+unit.GetPos(ai.frame); ++eligible;
            }
            if (eligible<Global::RoleSettings::Sea::ScoutRaidMinimumShips+Global::RoleSettings::Sea::ScoutRaidSurveyReserve) { if (group.target>=0) Clear(group); continue; }
            centre=centre/float(eligible);
            int selected=-1; float best=1e30f;
            for (int i=0;i<SeaPatrol::seaContacts;++i) {
                if (aiBattle.GetSeaForceBody(i)!=group.body) continue;
                const int definitionId=aiBattle.GetSeaForceDefId(i);
                const CCircuitDef@ definition=definitionId>=0 ? ai.GetCircuitDef(definitionId) : null;
                if (!Vulnerable(definition,aiBattle.GetSeaForceFlags(i),range)) continue;
                const AIFloat3 position=aiBattle.GetSeaForcePos(i);
                const float distance=MapHelpers::SqDist(centre,position);
                const float radius=Global::RoleSettings::Sea::ScoutRaidRecruitRadius;
                if (distance>radius*radius) continue;
                if (aiBattle.GetSeaForceId(i)==group.target) { selected=i; break; }
                if (distance<best) { best=distance; selected=i; }
            }
            if (selected<0) { if (group.target>=0) Clear(group); continue; }
            const int target=aiBattle.GetSeaForceId(selected);
            if (group.target<0 && ai.frame<group.cooldown) continue;
            const AIFloat3 position=aiBattle.GetSeaForcePos(selected);
            if (group.target!=target) {
                group.members.resize(0); group.memberSlots.deleteAll();
                group.target=target; group.started=ai.frame; group.attacking=false;
                const float distance=AiMax(1.0f,sqrt(MapHelpers::SqDist(centre,position)));
                group.direction=(centre-position)/distance;
                group.assembly=position+group.direction*(range+Global::RoleSettings::Sea::ScoutRaidAssemblyRadius);
            }
            group.position=position; int ready=0;
            // Recruitment is fixed for one objective. New arrivals continue
            // scouting; casualties remove members without shifting survivors.
            const bool recruiting=group.members.length()==0;
            if (recruiting) {
                for (uint i=0;i<SeaPatrol::boats.length();++i) {
                    SeaPatrol::Boat@ boat=SeaPatrol::boats[i]; if (boat.body!=group.body) continue;
                    CCircuitUnit@ unit=ai.GetTeamUnit(boat.id); if (!Eligible(unit)) continue;
                    const AIFloat3 here=unit.GetPos(ai.frame);
                    const float radius=Global::RoleSettings::Sea::ScoutRaidRecruitRadius;
                    if (MapHelpers::SqDist(here,group.assembly)>radius*radius
                        || !SeaPatrol::Safe(unit,group.assembly,group.body)) continue;
                    group.members.insertLast(boat.id);
                    const float assemblyRadius=Global::RoleSettings::Sea::ScoutRaidAssemblyRadius;
                    if (MapHelpers::SqDist(here,group.assembly)<assemblyRadius*assemblyRadius) ++ready;
                }
                // Keep the last stable IDs surveying; membership does not rotate
                // every tick, so a retained raid does not repeatedly steal scouts.
                const int maximumMembers=eligible-Global::RoleSettings::Sea::ScoutRaidSurveyReserve;
                if (int(group.members.length())>maximumMembers) {
                    group.members.resize(maximumMembers);
                    ready=0;
                    for (uint i=0;i<group.members.length();++i) {
                        CCircuitUnit@ member=ai.GetTeamUnit(group.members[i]);
                        const float radius=Global::RoleSettings::Sea::ScoutRaidAssemblyRadius;
                        if (member !is null && MapHelpers::SqDist(member.GetPos(ai.frame),group.assembly)<radius*radius) ++ready;
                    }
                }
                group.formationSize=int(group.members.length());
                for (uint i=0;i<group.members.length();++i) group.memberSlots.set(""+group.members[i],int(i));
            } else {
                uint live=0;
                for (uint i=0;i<group.members.length();++i) {
                    const int id=group.members[i]; CCircuitUnit@ member=ai.GetTeamUnit(id);
                    if (!Eligible(member) || aiBattle.WaterBody(member.GetPos(ai.frame),false)!=group.body) {
                        group.memberSlots.delete(""+id); continue;
                    }
                    group.members[live++]=id;
                    const float radius=Global::RoleSettings::Sea::ScoutRaidAssemblyRadius;
                    if (MapHelpers::SqDist(member.GetPos(ai.frame),group.assembly)<radius*radius) ++ready;
                }
                group.members.resize(live);
            }
            if (SeaMath::ScoutRaidExpired(ai.frame-group.started,
                Global::RoleSettings::Sea::ScoutRaidAssemblySeconds*SECOND,
                Global::RoleSettings::Sea::ScoutRaidMaximumSeconds*SECOND,
                int(group.members.length()),ready,Global::RoleSettings::Sea::ScoutRaidMinimumShips,group.attacking)) {
                Clear(group); continue;
            }
            if (ready>=Global::RoleSettings::Sea::ScoutRaidMinimumShips) group.attacking=true;
            // Surviving slots remain stable; Control reads them in expected O(1).

        }
    }
    bool Control(SeaPatrol::Boat@ boat,CCircuitUnit@ unit) {
        Group@ group=Basin(boat.body);
        int slot=-1;
        if (!group.memberSlots.get(""+boat.id,slot)) slot=-1;
        if (group.target<0 || slot<0 || !Eligible(unit)) {
            if (boat.mode==3) { SeaPatrol::Release(boat); boat.mode=-1; boat.until=0; }
            return false;
        }
        if (group.attacking && int(group.members.length())<Global::RoleSettings::Sea::ScoutRaidMinimumShips) {
            Invariants::Violation("INV-184",""+group.body,"SEA scout attack has insufficient assembled members");
            Clear(group); SeaPatrol::Release(boat); boat.mode=-1; return false;
        }
        const float range=unit.circuitDef.GetMaxRange(1)*Global::RoleSettings::Sea::ScoutRaidFiringRangeFraction;
        const float angle=SeaMath::AntiSubAngle(slot,group.formationSize,Global::RoleSettings::Sea::ScoutRaidArcRadians);
        const float dx=group.direction.x*cos(angle)-group.direction.z*sin(angle);
        const float dz=group.direction.x*sin(angle)+group.direction.z*cos(angle);
        AIFloat3 goal=group.attacking ? group.position+AIFloat3(dx*range,0,dz*range)
            : group.assembly+AIFloat3(-group.direction.z*float(slot)*Global::RoleSettings::Sea::ScoutRaidFormationSpacing,
                0,group.direction.x*float(slot)*Global::RoleSettings::Sea::ScoutRaidFormationSpacing);
        if (!SeaPatrol::Safe(unit,goal,boat.body)) {
            SeaPatrol::Release(boat); boat.mode=-1; boat.until=0; return false;
        }
        const float reposition=Global::RoleSettings::Sea::ScoutRaidRepositionDistance;
        if (boat.mode!=3 || boat.target!=group.target || MapHelpers::SqDist(goal,boat.goal)>reposition*reposition
            || boat.route is null || boat.route.IsDead() || unit.task !is boat.route) {
            if (!SeaPatrol::SurveyOrder(boat,unit,goal)) {
                SeaPatrol::Release(boat); boat.mode=-1; boat.until=0; return false;
            }
            if (boat.sector>=0 && SeaPatrol::sectors[boat.sector].owner==boat.id)
                SeaPatrol::sectors[boat.sector].owner=-1;
            SeaPatrol::Count(5);
            boat.sector=-1; boat.mode=3; boat.target=group.target; boat.goal=goal;
            GenericHelpers::LogUtil("[SEA][ScoutRaid] id="+boat.id+" target="+group.target+" attacking="+group.attacking,1);
        }
        boat.route.SetNavalTarget(group.attacking ? group.target : -1);
        return true;
    }
}
