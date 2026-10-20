// Owner (2026-10-19): FRONT vehicle tank masses, two tiers.
// T1: from the T1 opener (scout rush, then the Blitz/Incisor/Alaris batch) until our first
// T2 factory stands, a T1 vehicle plant rolls every Front::VehicleTankMassIntervalSeconds;
// on Front::VehicleTankMassChance it builds a random VehicleTankMassMin..Max medium tanks
// (Stout/Brute/Decurion) in succession, held at the plant until the last one is out (or the
// batch's deadline passes), then released as one raid squad on normal orders.
// T2: once a T2 vehicle plant stands, it rolls every VehicleT2TankMassIntervalSeconds on
// VehicleT2TankMassChance for VehicleT2TankMassMin..Max Bull/Tiger/Prometheus, held the same
// way, then sent at the enemy as one attack squad. For the rest of the game.
// Bots (owner, 2026-10-19): from the bot lab opener (its Pawn/Grunt/Goblin wave) until our first
// T2 factory stands, a T1 bot lab rolls every BotWaveIntervalSeconds on BotWaveChance for a random
// BotWaveMin..Max Pawns or Grunts (BotWaveGoblinMin..Max Goblins), held the same way, then sent at
// the enemy as one attack wave.
// All tiers reuse FrontOpener's cohort, so one opener-or-mass batch exists at a time and Spam keeps
// off the plant. Only the factory MakeTask calls this; no periodic job. Log [FRONT][TankMass].
namespace FrontTankMass {
    // Frame of each tier's next roll (0 T1 tanks, 1 T2 tanks, 2 bots); -1 until that tier's factory first asks
    array<int> nextRoll = {-1, -1, -1};
    bool finished = false;    // T1 tanks: a T2 factory stood, no more T1 rolls this game
    bool botFinished = false; // bots: the same
    // Owner (2026-10-19): FRONT keeps to one factory type. The first T1 land factory (the scout
    // rush lock) sets it: 0 bot lab, 1 vehicle plant; -1 not seen yet. Masses come only from that
    // type; spam and edge lane labs never roll (they build their single spam unit).
    int mainType = -1;
    void SetMain(const string &in factoryName) {
        if (mainType >= 0) return;
        if (UnitHelpers::IsT1BotLab(factoryName)) mainType = 0;
        else if (UnitHelpers::IsT1VehicleLab(factoryName)) mainType = 1;
        if (mainType >= 0) GenericHelpers::LogUtil("[FRONT][TankMass] main factory type " + (mainType == 0 ? "bots" : "vehicles"), 1);
    }

    string WaveBot(const string &in side) {
        if (side == "armada") return "armpw";   // Pawn
        if (side == "cortex") return "corak";   // Grunt
        if (side == "legion") return "leggob";  // Goblin
        return "";
    }

    string MediumTank(const string &in side) {
        if (side == "armada") return "armstump";  // Stout
        if (side == "cortex") return "corraid";   // Brute
        if (side == "legion") return "leggat";    // Decurion
        return "";
    }
    string MainTank(const string &in side) {
        if (side == "armada") return "armbull";       // Bull
        if (side == "cortex") return "correap";       // Tiger
        if (side == "legion") return "legaheattank";  // Prometheus
        return "";
    }

