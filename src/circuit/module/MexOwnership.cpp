#include "module/EconomyManager.h"
#include "resource/MexNavigation.h"
#include "resource/MetalManager.h"
#include "terrain/TerrainManager.h"
#include "setup/SetupManager.h"
#include "unit/ally/AllyUnit.h"
#include "spring/SpringCallback.h"
#include "map/ThreatMap.h"
#include "CircuitAI.h"

#include "Log.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace circuit {
using springai::AIFloat3;
namespace {
bool ValidMexPosition(const AIFloat3& p) {
    return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z)
        && p.x >= 0 && p.z >= 0 && p.x < CTerrainManager::GetTerrainWidth()
        && p.z < CTerrainManager::GetTerrainHeight();
}
}

void CEconomyManager::SetMexOwnership(bool enabled, float seconds) {
    mexNavigationEnabled = enabled;
    mexOwnershipUntil = std::isfinite(seconds) ? int(std::clamp(seconds, 0.f, 86400.f) * FRAMES_PER_SEC) : 0;
    mexOwnersDirty = true;
}

bool CEconomyManager::IsMexOwnershipActive() const {
    return mexNavigationEnabled && mex_navigation::Protected(circuit->GetLastFrame(), mexOwnershipUntil);
}

void CEconomyManager::SetMexAllyStart(int team, const AIFloat3& pos, int commander) {
    if (team == circuit->GetTeamId() || !ValidMexPosition(pos)) return;
    auto* unit = circuit->GetFriendlyUnit(commander);
    auto* def = unit ? unit->GetCircuitDef() : nullptr;
    auto it = mexStarts.find(team);
    if (it == mexStarts.end()) {
        SMexStart start;
        start.pos = pos;
        if (def) start.definition = def->GetId();
        mexStarts.emplace(team, std::move(start));
        mexOwnersDirty = true;
    } else if (def && it->second.definition < 0) {
        it->second.definition = def->GetId();
        it->second.distance.clear();
        mexOwnersDirty = true;
    }
}

// Range checks use actual terrain elevation, even for script positions with y=0.
// Search only the local build-radius square: O((range / 64)^2), no full area scan.
// A null movement area is not proof of flight (stranded ground units also have it).
bool CEconomyManager::CanReachMex(CCircuitUnit* builder, const AIFloat3& pos) {
    auto* terrain = circuit->GetTerrainManager();
    if (!builder || !ValidMexPosition(pos)) return false;
    const auto* def = builder->GetCircuitDef();
    const float range = def->GetBuildDistance();
    if (!mexNavigationEnabled) return terrain->CanReachAtSafe(builder, pos, range);
    if (circuit->GetThreatMap()->GetThreatAt(pos) > THREAT_MIN) return false;
    if (def->IsAbleToFly()) return true;
    const auto* data = terrain->GetAreaData();
    const AIFloat3 target(pos.x, data->GetElevationAt(pos.x, pos.z), pos.z);
    const auto from = builder->GetPos(circuit->GetLastFrame());
    if (mex_navigation::InBuildRange(from.x-target.x, from.y-target.y, from.z-target.z, range)) return true;
    if (!def->IsMobile() || !builder->GetArea()) return false;
    const auto* area = builder->GetArea();
    const int pitch = terrain->GetConvertStoP(), width = terrain->GetSectorXSize(), height = terrain->GetSectorZSize();
    // TerrainManager may snap a stranded unit to a distant component. That
    // component cannot prove an exit from an isolated mountain or island.
    if (!ValidMexPosition(from)) return false;
    const int origin = terrain->GetSectorIndex(from);
    if (area->sector.find(origin) == area->sector.end()) {
        bool connected = false;
        const int sx=origin%width, sz=origin/width;
        for (int z=std::max(0,sz-1); z<=std::min(height-1,sz+1); ++z)
            for (int x=std::max(0,sx-1); x<=std::min(width-1,sx+1); ++x) {
                const auto& p=data->sector[z*width+x].position;
                if (area->sector.find(z*width+x)!=area->sector.end()
                    && mex_navigation::InBuildRange(p.x-from.x,p.y-from.y,p.z-from.z,float(pitch))) connected=true;
            }
        if (!connected) return false;
    }
    for (int z = std::max(0, int((pos.z-range)/pitch)); z <= std::min(height-1, int((pos.z+range)/pitch)); ++z)
        for (int x = std::max(0, int((pos.x-range)/pitch)); x <= std::min(width-1, int((pos.x+range)/pitch)); ++x) {
            if (area->sector.find(z*width+x) == area->sector.end()) continue;
            const auto& point = data->sector[z*width+x].position;
            if (mex_navigation::InBuildRange(point.x-target.x, point.y-target.y, point.z-target.z, range)) return true;
        }
    return false;
}

float CEconomyManager::MexStartDistance(SMexStart& start, const AIFloat3& pos) {
    auto* terrain = circuit->GetTerrainManager();
    const auto* data = terrain->GetAreaData();
    auto* def = circuit->GetCircuitDefSafe(start.definition);
    if (!def) def = circuit->GetSetupManager()->GetCommChoice();
    const int mobile = def ? def->GetMobileId() : -1;
    if (mobile < 0 || std::size_t(mobile) >= data->mobileType.size()) return mex_navigation::Unreachable;
    const auto& sectors = data->mobileType[mobile].sector;
    const int width = terrain->GetSectorXSize(), height = terrain->GetSectorZSize();
    const int pitch = terrain->GetConvertStoP();
    if (start.distance.empty() || start.revision != data->heightRevision) {
        int source = terrain->GetSectorIndex(start.pos);
        const float sy = data->GetElevationAt(start.pos.x, start.pos.z);
        // The starting point may lie on a conservative sector boundary. Permit
        // only a local, height-compatible connector, never a remote island snap.
        float nearest = mex_navigation::Unreachable;
        int chosen = -1;
        const int sx = source%width, sz = source/width;
        for (int z=std::max(0,sz-1); z<=std::min(height-1,sz+1); ++z)
            for (int x=std::max(0,sx-1); x<=std::min(width-1,sx+1); ++x) {
                const int index=z*width+x;
                const auto& p=data->sector[index].position;
                if (!sectors[index].area || std::abs(p.y-sy)>pitch) continue;
                const float distance=std::hypot(p.x-start.pos.x,p.z-start.pos.z);
                if (distance<nearest) { nearest=distance; chosen=index; }
            }
        const auto* component = chosen < 0 ? nullptr : sectors[chosen].area;
        start.distance = mex_navigation::Distances(width,height,chosen,nearest,
            [&](int i) { return component && sectors[i].area==component; },
            [&](int a,int b) { const auto& p=data->sector[a].position; const auto& q=data->sector[b].position;
                return std::sqrt(p.SqDistance(q)); });
        start.revision=data->heightRevision;
    }
    // Walk to a legal construction stance, not through an unwalkable mex cell.
    const float range=def->GetBuildDistance();
    const float y=data->GetElevationAt(pos.x,pos.z);
    float best=mex_navigation::Unreachable;
    for (int z=std::max(0,int((pos.z-range)/pitch)); z<=std::min(height-1,int((pos.z+range)/pitch)); ++z)
        for (int x=std::max(0,int((pos.x-range)/pitch)); x<=std::min(width-1,int((pos.x+range)/pitch)); ++x) {
            const int i=z*width+x; const auto& p=data->sector[i].position;
            if (mex_navigation::InBuildRange(p.x-pos.x,p.y-y,p.z-pos.z,range)) best=std::min(best,start.distance[i]);
        }
    return best;
}

