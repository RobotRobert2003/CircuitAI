// Test-only observations. Income is supplied through the normal sliding window.
namespace ScoutSweepProbe {
    bool gateSeen=false;
    int sampled=-SECOND, wave=0;
    dictionary seen;
    void Tick() {
        if(ai.teamId!=0 || ai.frame-sampled<SECOND) return;
        sampled=ai.frame;
        const bool gate=AirScoutSweep::Gate();
        if(gate && !gateSeen) {
            gateSeen=true;
            GenericHelpers::LogUtil("[ScoutSweepProbe] gate opened frame="+ai.frame,1);
            if(ai.frame<69*SECOND) Invariants::Violation("SCOUT-GATE","fixture","gate opened before full ten-second window");
        }
        array<string>@ ids=AirScoutSweep::flying.getKeys();
        int fresh=0, scouts=0, radar=0;
        for(uint i=0;i<ids.length();++i) {
            if(seen.exists(ids[i])) continue;
            seen.set(ids[i],true); ++fresh;
            CCircuitUnit@ u=ai.GetTeamUnit(parseInt(ids[i]));
            if(u is null) continue;
            if(AirScoutSweep::Kind(u.circuitDef.GetName())==0) ++scouts; else ++radar;
            AIFloat3 end; AirScoutSweep::endpoints.get(ids[i],end);
            WidgetLink::Send("scoutsweep", "cross|"+u.id+"|"+end.x+"|"+end.z);
        }
        if(fresh>0) {
            ++wave;
            GenericHelpers::LogUtil("[ScoutSweepProbe] wave="+wave+" scouts="+scouts+" radar="+radar+" frame="+ai.frame,1);
            if(scouts!=10 || radar!=4) Invariants::Violation("SCOUT-PACKAGE","fixture","incomplete mixed package");
        }
    }
}
