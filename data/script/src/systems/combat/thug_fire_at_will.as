#include "../../define.as"
#include "../../helpers/common/generic_helpers.as"

// Owner (2026-10-19): Thugs and Maces always fire at will; Legion Barrage and
// Medusa too (owner 2026-10-20); Thanatos and Inferno (owner 2026-10-21).
//
// The C++ ranged controller puts every unit it takes over on hold fire and
// shoots only its chosen priority target. That suits slow artillery, which
// should keep its shots, but fast-firing Thugs and Maces then stand silent
// between picks. The controller sets hold fire once, when a task takes the
// unit (siege artillery such as Barrage gets return fire in CArtilleryTask), so
// each second we re-open fire for any watched unit whose task has
// changed since we last did, and re-assert it every ResendSeconds anyway.
// Every other unit keeps its fire state. Works with any DLL.
//
// Cost: O(T) per second for T tracked hulls; one fire-state command per
// unit per task change, plus one per ResendSeconds.
namespace ThugFireAtWill {
    bool Enabled = false; // the profile that polls Tick owns the tracked hulls
    const int OPEN = 2;
    const int ResendSeconds = 15;
    const int SummarySeconds = 300;

    bool Watched(CCircuitUnit@ unit)
    {
        if (unit is null || unit.circuitDef is null) return false;
        const string name = unit.circuitDef.GetName();
        return name == "corthud" || name == "armham" || name == "legbar" || name == "legmed"
            || name == "leghrk" || name == "leginf";
    }

    final class Hull {
        int id = -1;
        int sentFrame = -100000;
        IUnitTask@ task;   // task when last sent; a new task may have set hold fire
    }

    array<Hull@> hulls;
    int lastTick = -100000;
    int sent = 0, lastSummary = 0;

    // Military::AiUnitAdded
    void UnitAdded(CCircuitUnit@ unit)
    {
        if (!Enabled || !Watched(unit)) return;
        for (uint i = 0; i < hulls.length(); ++i) if (hulls[i].id == unit.id) return;
        Hull h;
        h.id = unit.id;
        hulls.insertLast(h);
    }

    // Main::AiUpdate (every 30 frames); self-limited to once per second.
    void Tick()
    {
        if (!Enabled || ai.frame < lastTick + SECOND) return;
        lastTick = ai.frame;
        const int resend = ResendSeconds * SECOND;
        for (int i = int(hulls.length()) - 1; i >= 0; --i) {
            Hull@ h = hulls[i];
            CCircuitUnit@ u = ai.GetTeamUnit(h.id);
            if (u is null) { hulls.removeAt(uint(i)); continue; }
            if (u.task is h.task && ai.frame - h.sentFrame < resend) continue;
            u.SetFireState(OPEN);
            h.sentFrame = ai.frame; @h.task = u.task;
            ++sent;
        }
        if (ai.frame - lastSummary >= SummarySeconds * SECOND) {
            lastSummary = ai.frame;
            GenericHelpers::LogUtil("[ThugFireAtWill] hulls=" + hulls.length() + " fire-at-will orders=" + sent, 1);
        }
    }
}
