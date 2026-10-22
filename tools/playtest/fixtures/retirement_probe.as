// Injected only into an isolated test profile, never production data.
namespace RetirementProbe {
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length() != 2 || fields[0] != "retirement-probe") return false;
        CCircuitUnit@ factory = ai.GetTeamUnit(parseInt(fields[1]));
        if (factory !is null) Lifecycle::Retire(factory, "isolated retirement regression");
        return true;
    }
    IUnitTask@ MakeTask(CCircuitUnit@ factory) {
        if (!factory.IsProductionEnabled()) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        string product;
        const string name = factory.circuitDef.GetName();
        if (name == "armalab") product = "armack";
        else if (name == "coralab") product = "corack";
        else if (name == "legalab") product = "legack";
        else return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        CCircuitDef@ definition = ai.GetCircuitDef(product);
        if (definition is null) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        definition.maxThisUnit = 1000;
        return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH,
            definition, factory.GetPos(ai.frame), 64.0f, true));
    }
}
