#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/math/team_share_math.as"

/******************************************************************************

TEAM ECONOMY (D-106)

The latest economic state of every allied team, human players included. The
engine lets an AI read an allied team's resources (Game::GetTeamResource*);
native keeps one snapshot per teammate from the ally team's list (the start
script's [teamN] entries of our allyteam, our own team excluded) and refreshes
it only when asked, so a decision that needs it asks first:

    TeamEconomy::UpdateAll();              // every teammate
    TeamEconomy::UpdateTeam(teamId);       // one teammate
    TeamEconomy::Metal(teamId, TeamEconomy::FREE)   // then read

Fields, per resource: CURRENT (bank), STORAGE, INCOME, USAGE, PULL, SHARE (the
share slider), SENT, RECEIVED, EXCESS (what overflowed), FREE (storage - bank).
A team counts as alive while its metal income is above 0 (every live team has
at least its commander's income; the engine has no dead-team query for an AI).
Sending resources goes through the engine's own share command.

******************************************************************************/
namespace TeamEconomy {

    const int METAL = 0;
    const int ENERGY = 1;

    const int CURRENT = 0;
    const int STORAGE = 1;
    const int INCOME = 2;
    const int USAGE = 3;
    const int SENT = 6;
    const int RECEIVED = 7;
    const int EXCESS = 8;
    const int FREE = 9;

    // refresh one teammate's snapshot; false when it is not a teammate
    bool UpdateTeam(int teamId) { return aiEconomyMgr.UpdateTeamEconomy(teamId); }
    // refresh every teammate's snapshot; the number refreshed
    int UpdateAll() { return aiEconomyMgr.UpdateAllTeamEconomy(); }

    int Count() { return aiEconomyMgr.GetAllyTeamCount(); }
    int TeamAt(int index) { return aiEconomyMgr.GetAllyTeamIdAt(index); }
    bool Alive(int teamId) { return aiEconomyMgr.IsTeamAlive(teamId); }
    int Frame(int teamId) { return aiEconomyMgr.GetTeamEcoFrame(teamId); }   // -1: never refreshed

    float Metal(int teamId, int field) { return aiEconomyMgr.GetTeamEco(teamId, METAL, field); }
    float Energy(int teamId, int field) { return aiEconomyMgr.GetTeamEco(teamId, ENERGY, field); }
    float OwnMetal(int field) { return aiEconomyMgr.GetOwnEco(METAL, field); }
    float OwnEnergy(int field) { return aiEconomyMgr.GetOwnEco(ENERGY, field); }

    // the metal bank as a share of storage, 1 when storage is unknown
    float MetalFill(int teamId)
    {
        const float s = Metal(teamId, STORAGE);
        return (s > 0.0f) ? Metal(teamId, CURRENT) / s : 1.0f;
    }

    bool SendMetal(int teamId, float amount) { return aiEconomyMgr.SendResourceTo(METAL, amount, teamId); }
    bool SendEnergy(int teamId, float amount) { return amount>0.f && aiEconomyMgr.SendResourceTo(ENERGY,amount,teamId); }

