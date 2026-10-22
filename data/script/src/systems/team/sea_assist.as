// SEA seeds a TACTICAL ally with a construction ship so it can go coastal.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../types/ai_role.as"
#include "roster.as"
#include "../presentation/widget_link.as"

/******************************************************************************

SEA ASSIST

TACTICAL starts with both shipyard caps at zero
(`Global::RoleSettings::Tactical::StartCapT1Shipyards` / `...T2Shipyards`), so
it cannot touch the water at all - it is a hover role and the caps keep it
from wandering into a naval game it has no constructor for.

That is the right default alone and the wrong one next to a SEA ally. A
TACTICAL player with one construction ship can expand along the coast beside
the SEA player, hold the shoreline it is already good at fighting over, and
add naval economy the SEA player does not have to build itself.

So: once SEA's economy can spare it, SEA hands **one** T1 construction ship to
a TACTICAL ally, once, and TACTICAL lifts its own naval caps the moment it
owns a sea constructor.

  SEA       metal income clears MinMetalIncome, a TACTICAL ally is on the
            roster, and we hold more than KeepConstructors construction ships
            -> give one away, announce it, and never do it again
  TACTICAL  owns a sea constructor from any source -> raise the shipyard caps
            to UnlockedT1Shipyards / UnlockedT2Shipyards, AND enqueue a T1
            shipyard where the ship is standing. Lifting a cap grants
            permission; nothing in TACTICAL's builder policy ever *asks* for a
            naval structure, so without the seed the ship was given, unlocked,
            and then sat idle in SEA's water with no task it could reach.

The unlock is keyed on **owning the constructor**, not on having received the
message, because that is the condition that actually matters: a TACTICAL that
gets a construction ship any other way - a human gift, an orphan rescue -
should be able to use it. The message is an announcement, not the trigger.

Note the two senses of "role" in here. `Global::AISettings::Role` and
`Team::Roster::Entry::role` are **AiRole**, the start-position player role that
decides who donates and who receives. `Unit::Role::*` is a unit's config role
and never appears in that decision - the units are matched by name against
UnitHelpers' constructor lists.

See doc/roles/sea.md and doc/roles/tactical.md.

******************************************************************************/
namespace Team {
namespace SeaAssist {

    const string MSG = "barbnavy";

    // ---- SEA side
    array<int> seaCtorIds;         // our T1 construction ships
    bool donated = false;          // once per SEA instance

    // ---- TACTICAL side
    bool navalUnlocked = false;

    bool IsEnabled() { return Global::SeaAssist::Enabled; }

    bool _InList(const array<string>@ list, const string &in name)
    {
        for (uint i = 0; i < list.length(); ++i) {
            if (list[i] == name) return true;
        }
        return false;
    }

    bool IsT1SeaConstructor(const CCircuitDef@ d)
    {
        if (d is null) return false;
        array<string> ids = UnitHelpers::GetAllT1SeaConstructors();
        return _InList(ids, d.GetName());
    }

    // Any sea constructor unlocks TACTICAL's naval caps, not just a donated
    // T1 one.
    bool IsAnySeaConstructor(const CCircuitDef@ d)
    {
        if (d is null) return false;
        array<string> t1 = UnitHelpers::GetAllT1SeaConstructors();
        if (_InList(t1, d.GetName())) return true;
        array<string> t2 = UnitHelpers::GetAllT2SeaConstructors();
        return _InList(t2, d.GetName());
    }

