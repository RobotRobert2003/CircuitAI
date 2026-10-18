#include "module/EconomyManager.h"
#include "resource/MexNavigation.h"
#include "resource/MetalManager.h"
#include "terrain/TerrainManager.h"
#include "setup/SetupManager.h"
#include "unit/ally/AllyUnit.h"
#include "spring/SpringCallback.h"
#include "map/ThreatMap.h"
#include "CircuitAI.h"

#include <algorithm>
#include <cmath>

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
