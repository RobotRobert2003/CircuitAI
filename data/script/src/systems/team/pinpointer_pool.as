// Shared pinpointer pool (owner, 2026-10-16): PoolSize pinpointers (armtarg / cortarg / legtarg,
// one pool whatever the faction) across every allied SMRTBARb. AIs cannot list allied units by
// type, so each AI broadcasts its own count ("targ|have|<built>|<building>") when it changes and
// every HaveSeconds; a "targ|claim" counts as one under way for ClaimSeconds. While the pool is
// short, the richest allied AIs by 10 s metal income (TeamEconomy, the same numbers on every AI;
// ties to the lower team id) each build one with a T2 constructor, in their own base through
// their own layout reservations; FRONT/SUPPORT/other builders also keep KeepAway from every AIR
// and TECH start position. A lost one drops the count and the pick reruns.
// Global::Team::PinpointerPoolSize: 0 = off (src), 3 in experimental_balanced.
namespace Team { namespace PinpointerPool {
    const string MSG = "targ";
    class Ally {
        int built = 0, building = 0, claimUntil = -1, frame = -1;
    }
    dictionary allies;            // team id string -> Ally@ (other teams only)
    int lastHave = -100000, lastBuilt = -1, lastBuilding = -1;
    int myClaimUntil = -1;
    int nextPick = 0;
    int lastLog = -100000;

    bool Enabled() { return Global::Team::PinpointerPoolSize > 0; }
    string DefName(const string &in side)
    {
        return side == "armada" ? "armtarg" : side == "cortex" ? "cortarg" : side == "legion" ? "legtarg" : "";
    }
    void Own(int &out built, int &out building)
    {
        built = 0; building = 0;
        CCircuitDef@ d = ai.GetCircuitDef(DefName(Global::AISettings::Side));
        if (d is null) return;
        const int unfinished = aiBuilderMgr.GetUnfinishedCount(d);
        built = AiMax(0, d.count - unfinished);
        building = unfinished + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::DEFENCE), d);
        if (myClaimUntil >= ai.frame && building == 0) building = 1;
    }
    int Pool()
    {
        int built, building;
        Own(built, building);
        int total = built + building;
        array<string>@ keys = allies.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            Ally@ a = null;
            if (!allies.get(keys[i], @a) || a is null) continue;
            if (!TeamEconomy::Alive(parseInt(keys[i]))) continue;
            total += a.built + (a.claimUntil >= ai.frame ? AiMax(1, a.building) : a.building);
        }
        return total;
    }
    void Broadcast()
    {
        int built, building;
        Own(built, building);
        if (built == lastBuilt && building == lastBuilding
            && ai.frame - lastHave < int(Global::Team::PinpointerHaveSeconds) * SECOND) return;
        lastBuilt = built; lastBuilding = building; lastHave = ai.frame;
        AiSendMessage(MSG + "|have|" + built + "|" + building);
    }
    float Income(int team)
    {
        if (team == ai.teamId) return Economy::GetMinMetalIncomeLast10s();
        return TeamEconomy::Metal(team, TeamEconomy::INCOME);
    }
    // our place among the allied AIs by metal income (0 = richest)
    int Rank()
    {
        TeamEconomy::UpdateAll();
        const float mine = Income(ai.teamId);
        int rank = 0;
        array<Team::Roster::Entry@>@ all = Team::Roster::All();
        for (uint i = 0; i < all.length(); ++i) {
            const int t = all[i].teamId;
            if (t == ai.teamId || !TeamEconomy::Alive(t)) continue;
            const float theirs = Income(t);
            if (theirs > mine || (theirs == mine && t < ai.teamId)) ++rank;
        }
        return rank;
    }
    AIFloat3 Site()
    {
        AIFloat3 p = Global::Map::StartPos;
        if (Global::AISettings::Role == AiRole::AIR || Global::AISettings::Role == AiRole::TECH) return p;  // own layout check only
        const float away = Global::Team::PinpointerKeepAway;
        array<Team::Roster::Entry@>@ all = Team::Roster::All();
        for (int pass = 0; pass < 3; ++pass) {
            for (uint i = 0; i < all.length(); ++i) {
                if (all[i].teamId == ai.teamId || (all[i].role != AiRole::AIR && all[i].role != AiRole::TECH)) continue;
                const AIFloat3 o = all[i].startPos;
                const float d = sqrt(MapHelpers::SqDist(p, o));
                if (d >= away) continue;
                const float dx = (d > 1.0f) ? (p.x - o.x) / d : 1.0f;
                const float dz = (d > 1.0f) ? (p.z - o.z) / d : 0.0f;
                p.x = AiMax(64.0f, AiMin(float(AiTerrainWidth()) - 64.0f, o.x + dx * away));
                p.z = AiMax(64.0f, AiMin(float(AiTerrainHeight()) - 64.0f, o.z + dz * away));
            }
        }
        return p;
    }
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || u is null || u.circuitDef is null || !u.circuitDef.IsMobile()) return null;
        Broadcast();
        if (ai.frame < nextPick) return null;
        nextPick = ai.frame + 5 * SECOND;
        CCircuitDef@ d = ai.GetCircuitDef(DefName(Global::AISettings::Side));
        if (d is null || !u.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame)) return null;
        if (Economy::GetMinMetalIncomeLast10s() < Global::Team::PinpointerMinMetalIncome) return null;
        int built, building;
        Own(built, building);
        if (building > 0) return null;   // ours is going up: one at a time per AI
        const int pool = Pool();
        const int need = Global::Team::PinpointerPoolSize - pool;
        if (need <= 0) return null;
        const int rank = Rank();
        if (rank >= need) return null;
        const AIFloat3 site = Site();
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::NORMAL, d, site,
            SQUARE_SIZE * 40, true, 300 * SECOND));
        if (t is null) return null;
        myClaimUntil = ai.frame + int(Global::Team::PinpointerClaimSeconds) * SECOND;
        AiSendMessage(MSG + "|claim");
        Broadcast();
        GenericHelpers::LogUtil("[Pinpointer] pool " + pool + " of " + Global::Team::PinpointerPoolSize + ", income rank " + rank
            + " (+" + int(Income(ai.teamId)) + " metal): " + d.GetName() + " by " + u.circuitDef.GetName() + " " + u.id
            + " near (" + int(site.x) + ", " + int(site.z) + ")", 1);
        return t;
    }
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        array<string>@ p = msg.split("|");
        if (p.length() < 2 || p[0] != MSG) return false;
        if (fromTeamId == ai.teamId) return true;
        Ally@ a = null;
        if (!allies.get("" + fromTeamId, @a) || a is null) { @a = Ally(); allies.set("" + fromTeamId, @a); }
        a.frame = ai.frame;
        if (p[1] == "have" && p.length() >= 4) {
            a.built = AiMax(0, parseInt(p[2]));
            a.building = AiMax(0, parseInt(p[3]));
            if (a.built + a.building > 0) a.claimUntil = -1;
        } else if (p[1] == "claim") {
            a.claimUntil = ai.frame + int(Global::Team::PinpointerClaimSeconds) * SECOND;
        }
        return true;
    }
} }
