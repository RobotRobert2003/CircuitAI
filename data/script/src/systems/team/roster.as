// Allied BARb roster: who is on our team, where they started, what they play.
#include "../../define.as"
#include "../../global.as"
#include "../../types/ai_role.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../presentation/widget_link.as"

/******************************************************************************

TEAM ROSTER

Every BARb instance on an ally team announces itself to the others with
AiSendMessage, and keeps what the others announce. The transport is in-process
(CInitScript::SendMessage queues a job on each allied instance's scheduler, so
delivery is asynchronous but same-frame-ordered and never re-entrant); human
allies and enemies never see it. The message is one line:

    roster|<version>|teamId|skirmishAIId|role|side|startFactory|x|z|landLocked|spotIndex|isLeader

Announcing starts as soon as this instance knows its own role and start
position (Setup resolves the role on the first factory choice, the start
position is captured from the commander), and repeats every RebroadcastFrames
until every allied team id from ai.GetTeamIds() has answered or GiveUpFrames
have passed. An instance that receives an announcement from a team it did not
know answers with its own, so late starters get the roster too; an instance
that already knew the sender just refreshes the entry, which ends the exchange.

Consumers read Team::Roster::Get / All / WithRole / Leader / Nearest. The lead
team (ai.GetLeadTeamId(), the instance that owns the native ally-team object)
is marked so donation logic can find it without a second query.

******************************************************************************/
namespace Team {
namespace Roster {
    const string Prefix = "roster|";
    const int Version = 1;
    const int RebroadcastFrames = 30 * SECOND;   // between announcements while allies are missing
    const int GiveUpFrames = 5 * MINUTE;         // stop repeating after this; replies still work

    class Entry {
        int teamId = -1;
        int skirmishAIId = -1;
        AiRole role = AiRole::FRONT;
        string side;
        string startFactory;
        AIFloat3 startPos;
        AIFloat3 firstMex = AIFloat3(-1.0f, 0.0f, -1.0f);
        bool landLocked = false;
        int spotIndex = -1;        // index into Global::Map::Config.StartSpots, -1 when none
        bool isLeader = false;
        int advancedConstructors = 0; // explicit allied acknowledgement, never allied task inspection
        int commanderId = -1; // publish identity on change, query live position only when needed
        int receivedFrame = -1;
    }

    dictionary entries;            // team id string -> Entry@
    int firstBroadcastFrame = -1;
    int lastBroadcastFrame = -1;
    int lastAdvancedConstructors = -1;
    int lastCommanderId = -1;

    int CommanderId() { return Builder::commander is null ? -1 : Builder::commander.id; }
    AIFloat3 DeliveryAnchor(Entry@ entry) {
        if (entry is null) return AIFloat3(-1.0f, 0.0f, -1.0f);
        if (entry.commanderId >= 0) {
            const AIFloat3 commander = ai.GetFriendlyUnitPosition(entry.commanderId, entry.teamId);
            if (commander.x >= 0.0f) return commander;
        }
        return entry.firstMex;
    }

    int AdvancedConstructors() {
        int completed = 0;
        array<string> definitions = UnitHelpers::GetAllT2BotConstructors();
        for (uint index = 0; index < definitions.length(); ++index) {
            CCircuitDef@ definition = ai.GetCircuitDef(definitions[index]);
            if (definition !is null) completed += definition.count - aiBuilderMgr.GetUnfinishedCount(definition);
        }
        return completed;
    }

