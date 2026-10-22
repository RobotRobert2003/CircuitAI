#include "../../global.as"
#include "../../manager/military.as"
#include "../presentation/widget_link.as"

namespace Aggression {
    // Uses already-maintained army cost and the existing legal enemy cache.
    // Called after cache publication: constant work, no unit census/messages.
    void Update() {
        const float own=aiMilitaryMgr.armyCost;
        const float enemy=Military::GetEnemySurfaceCostPerPlayer();
        aiMilitaryMgr.SetAutomaticAggression((own>0.f && enemy>0.f)
            ? Global::Military::AggressionAutoWeight*(own-enemy)/(own+enemy) : 0.f);
    }
    void Announce() {
        WidgetLink::Send("aggression", ""+aiMilitaryMgr.GetAggressionDelta()+"|"+aiMilitaryMgr.GetAutomaticAggression());
    }
    bool SetDelta(const string &in value) {
        // parseFloat accepts prefixes; require complete consumption as well as
        // a finite, bounded result. Malformed UI messages cannot change state.
        uint consumed=0;
        const float delta=float(parseFloat(value,consumed));
        if(consumed!=value.length() || consumed==0 || !(delta>=-1.f && delta<=1.f)) return false;
        aiMilitaryMgr.SetAggressionDelta(delta);
        Announce();
        return true;
    }
}
