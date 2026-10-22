#include "module/EconomyManager.h"
#include "module/BuilderManager.h"
#include "resource/MetalField.h"
#include "setup/SetupManager.h"
#include "spring/SpringMap.h"
#include "task/builder/MexTask.h"
#include "task/builder/MexUpTask.h"
#include "terrain/TerrainManager.h"
#include "unit/ally/AllyTeam.h"
#include "util/GameAttribute.h"
#include "util/Utils.h"
#include "CircuitAI.h"
#include "Game.h"
#include "Log.h"
#include "json/json.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

namespace circuit {
using namespace springai;

void CEconomyManager::InitMetalField()
{
    const auto& config = circuit->GetSetupManager()->GetConfig()["economy"]["metal_map"];
    if (!config.get("enabled", false).asBool()) return;
    const float published = circuit->GetGame()->GetRulesParamFloat("mex_count", -999.f);
    // A missing publication, barren map, and positive ordinary spot list are
    // different states. calc_mex never overrides this compatibility boundary.
    if (published != -1.f) return;
    auto& grid = circuit->GetGameAttribute()->GetMetalField();
    CMap* map = circuit->GetMap();
    if (!grid.Ready()) {
        ShortVec raw;
        map->GetResourceMap(metalRes, raw);
        if (!grid.Init(map->GetWidth() / 2, map->GetHeight() / 2, map->GetMaxResource(metalRes), raw)) return;
    }
    bool known = false;
    for (const auto& name : config["maps"]) if (name.asString() == map->GetName()) known = true;
    const bool broad = grid.BroadField(map->GetExtractorRadius(metalRes));
    metalMap = broad || known;
    if (!metalMap) return;
    // A known terrain name still needs positive extraction in its raw layer.
    bool positive = false;
    for (int cell = 0; cell < grid.Columns() * grid.Rows(); ++cell)
        if (grid.Amount(cell) > 0) { positive = true; break; }
    metalMap = positive;
    fieldCandidateBudget = std::clamp(config.get("candidate_budget", 96).asInt(), 8, 256);
    fieldCellBudget = std::clamp(config.get("cell_budget", 16384).asInt(), 1024, 262144);
    fieldMinYieldFraction = std::clamp(config.get("minimum_yield_fraction", .8f).asFloat(), .1f, 1.f);
    fieldLegacyEnergyRatio = std::max(1.f, config.get("legacy_energy_ratio", 25.f).asFloat());
    fieldHomeRadius = std::clamp(config.get("home_radius", 2400.f).asFloat(), 256.f, 8000.f);
    circuit->LOG("METAL_FIELD: team=%i mode=%i schema=1 candidates=%i cells=%i map=%s",
        circuit->GetTeamId(), int(metalMap), fieldCandidateBudget, fieldCellBudget, map->GetName());
}

bool CEconomyManager::IsMetalConverter(const CCircuitDef* def) const
{
    return metalMap && def != nullptr && fieldConverters.contains(def->GetId());
}

int CEconomyManager::GetEffectiveUnitLimit() const
{
    const auto& units = circuit->GetTeamUnits();
    return units.empty() ? 0 : units.begin()->second->GetUnit()->GetLimit();
}

bool CEconomyManager::SyncFieldUnits()
{
    if (!metalMap) return false;
    auto* ally = circuit->GetAllyTeam();
    auto& claims = ally->GetMetalClaims();
    const int frame = circuit->GetLastFrame();
    if (claims.observedFrame >= 0 && frame - claims.observedFrame < FRAMES_PER_SEC) return true;
    ally->UpdateFriendlyUnits();
    auto& grid = circuit->GetGameAttribute()->GetMetalField();
    int budget = fieldCellBudget;
    std::set<metal_field::Key> alive;
    for (const auto& [id, unit] : ally->GetFriendlyUnits()) {
        const auto* def = unit->GetCircuitDef();
        if (def == nullptr || def->GetExtractsM() <= 0) continue;
        const auto key = metal_field::UnitKey(id);
        alive.insert(key);
        const auto& pos = unit->GetPos(frame);
        metal_field::Claims::Record r;
        r.owner = unit->GetUnit()->GetTeam(); r.x = pos.x; r.z = pos.z;
        r.radius = def->GetExtrRangeM(); r.depth = def->GetExtractsM();
        // Frames conservatively reserve extraction too. Max-depth composition
        // means a frame and its still-live task never double the expected yield.
        if (!claims.Upsert(key, r, grid, budget)) return false;
    }
    std::vector<metal_field::Key> gone;
    for (const auto& [key, record] : claims.Records())
        if ((key & metal_field::UnitBit) && !alive.contains(key)) gone.push_back(key);
    for (auto key : gone) claims.Erase(key);
    claims.observedFrame = frame;
    return true;
}

int CEconomyManager::GetFieldMexCount(const AIFloat3& center, float radius) const
{
    int count = 0;
    for (const auto& [id, unit] : circuit->GetTeamUnits()) {
        if (unit->GetCircuitDef()->GetExtractsM() > 0
            && unit->GetPos(circuit->GetLastFrame()).SqDistance2D(center) <= radius * radius) ++count;
    }
    for (const auto* task : circuit->GetBuilderManager()->GetTasks(IBuilderTask::BuildType::MEX))
        if (!task->IsDead() && task->GetTarget() == nullptr
            && task->GetPosition().SqDistance2D(center) <= radius * radius) ++count;
    return count;
}

float CEconomyManager::GetFieldYield(CCircuitDef* def, const AIFloat3& position)
{
    if (!metalMap || def == nullptr) return 0;
    const auto pos = CTerrainManager::Pos2BuildPos(def, position, UNIT_FACING_SOUTH);
    int budget = fieldCellBudget;
    const auto& grid = circuit->GetGameAttribute()->GetMetalField();
    return grid.Cells(pos.x, pos.z, def->GetExtrRangeM(), budget, fieldCells)
        ? grid.Isolated(fieldCells, def->GetExtractsM()) : -1.f;
}

bool CEconomyManager::ClaimFieldSite(metal_field::Key& key, CCircuitDef* def, const AIFloat3& pos, int targetId)
{
    if (!metalMap || def == nullptr || !geom::is_valid(pos) || !SyncFieldUnits()) return false;
    auto& claims = circuit->GetAllyTeam()->GetMetalClaims();
    if (key == 0) key = claims.Allocate(circuit->GetTeamId());
    if ((key & metal_field::UnitBit) || (key >> 32) != std::uint32_t(circuit->GetTeamId())) return false;
    const auto& grid = circuit->GetGameAttribute()->GetMetalField();
    int budget = fieldCellBudget;
    if (!grid.Cells(pos.x, pos.z, def->GetExtrRangeM(), budget, fieldCells)) return false;
    const float delta = claims.Marginal(grid, fieldCells, def->GetExtractsM(), key);
    // Load can adopt an already-created frame at this exact owned site.
    bool ownFrame = false;
    for (const auto& [id, unit] : circuit->GetTeamUnits())
        if (unit->GetCircuitDef() == def && unit->GetPos(circuit->GetLastFrame()).SqDistance2D(pos) < 1.f) { ownFrame = true; break; }
    if (delta <= .001f && !ownFrame) return false;
    metal_field::Claims::Record r;
    r.owner = circuit->GetTeamId(); r.x = pos.x; r.z = pos.z;
    r.radius = def->GetExtrRangeM(); r.depth = def->GetExtractsM(); r.targetId = targetId;
    return claims.Upsert(key, r, grid, budget);
}

bool CEconomyManager::OwnsFieldSite(metal_field::Key key) const
{
    return metalMap && circuit->GetAllyTeam()->GetMetalClaims().Owns(key, circuit->GetTeamId());
}

void CEconomyManager::ReleaseFieldSite(metal_field::Key key)
{
    if (!OwnsFieldSite(key)) return;
    auto& claims = circuit->GetAllyTeam()->GetMetalClaims();
    const auto record = claims.Records().at(key);
    // Promote a created frame before releasing its order, even between the
    // one-second allied snapshots. Cancelling an order must not free its frame.
    const auto& grid = circuit->GetGameAttribute()->GetMetalField();
    int budget = fieldCellBudget;
    for (const auto& [id, unit] : circuit->GetTeamUnits()) {
        const auto* def = unit->GetCircuitDef();
        if (def->GetExtractsM() <= 0) continue;
        const auto& pos = unit->GetPos(circuit->GetLastFrame());
        if (std::abs(pos.x - record.x) > 1 || std::abs(pos.z - record.z) > 1) continue;
        metal_field::Claims::Record observed;
        observed.owner = circuit->GetTeamId(); observed.x = pos.x; observed.z = pos.z;
        observed.radius = def->GetExtrRangeM(); observed.depth = def->GetExtractsM();
        if (!claims.Upsert(metal_field::UnitKey(id), observed, grid, budget)) return;
    }
    claims.Erase(key);
}

IBuilderTask* CEconomyManager::EnqueueFieldMex(CCircuitUnit* builder, const AIFloat3& center, float radius)
{
    if (!metalMap || builder == nullptr || !std::isfinite(radius) || radius <= 0 || !SyncFieldUnits()) return nullptr;
    auto* mgr = circuit->GetBuilderManager();
    if (!mgr->CanEnqueueTask(16)) return nullptr;
    auto* terrain = circuit->GetTerrainManager();
    const int frame = circuit->GetLastFrame();
    for (auto* task : mgr->GetTasks(IBuilderTask::BuildType::MEX)) {
        if (!task->IsDead() && task->GetAssignees().empty() && task->GetBuildDef() != nullptr
            && builder->GetCircuitDef()->CanBuild(task->GetBuildDef())
            && task->GetPosition().SqDistance2D(center) <= radius * radius
            && CanReachMex(builder, task->GetPosition())
            && (!mexNavigationEnabled || task->GetTarget() != nullptr || IsOwnSpot(task->GetPosition()))) return task;
    }
    auto& grid = circuit->GetGameAttribute()->GetMetalField();
    auto& claims = circuit->GetAllyTeam()->GetMetalClaims();
    int budget = fieldCellBudget, candidates = fieldCandidateBudget;
    int outside = 0, occupied = 0, territory = 0, footprint = 0, unreachable = 0, available = 0;
    auto choices = metalDefs.GetBuildDefs(builder->GetCircuitDef());
    std::stable_sort(choices.begin(), choices.end(), [](const auto* a, const auto* b) {
        return a->GetCostM() < b->GetCostM();
    });
    for (auto* def : choices) {
        if (!def->IsAvailable(frame)) continue;
        ++available;
        const float pitch = std::ceil(std::max(64.f, def->GetExtrRangeM() * 2) / 16) * 16;
        const int rings = std::min(128, int(std::ceil(radius / pitch)));
        const int total = (rings * 2 + 1) * (rings * 2 + 1);
        int& cursor = fieldCursors[def->GetId()];
        const int allowance = std::max(1, fieldCandidateBudget / int(choices.size()));
        for (int tested = 0; tested < std::min(total, allowance) && candidates-- > 0; ++tested) {
            const int index = cursor++ % total;
            const int ring = int(std::ceil((std::sqrt(float(index + 1)) - 1) * .5f));
            int dx = 0, dz = 0;
            if (ring > 0) {
                const int side = ring * 2, offset = index - (side - 1) * (side - 1);
                const int edge = offset / side, n = offset % side;
                if (edge == 0) { dx = ring; dz = -ring + 1 + n; }
                else if (edge == 1) { dx = ring - 1 - n; dz = ring; }
                else if (edge == 2) { dx = -ring; dz = ring - 1 - n; }
                else { dx = -ring + 1 + n; dz = -ring; }
            }
            // Open aisles in a large field; factory/eco reservations exclude the
            // complete footprint below. Terrain-specific routes remain mandatory.
            if ((std::abs(dx) % 8 == 7) || (std::abs(dz) % 8 == 7)) continue;
            AIFloat3 pos(center.x + dx * pitch, 0, center.z + dz * pitch);
            pos = CTerrainManager::Pos2BuildPos(def, pos, UNIT_FACING_SOUTH);
            if (!geom::is_valid(pos) || pos.SqDistance2D(center) > radius * radius
                || pos.x < 64 || pos.z < 64 || pos.x >= grid.Columns() * 16 - 64 || pos.z >= grid.Rows() * 16 - 64) { ++outside; continue; }
            if (!grid.Cells(pos.x, pos.z, def->GetExtrRangeM(), budget, fieldCells)) return nullptr;
            const float isolated = grid.Isolated(fieldCells, def->GetExtractsM());
            if (isolated <= .001f || claims.Marginal(grid, fieldCells, def->GetExtractsM()) < isolated * fieldMinYieldFraction) { ++occupied; continue; }
            pos.y = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
            const bool placeable = terrain->IsLayoutEnabled()
                ? terrain->CanReserveBuilding(def, pos, UNIT_FACING_SOUTH)
                : terrain->CanBeBuiltAt(def, pos) && !terrain->IsAllyLayoutBlocked(def, pos, UNIT_FACING_SOUTH)
                    && circuit->GetMap()->IsPossibleToBuildAt(def->GetDef(), pos, UNIT_FACING_SOUTH);
            // The coarse allied-base exclusion can cover our entire start on
            // narrow team maps. Voronoi ownership plus actual allied footprint
            // reservations above protects neighbours without forbidding our base.
            if (!IsOwnSpot(pos)) { ++territory; continue; }
            if (!placeable) { ++footprint; continue; }
            if (!CanReachMex(builder, pos)) { ++unreachable; continue; }
            auto* task = mgr->Enqueue(TaskB::Spot(IBuilderTask::BuildType::MEX, IBuilderTask::Priority::HIGH,
                def, pos, metal_field::SiteTagV1));
            if (task != nullptr) circuit->LOG("METAL_FIELD: team=%i mex=%s x=%.0f z=%.0f isolated=%.2f",
                circuit->GetTeamId(), def->GetDef()->GetName(), pos.x, pos.z, isolated);
            return task;
        }
    }
    int& reported = fieldCursors[-1];
    if (frame - reported >= 10 * FRAMES_PER_SEC) {
        reported = frame;
        circuit->LOG("METAL_FIELD: team=%i pending defs=%i outside=%i occupied=%i territory=%i footprint=%i reach=%i center=%.0f,%.0f",
            circuit->GetTeamId(), available, outside, occupied, territory, footprint, unreachable, center.x, center.z);
    }
    return nullptr; // bounded search pending; never a declaration of map exhaustion
}

IBuilderTask* CEconomyManager::EnqueueFieldUpgrade(CCircuitUnit* builder, const AIFloat3& center, float radius)
{
    if (!metalMap || builder == nullptr || !SyncFieldUnits()) return nullptr;
    auto* mgr = circuit->GetBuilderManager();
    if (!mgr->CanEnqueueTask(16) || mgr->GetTasks(IBuilderTask::BuildType::MEXUP).size() >= numMexUp) return nullptr;
    auto& claims = circuit->GetAllyTeam()->GetMetalClaims();
    int candidates = fieldCandidateBudget;
    // Stable unit-id order; upgrades belong to a real extractor, never its
    // nearest synthetic legacy spot. Allied upgrade delivery is separate policy.
    for (const auto& [id, unit] : circuit->GetTeamUnits()) {
        const auto* old = unit->GetCircuitDef();
        if (old->GetExtractsM() <= 0 || unit->GetUnit()->IsBeingBuilt() || !claims.TargetAvailable(id)) continue;
        const auto& pos = unit->GetPos(circuit->GetLastFrame());
        if (pos.SqDistance2D(center) > radius * radius) continue;
        if (--candidates < 0) break;
        for (auto* def : metalDefs.GetBuildDefs(builder->GetCircuitDef())) {
            if (def->GetExtractsM() <= old->GetExtractsM() || !def->IsAvailable(circuit->GetLastFrame())) continue;
            if (!CanReachMex(builder, pos)) continue;
            auto* task = mgr->Enqueue(TaskB::Spot(IBuilderTask::BuildType::MEXUP,
                IBuilderTask::Priority::HIGH, def, pos, metal_field::SiteTagV1));
            return task;
        }
    }
    return nullptr;
}
}
