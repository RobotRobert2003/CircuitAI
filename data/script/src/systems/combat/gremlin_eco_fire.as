#include "../../define.as"
#include "../../unit.as"
#include "../../global.as"
#include "../../settings/shared/gremlin_eco_fire.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"

// Owner (2026-10-19): Gremlins still scout like spy bots, but shoot enemy economy.
//
// The game ships armgremlin on hold fire (firestate = 0), and experimental_balanced
// gives it power 0 so the native CScoutTask never picks a target and only paths
// round threats to scout points. That task is left alone. Once per second each of
// our Gremlins is set to fire at will while an observed enemy economy structure
// (extractor, energy, converter, storage) is within weapon reach and no other
// observed ground contact is near that reach; otherwise back to hold fire. The
// engine then fires on the move at the only thing it can see, and the Gremlin
// keeps its hold-position move state, so it never chases.
//
// Cost: one O(G) pass over the ground contacts per Gremlin per second, G observed
// ground contacts. Commands: a fire-state change only when the wanted state flips,
// re-sent every ResendSeconds while it stands.
namespace GremlinEcoFire {
    const string Name = "armgremlin";
    const int HOLD = 0, OPEN = 2;
    // Economy structures from the game's own economy unit folders (test-31677).
    // Extractors and wind generators are also caught by the contact kind bits.
    const array<string> EcoNames = {
        "armadvsol", "armafus", "armageo", "armamex", "armckfus", "armestor", "armfmkr", "armfus", "armgeo", "armgmm",
        "armmakr", "armmex", "armmmkr", "armmoho", "armmstor", "armsolar", "armtide", "armuwadves", "armuwadvms",
        "armuwageo", "armuwes", "armuwfus", "armuwgeo", "armuwmme", "armuwmmm", "armuwms", "armwin",
        "coradvsol", "corafus", "corageo", "corestor", "corfmkr", "corfus", "corgeo", "cormakr", "cormex", "cormmkr",
        "cormoho", "cormstor", "corsolar", "cortide", "coruwadves", "coruwadvms", "coruwageo", "coruwes", "coruwfus",
        "coruwgeo", "coruwmme", "coruwmmm", "coruwms", "corwin",
        "legadveconv", "legadvestore", "legadvsol", "legafus", "legageo", "legamstor", "leganavaladvgeo",
        "leganavaleconv", "leganavalfusion", "leganavalmex", "legeconv", "legestor", "legfeconv", "legfus", "leggeo",
        "legmex", "legmoho", "legmohobp", "legmohobpct", "legmohocon", "legmohoconct", "legmohoconin", "legmstor",
        "legsolar", "legtide", "leguwestore", "leguwgeo", "leguwmstore", "legwin"
    };

    final class Gremlin {
        int id = -1;
        int state = HOLD;      // last fire state sent
        int sentFrame = -100000;
        IUnitTask@ task;       // task when last sent: a new task may have reset the fire state
    }

    array<Gremlin@> gremlins;
    array<bool> ecoByDef;
    bool rosterReady = false;
    int lastTick = -100000;
    int opens = 0, holds = 0;  // fire-state commands this game, for the summary line
    int lastSummary = 0;

    bool Active() { return Global::GremlinEcoFire::Enabled; }

    void InitRoster()
    {
        if (rosterReady) return;
        rosterReady = true;
        ecoByDef.resize(ai.GetDefCount() + 1);
        for (uint i = 0; i < ecoByDef.length(); ++i) ecoByDef[i] = false;
        int found = 0;
        for (uint i = 0; i < EcoNames.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(EcoNames[i]);
            if (d is null || d.id < 0 || d.id >= int(ecoByDef.length())) continue;
            ecoByDef[d.id] = true; ++found;
        }
        GenericHelpers::LogUtil("[GremlinEcoFire] roster eco defs=" + found + " of " + EcoNames.length(), 1);
    }

    bool IsEco(int defId, int kind)
    {
        if ((kind & 3) != 0) return true;   // CBattleAnalysis::K_MEX | K_WIND
        return defId >= 0 && defId < int(ecoByDef.length()) && ecoByDef[defId];
    }

    // Military::AiUnitAdded
    void UnitAdded(CCircuitUnit@ unit)
    {
        if (unit is null || unit.circuitDef is null || !Active() || unit.circuitDef.GetName() != Name) return;
        for (uint i = 0; i < gremlins.length(); ++i) if (gremlins[i].id == unit.id) return;
        Gremlin g;
        g.id = unit.id;
        gremlins.insertLast(g);
    }

    // OPEN when an observed economy structure is in reach and nothing else is near it.
    int Wanted(const AIFloat3& in pos, float range, int &out target)
    {
        target = -1;
        const float reach = range + Global::GremlinEcoFire::ReachMargin;
        const float guard = range + Global::GremlinEcoFire::GuardMargin;
        float best = reach * reach;
        bool eco = false;
        const int n = aiBattle.GetGroundContactCount();
        for (int i = 0; i < n; ++i) {
            const float d = MapHelpers::SqDist(pos, aiBattle.GetGroundContactPos(i));
            if (d > guard * guard) continue;
            if (!IsEco(aiBattle.GetGroundContactDefId(i), aiBattle.GetGroundContactKind(i))) return HOLD;
            if (d <= best) { best = d; eco = true; target = aiBattle.GetGroundContactId(i); }
        }
        return eco ? OPEN : HOLD;
    }

    // Main::AiUpdate (every 30 frames); self-limited to once per second.
    void Tick()
    {
        if (ai.frame < lastTick + SECOND) return;
        lastTick = ai.frame;
        if (!Active() || gremlins.length() == 0) return;
        InitRoster();
        const int resend = Global::GremlinEcoFire::ResendSeconds * SECOND;
        for (int i = int(gremlins.length()) - 1; i >= 0; --i) {
            Gremlin@ g = gremlins[i];
            CCircuitUnit@ u = ai.GetTeamUnit(g.id);
            if (u is null) { gremlins.removeAt(uint(i)); continue; }
            const AIFloat3 pos = u.GetPos(ai.frame);
            int target;
            const int want = Wanted(pos, u.circuitDef.GetMaxRange(), target);
            const bool flip = want != g.state;
            // A task change may have reset the def's hold fire; while open, re-assert it.
            if (!flip && !(want == OPEN && (u.task !is g.task || ai.frame - g.sentFrame >= resend))) continue;
            u.SetFireState(want);
            g.state = want; g.sentFrame = ai.frame; @g.task = u.task;
            if (want == OPEN) ++opens; else ++holds;
            if (flip) GenericHelpers::LogUtil("[GremlinEcoFire] unit=" + g.id + (want == OPEN ? " fire at eco target=" + target : " hold")
                + " at (" + int(pos.x) + "," + int(pos.z) + ")", 1);
        }
        if (ai.frame - lastSummary >= 300 * SECOND) {
            lastSummary = ai.frame;
            GenericHelpers::LogUtil("[GremlinEcoFire] gremlins=" + gremlins.length() + " opens=" + opens + " holds=" + holds, 1);
        }
    }
}
