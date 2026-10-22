#include "../../global.as"
#include "../../helpers/spatial/map_helpers.as"

// D-076: one lifecycle state per structure, read by every actor.
//
// A structure is framed, active, retiring or gone. The first two the engine
// tells us (a frame is under construction, a unit stands); retiring and gone
// are recorded here, once, by the act that decides them, and every other act
// reads them from here. Played: the T1 lab was reclaimed by a constructor and
// a turret while the factory rows kept it producing a Lazarus, because the
// reclaim was a private idea of one act.
//
// Retiring means: production stops now (CmdStop), the factory rows return
// nothing for it, guards and the commander's help end, layout holds nothing
// for it any more, and only reclaim tasks may target it.
namespace Lifecycle {
    dictionary retiringSince;   // unit id -> frame the structure was retired
    dictionary retiringX;       // unit id -> position, kept LifecycleMemorySeconds after the structure is gone (INV-001)
    dictionary retiringZ;
    dictionary goneAt;          // unit id -> frame the structure was removed
    dictionary retiringName;    // unit id -> def name, for the log after it is gone
    array<string> ids;          // every id ever retired; a handful per game

    bool IsRetiringId(int id) { return retiringSince.exists("" + id); }
    bool IsRetiring(CCircuitUnit@ u) { return u !is null && IsRetiringId(u.id); }

    // The act that decides a structure's end calls this once. Idempotent.
    void Retire(CCircuitUnit@ u, const string &in why)
    {
        if (u is null || u.circuitDef is null) return;
        const string key = "" + u.id;
        if (retiringSince.exists(key)) return;
        const AIFloat3 p = u.GetPos(ai.frame);
        retiringSince.set(key, int64(ai.frame));
        retiringX.set(key, double(p.x));
        retiringZ.set(key, double(p.z));
        retiringName.set(key, u.circuitDef.GetName());
        ids.insertLast(key);
        // Close native admission before engine commands can generate an idle
        // callback. Previously a pending recruit could restart after STOP.
        u.SetProductionEnabled(false);
        // production and the queue end now; the unit being built inside a
        // factory is dropped by the engine (native binding, build26)
        u.CmdRepeat(false);
        u.CmdClearBuildQueue();
        u.CmdStop();
        GenericHelpers::LogUtil("[LIFECYCLE] " + u.circuitDef.GetName() + " " + u.id + " retiring: " + why, 1);
    }

    // The unit-removed hook: the position is remembered a while for INV-001.
    void Forget(CCircuitUnit@ u)
    {
        if (u is null) return;
        const string key = "" + u.id;
        if (retiringSince.exists(key) && !goneAt.exists(key)) {
            goneAt.set(key, int64(ai.frame));
            string name; retiringName.get(key, name);
            GenericHelpers::LogUtil("[LIFECYCLE] " + name + " " + u.id + " gone", 1);
        }
    }

    string Describe(CCircuitUnit@ u)
    {
        if (u is null) return "gone";
        return IsRetiring(u) ? "retiring" : "active";
    }
}
