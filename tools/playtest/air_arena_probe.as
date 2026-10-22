// Read-only combat observer, appended only to staged experimental main.as.
namespace AirArenaProbe {
    int serial = 0;
    int lastCommitment = -100000;
    bool rosterReported = false;
    bool responding = false;
    array<CAirWaveTask@> observed;
    array<int> serials;
    void Tick()
    {
        if (ai.teamId > 1 || Global::AISettings::Role != AiRole::AIR) return;
        if (ai.teamId == 0 && !rosterReported && AirOperations::rosterReady) {
            rosterReported = true;
            GenericHelpers::LogUtil("[AirArenaProbe] T3 roster=" + AirOperations::groundHeavyDefs.length()
                + " shiva=" + AirOperations::groundHeavyDefs.find("corshiva")
                + " telchine=" + AirOperations::groundHeavyDefs.find("legamph")
                + " home=" + int(Global::Map::StartPos.x) + "," + int(Global::Map::StartPos.z), 1);
        }
        if (ai.teamId == 1) {
            if (AirScreen::responding != responding) {
                responding = AirScreen::responding;
                WidgetLink::Send("arena", "response|" + ai.frame + "|" + (responding ? "1" : "0"));
            }
            return;
        }
        // Observe each task identity independently. Surviving committed waves
        // may overlap; watching only the newest pointer conceals later launches.
        for (int i = int(observed.length())-1; i >= 0; --i) {
            if (!observed[i].IsDead()) continue;
            WidgetLink::Send("arena", "end|" + serials[i] + "|" + ai.frame + "|" + AirWaves::learnedResistance);
            observed.removeAt(i); serials.removeAt(i);
        }
        for (uint i = 0; i < AirOperations::operations.length(); ++i) {
            CAirWaveTask@ wave = AirOperations::operations[i];
            if (wave is null || wave.IsDead() || observed.findByRef(wave) >= 0) continue;
            array<CCircuitUnit@>@ units = wave.GetUnits();
            array<string> ids;
            for (uint j = 0; j < units.length(); ++j)
                if (units[j] !is null && (AirWaves::IsWaveBomber(units[j].circuitDef) || AirRaids::IsBomber(units[j].circuitDef)))
                    ids.insertLast("" + units[j].id);
            if (ids.isEmpty()) continue;
            ids.sortAsc(); string members;
            for (uint j = 0; j < ids.length(); ++j) members += (j == 0 ? "" : ",") + ids[j];
            ++serial; observed.insertLast(wave); serials.insertLast(serial);
            WidgetLink::Send("arena", "launch|" + serial + "|" + ai.frame + "|" + wave.GetStrikeTargetId()
                + "|" + AirWaves::learnedResistance + "|" + members);
        }
        if (ai.frame-lastCommitment < 10*SECOND) return;
        lastCommitment = ai.frame;
        array<string>@ escorts = AirOperations::escorts.getKeys();
        for (uint i = 0; i < observed.length(); ++i) {
            int live = 0, owned = 0;
            for (uint j = 0; j < escorts.length(); ++j) {
                IUnitTask@ owner;
                CCircuitUnit@ unit = ai.GetTeamUnit(parseInt(escorts[j]));
                if (unit is null || !AirOperations::escorts.get(escorts[j], @owner) || owner !is observed[i]) continue;
                ++live;
                if (unit.task is owner) ++owned;
            }
            WidgetLink::Send("arena", "commitment|" + serials[i] + "|" + live + "|" + owned
                + "|" + AirScreen::IntrusionCost() + "|" + observed[i].GetState());
        }
    }
}