    AIFloat3 firstMex(-1.0f, 0.0f, -1.0f);
    void ObserveMex()
    {
        if (firstMex.x >= 0.0f) {
            aiTerrainMgr.SetLayoutInt("roster.mex.x", int(firstMex.x));
            aiTerrainMgr.SetLayoutInt("roster.mex.z", int(firstMex.z));
            return;
        }
        const int x = aiTerrainMgr.GetLayoutInt("roster.mex.x", -1);
        if (x >= 0) {
            firstMex = AIFloat3(float(x), 0.0f, float(aiTerrainMgr.GetLayoutInt("roster.mex.z", -1)));
            return;
        }
        array<Id>@ ids = ai.GetOwnedUnitIds();
        CCircuitUnit@ chosen = null;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef.GetExtractsMetal() <= 0.0f || u.GetBuildProgress() < 1.0f) continue;
            if (chosen is null || u.id < chosen.id) @chosen = u;
        }
        if (chosen is null) return;
        firstMex = chosen.GetPos(ai.frame);
        aiTerrainMgr.SetLayoutInt("roster.mex.x", int(firstMex.x));
        aiTerrainMgr.SetLayoutInt("roster.mex.z", int(firstMex.z));
        GenericHelpers::LogUtil("[Team][Roster] first mex " + chosen.id + " at " + int(firstMex.x) + "," + int(firstMex.z), 1);
        Reannounce();
    }
    string RoleName(AiRole r)
    {
        switch (r) {
            case AiRole::FRONT: return "FRONT";
            case AiRole::AIR: return "AIR";
            case AiRole::TECH: return "TECH";
            case AiRole::SEA: return "SEA";
            case AiRole::SUPPORT: return "SUPPORT";
            case AiRole::TACTICAL: return "TACTICAL";
        }
        return "FRONT";
    }

    AiRole RoleFromName(const string &in n)
    {
        if (n == "AIR") return AiRole::AIR;
        if (n == "TECH") return AiRole::TECH;
        if (n == "SEA") return AiRole::SEA;
        if (n == "SUPPORT") return AiRole::SUPPORT;
        if (n == "TACTICAL") return AiRole::TACTICAL;
        return AiRole::FRONT;
    }

    // Own role and start position are known.
    bool IsReady()
    {
        return Global::Map::MapResolved && Global::Map::HasStart;
    }

    int OwnSpotIndex()
    {
        StartSpot@[]@ spots = Global::Map::Config.StartSpots;
        if (spots is null || spots.length() == 0) return -1;
        return MapHelpers::NearestSpotIdx(Global::Map::StartPos, spots);
    }

    string Encode()
    {
        const AIFloat3 pos = Global::Map::StartPos;
        return Prefix + Version
            + "|" + ai.teamId
            + "|" + ai.skirmishAIId
            + "|" + RoleName(Global::AISettings::Role)
            + "|" + Global::AISettings::Side
            + "|" + Global::AISettings::StartFactory
            + "|" + int(pos.x)
            + "|" + int(pos.z)
            + "|" + (Global::Map::LandLocked ? 1 : 0)
            + "|" + OwnSpotIndex()
            + "|" + ((ai.teamId == ai.GetLeadTeamId()) ? 1 : 0)
            + "|" + int(firstMex.x) + "|" + int(firstMex.z)
            + "|" + AdvancedConstructors() + "|" + CommanderId();
    }

    // Returns null when the message is not a roster line of a supported version.
    Entry@ Decode(const string &in msg)
    {
        if (msg.length() < Prefix.length() || msg.substr(0, Prefix.length()) != Prefix) return null;
        array<string>@ parts = msg.split("|");
        if (parts.length() < 12 || int(parseInt(parts[1])) != Version) return null;
        Entry e;
        e.teamId = int(parseInt(parts[2]));
        e.skirmishAIId = int(parseInt(parts[3]));
        e.role = RoleFromName(parts[4]);
        e.side = parts[5];
        e.startFactory = parts[6];
        e.startPos = AIFloat3(float(parseInt(parts[7])), 0.0f, float(parseInt(parts[8])));
        e.landLocked = (parseInt(parts[9]) != 0);
        e.spotIndex = int(parseInt(parts[10]));
        e.isLeader = (parseInt(parts[11]) != 0);
        if (parts.length() >= 14) {
            const int x = int(parseInt(parts[12])), z = int(parseInt(parts[13]));
            if (x >= 0 && z >= 0 && x < AiTerrainWidth() && z < AiTerrainHeight())
                e.firstMex = AIFloat3(float(x), 0.0f, float(z));
        }
        e.receivedFrame = ai.frame;
        if (parts.length() >= 15) e.advancedConstructors = int(parseInt(parts[14]));
        if (parts.length() >= 16) e.commanderId = int(parseInt(parts[15]));
        return e;
    }

    // Allied team ids other than our own.
    array<int> AllyTeamIds()
    {
        array<int> result;
        array<Id>@ teams = ai.GetTeamIds();
        if (teams is null) return result;
        for (uint i = 0; i < teams.length(); ++i) {
            if (int(teams[i]) != ai.teamId) result.insertLast(int(teams[i]));
        }
        return result;
    }

    bool IsComplete()
    {
        array<int> allies = AllyTeamIds();
        for (uint i = 0; i < allies.length(); ++i) {
            if (!entries.exists("" + allies[i])) return false;
        }
        return true;
    }

    // Main::AiUpdate (every 30 frames): announce until the roster is complete.
    void Update()
    {
        if (!IsReady()) return;
        ObserveMex();
        // A bounded definition count query, only broadcast on a state change.
        // Recipients can decline duplicate SUPPORT gifts after TECH supplied them.
        const int advanced = AdvancedConstructors();
        const int commander = CommanderId();
        if (advanced != lastAdvancedConstructors || commander != lastCommanderId) {
            lastAdvancedConstructors = advanced;
            lastCommanderId = commander;
            Reannounce();
        }
        if (AllyTeamIds().length() == 0) return;              // no allied BARb to talk to
        if (lastBroadcastFrame >= 0 && IsComplete()) return;  // everyone answered
        if (firstBroadcastFrame >= 0 && (ai.frame - firstBroadcastFrame) >= GiveUpFrames) return;
        if (lastBroadcastFrame >= 0 && (ai.frame - lastBroadcastFrame) < RebroadcastFrames) return;

        AiSendMessage(Encode());
        if (firstBroadcastFrame < 0) {
            firstBroadcastFrame = ai.frame;
            GenericHelpers::LogUtil("[Team][Roster] Announced: " + Encode(), 1);
            WidgetLink::Send("roster", "self|" + Encode());
        }
        lastBroadcastFrame = ai.frame;
    }

    // After a runtime role change: broadcast the new line now and keep announcing
    // until everyone has it again.
    void Reannounce()
    {
        if (!IsReady()) return;
        AiSendMessage(Encode());
        WidgetLink::Send("roster", "self|" + Encode());
        firstBroadcastFrame = ai.frame;
        lastBroadcastFrame = ai.frame;
        GenericHelpers::LogUtil("[Team][Roster] Re-announced: " + Encode(), 1);
    }

    // Main::AiMessage. Returns true when the message was a roster line.
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        Entry@ e = Decode(msg);
        if (e is null) return false;
        if (e.teamId != fromTeamId || AllyTeamIds().find(fromTeamId) < 0) return true;
        Entry@ prior = Get(fromTeamId);
        if (e.firstMex.x < 0.0f && prior !is null) e.firstMex = prior.firstMex;
        if (e.firstMex.x >= 0.0f && (prior is null || prior.firstMex.x < 0.0f))
            GenericHelpers::LogUtil("[Team][Roster] team " + fromTeamId + " first mex at " + int(e.firstMex.x) + "," + int(e.firstMex.z), 1);
        const string key = "" + e.teamId;
        const bool isNew = !entries.exists(key);
        entries.set(key, @e);
        if (e.teamId != ai.teamId && Global::RoleSettings::MexOwnershipEnabled)
            aiEconomyMgr.SetMexAllyStart(e.teamId, e.startPos, e.commanderId);
        if (isNew && e.teamId != ai.teamId) {
            // D-072: a metal spot belongs to the team whose start is nearest; the
            // ally-aware mex enqueue needs the allies' starts
            aiEconomyMgr.AddAllyStart(e.startPos);
        }
        if (isNew) {
            GenericHelpers::LogUtil("[Team][Roster] Team " + e.teamId + " (AI " + e.skirmishAIId + "): role=" + RoleName(e.role)
                + " side=" + e.side + " start=(" + int(e.startPos.x) + "," + int(e.startPos.z) + ") factory=" + e.startFactory
                + " landLocked=" + (e.landLocked ? "yes" : "no") + " spot=" + e.spotIndex + (e.isLeader ? " leader" : "")
                + " known=" + entries.getSize() + "/" + AllyTeamIds().length(), 1);
            // Answer a newcomer directly so it learns about us without waiting for
            // the next broadcast. An instance that already knew us does not answer
            // again, which terminates the exchange.
            if (IsReady()) AiSendMessage(Encode(), fromTeamId);
            WidgetLink::Send("roster", "ally|" + msg);
        }
        return true;
    }

    /**************************************************************************
     Queries for coordinated planning.
     **************************************************************************/
    Entry@ Get(int teamId)
    {
        Entry@ e = null;
        entries.get("" + teamId, @e);
        return e;
    }

    array<Entry@>@ All()
    {
        array<Entry@> result;
        array<string>@ keys = entries.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            Entry@ e = null;
            if (entries.get(keys[i], @e) && e !is null) result.insertLast(e);
        }
        return result;
    }

    array<Entry@>@ WithRole(AiRole role)
    {
        array<Entry@> result;
        array<Entry@>@ all = All();
        for (uint i = 0; i < all.length(); ++i) {
            if (all[i].role == role) result.insertLast(all[i]);
        }
        return result;
    }

    Entry@ Leader()
    {
        array<Entry@>@ all = All();
        for (uint i = 0; i < all.length(); ++i) {
            if (all[i].isLeader) return all[i];
        }
        return null;
    }

    int Count() { return int(entries.getSize()); }
}  // namespace Roster
}  // namespace Team