    // one line per teammate, for the log
    string Describe(int teamId)
    {
        return "team " + teamId + (Alive(teamId) ? "" : " (not alive)") + ": metal " + int(Metal(teamId, CURRENT)) + "/" + int(Metal(teamId, STORAGE))
            + " +" + int(Metal(teamId, INCOME)) + " (free " + int(Metal(teamId, FREE)) + "), energy " + int(Energy(teamId, CURRENT)) + "/"
            + int(Energy(teamId, STORAGE)) + " +" + int(Energy(teamId, INCOME));
    }
    // D-106 (owner's rule): a fallback so no metal is lost to overflow when our
    // build power cannot keep up: whenever the metal bank is over
    // TeamShareMetalAbove of storage, refresh every teammate's economy and give
    // up to TeamShareMetalBudget of our storage, the lowest-filled live teammate
    // first, each filled up to its free storage
    int teamShareFrame = -100000;
    int teamShareLog = -100000;
    bool firstFactoryStood = false;
    int verifyFrame = -1;          // one check after a donation: did it arrive
    array<int> verifyTeams;
    // TECH retains its original T1-bot/T2-recovery gate. Other roles accept
    // any completed factory; native GetFactoryCount excludes construction frames.
    // The latch survives reclaim/loss and role switches within this instance.
    bool OpeningReady()
    {
        if (firstFactoryStood) return true;
        if (Global::AISettings::Role == AiRole::TECH) {
            CCircuitDef@ l1 = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(Global::AISettings::Side));
            firstFactoryStood = (l1 !is null && l1.count > aiBuilderMgr.GetUnfinishedCount(l1)) || TechBuild::WasIntoT2();
        } else {
            firstFactoryStood = aiFactoryMgr.GetFactoryCount() > 0;
        }
        return firstFactoryStood;
    }

    void VerifyShare()
    {
        if (verifyFrame < 0 || ai.frame < verifyFrame) return;
        verifyFrame = -1;
        string line = "";
        for (uint i = 0; i < verifyTeams.length(); ++i) {
            TeamEconomy::UpdateTeam(verifyTeams[i]);
            line += (line.length() > 0 ? ", " : "") + "team " + verifyTeams[i] + " received " + int(TeamEconomy::Metal(verifyTeams[i], TeamEconomy::RECEIVED))
                + " (bank " + int(TeamEconomy::Metal(verifyTeams[i], TeamEconomy::CURRENT)) + ")";
        }
        GenericHelpers::LogUtil("[" + Team::Roster::RoleName(Global::AISettings::Role) + "][Share] after the donation: we sent " + int(TeamEconomy::OwnMetal(TeamEconomy::SENT)) + "; " + line + " (D-106)", 1);
    }
    void ShareOverflow()
    {
        VerifyShare();
        const float stor = aiEconomyMgr.metal.storage;
        const float cur = aiEconomyMgr.metal.current;
        float budget = TeamShareMath::Budget(cur, stor,
            Global::RoleSettings::Tech::TeamShareMetalAbove,
            Global::RoleSettings::Tech::TeamShareMetalBudget, OpeningReady());
        if (budget < Global::RoleSettings::Tech::TeamShareMinAmount || budget <= 0.0f) return;
        if (ai.frame - teamShareFrame < int(Global::RoleSettings::Tech::TeamShareCheckSeconds * SECOND)) return;
        teamShareFrame = ai.frame;
        const int n = TeamEconomy::UpdateAll();
        array<int> ids;
        array<float> fills;
        for (int i = 0; i < n; ++i) {
            const int tid = TeamEconomy::TeamAt(i);
            if (tid < 0 || !TeamEconomy::Alive(tid) || TeamEconomy::Metal(tid, TeamEconomy::FREE) < Global::RoleSettings::Tech::TeamShareMinAmount) continue;
            // insertion by fill, lowest first
            const float f = TeamEconomy::MetalFill(tid);
            uint at = 0;
            while (at < fills.length() && fills[at] <= f) ++at;
            ids.insertAt(at, tid);
            fills.insertAt(at, f);
        }
        string sent = "";
        for (uint i = 0; i < ids.length() && budget >= Global::RoleSettings::Tech::TeamShareMinAmount; ++i) {
            const float give = TeamShareMath::Amount(TeamEconomy::Metal(ids[i], TeamEconomy::FREE), budget,
                Global::RoleSettings::Tech::TeamShareMinAmount);
            if (give <= 0.0f) continue;
            if (!TeamEconomy::SendMetal(ids[i], give)) continue;
            budget -= give;
            if (verifyFrame < 0) { verifyTeams.resize(0); verifyFrame = ai.frame + 45; }   // after the engine's next slow update
            verifyTeams.insertLast(ids[i]);
            sent += (sent.length() > 0 ? ", " : "") + int(give) + " to team " + ids[i] + " (" + int(fills[i] * 100.0f) + "% full)";
        }
        if (sent.length() > 0 || ai.frame - teamShareLog > 60 * SECOND) {
            teamShareLog = ai.frame;
            GenericHelpers::LogUtil("[" + Team::Roster::RoleName(Global::AISettings::Role) + "][Share] metal " + int(cur) + " of " + int(stor) + " (" + int(cur * 100.0f / stor) + "%): "
                + ((sent.length() > 0) ? ("sent " + sent) : ("no teammate with room (" + n + " teammates)"))
                + "; the engine counts " + int(TeamEconomy::OwnMetal(TeamEconomy::SENT)) + " metal sent in the last update (D-106)", 1);
        }
    }

}