    /**************************************************************************
     TACTICAL: stop pretending the water does not exist.
     **************************************************************************/
    void UnlockNaval(CCircuitUnit@ ship, const string &in why)
    {
        if (navalUnlocked) return;
        navalUnlocked = true;
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1Shipyards(),
                Global::SeaAssist::UnlockedT1Shipyards);
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(),
                Global::SeaAssist::UnlockedT2Shipyards);
        GenericHelpers::LogUtil("[SeaAssist] TACTICAL: naval unlocked (" + why + "); shipyard caps now "
            + Global::SeaAssist::UnlockedT1Shipyards + "/" + Global::SeaAssist::UnlockedT2Shipyards, 1);
        WidgetLink::Send("seaassist", "unlocked|" + Global::SeaAssist::UnlockedT1Shipyards);
        SeedShipyard(ship);
    }

    // Demand, not just permission. A T1 shipyard at the ship's own position:
    // that is water it can certainly reach, and the constructor is the
    // representer for the site test - it is a ship, so the native area check
    // is answered by the unit that will actually do the building. Priority
    // NOW so the idle ship picks it up on its next task query rather than
    // waiting behind TACTICAL's land queue.
    void SeedShipyard(CCircuitUnit@ ship)
    {
        if (ship is null || ship.circuitDef is null) return;
        const string yard = UnitHelpers::GetT1ShipyardForSide(Global::AISettings::Side);
        CCircuitDef@ yardDef = ai.GetCircuitDef(yard);
        CCircuitDef@ reprDef = ai.GetCircuitDef(ship.circuitDef.GetName());
        if (yardDef is null || reprDef is null) {
            GenericHelpers::LogUtil("[SeaAssist] TACTICAL: cannot seed a shipyard; '" + yard + "' not loaded", 2);
            return;
        }
        const AIFloat3 at = ship.GetPos(ai.frame);
        aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, yardDef, at, reprDef,
                Global::SeaAssist::SeedShake));
        GenericHelpers::LogUtil("[SeaAssist] TACTICAL: seeded " + yard + " near ("
            + int(at.x) + "," + int(at.z) + ") for ship " + ship.id, 1);
        WidgetLink::Send("seaassist", "seed|" + yard + "|" + int(at.x) + "|" + int(at.z));
    }

    /**************************************************************************
     Unit bookkeeping. Builder::AiUnitAdded / AiUnitRemoved, role-independent:
     each branch below checks the role it cares about.
     **************************************************************************/
    void OnUnitAdded(CCircuitUnit@ unit)
    {
        if (!IsEnabled() || unit is null || unit.circuitDef is null) return;

        if (Global::AISettings::Role == AiRole::TACTICAL) {
            if (IsAnySeaConstructor(unit.circuitDef)) {
                UnlockNaval(unit, "owns " + unit.circuitDef.GetName());
            }
            return;
        }
        if (Global::AISettings::Role == AiRole::SEA) {
            if (IsT1SeaConstructor(unit.circuitDef)) {
                seaCtorIds.insertLast(unit.id);
            }
        }
    }

    void OnUnitRemoved(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        for (uint i = 0; i < seaCtorIds.length(); ++i) {
            if (seaCtorIds[i] == unit.id) {
                seaCtorIds.removeAt(i);
                return;
            }
        }
    }

    /**************************************************************************
     SEA: pick a TACTICAL ally. AiRole, not unit role.
     **************************************************************************/
    int PickTactical()
    {
        array<Team::Roster::Entry@>@ all = Team::Roster::All();
        if (all is null) return -1;
        int best = -1;
        for (uint i = 0; i < all.length(); ++i) {
            Team::Roster::Entry@ e = all[i];
            if (e is null || e.teamId == ai.teamId) continue;
            if (e.role != AiRole::TACTICAL) continue;
            // Lowest team id wins, so two SEA players on one team both pick the
            // same TACTICAL rather than each seeding a different one. Seeding
            // one ally properly beats seeding two halfway.
            if (best < 0 || e.teamId < best) best = e.teamId;
        }
        return best;
    }

    /**************************************************************************
     Tick. Main::AiUpdate, every 30 frames.
     **************************************************************************/
    void Update()
    {
        if (!IsEnabled() || donated) return;
        if (Global::AISettings::Role != AiRole::SEA) return;
        if (Economy::GetMinMetalIncomeLast10s() < Global::SeaAssist::MinMetalIncome) return;
        // Keep our own. A construction ship is 200 metal and SEA needs its own
        // expansion first; only the surplus goes.
        if (int(seaCtorIds.length()) <= Global::SeaAssist::KeepConstructors) return;

        const int recipient = PickTactical();
        if (recipient < 0) return;   // no TACTICAL ally: nothing to do, ever

        CCircuitUnit@ ctor = ai.GetTeamUnit(seaCtorIds[seaCtorIds.length() - 1]);
        if (ctor is null) {
            seaCtorIds.removeLast();
            return;
        }
        array<CCircuitUnit@> give(1);
        @give[0] = ctor;
        ai.GiveUnits(give, recipient);
        donated = true;
        AiSendMessage(MSG + "|ctor", recipient);
        GenericHelpers::LogUtil("[SeaAssist] SEA: gave " + ctor.circuitDef.GetName()
            + "(" + ctor.id + ") to TACTICAL team " + recipient, 1);
        WidgetLink::Send("seaassist", "gave|" + ctor.id + "|" + recipient);
    }

    /**************************************************************************
     Messages. Team::HandleMessage routes here.
     **************************************************************************/
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        if (!IsEnabled()) return false;
        array<string>@ p = msg.split("|");
        if (p.length() < 2 || p[0] != MSG) return false;
        if (p[1] == "ctor") {
            // Announcement only; OnUnitAdded does the unlocking when the unit
            // actually arrives, which is the condition that matters.
            GenericHelpers::LogUtil("[SeaAssist] Team " + fromTeamId + " is sending us a construction ship", 2);
            return true;
        }
        return false;
    }

}  // namespace SeaAssist
}  // namespace Team