bool CEconomyManager::IsMexExpansionAllowed(const AIFloat3& pos, bool allyAware) {
    if (!mexNavigationEnabled) return !allyAware || (!circuit->GetTerrainManager()->IsZoneAlly(pos) && IsOwnSpot(pos));
    // While the opening window runs, start allocation is the only territorial
    // veto. Real occupied mexes and allied structure footprints are still
    // protected by their existing owners. After the window the ally-zone veto
    // and the D-072 Voronoi split (inside IsOwnSpot) hold again (D-327).
    if (IsMexOwnershipActive()) return IsOwnSpot(pos);
    return !allyAware || (!circuit->GetTerrainManager()->IsZoneAlly(pos) && IsOwnSpot(pos));
}
}

/******************************************************************************
 D-352: mex ownership by theatre. Fields per announced class, the enemy sources
 from the start boxes (or the mirror of our starts), the lane partition and one
 resolved record per spot. Everything the rules read is roster data every ally
 holds, so allies agree on every owner (resource/MexTerritory.h).
******************************************************************************/
#include "module/BuilderManager.h"
#include "task/builder/BuilderTask.h"
#include "resource/MetalManager.h"
#include "util/Utils.h"

#include <limits>
#include <sstream>
#include <string>

namespace circuit {
using mex_territory::Entrant;
using mex_territory::Rule;

void CEconomyManager::SetMexTheatres(bool enabled, float theatreSeconds, float homeRadius) {
    mexTheatresEnabled = enabled;
    if (enabled) mexNavigationEnabled = true;
    mexTheatreUntil = !std::isfinite(theatreSeconds) || theatreSeconds < 0.f ? -1
        : int(std::clamp(theatreSeconds, 0.f, 86400.f) * FRAMES_PER_SEC);
    mexHomeRadius = std::isfinite(homeRadius) ? std::clamp(homeRadius, 0.f, 8192.f) : 900.f;
    mexTerritoryDirty = true;
}

void CEconomyManager::SetMexLaneSettings(float mergeRadius, float mergeShare, float bandRadius) {
    if (std::isfinite(mergeRadius)) mexLaneSettings.mergeRadius = std::clamp(mergeRadius, 0.f, 8192.f);
    if (std::isfinite(mergeShare)) mexLaneSettings.mergeShare = std::clamp(mergeShare, 0.f, 1.f);
    if (std::isfinite(bandRadius)) mexLaneSettings.bandRadius = std::clamp(bandRadius, 0.f, 8192.f);
    mexTerritoryDirty = true;
}

bool CEconomyManager::IsMexTheatreWindow() const {
    if (mexTheatreUntil < 0) return mex_navigation::Protected(circuit->GetLastFrame(), mexOwnershipUntil);
    if (mexTheatreUntil == 0) return true;
    return mex_navigation::Protected(circuit->GetLastFrame(), mexTheatreUntil);
}

static int DefinitionId(CCircuitAI* circuit, const char* name) {
    if (name == nullptr || *name == '\0') return -1;
    auto* def = circuit->GetCircuitDef(name);
    return def ? def->GetId() : -1;
}

void CEconomyManager::SetMexAllyClaim(int team, const AIFloat3& start, const AIFloat3& anchor,
        const char* groundDef, const char* classDef, int readyFrame, float secureSeconds,
        const char* combatDef, int combatReadyFrame, bool laneSpots) {
    if (!ValidMexPosition(start)) return;
    SMexClaim claim;
    claim.start = start;
    claim.anchor = ValidMexPosition(anchor) ? anchor : start;
    claim.groundDef = DefinitionId(circuit, groundDef);
    claim.classDef = DefinitionId(circuit, classDef);
    if (claim.classDef < 0) claim.classDef = claim.groundDef;
    if (claim.groundDef < 0) claim.groundDef = claim.classDef;
    claim.combatDef = DefinitionId(circuit, combatDef);
    claim.readyFrame = std::max(0, readyFrame);
    claim.combatReadyFrame = std::max(0, combatReadyFrame);
    claim.secureSeconds = std::isfinite(secureSeconds) ? std::clamp(secureSeconds, 0.f, 3600.f) : 0.f;
    claim.laneSpots = laneSpots;
    auto it = mexClaims.find(team);
    if (it != mexClaims.end()) {
        // A moved anchor or changed class drops the fields; a timing change only
        // invalidates the cached owners.
        SMexClaim& old = it->second;
        const bool same = old.start.SqDistance2D(claim.start) < 1.f && old.anchor.SqDistance2D(claim.anchor) < 1.f
            && old.groundDef == claim.groundDef && old.classDef == claim.classDef && old.combatDef == claim.combatDef;
        if (same) { claim.ground = std::move(old.ground); claim.cls = std::move(old.cls); claim.combat = std::move(old.combat); }
        old = std::move(claim);
    } else {
        mexClaims.emplace(team, std::move(claim));
    }
    mexTerritoryDirty = true;
}

void CEconomyManager::RemoveMexAllyClaim(int team) {
    if (mexClaims.erase(team) > 0) mexTerritoryDirty = true;
    if (mexCorridors.erase(team) > 0) mexTerritoryDirty = true;
}

// D-357: a FRONT ally's coverage corridor, as the roster broadcast it. The
// polyline is copied once per publication (a seat or endpoint change, rare);
// RebuildMexTerritory resolves clusters against it. An empty polyline clears.
void CEconomyManager::SetMexCorridor(int team, const std::vector<AIFloat3>& points, float halfWidth) {
    if (points.size() < 2 || !std::isfinite(halfWidth) || halfWidth <= 0.f) {
        if (mexCorridors.erase(team) > 0) mexTerritoryDirty = true;
        return;
    }
    SMexCorridor corridor;
    corridor.points.reserve(points.size());
    for (const auto& q : points) {
        if (!ValidMexPosition(q)) return;
        corridor.points.push_back(q);
    }
    corridor.halfWidth = std::clamp(halfWidth, 64.f, 2048.f);
    for (std::size_t i = 1; i < corridor.points.size(); ++i) corridor.length += std::sqrt(corridor.points[i].SqDistance2D(corridor.points[i - 1]));
    mexCorridors[team] = std::move(corridor);
    mexTerritoryDirty = true;
}

// Nearest corridor holding the point (distance to the polyline within its
// half-width); ties to the lower team id. Progress along it decides forward.
static int CorridorOwner(const std::map<int, CEconomyManager::SMexCorridor>& corridors, const AIFloat3& pos, bool& forward) {
    int owner = -1; float best = std::numeric_limits<float>::max(); forward = false;
    for (const auto& [team, c] : corridors) {
        float distance = std::numeric_limits<float>::max(), progress = 0.f, walked = 0.f;
        for (std::size_t i = 1; i < c.points.size(); ++i) {
            const AIFloat3& a = c.points[i - 1]; const AIFloat3& b = c.points[i];
            const float dx = b.x - a.x, dz = b.z - a.z, len2 = dx * dx + dz * dz;
            const float u = len2 > 0.f ? std::clamp(((pos.x - a.x) * dx + (pos.z - a.z) * dz) / len2, 0.f, 1.f) : 0.f;
            const float px = a.x + dx * u - pos.x, pz = a.z + dz * u - pos.z;
            const float d = std::sqrt(px * px + pz * pz);
            if (d < distance) { distance = d; progress = walked + std::sqrt(len2) * u; }
            walked += std::sqrt(len2);
        }
        if (distance <= c.halfWidth && (owner < 0 || distance < best || (distance == best && team < owner))) {
            best = distance; owner = team; forward = c.length > 0.f && progress > c.length * .5f;
        }
    }
    return owner;
}

void CEconomyManager::SetMexEnemyClass(const char* classDef, float readySeconds) {
    const int id = DefinitionId(circuit, classDef);
    if (id < 0) return;
    const float ready = std::isfinite(readySeconds) ? std::max(0.f, readySeconds) : 0.f;
    for (auto& enemy : mexEnemies) {
        if (enemy.definition == id) { enemy.readySeconds = ready; mexTerritoryDirty = true; return; }
    }
    SMexEnemy enemy;
    enemy.definition = id;
    enemy.readySeconds = ready;
    mexEnemies.push_back(std::move(enemy));
    mexTerritoryDirty = true;
}

// The theatre bit a constructor class stands for: aircraft, hovercraft, a class
// that needs water under it (ships), else ground.
int CEconomyManager::MexTheatreKind(int definition) const {
    auto* def = circuit->GetCircuitDefSafe(definition);
    if (def == nullptr) return mex_territory::LAND;
    if (def->IsAbleToFly()) return mex_territory::AIR;
    auto* mobile = circuit->GetTerrainManager()->GetMobileTypeById(def->GetMobileId());
    if (mobile == nullptr) return mex_territory::LAND;
    if (mobile->canHover) return mex_territory::HOVER;
    if (mobile->maxElevation < 0.f) return mex_territory::NAVAL;
    return mex_territory::LAND;
}

// One field per (class, seeds): the class's own terrain areas, eight edges per
// cell, Euclidean sector distance. Aircraft pass everywhere. Rebuilt when the
// terrain publication changes; the caller keeps the seeds stable.
void CEconomyManager::BuildMexField(SMexField& field, int definition, const std::vector<std::pair<int, float>>& seeds) {
    auto* terrain = circuit->GetTerrainManager();
    const auto* data = terrain->GetAreaData();
    const int width = terrain->GetSectorXSize(), height = terrain->GetSectorZSize();
    field.definition = definition;
    field.revision = data->heightRevision;
    const auto cost = [&](int a, int b) {
        const auto& p = data->sector[a].position; const auto& q = data->sector[b].position;
        return std::sqrt(p.SqDistance(q)); };
    auto* def = circuit->GetCircuitDefSafe(definition);
    if (def != nullptr && def->IsAbleToFly()) {
        field.distance = mex_navigation::DistancesMulti(width, height, seeds, [](int) { return true; }, cost);
        return;
    }
    const int mobile = def ? def->GetMobileId() : -1;
    if (mobile < 0 || std::size_t(mobile) >= data->mobileType.size()) {
        field.distance.assign(std::size_t(width) * height, mex_navigation::Unreachable);
        return;
    }
    const auto& sectors = data->mobileType[mobile].sector;
    field.distance = mex_navigation::DistancesMulti(width, height, seeds,
        [&](int i) { return sectors[i].area != nullptr; }, cost);
}

// The sector a class leaves from. Ground: a local height-compatible 3x3
// connector as D-322. Ships and hovers whose anchor is not on their terrain
// (a SEA seat with a land start before its berth is planned): the class's
// sector nearest by the claimant's own ground walk within walkLimit, so the
// sailing distance includes the overland leg and no radius constant is needed.
int CEconomyManager::MexConnector(int definition, const AIFloat3& pos, const SMexField* walk, float walkLimit, float& initial) {
    auto* terrain = circuit->GetTerrainManager();
    const auto* data = terrain->GetAreaData();
    const int width = terrain->GetSectorXSize(), height = terrain->GetSectorZSize();
    const int pitch = terrain->GetConvertStoP();
    initial = 0.f;
    if (!ValidMexPosition(pos)) return -1;
    auto* def = circuit->GetCircuitDefSafe(definition);
    const int source = terrain->GetSectorIndex(pos);
    if (def != nullptr && def->IsAbleToFly()) return source;
    const int mobile = def ? def->GetMobileId() : -1;
    if (mobile < 0 || std::size_t(mobile) >= data->mobileType.size()) return -1;
    const auto& sectors = data->mobileType[mobile].sector;
    const float sy = data->GetElevationAt(pos.x, pos.z);
    float nearest = mex_navigation::Unreachable;
    int chosen = -1;
    const int sx = source % width, sz = source / width;
    for (int z = std::max(0, sz - 1); z <= std::min(height - 1, sz + 1); ++z)
        for (int x = std::max(0, sx - 1); x <= std::min(width - 1, sx + 1); ++x) {
            const int index = z * width + x;
            const auto& p = data->sector[index].position;
            if (!sectors[index].area || std::abs(p.y - sy) > pitch) continue;
            const float distance = std::hypot(p.x - pos.x, p.z - pos.z);
            if (distance < nearest || (distance == nearest && index < chosen)) { nearest = distance; chosen = index; }
        }
    if (chosen >= 0) { initial = nearest; return chosen; }
    if (walk == nullptr || walk->distance.size() != sectors.size()) return -1;
    // The ship's sectors (deep enough) and the bot's (shallow enough) do not
    // overlap at a shore, so a class sector connects through any of its eight
    // neighbours the ground walk reaches, one sector step added.
    const float step = float(pitch) * 1.4142f;
    for (std::size_t i = 0; i < sectors.size(); ++i) {
        if (!sectors[i].area) continue;
        const int ix = int(i) % width, iz = int(i) / width;
        float d = walk->distance[i];
        for (int dz = -1; dz <= 1; ++dz) for (int dx = -1; dx <= 1; ++dx) {
            const int nx = ix + dx, nz = iz + dz;
            if ((!dx && !dz) || nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
            const float via = walk->distance[nz * width + nx];
            if (std::isfinite(via)) d = std::min(d, via + ((dx && dz) ? step : float(pitch)));
        }
        if (!std::isfinite(d) || d > walkLimit) continue;
        if (d < nearest || (d == nearest && int(i) < chosen)) { nearest = d; chosen = int(i); }
    }
    if (chosen >= 0) initial = nearest;
    return chosen;
}

// Field distance to the nearest legal construction stance of the class
// around the spot (its build range, 3D), as MexStartDistance.
float CEconomyManager::MexStance(const SMexField& field, int definition, const AIFloat3& pos, float range) {
    auto* terrain = circuit->GetTerrainManager();
    const auto* data = terrain->GetAreaData();
    const int width = terrain->GetSectorXSize(), height = terrain->GetSectorZSize();
    const int pitch = terrain->GetConvertStoP();
    if (field.distance.size() != std::size_t(width) * height) return mex_navigation::Unreachable;
    auto* def = circuit->GetCircuitDefSafe(definition);
    if (def != nullptr && def->IsAbleToFly()) {
        const int index = terrain->GetSectorIndex(pos);
        return index >= 0 && index < width * height ? field.distance[index] : mex_navigation::Unreachable;
    }
    const float y = data->GetElevationAt(pos.x, pos.z);
    float best = mex_navigation::Unreachable;
    for (int z = std::max(0, int((pos.z - range) / pitch)); z <= std::min(height - 1, int((pos.z + range) / pitch)); ++z)
        for (int x = std::max(0, int((pos.x - range) / pitch)); x <= std::min(width - 1, int((pos.x + range) / pitch)); ++x) {
            const int i = z * width + x; const auto& p = data->sector[i].position;
            if (mex_navigation::InBuildRange(p.x - pos.x, p.y - y, p.z - pos.z, range)) best = std::min(best, field.distance[i]);
        }
    return best;
}

// Enemy sources, in order of what the setup reveals, each identical on every
// ally (observed enemy positions are deliberately not used):
//   1. the enemy teams' start positions when the start script carries them;
//   2. the metal spots inside the enemy start boxes (players start on metal;
//      every cell of a half-map box would put the enemy next to everything);
//   3. the point mirror of every claimant start through the map centre.
// Each source seeds its 3x3 sectors so a point on a wall still seeds.
void CEconomyManager::EnsureMexEnemySeeds() {
    auto* terrain = circuit->GetTerrainManager();
    const auto* data = terrain->GetAreaData();
    if (!mexEnemySeeds.empty() && mexEnemySeedRevision == data->heightRevision && mexEnemySeedClaims == mexClaims.size()) return;
    mexEnemySeeds.clear();
    mexEnemySeedRevision = data->heightRevision;
    mexEnemySeedClaims = mexClaims.size();
    const int width = terrain->GetSectorXSize(), height = terrain->GetSectorZSize();
    auto* setup = circuit->GetSetupManager();
    const auto seedAround = [&](const AIFloat3& p) {
        if (!ValidMexPosition(p)) return;
        const int c = terrain->GetSectorIndex(p);
        const int cx = c % width, cz = c / width;
        for (int z = std::max(0, cz - 1); z <= std::min(height - 1, cz + 1); ++z)
            for (int x = std::max(0, cx - 1); x <= std::min(width - 1, cx + 1); ++x)
                mexEnemySeeds.emplace_back(z * width + x, 0.f);
    };
    for (int i = 0; i < setup->GetScriptStartCount(); ++i) {
        if (setup->IsScriptStartEnemy(i)) seedAround(setup->GetScriptStart(i));
    }
    if (mexEnemySeeds.empty() && setup->HasStartBoxes()) {
        for (const auto& spot : circuit->GetMetalManager()->GetSpots()) {
            if (setup->EnemyStartBoxAt(spot.position) == 1) seedAround(spot.position);
        }
    }
    if (mexEnemySeeds.empty()) {
        const float w = float(CTerrainManager::GetTerrainWidth()), h = float(CTerrainManager::GetTerrainHeight());
        for (const auto& [team, claim] : mexClaims) {
            seedAround(AIFloat3(std::clamp(w - claim.start.x, 0.f, w - 1.f), 0.f, std::clamp(h - claim.start.z, 0.f, h - 1.f)));
        }
    }
    std::sort(mexEnemySeeds.begin(), mexEnemySeeds.end());
    mexEnemySeeds.erase(std::unique(mexEnemySeeds.begin(), mexEnemySeeds.end()), mexEnemySeeds.end());
    for (auto& enemy : mexEnemies) enemy.field.revision = 0;  // reseed
}

int CEconomyManager::MexSpotIndex(const AIFloat3& pos) const {
    if (metalMap || !ValidMexPosition(pos)) return -1;
    auto* metalMgr = circuit->GetMetalManager();
    const auto& spots = metalMgr->GetSpots();
    const int index = metalMgr->FindNearestSpot(pos);
    return index >= 0 && std::size_t(index) < spots.size() && spots[index].position.SqDistance2D(pos) < SQUARE(64.f) ? index : -1;
}

// Everything at once: fields, enemy sources, the lane partition and one
// resolved record per spot. Rebuilt on a claim or enemy change, a terrain
// publication, a cluster publication, or a window boundary. O(fields x G log G
// + spots x claimants x stance cells), a few times per game.
void CEconomyManager::RebuildMexTerritory() {
    auto* terrain = circuit->GetTerrainManager();
    auto* metalMgr = circuit->GetMetalManager();
    const auto* data = terrain->GetAreaData();
    const auto& spots = metalMgr->GetSpots();
    const auto& clusters = metalMgr->GetClusters();
    const bool landWindow = IsMexOwnershipActive();
    const bool theatreWindow = IsMexTheatreWindow();
    if (!mexTerritoryDirty && mexResolvedRevision == data->heightRevision && mexResolved.size() == spots.size()
        && mexResolvedClusters == clusters.size() && mexResolvedLandWindow == landWindow && mexResolvedTheatreWindow == theatreWindow) return;
    mexTerritoryDirty = false;
    mexResolvedRevision = data->heightRevision;
    mexResolvedClusters = clusters.size();
    mexResolvedLandWindow = landWindow;
    mexResolvedTheatreWindow = theatreWindow;
    const int width = terrain->GetSectorXSize(), height = terrain->GetSectorZSize();
    const float pitch = float(terrain->GetConvertStoP());
    // Own claim: the roster announces it like any ally's; until then the commander walks.
    const int ownTeam = circuit->GetTeamId();
    if (mexClaims.find(ownTeam) == mexClaims.end()) {
        SMexClaim own;
        own.start = own.anchor = circuit->GetSetupManager()->GetStartPos();
        const auto* def = circuit->GetSetupManager()->GetCommChoice();
        if (def) own.groundDef = own.classDef = def->GetId();
        mexClaims.emplace(ownTeam, std::move(own));
    }
    // Fields per claimant: ground from the start, the own class from the
    // anchor (connected over the ground walk when the anchor is on land), the
    // combat class from the anchor; a class equal to the ground class reuses it.
    for (auto& [team, claim] : mexClaims) {
        const auto build = [&](SMexField& f, int def, const AIFloat3& at, const SMexField* walk, float limit) {
            if (def < 0) { f.distance.clear(); return; }
            if (f.definition == def && f.revision == data->heightRevision && !f.distance.empty()) return;
            float initial = 0.f;
            const int seed = MexConnector(def, at, walk, limit, initial);
            f.seed = seed; f.initial = initial;
            BuildMexField(f, def, {{seed, initial}});
        };
        build(claim.ground, claim.groundDef, claim.start, nullptr, 0.f);
        auto* groundDef = circuit->GetCircuitDefSafe(claim.groundDef);
        const float walkLimit = groundDef ? float(mexOwnershipUntil) / FRAMES_PER_SEC * groundDef->GetSpeed() : 0.f;
        if (claim.classDef == claim.groundDef) claim.cls.distance.clear();
        else build(claim.cls, claim.classDef, claim.anchor, &claim.ground, walkLimit);
        if (claim.combatDef < 0 || claim.combatDef == claim.classDef || claim.combatDef == claim.groundDef) claim.combat.distance.clear();
        else build(claim.combat, claim.combatDef, claim.anchor, &claim.ground, walkLimit);
    }
    EnsureMexEnemySeeds();
    for (auto& enemy : mexEnemies) {
        if (enemy.field.revision != data->heightRevision || enemy.field.distance.empty()) BuildMexField(enemy.field, enemy.definition, mexEnemySeeds);
    }
    // The lane partition over the ground class of our own claim (every ally
    // announces the same T1 constructor class, so the grid is the same).
    mexLanes = mex_lanes::Partition();
    mexLaneTeams.clear();
    mexSpotCluster.assign(spots.size(), -1);
    for (std::size_t c = 0; c < clusters.size(); ++c) for (int i : clusters[c].idxSpots) if (i >= 0 && std::size_t(i) < spots.size()) mexSpotCluster[i] = int(c);
    {
        const auto& own = mexClaims.at(ownTeam);
        auto* def = circuit->GetCircuitDefSafe(own.groundDef);
        const int mobile = def && !def->IsAbleToFly() ? def->GetMobileId() : -1;
        const SMexEnemy* enemyGround = nullptr;
        for (const auto& enemy : mexEnemies) {
            auto* edef = circuit->GetCircuitDefSafe(enemy.definition);
            if (edef && !edef->IsAbleToFly() && edef->GetMobileId() == mobile) { enemyGround = &enemy; break; }
        }
        if (mobile >= 0 && std::size_t(mobile) < data->mobileType.size() && enemyGround != nullptr && !clusters.empty()) {
            const auto& sectors = data->mobileType[mobile].sector;
            const auto passable = [&](int i) { return sectors[i].area != nullptr; };
            const auto cost = [&](int a, int b) {
                const auto& p = data->sector[a].position; const auto& q = data->sector[b].position;
                return std::sqrt(p.SqDistance(q)); };
            std::vector<int> starts;
            std::vector<std::pair<int, float>> ourSeeds;
            for (auto& [team, claim] : mexClaims) {
                mexLaneTeams.push_back(team);
                starts.push_back(claim.ground.seed);
                ourSeeds.emplace_back(claim.ground.seed, claim.ground.initial);
            }
            const auto ours = mex_navigation::DistancesMulti(width, height, ourSeeds, passable, cost);
            std::vector<std::pair<float, float>> centres;
            std::vector<int> cells;
            for (const auto& cluster : clusters) {
                centres.emplace_back(cluster.weightCentr.x, cluster.weightCentr.z);
                int cell = -1; float best = std::numeric_limits<float>::max();
                for (int i : cluster.idxSpots) {
                    if (i < 0 || std::size_t(i) >= spots.size()) continue;
                    const float d = spots[i].position.SqDistance2D(cluster.weightCentr);
                    if (d < best) { best = d; cell = terrain->GetSectorIndex(spots[i].position); }
                }
                cells.push_back(cell);
            }
            mexLanes = mex_lanes::Build(width, height, pitch, starts, enemyGround->field.distance, ours, passable, centres, cells, mexLaneSettings);
            for (std::size_t s = 0; s < mexLaneTeams.size(); ++s) mexClaims[mexLaneTeams[s]].lane = mexLanes.startLane[s];
        } else {
            for (auto& [team, claim] : mexClaims) claim.lane = -1;
        }
    }
    // Resolve every spot. Sea-rule spots are dealt out among the SEA seats
    // that reach them after the pass (mex_territory::BalanceSea).
    mexResolved.assign(spots.size(), SMexResolved());
    std::vector<int> seaSpots;
    std::vector<std::vector<std::pair<int, float>>> seaCandidates;
    mex_territory::Inputs in;
    in.homeRadius = mexHomeRadius;
    in.window = landWindow;
    in.theatreWindow = theatreWindow;
    in.framesPerSecond = float(FRAMES_PER_SEC);
    in.entrants.reserve(mexClaims.size());
    for (std::size_t i = 0; i < spots.size(); ++i) {
        const AIFloat3& pos = spots[i].position;
        in.entrants.clear();
        for (auto& [team, claim] : mexClaims) {
            Entrant e;
            e.team = team;
            e.kind = MexTheatreKind(claim.classDef);
            auto* gdef = circuit->GetCircuitDefSafe(claim.groundDef);
            auto* cdef = circuit->GetCircuitDefSafe(claim.classDef);
            auto* fdef = circuit->GetCircuitDefSafe(claim.combatDef);
            if (gdef && !claim.ground.distance.empty() && MexTheatreKind(claim.groundDef) == mex_territory::LAND)
                e.groundDistance = MexStance(claim.ground, claim.groundDef, pos, gdef->GetBuildDistance());
            e.startDistance2D = std::sqrt(claim.start.SqDistance2D(pos));
            if (cdef) {
                e.classSpeed = cdef->GetSpeed();
                if (e.kind == mex_territory::LAND) e.classDistance = e.groundDistance;
                else if (claim.classDef == claim.groundDef) e.classDistance = MexStance(claim.ground, claim.classDef, pos, cdef->GetBuildDistance());
                else if (!claim.cls.distance.empty()) e.classDistance = MexStance(claim.cls, claim.classDef, pos, cdef->GetBuildDistance());
                if (e.kind == mex_territory::AIR) e.classDistance = std::sqrt(claim.anchor.SqDistance2D(pos));
            }
            e.readyFrame = claim.readyFrame;
            e.secureSeconds = claim.secureSeconds;
            if (fdef) {
                e.combatSpeed = fdef->GetSpeed();
                e.combatReadyFrame = claim.combatReadyFrame;
                const SMexField& f = !claim.combat.distance.empty() ? claim.combat : (claim.combatDef == claim.classDef && !claim.cls.distance.empty() ? claim.cls : claim.ground);
                e.combatDistance = MexStance(f, claim.combatDef, pos, std::max(pitch, fdef->GetBuildDistance()));
            }
            e.laneSpots = claim.laneSpots;
            e.lane = claim.lane;
            in.entrants.push_back(e);
        }
        in.enemySeconds = mex_navigation::Unreachable;
        in.enemyCombatSeconds = mex_navigation::Unreachable;
        for (const auto& enemy : mexEnemies) {
            auto* edef = circuit->GetCircuitDefSafe(enemy.definition);
            if (!edef || !(edef->GetSpeed() > 0.f) || enemy.field.distance.empty()) continue;
            const float d = MexStance(enemy.field, enemy.definition, pos, std::max(pitch, edef->GetBuildDistance()));
            if (!std::isfinite(d)) continue;
            const float at = enemy.readySeconds + d / edef->GetSpeed();
            in.enemySeconds = std::min(in.enemySeconds, at);
            // A class without build power is a combat class: it can hold the ground.
            if (!(edef->GetWorkerTime() > 0.f)) in.enemyCombatSeconds = std::min(in.enemyCombatSeconds, at);
        }
        const int cluster = mexSpotCluster[i];
        in.lane = cluster >= 0 && std::size_t(cluster) < mexLanes.clusterLane.size() ? mexLanes.clusterLane[cluster] : -1;
        in.forward = in.lane >= 0 && mexLanes.clusterForward[cluster] != 0;
        in.corridor = mexCorridors.empty() ? -1 : CorridorOwner(mexCorridors, pos, in.corridorForward);
        const auto r = mex_territory::Resolve(in);
        SMexResolved& out = mexResolved[i];
        out.mask = r.mask; out.rule = int(r.rule); out.owner = r.owner; out.lane = in.lane;
        out.arrive = r.arriveSeconds; out.secure = r.secureSeconds; out.enemy = r.enemySeconds;
        if (r.rule == Rule::SEA) {
            seaSpots.push_back(int(i));
            seaCandidates.emplace_back();
            for (const auto& e : in.entrants) if (e.kind == mex_territory::NAVAL && std::isfinite(e.classDistance)) seaCandidates.back().emplace_back(e.team, e.classDistance);
        }
    }
    const auto dealt = mex_territory::BalanceSea(seaCandidates);
    for (std::size_t k = 0; k < seaSpots.size(); ++k) if (dealt[k] >= 0) mexResolved[seaSpots[k]].owner = dealt[k];
}

const CEconomyManager::SMexResolved* CEconomyManager::MexResolvedAt(const AIFloat3& pos) {
    if (!mexTheatresEnabled) return nullptr;
    const int index = MexSpotIndex(pos);
    if (index < 0) return nullptr;
    RebuildMexTerritory();
    return std::size_t(index) < mexResolved.size() ? &mexResolved[index] : nullptr;
}

int CEconomyManager::MexTheatre(const AIFloat3& pos) { const auto* r = MexResolvedAt(pos); return r ? r->mask : mex_territory::AIR; }
int CEconomyManager::MexSpotOwner(const AIFloat3& pos) { const auto* r = MexResolvedAt(pos); return r ? r->owner : -1; }
int CEconomyManager::MexSpotRule(const AIFloat3& pos) { const auto* r = MexResolvedAt(pos); return r ? r->rule : 0; }
float CEconomyManager::MexSpotEnemySeconds(const AIFloat3& pos) { const auto* r = MexResolvedAt(pos); return r ? r->enemy : mex_navigation::Unreachable; }

int CEconomyManager::MexSpotAdmission(CCircuitUnit* builder, const AIFloat3& pos) {
    int flags = 0;
    if (builder == nullptr || builder->GetCircuitDef() == nullptr || !ValidMexPosition(pos)) return flags;
    const int index = MexSpotIndex(pos);
    if (index < 0) return flags;
    flags |= 1;
    if (circuit->GetMetalManager()->IsOpenSpot(index)) flags |= 2;
    if (IsOpenMexSpot(index)) flags |= 4;
    if (CanReachMex(builder, pos)) flags |= 8;
    if (IsMexExpansionAllowed(pos, true)) flags |= 16;
    auto* terrainMgr = circuit->GetTerrainManager();
    const int frame = circuit->GetLastFrame();
    for (CCircuitDef* mexDef : metalDefs.GetBuildDefs(builder->GetCircuitDef())) {
        if (mexDef != nullptr && mexDef->IsAvailable(frame) && terrainMgr->CanBeBuiltAt(mexDef, pos)) { flags |= 32; break; }
    }
    for (IBuilderTask* task : circuit->GetBuilderManager()->GetTasks(IBuilderTask::BuildType::MEX)) {
        if (task == nullptr || task->IsDead() || task->GetPosition().SqDistance2D(pos) > SQUARE(64.f)) continue;
        flags |= 64;
        if (!task->GetAssignees().empty()) flags |= 128;
        if (task->GetTarget() != nullptr) flags |= 256;
        for (CCircuitUnit* u : task->GetAssignees()) {
            if (u != nullptr && u->GetCircuitDef() != nullptr && u->GetCircuitDef()->IsAbleToFly()) flags |= 512;
        }
        break;
    }
    return flags;
}

// Income per second of waiting for this team's own class (proposal 3.2.2).
float CEconomyManager::MexSpotValue(const AIFloat3& pos, int team) {
    const int index = MexSpotIndex(pos);
    if (index < 0 || !mexTheatresEnabled) return 0.f;
    RebuildMexTerritory();
    auto it = mexClaims.find(team);
    if (it == mexClaims.end()) return 0.f;
    const SMexClaim& claim = it->second;
    auto* cdef = circuit->GetCircuitDefSafe(claim.classDef);
    if (cdef == nullptr) return 0.f;
    const float pitch = float(circuit->GetTerrainManager()->GetConvertStoP());
    float distance;
    if (cdef->IsAbleToFly()) distance = std::sqrt(claim.anchor.SqDistance2D(pos));
    else if (claim.classDef == claim.groundDef || claim.cls.distance.empty()) distance = MexStance(claim.ground, claim.classDef, pos, std::max(pitch, cdef->GetBuildDistance()));
    else distance = MexStance(claim.cls, claim.classDef, pos, std::max(pitch, cdef->GetBuildDistance()));
    const CCircuitDef* mexDef = GetSideInfo().mexDef;
    const float power = cdef->GetWorkerTime();
    const float build = (mexDef != nullptr && power > 0.f) ? mexDef->GetBuildTime() / power : 0.f;
    const float income = circuit->GetMetalManager()->GetSpots()[index].income;
    return mex_territory::Value(income, float(claim.readyFrame), distance, cdef->GetSpeed(), build, float(FRAMES_PER_SEC));
}

int CEconomyManager::MexLaneCount() { if (!mexTheatresEnabled) return 0; RebuildMexTerritory(); return int(mexLanes.lanes.size()); }
int CEconomyManager::MexLane(const AIFloat3& pos) { const auto* r = MexResolvedAt(pos); return r ? r->lane : -1; }
float CEconomyManager::MexLaneWidth(int lane) {
    if (!mexTheatresEnabled) return 0.f;
    RebuildMexTerritory();
    return lane >= 0 && std::size_t(lane) < mexLanes.lanes.size() ? mexLanes.lanes[lane].width : 0.f;
}
bool CEconomyManager::MexLaneMember(int lane, int team) {
    if (!mexTheatresEnabled) return false;
    RebuildMexTerritory();
    auto it = mexClaims.find(team);
    return it != mexClaims.end() && it->second.lane == lane && lane >= 0;
}
static AIFloat3 SectorPos(CCircuitAI* circuit, int cell) {
    const auto* data = circuit->GetTerrainManager()->GetAreaData();
    return cell >= 0 && std::size_t(cell) < data->sector.size() ? data->sector[cell].position : AIFloat3(-1.f, 0.f, -1.f);
}
AIFloat3 CEconomyManager::MexLaneChoke(int lane) {
    if (!mexTheatresEnabled) return AIFloat3(-1.f, 0.f, -1.f);
    RebuildMexTerritory();
    return lane >= 0 && std::size_t(lane) < mexLanes.lanes.size() ? SectorPos(circuit, mexLanes.lanes[lane].choke) : AIFloat3(-1.f, 0.f, -1.f);
}
AIFloat3 CEconomyManager::MexLaneMidpoint(int lane) {
    if (!mexTheatresEnabled) return AIFloat3(-1.f, 0.f, -1.f);
    RebuildMexTerritory();
    return lane >= 0 && std::size_t(lane) < mexLanes.lanes.size() ? SectorPos(circuit, mexLanes.lanes[lane].midpoint) : AIFloat3(-1.f, 0.f, -1.f);
}
std::vector<AIFloat3> CEconomyManager::MexLaneSpine(int lane, int step) {
    std::vector<AIFloat3> out;
    if (!mexTheatresEnabled) return out;
    RebuildMexTerritory();
    if (lane < 0 || std::size_t(lane) >= mexLanes.lanes.size()) return out;
    const auto& spine = mexLanes.lanes[lane].spine;
    const std::size_t stride = std::size_t(std::max(1, step));
    for (std::size_t i = 0; i < spine.size(); i += stride) out.push_back(SectorPos(circuit, spine[i]));
    if (!spine.empty() && (spine.size() - 1) % stride != 0) out.push_back(SectorPos(circuit, spine.back()));
    return out;
}

// Compact payload for the team-link widget (state key "territory"):
//   1;<frame>;<landWindow><theatreWindow>;<homeRadius>
//   ;S,<x>,<z>,<mask>,<rule>,<owner>,<lane>           one per spot
//   ;L,<id>,<midX>,<midZ>,<chokeX>,<chokeZ>,<width>,<members:t+t>,<spine x:z ...>
//   ;H,<team>,<x>,<z>                                  one per claim
std::string CEconomyManager::DescribeMexTerritory() {
    if (!mexTheatresEnabled) return "";
    RebuildMexTerritory();
    const auto& spots = circuit->GetMetalManager()->GetSpots();
    std::ostringstream text;
    text << "1;" << circuit->GetLastFrame() << ';' << (mexResolvedLandWindow ? 1 : 0) << (mexResolvedTheatreWindow ? 1 : 0) << ';' << int(mexHomeRadius);
    for (std::size_t i = 0; i < spots.size() && i < mexResolved.size(); ++i) {
        const auto& r = mexResolved[i];
        text << ";S," << int(spots[i].position.x) << ',' << int(spots[i].position.z) << ',' << r.mask << ',' << r.rule << ',' << r.owner << ',' << r.lane;
    }
    for (std::size_t l = 0; l < mexLanes.lanes.size(); ++l) {
        const auto& lane = mexLanes.lanes[l];
        const AIFloat3 mid = SectorPos(circuit, lane.midpoint), choke = SectorPos(circuit, lane.choke);
        text << ";L," << l << ',' << int(mid.x) << ',' << int(mid.z) << ',' << int(choke.x) << ',' << int(choke.z) << ',' << int(std::isfinite(lane.width) ? lane.width : -1.f) << ',';
        for (std::size_t m = 0; m < lane.members.size(); ++m) {
            if (m) text << '+';
            text << (lane.members[m] < int(mexLaneTeams.size()) ? mexLaneTeams[lane.members[m]] : -1);
        }
        const auto spine = MexLaneSpine(int(l), 4);
        for (const auto& p : spine) text << ',' << int(p.x) << ':' << int(p.z);
    }
    for (const auto& [team, claim] : mexClaims) text << ";H," << team << ',' << int(claim.start.x) << ',' << int(claim.start.z);
    return text.str();
}

void CEconomyManager::DumpMexTerritory(const char* why) {
    if (!mexTheatresEnabled) return;
    RebuildMexTerritory();
    const auto& spots = circuit->GetMetalManager()->GetSpots();
    circuit->LOG("[MexTerritory] team=%i frame=%i why=%s spots=%i lanes=%i claims=%i enemies=%i window=%i theatre=%i home=%.0f",
        circuit->GetTeamId(), circuit->GetLastFrame(), why ? why : "", int(spots.size()), int(mexLanes.lanes.size()),
        int(mexClaims.size()), int(mexEnemies.size()), mexResolvedLandWindow ? 1 : 0, mexResolvedTheatreWindow ? 1 : 0, mexHomeRadius);
    for (std::size_t i = 0; i < spots.size() && i < mexResolved.size(); ++i) {
        const auto& r = mexResolved[i];
        circuit->LOG("[MexTerritory] team=%i frame=%i spot=%i x=%.0f z=%.0f mask=%i rule=%s owner=%i arrive=%.0f secure=%.0f enemy=%.0f lane=%i",  // enemy: any class; see the claim lines for the combat classes
            circuit->GetTeamId(), circuit->GetLastFrame(), int(i), spots[i].position.x, spots[i].position.z, r.mask,
            mex_territory::RuleName(Rule(r.rule)), r.owner, std::isfinite(r.arrive) ? r.arrive : -1.f,
            std::isfinite(r.secure) ? r.secure : -1.f, std::isfinite(r.enemy) ? r.enemy : -1.f, r.lane);
    }
    for (const auto& [team, claim] : mexClaims) {
        const auto finite = [](const SMexField& f) { std::size_t n = 0; for (float d : f.distance) if (std::isfinite(d)) ++n; return int(n); };
        auto* gdef = circuit->GetCircuitDefSafe(claim.groundDef);
        auto* cdef = circuit->GetCircuitDefSafe(claim.classDef);
        auto* fdef = circuit->GetCircuitDefSafe(claim.combatDef);
        circuit->LOG("[MexTerritory] team=%i frame=%i claim=%i ground=%s groundCells=%i class=%s kind=%i seed=%i initial=%.0f classCells=%i combat=%s combatCells=%i ready=%i secure=%.0f lane=%i anchor=%.0f:%.0f",
            circuit->GetTeamId(), circuit->GetLastFrame(), team, gdef ? gdef->GetDef()->GetName() : "-", finite(claim.ground),
            cdef ? cdef->GetDef()->GetName() : "-", MexTheatreKind(claim.classDef), claim.cls.seed, claim.cls.initial, finite(claim.cls),
            fdef ? fdef->GetDef()->GetName() : "-", finite(claim.combat), claim.readyFrame, claim.secureSeconds, claim.lane, claim.anchor.x, claim.anchor.z);
    }
    circuit->LOG("[MexTerritory] team=%i frame=%i enemySeeds=%i", circuit->GetTeamId(), circuit->GetLastFrame(), int(mexEnemySeeds.size()));
    for (std::size_t l = 0; l < mexLanes.lanes.size(); ++l) {
        const auto& lane = mexLanes.lanes[l];
        const AIFloat3 mid = SectorPos(circuit, lane.midpoint), choke = SectorPos(circuit, lane.choke);
        std::string members;
        for (int m : lane.members) members += (members.empty() ? "" : "+") + std::to_string(m < int(mexLaneTeams.size()) ? mexLaneTeams[m] : -1);
        circuit->LOG("[MexTerritory] team=%i frame=%i lane=%i members=%s cells=%i midpoint=%.0f:%.0f choke=%.0f:%.0f width=%.0f",
            circuit->GetTeamId(), circuit->GetLastFrame(), int(l), members.c_str(), int(lane.spine.size()),
            mid.x, mid.z, choke.x, choke.z, std::isfinite(lane.width) ? lane.width : -1.f);
    }
}
}  // namespace circuit
