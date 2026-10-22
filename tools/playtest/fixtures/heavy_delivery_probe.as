// Supplied logistics fixture: production budget tests live in heavy_strategy_probe.
// Register real spawned cargo in the same persistent delivery ledger; observe
// physical engine load/unload/ownership independently in the Lua test widget.
namespace HeavyDeliveryProbe {
    bool active = false;
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length() < 2 || fields[0] != "heavy-logistics") return false;
        if (fields[1] == "setup") {
            active = true;
            if (Builder::commander !is null) {
                aiBuilderMgr.AssignTask(Builder::commander, aiBuilderMgr.Enqueue(TaskB::Wait(15 * MINUTE)));
                Builder::commander.CmdStop();
            }
            if (ai.teamId == 0) {
                // Supplied combat cargo has no factory provenance or earned
                // income. This fixture does not claim natural economy timing.
                Global::RoleSettings::Tech::PlanCombatGate = 0.0f;
                Global::RoleSettings::Tech::FirstFactorySeconds = 900;
                Global::RoleSettings::Tech::StrategyMask = uint(1) << uint(Strategy::T2_RUSH);
                Global::RoleSettings::Tech::HeavyTransportPoolEnabled = fields[2] != "walk" && fields[2] != "mex";
                if (fields[2] == "request" || fields[2] == "local") {
                    Team::HeavyTransport::desired = 2;
                    aiTerrainMgr.SetLayoutInt(Team::HeavyTransport::TargetKey, 2);
                    Global::Ferry::RequestCooldownSeconds = 30.0f;
                }
                GenericHelpers::LogUtil("[HeavyDeliveryTest] mapping=" + TechHeavyRush::UnitName(), 1);
            }
            return true;
        }
        if (fields[1] == "cargo" && ai.teamId == 0) {
            const int id = parseInt(fields[2]);
            CCircuitUnit@ unit = ai.GetTeamUnit(id);
            if (fields.length()>3 && fields[3]=="constructor") {
                if (unit is null || !Team::Ferry::TryCarry(unit,2,AIFloat3(4550,0,7750),true))
                    GenericHelpers::LogUtil("[HeavyDeliveryTest] FAIL constructor refused",1);
                return true;
            }
            if (unit is null || unit.circuitDef.GetName() != TechHeavyRush::UnitName()) {
                GenericHelpers::LogUtil("[HeavyDeliveryTest] FAIL cargo definition", 1); return true;
            }
            const int index = TechHeavyRush::completed;
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey + "gift." + index, id);
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey + "sent." + index, 0);
            TechHeavyDelivery::Record(index, id);
            ++TechHeavyRush::completed;
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey + "completed", TechHeavyRush::completed);
            return true;
        }
        if (fields[1] == "sample" && ai.teamId == 0) {
            GenericHelpers::LogUtil("[HeavyDeliveryTest] sample selected=" + TechHeavyRush::Recipient()
                + " carriers=" + Team::HeavyTransport::CompletedCount() + " desired=" + Team::HeavyTransport::desired, 1);
            return true;
        }
        return true;
    }
}
