// Isolated host regression: exercise real callback arbitration, not a copy.
namespace FerryOwnershipProbe {
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length() != 2 || fields[0] != "ferry-ownership-probe") return false;
        CCircuitUnit@ unit = ai.GetTeamUnit(parseInt(fields[1]));
        if (unit is null) {
            GenericHelpers::LogUtil("[FerryOwnershipTest] FAIL missing unit", 1);
            return true;
        }
        Team::Ferry::queuedCargo.insertLast(unit.id);
        Team::Ferry::queuedRecipient.insertLast(1);
        IUnitTask@ hold = Builder::AiMakeTask(unit);
        if (hold is null || hold.GetType() != Task::Type::WAIT) {
            GenericHelpers::LogUtil("[FerryOwnershipTest] FAIL shared callback diverted gift", 1);
            return true;
        }
        aiBuilderMgr.AssignTask(unit, hold);
        // Repeated asks must preserve the same hold, including direct role entry.
        IUnitTask@ repeated = Builder::AiMakeTask(unit);
        IUnitTask@ direct = TechRules::Evaluate(unit);
        if (repeated !is hold || direct !is hold)
            GenericHelpers::LogUtil("[FerryOwnershipTest] FAIL hold replaced", 1);
        else GenericHelpers::LogUtil("[FerryOwnershipTest] PASS " + unit.circuitDef.GetName(), 1);
        return true;
    }
}
