// Supplied production inputs; actual FRONT recruitment and native military tasks.
namespace FrontOpenerProbe {
    bool active = false;
    string mode, side;
    int previous = -1;
    bool canceled = false;
    bool checked = false;
    int productionFactory = -1;
    IUnitTask@ unrelatedRaid;
    IUnitTask@ unrelatedDefend;
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length() < 2 || fields[0] != "front-opener") return false;
        if (fields[1] == "state" && fields.length() > 2) {
            CCircuitUnit@ unit = ai.GetTeamUnit(parseInt(fields[2]));
            if (unit !is null && unit.task !is null) {
                IFighterTask@ fighter = cast<IFighterTask>(unit.task);
                GenericHelpers::LogUtil("[FrontOpenerTest] survivor_task id=" + unit.id
                    + " type=" + int(unit.task.GetType()) + " fight=" + (fighter is null ? -1 : int(fighter.GetFightType())), 1);
            }
        }
        if (fields[1] == "setup") {
            mode = fields[2]; side = fields[3]; active = true;
            Global::AISettings::Role = AiRole::FRONT;
            Global::AISettings::Side = side;
            if (!Global::Map::MapResolved) Setup::setupMap(AIFloat3(2513,0,7983));
            if (Global::AISettings::Role != AiRole::FRONT) GenericHelpers::LogUtil("[FrontOpenerTest] FAIL wrong role", 1);
            if (mode != "profile") Global::RoleSettings::Front::VehicleTankOpenerChance = mode == "ordinary" ? 0.0f : 1.0f;
            if (mode == "timeout") Global::RoleSettings::Front::VehicleTankGatherSeconds = 20;
            if (mode == "unavailable") ai.GetCircuitDef(side == "cortex" ? "corgator" : "leghades").maxThisUnit = 0;
            Global::Spam::Enabled = false; // supplied economy must not activate a spam pump
            GenericHelpers::LogUtil("[FrontOpenerTest] configured chance=" + Global::RoleSettings::Front::VehicleTankOpenerChance, 1);
            const array<string> factories = {"coralab", "armalab", "legalab", "armavp", "legavp"};
            const array<string> units = {"corroach", "armspy", "legaspy", "armgremlin", "leginf"};
            for (uint i=0; i<factories.length(); ++i) {
                CCircuitDef@ f = ai.GetCircuitDef(factories[i]);
                CCircuitDef@ u = ai.GetCircuitDef(units[i]);
                if (f is null || u is null || !f.CanBuild(u)) GenericHelpers::LogUtil("[FrontOpenerTest] FAIL build edge " + factories[i], 1);
            }
            GenericHelpers::LogUtil("[FrontOpenerTest] build_edges_checked=5", 1);
        }
        return true;
    }
    IUnitTask@ FactoryTask(CCircuitUnit@ u) {
        if (active && !UnitHelpers::IsT1VehicleLab(u.circuitDef.GetName()) && !UnitHelpers::IsT1BotLab(u.circuitDef.GetName()))
            return aiFactoryMgr.DefaultMakeTask(u);
        if (active) productionFactory = u.id;
        if (!active) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        if (RoleFront::g_frontRaiderOpenerDone) {
            const string normal = UnitHelpers::GetFrontT1RaiderForFactory(u.circuitDef.GetName(), side);
            const string tank = side == "cortex" ? "corgator" : (side == "legion" ? "leghades" : "armflash");
            if (aiFactoryMgr.GetPendingRecruitCount(ai.GetCircuitDef(normal)) > 0
                || aiFactoryMgr.GetPendingRecruitCount(ai.GetCircuitDef(tank)) > 0)
                return aiFactoryMgr.DefaultMakeTask(u);
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        }
        return RoleFront::Front_FactoryAiMakeTask(u);
    }
    IUnitTask@ BuilderTask(CCircuitUnit@ u) {
        CCircuitUnit@ factory = ai.GetTeamUnit(productionFactory);
        if (active && factory !is null && u !is null && !u.circuitDef.IsRoleAny(Unit::Role::COMM.mask))
            return aiBuilderMgr.Enqueue(TaskB::Guard(Task::Priority::NORMAL, factory, false, 600 * SECOND));
        return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
    }
    IUnitTask@ GiftTask(CCircuitUnit@ u) {
        if (!active || u is null || u.GetProducerId() >= 0) return null;
        const string name = u.circuitDef.GetName();
        if (name != "corgator" && name != "leghades") return null;
        if (unrelatedRaid is null) { @unrelatedRaid = aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::RAID)); return unrelatedRaid; }
        if (unrelatedDefend is null) { @unrelatedDefend = aiMilitaryMgr.Enqueue(TaskF::Defend(Task::FightType::RAID, 1000.0f)); return unrelatedDefend; }
        return null;
    }
    void Tick() {
        if (!active) return;
        if (FrontOpener::gather !is null && !FrontOpener::gather.IsDead()) {
            const array<CCircuitUnit@>@ units = FrontOpener::gather.GetUnits();
            if (int(units.length()) != previous) {
                previous = units.length();
                GenericHelpers::LogUtil("[FrontOpenerTest] gathering=" + previous + " expected=" + FrontOpener::expected, 1);
            }
            for (uint i=0; i<units.length(); ++i)
                if (units[i].GetProducerId() != FrontOpener::factoryId)
                    GenericHelpers::LogUtil("[FrontOpenerTest] FAIL foreign member", 1);
            // Other FRONT quotas change independently while the opener gathers.
            aiMilitaryMgr.quota.raid.min = 100.0f;
            aiMilitaryMgr.quota.raid.avg = 200.0f;
            if (!checked) {
                checked = true;
                GenericHelpers::LogUtil("[FrontOpenerTest] power_basis=" + FrontOpener::unitPower + " threshold=" + FrontOpener::RequiredPower(), 1);
                if (mode == "spam") {
                    Global::Spam::Enabled = true;
                    Global::Spam::MinMetalIncome = 1.0f;
                    Global::Spam::FloatMetalIncome = 1.0f;
                    Global::Spam::MinEnergyIncome = 1.0f;
                    Global::Spam::MinWorkers = 0;
                    Spam::active = true;
                    CRouteTask@ route = Spam::RouteFor(ai.GetTeamUnit(FrontOpener::factoryId));
                    GenericHelpers::LogUtil("[FrontOpenerTest] " + (route is null ? "FAIL missing competing route" : "competing_spam_route_ready"), 1);
                }
            }
            if (mode == "spam" && Spam::repeatTask.exists("" + FrontOpener::factoryId))
                GenericHelpers::LogUtil("[FrontOpenerTest] FAIL spam pump stole the queued opener", 1);
            if (mode == "cancel" && !canceled && units.length() >= 3 && FrontOpener::recruits.length() > 0) {
                for (uint i=0; i<FrontOpener::recruits.length(); ++i) {
                    if (FrontOpener::recruits[i].GetUnits().length() > 0) continue;
                    canceled = true;
                    FrontOpener::recruits[i].Abort();
                    GenericHelpers::LogUtil("[FrontOpenerTest] canceled_one_recruit", 1);
                    break;
                }
            }
        }
    }
}
