// Staged-only observer. Does not assign tasks, pick members or issue commands.
namespace FrontRosterProbe {
    array<int> first = {-1,-1,-1};
    array<bool> lost = {false,false,false};
    int next = 0;
    int sampled = -100000;
    bool energy = false, group = false;
    void Added(int id, int seat) {
        if (ai.teamId != 0 || seat < 0) return;
        if (first[seat] < 0) {
            if (seat != next) GenericHelpers::LogUtil("[FrontRosterProbe] FAIL initial order",1);
            first[seat] = id; ++next;
        } else if (lost[seat]) {
            for (int i=0; i<seat; ++i)
                if (FrontConstructors::seats[i] < 0) GenericHelpers::LogUtil("[FrontRosterProbe] FAIL replacement order",1);
            GenericHelpers::LogUtil("[FrontRosterProbe] replaced seat="+seat+" unit="+id,1);
            lost[seat] = false;
        }
    }
    void Removed(int id, int seat) {
        if (ai.teamId == 0 && seat >= 0) lost[seat] = true;
    }
    void Tick() {
        if (ai.teamId != 0 || ai.frame-sampled < 5*SECOND) return;
        sampled = ai.frame;
        if (CommanderGroup::member >= 0) {
            if (CommanderGroup::member != FrontConstructors::seats[2])
                GenericHelpers::LogUtil("[FrontRosterProbe] FAIL commander stole another seat",1);
            else if (!group) { group=true; GenericHelpers::LogUtil("[FrontRosterProbe] commander_third",1); }
        }
        CCircuitUnit@ base = ai.GetTeamUnit(FrontConstructors::seats[0]);
        if (base is null) return;
        const float distance = sqrt(MapHelpers::SqDist(base.GetPos(ai.frame),Global::Map::StartPos));
        GenericHelpers::LogUtil("[FrontRosterProbe] base unit="+base.id+" distance="+int(distance),1);
        if (distance > Global::RoleSettings::Front::BaseSupportRadius+base.circuitDef.GetBuildDistance())
            GenericHelpers::LogUtil("[FrontRosterProbe] FAIL base left home",1);
        IBuilderTask@ task = cast<IBuilderTask>(base.task);
        if (!energy && task !is null && task.GetBuildType()==int(Task::BuildType::ENERGY)) {
            energy=true; GenericHelpers::LogUtil("[FrontRosterProbe] base_energy unit="+base.id,1);
        }
    }
}
