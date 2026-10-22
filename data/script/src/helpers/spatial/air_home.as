#include "wall_helpers.as"
#include "../math/placement_math.as"
#include "../../systems/world/lanes.as"

namespace AirHome {
    array<AIFloat3> enemies;
    int refreshed = -100000;
    void Refresh()
    {
        if (ai.frame - refreshed < SECOND) return;
        refreshed = ai.frame;
        WallHelpers::Refresh();
        enemies = Lanes::ScriptStarts(true);
    }
    bool Within(const AIFloat3 &in p, float radius)
    {
        return p.x >= 0.0f && p.z >= 0.0f && radius > 0.0f
            && MapHelpers::SqDist(p, Global::Map::StartPos) <= radius * radius;
    }
    AIFloat3 Neighbour()
    {
        // Reuse the shared participating allied-start cache, including humans.
        Refresh();
        AIFloat3 best(-1.0f, 0.0f, -1.0f);
        float distance = 1.0e20f;
        for (uint i = 0; i < WallHelpers::starts.length(); ++i) {
            const float sq = MapHelpers::SqDist(Global::Map::StartPos, WallHelpers::starts[i]);
            if (sq > 64.0f * 64.0f && sq < distance) { best = WallHelpers::starts[i]; distance = sq; }
        }
        return best;
    }
    bool Friendly(const AIFloat3 &in p)
    {
        Refresh();
        float ally = MapHelpers::SqDist(p, Global::Map::StartPos);
        for (uint i = 0; i < WallHelpers::starts.length(); ++i) ally = AiMin(ally, MapHelpers::SqDist(p, WallHelpers::starts[i]));
        if (enemies.length() == 0) return ally <= Global::RoleSettings::Air::HomeEconomyRadius * Global::RoleSettings::Air::HomeEconomyRadius;
        float enemy = 1.0e20f;
        for (uint i = 0; i < enemies.length(); ++i) enemy = AiMin(enemy, MapHelpers::SqDist(p, enemies[i]));
        return PlacementMath::FriendlyTerritory(ally, enemy);
    }
    bool EconomySite(const AIFloat3 &in p)
    {
        return Within(p, Global::RoleSettings::Air::HomeEconomyRadius) && Friendly(p);
    }
}