    // A finished T2 bot lab or vehicle plant of ours
    bool T2FactoryStands() {
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f) continue;
            const string n = f.circuitDef.GetName();
            if (UnitHelpers::IsT2BotLab(n) || UnitHelpers::IsT2VehicleLab(n)) return true;
        }
        return false;
    }

    // openerDone: the T1 scout rush and raider opener were queued
    IUnitTask@ Try(CCircuitUnit@ u, const string &in factoryName, const string &in side, bool openerDone) {
        if (u is null || EdgeLanes::IsEdgeLab(u) || Spam::routeByFactory.exists("" + u.id)) return null;
        const bool vehicle = UnitHelpers::IsT1VehicleLab(factoryName) || UnitHelpers::IsT2VehicleLab(factoryName);
        if (mainType >= 0 && (vehicle ? 1 : 0) != mainType) return null;
        if (UnitHelpers::IsT1VehicleLab(factoryName)) {
            if (finished || !openerDone || Global::RoleSettings::Front::VehicleTankMassChance <= 0.0f) return null;
            if (nextRoll[0] >= 0 && ai.frame >= nextRoll[0] && T2FactoryStands()) {
                finished = true;
                GenericHelpers::LogUtil("[FRONT][TankMass] T2 factory stands: no more T1 rolls", 1);
                return null;
            }
            return Roll(u, side, 0, Global::RoleSettings::Front::VehicleTankMassIntervalSeconds,
                Global::RoleSettings::Front::VehicleTankMassChance, MediumTank(side),
                Global::RoleSettings::Front::VehicleTankMassMin, Global::RoleSettings::Front::VehicleTankMassMax,
                Global::RoleSettings::Front::VehicleTankMassGatherSeconds, Task::FightType::RAID);
        }
        if (UnitHelpers::IsT1BotLab(factoryName)) {
            if (botFinished || !openerDone || Global::RoleSettings::Front::BotWaveChance <= 0.0f) return null;
            if (nextRoll[2] >= 0 && ai.frame >= nextRoll[2] && T2FactoryStands()) {
                botFinished = true;
                GenericHelpers::LogUtil("[FRONT][TankMass] T2 factory stands: no more bot wave rolls", 1);
                return null;
            }
            const bool goblin = side == "legion";
            return Roll(u, side, 2, Global::RoleSettings::Front::BotWaveIntervalSeconds,
                Global::RoleSettings::Front::BotWaveChance, WaveBot(side),
                goblin ? Global::RoleSettings::Front::BotWaveGoblinMin : Global::RoleSettings::Front::BotWaveMin,
                goblin ? Global::RoleSettings::Front::BotWaveGoblinMax : Global::RoleSettings::Front::BotWaveMax,
                Global::RoleSettings::Front::BotWaveGatherSeconds, Task::FightType::ATTACK);
        }
        if (UnitHelpers::IsT2VehicleLab(factoryName)) {
            if (Global::RoleSettings::Front::VehicleT2TankMassChance <= 0.0f || u.GetBuildProgress() < 1.0f) return null;
            return Roll(u, side, 1, Global::RoleSettings::Front::VehicleT2TankMassIntervalSeconds,
                Global::RoleSettings::Front::VehicleT2TankMassChance, MainTank(side),
                Global::RoleSettings::Front::VehicleT2TankMassMin, Global::RoleSettings::Front::VehicleT2TankMassMax,
                Global::RoleSettings::Front::VehicleT2TankMassGatherSeconds, Task::FightType::ATTACK);
        }
        return null;
    }

    IUnitTask@ Roll(CCircuitUnit@ u, const string &in side, uint t, int intervalSeconds,
                    float chance, const string &in tankName, int minCount, int maxCount, int gatherSeconds,
                    Task::FightType promote) {
        const string tier = t == 0 ? "T1" : (t == 1 ? "T2" : "Bots");
        const int interval = AiMax(1, intervalSeconds) * SECOND;
        if (nextRoll[t] < 0) {
            nextRoll[t] = ai.frame + interval;
            GenericHelpers::LogUtil("[FRONT][TankMass] " + tier + " first roll at " + (nextRoll[t] / SECOND) + " s", 1);
            return null;
        }
        if (ai.frame < nextRoll[t]) return null;
        // Owner (2026-10-20): an artillery squad still gathering at this plant: roll once it departs
        if (t == 1 && FrontArtySquad::Gathering(u.id)) return null;
        // The opener's tanks or the last mass still gather: roll once they are released
        if (!FrontOpener::closed) {
            if (ai.frame < FrontOpener::deadline) return null;
            FrontOpener::Close();
        }
        nextRoll[t] = ai.frame + interval;
        // Owner (2026-10-20): the T2 roll also carries VehicleT2ArtySquadChance for a faction artillery squad
        const float squadChance = t == 1 ? AiMax(0.0f, Global::RoleSettings::Front::VehicleT2ArtySquadChance) : 0.0f;
        if (chance < 1.0f || squadChance > 0.0f) {
            // AiDice's rare -1 endpoint counts as a miss (KI-628, as FrontOpener::ChooseTank)
            const array<float> weights = {AiMax(0.0f, 1.0f - chance - squadChance), chance, squadChance};
            const int pick = AiDice(weights);
            if (pick == 2) {
                IUnitTask@ squad = FrontArtySquad::Begin(u, side, gatherSeconds);
                if (squad !is null) {
                    GenericHelpers::LogUtil("[FRONT][TankMass] " + tier + " roll hit the artillery squad at factory " + u.id
                        + "; next roll at " + (nextRoll[t] / SECOND) + " s", 1);
                    return squad;
                }
                // no squad possible (Legion without a T2 bot lab): the tank wave instead
            } else if (pick != 1) {
                GenericHelpers::LogUtil("[FRONT][TankMass] " + tier + " roll missed; next at " + (nextRoll[t] / SECOND) + " s", 1);
                return null;
            }
        }
        CCircuitDef@ def = ai.GetCircuitDef(tankName);
        if (def is null || !u.circuitDef.CanBuild(def) || !def.IsAvailable(ai.frame) || def.power <= 0.0f) {
            GenericHelpers::LogUtil("[FRONT][TankMass] " + tier + " roll hit but no tank '" + tankName + "' at " + u.circuitDef.GetName(), 1);
            return null;
        }
        const int lo = AiMax(1, minCount);
        const int count = AiRandom(lo, AiMax(lo, maxCount));
        // Owner (2026-10-19/20): each T2 wave gets a jammer, radar and flak vehicle from the same plant,
        // queued first so they are out before the tanks; the wave holds until they are
        IUnitTask@ escortFirst = null;
        if (t == 1) @escortFirst = FrontWaveEscort::Begin(u, side, def, count, gatherSeconds);
        FrontOpener::Begin(u, def, count, gatherSeconds, promote);
        const AIFloat3 pos = u.GetPos(ai.frame);
        IUnitTask@ last = null;
        for (int i = 0; i < count; ++i) {
            @last = aiFactoryMgr.Enqueue(
                TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, def, pos, 64.f)
            );
            FrontOpener::Recruit(last);
        }
        GenericHelpers::LogUtil("[FRONT][TankMass] " + tier + " roll hit: " + count + " x " + def.GetName() + " at factory "
            + u.id + "; next roll at " + (nextRoll[t] / SECOND) + " s", 1);
        return escortFirst !is null ? escortFirst : last;
    }
}
