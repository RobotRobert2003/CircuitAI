#include "../math/placement_math.as"
#include "../../global.as"
#include "../../systems/team/roster.as"

namespace WallHelpers {
    array<AIFloat3> starts;
    int startsFrame = -100000;
    bool configured = false;
    float baseRadius = 1200.0f;

    bool Active() { return Global::AISettings::Role == AiRole::AIR || Global::AISettings::Role == AiRole::TECH; }

    bool IsWall(CCircuitDef@ d)
    {
        if (d is null || d.IsMobile()) return false;
        const string n = d.GetName();
        // Exact ids: Legion's legfort is an aircraft, legforti is the wall.
        return n == "armdrag" || n == "cordrag" || n == "legdrag"
            || n == "armfort" || n == "corfort" || n == "legforti"
            || n == "armfdrag" || n == "corfdrag" || n == "legfdrag";
    }

    void AddStart(const AIFloat3 &in p)
    {
        if (p.x < 0.0f || p.z < 0.0f) return;
        for (uint i = 0; i < starts.length(); ++i)
            if (MapHelpers::SqDist(p, starts[i]) < 64.0f * 64.0f) return;
        starts.insertLast(p);
    }

    void Refresh()
    {
        if (!configured) {
            baseRadius = AiMax(0.0f, aiSetupMgr.ConfigFloat("weapons/fortification/base_exclusion_radius", Global::RoleSettings::WallBaseExclusionRadius));
            configured = true;
        }
        if (ai.frame - startsFrame < SECOND) return;
        startsFrame = ai.frame;
        starts.resize(0);
        if (Global::Map::HasStart) AddStart(Global::Map::StartPos);
        array<Team::Roster::Entry@>@ allies = Team::Roster::All();
        for (uint i = 0; i < allies.length(); ++i) AddStart(allies[i].startPos);
        for (int i = 0; i < aiSetupMgr.GetScriptStartCount(); ++i)
            if (!aiSetupMgr.IsScriptStartEnemy(i)) AddStart(aiSetupMgr.GetScriptStart(i));
    }

    bool InBase(const AIFloat3 &in p, float halfX = 0.0f, float halfZ = 0.0f)
    {
        Refresh();
        if (baseRadius <= 0.0f) return false;
        for (uint i = 0; i < starts.length(); ++i)
            if (PlacementMath::FootprintIntersectsCircle(p.x, p.z, halfX, halfZ, starts[i].x, starts[i].z, baseRadius)) return true;
        return false;
    }

    bool Allowed(CCircuitDef@ d, const AIFloat3 &in p)
    {
        if (!Active() || !IsWall(d)) return true;
        // A square envelope also covers rotated, non-square wall variants.
        const float halfSize = float(AiMax(d.GetFootprintX(), d.GetFootprintZ())) * SQUARE_SIZE * 0.5f;
        return p.x >= 0.0f && p.z >= 0.0f && !InBase(p, halfSize, halfSize)
            && (Global::AISettings::Role != AiRole::TECH
                || TechWeapons::NearFront(p,Global::RoleSettings::Tech::WeaponWallFrontRadius));
    }

}
