#include "terrain/ReservationCandidates.h"
/*
 * TerrainManager.cpp
 *
 *  Created on: Dec 6, 2014
 *      Author: rlcevg
 */

#include "terrain/TerrainManager.h"
#include "terrain/LayoutRanking.h"
#include "terrain/NavalGeometry.h"
#include "Sim/MoveTypes/MoveDefHandler.h"
#include "terrain/BlockRectangle.h"
#include "terrain/BlockCircle.h"
#include "terrain/path/PathFinder.h"
#include "terrain/path/QueryPathWide.h"
#include "map/ThreatMap.h"
#include "map/MapManager.h"
#include "map/InfluenceMap.h"
#include "module/EconomyManager.h"
#include "module/BuilderManager.h"  // Only for UpdateAreaUsers
#include "resource/MetalManager.h"
#include "resource/EnergyManager.h"
#include "scheduler/Scheduler.h"
#include "setup/SetupManager.h"
#include "unit/CircuitUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "util/Profiler.h"
#include "util/Performance.h"
#include "json/json.h"

#include "spring/SpringMap.h"

#include "OOAICallback.h"
#include "WeaponDef.h"
#include "Pathing.h"
#include "MoveData.h"
#include "Log.h"

#include <algorithm>
#include <limits>
#include <cmath>
#include <chrono>
#include <cstdlib>

// D-083 diagnosis (KI-419): any layout call over SLOW_CALL_MS is logged with its
// cost, so a sim stall names the function that caused it.
namespace {
inline circuit::layout_rank::Pt ToPt(const springai::AIFloat3& p) { return circuit::layout_rank::Pt{p.x, p.z}; }  // D-094
// D-314 / KI-591: reject before float-to-int conversion, threat/influence
// indexing or the flying-unit shortcut. An index-only guard lets x wrap into
// an adjacent row. These O(1) checks allocate nothing and do not clamp a bad
// request into a different job. Actual-VM coverage: run_terrain_reachability.py.
bool ValidReachDestination(const springai::AIFloat3& p, float range = 0.f) {
    return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z)
        && p.x >= 0.f && p.z >= 0.f
        && p.x < springai::AIFloat3::maxxpos && p.z < springai::AIFloat3::maxzpos
        && std::isfinite(range) && range >= 0.f;
}
constexpr double SLOW_CALL_MS = 20.0;
struct SSlowCall {
	const char* name; circuit::CCircuitAI* ai; std::chrono::steady_clock::time_point t0;
	SSlowCall(const char* n, circuit::CCircuitAI* a) : name(n), ai(a), t0(std::chrono::steady_clock::now()) {}
	~SSlowCall() {
		const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
		if (ms > SLOW_CALL_MS) { ai->LOG("SLOW: %s took %.0f ms", name, ms); }
	}
};
}
#include <cstdio>
#include <string_view>

namespace circuit {

// D-074: the exit a factory keeps clear, in elmos (the first lab's exit cone: 320 long, 32 margin)
static constexpr float EXIT_CLEAR_LENGTH = 320.f;
static constexpr float EXIT_CLEAR_MARGIN = 32.f;


using namespace springai;
using namespace terrain;

namespace {

void WriteLayoutString(std::ostream& os, const std::string& value)
{
	const uint32_t size = static_cast<uint32_t>(value.size());
	utils::binary_write(os, size);
	os.write(value.data(), size);
}

bool ReadLayoutString(std::istream& is, std::string& value)
{
	uint32_t size = 0;
	utils::binary_read(is, size);
	if (!is.good() || (size > 4096)) {
		return false;
	}
	value.resize(size);
	if (size > 0) {
		is.read(value.data(), size);
	}
	return is.good();
}

} // namespace

CTerrainManager::CTerrainManager(CCircuitAI* circuit, CTerrainData* terrainData)
		: circuit(circuit)
		, allyZoneCells(9)
		, terrainData(terrainData)
#ifdef DEBUG_VIS
		, dbgTextureId(-1)
		, sdlWindowId(-1)
		, dbgMap(nullptr)
#endif
{
	ResetBuildFrame();

	CMap* map = circuit->GetMap();
	int mapWidth = map->GetWidth();
	int mapHeight = map->GetHeight();
	blockingMap.columns = mapWidth / 2;  // build-step = 2 * SQUARE_SIZE
	blockingMap.rows = mapHeight / 2;
	SBlockingMap::SBlockCell cell = {0};
	blockingMap.grid.resize(blockingMap.columns * blockingMap.rows, cell);

	blockingMap.columnsLow = mapWidth / (GRID_RATIO_LOW * 2);
	blockingMap.rowsLow = mapHeight / (GRID_RATIO_LOW * 2);
	SBlockingMap::SBlockCellLow cellLow = {0};
	blockingMap.gridLow.resize(blockingMap.columnsLow * blockingMap.rowsLow, cellLow);

	blockingMap.columnsAlly = mapWidth / (GRID_RATIO_ALLY * 2);
	blockingMap.rowsAlly = mapHeight / (GRID_RATIO_ALLY * 2);
	SBlockingMap::SBlockCellAlly cellAlly = {0};
	blockingMap.gridAlly.resize(blockingMap.columnsAlly * blockingMap.rowsAlly, cellAlly);
}

CTerrainManager::~CTerrainManager()
{
	if (circuit->GetAllyTeam() != nullptr) circuit->GetAllyTeam()->GetLayoutReservations().RemoveOwner(circuit->GetTeamId());
	for (auto& kv : blockInfos) {
		delete kv.second;
	}

#ifdef DEBUG_VIS
	if (dbgTextureId >= 0) {
		circuit->GetDebugDrawer()->DelOverlayTexture(dbgTextureId);
		circuit->GetDebugDrawer()->DelSDLWindow(sdlWindowId);
		delete[] dbgMap;
	}
#endif
}

void CTerrainManager::InitAnalyzer()
{
	assert(terrainData->IsInitialized());
	terrainData->AnalyzeMap(circuit);

	areaData = terrainData->pAreaData.load();

	ReadConfig();
}

void CTerrainManager::ReadConfig()
{
	/*
	 * Building masks
	 */
	struct SBlockDesc {
		SBlockingMap::StructType structType;
		int structIdx;
		int2 offset;
		int2 yard;
		int radius;
		int radIdx;
		int2 ssize;
		int sizeIdx;
		int ignoreMask;
	};

	const Json::Value& root = circuit->GetSetupManager()->GetConfig();
	const std::string& cfgName = circuit->GetSetupManager()->GetConfigName();
	const Json::Value& block = root["building"];
	SBlockingMap::StructTypes& structTypes = SBlockingMap::GetStructTypes();
	SBlockingMap::StructMasks& structMasks = SBlockingMap::GetStructMasks();
	const std::array<std::string, 2> blockNames = {"rectangle", "circle"};
	enum {RECTANGLE = 0, CIRCLE};
	const std::array<std::string, 2> radNames = {"explosion", "expl_ally"};
	enum {EXPLOSION = 0, EXPL_ALLY};
	minLandPercent = root["select"].get("min_land", 40.0f).asFloat();
	// JSON permits the mechanism; a role must still opt its own AI instance in.
	layoutConfigured = root["layout"].get("enabled", false).asBool();
	layoutEnabled = false;
	const bool isWaterMap = IsWaterMap();

	const Json::Value& clLand = block["class_land"];
	const Json::Value& clWater = block["class_water"];
	const Json::Value& instance = block["instance"];

	auto readBlockDesc = [this, &cfgName, &structTypes, &structMasks, &blockNames, &radNames]
						 (const char* clName, const Json::Value& cls, SBlockDesc& outDesc)
	{
		const Json::Value& type = cls["type"];
		const std::string& strST = type.get((unsigned)1, "").asString();
		auto it = structTypes.find(strST);
		if (it == structTypes.end()) {
			circuit->LOG("CONFIG %s: '%s' has unknown struct type '%s'", cfgName.c_str(), clName, strST.c_str());
			return false;
		}
		outDesc.structType = it->second;

		outDesc.structIdx = -1;
		const std::string& strBT = type.get((unsigned)0, "").asString();
		for (unsigned i = 0; i < blockNames.size(); ++i) {
			if (strBT == blockNames[i]) {
				outDesc.structIdx = i;
				break;
			}
		}
		if (outDesc.structIdx < 0) {
			circuit->LOG("CONFIG %s: '%s' has unknown block type '%s'", cfgName.c_str(), clName, strBT.c_str());
			return false;
		}

		const Json::Value& offs = cls["offset"];
		outDesc.offset = int2(offs.get((unsigned)0, 0).asInt(), offs.get((unsigned)1, 0).asInt());

		outDesc.radIdx = -1;
		switch (outDesc.structIdx) {
			default:
			case RECTANGLE: {
				const Json::Value& rd = cls["yard"];
				outDesc.yard = int2(rd.get((unsigned)0, 0).asInt(), rd.get((unsigned)1, 0).asInt());
			} break;
			case CIRCLE: {
				const Json::Value& rad = cls["radius"];
				if (rad.empty()) {
					outDesc.radIdx = EXPLOSION;
				} else if (rad.isString()) {
					const std::string& strRad = rad.asString();
					for (unsigned i = 0; i < radNames.size(); ++i) {
						if (strRad == radNames[i]) {
							outDesc.radIdx = i;
							break;
						}
					}
					if (outDesc.radIdx < 0) {
						circuit->LOG("CONFIG %s: '%s' has unknown radius '%s'", cfgName.c_str(), clName, strRad.c_str());
						outDesc.radIdx = EXPLOSION;
					}
				} else {
					outDesc.radius = rad.asInt();
				}
			} break;
		}

		outDesc.sizeIdx = -1;
		const Json::Value& size = cls["size"];
		if (!size.empty()) {
			outDesc.ssize = int2(size.get((unsigned)0, 0).asInt(), size.get((unsigned)1, 0).asInt());
			outDesc.sizeIdx = 0;
		}

		outDesc.ignoreMask = STRUCT_BIT(NONE);
		const Json::Value& ignore = cls["ignore"];
		if (!ignore.empty()) {
			for (const Json::Value& mask : ignore) {
				auto it = structMasks.find(mask.asString());
				if (it == structMasks.end()) {
					circuit->LOG("CONFIG %s: '%s' has unknown ignore type '%s'", cfgName.c_str(), clName, mask.asCString());
				} else {
					outDesc.ignoreMask |= static_cast<SBlockingMap::SM>(it->second);
				}
			}
		} else {
			const Json::Value& notIgnore = cls["not_ignore"];
			if (!notIgnore.empty()) {
				int notIgnoreMask = STRUCT_BIT(NONE);
				for (const Json::Value& mask : notIgnore) {
					auto it = structMasks.find(mask.asString());
					if (it == structMasks.end()) {
						circuit->LOG("CONFIG %s: '%s' has unknown not_ignore type '%s'", cfgName.c_str(), clName, mask.asCString());
					} else {
						notIgnoreMask |= static_cast<SBlockingMap::SM>(it->second);
					}
				}
				outDesc.ignoreMask = STRUCT_BIT(ALL) & ~notIgnoreMask;
			}
		}

		return true;
	};

	auto createBlockInfo = [this](SBlockDesc& blockDesc, UnitDef* def) {
		if (blockDesc.sizeIdx < 0) {
			blockDesc.ssize = int2(def->GetXSize() / 2, def->GetZSize() / 2);
		}

		IBlockMask* blocker;
		switch (blockDesc.structIdx) {
			default:
			case RECTANGLE: {
				int2 bsize = blockDesc.ssize + blockDesc.yard;
				blocker = new CBlockRectangle(blockDesc.offset, bsize, blockDesc.ssize, blockDesc.structType, blockDesc.ignoreMask);
			} break;
			case CIRCLE: {
				switch (blockDesc.radIdx) {
					case EXPLOSION: {
						WeaponDef* wpDef = def->GetDeathExplosion();
						blockDesc.radius = wpDef->GetAreaOfEffect() / (SQUARE_SIZE * 2);
						delete wpDef;
					} break;
					case EXPL_ALLY: {
						WeaponDef* wpDef = def->GetDeathExplosion();
						blockDesc.radius = wpDef->GetAreaOfEffect() / (SQUARE_SIZE * 2);
						// [radius ~ 1 player ; radius/2 ~ 4+ players]
						blockDesc.radius -= blockDesc.radius / 6 * (std::min(circuit->GetAllyTeam()->GetSize(), 4) - 1);
						delete wpDef;
					} break;
					default: break;
				}
				blocker = new CBlockCircle(blockDesc.offset, blockDesc.radius, blockDesc.ssize, blockDesc.structType, blockDesc.ignoreMask);
			} break;
		}
		return blocker;
	};

	for (const std::string& clName : instance.getMemberNames()) {
		Json::Value cls = isWaterMap ? clWater[clName] : Json::Value::nullSingleton();
		if (cls.empty()) {
			cls = clLand[clName];
			if (cls.empty()) {
				circuit->LOG("CONFIG %s: unknown instances of class '%s'", cfgName.c_str(), clName.c_str());
				continue;
			}
		}

		SBlockDesc blockDesc;
		if (!readBlockDesc(clName.c_str(), cls, blockDesc)) {
			continue;
		}

		const Json::Value& defNames = instance[clName];
		for (const Json::Value& def : defNames) {
			CCircuitDef* cdef = circuit->GetCircuitDef(def.asCString());
			if (cdef == nullptr) {
				circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), def.asCString());
				continue;
			}

			if (blockInfos.find(cdef->GetId()) != blockInfos.end()) {
				circuit->LOG("CONFIG %s: ignored block_map duplicate of '%s'", cfgName.c_str(), def.asCString());
				continue;
			}

			blockInfos[cdef->GetId()] = createBlockInfo(blockDesc, cdef->GetDef());
		}
	}

	SBlockDesc blockDesc;
	const char* defName = "_default_";
	if (readBlockDesc(defName, clLand[defName], blockDesc)) {
		for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
			if (!cdef.IsMobile() && (blockInfos.find(cdef.GetId()) == blockInfos.end())) {
				blockInfos[cdef.GetId()] = createBlockInfo(blockDesc, cdef.GetDef());
			}
		}
	}
}

void CTerrainManager::Init()
{
    resourceLayout.clear();
    const auto describeResource = [this](const char* kind, const int2& a, const int2& b) {
        char entry[128];
        snprintf(entry, sizeof(entry), "resource:%s:%i:%i:0:%i:%i:r;", kind,
            (a.x + b.x) * SQUARE_SIZE, (a.y + b.y) * SQUARE_SIZE,
            (b.x - a.x) * SQUARE_SIZE * 2, (b.y - a.y) * SQUARE_SIZE * 2);
        resourceLayout += entry;
    };
	const CMetalData::Metals& mspots = circuit->GetMetalManager()->GetSpots();
	CCircuitDef* cdef = circuit->GetEconomyManager()->GetSideInfo().mexDef;
	int xsize, zsize;
	auto it = blockInfos.find(cdef->GetId());
	if (it != blockInfos.end()) {
		xsize = it->second->GetXSize();
		zsize = it->second->GetZSize();
	} else {
		xsize = cdef->GetDef()->GetXSize() / 2;
		zsize = cdef->GetDef()->GetZSize() / 2;
	}
	int notIgnoreMask = ~STRUCT_BIT(MEX);  // all except mex
	for (auto& spot : mspots) {
		if (circuit->GetEconomyManager()->IsMetalMap()) break;
		const AIFloat3 pos = Pos2BuildPos(cdef, spot.position, UNIT_FACING_SOUTH);
		const int x1 = int(pos.x / (SQUARE_SIZE << 1)) - (xsize >> 1), x2 = x1 + xsize;
		const int z1 = int(pos.z / (SQUARE_SIZE << 1)) - (zsize >> 1), z2 = z1 + zsize;
		int2 m1(x1, z1);
		int2 m2(x2, z2);
		blockingMap.Bound(m1, m2);
        describeResource("metal", m1, m2);
		for (int z = m1.y; z < m2.y; ++z) {
			for (int x = m1.x; x < m2.x; ++x) {
				blockingMap.MarkBlocker(x, z, SBlockingMap::StructType::MEX, notIgnoreMask);
			}
		}
	}

	const CEnergyData::Geos& espots = circuit->GetEnergyManager()->GetSpots();
	cdef = circuit->GetEconomyManager()->GetSideInfo().geoDef;
	it = blockInfos.find(cdef->GetId());
	if (it != blockInfos.end()) {
		xsize = it->second->GetXSize();
		zsize = it->second->GetZSize();
	} else {
		xsize = cdef->GetDef()->GetXSize() / 2;
		zsize = cdef->GetDef()->GetZSize() / 2;
	}
	notIgnoreMask = ~STRUCT_BIT(GEO);  // all except geo
	for (auto& spot : espots) {
		const AIFloat3 pos = Pos2BuildPos(cdef, spot, UNIT_FACING_SOUTH);
		const int x1 = int(pos.x / (SQUARE_SIZE << 1)) - (xsize >> 1), x2 = x1 + xsize;
		const int z1 = int(pos.z / (SQUARE_SIZE << 1)) - (zsize >> 1), z2 = z1 + zsize;
		int2 m1(x1, z1);
		int2 m2(x2, z2);
		blockingMap.Bound(m1, m2);
        describeResource("geo", m1, m2);
		for (int z = m1.y; z < m2.y; ++z) {
			for (int x = m1.x; x < m2.x; ++x) {
				blockingMap.MarkBlocker(x, z, SBlockingMap::StructType::GEO, notIgnoreMask);
			}
		}
	}

	// Mark edges of the map
	notIgnoreMask = STRUCT_BIT(NONE);
	for (int j = 0; j < 4; ++j) {
		for (int i = 5; i < blockingMap.columns - 5; ++i) {
			blockingMap.MarkBlocker(i, j, SBlockingMap::StructType::TERRA, notIgnoreMask);
			blockingMap.MarkBlocker(i, blockingMap.rows - j - 1, SBlockingMap::StructType::TERRA, notIgnoreMask);
		}
	}
	for (int j = 5; j < blockingMap.rows - 5; ++j) {
		for (int i = 0; i < 4; ++i) {
			blockingMap.MarkBlocker(i, j, SBlockingMap::StructType::TERRA, notIgnoreMask);
			blockingMap.MarkBlocker(blockingMap.columns - i - 1, j, SBlockingMap::StructType::TERRA, notIgnoreMask);
		}
	}
}

void CTerrainManager::AddBlocker(CCircuitDef* cdef, const AIFloat3& pos, int facing, bool isOffset)
{
	AIFloat3 newPos = pos;
	if (isOffset) {
		newPos += cdef->GetMidPosOffset(facing);
	}

	SStructure building = {-1, cdef, newPos, facing};
	MarkBlocker(building, true);

#ifdef DEBUG_VIS
	UpdateVis();
#endif
}

void CTerrainManager::DelBlocker(CCircuitDef* cdef, const AIFloat3& pos, int facing, bool isOffset)
{
	AIFloat3 newPos = pos;
	if (isOffset) {
		newPos += cdef->GetMidPosOffset(facing);
	}

	SStructure building = {-1, cdef, newPos, facing};
	MarkBlocker(building, false);

	if (!zones.empty()) {
		// Zone ground under a structure that went is held again, and the slot
		// it stood on is restored (final def) or forgotten (tenant).
		int2 c1, c2;
		if (ReservationCells(cdef, newPos, facing, c1, c2)) {
			RemarkZoneCells(int2(c1.x - 8, c1.y - 8), int2(c2.x + 8, c2.y + 8));
		}
		OnStructureGone(cdef, newPos);
	}

#ifdef DEBUG_VIS
	UpdateVis();
#endif
}

bool CTerrainManager::IsObstruct(const AIFloat3& pos) const
{
	const int x = int(pos.x + 0.5f) / (SQUARE_SIZE * 2);
	const int z = int(pos.z + 0.5f) / (SQUARE_SIZE * 2);

	return blockingMap.IsStruct(x, z);
}

//AIFloat3 CTerrainManager::CheckObstruct(CCircuitUnit* unit) const
//{
//	/*
//	 * Check 4 directions WRT unit radius and find shortest direction out of struct
//	 */
//	// FIXME: false positives on solars: no way to distinguish between plan and building.
//	//        Short path out of struct isn't towards build-target or in free space -
//	//        may stuck going back and forth between 2 close buildings.
//	if (unit->GetCircuitDef()->GetMobileId() < 0) {
//		return -RgtVector;
//	}
//
//	const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
//	const int2 c(int(pos.x + 0.5f) / (SQUARE_SIZE * 2), int(pos.z + 0.5f) / (SQUARE_SIZE * 2));
//	const int radius = unit->GetCircuitDef()->GetRadius() / (SQUARE_SIZE * 2);
//	const std::array<int2, 4> exts = {
//		int2(0, radius),  // UNIT_FACING_SOUTH
//		int2(radius, 0),  // UNIT_FACING_EAST
//		int2(0, -radius),  // UNIT_FACING_NORTH
//		int2(-radius, 0)  // UNIT_FACING_WEST
//	};
//	const std::array<int2, 4> dirs = {
//		int2(0, -1),  // UNIT_FACING_SOUTH
//		int2(-1, 0),  // UNIT_FACING_EAST
//		int2(0, 1),  // UNIT_FACING_NORTH
//		int2(1, 0)  // UNIT_FACING_WEST
//	};
//
//	std::array<int2, 4> cs = {
//		c + exts[UNIT_FACING_SOUTH],
//		c + exts[UNIT_FACING_EAST],
//		c + exts[UNIT_FACING_NORTH],
//		c + exts[UNIT_FACING_WEST]
//	};
//	std::vector<int> facings;
//	facings.reserve(4);
//	for (int facing = 0; facing < 4; ++facing) {
//		const int2 t = cs[facing];
//		if (blockingMap.IsInBounds(t.x, t.y) && blockingMap.IsStruct(t.x, t.y)) {
//			facings.push_back(facing);
//		}
//	}
//	if (facings.empty()) {
//		return -RgtVector;
//	}
//
//	int facing = UNIT_NO_FACING;
//	int numTry = 0;
//	constexpr int NUM_TRIES = 32;
//	do {
//		for (int f : facings) {
//			const int2 t = (cs[f] += dirs[f]);
//			if (blockingMap.IsInBounds(t.x, t.y) && !blockingMap.IsStruct(t.x, t.y)) {
//				facing = f;
//				break;
//			}
//		}
//	} while ((facing == UNIT_NO_FACING) && (++numTry < NUM_TRIES));
//
//	const int2 t = cs[facing] - exts[facing] + dirs[facing];  // +dirs[facing] is slack, engine ignores short move-order
//	if ((numTry >= NUM_TRIES) || !blockingMap.IsInBounds(t.x, t.y)) {
//		return geom::get_radial_pos(pos, 64.f);
//	}
//
//	return AIFloat3(t.x * (SQUARE_SIZE * 2) + SQUARE_SIZE, 0, t.y * (SQUARE_SIZE * 2) + SQUARE_SIZE);
//}

void CTerrainManager::AddBusPath(CCircuitUnit* unit, const AIFloat3& toPos, CCircuitDef* mobileDef)
{
	AIFloat3 startPos = unit->GetPos(circuit->GetLastFrame());
	bool isOK;
	SArea* area;
	std::tie(area, isOK) = GetCurrentMapArea(mobileDef, startPos);
	if (!isOK) {
		return;
	}
	const int iS = GetSectorIndex(toPos);
	// FIXME: altitude works only for armcom (amphibious) move-type;
	//        create additional for land, and for water?
	constexpr int altitude = 4 * 2 * ALTITUDE_SCALE;  // 4 - tiles in sector, side
	SAreaSector* CAS = GetClosestSectorWithAltitude(area, iS, altitude);
	if (CAS == nullptr) {
		return;
	}

	AIFloat3 sectorStep;
	switch (unit->GetUnit()->GetBuildingFacing()) {
		default:
		case UNIT_FACING_SOUTH: {
			// FIXME: startPos is aimpoint, not center
			const int edgeZH = unit->GetCircuitDef()->GetDef()->GetZSize() * (SQUARE_SIZE / 2) + SQUARE_SIZE * 5;
			sectorStep = AIFloat3(0.f, 0.f, GetConvertStoP());
			startPos += AIFloat3(0.f, 0.f, edgeZH);
		} break;
		case UNIT_FACING_EAST: {
			const int edgeXH = unit->GetCircuitDef()->GetDef()->GetXSize() * (SQUARE_SIZE / 2) + SQUARE_SIZE * 5;
			sectorStep = AIFloat3(GetConvertStoP(), 0.f, 0.f);
			startPos += AIFloat3(edgeXH, 0.f, 0.f);
		} break;
		case UNIT_FACING_NORTH: {
			const int edgeZH = unit->GetCircuitDef()->GetDef()->GetZSize() * (SQUARE_SIZE / 2) + SQUARE_SIZE * 5;
			sectorStep = AIFloat3(0.f, 0.f, -GetConvertStoP());
			startPos += AIFloat3(0.f, 0.f, -edgeZH);
		} break;
		case UNIT_FACING_WEST: {
			const int edgeXH = unit->GetCircuitDef()->GetDef()->GetXSize() * (SQUARE_SIZE / 2) + SQUARE_SIZE * 5;
			sectorStep = AIFloat3(-GetConvertStoP(), 0.f, 0.f);
			startPos += AIFloat3(-edgeXH, 0.f, 0.f);
		} break;
	}
	if (!geom::is_in_map(startPos) || !CanMoveToPos(area, startPos)) {
		startPos -= sectorStep;
	}

	const AIFloat3& endPos = CAS->S->position;

	// NOTE: heuristic in micropather may lead not to closest node, but a bit further,
	//       as it tests only single end-node.
	//       Reduce end-nodes in half (interleave) and test manhattan distance to each?
	IndexVec targets;
	for (const auto& kv : busPath) {
		if (kv.second.pPath != nullptr) {
			// targets will have many duplicates, but performance hit shouldn't
			// worth an effort to store additional array of only unique sectors
			// @see FillParentBusNodes
			auto startIt = kv.second.pPath->path.begin();
			const int dist = 1024 / GetConvertStoP();  // 1024 / 32|64|128
			// TODO: Better to advance from closest point, then dist can be halved
			std::advance(startIt, std::min<int>(dist, kv.second.pPath->path.size()));
			targets.insert(targets.end(), startIt, kv.second.pPath->path.end());
		}
	}

	FactoryPathQuery& fpq = busQueries[unit];
	fpq.mobileDef = mobileDef;
	fpq.startPos = startPos;
	fpq.endPos = endPos;
	fpq.targets = std::move(targets);
	busPath[unit] = {nullptr, 0};
}

void CTerrainManager::DelBusPath(CCircuitUnit* unit)
{
	auto it = busPath.find(unit);
	if (it == busPath.end()) {
		return;
	}

	if (it->second.pPath != nullptr) {
		// TODO: Path for new factories contains only part that connects to 1st built path.
		//       Hence removing it leaves others with short leftover.
		//       Place it to AllyTeam and count or copy common path nodes.
		CPathFinder* pathfinder = circuit->GetPathfinder();
		const int granularity = pathfinder->GetSquareSize() / (SQUARE_SIZE * 2);
		const int howWide = it->second.howWide;
		const int squares = howWide * granularity;
		for (int index : it->second.pPath->path) {
			int ix, iz;
			pathfinder->PathIndex2PathXY(index, &ix, &iz);

			ix = ix * granularity + granularity / 2;
			iz = iz * granularity + granularity / 2;
			int2 m1 = (howWide & 1) ? int2(ix - squares / 2, iz - squares / 2)
					: int2(ix - (squares - granularity) / 2, iz - (squares - granularity) / 2);
			int2 m2 = (howWide & 1) ? int2(ix + squares / 2, iz + squares / 2)
					: int2(ix + (squares + granularity) / 2, iz + (squares + granularity) / 2);
			blockingMap.Bound(m1, m2);
			for (int z = m1.y; z < m2.y; ++z) {
				for (int x = m1.x; x < m2.x; ++x) {
					blockingMap.DelBlocker(x, z, SBlockingMap::StructType::TERRA);
				}
			}
		}
	}
	busPath.erase(it);
	busQueries.erase(unit);
}

AIFloat3 CTerrainManager::GetBusPos(CCircuitDef* facDef, const AIFloat3& pos, int& outFacing)
{
	outFacing = UNIT_NO_FACING;

	CCircuitUnit* unit = nullptr;
	CPathInfo* pathInfo = nullptr;
	const int frame = circuit->GetLastFrame();
	float minSqDist = std::numeric_limits<float>::max();
	for (auto& kv : busPath) {
		const float sqDist = kv.first->GetPos(frame).SqDistance2D(pos);
		if ((minSqDist > sqDist) && (kv.second.pPath != nullptr)) {
			minSqDist = sqDist;
			unit = kv.first;
			pathInfo = kv.second.pPath.get();
		}
	}
	if ((unit == nullptr) || pathInfo->path.empty()) {
		return pos;
	}

	// TODO: make sorted offsets pattern for this specific case, instead of circle.
	// After reclaiming old eco there could be blocked position for T3 in the back.
	// a) use max howWide all the time?
	// b) pre-occupy place for T2 and T3, as current "build along path" moves factory closer to front?
	CPathFinder* pathfinder = circuit->GetPathfinder();
	const int incr = std::max(1, 128 / GetConvertStoP());  // convertStoP ~= 32, 64, 128
	const int maxIdx = std::min<int>(pathInfo->path.size(), 32 * incr);
	AIFloat3 prevPos = pathfinder->PathIndex2Pos(pathInfo->path[0]);
	const int zElmoSize = facDef->GetDef()->GetZSize() * SQUARE_SIZE;
	const float searchRadius = std::max(zElmoSize / 2 + SQUARE_SIZE * 2, GetConvertStoP());
	const std::array<AIFloat3, 4> faceOffs = {
		AIFloat3(0, 0, -(GetConvertStoP() * incr + zElmoSize) / 2),  // UNIT_FACING_SOUTH
		AIFloat3(-(GetConvertStoP() * incr + zElmoSize) / 2, 0, 0),  // UNIT_FACING_EAST
		AIFloat3(0, 0, (GetConvertStoP() * incr + zElmoSize) / 2),  // UNIT_FACING_NORTH
		AIFloat3((GetConvertStoP() * incr + zElmoSize) / 2, 0, 0)  // UNIT_FACING_WEST
	};
	for (int index = incr; index < maxIdx; index += incr) {
		const AIFloat3& pathPos = pathfinder->PathIndex2Pos(pathInfo->path[index]);
		std::array<int, 2> testFaces;
		if (std::fabs(pathPos.x - prevPos.x) > std::fabs(pathPos.z - prevPos.z)) {
			testFaces = {UNIT_FACING_SOUTH, UNIT_FACING_NORTH};
		} else {
			testFaces = {UNIT_FACING_EAST, UNIT_FACING_WEST};
		}
		for (int facing : testFaces) {
			AIFloat3 buildPos = pathPos + faceOffs[facing];
			CTerrainManager::CorrectPosition(buildPos);
			buildPos = FindBuildSite(facDef, buildPos, searchRadius, facing, false, true);
			if (geom::is_valid(buildPos)) {
				outFacing = facing;
				return buildPos;
			}
		}
		prevPos = pathPos;
	}
	return pos;
}

AIFloat3 CTerrainManager::FindBuildSite(CCircuitDef* cdef, const AIFloat3& pos,
		float searchRadius, int facing, bool isIgnore, bool isHighRes)
{
	TerrainPredicate predicate = [](const AIFloat3& p) {
		return true;
	};
	return FindBuildSite(cdef, pos, searchRadius, facing, predicate, isIgnore, isHighRes);
}

AIFloat3 CTerrainManager::FindBuildSite(CCircuitDef* cdef, const AIFloat3& pos,
		float searchRadius, int facing, TerrainPredicate& requested, bool isIgnore, bool isHighRes)
{
	ZoneScoped;
	TerrainPredicate predicate = [this, cdef, facing, &requested](const AIFloat3& p) {
		return !IsResourceFootprintBlocked(cdef, p, facing)
			&& (cdef->IsMobile() || !IsAllyLayoutBlocked(cdef, p, facing)) && requested(p);
	};

	if (circuit->IsAllyAware()) {
		MarkAllyBuildings();
	}

	// A planned site for this def wins over the spiral; see the header. Only a
	// builder task's search may take one (BeginReservedSearch), and the hand-off
	// is cleared first so a stale id never reaches the next task (CR-002).
	lastReservedId = -1;
	lastReservedFacing = -1;
	const bool serve = reservationSearch;
	const bool required = pinnedReservationRequired;
	const int facingFilter = reservationSearch ? reservationFacingFilter : -1;
	reservationFacingFilter = -1;
	reservationSearch = false;
	if (!serve) {
		pinnedReservation = -1;
		pinnedReservationRequired = false;
	}
	if (layoutEnabled && serve && !reservations.empty()) {
		AIFloat3 rpos;
		int rfacing, rid;
		if (FindReservedSite(cdef, pos, predicate, rpos, rfacing, rid, facingFilter)) {
			lastReservedId = rid;
			lastReservedFacing = rfacing;
			return rpos;
		}
	}
	if (required) {
		// A task explicitly pinned to the layout must never build elsewhere.
		pinnedReservation = -1;
		pinnedReservationRequired = false;
		return -RgtVector;
	}
    predicate = [this, cdef, facing, &requested](const AIFloat3& p) {
        if (IsResourceFootprintBlocked(cdef, p, facing)) return false;
        if (!cdef->IsMobile() && !IsResourceBuildingSite(cdef, p, facing)) {
            if (IsAllyLayoutBlocked(cdef, p, facing)) return false;
            int2 a, b;
            if (ReservationCells(cdef, Pos2BuildPos(cdef, p, facing), facing, a, b)) {
                for (const auto& entry : zones) {
                    const auto& z = entry.second;
                    if (a.x < z.c2.x && z.c1.x < b.x && a.y < z.c2.y && z.c1.y < b.y) return false;
                }
            }
        }
        return requested(p);
    };
	if (circuit->GetBuilderManager()->IsExperimentalBuild() && !cdef->IsMobile()) {
		// D-066: never the stock spiral for this instance. The site is the
		// free footprint nearest the asked anchor, reserved and served.
		// Structures only (D-068): a recruit, rally or retreat asks for a free
		// spot for a mobile unit, and a packed reservation for one is never
		// forgotten (no structure ever stands on it) - 21 of them blocked the
		// turret box on 2026-09-21. Those asks take the stock search below.
		const float radius = std::min(searchRadius, circuit->GetBuilderManager()->GetExperimentalSearchRadius());
		return PackNearPoint(cdef, pos, radius, facing, predicate);
	}

	auto search = blockInfos.find(cdef->GetId());
	if (search != blockInfos.end()) {
		IBlockMask* mask = search->second;
		int xmsize = mask->GetXSize();
		int zmsize = mask->GetZSize();
		if (!isHighRes && (searchRadius > SQUARE_SIZE * 2 * 100 || xmsize * zmsize > GRID_RATIO_LOW * GRID_RATIO_LOW * 4)) {
			return FindBuildSiteByMaskLow(cdef, pos, searchRadius, facing, mask, predicate);
		}
		return FindBuildSiteByMask(cdef, pos, searchRadius, facing, mask, predicate);
	}

	if (searchRadius > SQUARE_SIZE * 2 * 100) {
		return FindBuildSiteLow(cdef, pos, searchRadius, facing, predicate);  // isIgnore = false
	}

	/*
	 * Default FindBuildSite
	 */
	UnitDef* unitDef = cdef->GetDef();
	const int xsize = (((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;
	const int zsize = (((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;

	const SBlockingMap::SM notIgnore = static_cast<SBlockingMap::SM>(
		isIgnore ? SBlockingMap::StructMask::NONE : SBlockingMap::StructMask::ALL
	);
	auto isOpenSite = [this, notIgnore](const int2& s1, const int2& s2) {
		for (int z = s1.y; z < s2.y; ++z) {
			for (int x = s1.x; x < s2.x; ++x) {
				if (blockingMap.IsBlocked(x, z, notIgnore)) {
					return false;
				}
			}
		}
		return true;
	};

	const int endr = (int)(searchRadius / (SQUARE_SIZE * 2));
	const std::vector<SSearchOffset>& ofs = GetSearchOffsetTable(endr);

	const int cornerX1 = int(pos.x / (SQUARE_SIZE * 2)) - (xsize / 2);
	const int cornerZ1 = int(pos.z / (SQUARE_SIZE * 2)) - (zsize / 2);

	AIFloat3 probePos(ZeroVector);
	CMap* map = circuit->GetMap();

	for (int so = 0; so < endr * endr * 4; so++) {
		int2 s1(cornerX1 + ofs[so].dx, cornerZ1 + ofs[so].dy);
		int2 s2(    s1.x + xsize,          s1.y + zsize);
		if (!blockingMap.IsInBounds(s1, s2) || !isOpenSite(s1, s2)) {
			continue;
		}

		probePos.x = (s1.x + s2.x) * SQUARE_SIZE;
		probePos.z = (s1.y + s2.y) * SQUARE_SIZE;
		if (CanBeBuiltAtSafe(cdef, probePos) && map->IsPossibleToBuildAt(unitDef, probePos, facing)) {
			probePos.y = map->GetElevationAt(probePos.x, probePos.z);
			if (predicate(probePos)) {
				return probePos;
			}
		}
	}

	return -RgtVector;
}

/*
 * Reservations
 */
bool CTerrainManager::ReservationCells(CCircuitDef* cdef, const AIFloat3& pos, int facing, int2& c1, int2& c2) const
{
	const base_layout::Footprint footprint{cdef->GetDef()->GetXSize() / 2, cdef->GetDef()->GetZSize() / 2};
	const base_layout::Point centre{
		int(std::lround(pos.x / base_layout::HALF_CELL_ELMOS)),
		int(std::lround(pos.z / base_layout::HALF_CELL_ELMOS))
	};
	if (!base_layout::IsAligned(centre, footprint, facing)) {
		return false;
	}
	const base_layout::Rect rect = base_layout::RectFromCentre(centre, footprint, facing);
	c1.x = rect.minX;
	c1.y = rect.minZ;
	c2.x = rect.maxX;
	c2.y = rect.maxZ;
	return base_layout::InBounds(rect, blockingMap.columns, blockingMap.rows);
}

bool CTerrainManager::IsReservationFree(const int2& c1, const int2& c2) const
{
	if (IsAllyLayoutRectBlocked(c1, c2)) return false;
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			if (blockingMap.IsBlocked(x, z, all)) {
				return false;
			}
		}
	}
	return true;
}

void CTerrainManager::MarkReservation(const int2& c1, const int2& c2, bool mark)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			if (mark) {
				if (!blockingMap.IsReserved(x, z)) {  // AddStruct twice would drift the low-res counts
					blockingMap.AddStruct(x, z, SBlockingMap::StructType::RESERVED, all);
				}
			} else if (blockingMap.IsReserved(x, z)) {
				blockingMap.DelStruct(x, z, SBlockingMap::StructType::RESERVED, all);
			}
		}
	}
}

int CTerrainManager::ReserveBuilding(CCircuitDef* cdef, const AIFloat3& position, int facing, int ttlFrames, int group)
{
	return ReserveBuildingEx(cdef, position, facing, ttlFrames, group, true, false, false, 0, false);
}

int CTerrainManager::ReserveBuildingEx(CCircuitDef* cdef, const AIFloat3& position, int facing, int ttlFrames, int group,
		bool armed, bool anyReach, bool tenant, int zone, bool quiet, bool exitsPreflighted)
{
	SSlowCall slow("ReserveBuildingEx", circuit);
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return -1;
	}
	if (!layoutEnabled) {
		if (!layoutRefusalLogged) {
			layoutRefusalLogged = true;
			circuit->LOG("RESERVE: refused: layout is off for this AI (behaviour.json layout.enabled, aiTerrainMgr.layoutEnabled)");
		}
		return -1;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	AIFloat3 pos = position;
	CorrectPosition(pos);
	pos = Pos2BuildPos(cdef, pos, facing);
	pos.y = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
	int2 c1, c2;
	if (!ReservationCells(cdef, pos, facing, c1, c2)) {
		circuit->LOG("RESERVE: refused %s at (%.0f, %.0f): off map", cdef->GetDef()->GetName(), pos.x, pos.z);
		return -1;
	}
	if (!CanBeBuiltAt(cdef, pos)) {
		if (!quiet) {
			circuit->LOG("RESERVE: refused %s at (%.0f, %.0f): terrain", cdef->GetDef()->GetName(), pos.x, pos.z);
		}
		return -1;
	}
	// D-116: CanBeBuiltAt is a sector test (the footprint's centre sector is in a
	// usable area); it never sees the footprint's own cells. The engine's test
	// decides at build time, so it decides here too (played on All That Glitters:
	// an advanced lab footprint across a 161-elmo cliff was reserved, then refused
	// by the engine at every order for 15 minutes). A zone band or a tenant slot
	// is laid over our own structures on purpose, so they skip it.
	if ((zone == 0) && !tenant && !IsEngineBuildable(cdef, pos, facing)) {
		if (!quiet) {
			circuit->LOG("RESERVE: refused %s at (%.0f, %.0f) facing %i: the engine refuses the ground (slope, water or a structure)",
					cdef->GetDef()->GetName(), pos.x, pos.z, facing);
		}
		return -1;
	}
	if (zone > 0) {
		const int existing = FindSlotAt(cdef, pos);
		if (existing >= 0) {
			return -2;  // already laid (idempotent bands)
		}
	}
	if (!IsSlotFree(c1, c2, zone, -1)) {
		if (quiet) {
			return -1;
		}
		// Say which cell and what holds it: a mex spot, a map edge, another
		// reservation. The plan can slide the footprint; the log says how far.
		int bx = c1.x, bz = c1.y;
		unsigned blocker = 0, structed = 0;
		for (int z = c1.y; z < c2.y; ++z) {
			for (int x = c1.x; x < c2.x; ++x) {
				const SBlockingMap::SBlockCell& cell = blockingMap.grid[z * blockingMap.columns + x];
				if ((cell.blockerMask != 0) || (static_cast<SBlockingMap::SM>(cell.structMask) != 0)) {
					bx = x; bz = z;
					blocker = cell.blockerMask;
					structed = static_cast<SBlockingMap::SM>(cell.structMask);
					z = c2.y;
					break;
				}
			}
		}
		circuit->LOG("RESERVE: refused %s at (%.0f, %.0f): cell (%i, %i) blocked (blocker 0x%x, struct 0x%x)",
				cdef->GetDef()->GetName(), pos.x, pos.z, bx * (SQUARE_SIZE * 2), bz * (SQUARE_SIZE * 2), blocker, structed);
		return -1;
	}
	// D-099 (played: the first lab reserved at the commander stood in the
	// advanced lab's planned exit): no reservation of the layout in a planned or
	// standing factory's exit lane, whoever asks
	if (!exitsPreflighted && layout_rank::OverlapsAny(layout_rank::CellRect{c1.x, c1.y, c2.x, c2.y}, FactoryExitLanes())) {
		if (!quiet) {
			circuit->LOG("RESERVE: refused %s at (%.0f, %.0f): in a factory's exit lane", cdef->GetDef()->GetName(), pos.x, pos.z);
		}
		return -1;
	}
	MarkReservation(c1, c2, true);
	const int id = nextReservationId++;
	const int frame = circuit->GetLastFrame();
	const int order = (group == 0) ? 0 : GetGroupCount(group, false);
	reservations[id] = SReservation{id, cdef, pos, facing, group, (ttlFrames > 0) ? frame + ttlFrames : 0, false,
			armed, anyReach, tenant, zone, 0, order, false};
	IndexReservation(id);
	ShareSlot(id);
	if (group == 0) {
		circuit->LOG("RESERVE: %s at (%.0f, %.0f) facing %i (id %i)", cdef->GetDef()->GetName(), pos.x, pos.z, facing, id);
	}
	return id;
}

int CTerrainManager::ReserveGrid(CCircuitDef* cdef, const AIFloat3& frontCentre, int facing, int cols, int rows, int gap, int ttlFrames)
{
	return ReserveGridEx(cdef, frontCentre, facing, cols, rows, gap, ttlFrames, true, false, false, 0, 0);
}

int CTerrainManager::ReserveGridEx(CCircuitDef* cdef, const AIFloat3& frontCentre, int facing, int cols, int rows, int gap,
		int ttlFrames, bool armed, bool anyReach, bool tenant, int zone, int groupIn)
{
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr) || (cols <= 0) || (rows <= 0)) {
		return 0;
	}
	if (!layoutEnabled) {
		ReserveBuildingEx(cdef, frontCentre, facing, 0, 0, true, false, false, 0, false);  // logs the refusal once
		return 0;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	UnitDef* unitDef = cdef->GetDef();
	const float cell = SQUARE_SIZE * 2;
	// extent across the facing (w) and along it (d), in elmos
	const float w = ((((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2) * cell;
	const float d = ((((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2) * cell;
	const float g = std::max(0, gap) * cell;
	AIFloat3 fwd, side;
	switch (facing) {
		default:
		case UNIT_FACING_SOUTH: fwd = AIFloat3(0.f, 0.f, 1.f);  side = AIFloat3(1.f, 0.f, 0.f);  break;
		case UNIT_FACING_EAST:  fwd = AIFloat3(1.f, 0.f, 0.f);  side = AIFloat3(0.f, 0.f, -1.f); break;
		case UNIT_FACING_NORTH: fwd = AIFloat3(0.f, 0.f, -1.f); side = AIFloat3(-1.f, 0.f, 0.f); break;
		case UNIT_FACING_WEST:  fwd = AIFloat3(-1.f, 0.f, 0.f); side = AIFloat3(0.f, 0.f, 1.f);  break;
	}
	const int group = (groupIn > 0) ? groupIn : nextGroupId++;
	const bool quiet = (zone > 0);  // a band is laid again and again; a refused slot is a hole, not news
	int placed = 0, existing = 0;
	for (int r = 0; r < rows; ++r) {
		const float back = r * (d + g) + d * 0.5f;  // centre of row r, behind the front line
		for (int c = 0; c < cols; ++c) {
			const float lat = (c - (cols - 1) * 0.5f) * (w + g);
			const AIFloat3 p = frontCentre - fwd * back + side * lat;
			const int id = ReserveBuildingEx(cdef, p, facing, ttlFrames, group, armed, anyReach, tenant, zone, quiet);
			if (id >= 0) {
				++placed;
			} else if (id == -2) {
				++existing;
			}
		}
	}
	if ((placed > 0) || (zone == 0)) {
		circuit->LOG("RESERVE: grid of %s %ix%i gap %i behind (%.0f, %.0f) facing %i: %i of %i slots%s (group %i%s%s%s)",
				unitDef->GetName(), cols, rows, gap, frontCentre.x, frontCentre.z, facing, placed, cols * rows,
				(existing > 0) ? " new" : "", group, armed ? "" : ", held", tenant ? ", tenant" : "", (zone > 0) ? ", zone" : "");
	}
	return ((placed > 0) || (groupIn > 0)) ? group : 0;
}

bool CTerrainManager::CanReserveNanoBlockAt(CCircuitDef* nanoDef, CCircuitDef* facDef,
        const AIFloat3& facPos, int facing, int cols, int rows, int gap)
{
    // Pure preflight for CrampedLabSite: simulate the future factory footprint
    // and the support band's insertion order without allocating IDs, changing
    // allied reservations or dirtying the blocker grids. Final commit keeps its
    // existing checks. O(rows*columns*footprint + existing exit lanes).
    if (!layoutEnabled || !nanoDef || !facDef || !nanoDef->GetDef() || !facDef->GetDef()
        || cols <= 0 || rows <= 0) return false;
    if (facing < 0 || facing > 3) facing = UNIT_FACING_SOUTH;
    UnitDef* factory = facDef->GetDef();
    UnitDef* turret = nanoDef->GetDef();
    const float cell = SQUARE_SIZE * 2;
    const float depth = (((facing & 1) ? factory->GetXSize() : factory->GetZSize()) / 2) * cell;
    const float width = (((facing & 1) ? turret->GetZSize() : turret->GetXSize()) / 2) * cell;
    const float length = (((facing & 1) ? turret->GetXSize() : turret->GetZSize()) / 2) * cell;
    const float spacing = std::max(0, gap) * cell;
    const AIFloat3 forwards[] = {{0,0,1},{1,0,0},{0,0,-1},{-1,0,0}};
    const AIFloat3 sides[] = {{1,0,0},{0,0,-1},{-1,0,0},{0,0,1}};
    const AIFloat3 front = facPos - forwards[facing] * (depth * .5f);
    const float blockWidth = cols * width + (cols - 1) * spacing;
    const float blockDepth = rows * length + (rows - 1) * spacing;
    AIFloat3 factoryPosition = facPos;
    CorrectPosition(factoryPosition);
    factoryPosition = Pos2BuildPos(facDef, factoryPosition, facing);
    int2 zoneFirst, zoneLast, factoryFirst, factoryLast;
    if (!RectCells(front - forwards[facing] * (blockDepth * .5f), facing,
            blockWidth * .5f, blockDepth * .5f, zoneFirst, zoneLast)
        || IsAllyLayoutRectBlocked(zoneFirst, zoneLast)
        || !ReservationCells(facDef, factoryPosition, facing, factoryFirst, factoryLast)) return false;
    std::vector<layout_rank::CellRect> occupied{{factoryFirst.x,factoryFirst.y,factoryLast.x,factoryLast.y}};
    auto exits = FactoryExitLanes();
    int2 exitFirst, exitLast;
    if (!facDef->IsMobile() && facDef->IsBuilder()
        && ExitLaneCells(facDef, factoryPosition, facing,
            EXIT_CLEAR_LENGTH, EXIT_CLEAR_MARGIN, exitFirst, exitLast))
        exits.push_back({exitFirst.x,exitFirst.y,exitLast.x,exitLast.y});
    const auto all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
    bool heldCell = false;
    for (int z=zoneFirst.y; z<zoneLast.y && !heldCell; ++z)
        for (int x=zoneFirst.x; x<zoneLast.x; ++x)
            if (!blockingMap.IsBlocked(x,z,all)
                && !(x>=factoryFirst.x && x<factoryLast.x && z>=factoryFirst.y && z<factoryLast.y)) {
                heldCell=true; break;
            }
    if (!heldCell) return false;
    bool reachable = false;
    for (int row=0; row<rows; ++row) for (int column=0; column<cols; ++column) {
        const float back = row*(length+spacing)+length*.5f;
        const float lateral = (column-(cols-1)*.5f)*(width+spacing);
        AIFloat3 point = front-forwards[facing]*back+sides[facing]*lateral;
        CorrectPosition(point);
        point=Pos2BuildPos(nanoDef,point,facing);
        int2 first,last;
        if (!ReservationCells(nanoDef,point,facing,first,last) || !CanBeBuiltAt(nanoDef,point)
            || FindSlotAt(nanoDef,point)>=0 || IsAllyLayoutRectBlocked(first,last)) continue;
        const layout_rank::CellRect rectangle{first.x,first.y,last.x,last.y};
        if (layout_rank::OverlapsAny(rectangle,occupied) || layout_rank::OverlapsAny(rectangle,exits)
            || localReservations.OverlapsSlot({first.x,first.y,last.x,last.y})) continue;
        bool free = true;
        for (int z=first.y; z<last.y && free; ++z) for (int x=first.x; x<last.x; ++x)
            if (blockingMap.IsResourceSite(x,z) || blockingMap.IsBlocked(x,z,all)) { free=false; break; }
        // ReserveZone claims only initially free cells. Existing blocked cells
        // never become owned by the hypothetical zone, including another zone.
        if (!free) continue;
        occupied.push_back(rectangle);
        if (point.SqDistance2D(facPos)<=SQUARE(nanoDef->GetBuildDistance())) reachable=true;
    }
    return reachable;
}

int CTerrainManager::ReserveNanoBlockAt(CCircuitDef* nanoDef, CCircuitDef* facDef, const AIFloat3& facPos, int facing, int cols, int rows, int gap)
{
	if ((nanoDef == nullptr) || (facDef == nullptr) || (facDef->GetDef() == nullptr)) {
		return 0;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	UnitDef* unitDef = facDef->GetDef();
	const float depth = ((((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2) * (SQUARE_SIZE * 2);
	AIFloat3 fwd;
	switch (facing) {
		default:
		case UNIT_FACING_SOUTH: fwd = AIFloat3(0.f, 0.f, 1.f);  break;
		case UNIT_FACING_EAST:  fwd = AIFloat3(1.f, 0.f, 0.f);  break;
		case UNIT_FACING_NORTH: fwd = AIFloat3(0.f, 0.f, -1.f); break;
		case UNIT_FACING_WEST:  fwd = AIFloat3(-1.f, 0.f, 0.f); break;
	}
	const AIFloat3 frontCentre = facPos - fwd * (depth * 0.5f);  // the factory's back edge
	// The block is laid in a zone of its own, not as plain slots: a plain slot
	// refuses the cells of the factory's own yard, and the Cortex and Legion
	// labs (block class fac_bot_pass) have a yard behind them - every plain
	// block behind one was refused ("blocked (blocker 0x1)"). A zone slot
	// tolerates the yard; the engine's own test still decides buildability.
	if (!layoutEnabled) {
		return ReserveGrid(nanoDef, frontCentre, facing, cols, rows, gap, 0);  // logs the refusal once
	}
	UnitDef* nanoUd = nanoDef->GetDef();
	if (nanoUd == nullptr) {
		return 0;
	}
	const float cell = SQUARE_SIZE * 2;
	const float w = ((((facing & 1) == 0) ? nanoUd->GetXSize() : nanoUd->GetZSize()) / 2) * cell;
	const float d = ((((facing & 1) == 1) ? nanoUd->GetXSize() : nanoUd->GetZSize()) / 2) * cell;
	const float g = std::max(0, gap) * cell;
	const float blockW = cols * w + (cols - 1) * g;
	const float blockD = rows * d + (rows - 1) * g;
	const int zone = ReserveZone(frontCentre - fwd * (blockD * 0.5f), facing, blockW * 0.5f, blockD * 0.5f, false);
	if (zone == 0) {
		return 0;
	}
	const int group = LayBand(zone, nanoDef, frontCentre, facing, cols, rows, gap, true, false, false, 0);
	if (group <= 0 || GetGroupCount(group, false) == 0) {
		// A failed support probe must not leave an empty zone blocking the next
		// candidate. Successful groups retain their zone for future construction.
		if (group > 0) ReleaseGroup(group);
		ReleaseZone(zone);
		return 0;
	}
	return group;
}


void CTerrainManager::IndexLocalSlot(int id)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
    const auto it = reservations.find(id);
    int2 a, b;
    if (it == reservations.end() || it->second.consumed
            || !ReservationCells(it->second.def, it->second.pos, it->second.facing, a, b)) {
        localReservations.EraseSlot(id);
        return;
    }
    localReservations.PutSlot(id, {a.x, a.y, b.x, b.y});
}

void CTerrainManager::ShareSlot(int id)
{
    IndexLocalSlot(id);
    const auto it = reservations.find(id);
    if (it == reservations.end()) return;
    int2 a, b;
    const auto& r = it->second;
    if (ReservationCells(r.def, r.pos, r.facing, a, b)) {
        if (IsAllyLayoutRectBlocked(a, b)) circuit->LOG("[INVARIANT] INV-088: reservation %i overlaps an allied plan", id);
        circuit->GetAllyTeam()->GetLayoutReservations().Put(circuit->GetTeamId(), allied_layout::Reservations::SLOT,
            id, {a.x, a.y, b.x, b.y});
    }
}

void CTerrainManager::ShareZone(int id)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
    const auto it = zones.find(id);
    if (it == zones.end()) return;
    const auto& z = it->second;
    localReservations.PutZone(id, {z.c1.x, z.c1.y, z.c2.x, z.c2.y});
    if (IsAllyLayoutRectBlocked(z.c1, z.c2)) circuit->LOG("[INVARIANT] INV-088: zone %i overlaps an allied plan", id);
    circuit->GetAllyTeam()->GetLayoutReservations().Put(circuit->GetTeamId(), allied_layout::Reservations::ZONE,
        id, {z.c1.x, z.c1.y, z.c2.x, z.c2.y});
}

bool CTerrainManager::IsAllyLayoutRectBlocked(const int2& c1, const int2& c2) const
{
    return circuit->GetAllyTeam() != nullptr && circuit->GetAllyTeam()->GetLayoutReservations().OverlapsOther(
        circuit->GetTeamId(), {c1.x, c1.y, c2.x, c2.y});
}

bool CTerrainManager::IsAllyLayoutBlocked(CCircuitDef* cdef, const AIFloat3& pos, int facing) const
{
    int2 a, b;
    if (cdef == nullptr || cdef->IsMobile()) return false;
    if (facing < 0 || facing > 3) facing = UNIT_FACING_SOUTH;
    // Zone rectangles enclose holes. A genuine resource building wholly on its
    // matching immutable site may use that cutout; no other footprint may.
    // Metal maps have no MEX site markers, so their dense field reservations
    // continue to respect allied cluster ownership exactly as before.
    if (IsResourceBuildingSite(cdef, pos, facing)) return false;
    return ReservationCells(cdef, Pos2BuildPos(cdef, pos, facing), facing, a, b) && IsAllyLayoutRectBlocked(a, b);
}

bool CTerrainManager::IsReservationBuildable(int id) const
{
    const auto it = reservations.find(id);
    if (it == reservations.end()) return false;
    const auto& r = it->second;
    return !r.consumed && !r.claimed && r.unitId == 0 && !IsSlotDead(id)
        && !IsAllyLayoutBlocked(r.def, r.pos, r.facing) && IsEngineBuildable(r.def, r.pos, r.facing);
}

bool CTerrainManager::CanReserveArea(const AIFloat3& centre, int facing, float halfAcross, float halfAlong) const
{
    int2 a, b;
    const float hx = ((facing & 1) == 0) ? halfAcross : halfAlong;
    const float hz = ((facing & 1) == 0) ? halfAlong : halfAcross;
    return layoutEnabled && halfAcross > 0.f && halfAlong > 0.f
        && centre.x >= hx && centre.z >= hz && centre.x + hx <= GetTerrainWidth() && centre.z + hz <= GetTerrainHeight()
        && RectCells(centre, facing, halfAcross, halfAlong, a, b)
        && IsRectFree(base_layout::Rect{a.x, a.y, b.x, b.y});
}

int CTerrainManager::GetGroupActivationState(int group) const
{
    bool found = false, blocked = false;
    if (group <= 0) return -1;
    for (const auto& entry : reservations) {
        const auto& r = entry.second;
        if (r.group != group) continue;
        found = true;
        if (r.claimed || r.consumed || r.unitId != 0) return 2;
        if (!IsReservationBuildable(r.id)) blocked = true;
    }
    return !found ? -1 : blocked ? 1 : 0;
}

int CTerrainManager::GetZoneActivationState(int zone) const
{
    if (zones.find(zone) == zones.end()) return -1;
    bool blocked = false;
    for (const auto& entry : reservations) {
        const auto& r = entry.second;
        if (r.zone != zone) continue;
        if (r.claimed || r.consumed || r.unitId != 0) return 2;
        if (!IsReservationBuildable(r.id)) blocked = true;
    }
    return blocked ? 1 : 0;
}

int CTerrainManager::GetGroupZone(int group) const
{
    for (const auto& r : reservations) if (group > 0 && r.second.group == group) return r.second.zone;
    return 0;
}

int CTerrainManager::ReserveClusterEnvelope(int slot, int group)
{
    int2 low(blockingMap.columns, blockingMap.rows), high(0, 0);
    for (const auto& entry : reservations) {
        const auto& r = entry.second;
        if (r.id != slot && (group <= 0 || r.group != group)) continue;
        int2 a, b;
        if (!ReservationCells(r.def, r.pos, r.facing, a, b)) continue;
        low.x = std::min(low.x, a.x); low.y = std::min(low.y, a.y);
        high.x = std::max(high.x, b.x); high.y = std::max(high.y, b.y);
    }
    if (low.x >= high.x || low.y >= high.y) return 0;
    return ReserveZone(AIFloat3((low.x + high.x) * SQUARE_SIZE, 0.f, (low.y + high.y) * SQUARE_SIZE),
        0, (high.x - low.x) * SQUARE_SIZE, (high.y - low.y) * SQUARE_SIZE, false);
}

bool CTerrainManager::CanReserveBuilding(CCircuitDef* cdef, const AIFloat3& position, int facing)
{
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return false;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	AIFloat3 pos = position;
	CorrectPosition(pos);
	pos = Pos2BuildPos(cdef, pos, facing);
	int2 c1, c2;
	return layoutEnabled && ReservationCells(cdef, pos, facing, c1, c2) && CanBeBuiltAt(cdef, pos) && IsSlotFree(c1, c2, 0, -1)
			&& !layout_rank::OverlapsAny(layout_rank::CellRect{c1.x, c1.y, c2.x, c2.y}, FactoryExitLanes())  // D-099
			&& IsEngineBuildable(cdef, pos, facing);  // D-116: last, the one engine call
}

bool CTerrainManager::IsEngineBuildable(CCircuitDef* cdef, const AIFloat3& buildPos, int facing) const
{
	// The engine's own build test: false for ground it will not build on (slope
	// past the def's maxHeightDif, water or land the def cannot stand on, a
	// structure); units standing there and reclaimable features pass (the
	// builder moves them / reclaims them first)
	return !IsResourceFootprintBlocked(cdef, buildPos, facing)
		&& circuit->GetMap()->IsPossibleToBuildAt(cdef->GetDef(), buildPos, facing);
}

bool CTerrainManager::IsResourceAreaBlocked(const AIFloat3& centre, int facing, float halfAcross, float halfAlong) const
{
	int2 a, b;
	if (!RectCells(centre, facing, halfAcross, halfAlong, a, b)) return true;
	for (int z = a.y; z < b.y; ++z) for (int x = a.x; x < b.x; ++x) {
		if (blockingMap.IsResourceSite(x, z)) return true;
	}
	return false;
}

bool CTerrainManager::IsResourceFootprintBlocked(CCircuitDef* cdef, const AIFloat3& pos, int facing) const
{
	if (cdef == nullptr || cdef->IsMobile()) return false;
	// Resource buildings retain their normal site/upgrade path; first-factory
	// placement exceptions may ignore layouts, but never steal resource ground.
	SBlockingMap::SM mask = STRUCT_BIT(ALL);
	if (cdef->GetExtractsM() > 0.f) mask &= ~STRUCT_BIT(MEX);
	if (cdef->GetDef()->IsNeedGeo()) mask &= ~STRUCT_BIT(GEO);
	int2 a, b;
	if (!ReservationCells(cdef, Pos2BuildPos(cdef, pos, facing), facing, a, b)) return true;
	for (int z = a.y; z < b.y; ++z) for (int x = a.x; x < b.x; ++x) {
		if (blockingMap.IsResourceSite(x, z, mask)) return true;
	}
	return false;
}

bool CTerrainManager::IsResourceBuildingSite(CCircuitDef* cdef, const AIFloat3& pos, int facing) const
{
	if (cdef == nullptr || cdef->IsMobile()) return false;
	const auto mask = cdef->GetExtractsM() > 0.f ? STRUCT_BIT(MEX)
		: cdef->GetDef()->IsNeedGeo() ? STRUCT_BIT(GEO) : STRUCT_BIT(NONE);
	if (mask == STRUCT_BIT(NONE)) return false;
	int2 a, b;
	if (!ReservationCells(cdef, Pos2BuildPos(cdef, pos, facing), facing, a, b)) return false;
	for (int z = a.y; z < b.y; ++z) for (int x = a.x; x < b.x; ++x) {
		if (!blockingMap.IsResourceSite(x, z, mask)) return false;
	}
	return true;
}

float CTerrainManager::BuildableFraction(CCircuitDef* cdef, const AIFloat3& centre, float halfAcross, float halfAlong, int facing)
{
	SSlowCall slow("BuildableFraction", circuit);
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return 0.f;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	AIFloat3 fwd, side;
	switch (facing) {
		default:
		case UNIT_FACING_SOUTH: fwd = AIFloat3(0.f, 0.f, 1.f);  side = AIFloat3(1.f, 0.f, 0.f);  break;
		case UNIT_FACING_EAST:  fwd = AIFloat3(1.f, 0.f, 0.f);  side = AIFloat3(0.f, 0.f, -1.f); break;
		case UNIT_FACING_NORTH: fwd = AIFloat3(0.f, 0.f, -1.f); side = AIFloat3(-1.f, 0.f, 0.f); break;
		case UNIT_FACING_WEST:  fwd = AIFloat3(-1.f, 0.f, 0.f); side = AIFloat3(0.f, 0.f, 1.f);  break;
	}
	CMap* map = circuit->GetMap();
	UnitDef* unitDef = cdef->GetDef();
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	const float step = SQUARE_SIZE * 4;
	int total = 0, ok = 0;
	for (float a = -halfAlong; a <= halfAlong; a += step) {
		for (float s = -halfAcross; s <= halfAcross; s += step) {
			++total;
			const AIFloat3 p = centre + fwd * a + side * s;
			if ((p.x < 0.f) || (p.z < 0.f) || (p.x >= GetTerrainWidth()) || (p.z >= GetTerrainHeight())) {
				continue;  // off the map counts against the site
			}
			const int x = int(p.x) / (SQUARE_SIZE * 2);
			const int z = int(p.z) / (SQUARE_SIZE * 2);
			if (!blockingMap.IsInBounds(x, z) || blockingMap.IsBlocked(x, z, all)) {
				continue;
			}
			if (!CanBeBuiltAt(cdef, p) || !map->IsPossibleToBuildAt(unitDef, p, facing)) {
				continue;
			}
			++ok;
		}
	}
	return (total > 0) ? float(ok) / float(total) : 0.f;
}

bool CTerrainManager::SetLayoutEnabled(bool enabled)
{
	++packingRevision;
	if (enabled && !layoutConfigured) {
		if (!layoutRefusalLogged) {
			layoutRefusalLogged = true;
			circuit->LOG("RESERVE: layout opt-in refused: behaviour.json layout.enabled is false");
		}
		layoutEnabled = false;
		return false;
	}
	layoutEnabled = enabled;
	return layoutEnabled;
}

bool CTerrainManager::IsRectFree(const base_layout::Rect& rect) const
{
	if (IsAllyLayoutRectBlocked(int2(rect.minX, rect.minZ), int2(rect.maxX, rect.maxZ))) return false;
	if (!base_layout::InBounds(rect, blockingMap.columns, blockingMap.rows)) {
		return false;
	}
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = rect.minZ; z < rect.maxZ; ++z) {
		for (int x = rect.minX; x < rect.maxX; ++x) {
			if (blockingMap.IsBlocked(x, z, all)) {
				return false;
			}
		}
	}
	return true;
}

int CTerrainManager::ReserveExactZone(const std::string& name, const base_layout::Rect& rect, bool corridor)
{
	const auto found = layoutZones.find(name);
	if (found != layoutZones.end()) {
		return found->second;
	}
	if (!layoutEnabled || !IsRectFree(rect)) {
		return 0;
	}
	if (zoneMap.size() != blockingMap.grid.size()) {
		zoneMap.assign(blockingMap.grid.size(), 0);
	}
	const int id = nextZoneId++;
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = rect.minZ; z < rect.maxZ; ++z) {
		for (int x = rect.minX; x < rect.maxX; ++x) {
			blockingMap.AddReservationUnderlay(x, z, all);
			zoneMap[z * blockingMap.columns + x] = id;
		}
	}
	zones[id] = SZone{id, int2(rect.minX, rect.minZ), int2(rect.maxX, rect.maxZ), corridor,
			rect.Width() * rect.Depth()};
	ShareZone(id);
	layoutZones[name] = id;
	return id;
}

int CTerrainManager::EnsureLayoutGroup(const std::string& name)
{
	const auto found = layoutGroups.find(name);
	if (found != layoutGroups.end()) {
		return found->second;
	}
	const int id = nextGroupId++;
	layoutGroups[name] = id;
	return id;
}

int CTerrainManager::GetLayoutGroupId(const std::string& name) const
{
	const auto found = layoutGroups.find(name);
	return (found == layoutGroups.end()) ? 0 : found->second;
}

bool CTerrainManager::HasLayoutGroup(const std::string& name) const
{
	return GetLayoutGroupId(name) > 0;
}

int CTerrainManager::GetLayoutGroupTotal(const std::string& name) const
{
	const int group = GetLayoutGroupId(name);
	return (group == 0) ? 0 : GetGroupCount(group, false);
}

int CTerrainManager::GetLayoutGroupBuilt(const std::string& name) const
{
	const int group = GetLayoutGroupId(name);
	if (group == 0) {
		return 0;
	}
	int count = 0;
	for (const auto& kv : reservations) {
		if ((kv.second.group == group) && (kv.second.unitId != 0)) {
			CCircuitUnit* unit = circuit->GetTeamUnit(kv.second.unitId);
			if ((unit != nullptr) && !unit->GetUnit()->IsBeingBuilt()) {
				++count;
			}
		}
	}
	return count;
}

int CTerrainManager::GetLayoutGroupStarted(const std::string& name) const
{
	const int group = GetLayoutGroupId(name);
	if (group == 0) {
		return 0;
	}
	int count = 0;
	for (const auto& kv : reservations) {
		if ((kv.second.group == group) && (kv.second.claimed || kv.second.consumed)) {
			++count;
		}
	}
	return count;
}

int CTerrainManager::GetLayoutGroupAvailable(const std::string& name) const
{
	const int group = GetLayoutGroupId(name);
	if (group == 0) {
		return 0;
	}
	int count = 0;
	for (const auto& kv : reservations) {
		if ((kv.second.group == group) && !kv.second.claimed && !kv.second.consumed) {
			++count;
		}
	}
	return count;
}

int CTerrainManager::GetLayoutInt(const std::string& name, int fallback) const
{
	const auto found = layoutInts.find(name);
	return (found == layoutInts.end()) ? fallback : found->second;
}

AIFloat3 CTerrainManager::GetLayoutGroupCenter(const std::string& name) const
{
	const int group = GetLayoutGroupId(name);
	if (group == 0) {
		return AIFloat3(-RgtVector);
	}
	AIFloat3 center(ZeroVector);
	int count = 0;
	for (const auto& kv : reservations) {
		if (kv.second.group == group) {
			center += kv.second.pos;
			++count;
		}
	}
	return (count > 0) ? center / float(count) : AIFloat3(-RgtVector);
}

int CTerrainManager::GetNextLayoutSlot(const std::string& name, CCircuitUnit* builder, CCircuitDef* buildDef)
{
	const int group = GetLayoutGroupId(name);
	return GetNextLayoutSlot(group, builder, buildDef);
}

int CTerrainManager::GetNextLayoutSlot(int group, CCircuitUnit* builder, CCircuitDef* buildDef)
{
	if ((group == 0) || (builder == nullptr) || (buildDef == nullptr)) {
		return -1;
	}
	int best = -1;
	int bestOrder = std::numeric_limits<int>::max();
	for (const auto& kv : reservations) {
		const SReservation& reservation = kv.second;
		if ((reservation.group != group) || (reservation.def != buildDef)
				|| reservation.claimed || reservation.consumed) {
			continue;
		}
		if (!CanReachAtSafe(builder, reservation.pos, builder->GetCircuitDef()->GetBuildDistance())) {
			continue;
		}
		if ((reservation.order < bestOrder) || ((reservation.order == bestOrder) && (reservation.id < best))) {
			best = reservation.id;
			bestOrder = reservation.order;
		}
	}
	return best;
}

std::vector<int> CTerrainManager::GetCompletedFactoryNanoGroups() const
{
	std::vector<int> groups;
	for (const auto& named : layoutGroups) {
		static constexpr std::string_view suffix = ".factory";
		if ((named.first.size() <= suffix.size())
				|| (named.first.compare(named.first.size() - suffix.size(), suffix.size(), suffix) != 0)) {
			continue;
		}
		bool complete = false;
		for (const auto& kv : reservations) {
			const SReservation& reservation = kv.second;
			if ((reservation.group != named.second) || (reservation.unitId == 0)) {
				continue;
			}
			CCircuitUnit* factory = circuit->GetTeamUnit(reservation.unitId);
			complete = (factory != nullptr) && !factory->GetUnit()->IsBeingBuilt();
			break;
		}
		if (!complete) {
			continue;
		}
		const std::string nanoName = named.first.substr(0, named.first.size() - suffix.size()) + ".nano";
		const int group = GetLayoutGroupId(nanoName);
		if ((group > 0) && (std::find(groups.begin(), groups.end(), group) == groups.end())) {
			groups.push_back(group);
		}
	}
	return groups;
}

int CTerrainManager::GetFactoryNanoAvailable() const
{
	int count = 0;
	for (int group : GetCompletedFactoryNanoGroups()) {
		for (const auto& kv : reservations) {
			const SReservation& reservation = kv.second;
			if ((reservation.group == group) && !reservation.claimed && !reservation.consumed) {
				++count;
			}
		}
	}
	return count;
}

int CTerrainManager::GetFactoryNanoActive() const
{
	int started = 0;
	int built = 0;
	for (int group : GetCompletedFactoryNanoGroups()) {
		for (const auto& kv : reservations) {
			const SReservation& reservation = kv.second;
			if (reservation.group != group) {
				continue;
			}
			if (reservation.claimed || reservation.consumed) {
				++started;
			}
			if (reservation.unitId != 0) {
				CCircuitUnit* unit = circuit->GetTeamUnit(reservation.unitId);
				if ((unit != nullptr) && !unit->GetUnit()->IsBeingBuilt()) {
					++built;
				}
			}
		}
	}
	return started - built;
}

bool CTerrainManager::PinLayoutTask(IBuilderTask* task, const std::string& groupName, CCircuitUnit* builder)
{
	if (!layoutEnabled || (task == nullptr) || (builder == nullptr)) {
		return false;
	}
	const int id = GetNextLayoutSlot(groupName, builder, task->GetBuildDef());
	return (id >= 0) && task->PinReservation(id);
}

bool CTerrainManager::PinFactoryNanoTask(IBuilderTask* task, CCircuitUnit* builder)
{
	if (!layoutEnabled || (task == nullptr) || (builder == nullptr)) {
		return false;
	}
	int best = -1;
	int bestOrder = std::numeric_limits<int>::max();
	for (int group : GetCompletedFactoryNanoGroups()) {
		const int id = GetNextLayoutSlot(group, builder, task->GetBuildDef());
		if (id < 0) {
			continue;
		}
		const SReservation& reservation = reservations.at(id);
		if ((reservation.order < bestOrder) || ((reservation.order == bestOrder) && (id < best))) {
			best = id;
			bestOrder = reservation.order;
		}
	}
	return (best >= 0) && task->PinReservation(best);
}

bool CTerrainManager::CanReserveFactoryCluster(const base_layout::FactoryCluster& cluster,
		CCircuitDef* factoryDef, CCircuitDef* nanoDef)
{
	if (!cluster.valid || (factoryDef == nullptr) || (nanoDef == nullptr)) {
		return false;
	}
	const base_layout::Rect factoryRect = base_layout::RectFromCentre(
			cluster.factory.centre, cluster.factory.footprint, cluster.factory.facing);
	if (!IsRectFree(factoryRect) || !IsRectFree(cluster.nanoBounds) || !IsRectFree(cluster.exit)) {
		return false;
	}
	CMap* map = circuit->GetMap();
	const auto canBuild = [this, map](CCircuitDef* def, const base_layout::Slot& slot) {
		const AIFloat3 pos(slot.centre.x2 * base_layout::HALF_CELL_ELMOS, 0.f,
				slot.centre.z2 * base_layout::HALF_CELL_ELMOS);
		return CanBeBuiltAt(def, pos) && map->IsPossibleToBuildAt(def->GetDef(), pos, slot.facing);
	};
	if (!canBuild(factoryDef, cluster.factory)) {
		return false;
	}
	for (const base_layout::Slot& slot : cluster.nanos) {
		if (!canBuild(nanoDef, slot)) {
			return false;
		}
	}
	return true;
}

void CTerrainManager::ReleaseLayoutPrefix(const std::string& prefix)
{
	std::vector<int> groupIds;
	for (auto it = layoutGroups.begin(); it != layoutGroups.end();) {
		if (it->first.rfind(prefix, 0) == 0) {
			groupIds.push_back(it->second);
			it = layoutGroups.erase(it);
		} else {
			++it;
		}
	}
	for (int group : groupIds) {
		ReleaseGroup(group);
	}
	std::vector<int> zoneIds;
	for (auto it = layoutZones.begin(); it != layoutZones.end();) {
		if (it->first.rfind(prefix, 0) == 0) {
			zoneIds.push_back(it->second);
			it = layoutZones.erase(it);
		} else {
			++it;
		}
	}
	for (int zone : zoneIds) {
		ReleaseZone(zone);
	}
	for (auto it = layoutInts.begin(); it != layoutInts.end();) {
		if (it->first.rfind(prefix, 0) == 0) {
			it = layoutInts.erase(it);
		} else {
			++it;
		}
	}
}

bool CTerrainManager::ReserveFactoryCluster(const std::string& name, const base_layout::FactoryCluster& cluster,
		CCircuitDef* factoryDef, CCircuitDef* nanoDef, int& factoryReservation)
{
	factoryReservation = -1;
	if (!CanReserveFactoryCluster(cluster, factoryDef, nanoDef)) {
		return false;
	}
	const base_layout::Rect factoryRect = base_layout::RectFromCentre(
			cluster.factory.centre, cluster.factory.footprint, cluster.factory.facing);
	const int factoryZone = ReserveExactZone(name + ".factory.zone", factoryRect, false);
	const int nanoZone = ReserveExactZone(name + ".nano.zone", cluster.nanoBounds, false);
	const int exitZone = ReserveExactZone(name + ".exit", cluster.exit, true);
	if ((factoryZone == 0) || (nanoZone == 0) || (exitZone == 0)) {
		ReleaseLayoutPrefix(name);
		return false;
	}
	const int factoryGroup = EnsureLayoutGroup(name + ".factory");
	const int nanoGroup = EnsureLayoutGroup(name + ".nano");
	const AIFloat3 factoryPos(cluster.factory.centre.x2 * base_layout::HALF_CELL_ELMOS, 0.f,
			cluster.factory.centre.z2 * base_layout::HALF_CELL_ELMOS);
	factoryReservation = ReserveBuildingEx(factoryDef, factoryPos, cluster.factory.facing, 0,
			factoryGroup, false, false, false, factoryZone, true);
	if (factoryReservation < 0) {
		ReleaseLayoutPrefix(name);
		return false;
	}
	reservations[factoryReservation].order = 0;
	for (const base_layout::Slot& slot : cluster.nanos) {
		const AIFloat3 pos(slot.centre.x2 * base_layout::HALF_CELL_ELMOS, 0.f,
				slot.centre.z2 * base_layout::HALF_CELL_ELMOS);
		const int id = ReserveBuildingEx(nanoDef, pos, slot.facing, 0, nanoGroup,
				false, false, false, nanoZone, true);
		if (id < 0) {
			ReleaseLayoutPrefix(name);
			factoryReservation = -1;
			return false;
		}
		reservations[id].order = slot.order;
	}
	layoutInts[name + ".factory_slot"] = factoryReservation;
	layoutInts[name + ".exit_zone"] = exitZone;
	return true;
}

bool CTerrainManager::PlanFactoryPair(const std::string& name, CCircuitDef* firstFactory, CCircuitDef* secondFactory,
		CCircuitDef* nanoDef, const AIFloat3& base, int facing, int sideOffsetCells, int forwardOffsetCells)
{
	if (!layoutEnabled || (firstFactory == nullptr) || (secondFactory == nullptr) || (nanoDef == nullptr)
			|| (firstFactory->GetDef() == nullptr) || (secondFactory->GetDef() == nullptr)
			|| (nanoDef->GetDef() == nullptr) || !base_layout::IsFacingValid(facing)) {
		return false;
	}
	if (HasLayoutGroup(name + ".t1.factory") && HasLayoutGroup(name + ".t2.factory")) {
		return true;
	}
	const base_layout::Footprint firstFp{firstFactory->GetDef()->GetXSize() / 2, firstFactory->GetDef()->GetZSize() / 2};
	const base_layout::Footprint secondFp{secondFactory->GetDef()->GetXSize() / 2, secondFactory->GetDef()->GetZSize() / 2};
	const base_layout::Footprint nanoFp{nanoDef->GetDef()->GetXSize() / 2, nanoDef->GetDef()->GetZSize() / 2};
	base_layout::Point rear{
		int(std::lround(base.x / base_layout::HALF_CELL_ELMOS)),
		int(std::lround(base.z / base_layout::HALF_CELL_ELMOS))
	};
	rear = base_layout::Offset(rear, facing, 2 * forwardOffsetCells, 2 * sideOffsetCells);
	const base_layout::FactoryPair pair = base_layout::MakeFactoryPair(
			rear, facing, firstFp, base_layout::FactoryTier::T1,
			secondFp, base_layout::FactoryTier::T2, nanoFp,
			base_layout::FACTORY_EXIT_MARGIN * 2);
	if (!pair.valid
			|| !CanReserveFactoryCluster(pair.first, firstFactory, nanoDef)
			|| !CanReserveFactoryCluster(pair.second, secondFactory, nanoDef)) {
		return false;
	}
	int firstId = -1;
	int secondId = -1;
	if (!ReserveFactoryCluster(name + ".t1", pair.first, firstFactory, nanoDef, firstId)
			|| !ReserveFactoryCluster(name + ".t2", pair.second, secondFactory, nanoDef, secondId)) {
		ReleaseLayoutPrefix(name);
		return false;
	}
	factoryLineReady = true;
	factoryLineFacing = facing;
	factoryRearCentre = pair.rearEdgeCentre;
	factoryLineLeft2 = pair.sideMin2;
	factoryLineRight2 = pair.sideMax2;
	layoutNanoDefId = nanoDef->GetId();
	nextFactoryCluster = 1;
	layoutInts[name + ".facing"] = facing;
	layoutInts[name + ".t1_slot"] = firstId;
	layoutInts[name + ".t2_slot"] = secondId;
	circuit->LOG("RESERVE: factory pair '%s' committed atomically facing %i", name.c_str(), facing);
	return true;
}

bool CTerrainManager::PlanMexCluster(const std::string& name, CCircuitDef* def,
        const AIFloat3& origin, int facing, int cols, int rows)
{
    auto* economy = circuit->GetEconomyManager();
    if (!layoutEnabled || !economy->IsMetalMap() || name.empty() || def == nullptr
        || def->GetExtractsM() <= 0 || !geom::is_valid(origin)
        || !base_layout::IsFacingValid(facing) || cols < 1 || rows < 1 || cols > 8 || rows > 8) return false;
    const base_layout::Footprint fp{def->GetDef()->GetXSize() / 2, def->GetDef()->GetZSize() / 2};
    // Dense without overlapping extraction circles; rounding follows the same
    // build lattice as factories and economy modules. Policy chooses membership.
    const int pitch = int(std::ceil(def->GetExtrRangeM() * 2.f / BUILD_SQUARE_SIZE));
    const int gap = std::max(0, pitch - std::min(fp.x, fp.z));
    base_layout::Point anchor{int(std::lround(origin.x / 8.f)), int(std::lround(origin.z / 8.f))};
    anchor.x2 -= anchor.x2 & 1; anchor.z2 -= anchor.z2 & 1;
    auto slots = base_layout::GridBehind(anchor,
        facing, fp, cols, rows, gap, false, 0);
    for (auto& slot : slots) {
        const auto snapped = Pos2BuildPos(def, AIFloat3(slot.centre.x2 * 8.f, 0.f, slot.centre.z2 * 8.f), facing);
        slot.centre = {int(std::lround(snapped.x / 8.f)), int(std::lround(snapped.z / 8.f))};
    }
    const auto bounds = base_layout::BoundsOf(slots);
    if (slots.size() != std::size_t(cols * rows) || !IsRectFree(bounds)
        || layout_rank::OverlapsAny({bounds.minX, bounds.minZ, bounds.maxX, bounds.maxZ}, FactoryExitLanes())) return false;
    const auto position = [](const base_layout::Slot& s) {
        return AIFloat3(s.centre.x2 * 8.f, 0.f, s.centre.z2 * 8.f);
    };
    for (const auto& slot : slots) {
        const auto pos = position(slot);
        if (!economy->IsOwnSpot(pos) || !CanBeBuiltAt(def, pos)
            || !IsEngineBuildable(def, pos, facing) || economy->GetFieldYield(def, pos) <= .001f) return false;
    }
    std::vector<int> ids;
    for (const auto& slot : slots) {
        const int id = ReservePersistentBuilding(def, position(slot), facing);
        if (id < 0) {
            for (int old : ids) ReleasePersistentBuilding(old);
            return false;
        }
        ids.push_back(id);
    }
    const auto centre = base_layout::CentreOf(bounds);
    const int envelope = ReserveZone(AIFloat3(centre.x2 * 8.f, 0.f, centre.z2 * 8.f), 0,
        bounds.Width() * 8.f, bounds.Depth() * 8.f, false);
    for (std::size_t i = 0; i < ids.size(); ++i) layoutInts[name + ".slot." + std::to_string(i)] = ids[i];
    layoutInts[name + ".n"] = int(ids.size());
    layoutInts[name + ".zone"] = envelope;
    layoutInts[name + ".started"] = 0;
    circuit->LOG("METAL_CLUSTER: team=%i name=%s slots=%i pitch=%i", circuit->GetTeamId(), name.c_str(), int(ids.size()), (std::min(fp.x, fp.z) + gap) * BUILD_SQUARE_SIZE);
    return true;
}

bool CTerrainManager::PlanAirFactoryCluster(const std::string& name, CCircuitDef* firstFactory,
		CCircuitDef* repeatedFactory, CCircuitDef* nanoDef, const AIFloat3& origin,
		int facing, int count, int columns, int firstNanos)
{
	if (!layoutEnabled || name.empty() || !MakesAircraft(circuit, firstFactory)
			|| !MakesAircraft(circuit, repeatedFactory) || nanoDef == nullptr || nanoDef->GetDef() == nullptr) return false;
	const auto footprint = [](CCircuitDef* d) {
		return base_layout::Footprint{d->GetDef()->GetXSize() / 2, d->GetDef()->GetZSize() / 2};
	};
	const auto plan = base_layout::MakeAirFactoryCluster(
			{int(std::lround(origin.x / 8.f)), int(std::lround(origin.z / 8.f))}, facing,
			footprint(firstFactory), footprint(repeatedFactory), footprint(nanoDef), count, columns, firstNanos, 20);
	if (!plan.valid || !IsRectFree(plan.bounds)) return false;
	// Existing corridors are checked once; flying output needs no internal
	// ground lanes. Every other reservation caller retains its original policy.
	if (layout_rank::OverlapsAny({plan.bounds.minX, plan.bounds.minZ, plan.bounds.maxX, plan.bounds.maxZ}, FactoryExitLanes())) return false;
	const auto position = [](const base_layout::Slot& s) {
		return AIFloat3(s.centre.x2 * base_layout::HALF_CELL_ELMOS, 0.f, s.centre.z2 * base_layout::HALF_CELL_ELMOS);
	};
	const auto canBuild = [this, &position](CCircuitDef* d, const base_layout::Slot& s) {
		const auto p = position(s);
		return CanBeBuiltAt(d, p) && IsEngineBuildable(d, p, s.facing);
	};
	for (int b = 0; b < count; ++b) {
		if (!canBuild(b == 0 ? firstFactory : repeatedFactory, plan.factories[b])) return false;
		for (const auto& slot : plan.nanos[b]) {
			if (!canBuild(nanoDef, slot)
					|| position(slot).SqDistance2D(position(plan.factories[b])) > SQUARE(nanoDef->GetBuildDistance())) return false;
		}
	}
	std::vector<int> ids;
	std::vector<std::pair<std::string, int>> values;
	const auto reserve = [this, &position, &ids](CCircuitDef* d, const base_layout::Slot& s) {
		const auto p = position(s);
		const int zone = ReserveZone(p, s.facing, s.footprint.x * 8.f, s.footprint.z * 8.f, false);
		if (zone <= 0) return -1;
		const int id = ReserveBuildingEx(d, p, s.facing, 0, 0, true, false, false, zone, true, true);
		if (id < 0) ReleaseZone(zone);
		else ids.push_back(id);
		return id;
	};
	bool success = true;
	for (int b = 0; b < count && success; ++b) {
		const std::string key = name + ".bay." + std::to_string(b);
		const int id = reserve(b == 0 ? firstFactory : repeatedFactory, plan.factories[b]);
		values.emplace_back(key + ".slot", id);
		success = id >= 0;
		for (std::size_t n = 0; n < plan.nanos[b].size() && success; ++n) {
			const int nano = reserve(nanoDef, plan.nanos[b][n]);
			values.emplace_back(key + ".nano." + std::to_string(n), nano);
			success = nano >= 0;
		}
		values.emplace_back(key + ".n", int(plan.nanos[b].size()));
	}
	if (success) {
		const auto centre = base_layout::CentreOf(plan.bounds);
		const int envelope = ReserveZone(AIFloat3(centre.x2 * 8.f, 0.f, centre.z2 * 8.f), 0,
				plan.bounds.Width() * 8.f, plan.bounds.Depth() * 8.f, false);
		values.emplace_back(name + ".envelope", envelope);
		values.emplace_back(name + ".count", count);
		for (const auto& value : values) layoutInts[value.first] = value.second;
		return true;
	}
	for (int id : ids) ReleasePersistentBuilding(id);
	return false;
}

int CTerrainManager::AcquireFactoryReservation(CCircuitDef* factoryDef)
{
	if (!layoutEnabled || !factoryLineReady || (factoryDef == nullptr)) {
		return -1;
	}
	for (const auto& named : layoutGroups) {
		if ((named.first.rfind("tech.factory.", 0) != 0)
				|| (named.first.size() < 8)
				|| (named.first.compare(named.first.size() - 8, 8, ".factory") != 0)) {
			continue;
		}
		for (const auto& kv : reservations) {
			const SReservation& reservation = kv.second;
			if ((reservation.group == named.second) && (reservation.def == factoryDef)
					&& !reservation.claimed && !reservation.consumed) {
				return reservation.id;
			}
		}
	}
	CCircuitDef* nanoDef = circuit->GetCircuitDefSafe(layoutNanoDefId);
	if (nanoDef == nullptr) {
		return -1;
	}
	const base_layout::Footprint factoryFp{factoryDef->GetDef()->GetXSize() / 2, factoryDef->GetDef()->GetZSize() / 2};
	const base_layout::Footprint nanoFp{nanoDef->GetDef()->GetXSize() / 2, nanoDef->GetDef()->GetZSize() / 2};
	const int width = base_layout::Across(factoryFp, factoryLineFacing);
	const int depth = base_layout::Along(factoryFp, factoryLineFacing);
	const base_layout::FactoryTier tier = (width >= 9) ? base_layout::FactoryTier::T2 : base_layout::FactoryTier::T1;
	const bool leftFirst = (-factoryLineLeft2) <= factoryLineRight2;
	for (int step = 0; step <= 8; ++step) {
		for (int pass = 0; pass < 2; ++pass) {
			const bool left = (pass == 0) ? leftFirst : !leftFirst;
			const int gap2 = 2 * (base_layout::FACTORY_EXIT_MARGIN * 2 + step * 2);
			const int side2 = left
					? factoryLineLeft2 - gap2 - width
					: factoryLineRight2 + gap2 + width;
			const base_layout::Point centre = base_layout::Offset(factoryRearCentre, factoryLineFacing, depth, side2);
			const base_layout::FactoryCluster cluster = base_layout::MakeFactoryCluster(
					centre, factoryLineFacing, factoryFp, nanoFp, tier);
			const std::string name = "tech.factory.auto." + std::to_string(nextFactoryCluster);
			int reservation = -1;
			if (!ReserveFactoryCluster(name, cluster, factoryDef, nanoDef, reservation)) {
				continue;
			}
			if (left) {
				factoryLineLeft2 = side2 - width;
			} else {
				factoryLineRight2 = side2 + width;
			}
			++nextFactoryCluster;
			return reservation;
		}
	}
	circuit->LOG("RESERVE: no atomic factory cluster fits for %s; required factory task will abort",
			factoryDef->GetDef()->GetName());
	return -1;
}

int CTerrainManager::ReserveNanoBlock(CCircuitUnit* factory, CCircuitDef* nanoDef, int cols, int rows, int gap)
{
	if ((factory == nullptr) || (nanoDef == nullptr)) {
		return 0;
	}
	CCircuitDef* facDef = factory->GetCircuitDef();
	const int facing = factory->GetUnit()->GetBuildingFacing();
	const AIFloat3 pos = factory->GetPos(circuit->GetLastFrame()) + facDef->GetMidPosOffset(facing);
	return ReserveNanoBlockAt(nanoDef, facDef, pos, facing, cols, rows, gap);
}

void CTerrainManager::ReleaseReservation(int id)
{
	auto it = reservations.find(id);
	if (it == reservations.end()) {
		return;
	}
	SReservation& r = it->second;
	if (!r.consumed) {
		int2 c1, c2;
		if (ReservationCells(r.def, r.pos, r.facing, c1, c2)) {
			UnmarkSlot(c1, c2);
		}
	}
	circuit->GetAllyTeam()->GetLayoutReservations().Erase(circuit->GetTeamId(), allied_layout::Reservations::SLOT, it->first);
	localReservations.EraseSlot(it->first);
	EraseReservation(it->first);
}

void CTerrainManager::ReleaseGroup(int group)
{
	if (group == 0) {
		return;
	}
	std::vector<int> ids;
	for (const auto& kv : reservations) {
		if (kv.second.group == group) {
			ids.push_back(kv.first);
		}
	}
	for (int id : ids) {
		ReleaseReservation(id);
	}
}

bool CTerrainManager::IsReserved(const AIFloat3& pos) const
{
	const int x = int(pos.x + 0.5f) / (SQUARE_SIZE * 2);
	const int z = int(pos.z + 0.5f) / (SQUARE_SIZE * 2);
	return blockingMap.IsInBounds(x, z) && blockingMap.IsReserved(x, z);
}

int CTerrainManager::GetReservationCount(CCircuitDef* cdef) const
{
	int count = 0;
	for (const auto& kv : reservations) {
		if (!kv.second.consumed && (kv.second.def == cdef)) {
			++count;
		}
	}
	return count;
}

void CTerrainManager::RestoreReservation(int id)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	auto it = reservations.find(id);
	if (it == reservations.end()) {
		return;
	}
	SReservation& r = it->second;
	if (!r.consumed && !(circuit->GetEconomyManager()->IsMetalMap() && r.def->GetExtractsM() > 0)) {
		return;
	}
	int2 c1, c2;
	if (ReservationCells(r.def, r.pos, r.facing, c1, c2) && IsSlotFree(c1, c2, r.zone, id)) {
		MarkReservation(c1, c2, true);
		r.consumed = false;
		IndexLocalSlot(r.id);
		r.unitId = 0;
		r.claimed = false;
		circuit->LOG("RESERVE: restored %s at (%.0f, %.0f) (id %i)", r.def->GetDef()->GetName(), r.pos.x, r.pos.z, id);
	} else {
		circuit->GetAllyTeam()->GetLayoutReservations().Erase(circuit->GetTeamId(), allied_layout::Reservations::SLOT, it->first);
		localReservations.EraseSlot(it->first);
		EraseReservation(it->first);  // something took the ground meanwhile
	}
}

void CTerrainManager::FinishReservation(int id, int unitId)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	auto it = reservations.find(id);
	if (it == reservations.end()) {
		return;
	}
	if ((it->second.zone == 0) || (unitId == 0)) {
		circuit->GetAllyTeam()->GetLayoutReservations().Erase(circuit->GetTeamId(), allied_layout::Reservations::SLOT, it->first);
		localReservations.EraseSlot(it->first);
		EraseReservation(it->first);  // a plain reservation is met and forgotten
		return;
	}
	it->second.claimed = false;
	it->second.unitId = unitId;  // a zone slot remembers its structure (restore or forget when it goes)
    ClearLostReservation(id);
}

bool CTerrainManager::CanNavalRoute(CCircuitDef* cdef, const AIFloat3& from, const AIFloat3& to)
{
	if (cdef == nullptr || !geom::is_in_map(from) || !geom::is_in_map(to)) return false;
	auto* mt = GetMobileTypeById(cdef->GetMobileId());
	if (mt == nullptr) return false;
	// Strict membership: GetCurrentMapArea deliberately snaps impossible spawns,
	// which is inappropriate evidence for a new production berth.
	const auto* a = mt->sector[GetSectorIndex(from)].area;
	return a != nullptr && a == mt->sector[GetSectorIndex(to)].area;
}

bool CTerrainManager::PlanNavalBerth(const std::string& key, CCircuitDef* cdef,
        const AIFloat3& pos, int facing, float length, float margin)
{
	if (!layoutEnabled || cdef == nullptr || facing < 0 || facing > 3 || length <= 0.f
	    || length > 2048.f || margin < 0.f || margin > 256.f
	    || !CanReserveBuilding(cdef, pos, facing)) return false;
	const AIFloat3 p = Pos2BuildPos(cdef, pos, facing);
	const float halfDepth = cdef->GetDef()->GetZSize() * SQUARE_SIZE * .5f;
	const float halfWidth = cdef->GetDef()->GetXSize() * SQUARE_SIZE * .5f + margin;
	const AIFloat3 forward(facing == 1 ? 1.f : facing == 3 ? -1.f : 0.f, 0.f,
	                      facing == 0 ? 1.f : facing == 2 ? -1.f : 0.f);
	bool hasShip = false;
	float hullHalf = 0.f, draft = 0.f;
	for (const auto id : cdef->GetBuildOptions()) {
		auto* product = circuit->GetCircuitDef(id);
		if (product == nullptr || !product->IsMobile() || product->GetDef()->IsAbleToFly()) continue;
		std::unique_ptr<MoveData> move(product->GetDef()->GetMoveData());
		if (!move || move->GetSpeedModClass() != MoveDef::Ship) continue;
		hasShip = true;
		hullHalf = std::max(hullHalf, float(std::max(move->GetXSize(), move->GetZSize())) * SQUARE_SIZE * .5f);
		draft = std::max(draft, move->GetDepth());
		if (!CanNavalRoute(product, p, p + forward * (halfDepth + length))) return false;
	}
	if (!hasShip || hullHalf > halfWidth) return false;
	const auto elevation = [this](float x, float z) {
		return geom::is_in_map(AIFloat3(x,0.f,z)) ? areaData->GetElevationAt(x,z)
		    : std::numeric_limits<float>::quiet_NaN();
	};
	if (!naval::Corridor(p.x,p.z,facing,halfDepth+length,hullHalf,draft,elevation)
	    || !IsExitClear(cdef,p,facing,length,margin)) return false;
	int2 low, high;
	if (!ExitLaneCells(cdef,p,facing,length,margin,low,high) || IsAllyLayoutRectBlocked(low,high)) return false;
	const int slot = ReservePersistentBuilding(cdef,p,facing);
	if (slot < 0) return false;
	const int exit = ReserveZone(p + forward * (halfDepth + length*.5f), facing, halfWidth, length*.5f, true);
	if (exit <= 0) { ReleasePersistentBuilding(slot); return false; }
	SetLayoutInt(key+".slot",slot);
	SetLayoutInt(key+".exit",exit);
	SetLayoutInt(key+".facing",facing);
	SetLayoutInt(key+".x",int(p.x)); SetLayoutInt(key+".z",int(p.z));
	return true;
}

bool CTerrainManager::IsAreaVisible(const AIFloat3& pos, float radius) const
{
	return circuit->GetMapManager()->IsAreaInLOS(pos,radius);
}

int CTerrainManager::PlanNavalSupport(const std::string& key, CCircuitDef* nano, CCircuitDef* factory,
        const AIFloat3& pos, int facing, int maximum, int minimum, float margin)
{
	SSlowCall slow("PlanNavalSupport", circuit);
	if (!layoutEnabled || nano==nullptr || factory==nullptr || facing<0 || facing>3
	    || minimum<1 || maximum<minimum || maximum>128 || margin<0 || margin>256) return 0;
	const float reach=nano->GetBuildDistance();
	const auto sites=naval::SupportSites(nano->GetDef()->GetXSize()*SQUARE_SIZE,
	    nano->GetDef()->GetZSize()*SQUARE_SIZE, factory->GetDef()->GetXSize()*SQUARE_SIZE,
	    factory->GetDef()->GetZSize()*SQUARE_SIZE,reach,margin);
	const AIFloat3 forward(facing==1 ? 1.f : facing==3 ? -1.f : 0.f,0.f,facing==0 ? 1.f : facing==2 ? -1.f : 0.f);
	const AIFloat3 across(forward.z,0.f,-forward.x);
	std::vector<int> slots; slots.reserve(maximum);
	// Native private footprint reservations consult the existing allied index.
	// A single owner-thread call reserves the usable cluster before any ally or
	// economy callback can interleave. Partial terrain fits are intentional;
	// an unsuccessful minimum is rolled back, never left as an orphan bank.
	for (const auto& site: sites) {
		const auto p=Pos2BuildPos(nano,pos+across*site.across+forward*site.along,facing);
		if (p.SqDistance2D(pos)>reach*reach) continue;
		const int id=ReservePersistentBuilding(nano,p,facing);
		if (id>=0) slots.push_back(id);
		if (int(slots.size())>=maximum) break;
	}
	if (int(slots.size())<minimum) { for (int id:slots) ReleasePersistentBuilding(id); return 0; }
	for (size_t i=0;i<slots.size();++i) SetLayoutInt(key+".slot."+std::to_string(i),slots[i]);
	return int(slots.size());
}

int CTerrainManager::ReservePackedBuilding(CCircuitDef* cdef, const AIFloat3& position, int facing)
{
	if (!layoutEnabled || cdef == nullptr || cdef->GetDef() == nullptr || facing < 0 || facing > 3) return -1;
	const auto mask = blockInfos.find(cdef->GetId());
	if (mask == blockInfos.end()) return ReservePersistentBuilding(cdef, position, facing);
	const auto pos = Pos2BuildPos(cdef, position, facing);
	int2 low, high;
	if (!ReservationCells(cdef, pos, facing, low, high) || !CanBeBuiltAt(cdef, pos)) return -1;
	const layout_rank::CellRect footprint{low.x, low.y, high.x, high.y};
	if (IsAllyLayoutRectBlocked(low, high) || localReservations.OverlapsZone({low.x,low.y,high.x,high.y})
		|| localReservations.OverlapsSlot({low.x,low.y,high.x,high.y}, -1)
		|| layout_rank::OverlapsAny(footprint, FactoryExitLanes())) return -1;
	// Explicit script opt-in honours the JSON spacing mask, as ordinary build
	// search does. Ignore only permitted soft yards: real structure cells,
	// resources, allied plans and factory exits remain hard exclusions. The
	// soft-yard check visits only footprint cells; exit/index checks above keep
	// their existing cost. No additional building census is needed.
	const auto blocking = static_cast<SBlockingMap::SM>(~mask->second->GetIgnoreMask());
	for (int z=low.y; z<high.y; ++z) for (int x=low.x; x<high.x; ++x)
		if (blockingMap.IsResourceSite(x,z) || blockingMap.IsBlocked(x,z,blocking)) return -1;
	if (!IsEngineBuildable(cdef,pos,facing)) return -1;
	auto* definition=cdef->GetDef();
	const int zone=ReserveZoneMasked(pos,facing,float(definition->GetXSize()/2)*SQUARE_SIZE,
		float(definition->GetZSize()/2)*SQUARE_SIZE,false,blocking);
	if (zone<=0) return -1;
	const int slot=ReserveBuildingEx(cdef,pos,facing,0,0,true,false,false,zone,true);
	if (slot<0) ReleaseZone(zone);
	return slot;
}

int CTerrainManager::ReservePersistentBuilding(CCircuitDef* cdef, const AIFloat3& pos, int facing)
{
	if (!CanReserveBuilding(cdef, pos, facing)) return -1;
	const AIFloat3 snapped = Pos2BuildPos(cdef, pos, facing);
	auto* def = cdef->GetDef();
	// ReserveZone rotates local across/along dimensions itself.
	const float halfAcross = float(def->GetXSize() / 2) * SQUARE_SIZE;
	const float halfAlong = float(def->GetZSize() / 2) * SQUARE_SIZE;
	const int zone = ReserveZone(snapped, facing, halfAcross, halfAlong, false);
	if (zone <= 0) return -1;
	const int id = ReserveBuildingEx(cdef, snapped, facing, 0, 0, true, false, false, zone, true);
	if (id < 0) ReleaseZone(zone);
	return id;
}

void CTerrainManager::ReleasePersistentBuilding(int id)
{
	const auto it = reservations.find(id);
	if (it == reservations.end()) return;
	const int zone = it->second.zone;
	ReleaseReservation(id);
	if (zone > 0) ReleaseZone(zone);
}

int CTerrainManager::GetReservationState(int id) const
{
	const auto it = reservations.find(id);
	if (it == reservations.end()) return -1;
	const SReservation& slot = it->second;
	if (slot.unitId != 0) {
		const CCircuitUnit* unit = circuit->GetTeamUnit(slot.unitId);
		if (unit != nullptr) return unit->GetUnit()->IsBeingBuilt() ? 2 : 3;
	}
	if (slot.serveFails >= kDeadSlotFails) return 4;
	return slot.consumed ? 2 : slot.claimed ? 1 : 0;
}

bool CTerrainManager::ClaimReservation(int id)
{
	auto it = reservations.find(id);
	if ((it == reservations.end()) || it->second.claimed || it->second.consumed) {
		return false;
	}
	it->second.claimed = true;
	return true;
}

void CTerrainManager::UnclaimReservation(int id)
{
	auto it = reservations.find(id);
	if ((it != reservations.end()) && !it->second.consumed) {
		it->second.claimed = false;
	}
}

void CTerrainManager::ExpireReservations()
{
	const int frame = circuit->GetLastFrame();
	std::vector<int> ids;
	for (const auto& kv : reservations) {
		if ((kv.second.untilFrame > 0) && (frame > kv.second.untilFrame)) {
			ids.push_back(kv.first);
		}
	}
	for (int id : ids) {
		ReleaseReservation(id);
	}
}

bool CTerrainManager::FindReservedSite(CCircuitDef* cdef, const AIFloat3& pos, TerrainPredicate& predicate,
		AIFloat3& outPos, int& outFacing, int& outId, int facingFilter)
{
	const int pinned = pinnedReservation;
	const bool required = pinnedReservationRequired;
	pinnedReservation = -1;
	pinnedReservationRequired = false;
	if (!layoutEnabled) {
		return false;
	}
	ExpireReservations();
	// Reservations whose ground is no longer ours to serve: something was built
	// on it by a teammate, or it was reserved off the current map state.
	std::vector<int> dead;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if (r.consumed || (r.def != cdef)) {
			continue;
		}
		int2 c1, c2;
		bool held = ReservationCells(cdef, r.pos, r.facing, c1, c2);
		if (held && (r.zone > 0)) {
			const bool free = IsSlotFree(c1, c2, r.zone, r.id);  // zone marks stay; a structure on the cells is what takes it
			if (free) {
				continue;
			}
			// D-099: a ring site stands (partly) outside its zone; those cells carry
			// only this reservation's own mark, so it is held as a zone-less one is
			// (played: 542 reserve-drop cycles at one ring site, "ground taken")
			auto zit = zones.find(r.zone);
			const bool inZone = (zit == zones.end()) || layout_rank::Inside(layout_rank::CellRect{c1.x, c1.y, c2.x, c2.y},
					layout_rank::CellRect{zit->second.c1.x, zit->second.c1.y, zit->second.c2.x, zit->second.c2.y});
			held = !inZone;
		}
		for (int z = c1.y; held && (z < c2.y); ++z) {
			for (int x = c1.x; x < c2.x; ++x) {
				if (!blockingMap.IsReserved(x, z)) {
					held = false;
					break;
				}
			}
		}
		if (!held) {
			dead.push_back(r.id);
		}
	}
	for (int id : dead) {
		circuit->LOG("RESERVE: dropped %s reservation %i: ground taken", cdef->GetDef()->GetName(), id);
		ReleaseReservation(id);
	}

	CMap* map = circuit->GetMap();
	float maxSq = (reservationMatchRadius > 0.f) ? SQUARE(reservationMatchRadius) : std::numeric_limits<float>::max();
	// A construction turret is only worth its slot if it reaches what it was
	// asked to assist: the anchor of a nano task is the factory it is for.
	// Serving a nano for the air plant a block slot behind the bot labs put
	// it out of range of both. The slack covers the task's position shake.
	if (!cdef->IsMobile() && (cdef->GetBuildDistance() > 0.f)) {
		const float reach = cdef->GetBuildDistance() + SQUARE_SIZE * 16;
		maxSq = std::min(maxSq, SQUARE(reach));
	}
	float bestSq = std::numeric_limits<float>::max();
	SReservation* best = nullptr;
	if (pinned >= 0) {
		// An exact layout task: this slot or nothing. The caller aborts a
		// required-pin failure instead of silently falling through to the spiral.
		auto it = reservations.find(pinned);
		const char* why = (it == reservations.end()) ? "gone"
			: it->second.consumed ? "consumed"
			: (it->second.def != cdef) ? "another def"
			: (it->second.serveFails >= kDeadSlotFails) ? "dead"
			: !map->IsPossibleToBuildAt(cdef->GetDef(), it->second.pos, it->second.facing) ? "the engine refuses the ground"
			: IsAllyLayoutBlocked(cdef, it->second.pos, it->second.facing) ? "allied reservation"
			: !predicate(it->second.pos) ? "out of the builder's reach"
			: nullptr;
		if (why != nullptr) {
			// D-108 (played: one held advanced-fusion slot the engine refused was
			// offered again after every abort, and no advanced fusion went up for
			// the last nine minutes): a slot refused kDeadSlotFails times is dead;
			// its ground stays held so it is not packed again, and it is not offered
			if ((it != reservations.end()) && (std::string(why) == "the engine refuses the ground")
				&& (++it->second.serveFails == kDeadSlotFails))
			{
				circuit->LOG("RESERVE: slot %i for %s at (%.0f, %.0f) is dead after %i refusals: its ground stays held, the set moves on",
						pinned, cdef->GetDef()->GetName(), it->second.pos.x, it->second.pos.z, kDeadSlotFails);
			}
			circuit->LOG("RESERVE: pinned slot %i for %s cannot be served: %s", pinned, cdef->GetDef()->GetName(), why);
			return false;
		}
		best = &it->second;
	}
	for (auto& kv : reservations) {
		if (pinned >= 0) {
			break;
		}
		SReservation& r = kv.second;
		if (r.consumed || r.claimed || (r.def != cdef) || !r.armed
            || !layout_rank::MatchesFacingPass(r.facing, facingFilter)) {
			continue;
		}
		// The engine's own test: a wreck or a standing structure keeps the slot
		// unserved for now (a mobile unit on it does not - that is OCCUPIED, not
		// BLOCKED, and it will move). The builder must be able to reach it.
		if (IsAllyLayoutBlocked(cdef, r.pos, r.facing) || !map->IsPossibleToBuildAt(cdef->GetDef(), r.pos, r.facing) || !predicate(r.pos)) {
			continue;
		}
		const float sq = pos.SqDistance2D(r.pos);
		const float limit = r.anyReach ? std::numeric_limits<float>::max() : maxSq;
		if ((sq < limit) && (sq < bestSq)) {
			bestSq = sq;
			best = &r;
		}
	}
	if (best == nullptr) {
		if (required) {
			circuit->LOG("RESERVE: required slot for %s cannot be served", cdef->GetDef()->GetName());
		}
		return false;
	}
	int2 c1, c2;
	if (ReservationCells(cdef, best->pos, best->facing, c1, c2)) {
		UnmarkSlot(c1, c2);
	}
	best->consumed = true;
	IndexLocalSlot(best->id);
	best->claimed = true;
	outPos = best->pos;
	outFacing = best->facing;
	outId = best->id;
	circuit->LOG("RESERVE: served %s at (%.0f, %.0f) facing %i (id %i, %i of this def still held)",
			cdef->GetDef()->GetName(), outPos.x, outPos.z, outFacing, outId, GetReservationCount(cdef));
	return true;
}

/*
 * Layout: zones, corridors, bands (D-053)
 */
bool CTerrainManager::RectCells(const AIFloat3& centre, int facing, float halfAcross, float halfAlong, int2& c1, int2& c2) const
{
	const float hx = ((facing & 1) == 0) ? halfAcross : halfAlong;
	const float hz = ((facing & 1) == 0) ? halfAlong : halfAcross;
	const float cell = SQUARE_SIZE * 2;
	c1.x = int(std::floor((centre.x - hx) / cell));
	c1.y = int(std::floor((centre.z - hz) / cell));
	c2.x = int(std::ceil((centre.x + hx) / cell));
	c2.y = int(std::ceil((centre.z + hz) / cell));
	c1.x = std::max(0, c1.x); c1.y = std::max(0, c1.y);
	c2.x = std::min(blockingMap.columns, c2.x); c2.y = std::min(blockingMap.rows, c2.y);
	return (c2.x > c1.x) && (c2.y > c1.y);
}

int CTerrainManager::ZoneAt(int x, int z) const
{
	if (zoneMap.empty() || !blockingMap.IsInBounds(x, z)) {
		return 0;
	}
	return zoneMap[z * blockingMap.columns + x];
}

bool CTerrainManager::IsSlotFree(const int2& c1, const int2& c2, int zone, int ignoreId) const
{
    const bool result = IsSlotFreeIndexed(c1, c2, zone, ignoreId);
    // D-199: opt-in differential runtime oracle; never changes the answer.
    static const bool verify = std::getenv("CIRCUIT_VERIFY_LOCAL_LAYOUT") != nullptr;
    if (verify) {
        ++localOracleQueries;
        if (result != IsSlotFreeLegacy(c1, c2, zone, ignoreId)) {
            ++localOracleMismatches;
            circuit->LOG("[INVARIANT] INV-144: local occupancy differs from legacy scan team=%i zone=%i ignore=%i rect=%i,%i,%i,%i",
                circuit->GetTeamId(), zone, ignoreId, c1.x, c1.y, c2.x, c2.y);
        }
        if (localOracleQueries == 1 || localOracleQueries % 100000 == 0)
            circuit->LOG("[LocalOracle] team=%i frame=%i queries=%llu mismatches=%llu cell_bytes=%llu",
                circuit->GetTeamId(), circuit->GetLastFrame(),
                static_cast<unsigned long long>(localOracleQueries), static_cast<unsigned long long>(localOracleMismatches),
                static_cast<unsigned long long>(localReservations.CellStorageBytes()));
    }
    return result;
}

bool CTerrainManager::IsSlotFreeIndexed(const int2& c1, const int2& c2, int zone, int ignoreId) const
{
	if (IsAllyLayoutRectBlocked(c1, c2)) return false;
	// Fresh unscoped reservations cannot fill holes inside a planned rectangle
	// (for example after a wreck or old structure disappears). Zone packing and
	// restoring an existing exact slot retain their explicit authority.
	if (zone == 0 && ignoreId < 0 && localReservations.OverlapsZone({c1.x, c1.y, c2.x, c2.y})) return false;
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			if (!blockingMap.IsInBounds(x, z)) {
				return false;
			}
			// A zone only grants permission to overlap its reservation marks and
			// building yards, never an unoccupied resource node (including load).
			if (blockingMap.IsResourceSite(x, z)) return false;
			if (!blockingMap.IsBlocked(x, z, all)) {
				continue;
			}
			// Inside its own zone a slot may stand on the zone's marks and in the
			// yards of the zone's other structures (converters are stacked, the
			// spine sits in the fusions' circle); a structure's own cells refuse.
			if ((zone > 0) && blockingMap.IsReserved(x, z) && (ZoneAt(x, z) == zone)) {
				continue;
			}
			return false;
		}
	}
	if (zone > 0 && localReservations.OverlapsSlot({c1.x, c1.y, c2.x, c2.y}, ignoreId)) return false;
	return true;
}

bool CTerrainManager::IsSlotFreeLegacy(const int2& c1, const int2& c2, int zone, int ignoreId) const
{
	if (IsAllyLayoutRectBlocked(c1, c2)) return false;
	// Fresh unscoped reservations cannot fill holes inside a planned rectangle
	// (for example after a wreck or old structure disappears). Zone packing and
	// restoring an existing exact slot retain their explicit authority.
	if (zone == 0 && ignoreId < 0) {
		for (const auto& entry : zones) {
			const SZone& z = entry.second;
			if (c1.x < z.c2.x && z.c1.x < c2.x && c1.y < z.c2.y && z.c1.y < c2.y) return false;
		}
	}
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			if (!blockingMap.IsInBounds(x, z)) {
				return false;
			}
			if (blockingMap.IsResourceSite(x, z)) return false;
			if (!blockingMap.IsBlocked(x, z, all)) {
				continue;
			}
			// Inside its own zone a slot may stand on the zone's marks and in the
			// yards of the zone's other structures (converters are stacked, the
			// spine sits in the fusions' circle); a structure's own cells refuse.
			if ((zone > 0) && blockingMap.IsReserved(x, z) && (ZoneAt(x, z) == zone)) {
				continue;
			}
			return false;
		}
	}
	if (zone > 0) {
		for (const auto& kv : reservations) {
			const SReservation& r = kv.second;
			if ((r.id == ignoreId) || r.consumed) {
				continue;
			}
			int2 r1, r2;
			if (!ReservationCells(r.def, r.pos, r.facing, r1, r2)) {
				continue;
			}
			if ((r1.x < c2.x) && (c1.x < r2.x) && (r1.y < c2.y) && (c1.y < r2.y)) {
				return false;  // another unserved slot holds these cells
			}
		}
	}
	return true;
}

void CTerrainManager::UnmarkSlot(const int2& c1, const int2& c2)
{
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			if (blockingMap.IsReserved(x, z) && (ZoneAt(x, z) == 0)) {
				blockingMap.DelStruct(x, z, SBlockingMap::StructType::RESERVED, all);
			}
		}
	}
}

int CTerrainManager::FindSlotAt(CCircuitDef* cdef, const AIFloat3& pos) const
{
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.def == cdef) && (r.pos.SqDistance2D(pos) < SQUARE(SQUARE_SIZE))) {
			return r.id;
		}
	}
	return -1;
}

void CTerrainManager::RemarkZoneCells(int2 c1, int2 c2)
{
	blockingMap.Bound(c1, c2);
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			if ((ZoneAt(x, z) != 0) && !blockingMap.IsStruct(x, z)) {
				blockingMap.ReStruct(x, z, SBlockingMap::StructType::RESERVED, all);  // the zone's own count still stands
			}
		}
	}
}

void CTerrainManager::MarkSlotRecycled(CCircuitDef* cdef, const AIFloat3& pos)
{
	if (!layoutEnabled || (cdef == nullptr)) {
		return;
	}
	int best = -1;
	float bestSq = SQUARE(SQUARE_SIZE * 4);
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.def != cdef) || !r.consumed) {
			continue;
		}
		const float sq = r.pos.SqDistance2D(pos);
		if (sq <= bestSq) {
			bestSq = sq;
			best = r.id;
		}
	}
	if ((best >= 0) && recycledSlots.insert(best).second) {
		circuit->LOG("RESERVE: %s at (%.0f, %.0f) is being reclaimed: its slot will be freed (id %i)",
				cdef->GetDef()->GetName(), pos.x, pos.z, best);
	}
}

int CTerrainManager::EdgeGapToGroup(CCircuitDef* cdef, const AIFloat3& pos, int facing, int group) const
{
	if (cdef == nullptr) {
		return -1;
	}
	int2 c1, c2;
	if (!ReservationCells(cdef, pos, facing, c1, c2)) {
		// D-104: a standing unit's position need not be grid-aligned: its footprint from its size
		UnitDef* ud = cdef->GetDef();
		const float cell = SQUARE_SIZE * 2;
		const float hx = (((facing & 1) == 0) ? ud->GetXSize() : ud->GetZSize()) * SQUARE_SIZE * 0.5f;
		const float hz = (((facing & 1) == 0) ? ud->GetZSize() : ud->GetXSize()) * SQUARE_SIZE * 0.5f;
		c1 = int2(int(std::floor((pos.x - hx) / cell)), int(std::floor((pos.z - hz) / cell)));
		c2 = int2(int(std::ceil((pos.x + hx) / cell)), int(std::ceil((pos.z + hz) / cell)));
	}
	std::vector<layout_rank::CellRect> turrets;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		int2 r1, r2;
		if ((r.group == group) && (r.def != nullptr) && ReservationCells(r.def, r.pos, r.facing, r1, r2)) {
			turrets.push_back(layout_rank::CellRect{r1.x, r1.y, r2.x, r2.y});
		}
	}
	return turrets.empty() ? -1 : layout_rank::NearestEdgeGap(layout_rank::CellRect{c1.x, c1.y, c2.x, c2.y}, turrets);
}

bool CTerrainManager::PickFlushSite(int zone, CCircuitDef* cdef, int nanoGroup, int facing, const AIFloat3& anchor, bool needExit,
		AIFloat3& outPos, int& outGap, AIFloat3& outTouch, int* outServedGap, bool ring, int maximumGapCells)
{
	if (cdef == nullptr) {
		return false;
	}
	// D-104: factories scan the ring round the zone (the block's open front side,
	// the factory line, lies there); economy sets stay in the zone, so the front
	// is left to the factories (played: the sets took it, the rebuilt lab found
	// no ground against a built turret)
	const std::vector<SPackCandidate> cands = PackCandidates(zone, cdef, nanoGroup, facing, anchor, 0.f, 0.f, ring);
	if (cands.empty()) {
		return false;
	}
	struct STurret { layout_rank::CellRect rect; AIFloat3 pos; };
	std::vector<STurret> turrets;
	std::vector<layout_rank::CellRect> turretRects, servedRects;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		int2 r1, r2;
		if ((r.group == nanoGroup) && (r.def != nullptr) && ReservationCells(r.def, r.pos, r.facing, r1, r2)) {
			turrets.push_back(STurret{layout_rank::CellRect{r1.x, r1.y, r2.x, r2.y}, r.pos});
			turretRects.push_back(turrets.back().rect);
			if (r.consumed) {
				servedRects.push_back(turrets.back().rect);  // a turret built or going up
			}
		}
	}
	if (turrets.empty()) {
		return false;
	}
	// flush first (gap 0 to a turret slot), then the packer's own order (served
	// turrets first, nearest the anchor): a stable sort keeps it among equals
	// D-104: touching a turret that stands (or is going up) first, then touching a
	// planned one (played: a rebuilt advanced lab flush against a planned slot,
	// its nearest built turret 258 elmos away)
	struct SRanked { const SPackCandidate* c; int gap; int servedGap; };
	std::vector<SRanked> ranked;
	ranked.reserve(cands.size());
	for (const SPackCandidate& c : cands) {
		int2 c1, c2;
		if (!ReservationCells(cdef, c.pos, facing, c1, c2)) {
			continue;
		}
		const layout_rank::CellRect cr{c1.x, c1.y, c2.x, c2.y};
		ranked.push_back(SRanked{&c, layout_rank::NearestEdgeGap(cr, turretRects), layout_rank::NearestEdgeGap(cr, servedRects)});
	}
	std::stable_sort(ranked.begin(), ranked.end(), [](const SRanked& a, const SRanked& b) {
		const bool aServed = (a.servedGap == 0), bServed = (b.servedGap == 0);
		if (aServed != bServed) {
			return aServed;
		}
		return a.gap < b.gap;
	});
	constexpr int POCKET_TESTS_MAX = 40;  // D-090
	int pocketTests = 0, tried = 0;
	for (const SRanked& rk : ranked) {
		if (maximumGapCells >= 0 && rk.gap > maximumGapCells) continue;
		if (++tried > 400) {
			break;
		}
		AIFloat3 pos = rk.c->pos;
		pos.y = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
		if (!circuit->GetMap()->IsPossibleToBuildAt(cdef->GetDef(), pos, facing)) {
			continue;
		}
		if (needExit && !IsExitClear(cdef, pos, facing, EXIT_CLEAR_LENGTH, EXIT_CLEAR_MARGIN)) {
			continue;  // D-104: a ground factory's units walk out
		}
		if ((++pocketTests <= POCKET_TESTS_MAX) && LeavesPocket(zone, cdef, pos, facing)) {
			continue;
		}
		int2 f1, f2;
		ReservationCells(cdef, pos, facing, f1, f2);
		const layout_rank::CellRect fr{f1.x, f1.y, f2.x, f2.y};
		int touchGap = 1 << 20;
		for (const STurret& tt : turrets) {
			const int g = layout_rank::EdgeGap(fr, tt.rect);
			if (g < touchGap) {
				touchGap = g;
				outTouch = tt.pos;
			}
		}
		outPos = pos;
		outGap = rk.gap;
		if (outServedGap != nullptr) {
			*outServedGap = rk.servedGap;
		}
		return true;
	}
	return false;
}

int CTerrainManager::PackSet(int zone, CCircuitDef* cdef, int nanoGroup, int facing, const AIFloat3& anchor, int count, bool ring, int maximumGapCells)
{
	SSlowCall slow("PackSet", circuit);
	if ((cdef == nullptr) || (count < 1)) {
		return -1;
	}
	AIFloat3 pos, touch;
	int gap = 0;
	if (!PickFlushSite(zone, cdef, nanoGroup, facing, anchor, false, pos, gap, touch, nullptr, ring, maximumGapCells)) {
		return -1;
	}
	// PickFlushSite checks the seed. Previously the remaining line could grow
	// beyond build range. Gather immutable local geometry
	// once, then validate each extension before reserving it. This runs only at
	// set allocation, not per frame; occupancy remains indexed per footprint.
	std::vector<layout_rank::SupportReach> support;
	for (const auto& entry : reservations) {
		const auto& reservation = entry.second;
		if (reservation.group == nanoGroup && reservation.def != nullptr)
			support.push_back({ToPt(reservation.pos), reservation.def->GetBuildDistance()});
	}
	if (!layout_rank::WithinSupport(ToPt(pos), support)) return -1;
	const int group = nextGroupId++;
	const int first = ReserveBuildingEx(cdef, pos, facing, 0, group, true, true, false, zone, true);
	if (first < 0) {
		--nextGroupId;
		return -1;
	}
	setGroups.insert(group);
	// the rest of the set: lined up away from the turret the first touches
	int2 f1, f2;
	ReservationCells(cdef, pos, facing, f1, f2);
	int sx = 0, sz = 0;
	layout_rank::SetStep(pos.x, pos.z, touch.x, touch.z, f2.x - f1.x, f2.y - f1.y, sx, sz);
	int laid = 1;
	for (int k = 1; (k < count) && ((sx != 0) || (sz != 0)); ++k) {
		AIFloat3 p(pos.x + float(sx * k) * SQUARE_SIZE * 2, 0.f, pos.z + float(sz * k) * SQUARE_SIZE * 2);
		p.y = circuit->GetMap()->GetElevationAt(p.x, p.z);
		if (!layout_rank::WithinSupport(ToPt(p), support)) break;
		// ReserveBuildingEx below already validates the footprint and all exits.
		// Do not duplicate that scan for every extension.
		if (!circuit->GetMap()->IsPossibleToBuildAt(cdef->GetDef(), p, facing) || LeavesPocket(zone, cdef, p, facing)) {
			break;
		}
		if (ReserveBuildingEx(cdef, p, facing, 0, group, true, true, false, zone, true) < 0) {
			break;
		}
		++laid;
	}
	circuit->LOG("RESERVE: set of %i %s from (%.0f, %.0f), %i cell(s) from a turret, growing (%i, %i) cells a step (group %i, id %i)",
			laid, cdef->GetDef()->GetName(), pos.x, pos.z, gap, sx, sz, group, first);
	return first;
}

bool CTerrainManager::MakesAircraft(CCircuitAI* circuit, CCircuitDef* cdef)
{
	if (cdef == nullptr) {
		return false;
	}
	for (CCircuitDef::Id id : cdef->GetBuildOptions()) {
		CCircuitDef* o = circuit->GetCircuitDef(id);
		if ((o != nullptr) && o->IsMobile() && o->IsAbleToFly()) {
			return true;
		}
	}
	return false;
}

int CTerrainManager::PackFactoryFlush(CCircuitDef* cdef, const AIFloat3& anchor)
{
	SSlowCall slow("PackFactoryFlush", circuit);
	if (!layoutEnabled || (cdef == nullptr) || factoryZones.empty()) {
		return -1;
	}
	// the owner's rule (D-101): with no turret of ours standing a factory goes anywhere
	bool turretStands = false;
	for (const auto& kv : reservations) {
		for (const auto& zg : factoryZones) {
			if ((kv.second.group == zg.second) && kv.second.consumed) {
				turretStands = true;
				break;
			}
		}
		if (turretStands) {
			break;
		}
	}
	if (!turretStands) {
		return -1;
	}
	const bool air = MakesAircraft(circuit, cdef);
	const int front = ((factoryFront >= 0) && (factoryFront <= 3)) ? factoryFront : UNIT_FACING_SOUTH;
	std::vector<int> facings = {front, (front + 1) % 4, (front + 3) % 4};
	if (air) {
		facings.push_back((front + 2) % 4);  // D-104: an air factory's units fly out; any facing
	}
	// over every cluster and facing: touching a turret that stands first, then
	// the smallest gap; the front facing and the main cluster first among equals
	// (played: a rebuilt advanced lab flush against the forward cluster's planned
	// slots, 592 elmos from any built turret)
	int bestGap = 1 << 20, bestZone = 0, bestFacing = front;
	bool bestServed = false;
	AIFloat3 bestPos;
	for (int f : facings) {
		for (const auto& zg : factoryZones) {
			AIFloat3 pos, touch;
			int gap = 0, servedGap = 1 << 20;
			if (!PickFlushSite(zg.first, cdef, zg.second, f, anchor, !air, pos, gap, touch, &servedGap, true)) {
				continue;
			}
			const bool served = (servedGap == 0);
			if ((served && !bestServed) || ((served == bestServed) && (gap < bestGap))) {
				bestGap = gap;
				bestServed = served;
				bestZone = zg.first;
				bestFacing = f;
				bestPos = pos;
			}
		}
		if (bestServed && !air) {
			break;  // touching a built turret in the preferred facing: no need to turn it
		}
	}
	if (bestZone == 0) {
		return -1;
	}
	const int id = ReserveBuildingEx(cdef, bestPos, bestFacing, 0, 0, true, true, false, bestZone, true);
	if (id >= 0) {
		circuit->LOG("RESERVE: factory %s flush at (%.0f, %.0f) facing %i, %i cell(s) from a turret%s%s (id %i)",
				cdef->GetDef()->GetName(), bestPos.x, bestPos.z, bestFacing, bestGap, bestServed ? ", touching a built one" : ", planned slots only",
				air ? ", air: any facing" : "", id);
	}
	return id;
}

void CTerrainManager::IndexReservation(int id)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
    const auto& r = reservations.at(id);
    // Persist in the existing named-int section: no binary layout change.
    // Load reads that section before indexing slots; the index itself is derived.
    if (GetLayoutInt("native.lost." + std::to_string(id), 0) != 0)
        lostSlots[r.def->GetId()].ids.insert(id);
    for (int scope : {r.zone, -r.group}) {
        if (!scope) continue;
        auto& bucket = scopedSlots[{scope, r.def->GetId()}];
        bucket.ids.insert(id); bucket.visited=0; bucket.sawFree=false;
    }
}

void CTerrainManager::EraseReservation(int id)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
    auto found = reservations.find(id);
    if (found == reservations.end()) return;
    const auto& r = found->second;
    ClearLostReservation(id);
    for (int scope : {r.zone, -r.group}) {
        if (!scope) continue;
        auto bucket = scopedSlots.find({scope, r.def->GetId()});
        if (bucket == scopedSlots.end()) continue;
        bucket->second.ids.erase(id);
        bucket->second.visited=0; bucket->second.sawFree=false;
        if (bucket->second.ids.empty()) scopedSlots.erase(bucket);
    }
    reservations.erase(found);
}

int CTerrainManager::NextReachableSlot(CCircuitUnit* builder, const CCircuitDef* cdef, int zone, int group, int budget)
{
    if (!builder || !cdef || (zone <= 0 && group <= 0)) return -1;
    auto scope = scopedSlots.find({group > 0 ? -group : zone, cdef->GetId()});
    if (scope == scopedSlots.end()) return -1;
    auto& bucket = scope->second;
    // All creation, release, expiry and load paths maintain this index. States
    // (claimed/framed/dead) are read fresh. O(log scopes + B log reservations),
    // at most B reach/build callbacks. The cursor advances even on rejection:
    // a blocked prefix cannot starve later slots on successive idle asks.
    // IDs, not iterators, survive mutation. Shared rotation is fair to different
    // builders without retaining per-unit cursors after transfer/destruction.
    const int result = reservation_candidates::Next(bucket.ids, bucket.after, budget, [&](int id) {
        ++bucket.visited;
        const auto& r = reservations.at(id);
        if (r.consumed || r.claimed || r.serveFails >= kDeadSlotFails || (zone > 0 && r.zone != zone)) return false;
        bucket.sawFree = true;
        return CanReachAtSafe(builder, r.pos, builder->GetCircuitDef()->GetBuildDistance()) && IsReservationBuildable(id);
    });
    if (result >= 0) { bucket.visited=0; bucket.sawFree=false; return result; }
    if (bucket.visited < int(bucket.ids.size())) return -2;
    // Only grow the pack after a full cycle proves all existing slots occupied.
    // Free but unreachable/blocked slots must not cause endless new packs.
    const bool free = bucket.sawFree; bucket.visited=0; bucket.sawFree=false;
    return free ? -2 : -1;
}

void CTerrainManager::ClearLostReservation(int id)
{
    const auto found = reservations.find(id);
    if (found != reservations.end()) {
        auto bucket = lostSlots.find(found->second.def->GetId());
        if (bucket != lostSlots.end()) {
            bucket->second.ids.erase(id);
            if (bucket->second.ids.empty()) lostSlots.erase(bucket);
        }
    }
    layoutInts.erase("native.lost." + std::to_string(id));
}

int CTerrainManager::GetLostReservationCount(const CCircuitDef* cdef) const
{
    if (cdef == nullptr) return 0;
    const auto bucket = lostSlots.find(cdef->GetId());
    return bucket == lostSlots.end() ? 0 : int(bucket->second.ids.size());
}

int CTerrainManager::NextLostReservation(CCircuitUnit* builder, const CCircuitDef* cdef, int budget)
{
    if (builder == nullptr || cdef == nullptr) return -1;
    auto bucket = lostSlots.find(cdef->GetId());
    if (bucket == lostSlots.end()) return -1;
    // Lifecycle maintained IDs, O(log D + B log R), at most B reach/build
    // queries per decision (B <= 32). No unit scan or recurring polling. A
    // wreck can outlive three failed starts: only lost capacity gets a fresh
    // failure budget once its original footprint is safe and buildable again.
    return reservation_candidates::Next(bucket->second.ids, bucket->second.after, budget, [&](int id) {
        auto& r = reservations.at(id);
        if (r.consumed || r.claimed || r.unitId != 0) return false;
        if (!CanReachAtSafe(builder, r.pos, builder->GetCircuitDef()->GetBuildDistance())) return false;
        const int failures = r.serveFails;
        r.serveFails = 0;
        if (IsReservationBuildable(id)) return true;
        r.serveFails = failures;
        return false;
    });
}

int CTerrainManager::NextSetSlot(CCircuitDef* cdef) const
{
	int best = -1, bestOrder = 1 << 20;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.def != cdef) || r.consumed || r.claimed || (setGroups.count(r.group) == 0) || (r.serveFails >= kDeadSlotFails)) {
			continue;
		}
		// the set's own order: the footprint nearest the turret first
		const int key = r.group * 64 + r.order;
		if (key < bestOrder) {
			bestOrder = key;
			best = r.id;
		}
	}
	return best;
}

int CTerrainManager::ReleaseSetSlots(CCircuitDef* cdef)
{
	std::vector<int> ids;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.def == cdef) && !r.consumed && !r.claimed && (setGroups.count(r.group) > 0) && (r.serveFails < kDeadSlotFails)
            && GetLayoutInt("native.lost." + std::to_string(r.id), 0) == 0) {
			ids.push_back(r.id);
		}
	}
	for (int id : ids) {
		ReleaseReservation(id);
	}
	if (!ids.empty()) {
		circuit->LOG("RESERVE: %i unused %s set slot(s) released", int(ids.size()), cdef->GetDef()->GetName());
	}
	return int(ids.size());
}

void CTerrainManager::OnStructureGone(CCircuitDef* cdef, const AIFloat3& pos)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	const int id = FindSlotAt(cdef, pos);
	if (id < 0) {
		return;
	}
	auto it = reservations.find(id);
	SReservation& r = it->second;
	if ((r.unitId == 0) || (r.zone == 0)) {
		return;  // a pending task's blocker, not a structure
	}
	if (r.tenant) {
		circuit->LOG("RESERVE: tenant %s at (%.0f, %.0f) gone; its ground goes to the successor band (id %i)",
				cdef->GetDef()->GetName(), pos.x, pos.z, id);
		circuit->GetAllyTeam()->GetLayoutReservations().Erase(circuit->GetTeamId(), allied_layout::Reservations::SLOT, it->first);
		localReservations.EraseSlot(it->first);
		EraseReservation(it->first);
		return;
	}
	if (recycledSlots.erase(id) > 0) {
		// D-101 (played: 38 turbines, 10 converters and the T1 lab reclaimed, each
		// slot restored for its own def; the advanced fusions went elsewhere and the
		// rebuilt lab went back into the old footprint)
		circuit->LOG("RESERVE: %s at (%.0f, %.0f) reclaimed; its ground is free again (id %i)",
				cdef->GetDef()->GetName(), pos.x, pos.z, id);
		circuit->GetAllyTeam()->GetLayoutReservations().Erase(circuit->GetTeamId(), allied_layout::Reservations::SLOT, it->first);
		localReservations.EraseSlot(it->first);
		EraseReservation(it->first);
		return;
	}
	r.unitId = 0;
	r.consumed = false;
    r.claimed = false;
    layoutInts["native.lost." + std::to_string(id)] = 1;
    lostSlots[cdef->GetId()].ids.insert(id);
	IndexLocalSlot(r.id);
	int2 c1, c2;
	if (ReservationCells(cdef, pos, r.facing, c1, c2)) {
		MarkReservation(c1, c2, true);
	}
	circuit->LOG("RESERVE: %s at (%.0f, %.0f) lost; slot restored (id %i)", cdef->GetDef()->GetName(), pos.x, pos.z, id);
}

AIFloat3 CTerrainManager::GetZoneCorner(int id, bool upper) const
{
    const auto found = zones.find(id);
    if (found == zones.end()) return {-1.f, 0.f, -1.f};
    const int2& cell = upper ? found->second.c2 : found->second.c1;
    return {float(cell.x * SQUARE_SIZE * 2), 0.f, float(cell.y * SQUARE_SIZE * 2)};
}

int CTerrainManager::ReserveZone(const AIFloat3& centre, int facing, float halfAcross, float halfAlong, bool corridor)
{
	return ReserveZoneMasked(centre,facing,halfAcross,halfAlong,corridor,static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL));
}

int CTerrainManager::ReserveZoneMasked(const AIFloat3& centre, int facing, float halfAcross, float halfAlong,
	bool corridor, SBlockingMap::SM blockingMask)
{
	SSlowCall slow("ReserveZone", circuit);
	if (!layoutEnabled) {
		return 0;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	if (zoneMap.size() != blockingMap.grid.size()) {
		zoneMap.assign(blockingMap.grid.size(), 0);
	}
	int2 c1, c2;
	if (!RectCells(centre, facing, halfAcross, halfAlong, c1, c2)) {
		circuit->LOG("RESERVE: %s refused at (%.0f, %.0f): off map", corridor ? "corridor" : "zone", centre.x, centre.z);
		return 0;
	}
	if (IsAllyLayoutRectBlocked(c1, c2)) return 0;
    // Keep immutable resource sites as holes, even when their surrounding
    // envelope is shared with allies. IsAllyLayoutBlocked admits only the
    // matching resource building on the whole protected plot; IsSlotFree and
    // the ordinary placement predicate still reject all unrelated buildings.

	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	const int id = nextZoneId++;
	int cells = 0;
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			if (blockingMap.IsBlocked(x, z, blockingMask)) {
				continue;  // a hole: a mex, a structure, another plan's ground
			}
			blockingMap.AddReservationUnderlay(x, z, all);
			zoneMap[z * blockingMap.columns + x] = id;
			++cells;
		}
	}
	const int total = (c2.x - c1.x) * (c2.y - c1.y);
	circuit->LOG("RESERVE: %s %i at (%.0f, %.0f) facing %i, %ix%i cells: %i of %i held",
			corridor ? "corridor" : "zone", id, centre.x, centre.z, facing, c2.x - c1.x, c2.y - c1.y, cells, total);
	if (cells == 0) {
		--nextZoneId;
		return 0;
	}
	zones[id] = SZone{id, c1, c2, corridor, cells};
	ShareZone(id);
	return id;
}

int CTerrainManager::ReserveExitCone(CCircuitUnit* factory, float length, float margin)
{
	if (!layoutEnabled || (factory == nullptr) || (factory->GetCircuitDef()->GetDef() == nullptr)) {
		return 0;
	}
	CCircuitDef* facDef = factory->GetCircuitDef();
	const int facing = factory->GetUnit()->GetBuildingFacing();
	const AIFloat3 pos = factory->GetPos(circuit->GetLastFrame()) + facDef->GetMidPosOffset(facing);
	UnitDef* unitDef = facDef->GetDef();
	const float width = ((((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2) * (SQUARE_SIZE * 2);
	const float depth = ((((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2) * (SQUARE_SIZE * 2);
	AIFloat3 fwd;
	switch (facing) {
		default:
		case UNIT_FACING_SOUTH: fwd = AIFloat3(0.f, 0.f, 1.f);  break;
		case UNIT_FACING_EAST:  fwd = AIFloat3(1.f, 0.f, 0.f);  break;
		case UNIT_FACING_NORTH: fwd = AIFloat3(0.f, 0.f, -1.f); break;
		case UNIT_FACING_WEST:  fwd = AIFloat3(-1.f, 0.f, 0.f); break;
	}
	const AIFloat3 centre = pos + fwd * (depth * 0.5f + length * 0.5f);
	return ReserveZone(centre, facing, width * 0.5f + margin, length * 0.5f, true);
}

void CTerrainManager::ReleaseZone(int id)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	auto it = zones.find(id);
	if (it == zones.end()) {
		return;
	}
	std::vector<int> ids;
	for (const auto& kv : reservations) {
		if (kv.second.zone == id) {
			ids.push_back(kv.first);
		}
	}
	for (int rid : ids) {
		circuit->GetAllyTeam()->GetLayoutReservations().Erase(circuit->GetTeamId(), allied_layout::Reservations::SLOT, rid);
		localReservations.EraseSlot(rid);
		EraseReservation(rid);
	}
	const SZone& zn = it->second;
	for (int z = zn.c1.y; z < zn.c2.y; ++z) {
		for (int x = zn.c1.x; x < zn.c2.x; ++x) {
			const int i = z * blockingMap.columns + x;
			if (zoneMap[i] != id) {
				continue;
			}
			zoneMap[i] = 0;
			blockingMap.DelReservationUnderlay(x, z);
		}
	}
	circuit->LOG("RESERVE: %s %i released", zn.corridor ? "corridor" : "zone", id);
	circuit->GetAllyTeam()->GetLayoutReservations().Erase(circuit->GetTeamId(), allied_layout::Reservations::ZONE, id);
	localReservations.EraseZone(it->first);
	zones.erase(it);
}

bool CTerrainManager::IsZoneClear(int id) const
{
	auto it = zones.find(id);
	if (it == zones.end()) {
		return false;
	}
	const SZone& zn = it->second;
	for (int z = zn.c1.y; z < zn.c2.y; ++z) {
		for (int x = zn.c1.x; x < zn.c2.x; ++x) {
			if ((zoneMap[z * blockingMap.columns + x] == id) && blockingMap.IsStruct(x, z) && !blockingMap.IsReserved(x, z)) {
				return false;
			}
		}
	}
	return true;
}

int CTerrainManager::LayBand(int zone, CCircuitDef* cdef, const AIFloat3& frontCentre, int facing, int cols, int rows, int gap,
		bool armed, bool anyReach, bool tenant, int group)
{
	SSlowCall slow("LayBand", circuit);
	auto it = zones.find(zone);
	if ((it == zones.end()) || it->second.corridor) {
		return 0;
	}
	return ReserveGridEx(cdef, frontCentre, facing, cols, rows, gap, 0, armed, anyReach, tenant, zone, group);
}

void CTerrainManager::ArmGroup(int group, bool armed)
{
	if (group == 0) {
		return;
	}
	int n = 0;
	for (auto& kv : reservations) {
		if ((kv.second.group == group) && (kv.second.armed != armed)) {
			kv.second.armed = armed;
			++n;
		}
	}
	if (n > 0) {
		circuit->LOG("RESERVE: group %i %s (%i slots)", group, armed ? "armed" : "held", n);
	}
}

void CTerrainManager::ReleaseUnconsumed(int group)
{
	if (group == 0) {
		return;
	}
	std::vector<int> ids;
	for (const auto& kv : reservations) {
		if ((kv.second.group == group) && !kv.second.consumed && !kv.second.claimed) {
			ids.push_back(kv.first);
		}
	}
	for (int id : ids) {
		ReleaseReservation(id);
	}
	if (!ids.empty()) {
		circuit->LOG("RESERVE: group %i: %i unserved slots released", group, (int)ids.size());
	}
}

int CTerrainManager::GetGroupCount(int group, bool unconsumedOnly) const
{
	int count = 0;
	for (const auto& kv : reservations) {
		if ((kv.second.group == group) && (!unconsumedOnly || (!kv.second.consumed && (kv.second.serveFails < kDeadSlotFails)))) {
			++count;
		}
	}
	return count;
}

int CTerrainManager::NextSlot(int group, const AIFloat3& anchor) const
{
	int best = -1;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.group != group) || r.consumed || !r.armed || (r.serveFails >= kDeadSlotFails)) {
			continue;
		}
		const float sq = anchor.SqDistance2D(r.pos);
		if (sq < bestSq) {
			bestSq = sq;
			best = r.id;
		}
	}
	return best;
}

int CTerrainManager::NextBuilt(int group, const AIFloat3& anchor) const
{
	int best = -1;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.group != group) || (r.unitId == 0)) {
			continue;
		}
		const float sq = anchor.SqDistance2D(r.pos);
		if (sq < bestSq) {
			bestSq = sq;
			best = r.id;
		}
	}
	return best;
}

static constexpr int PACK_NEAR_POINT_TRIES = 2000;

AIFloat3 CTerrainManager::PackNearPoint(CCircuitDef* cdef, const AIFloat3& pos, float radius, int facing, TerrainPredicate& predicate)
{
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return -RgtVector;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	UnitDef* unitDef = cdef->GetDef();
	const int dx = (((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;
	const int dz = (((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;
	if ((dx <= 0) || (dz <= 0)) {
		return -RgtVector;
	}
	// A def with a block mask (a factory's yard) needs that much free ground;
	// only the footprint is reserved.
	int mx = dx, mz = dz;
	auto search = blockInfos.find(cdef->GetId());
	if (search != blockInfos.end()) {
		mx = std::max(mx, search->second->GetXSize());
		mz = std::max(mz, search->second->GetZSize());
	}
	const float cell = SQUARE_SIZE * 2;
	const float half = base_layout::HALF_CELL_ELMOS;
	const int r = std::max(1, int(std::ceil(std::max(0.f, radius) / cell)));
	const int cx0 = int(pos.x / cell) - r, cx1 = int(pos.x / cell) + r;
	const int cz0 = int(pos.z / cell) - r, cz1 = int(pos.z / cell) + r;
	struct SCand { AIFloat3 pos; float sq; };
	std::vector<SCand> cands;
	const float radiusSq = SQUARE(std::max(radius, cell));
	for (int cz = std::max(0, cz0); cz + dz <= blockingMap.rows && cz <= cz1; ++cz) {
		for (int cx = std::max(0, cx0); cx + dx <= blockingMap.columns && cx <= cx1; ++cx) {
			const AIFloat3 p((2 * cx + dx) * half, 0.f, (2 * cz + dz) * half);
			const float sq = p.SqDistance2D(pos);
			if (sq > radiusSq) {
				continue;
			}
			const int ox = (mx - dx) / 2, oz = (mz - dz) / 2;
			const int2 m1(std::max(0, cx - ox), std::max(0, cz - oz));
			const int2 m2(std::min(blockingMap.columns, cx - ox + mx), std::min(blockingMap.rows, cz - oz + mz));
			if (!IsReservationFree(m1, m2)) {
				continue;
			}
			cands.push_back(SCand{p, sq});
		}
	}
	std::sort(cands.begin(), cands.end(), [](const SCand& a, const SCand& b) { return a.sq < b.sq; });
	CMap* map = circuit->GetMap();
	int tried = 0;
	for (const SCand& c : cands) {
		if (++tried > PACK_NEAR_POINT_TRIES) {  // D-121: was 400 (Tundra: the 400 nearest free cells were all slopes)
			break;
		}
		AIFloat3 p = c.pos;
		p.y = map->GetElevationAt(p.x, p.z);
		if (!CanBeBuiltAt(cdef, p) || !map->IsPossibleToBuildAt(unitDef, p, facing) || !predicate(p)) {
			continue;
		}
		if (!cdef->IsMobile() && cdef->IsBuilder() && !IsExitClear(cdef, p, facing, EXIT_CLEAR_LENGTH, EXIT_CLEAR_MARGIN)) {
			continue;  // D-074
		}
		const int id = ReserveBuildingEx(cdef, p, facing, 0, 0, true, true, false, 0, true);
		if (id < 0) {
			continue;
		}
		// Served at once, like a planned slot: the task takes the id and the
		// registry forgets it when the structure stands.
		auto it = reservations.find(id);
		int2 c1, c2;
		if ((it != reservations.end()) && ReservationCells(cdef, it->second.pos, it->second.facing, c1, c2)) {
			UnmarkSlot(c1, c2);
			it->second.consumed = true;
			IndexLocalSlot(it->first);
			it->second.claimed = true;
			lastReservedId = id;
			lastReservedFacing = it->second.facing;
			circuit->LOG("RESERVE: packed %s near (%.0f, %.0f) at (%.0f, %.0f), %.0f away (id %i, %i candidates)",
					unitDef->GetName(), pos.x, pos.z, it->second.pos.x, it->second.pos.z, std::sqrt(c.sq), id, int(cands.size()));
			return it->second.pos;
		}
	}
	circuit->LOG("RESERVE: no site for %s within %.0f of (%.0f, %.0f) (%i candidates, %i tried)",
			unitDef->GetName(), radius, pos.x, pos.z, int(cands.size()), tried);
	return -RgtVector;
}

AIFloat3 CTerrainManager::FindDropSpot(CCircuitUnit* cargo, const AIFloat3& around, float maxRadius,
		const std::vector<AIFloat3>& avoid, float avoidRadius, float maxSurfaceThreat, float maxAirThreat)
{
	if (cargo == nullptr) {
		return -RgtVector;
	}
	const SBlockingMap::SM solid = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	CMap* map = circuit->GetMap();
	SMobileType* cargoMove = GetMobileTypeById(cargo->GetCircuitDef()->GetMobileId());
	std::vector<layout_rank::Pt> refused;  // D-091 via D-094
	for (const AIFloat3& q : avoid) {
		refused.push_back(ToPt(q));
	}
	// rings every 32 elmos, 16 bearings a ring: the nearest acceptable point wins
	for (const layout_rank::Pt& rp : layout_rank::RingOrder(ToPt(around), maxRadius, 32.f, 16)) {
		{
			AIFloat3 p(rp.x, 0.f, rp.z);
			CorrectPosition(p);
			p.y = map->GetElevationAt(p.x, p.z);
			if ((maxSurfaceThreat >= 0.f && circuit->GetThreatMap()->GetSurfThreatAtPos(p) > maxSurfaceThreat)
					|| (maxAirThreat >= 0.f && circuit->GetThreatMap()->GetAirThreatAtPos(p) > maxAirThreat)) {
				continue;
			}
			if (!layout_rank::ClearOf(ToPt(p), refused, avoidRadius)) {
				continue;
			}
			// the cell and its neighbours free of structures and reservations (a
			// unit set down needs room; the engine refused spots between buildings)
			const int cx = int(p.x) / (SQUARE_SIZE * 2), cz = int(p.z) / (SQUARE_SIZE * 2);
			bool blocked = false;
			for (int dz = -1; dz <= 1 && !blocked; ++dz) {
				for (int dx = -1; dx <= 1 && !blocked; ++dx) {
					if (!blockingMap.IsInBounds(cx + dx, cz + dz) || blockingMap.IsBlocked(cx + dx, cz + dz, solid)) {
						blocked = true;
					}
				}
			}
			if (blocked) {
				continue;
			}
			// A ferry can cross disconnected land areas. Test standing room for
			// the cargo's move type, not reachability from its pre-flight area.
			const int sector = GetSectorIndex(p);
			if (!terrainData->IsSectorValid(sector)
					|| (cargoMove != nullptr && cargoMove->sector[sector].area == nullptr)) {
				continue;
			}
			if (!cargo->GetCircuitDef()->IsAbleToSwim() && !cargo->GetCircuitDef()->IsAmphibious() && (p.y < 0.f)) {
				continue;  // a land unit is not set down in water
			}
			return p;
		}
	}
	return -RgtVector;
}

AIFloat3 CTerrainManager::FindApproachPoint(CCircuitUnit* unit, const AIFloat3& site, float radius)
{
	if ((unit == nullptr) || (radius <= 0.f)) {
		return -RgtVector;
	}
	const int frame = circuit->GetLastFrame();
	const AIFloat3& from = unit->GetPos(frame);
	float dx = from.x - site.x, dz = from.z - site.z;
	const float len = std::sqrt(dx * dx + dz * dz);
	if (len < 1.f) {
		dx = 1.f; dz = 0.f;
	} else {
		dx /= len; dz /= len;
	}
	const SBlockingMap::SM walkable = static_cast<SBlockingMap::SM>(
			static_cast<unsigned short>(SBlockingMap::StructMask::ALL) & ~static_cast<unsigned short>(SBlockingMap::StructMask::RESERVED));
	// D-109 (played: builders parked on the neighbouring planned turret slots
	// of a spam lab, and the engine dropped every build command there): off
	// reserved ground first; reserved ground only when nothing else is in reach
	const SBlockingMap::SM solid = static_cast<SBlockingMap::SM>(static_cast<unsigned short>(SBlockingMap::StructMask::ALL));
	CMap* map = circuit->GetMap();
	for (int pass = 0; pass < 2; ++pass) {
		const SBlockingMap::SM mask = (pass == 0) ? solid : walkable;
		for (int k = 0; k < 16; ++k) {
			// 0, +22.5, -22.5, +45, -45, ... degrees off the unit's own bearing
			const float a = 0.3926991f * float((k + 1) / 2) * ((k % 2 == 0) ? 1.f : -1.f);
			const float c = std::cos(a), s = std::sin(a);
			AIFloat3 p(site.x + (dx * c - dz * s) * radius, 0.f, site.z + (dx * s + dz * c) * radius);
			CorrectPosition(p);
			p.y = map->GetElevationAt(p.x, p.z);
			const int cx = int(p.x) / (SQUARE_SIZE * 2), cz = int(p.z) / (SQUARE_SIZE * 2);
			if (!blockingMap.IsInBounds(cx, cz) || blockingMap.IsBlocked(cx, cz, mask)) {
				continue;
			}
			if (!CanMoveToPos(unit->GetArea(), p)) {
				continue;
			}
			return p;
		}
	}
	return -RgtVector;
}

int CTerrainManager::NextSlotConnected(int group, const AIFloat3& centre) const
{
	SSlowCall slow("NextSlotConnected", circuit);
	// D-077/D-081, ranked by layout_rank::NextConnected (D-094)
	std::vector<layout_rank::Pt> taken, freeSlots;
	std::vector<int> freeIds;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if (r.group != group) {
			continue;
		}
		if (r.consumed || r.claimed || (r.serveFails >= kDeadSlotFails)) {
			taken.push_back(ToPt(r.pos));
		} else {
			freeSlots.push_back(ToPt(r.pos));
			freeIds.push_back(r.id);
		}
	}
	const int k = layout_rank::NextConnected(freeSlots, taken, ToPt(centre));
	return (k < 0) ? -1 : freeIds[k];
}

int CTerrainManager::NextSlotAny(int group, const AIFloat3& anchor) const
{
	int best = -1;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.group != group) || r.consumed || r.claimed || (r.serveFails >= kDeadSlotFails)) {
			continue;
		}
		const float sq = anchor.SqDistance2D(r.pos);
		if (sq < bestSq) {
			bestSq = sq;
			best = r.id;
		}
	}
	return best;
}

/*
 * Turret box packing (D-063). Every candidate footprint inside the zone,
 * nearest to the turret rows first, so the base grows outward from its
 * construction turrets and never beyond their reach.
 */
std::vector<CTerrainManager::SPackCandidate> CTerrainManager::PackCandidates(int zone, CCircuitDef* cdef, int nanoGroup,
        int facing, const AIFloat3& anchor, float maxReach, float minNanoDist, bool alwaysRing) const
{
    // Cache ONLY empty pure geometry results, never engine terrain/threat or
    // builder admission. Same-frame scope covers moving positions; all local
    // blocker/reservation writers, allied writes and team membership invalidate.
    // Positive ordering and every engine buildability check remain untouched.
    const auto allyRevision = circuit->GetAllyTeam()->GetLayoutReservations().Revision();
    const auto ownedRevision = circuit->GetOwnedUnitRevision();
    const int frame = circuit->GetLastFrame();
    if (emptyPackFrame != frame || emptyPackRevision != packingRevision
        || emptyPackAllyRevision != allyRevision || emptyPackOwnedRevision != ownedRevision) {
        emptyPackQueries.clear(); emptyPackFrame=frame; emptyPackRevision=packingRevision;
        emptyPackAllyRevision=allyRevision; emptyPackOwnedRevision=ownedRevision;
    }
    if (!cdef || !std::isfinite(maxReach) || !std::isfinite(minNanoDist))
        return ComputePackCandidates(zone,cdef,nanoGroup,facing,anchor,maxReach,minNanoDist,alwaysRing);
    // Anchor only sorts nonempty results and cannot affect emptiness.
    const EmptyPackKey key{zone,cdef->GetId(),nanoGroup,facing,maxReach,minNanoDist,alwaysRing};
    if (emptyPackQueries.count(key)) {
        static const bool verify = std::getenv("CIRCUIT_VERIFY_EMPTY_PACK") != nullptr;
        // Correctness runs re-evaluate cache hits against the original search.
        // Never enable this oracle in timing runs: it deliberately repeats work.
        if (verify) {
            auto oracle = ComputePackCandidates(zone,cdef,nanoGroup,facing,anchor,maxReach,minNanoDist,alwaysRing);
            if (!oracle.empty()) {
                circuit->LOG("[INVARIANT] empty packing cache diverged");
                return oracle;
            }
        }
        return {};
    }
    auto result=ComputePackCandidates(zone,cdef,nanoGroup,facing,anchor,maxReach,minNanoDist,alwaysRing);
    if (result.empty()) emptyPackQueries.insert(key);
    return result;
}

std::vector<CTerrainManager::SPackCandidate> CTerrainManager::ComputePackCandidates(int zone, CCircuitDef* cdef, int nanoGroup,
		int facing, const AIFloat3& anchor, float maxReach, float minNanoDist, bool alwaysRing) const
{
	performance::Scope measured(circuit, performance::PACK_CANDIDATES);
	std::vector<SPackCandidate> out;
	if (!layoutEnabled || (cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return out;
	}
	auto zit = zones.find(zone);
	if ((zit == zones.end()) || zit->second.corridor) {
		return out;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	// D-083 (owner's rule): a structure goes in range of a turret that stands or
	// is being built first, and only then where a turret is merely planned: a
	// planned slot counts as PLANNED_SLOT_PENALTY elmos further than it is.
	constexpr float PLANNED_SLOT_PENALTY = 256.f;
	std::vector<std::pair<AIFloat3, bool>> nanos;  // slot position, served (consumed)
	float reach = maxReach;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if (r.group != nanoGroup) {
			continue;
		}
		nanos.emplace_back(r.pos, r.consumed);
		if ((reach <= 0.f) && (r.def != nullptr)) {
			reach = r.def->GetBuildDistance();
		}
	}
	if (nanos.empty() || (reach <= 0.f)) {
		return out;
	}
	const SZone& z = zit->second;
	UnitDef* unitDef = cdef->GetDef();
	const int dx = (((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;
	const int dz = (((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;
	if ((dx <= 0) || (dz <= 0)) {
		return out;
	}
	const float reachSq = SQUARE(reach);
	const float minSq = SQUARE(std::max(0.f, minNanoDist));
	const float half = base_layout::HALF_CELL_ELMOS;
	// Same-def grouping (D-066 follow-up): the winds go next to the winds, the
	// converters next to the converters. The group's members are the standing
	// structures of this def and its planned slots inside the zone.
	std::vector<AIFloat3> same;
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.def == cdef) && (r.zone == zone)) {
			same.push_back(r.pos);
		}
	}
	{
		const int frame = circuit->GetLastFrame();
		for (const auto& kv : circuit->GetTeamUnits()) {
			CCircuitUnit* unit = kv.second;
			if ((unit != nullptr) && !unit->IsDead() && (unit->GetCircuitDef() == cdef)) {
				const AIFloat3& p = unit->GetPos(frame);
				if (ZoneAt(int(p.x) / (SQUARE_SIZE * 2), int(p.z) / (SQUARE_SIZE * 2)) == zone) {
					same.push_back(p);
				}
			}
		}
	}
	std::vector<layout_rank::Pt> samePts;  // D-088 via D-094
	for (const AIFloat3& s : same) {
		samePts.push_back(ToPt(s));
	}
	const layout_rank::Pt sameCentroid = layout_rank::Centroid(samePts, layout_rank::Pt{});
	// D-096 (played: windmills packed across the advanced lab's exit): no footprint
	// in a planned or standing factory's exit lane; the zone's corridor could not
	// hold these cells, the zone already does
	const std::vector<layout_rank::CellRect> lanes = FactoryExitLanes();
	// D-099 (owner: the box need not grow, there is buildable ground around the
	// turrets): the zone first; when nothing in it is left, the ring of ground
	// around it within a turret's reach of a slot (free ground only: another
	// plan's zone, a structure or a factory's exit refuse, as inside)
	auto scan = [&](const int2& a1, const int2& a2, bool ring) {
		for (int cz = a1.y; cz + dz <= a2.y; ++cz) {
			for (int cx = a1.x; cx + dx <= a2.x; ++cx) {
				if (ring && layout_rank::Inside(layout_rank::CellRect{cx, cz, cx + dx, cz + dz},
						layout_rank::CellRect{z.c1.x, z.c1.y, z.c2.x, z.c2.y})) {
					continue;  // scanned with the zone
				}
				const AIFloat3 pos((2 * cx + dx) * half, 0.f, (2 * cz + dz) * half);
				float nearSq = std::numeric_limits<float>::max();   // the nearest slot of any kind: the reach test
				float builtSq = std::numeric_limits<float>::max();  // the nearest served slot
				float plannedSq = std::numeric_limits<float>::max();
				bool tooClose = false;
				for (const auto& n : nanos) {
					const float sq = pos.SqDistance2D(n.first);
					if (sq < minSq) {
						tooClose = true;
						break;
					}
					nearSq = std::min(nearSq, sq);
					if (n.second) {
						builtSq = std::min(builtSq, sq);
					} else {
						plannedSq = std::min(plannedSq, sq);
					}
				}
				if (tooClose || (nearSq > reachSq)) {
					continue;
				}
				nearSq = layout_rank::TurretDistanceSq(builtSq, plannedSq, PLANNED_SLOT_PENALTY);  // D-083 via D-094
				if (!IsSlotFree(int2(cx, cz), int2(cx + dx, cz + dz), zone, -1)) {
					continue;
				}
				if (layout_rank::OverlapsAny(layout_rank::CellRect{cx, cz, cx + dx, cz + dz}, lanes)) {
					continue;  // D-096
				}
				// D-088: nearest the centroid of the group, not nearest any member: nearest
				// member grows a line (played: the turbines formed an L); the centroid grows
				// a filled block whose free edge cells are always the nearest
				const float sameSq = same.empty() ? std::numeric_limits<float>::max() : layout_rank::Sq(ToPt(pos), sameCentroid);
				out.push_back(SPackCandidate{pos, nearSq, anchor.SqDistance2D(pos), sameSq});
			}
		}
	};
	scan(z.c1, z.c2, false);
	// D-104: a flush pick scans the ring always (played: the turret block's open
	// front side lies outside its zone and was never offered to a factory)
	if (out.empty() || alwaysRing) {
		const int r = int(std::ceil(reach / (SQUARE_SIZE * 2)));
		const int2 r1(std::max(0, z.c1.x - r), std::max(0, z.c1.y - r));
		const int2 r2(std::min(blockingMap.columns, z.c2.x + r), std::min(blockingMap.rows, z.c2.y + r));
		scan(r1, r2, true);
	}
	const bool grouped = !same.empty();
	std::sort(out.begin(), out.end(), [grouped](const SPackCandidate& a, const SPackCandidate& b) {
		return layout_rank::PackBefore(layout_rank::PackKey{a.nanoSq, a.anchorSq, a.sameSq},
				layout_rank::PackKey{b.nanoSq, b.anchorSq, b.sameSq}, grouped);  // D-066/D-088 via D-094
	});
	return out;
}

bool CTerrainManager::LeavesPocket(int zone, CCircuitDef* cdef, const AIFloat3& pos, int facing) const
{
	performance::Scope measured(circuit, performance::POCKET);
	SSlowCall slow("LeavesPocket", circuit);
	// D-072: a constructor was walled in by a turbine cluster. Every free cell
	// of the zone must stay connected to the zone's edge once this footprint
	// stands; planned slots count as standing (they will).
	auto zit = zones.find(zone);
	if ((zit == zones.end()) || (cdef == nullptr)) {
		return false;
	}
	const SZone& zone0 = zit->second;
	int2 f1, f2;
	if (!ReservationCells(cdef, pos, facing, f1, f2)) {
		return false;
	}
	// D-090: a footprint can only cut off cells near it; the flood fill runs in a
	// window of POCKET_WINDOW cells around the footprint (clipped to the zone),
	// the window's border counting as open ground (played: 1,100 whole-zone
	// fills of a halo zone at 37 ms each, the stutter)
	constexpr int POCKET_WINDOW = 8;
	struct { int2 c1, c2; } z;
	// D-099: clipped to the map, not the zone: a site in the ring around the zone
	// stands outside it, and ground outside the zone can be walled in too
	(void)zone0;
	z.c1 = int2(std::max(0, f1.x - POCKET_WINDOW), std::max(0, f1.y - POCKET_WINDOW));
	z.c2 = int2(std::min(blockingMap.columns, f2.x + POCKET_WINDOW), std::min(blockingMap.rows, f2.y + POCKET_WINDOW));
	const int w = z.c2.x - z.c1.x;
	const int h = z.c2.y - z.c1.y;
	if ((w <= 0) || (h <= 0)) {
		return false;
	}
	std::vector<char> open(w * h, 0);
	for (int cz = z.c1.y; cz < z.c2.y; ++cz) {
		for (int cx = z.c1.x; cx < z.c2.x; ++cx) {
			const bool inFoot = (cx >= f1.x) && (cx < f2.x) && (cz >= f1.y) && (cz < f2.y);
			open[(cz - z.c1.y) * w + (cx - z.c1.x)] = (!inFoot && IsSlotFree(int2(cx, cz), int2(cx + 1, cz + 1), zone, -1)) ? 1 : 0;
		}
	}
	return layout_rank::LeavesPocket(open, w, h);  // D-072/D-090 via D-094
}

int CTerrainManager::CountGroupSlotsWithin(int group, const AIFloat3& pos, float radius) const
{
	int n = 0;
	const float sq = SQUARE(radius);
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.group == group) && (r.pos.SqDistance2D(pos) <= sq)) {
			++n;
		}
	}
	return n;
}

bool CTerrainManager::ExitLaneCells(CCircuitDef* cdef, const AIFloat3& pos, int facing, float length, float margin, int2& c1, int2& c2) const
{
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return false;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	UnitDef* unitDef = cdef->GetDef();
	const float width = ((((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2) * (SQUARE_SIZE * 2);
	const float depth = ((((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2) * (SQUARE_SIZE * 2);
	const layout_rank::Pt f = layout_rank::FacingForward(facing);
	const AIFloat3 fwd(f.x, 0.f, f.z);
	const AIFloat3 centre = pos + fwd * (depth * 0.5f + length * 0.5f);
	return RectCells(centre, facing, width * 0.5f + margin, length * 0.5f, c1, c2);
}

std::vector<layout_rank::CellRect> CTerrainManager::FactoryExitLanes() const
{
	std::vector<layout_rank::CellRect> lanes;
	auto add = [&](CCircuitDef* d, const AIFloat3& p, int f) {
		int2 c1, c2;
		if (ExitLaneCells(d, p, f, EXIT_CLEAR_LENGTH, EXIT_CLEAR_MARGIN, c1, c2)) {
			lanes.push_back(layout_rank::CellRect{c1.x, c1.y, c2.x, c2.y});
		}
	};
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if ((r.def != nullptr) && !r.def->IsMobile() && r.def->IsBuilder()) {
			add(r.def, r.pos, r.facing);
		}
	}
	const int frame = circuit->GetLastFrame();
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* u = kv.second;
		if ((u == nullptr) || u->IsDead() || (u->GetCircuitDef() == nullptr)) {
			continue;
		}
		CCircuitDef* d = u->GetCircuitDef();
		if (!d->IsMobile() && d->IsBuilder()) {
			add(d, u->GetPos(frame), u->GetUnit()->GetBuildingFacing());
		}
	}
	return lanes;
}

int CTerrainManager::GetBuildingFacing(CCircuitUnit* unit) const
{
	return (unit == nullptr) ? -1 : unit->GetUnit()->GetBuildingFacing();
}

int CTerrainManager::CountStructuresInExit(CCircuitUnit* factory) const
{
	if ((factory == nullptr) || (factory->GetCircuitDef() == nullptr)) {
		return 0;
	}
	const int frame = circuit->GetLastFrame();
	int2 c1, c2;
	if (!ExitLaneCells(factory->GetCircuitDef(), factory->GetPos(frame), factory->GetUnit()->GetBuildingFacing(),
			EXIT_CLEAR_LENGTH, EXIT_CLEAR_MARGIN, c1, c2)) {
		return 0;
	}
	const layout_rank::CellRect lane{c1.x, c1.y, c2.x, c2.y};
	const float cell = SQUARE_SIZE * 2;
	int n = 0;
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* u = kv.second;
		if ((u == nullptr) || (u == factory) || u->IsDead() || (u->GetCircuitDef() == nullptr) || u->GetCircuitDef()->IsMobile()) {
			continue;
		}
		if (u->GetCircuitDef()->IsMex() || (u->GetCircuitDef()->GetExtractsM() > 0.f)) {
			continue;  // D-099: an extractor stands where the map's metal spot is, and a 3x3 does not wall a lab in
		}
		UnitDef* ud = u->GetCircuitDef()->GetDef();
		const int f = u->GetUnit()->GetBuildingFacing();
		const float hx = (((f & 1) == 0) ? ud->GetXSize() : ud->GetZSize()) * SQUARE_SIZE * 0.5f;
		const float hz = (((f & 1) == 0) ? ud->GetZSize() : ud->GetXSize()) * SQUARE_SIZE * 0.5f;
		const AIFloat3 p = u->GetPos(frame);
		const layout_rank::CellRect r{int(std::floor((p.x - hx) / cell)), int(std::floor((p.z - hz) / cell)),
				int(std::ceil((p.x + hx) / cell)), int(std::ceil((p.z + hz) / cell))};
		if (layout_rank::Overlaps(r, lane)) {
			++n;
		}
	}
	return n;
}

bool CTerrainManager::IsExitClear(CCircuitDef* cdef, const AIFloat3& pos, int facing, float length, float margin) const
{
	SSlowCall slow("IsExitClear", circuit);
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return true;
	}
	if ((facing < 0) || (facing > 3)) {
		facing = UNIT_FACING_SOUTH;
	}
	int2 c1, c2;
	if (!ExitLaneCells(cdef, pos, facing, length, margin, c1, c2)) {
		return false;
	}
	for (int z = c1.y; z < c2.y; ++z) {
		for (int x = c1.x; x < c2.x; ++x) {
			// D-092: a layout zone marks every cell RESERVED; that mark alone is open
			// ground (planned slots are tested below by their reservations). Played:
			// no advanced lab inside the block's halo ever had a clear exit, so it went
			// to the pair's slot away from the turrets.
			if (!blockingMap.IsInBounds(x, z) || (blockingMap.IsStruct(x, z) && !blockingMap.IsReserved(x, z))) {
				return false;
			}
		}
	}
	// planned slots (any group) whose footprint overlaps the exit
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		if (r.def == nullptr) {
			continue;
		}
		int2 r1, r2;
		if (!ReservationCells(r.def, r.pos, r.facing, r1, r2)) {
			continue;
		}
		if ((r1.x < c2.x) && (r2.x > c1.x) && (r1.y < c2.y) && (r2.y > c1.y)) {
			return false;
		}
	}
	return true;
}

int CTerrainManager::PickMost(int zone, CCircuitDef* cdef, int nanoGroup, int facing, float reach, float flush, const AIFloat3& seed, AIFloat3& outPos) const
{
	constexpr int SERVED_SLOT_WEIGHT = 3;  // D-085
	// D-085 (played): with every slot planned, the count alone sent the lab to the
	// far edge; a planned slot counts only within SEED_SLOT_RADIUS of the seed, the
	// slots the block fills first. When none is, every planned slot counts.
	constexpr float SEED_SLOT_RADIUS = 560.f;
	// D-087: enough build power is enough; past LAB_SLOTS_ENOUGH the site nearest
	// the seed wins (played: the most-reached site was 1,139 elmos from the seed)
	constexpr int LAB_SLOTS_ENOUGH = 8;
	auto zit = zones.find(zone);
	if ((zit == zones.end()) || (cdef == nullptr)) {
		return -1;
	}
	const SZone& z = zit->second;
	const float half = base_layout::HALF_CELL_ELMOS;
	const AIFloat3 centre((z.c1.x + z.c2.x) * half, 0.f, (z.c1.y + z.c2.y) * half);
	// every free footprint in the zone within a slot's reach of some slot: the candidates the packer would consider
	const std::vector<SPackCandidate> cands = PackCandidates(zone, cdef, nanoGroup, facing, centre, 0.f, 0.f);
	if (cands.empty()) {
		return -1;
	}
	std::vector<layout_rank::Slot> slots;  // D-085 via D-094
	std::vector<layout_rank::Pt> slotPts;  // D-095
	for (const auto& kv : reservations) {
		if (kv.second.group == nanoGroup) {
			slots.push_back(layout_rank::Slot{ToPt(kv.second.pos), kv.second.consumed});
			slotPts.push_back(ToPt(kv.second.pos));
		}
	}
	// KI-419 (D-083): the cheap score first for every candidate, the dear tests
	// (the engine's build test, the pocket flood fill, the exit cone) only down
	// the ranked list until one passes (played: 8.5 s for one advanced lab).
	std::vector<layout_rank::SiteKey> ranked;
	ranked.reserve(cands.size());
	for (const SPackCandidate& c : cands) {
		const int n = layout_rank::WeightedSlots(ToPt(c.pos), slots, reach, ToPt(seed), SEED_SLOT_RADIUS, SERVED_SLOT_WEIGHT);
		ranked.push_back(layout_rank::MakeSiteKey(ToPt(c.pos), n, LAB_SLOTS_ENOUGH, ToPt(seed), c.nanoSq,
				layout_rank::NearestSq(ToPt(c.pos), slotPts), flush,  // D-095: flush with a slot before nearer the seed
				layout_rank::AheadOf(ToPt(c.pos), slotPts, layout_rank::FacingForward(facing))));  // D-096: the front side first
	}
	std::sort(ranked.begin(), ranked.end(), layout_rank::SiteBefore);
	// no try cap (played: the best-ranked sites inside the block all face planned
	// slots and fail the exit test; 400 of them exhausted the cap and the lab
	// fell back to the pair's slot); the exit test is cheap and the flood fill
	// runs only for sites that pass it
	for (const layout_rank::SiteKey& r : ranked) {
		const AIFloat3 site(r.pos.x, 0.f, r.pos.z);
		AIFloat3 cp = site;
		cp.y = circuit->GetMap()->GetElevationAt(cp.x, cp.z);
		if (!circuit->GetMap()->IsPossibleToBuildAt(cdef->GetDef(), cp, facing)) {
			continue;
		}
		if (!cdef->IsMobile() && cdef->IsBuilder() && !IsExitClear(cdef, site, facing, EXIT_CLEAR_LENGTH, EXIT_CLEAR_MARGIN)) {
			continue;  // D-074: a factory's exit stays clear of structures and planned slots (cheap: before the flood fill)
		}
		if (LeavesPocket(zone, cdef, site, facing)) {
			continue;
		}
		outPos = site;
		return r.slots;
	}
	return -1;
}

int CTerrainManager::PackNearGroupMost(int zone, CCircuitDef* cdef, int nanoGroup, int facing, float reach, float flush, int group, const AIFloat3& seed)
{
	SSlowCall slow("PackNearGroupMost", circuit);
	AIFloat3 pos;
	const int score = PickMost(zone, cdef, nanoGroup, facing, reach, flush, seed, pos);
	if (score < 0) {
		return -1;
	}
	pos.y = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
	// like PackNearGroup: the slot stays armed for the pinned task's own search
	const int id = ReserveBuildingEx(cdef, pos, facing, 0, group, true, true, false, zone, true);
	if (id < 0) {
		return -1;
	}
	circuit->LOG("RESERVE: packed %s at (%.0f, %.0f) facing %i in zone %i where %i slots of group %i reach (id %i)",
			cdef->GetDef()->GetName(), pos.x, pos.z, facing, zone, score, nanoGroup, id);
	return id;
}

int CTerrainManager::PackNearBuiltPower(int zone, CCircuitDef* cdef, int nanoGroup, int facing,
		const AIFloat3& anchor, float margin)
{
	// Opt-in mechanism: policy chooses the project and safety margin. Existing
	// placement callers and ranking are untouched. Snapshot owned completed
	// static assistants once, on the AI thread; never query wrappers per candidate.
	if (cdef == nullptr || !std::isfinite(margin) || margin < 0.f
			|| !std::isfinite(anchor.x) || !std::isfinite(anchor.z)) return -1;
	performance::Scope measured(circuit, performance::PACK_GROUP);
	SSlowCall slow("PackNearBuiltPower", circuit);
	std::vector<layout_rank::BuiltPower> power;
	const int frame = circuit->GetLastFrame();
	for (const auto& [id, unit] : circuit->GetTeamUnits()) {
		if (unit == nullptr || unit->IsDead()) continue;
		const auto* def = unit->GetCircuitDef();
		if (def == nullptr || def->IsMobile() || !def->IsAbleToAssist()
				|| unit->GetUnit()->IsBeingBuilt() || def->GetBuildDistance() <= margin) continue;
		const AIFloat3 pos = unit->GetPos(frame);
		power.push_back({{pos.x, pos.z}, SQUARE(def->GetBuildDistance() - margin), def->GetBuildSpeed()});
	}
	if (power.empty()) return -1;
	// Reuse authoritative zone, reservations, allied-space and exit exclusions.
	// O(N + C*T + C log C), only on a new placement attempt, not per frame.
	const auto candidates = PackCandidates(zone, cdef, nanoGroup, facing, anchor, 0.f, 0.f, true);
	struct Site { AIFloat3 pos; float power; float distance; };
	std::vector<Site> sites;
	sites.reserve(candidates.size());
	for (const auto& candidate : candidates) {
		const float sum = layout_rank::PowerAt({candidate.pos.x, candidate.pos.z}, power);
		if (sum > 0.f) sites.push_back({candidate.pos, sum, candidate.anchorSq});
	}
	std::stable_sort(sites.begin(), sites.end(), [](const Site& a, const Site& b) {
		return layout_rank::BuiltPowerBefore(a.power, a.distance, b.power, b.distance);
	});
	int tried = 0;
	for (auto& site : sites) {
		if (++tried > 400) break;
		site.pos.y = circuit->GetMap()->GetElevationAt(site.pos.x, site.pos.z);
		if (!IsEngineBuildable(cdef, site.pos, facing) || LeavesPocket(zone, cdef, site.pos, facing)) continue;
		const int slot = ReserveBuildingEx(cdef, site.pos, facing, 0, 0, true, true, false, zone, true);
		if (slot >= 0) {
			circuit->LOG("RESERVE: live power %s at (%.0f, %.0f), %.0f BP/s (id %i)",
					cdef->GetDef()->GetName(), site.pos.x, site.pos.z, site.power * FRAMES_PER_SEC, slot);
			return slot;
		}
	}
	return -1;
}

int CTerrainManager::PackNearGroup(int zone, CCircuitDef* cdef, int nanoGroup, int facing, const AIFloat3& anchor,
		float maxReach, float minNanoDist, int group)
{
	performance::Scope measured(circuit, performance::PACK_GROUP);
	SSlowCall slow("PackNearGroup", circuit);
	constexpr int POCKET_TESTS_MAX = 40;  // D-090
	int pocketTests = 0;
	const std::vector<SPackCandidate> candidates = PackCandidates(zone, cdef, nanoGroup, facing, anchor, maxReach, minNanoDist);
	int tried = 0;
	for (const SPackCandidate& c : candidates) {
		if (++tried > 400) {
			break;  // the zone is full of refused ground; say so below
		}
		AIFloat3 pos = c.pos;
		pos.y = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
		if (!circuit->GetMap()->IsPossibleToBuildAt(cdef->GetDef(), pos, facing)) {
			continue;  // D-073: the engine's own test; a box's unflat part refused an advanced fusion at serve time
		}
		if (!cdef->IsMobile() && cdef->IsBuilder() && !IsExitClear(cdef, c.pos, facing, EXIT_CLEAR_LENGTH, EXIT_CLEAR_MARGIN)) {
			continue;  // D-086: a factory packed nearest a turret keeps its exit clear (D-074)
		}
		if ((++pocketTests <= POCKET_TESTS_MAX) && LeavesPocket(zone, cdef, pos, facing)) {
			continue;  // D-072: never wall off free cells inside the box (D-090: at most POCKET_TESTS_MAX tests a call)
		}
		const int id = ReserveBuildingEx(cdef, pos, facing, 0, group, true, true, false, zone, true);
		if (id >= 0) {
			circuit->LOG("RESERVE: packed %s at (%.0f, %.0f) facing %i in zone %i, %.0f from a turret (id %i, group %i, %i candidates)",
					cdef->GetDef()->GetName(), pos.x, pos.z, facing, zone, std::sqrt(c.nanoSq), id, group, int(candidates.size()));
			return id;
		}
	}
	circuit->LOG("RESERVE: no room for %s in zone %i (%i candidates, %i tried)",
			cdef->GetDef()->GetName(), zone, int(candidates.size()), tried);
	return -1;
}

bool CTerrainManager::CanPackNearGroup(int zone, CCircuitDef* cdef, int nanoGroup, int facing, float maxReach, float minNanoDist)
{
	performance::Scope measured(circuit, performance::CAN_PACK);
	SSlowCall slow("CanPackNearGroup", circuit);
	const std::vector<SPackCandidate> candidates = PackCandidates(zone, cdef, nanoGroup, facing, ZeroVector, maxReach, minNanoDist);
	int tried = 0;
	for (const SPackCandidate& c : candidates) {
		if (++tried > 40) {  // D-083: a yes/no asked many times a second; forty tries answer it
			break;
		}
		AIFloat3 pos = c.pos;
		pos.y = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
		if (CanBeBuiltAt(cdef, pos)) {
			return true;
		}
	}
	return false;
}

AIFloat3 CTerrainManager::GetReservationPos(int id) const
{
	auto it = reservations.find(id);
	return (it == reservations.end()) ? AIFloat3(-RgtVector) : it->second.pos;
}

bool CTerrainManager::IsSlotDead(int id) const
{
	auto it = reservations.find(id);
	return (it != reservations.end()) && (it->second.serveFails >= kDeadSlotFails);
}

int CTerrainManager::GetReservationFacing(int id) const
{
	auto it = reservations.find(id);
	return (it == reservations.end()) ? -1 : it->second.facing;
}

CCircuitUnit* CTerrainManager::GetReservationUnit(int id) const
{
	auto it = reservations.find(id);
	if ((it == reservations.end()) || (it->second.unitId == 0)) {
		return nullptr;
	}
	return circuit->GetTeamUnit(it->second.unitId);
}

float CTerrainManager::FlatFraction(const AIFloat3& centre, int facing, float halfAcross, float halfAlong, float maxSlope) const
{
	SSlowCall slow("FlatFraction", circuit);
	const auto& slopes = terrainData->GetSlopeMap();
	const int xsize = terrainData->GetSlopeMapXSize();
	if (slopes.empty() || (xsize <= 0)) {
		return 1.f;
	}
	const int zsize = int(slopes.size()) / xsize;
	const float hx = ((facing & 1) == 0) ? halfAcross : halfAlong;
	const float hz = ((facing & 1) == 0) ? halfAlong : halfAcross;
	const float step = SQUARE_SIZE * 2;
	int total = 0, flat = 0;
	for (float dz = -hz; dz <= hz; dz += step) {
		for (float dx = -hx; dx <= hx; dx += step) {
			++total;
			const int xs = int(centre.x + dx) / (SQUARE_SIZE * 2);
			const int zs = int(centre.z + dz) / (SQUARE_SIZE * 2);
			if ((xs < 0) || (zs < 0) || (xs >= xsize) || (zs >= zsize)) {
				continue;  // off the map is not flat
			}
			if (slopes[zs * xsize + xs] <= maxSlope) {
				++flat;
			}
		}
	}
	return (total > 0) ? float(flat) / float(total) : 0.f;
}

std::string CTerrainManager::DescribeLayout() const
{
	std::string out = resourceLayout;
	char buf[160];
	const int cell = SQUARE_SIZE * 2;
	for (const auto& kv : zones) {
		const SZone& zn = kv.second;
		snprintf(buf, sizeof(buf), "%s:%i:%i:%i:0:%i:%i:z;", zn.corridor ? "corridor" : "zone", zn.id,
				(zn.c1.x + zn.c2.x) * cell / 2, (zn.c1.y + zn.c2.y) * cell / 2, (zn.c2.x - zn.c1.x) * cell, (zn.c2.y - zn.c1.y) * cell);
		out += buf;
	}
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		UnitDef* unitDef = r.def->GetDef();
		// Only the opt-in observer pays for this independent footprint audit.
		// It also detects incompatible saved plans without silently moving an
		// active construction task. The played probe separately verifies allied
		// resource cutout access inside the surrounding zone envelopes.
		if (IsResourceFootprintBlocked(r.def, r.pos, r.facing)) {
			circuit->LOG("[INVARIANT] INV-172 reserved footprint overlaps a resource site: %i", r.id);
		}
		const int w = (((r.facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2 * cell;
		const int d = (((r.facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2 * cell;
		const char state = (r.unitId != 0) ? 'b' : (r.consumed ? 's' : (r.claimed ? 'c' : (r.armed ? 'p' : 'h')));
		snprintf(buf, sizeof(buf), "slot:%s:%i:%i:%i:%i:%i:%c%s;", unitDef->GetName(), int(r.pos.x), int(r.pos.z), r.facing, w, d,
				state, r.tenant ? "t" : "");
		out += buf;
	}
	return out;
}

void CTerrainManager::ResetLayout()
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	// A task may already own a consumed or merely claimed slot. Stop those
	// tasks before deleting the registry so none can build from a stale pin
	// after a runtime role change.
	circuit->GetBuilderManager()->AbortLayoutTasks();
	std::vector<int> ids;
	for (const auto& kv : reservations) {
		ids.push_back(kv.first);
	}
	for (int id : ids) {
		ReleaseReservation(id);
	}
	std::vector<int> zids;
	for (const auto& kv : zones) {
		zids.push_back(kv.first);
	}
	for (int id : zids) {
		ReleaseZone(id);
	}
	pinnedReservation = -1;
	pinnedReservationRequired = false;
	reservationSearch = false;
	lastReservedId = -1;
	lastReservedFacing = -1;
	layoutGroups.clear();
	layoutZones.clear();
	layoutInts.clear();
	factoryLineReady = false;
	factoryLineFacing = UNIT_FACING_SOUTH;
	factoryRearCentre = {};
	factoryLineLeft2 = 0;
	factoryLineRight2 = 0;
	layoutNanoDefId = -1;
	nextFactoryCluster = 1;
	circuit->LOG("RESERVE: layout reset (%i reservations, %i zones released)", (int)ids.size(), (int)zids.size());
}

/*
 * Save/load (CR-003). The registry, the zones and the cells they own, the
 * counters and the flag. Blocking marks are rebuilt on load: zone cells and
 * unserved plain slots are marked again, a cell under a structure is left to
 * the structure (its blocker was added when the unit was re-registered).
 */
void CTerrainManager::SaveLayout(std::ostream& os) const
{
	utils::binary_write(os, layoutEnabled);
	utils::binary_write(os, nextReservationId);
	utils::binary_write(os, nextGroupId);
	utils::binary_write(os, nextZoneId);
	utils::binary_write(os, reservationMatchRadius);
	utils::binary_write(os, factoryLineReady);
	utils::binary_write(os, factoryLineFacing);
	utils::binary_write(os, factoryRearCentre.x2);
	utils::binary_write(os, factoryRearCentre.z2);
	utils::binary_write(os, factoryLineLeft2);
	utils::binary_write(os, factoryLineRight2);
	utils::binary_write(os, layoutNanoDefId);
	utils::binary_write(os, nextFactoryCluster);
	uint32_t groupNameCount = static_cast<uint32_t>(layoutGroups.size());
	utils::binary_write(os, groupNameCount);
	for (const auto& named : layoutGroups) {
		WriteLayoutString(os, named.first);
		utils::binary_write(os, named.second);
	}
	uint32_t zoneNameCount = static_cast<uint32_t>(layoutZones.size());
	utils::binary_write(os, zoneNameCount);
	for (const auto& named : layoutZones) {
		WriteLayoutString(os, named.first);
		utils::binary_write(os, named.second);
	}
	uint32_t intCount = static_cast<uint32_t>(layoutInts.size());
	utils::binary_write(os, intCount);
	for (const auto& named : layoutInts) {
		WriteLayoutString(os, named.first);
		utils::binary_write(os, named.second);
	}
	uint32_t zcount = zones.size();
	utils::binary_write(os, zcount);
	for (const auto& kv : zones) {
		const SZone& zn = kv.second;
		utils::binary_write(os, zn.id);
		utils::binary_write(os, zn.c1.x);
		utils::binary_write(os, zn.c1.y);
		utils::binary_write(os, zn.c2.x);
		utils::binary_write(os, zn.c2.y);
		utils::binary_write(os, zn.corridor);
		utils::binary_write(os, zn.cells);
		for (int z = zn.c1.y; z < zn.c2.y; ++z) {
			for (int x = zn.c1.x; x < zn.c2.x; ++x) {
				const uint8_t owned = (ZoneAt(x, z) == zn.id) ? 1 : 0;
				utils::binary_write(os, owned);
			}
		}
	}
	uint32_t rcount = reservations.size();
	utils::binary_write(os, rcount);
	for (const auto& kv : reservations) {
		const SReservation& r = kv.second;
		const CCircuitDef::Id defId = r.def->GetId();
		utils::binary_write(os, r.id);
		utils::binary_write(os, defId);
		utils::binary_write(os, r.pos.x);
		utils::binary_write(os, r.pos.y);
		utils::binary_write(os, r.pos.z);
		utils::binary_write(os, r.facing);
		utils::binary_write(os, r.group);
		utils::binary_write(os, r.untilFrame);
		utils::binary_write(os, r.consumed);
		utils::binary_write(os, r.armed);
		utils::binary_write(os, r.anyReach);
		utils::binary_write(os, r.tenant);
		utils::binary_write(os, r.zone);
		utils::binary_write(os, r.unitId);
		utils::binary_write(os, r.order);
		utils::binary_write(os, r.claimed);
	}
#ifdef DEBUG_SAVELOAD
	circuit->LOG("%s | zones=%i | reservations=%i", __PRETTY_FUNCTION__, zcount, rcount);
#endif
}

void CTerrainManager::LoadLayout(std::istream& is)
{
	ResetLayout();
	bool savedEnabled = false;
	utils::binary_read(is, savedEnabled);
	layoutEnabled = savedEnabled && layoutConfigured;
	utils::binary_read(is, nextReservationId);
	utils::binary_read(is, nextGroupId);
	utils::binary_read(is, nextZoneId);
	utils::binary_read(is, reservationMatchRadius);
	utils::binary_read(is, factoryLineReady);
	utils::binary_read(is, factoryLineFacing);
	utils::binary_read(is, factoryRearCentre.x2);
	utils::binary_read(is, factoryRearCentre.z2);
	utils::binary_read(is, factoryLineLeft2);
	utils::binary_read(is, factoryLineRight2);
	utils::binary_read(is, layoutNanoDefId);
	utils::binary_read(is, nextFactoryCluster);
	layoutGroups.clear();
	layoutZones.clear();
	layoutInts.clear();
	circuit->GetAllyTeam()->GetLayoutReservations().RemoveOwner(circuit->GetTeamId());
	zones.clear();
	reservations.clear();
	scopedSlots.clear();
    lostSlots.clear();
	localReservations.Clear();
	uint32_t groupNameCount = 0;
	utils::binary_read(is, groupNameCount);
	for (uint32_t i = 0; i < groupNameCount; ++i) {
		std::string name;
		int id = 0;
		if (!ReadLayoutString(is, name)) {
			return;
		}
		utils::binary_read(is, id);
		layoutGroups[name] = id;
	}
	uint32_t zoneNameCount = 0;
	utils::binary_read(is, zoneNameCount);
	for (uint32_t i = 0; i < zoneNameCount; ++i) {
		std::string name;
		int id = 0;
		if (!ReadLayoutString(is, name)) {
			return;
		}
		utils::binary_read(is, id);
		layoutZones[name] = id;
	}
	uint32_t intCount = 0;
	utils::binary_read(is, intCount);
	for (uint32_t i = 0; i < intCount; ++i) {
		std::string name;
		int value = 0;
		if (!ReadLayoutString(is, name)) {
			return;
		}
		utils::binary_read(is, value);
		layoutInts[name] = value;
	}
	if (zoneMap.size() != blockingMap.grid.size()) {
		zoneMap.assign(blockingMap.grid.size(), 0);
	} else {
		std::fill(zoneMap.begin(), zoneMap.end(), 0);
	}
	const SBlockingMap::SM all = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	uint32_t zcount = 0;
	utils::binary_read(is, zcount);
	for (uint32_t i = 0; i < zcount; ++i) {
		SZone zn;
		utils::binary_read(is, zn.id);
		utils::binary_read(is, zn.c1.x);
		utils::binary_read(is, zn.c1.y);
		utils::binary_read(is, zn.c2.x);
		utils::binary_read(is, zn.c2.y);
		utils::binary_read(is, zn.corridor);
		utils::binary_read(is, zn.cells);
		for (int z = zn.c1.y; z < zn.c2.y; ++z) {
			for (int x = zn.c1.x; x < zn.c2.x; ++x) {
				uint8_t owned = 0;
				utils::binary_read(is, owned);
				if ((owned == 0) || !blockingMap.IsInBounds(x, z)) {
					continue;
				}
				zoneMap[z * blockingMap.columns + x] = zn.id;
				blockingMap.AddReservationUnderlay(x, z, all);
			}
		}
		zones[zn.id] = zn;
		ShareZone(zn.id);
	}
	uint32_t rcount = 0;
	utils::binary_read(is, rcount);
	for (uint32_t i = 0; i < rcount; ++i) {
		SReservation r;
		CCircuitDef::Id defId;
		utils::binary_read(is, r.id);
		utils::binary_read(is, defId);
		utils::binary_read(is, r.pos.x);
		utils::binary_read(is, r.pos.y);
		utils::binary_read(is, r.pos.z);
		utils::binary_read(is, r.facing);
		utils::binary_read(is, r.group);
		utils::binary_read(is, r.untilFrame);
		utils::binary_read(is, r.consumed);
		utils::binary_read(is, r.armed);
		utils::binary_read(is, r.anyReach);
		utils::binary_read(is, r.tenant);
		utils::binary_read(is, r.zone);
		utils::binary_read(is, r.unitId);
		utils::binary_read(is, r.order);
		utils::binary_read(is, r.claimed);
		r.def = circuit->GetCircuitDef(defId);
		if (r.def == nullptr) {
			continue;
		}
		reservations[r.id] = r;
		IndexReservation(r.id);
		ShareSlot(r.id);
		if (!r.consumed && (r.zone == 0)) {
			int2 c1, c2;
			if (ReservationCells(r.def, r.pos, r.facing, c1, c2)) {
				MarkReservation(c1, c2, true);
			}
		}
	}
	circuit->LOG("RESERVE: layout loaded: %i zones, %i reservations, %s", (int)zones.size(), (int)reservations.size(), layoutEnabled ? "on" : "off");
}

//AIFloat3 CTerrainManager::FindSpringBuildSite(CCircuitDef* cdef, const AIFloat3& pos, float searchRadius, int facing)
//{
//	return circuit->GetMap()->FindClosestBuildSite(cdef->GetDef(), pos, searchRadius, 0, facing);
//}

void CTerrainManager::DoLineOfDef(const AIFloat3& start, const AIFloat3& end, CCircuitDef* buildDef,
		std::function<void (const AIFloat3& pos, CCircuitDef* buildDef)> exec) const
{
	const AIFloat3 delta = end - start;
	float xsize, zsize;

	auto search = blockInfos.find(buildDef->GetId());
	if (search != blockInfos.end()) {
		xsize = search->second->GetXSize() * 2 * SQUARE_SIZE;
		zsize = search->second->GetZSize() * 2 * SQUARE_SIZE;
	} else {
		xsize = buildDef->GetDef()->GetXSize() * SQUARE_SIZE;
		zsize = buildDef->GetDef()->GetZSize() * SQUARE_SIZE;
	}
	// NOTE: Ignore facing for simplicity, hence turn rectangles into squares
	xsize = zsize = std::max(xsize, zsize);

	const int xnum = (int)((math::fabs(delta.x) + xsize * 1.4f) / xsize);
	const int znum = (int)((math::fabs(delta.z) + zsize * 1.4f) / zsize);

	float xstep = (int)((0 < delta.x) ? xsize : -xsize);
	float zstep = (int)((0 < delta.z) ? zsize : -zsize);

	const bool xDominatesZ = (math::fabs(delta.x) > math::fabs(delta.z));

	if (xDominatesZ) {
		zstep = xstep * delta.z / (delta.x ? delta.x : 1);
	} else {
		xstep = zstep * delta.x / (delta.z ? delta.z : 1);
	}

	int n = xDominatesZ ? xnum : znum, x = start.x, z = start.z;
	for (int i = 0; i < n; ++i) {
		exec(AIFloat3(x, 0.f, z), buildDef);

		x += xstep;
		z += zstep;
	}
}

AIFloat3 CTerrainManager::GetRandomMovePosition(CCircuitUnit* unit)
{
	float x = rand() % GetTerrainWidth();
	float z = rand() % GetTerrainHeight();
	AIFloat3 pos(x, circuit->GetMap()->GetElevationAt(x, z), z);
	return GetMovePosition(unit->GetArea(), pos);
}

const SBlockingMap& CTerrainManager::GetBlockingMap()
{
	if (circuit->IsAllyAware()) {
		MarkAllyBuildings();
	}
	return blockingMap;
}

bool CTerrainManager::IsZoneAlly(const AIFloat3& pos) const
{
	const int x = int(pos.x) / (GRID_RATIO_ALLY * BUILD_SQUARE_SIZE);
	const int z = int(pos.z) / (GRID_RATIO_ALLY * BUILD_SQUARE_SIZE);
	return blockingMap.IsZoneAlly(x, z);
}

float CTerrainManager::SetAllyZoneRange(float range)
{
	allyZoneCells = circuit->IsAllyBaseAvoid() ? int(range * 2) / (GRID_RATIO_ALLY * BUILD_SQUARE_SIZE) : 0;
	return allyZoneCells * GRID_RATIO_ALLY * BUILD_SQUARE_SIZE / 2;
}

bool CTerrainManager::ResignAllyBuilding(CCircuitUnit* unit)
{
	auto it = markedAllies.cbegin();
	while (it != markedAllies.cend()) {
		if (it->unitId == unit->GetId()) {
			markedAllies.erase(it);
			return true;
		}
		++it;
	}
	return false;
}

void CTerrainManager::ApplyAuthority()
{
	for (SStructure& building : markedAllies) {
		building.cdef = circuit->GetCircuitDef(building.cdef->GetId());
	}
}

void CTerrainManager::MarkAllyBuildings()
{
	if (markFrame /*+ FRAMES_PER_SEC*/ >= circuit->GetLastFrame()) {
		return;
	}
	markFrame = circuit->GetLastFrame();

	circuit->UpdateFriendlyUnits();
	const CAllyTeam::AllyUnits& friendlies = circuit->GetFriendlyUnits();
	const int teamId = circuit->GetTeamId();
	const int frame = circuit->GetLastFrame();

	decltype(markedAllies) prevUnits = std::move(markedAllies);
	markedAllies.clear();
	auto first1  = friendlies.begin();
	auto last1   = friendlies.end();
	auto first2  = prevUnits.begin();
	auto last2   = prevUnits.end();
	auto d_first = std::back_inserter(markedAllies);
	auto addStructure = [this, &d_first, frame](CAllyUnit* unit) {
		SStructure building;
		building.unitId = unit->GetId();
		building.cdef = unit->GetCircuitDef();
		building.facing = unit->GetUnit()->GetBuildingFacing();
		building.pos = unit->GetPos(frame) + building.cdef->GetMidPosOffset(building.facing);
		*d_first++ = building;
//		if (!building.cdef->IsMex()) {  // mex positions are marked on start and must not change
			MarkBlocker(building, true);
//		}
		if (building.cdef->IsBuilder()) {
			MarkZoneAlly(building.pos, true);
		}
	};
	auto delStructure = [this](const SStructure& building) {
//		if (!building.cdef->IsMex()) {  // mex positions are marked on start and must not change
			MarkBlocker(building, false);
//		}
		if (building.cdef->IsBuilder()) {
			MarkZoneAlly(building.pos, false);
		}
	};

	// @see std::set_symmetric_difference + std::set_intersection
	while (first1 != last1) {
		CAllyUnit* unit = first1->second;
		if (unit->GetCircuitDef()->IsMobile() || (unit->GetUnit()->GetTeam() == teamId)) {
			++first1;
			continue;
		}
		if (first2 == last2) {
			addStructure(unit);  // everything else in first1..last1 is new units
			while (++first1 != last1) {
				CAllyUnit* unit = first1->second;
				if (unit->GetCircuitDef()->IsMobile() || (unit->GetUnit()->GetTeam() == teamId)) {
					continue;
				}
				addStructure(unit);
			}
			break;
		}

		if (first1->first < first2->unitId) {
			addStructure(unit);  // new unit
			++first1;  // advance friendlies
		} else {
			if (first2->unitId < first1->first) {
				delStructure(*first2);  // dead unit
			} else {
				*d_first++ = *first2;  // old unit
				++first1;  // advance friendlies
			}
			++first2;  // advance prevUnits
		}
	}
	while (first2 != last2) {  // everything else in first2..last2 is dead units
		delStructure(*first2++);
	}
}

const CTerrainManager::SearchOffsets& CTerrainManager::GetSearchOffsetTable(int radius)
{
	static std::vector<SSearchOffset> searchOffsets;
	unsigned int size = radius * radius * 4;
	if (size > searchOffsets.size()) {
		searchOffsets.resize(size);

		for (int y = 0; y < radius * 2; y++) {
			for (int x = 0; x < radius * 2; x++) {
				SSearchOffset& i = searchOffsets[y * radius * 2 + x];

				i.dx = x - radius;
				i.dy = y - radius;
				i.qdist = i.dx * i.dx + i.dy * i.dy;
			}
		}

		auto searchOffsetComparator = [](const SSearchOffset& a, const SSearchOffset& b) {
			return a.qdist < b.qdist;
		};
		std::sort(searchOffsets.begin(), searchOffsets.end(), searchOffsetComparator);
	}

	return searchOffsets;
}

const CTerrainManager::SearchOffsetsLow& CTerrainManager::GetSearchOffsetTableLow(int radius)
{
	static SearchOffsetsLow searchOffsetsLow;
	int radiusLow = radius / GRID_RATIO_LOW;
	unsigned int sizeLow = radiusLow * radiusLow * 4;
	if (sizeLow > searchOffsetsLow.size()) {
		searchOffsetsLow.resize(sizeLow);

		SearchOffsets searchOffsets;
		searchOffsets.resize(radius * radius * 4);
		for (int y = 0; y < radius * 2; y++) {
			for (int x = 0; x < radius * 2; x++) {
				SSearchOffset& i = searchOffsets[y * radius * 2 + x];
				i.dx = x - radius + GRID_RATIO_LOW / 2;
				i.dy = y - radius + GRID_RATIO_LOW / 2;
				i.qdist = i.dx * i.dx + i.dy * i.dy;  // from corner low-res cell
//				i.qdist = SQUARE(x - radius) + SQUARE(y - radius);  // from center of low-res cell
			}
		}

		auto searchOffsetComparator = [](const SSearchOffset& a, const SSearchOffset& b) {
			return a.qdist < b.qdist;
		};
		for (int yl = 0; yl < radiusLow * 2; yl++) {
			for (int xl = 0; xl < radiusLow * 2; xl++) {
				SSearchOffsetLow& il = searchOffsetsLow[yl * radiusLow * 2 + xl];
				il.dx = xl - radiusLow;
				il.dy = yl - radiusLow;
				il.qdist = il.dx * il.dx + il.dy * il.dy;

				il.ofs.reserve(GRID_RATIO_LOW * GRID_RATIO_LOW);
				const int xi = xl * GRID_RATIO_LOW;
				for (int y = yl * GRID_RATIO_LOW; y < (yl + 1) * GRID_RATIO_LOW; y++) {
					for (int x = xi; x < xi + GRID_RATIO_LOW; x++) {
						il.ofs.push_back(searchOffsets[y * radius * 2 + x]);
					}
				}

				std::sort(il.ofs.begin(), il.ofs.end(), searchOffsetComparator);
			}
		}

		auto searchOffsetLowComparator = [](const SSearchOffsetLow& a, const SSearchOffsetLow& b) {
			return a.qdist < b.qdist;
		};
		std::sort(searchOffsetsLow.begin(), searchOffsetsLow.end(), searchOffsetLowComparator);
	}

	return searchOffsetsLow;
}

AIFloat3 CTerrainManager::FindBuildSiteLow(CCircuitDef* cdef, const AIFloat3& pos,
		float searchRadius, int facing, TerrainPredicate& predicate)
{
	UnitDef* unitDef = cdef->GetDef();
	const int xsize = (((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;
	const int zsize = (((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;

	const SBlockingMap::SM notIgnore = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);
	auto isOpenSite = [this, notIgnore](const int2& s1, const int2& s2) {
		for (int z = s1.y; z < s2.y; z++) {
			for (int x = s1.x; x < s2.x; x++) {
				if (blockingMap.IsBlocked(x, z, notIgnore)) {
					return false;
				}
			}
		}
		return true;
	};

	const int endr = (int)(searchRadius / (SQUARE_SIZE * 2));
	const SearchOffsetsLow& ofsLow = GetSearchOffsetTableLow(endr);
	const int endrLow = endr / GRID_RATIO_LOW;

	const int centerX = int(pos.x / (SQUARE_SIZE * 2 * GRID_RATIO_LOW));
	const int centerZ = int(pos.z / (SQUARE_SIZE * 2 * GRID_RATIO_LOW));

	const int cornerX1 = int(pos.x / (SQUARE_SIZE * 2)) - (xsize / 2);
	const int cornerZ1 = int(pos.z / (SQUARE_SIZE * 2)) - (zsize / 2);

	AIFloat3 probePos(ZeroVector);
	CMap* map = circuit->GetMap();

	for (int soLow = 0; soLow < endrLow * endrLow * 4; soLow++) {
		int xlow = centerX + ofsLow[soLow].dx;
		int zlow = centerZ + ofsLow[soLow].dy;
		if (!blockingMap.IsInBoundsLow(xlow, zlow) || blockingMap.IsBlockedLow(xlow, zlow, notIgnore)) {
			continue;
		}

		probePos.x = (xlow * 2 + 1) * SQUARE_SIZE * GRID_RATIO_LOW;
		probePos.z = (zlow * 2 + 1) * SQUARE_SIZE * GRID_RATIO_LOW;
		if (!CanBeBuiltAtSafe(cdef, probePos)) {
			continue;
		}

		const SearchOffsets& ofs = ofsLow[soLow].ofs;
		for (int so = 0; so < GRID_RATIO_LOW * GRID_RATIO_LOW; so++) {
			int2 s1(cornerX1 + ofs[so].dx, cornerZ1 + ofs[so].dy);
			int2 s2(    s1.x + xsize,          s1.y + zsize);
			if (!blockingMap.IsInBounds(s1, s2) || !isOpenSite(s1, s2)) {
				continue;
			}

			probePos.x = (s1.x + s2.x) * SQUARE_SIZE;
			probePos.z = (s1.y + s2.y) * SQUARE_SIZE;
			if (CanBeBuiltAtSafe(cdef, probePos) && map->IsPossibleToBuildAt(unitDef, probePos, facing)) {
				probePos.y = map->GetElevationAt(probePos.x, probePos.z);
				if (predicate(probePos)) {
					return probePos;
				}
			}
		}
	}

	return -RgtVector;
}

AIFloat3 CTerrainManager::FindBuildSiteByMask(CCircuitDef* cdef, const AIFloat3& pos,
		float searchRadius, int facing, IBlockMask* mask, TerrainPredicate& predicate)
{
	int xmsize = mask->GetXSize();
	int zmsize = mask->GetZSize();

	UnitDef* unitDef = cdef->GetDef();
	int xssize, zssize;
	switch (facing) {
		default:
		case UNIT_FACING_SOUTH:
		case UNIT_FACING_NORTH: {
			xssize = unitDef->GetXSize() / 2;
			zssize = unitDef->GetZSize() / 2;
		} break;
		case UNIT_FACING_EAST:
		case UNIT_FACING_WEST: {
			xmsize = mask->GetZSize();
			zmsize = mask->GetXSize();
			xssize = unitDef->GetZSize() / 2;
			zssize = unitDef->GetXSize() / 2;
		} break;
	}

#define DECLARE_TEST(testName, facingType)																	\
	auto testName = [this, mask, notIgnore, structMask](const int2& m1, const int2& m2, const int2& om) {	\
		for (int z = m1.y, zm = om.y; z < m2.y; z++, zm++) {												\
			for (int x = m1.x, xm = om.x; x < m2.x; x++, xm++) {											\
				switch (mask->facingType(xm, zm)) {															\
					case IBlockMask::BlockType::BLOCK: {													\
						if (blockingMap.IsStructed(x, z, structMask)) {										\
							return false;																	\
						}																					\
					} break;																				\
					case IBlockMask::BlockType::STRUCT: {													\
						if (blockingMap.IsBlocked(x, z, notIgnore)) {										\
							return false;																	\
						}																					\
					} break;																				\
					case IBlockMask::BlockType::OPEN: {														\
					} break;																				\
				}																							\
			}																								\
		}																									\
		return true;																						\
	};

	const int endr = (int)(searchRadius / (SQUARE_SIZE * 2));
	const SearchOffsets& ofs = GetSearchOffsetTable(endr);

	int2 structCorner;
	structCorner.x = int(pos.x / (SQUARE_SIZE * 2)) - (xssize / 2);
	structCorner.y = int(pos.z / (SQUARE_SIZE * 2)) - (zssize / 2);

	const int2& offset = mask->GetStructOffset(facing);
	int2 maskCorner = structCorner - offset;

	const int notIgnore = ~mask->GetIgnoreMask();
	SBlockingMap::StructMask structMask = SBlockingMap::GetStructMask(mask->GetStructType());

	AIFloat3 probePos(ZeroVector);
	CMap* map = circuit->GetMap();

#define DO_TEST(testName)																				\
	for (int so = 0; so < endr * endr * 4; so++) {														\
		int2 s1(structCorner.x + ofs[so].dx, structCorner.y + ofs[so].dy);								\
		int2 s2(          s1.x + xssize,               s1.y + zssize);									\
		if (!blockingMap.IsInBounds(s1, s2)) {															\
			continue;																					\
		}																								\
																										\
		probePos.x = (s1.x + s2.x) * SQUARE_SIZE;														\
		probePos.z = (s1.y + s2.y) * SQUARE_SIZE;														\
		if (!CanBeBuiltAtSafe(cdef, probePos)) {														\
			continue;																					\
		}																								\
																										\
		int2 m1(maskCorner.x + ofs[so].dx, maskCorner.y + ofs[so].dy);									\
		int2 m2(        m1.x + xmsize,             m1.y + zmsize);										\
		int2 om = m1;																					\
		blockingMap.Bound(m1, m2);																		\
		om = m1 - om;																					\
		if (!testName(m1, m2, om)) {																	\
			continue;																					\
		}																								\
																										\
		if (map->IsPossibleToBuildAt(unitDef, probePos, facing)) {										\
			probePos.y = map->GetElevationAt(probePos.x, probePos.z);									\
			if (predicate(probePos)) {																	\
				return probePos;																		\
			}																							\
		}																								\
	}

	switch (facing) {
		default:
		case UNIT_FACING_SOUTH: {
			DECLARE_TEST(isOpenSouth, GetTypeSouth);
			DO_TEST(isOpenSouth);
		} break;
		case UNIT_FACING_EAST: {
			DECLARE_TEST(isOpenEast, GetTypeEast);
			DO_TEST(isOpenEast);
		} break;
		case UNIT_FACING_NORTH: {
			DECLARE_TEST(isOpenNorth, GetTypeNorth);
			DO_TEST(isOpenNorth);
		} break;
		case UNIT_FACING_WEST: {
			DECLARE_TEST(isOpenWest, GetTypeWest);
			DO_TEST(isOpenWest);
		} break;
	}
#undef DO_TEST
#undef DECLARE_TEST

	return -RgtVector;
}

AIFloat3 CTerrainManager::FindBuildSiteByMaskLow(CCircuitDef* cdef, const AIFloat3& pos,
		float searchRadius, int facing, IBlockMask* mask, TerrainPredicate& predicate)
{
	UnitDef* unitDef = cdef->GetDef();
	int xmsize, zmsize, xssize, zssize;
	switch (facing) {
		default:
		case UNIT_FACING_SOUTH:
		case UNIT_FACING_NORTH: {
			xmsize = mask->GetXSize();
			zmsize = mask->GetZSize();
			xssize = unitDef->GetXSize() / 2;
			zssize = unitDef->GetZSize() / 2;
		} break;
		case UNIT_FACING_EAST:
		case UNIT_FACING_WEST: {
			xmsize = mask->GetZSize();
			zmsize = mask->GetXSize();
			xssize = unitDef->GetZSize() / 2;
			zssize = unitDef->GetXSize() / 2;
		} break;
	}

#define DECLARE_TEST_LOW(testName, facingType)																\
	auto testName = [this, mask, notIgnore, structMask](const int2& m1, const int2& m2, const int2& om) {	\
		for (int z = m1.y, zm = om.y; z < m2.y; z++, zm++) {												\
			for (int x = m1.x, xm = om.x; x < m2.x; x++, xm++) {											\
				switch (mask->facingType(xm, zm)) {															\
					case IBlockMask::BlockType::BLOCK: {													\
						if (blockingMap.IsStructed(x, z, structMask)) {										\
							return false;																	\
						}																					\
						break;																				\
					}																						\
					case IBlockMask::BlockType::STRUCT: {													\
						if (blockingMap.IsBlocked(x, z, notIgnore)) {										\
							return false;																	\
						}																					\
						break;																				\
					}																						\
					case IBlockMask::BlockType::OPEN: {														\
					} break;																				\
				}																							\
			}																								\
		}																									\
		return true;																						\
	};

	const int endr = (int)(searchRadius / (SQUARE_SIZE * 2));
	const SearchOffsetsLow& ofsLow = GetSearchOffsetTableLow(endr);
	const int endrLow = endr / GRID_RATIO_LOW;

	int2 structCorner;
	structCorner.x = int(pos.x / (SQUARE_SIZE * 2)) - (xssize / 2);
	structCorner.y = int(pos.z / (SQUARE_SIZE * 2)) - (zssize / 2);

	const int2& offset = mask->GetStructOffset(facing);
	int2 maskCorner = structCorner - offset;

	int2 structCenter;
	structCenter.x = int(pos.x / (SQUARE_SIZE * 2 * GRID_RATIO_LOW));
	structCenter.y = int(pos.z / (SQUARE_SIZE * 2 * GRID_RATIO_LOW));

	const int notIgnore = ~mask->GetIgnoreMask();
	SBlockingMap::StructMask structMask = SBlockingMap::GetStructMask(mask->GetStructType());

	AIFloat3 probePos(ZeroVector);
	CMap* map = circuit->GetMap();

#define DO_TEST_LOW(testName)																					\
	for (int soLow = 0; soLow < endrLow * endrLow * 4; soLow++) {												\
		int2 low(structCenter.x + ofsLow[soLow].dx, structCenter.y + ofsLow[soLow].dy);							\
		if (!blockingMap.IsInBoundsLow(low.x, low.y) || blockingMap.IsBlockedLow(low.x, low.y, notIgnore)) {	\
			continue;																							\
		}																										\
																												\
		probePos.x = (low.x * 2 + 1) * SQUARE_SIZE * GRID_RATIO_LOW;											\
		probePos.z = (low.y * 2 + 1) * SQUARE_SIZE * GRID_RATIO_LOW;											\
		if (!CanBeBuiltAtSafe(cdef, probePos)) {																\
			continue;																							\
		}																										\
																												\
		const SearchOffsets& ofs = ofsLow[soLow].ofs;															\
		for (int so = 0; so < GRID_RATIO_LOW * GRID_RATIO_LOW; so++) {											\
			int2 s1(structCorner.x + ofs[so].dx, structCorner.y + ofs[so].dy);									\
			int2 s2(          s1.x + xssize,               s1.y + zssize);										\
			if (!blockingMap.IsInBounds(s1, s2)) {																\
				continue;																						\
			}																									\
																												\
			probePos.x = (s1.x + s2.x) * SQUARE_SIZE;															\
			probePos.z = (s1.y + s2.y) * SQUARE_SIZE;															\
			if (!CanBeBuiltAtSafe(cdef, probePos)) {															\
				continue;																						\
			}																									\
																												\
			int2 m1(maskCorner.x + ofs[so].dx, maskCorner.y + ofs[so].dy);										\
			int2 m2(        m1.x + xmsize,             m1.y + zmsize);											\
			int2 om = m1;																						\
			blockingMap.Bound(m1, m2);																			\
			om = m1 - om;																						\
			if (!testName(m1, m2, om)) {																		\
				continue;																						\
			}																									\
																												\
			if (map->IsPossibleToBuildAt(unitDef, probePos, facing)) {											\
				probePos.y = map->GetElevationAt(probePos.x, probePos.z);										\
				if (predicate(probePos)) {																		\
					return probePos;																			\
				}																								\
			}																									\
		}																										\
	}

	switch (facing) {
		default:
		case UNIT_FACING_SOUTH: {
			DECLARE_TEST_LOW(isOpenSouth, GetTypeSouth);
			DO_TEST_LOW(isOpenSouth);
		} break;
		case UNIT_FACING_EAST: {
			DECLARE_TEST_LOW(isOpenEast, GetTypeEast);
			DO_TEST_LOW(isOpenEast);
		} break;
		case UNIT_FACING_NORTH: {
			DECLARE_TEST_LOW(isOpenNorth, GetTypeNorth);
			DO_TEST_LOW(isOpenNorth);
		} break;
		case UNIT_FACING_WEST: {
			DECLARE_TEST_LOW(isOpenWest, GetTypeWest);
			DO_TEST_LOW(isOpenWest);
		} break;
	}
#undef DO_TEST_LOW
#undef DECLARE_TEST_LOW

	return -RgtVector;
}

void CTerrainManager::MarkBlockerByMask(const SStructure& building, bool block, IBlockMask* mask)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	UnitDef* unitDef = building.cdef->GetDef();
	int facing = building.facing;
	const AIFloat3& pos = building.pos;

	int xmsize, zmsize, xssize, zssize;
	switch (facing) {
		default:
		case UNIT_FACING_SOUTH:
		case UNIT_FACING_NORTH: {
			xmsize = mask->GetXSize();
			zmsize = mask->GetZSize();
			xssize = unitDef->GetXSize() / 2;
			zssize = unitDef->GetZSize() / 2;
		} break;
		case UNIT_FACING_EAST:
		case UNIT_FACING_WEST: {
			xmsize = mask->GetZSize();
			zmsize = mask->GetXSize();
			xssize = unitDef->GetZSize() / 2;
			zssize = unitDef->GetXSize() / 2;
		} break;
	}

#define DECLARE_MARKER(typeName, blockerOp, structOp)					\
	for (int z = m1.y, zm = om.y; z < m2.y; z++, zm++) {				\
		for (int x = m1.x, xm = om.x; x < m2.x; x++, xm++) {			\
			switch (mask->typeName(xm, zm)) {							\
				case IBlockMask::BlockType::BLOCK: {					\
					blockingMap.blockerOp(x, z, structType);			\
				} break;												\
				case IBlockMask::BlockType::STRUCT: {					\
					blockingMap.structOp(x, z, structType, notIgnore);	\
				} break;												\
				case IBlockMask::BlockType::OPEN: {						\
				} break;												\
			}															\
		}																\
	}

	int2 corner;
	corner.x = int(pos.x + 0.5f) / (SQUARE_SIZE * 2) - (xssize / 2);
	corner.y = int(pos.z + 0.5f) / (SQUARE_SIZE * 2) - (zssize / 2);

	int2 m1 = corner - mask->GetStructOffset(facing);	// top-left mask corner
	int2 m2(m1.x + xmsize, m1.y + zmsize);				// bottom-right mask corner
	int2 om = m1;										// store original mask corner
	blockingMap.Bound(m1, m2);							// corners bounded by map
	om = m1 - om;										// shift original mask corner

	const int notIgnore = ~mask->GetIgnoreMask();
	SBlockingMap::StructType structType = mask->GetStructType();

#define DO_MARK(facingType)												\
	if (block) {														\
		DECLARE_MARKER(facingType, AddBlocker, AddStruct);				\
	} else {															\
		DECLARE_MARKER(facingType, DelBlocker, DelStruct);				\
	}

	switch (facing) {
		default:
		case UNIT_FACING_SOUTH: {
			DO_MARK(GetTypeSouth);
		} break;
		case UNIT_FACING_EAST: {
			DO_MARK(GetTypeEast);
		} break;
		case UNIT_FACING_NORTH: {
			DO_MARK(GetTypeNorth);
		} break;
		case UNIT_FACING_WEST: {
			DO_MARK(GetTypeWest);
		} break;
	}
#undef DO_MARK
#undef DECLARE_MARKER
}

void CTerrainManager::MarkBlocker(const SStructure& building, bool block)
{
    ++packingRevision; // invalidate exact empty-geometry reuse on mutation
	CCircuitDef* cdef = building.cdef;
	auto search = blockInfos.find(cdef->GetId());
	if (search != blockInfos.end()) {
		MarkBlockerByMask(building, block, search->second);
		return;
	}

	/*
	 * Default marker
	 */
	int facing = building.facing;
	const AIFloat3& pos = building.pos;

	UnitDef* unitDef = cdef->GetDef();
	const int xsize = (((facing & 1) == 0) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;
	const int zsize = (((facing & 1) == 1) ? unitDef->GetXSize() : unitDef->GetZSize()) / 2;

	const int x1 = int(pos.x + 0.5f) / (SQUARE_SIZE * 2) - (xsize / 2), x2 = x1 + xsize;
	const int z1 = int(pos.z + 0.5f) / (SQUARE_SIZE * 2) - (zsize / 2), z2 = z1 + zsize;

	int2 m1(x1, z1);
	int2 m2(x2, z2);
	blockingMap.Bound(m1, m2);

	const SBlockingMap::StructType structType = SBlockingMap::StructType::UNKNOWN;
	const SBlockingMap::SM notIgnore = static_cast<SBlockingMap::SM>(SBlockingMap::StructMask::ALL);

	if (block) {
		for (int x = m1.x; x < m2.x; ++x) {
			for (int z = m1.y; z < m2.y; ++z) {
				blockingMap.AddStruct(x, z, structType, notIgnore);
			}
		}
	} else {
		// NOTE: This can mess up things if unit is inside factory :/
		// SOLUTION: Do not mark movable units
		for (int x = m1.x; x < m2.x; ++x) {
			for (int z = m1.y; z < m2.y; ++z) {
				blockingMap.DelStruct(x, z, structType, notIgnore);
			}
		}
	}
}

void CTerrainManager::MarkZoneAlly(const AIFloat3& pos, bool block)
{
	++packingRevision;
	const int xsize = allyZoneCells;
	const int zsize = allyZoneCells;

	const int x1 = int(pos.x + 0.5f) / (GRID_RATIO_ALLY * BUILD_SQUARE_SIZE) - (xsize / 2), x2 = x1 + xsize;
	const int z1 = int(pos.z + 0.5f) / (GRID_RATIO_ALLY * BUILD_SQUARE_SIZE) - (zsize / 2), z2 = z1 + zsize;

	int2 m1(x1, z1);
	int2 m2(x2, z2);
	blockingMap.BoundAlly(m1, m2);

	if (block) {
		for (int x = m1.x; x < m2.x; ++x) {
			for (int z = m1.y; z < m2.y; ++z) {
				blockingMap.AddZoneAlly(x, z);
			}
		}
	} else {
		for (int x = m1.x; x < m2.x; ++x) {
			for (int z = m1.y; z < m2.y; ++z) {
				blockingMap.DelZoneAlly(x, z);
			}
		}
	}
}

void CTerrainManager::MarkZoneOwn(const AIFloat3& pos, bool block)
{
	++packingRevision;
	const int xsize = allyZoneCells;
	const int zsize = allyZoneCells;

	const int x1 = int(pos.x + 0.5f) / (GRID_RATIO_ALLY * BUILD_SQUARE_SIZE) - (xsize / 2), x2 = x1 + xsize;
	const int z1 = int(pos.z + 0.5f) / (GRID_RATIO_ALLY * BUILD_SQUARE_SIZE) - (zsize / 2), z2 = z1 + zsize;

	int2 m1(x1, z1);
	int2 m2(x2, z2);
	blockingMap.BoundAlly(m1, m2);

	if (block) {
		for (int x = m1.x; x < m2.x; ++x) {
			for (int z = m1.y; z < m2.y; ++z) {
				blockingMap.AddZoneOwn(x, z);
			}
		}
	} else {
		for (int x = m1.x; x < m2.x; ++x) {
			for (int z = m1.y; z < m2.y; ++z) {
				blockingMap.DelZoneOwn(x, z);
			}
		}
	}
}

void CTerrainManager::MarkBusPath()
{
	++packingRevision;
	for (auto& kv : busQueries) {
		FactoryPathQuery& fpq = kv.second;
		std::shared_ptr<IPathQuery>& pQuery = fpq.query;
		if (pQuery != nullptr) {
			continue;
		}
		// FIXME: Sometimes creates path through factory structure
		// (structure sectors have high cost but don't block path, for future reclaiming).
		// Also late-game fpq.targets for T3 may contain nodes from T1/T2 thin path (not wide enough).
		pQuery = circuit->GetPathfinder()->CreatePathWideQuery(kv.first, fpq.mobileDef, fpq.startPos, fpq.endPos, fpq.targets);

		circuit->GetPathfinder()->RunQuery(circuit->GetScheduler().get(), pQuery, [this](const IPathQuery* query) {
			auto it = busPath.find(query->GetUnit());
			if (it == busPath.end()) {
				return;
			}
			const CQueryPathWide* q = static_cast<const CQueryPathWide*>(query);
			FillParentBusNodes(q->GetPathInfo().get());
			CPathFinder* pathfinder = circuit->GetPathfinder();
			const int granularity = pathfinder->GetSquareSize() / (SQUARE_SIZE * 2);
			const int howWide = q->GetHowWide();
			const int squares = howWide * granularity;
			for (int index : q->GetPathInfo()->path) {  // path can be empty
				int ix, iz;
				pathfinder->PathIndex2PathXY(index, &ix, &iz);

				ix = ix * granularity + granularity / 2;
				iz = iz * granularity + granularity / 2;
				int2 m1 = (howWide & 1) ? int2(ix - squares / 2, iz - squares / 2)
						: int2(ix - (squares - granularity) / 2, iz - (squares - granularity) / 2);
				int2 m2 = (howWide & 1) ? int2(ix + squares / 2, iz + squares / 2)
						: int2(ix + (squares + granularity) / 2, iz + (squares + granularity) / 2);
				blockingMap.Bound(m1, m2);
				for (int z = m1.y; z < m2.y; ++z) {
					for (int x = m1.x; x < m2.x; ++x) {
						blockingMap.AddBlocker(x, z, SBlockingMap::StructType::TERRA);
					}
				}
			}
			it->second.pPath = q->GetPathInfo();
			it->second.howWide = q->GetHowWide();
			busQueries.erase(query->GetUnit());
		});

		/*
		 * Example of engine's Pathing usage.
		 * Alas no threading and missing node extra-cost setters.
		 */
//		MoveData* moveData = fpq.mobileDef->GetDef()->GetMoveData();
//		const int pathType = moveData->GetPathType();
//		delete moveData;
//		Pathing* pathing = circuit->GetPathing();
//		// Error here: pathing->SetPathNodeCost();  For metal points. Doesn't exist!!!
//		const int pathId = pathing->InitPath(fpq.startPos, fpq.endPos, pathType, circuit->GetPathfinder()->GetSquareSize());
//		AIFloat3 point = pathing->GetNextWaypoint(pathId);
//		AIFloat3 prevPoint = -RgtVector;
//		while (point != prevPoint) {
//			circuit->GetDrawer()->AddPoint(point, "");
//			prevPoint = point;
//			point = pathing->GetNextWaypoint(pathId);
//		}
//		pathing->FreePath(pathId);
	}
}

void CTerrainManager::FillParentBusNodes(CPathInfo* pathInfo)
{
	if (pathInfo->path.empty()) {
		return;
	}
	for (const auto& kv : busPath) {
		if (kv.second.pPath == nullptr) {
			continue;
		}
		const IndexVec& path = kv.second.pPath->path;
		auto it = path.begin();
		while ((it != path.end()) && (pathInfo->path.back() != *it)) {
			++it;
		}
		if ((it != path.end()) && (++it != path.end())) {
			pathInfo->path.insert(pathInfo->path.end(), it, path.end());
			return;
		}
	}
}

void CTerrainManager::SnapPosition(AIFloat3& position)
{
	// NOTE: Build-cells have size of (SQURE_SIZE * 2)=16 elmos.
	//       Build-position in engine is footprint's center, and depends on (size/2)'s oddity.
	//       With !(size & 2) => !(size/2 & 1) engine treats [0..8) as cell_0, [8..24) as cell_1.
	//       But CircuitAI treats [0..16) as cell_0, [16..32) as cell_1.
	//       Hence snap source position to multiples of (SQUARE_SIZE * 2) to avoid further oddity hussle.
	// @see rts/Sim/Units/CommandAI/BuilderCAI.cpp:CBuilderCAI::ExecuteBuildCmd()
	// @see rts/Game/GameHelper.cpp:CGameHelper::Pos2BuildPos()
	position.x = int(position.x / (SQUARE_SIZE * 2)) * SQUARE_SIZE * 2;
	position.z = int(position.z / (SQUARE_SIZE * 2)) * SQUARE_SIZE * 2;
}

AIFloat3 CTerrainManager::Pos2BuildPos(CCircuitDef* cdef, const AIFloat3& position, int facing)
{
	AIFloat3 pos;
	int xsize = cdef->GetDef()->GetXSize();
	int zsize = cdef->GetDef()->GetZSize();
	if ((facing & 1) == 1) {
		std::swap(xsize, zsize);
	}

	// snap build-positions to 16-elmo grid
	if (xsize & 2) {
		pos.x = math::floor((position.x              ) / BUILD_SQUARE_SIZE) * BUILD_SQUARE_SIZE + SQUARE_SIZE;
	} else {
		pos.x = math::floor((position.x + SQUARE_SIZE) / BUILD_SQUARE_SIZE) * BUILD_SQUARE_SIZE;
	}

	if (zsize & 2) {
		pos.z = math::floor((position.z              ) / BUILD_SQUARE_SIZE) * BUILD_SQUARE_SIZE + SQUARE_SIZE;
	} else {
		pos.z = math::floor((position.z + SQUARE_SIZE) / BUILD_SQUARE_SIZE) * BUILD_SQUARE_SIZE;
	}

	pos.y = position.y;
	return pos;
}

std::pair<SArea*, bool> CTerrainManager::GetCurrentMapArea(CCircuitDef* cdef, const AIFloat3& position)
{
	SMobileType* mobileType = GetMobileTypeById(cdef->GetMobileId());
	if (mobileType == nullptr) {  // flying units & buildings
		return std::make_pair(nullptr, true);
	}

	// other mobile units & their factories
	AIFloat3 pos = position;
//	CorrectPosition(pos);
	const int iS = GetSectorIndex(pos);

	SArea* area = mobileType->sector[iS].area;
	if (area == nullptr) {
		// Case: 1) unit spawned/pushed/transported outside of valid area
		//       2) factory terraformed height around and became non-valid area
		SAreaSector* sector = GetAlternativeSector(nullptr, iS, mobileType);
		if (sector != nullptr) {
			area = sector->area;
		}
	}
	return std::make_pair(area, area != nullptr);
}

std::pair<SArea*, bool> CTerrainManager::GetCurrentMapArea(CCircuitDef* cdef, const int iS)
{
	SMobileType* mobileType = GetMobileTypeById(cdef->GetMobileId());
	if (mobileType == nullptr) {  // flying units & buildings
		return std::make_pair(nullptr, true);
	}

	// other mobile units & their factories
	SArea* area = mobileType->sector[iS].area;
	if (area == nullptr) {
		// Case: 1) unit spawned/pushed/transported outside of valid area
		//       2) factory terraformed height around and became non-valid area
		SAreaSector* sector = GetAlternativeSector(nullptr, iS, mobileType);
		if (sector != nullptr) {
			area = sector->area;
		}
	}
	return std::make_pair(area, area != nullptr);
}

bool CTerrainManager::CanMoveToPos(SArea* area, const AIFloat3& destination)
{
	if (!ValidReachDestination(destination)) return false;
	const int iS = GetSectorIndex(destination);
	if (!terrainData->IsSectorValid(iS)) {
		return false;
	}
	if (area == nullptr) {  // either a flying unit or a unit was somehow created at an impossible position
		return true;
	}
	if (area == GetSectorList(area)[iS].area) {
		return true;
	}
	return false;
}

AIFloat3 CTerrainManager::GetBuildPosition(CCircuitDef* cdef, const AIFloat3& position)
{
	AIFloat3 pos = position;
//	CorrectPosition(pos);
	const int iS = GetSectorIndex(pos);

	SMobileType* mobileType = GetMobileTypeById(cdef->GetMobileId());
	SImmobileType* immobileType = GetImmobileTypeById(cdef->GetImmobileId());
	if (mobileType != nullptr) {  // a factory or mobile unit
		SAreaSector* AS = GetAlternativeSector(nullptr, iS, mobileType);
		if (immobileType != nullptr) {  // a factory
			SSector* sector = GetAlternativeSector(AS->area, iS, immobileType);
			return (sector == nullptr) ? -RgtVector : sector->position;
		} else {
			return AS->S->position;
		}
	} else if (immobileType != nullptr) {  // buildings
		return GetClosestSector(immobileType, iS)->position;
	} else {
		return pos;  // flying units
	}
}

AIFloat3 CTerrainManager::GetMovePosition(SArea* sourceArea, const AIFloat3& position)
{
	AIFloat3 pos = position;
//	CorrectPosition(pos);
	const int iS = GetSectorIndex(pos);

	return (sourceArea == nullptr) ? pos : GetClosestSector(sourceArea, iS)->S->position;
}

AIFloat3 CTerrainManager::ShiftPos(CCircuitDef* cdef, const AIFloat3& position, float range, bool isOrtho)
{
	int clusterId = circuit->GetMetalManager()->FindNearestCluster(position);
	return ShiftPos(cdef, position, clusterId, range, isOrtho);
}

AIFloat3 CTerrainManager::ShiftPos(CCircuitDef* cdef, const AIFloat3& position, int clusterId, float range, bool isOrtho)
{
	AIFloat3 newPos;
	if (clusterId < 0) {
		newPos = geom::get_radial_pos(position, range);
	} else {
		const CMetalData::Clusters& clusters = circuit->GetMetalManager()->GetClusters();
		const CMetalData::SCluster& cluster = clusters[clusterId];
		if (cluster.idxSpots.size() == 1) {
			newPos = geom::get_radial_pos(position, range);
		} else {
			if (isOrtho) {
				const AIFloat3 shift = (cluster.position - position).Normalize2D();
				const AIFloat3 shifts[2] = {AIFloat3(shift.z, shift.y, -shift.x), AIFloat3(-shift.z, shift.y, shift.x)};
				int index = 0;
				if (shifts[0].dot2D(GetTerrainCenter() - position) < 0.f) {
					index = 1;
				}
				newPos = position + shifts[index] * range;
				CorrectPosition(newPos);
				if (CanBeBuiltAt(cdef, newPos)) {
					return newPos;
				} else {
					newPos = position + shifts[++index & 1] * range;
				}
			} else {
				if (cluster.position.SqDistance2D(position) < SQUARE(SQUARE_SIZE)) {
					newPos = geom::get_radial_pos(position, range);
				} else {
					newPos = position + (cluster.position - position).Normalize2D() * range;
				}
			}
		}
	}
	CorrectPosition(newPos);
	return CanBeBuiltAt(cdef, newPos) ? newPos : GetBuildPosition(cdef, newPos);
}

std::vector<SAreaSector>& CTerrainManager::GetSectorList(SArea* sourceArea)
{
	if ((sourceArea == nullptr) || (sourceArea->mobileType == nullptr)) {  // It flies or it's immobile
		return areaData->sectorAirType;
	}
	return sourceArea->mobileType->sector;
}

SAreaSector* CTerrainManager::GetClosestSectorWithAltitude(SArea* sourceArea, const int destinationSIndex, const int altitude)
{
	std::vector<SAreaSector>& TMSectors = GetSectorList(sourceArea);
	if (sourceArea == TMSectors[destinationSIndex].area) {
		return &TMSectors[destinationSIndex];
	}

	const AIFloat3& destination = TMSectors[destinationSIndex].S->position;
	SAreaSector* SClosest = nullptr;
	float sqDisClosest = std::numeric_limits<float>::max();
	for (auto& iS : sourceArea->sector) {
		float sqDist = iS.second->S->position.SqDistance2D(destination);
		if ((sqDist < sqDisClosest) && (terrainData->GetTASector(iS.first).GetMinAltitude() >= altitude)) {
			SClosest = iS.second;
			sqDisClosest = sqDist;
		}
	}
	return SClosest;
}

SAreaSector* CTerrainManager::GetClosestSector(SArea* sourceArea, const int destinationSIndex)
{
	if (sourceArea == nullptr) return nullptr;
	std::vector<SAreaSector>& TMSectors = GetSectorList(sourceArea);
	if (destinationSIndex < 0 || size_t(destinationSIndex) >= TMSectors.size()
			|| TMSectors[destinationSIndex].S == nullptr) return nullptr;
	auto iAS = sourceArea->sectorClosest.find(destinationSIndex);
	if (iAS != sourceArea->sectorClosest.end()) {  // It's already been determined
		return iAS->second;
	}

	if (sourceArea == TMSectors[destinationSIndex].area) {
		sourceArea->sectorClosest[destinationSIndex] = &TMSectors[destinationSIndex];
		return &TMSectors[destinationSIndex];
	}

	const AIFloat3& destination = TMSectors[destinationSIndex].S->position;
	SAreaSector* SClosest = nullptr;
	float sqDisClosest = std::numeric_limits<float>::max();
	for (auto& iS : sourceArea->sector) {
		float sqDist = iS.second->S->position.SqDistance2D(destination);  // TODO: Consider SqDistance() instead of 2D
		if (sqDist < sqDisClosest) {
			SClosest = iS.second;
			sqDisClosest = sqDist;
		}
	}
	sourceArea->sectorClosest[destinationSIndex] = SClosest;
	return SClosest;
}

SSector* CTerrainManager::GetClosestSector(SImmobileType* sourceIT, const int destinationSIndex)
{
	auto iS = sourceIT->sectorClosest.find(destinationSIndex);
	if (iS != sourceIT->sectorClosest.end()) {  // It's already been determined
		return iS->second;
	}

	if (sourceIT->sector.find(destinationSIndex) != sourceIT->sector.end()) {
		SSector* SClosest = &areaData->sector[destinationSIndex];
		sourceIT->sectorClosest[destinationSIndex] = SClosest;
		return SClosest;
	}

	const AIFloat3& destination = areaData->sector[destinationSIndex].position;
	SSector* SClosest = nullptr;
	float sqDisClosest = std::numeric_limits<float>::max();
	for (auto& iS : sourceIT->sector) {
		float sqDist = iS.second->position.SqDistance2D(destination);  // TODO: Consider SqDistance() instead of 2D
		if (sqDist < sqDisClosest) {
			SClosest = iS.second;
			sqDisClosest = sqDist;
		}
	}
	sourceIT->sectorClosest[destinationSIndex] = SClosest;
	return SClosest;
}

SAreaSector* CTerrainManager::GetAlternativeSector(SArea* sourceArea, const int sourceSIndex, SMobileType* destinationMT)
{
	std::vector<SAreaSector>& TMSectors = GetSectorList(sourceArea);
	auto iMS = TMSectors[sourceSIndex].sectorAlternativeM.find(destinationMT);
	if (iMS != TMSectors[sourceSIndex].sectorAlternativeM.end()) {  // It's already been determined
		return iMS->second;
	}

	if (destinationMT == nullptr) {  // flying unit movetype
		return &TMSectors[sourceSIndex];
	}

	if ((sourceArea != nullptr) && (sourceArea != TMSectors[sourceSIndex].area)) {
		return GetAlternativeSector(sourceArea, GetSectorIndex(GetClosestSector(sourceArea, sourceSIndex)->S->position), destinationMT);
	}

	const AIFloat3& position = TMSectors[sourceSIndex].S->position;
	SAreaSector* bestAS = nullptr;
	SArea* largestArea = destinationMT->areaLargest;
	float bestDistance = -1.0;
	float bestMidDistance = -1.0;
	const std::vector<SArea>& TMAreas = destinationMT->area;
	for (auto& area : TMAreas) {
		if (area.areaUsable || !largestArea->areaUsable) {
			SAreaSector* CAS = GetClosestSector(const_cast<SArea*>(&area), sourceSIndex);
			float midDistance; // how much of a gap exists between the two areas (source & destination)
			if ((sourceArea == nullptr) || (sourceArea == TMSectors[GetSectorIndex(CAS->S->position)].area)) {
				midDistance = 0.0;
			} else {
				midDistance = CAS->S->position.distance2D(GetClosestSector(sourceArea, GetSectorIndex(CAS->S->position))->S->position);
			}
			if ((bestMidDistance < 0) || (midDistance < bestMidDistance)) {
				bestMidDistance = midDistance;
				bestAS = nullptr;
				bestDistance = -1.0;
			}
			if (midDistance == bestMidDistance) {
				float distance = position.distance2D(CAS->S->position);
				if ((bestAS == nullptr) || (distance * area.percentOfMap < bestDistance * bestAS->area->percentOfMap)) {
					bestAS = CAS;
					bestDistance = distance;
				}
			}
		}
	}

	TMSectors[sourceSIndex].sectorAlternativeM[destinationMT] = bestAS;
	return bestAS;
}

SSector* CTerrainManager::GetAlternativeSector(SArea* destinationArea, const int sourceSIndex, SImmobileType* destinationIT)
{
	std::vector<SAreaSector>& TMSectors = GetSectorList(destinationArea);
	auto iMS = TMSectors[sourceSIndex].sectorAlternativeI.find(destinationIT);
	if (iMS != TMSectors[sourceSIndex].sectorAlternativeI.end()) {  // It's already been determined
		return iMS->second;
	}

	SSector* closestS = nullptr;
	if (destinationArea != nullptr) {
		if (destinationArea != TMSectors[sourceSIndex].area) {
			closestS = GetAlternativeSector(destinationArea, GetSectorIndex(GetClosestSector(destinationArea, sourceSIndex)->S->position), destinationIT);
		} else {
			const AIFloat3& position = areaData->sector[sourceSIndex].position;
			float closestDistance = std::numeric_limits<float>::max();
			for (auto& iS : destinationArea->sector) {
				float sqDist = iS.second->S->position.SqDistance2D(position);  // TODO: Consider SqDistance() instead of 2D
				if (sqDist < closestDistance) {
					closestS = iS.second->S;
					closestDistance = sqDist;
				}
			}
		}
	}

	TMSectors[sourceSIndex].sectorAlternativeI[destinationIT] = closestS;
	return closestS;
}

// NOTE: Slow after terra-update with many calls in single frame
bool CTerrainManager::CanBeBuiltAt(CCircuitDef* cdef, const AIFloat3& position, const float range)
{
	const int iS = GetSectorIndex(position);
	SSector* sector;
	SMobileType* mobileType = GetMobileTypeById(cdef->GetMobileId());
	SImmobileType* immobileType = GetImmobileTypeById(cdef->GetImmobileId());
	if (mobileType != nullptr) {  // a factory or mobile unit
		SAreaSector* AS = GetAlternativeSector(nullptr, iS, mobileType);
		if (AS == nullptr) {
			return false;  // FIXME: do not use units with typeUsable=false
		}
		if (immobileType != nullptr) {  // a factory
			sector = GetAlternativeSector(AS->area, iS, immobileType);
			if (sector == nullptr) {
				return false;
			}
		} else {
			sector = AS->S;
		}
	} else if (immobileType != nullptr) {  // buildings
		sector = GetClosestSector(immobileType, iS);
		if (sector == nullptr) {
			return false;  // FIXME: do not use buildings with typeUsable=false
		}
	} else {
		return true;  // flying units
	}

	if (sector == &GetSector(iS)) {  // the current sector is the best sector
		return true;
	}
	return sector->position.distance2D(GetSector(iS).position) < range;
}

bool CTerrainManager::CanBeBuiltAt(CCircuitDef* cdef, const AIFloat3& position)
{
	const int iS = GetSectorIndex(position);
	SMobileType* mobileType = GetMobileTypeById(cdef->GetMobileId());
	SImmobileType* immobileType = GetImmobileTypeById(cdef->GetImmobileId());
	if (mobileType != nullptr) {  // a factory or mobile unit
		const SArea* area = mobileType->sector[iS].area;
		if (area == nullptr) {
			return false;
		}
		/*
		 * NOTE: `areaUsable` means "this connected area covers at least 16% of
		 *       the map" - a relative test with no absolute floor. On Eight
		 *       Horses the water is two ~4% pools (boat9: "2 Map-Area(s)
		 *       occupying 8.26%"), so no naval area is ever usable, this vetoed
		 *       every shipyard site, and the SEA role re-picked a shipyard every
		 *       240 frames for the whole game without ever building one.
		 *
		 *       GetAlternativeSector and the (cdef, pos, range) overload already
		 *       degrade this same test - `area.areaUsable || !largestArea->
		 *       areaUsable` - taking a usable area when one exists and dropping
		 *       the requirement when the move type has none anywhere on the map.
		 *       This overload is the only one that treated it as an absolute
		 *       veto. Match the rest.
		 *
		 *       This does not let a shipyard onto dry land: the sector must
		 *       still belong to an area of the move type, the immobile type must
		 *       still accept it below, and the caller still checks the engine's
		 *       own buildability. Nor does it make the AI choose navy on a land
		 *       map - CFactoryData::GetFactoryToBuild still refuses a factory
		 *       whose mobile type is unusable, so the only way here is an
		 *       explicit AngelScript SelectFactoryHandler choice.
		 */
		if (!area->areaUsable && mobileType->typeUsable) {
			return false;
		}
		if (immobileType != nullptr) {  // a factory
			if (immobileType->sector.find(iS) == immobileType->sector.end()) {
				return false;
			}
		}
	} else if (immobileType != nullptr) {  // buildings
		if (immobileType->sector.find(iS) == immobileType->sector.end()) {
			return false;
		}
	}
	return true;
}

bool CTerrainManager::CanBeBuiltAtSafe(CCircuitDef* cdef, const AIFloat3& position)
{
	if (circuit->GetThreatMap()->GetBuilderThreatAt(position) > THREAT_MIN) {
		return false;
	}
	return CanBeBuiltAt(cdef, position);
}

bool CTerrainManager::CanReachAt(CCircuitUnit* unit, const AIFloat3& destination, const float range)
{
	if (unit == nullptr || !ValidReachDestination(destination, range)) return false;
	if (unit->GetCircuitDef()->GetImmobileId() != -1) {  // A hub or factory
		return unit->GetPos(circuit->GetLastFrame()).SqDistance2D(destination) < SQUARE(range);
	}
	SArea* area = unit->GetArea();
	if (area == nullptr) {  // A flying unit
		return true;
	}
	const int iS = GetSectorIndex(destination);
	if (area->sector.find(iS) != area->sector.end()) {
		return true;
	}
	const SAreaSector* closest = GetClosestSector(area, iS);
	return closest != nullptr && closest->S != nullptr
		&& closest->S->position.SqDistance2D(destination) < SQUARE(range);
}

bool CTerrainManager::CanReachAtSafe(CCircuitUnit* unit, const AIFloat3& destination, const float range, const float threat)
{
	if (unit == nullptr || !ValidReachDestination(destination, range)) return false;
	if (circuit->GetThreatMap()->GetThreatAt(destination) > threat) {
		return false;
	}
	return CanReachAt(unit, destination, range);
}

bool CTerrainManager::CanReachAtSafe2(CCircuitUnit* unit, const AIFloat3& destination, const float range)
{
	if (unit == nullptr || !ValidReachDestination(destination, range)) return false;
	if (circuit->GetInflMap()->GetInfluenceAt(destination) < -INFL_EPS) {
		return false;
	}
	return CanReachAt(unit, destination, range);
}

bool CTerrainManager::CanMobileReachAt(SArea* area, const AIFloat3& destination, const float range)
{
	if (!ValidReachDestination(destination, range)) return false;
	if (area == nullptr) {  // A flying unit
		return true;
	}
	const int iS = GetSectorIndex(destination);
	if (area->sector.find(iS) != area->sector.end()) {
		return true;
	}
	const SAreaSector* closest = GetClosestSector(area, iS);
	return closest != nullptr && closest->S != nullptr
		&& closest->S->position.SqDistance2D(destination) < SQUARE(range);
}

bool CTerrainManager::CanMobileReachAtSafe(SArea* area, const AIFloat3& destination, const float range, const float threat)
{
	if (!ValidReachDestination(destination, range)) return false;
	if (circuit->GetThreatMap()->GetBuilderThreatAt(destination) > threat) {
		return false;
	}
	return CanMobileReachAt(area, destination, range);
}

const bwem::CArea* CTerrainManager::GetTAArea(const springai::AIFloat3& pos) const
{
	const int iS = terrainData->GetSectorIndex(pos);
	const int id = terrainData->GetTASector(iS).GetAreaId();
	if (id <= 0) {
		return nullptr;
	}
	return const_cast<const CTerrainData*>(terrainData)->GetArea(id);
}

void CTerrainManager::UpdateAreaUsers(int interval)
{
	ZoneScopedN(__PRETTY_FUNCTION__);

	areaData = terrainData->GetNextAreaData();
	const int frame = circuit->GetLastFrame();
	for (auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;

		// Similar to GetCurrentMapArea
		SArea* area = nullptr;  // flying units & buildings
		SMobileType* mobileType = GetMobileTypeById(unit->GetCircuitDef()->GetMobileId());
		if (mobileType != nullptr) {
			// other mobile units & their factories
			AIFloat3 pos = unit->GetPos(frame);
//			CorrectPosition(pos);
			const int iS = GetSectorIndex(pos);

			area = mobileType->sector[iS].area;
			if (area == nullptr) {  // unit outside of valid area
				// TODO: Rescue operation
				SAreaSector* sector = GetAlternativeSector(nullptr, iS, mobileType);
				if (sector != nullptr) {
					area = sector->area;
				} else {
					circuit->Garbage(unit, "helpless");
				}
			}
		}
		unit->SetArea(area);
	}

	circuit->GetEnemyManager()->UpdateAreaUsers(circuit);  // AllyTeam
	enemyAreas = circuit->GetEnemyManager()->GetEnemyAreas();

	circuit->GetBuilderManager()->UpdateAreaUsers();

	// stagger area update
	circuit->GetScheduler()->RunJobAfter(CScheduler::GameJob([this]() {
		circuit->GetPathfinder()->UpdateAreaUsers(this);
		MarkBusPath();

		OnAreaUsersUpdated();
	}), interval);
}

#ifdef DEBUG_VIS
void CTerrainManager::UpdateVis()
{
	if (isWidgetDrawing) {
		std::ostringstream cmd;
		cmd << "ai_blk_data:";
		for (int z = 0; z < blockingMap.rows; ++z) {
			for (int x = 0; x < blockingMap.columns; ++x) {
				const char value = blockingMap.IsBlocked(x, z, STRUCT_BIT(ALL));
				cmd.write(&value, 1);
			}
		}
		std::string s = cmd.str();
		circuit->GetLua()->CallRules(s.c_str(), s.size());
	}

	if (dbgTextureId < 0) {
		return;
	}

	for (unsigned i = 0; i < blockingMap.gridLow.size(); ++i) {
		dbgMap[i] = (blockingMap.gridLow[i].blockerMask > 0) ? 1.0f : 0.0f;
	}
	circuit->GetDebugDrawer()->UpdateOverlayTexture(dbgTextureId, dbgMap, 0, 0, blockingMap.columnsLow, blockingMap.rowsLow);
	circuit->GetDebugDrawer()->DrawMap(sdlWindowId, dbgMap, {220, 220, 0, 0});
}

void CTerrainManager::ToggleVis()
{
	if (dbgTextureId < 0) {
		// /cheat
		// /debugdrawai
		// /team N
		// /spectator
		// "~block"
		dbgMap = new float [blockingMap.gridLow.size()];
		for (unsigned i = 0; i < blockingMap.gridLow.size(); ++i) {
			dbgMap[i] = (blockingMap.gridLow[i].blockerMask > 0) ? 1.0f : 0.0f;
		}
		dbgTextureId = circuit->GetDebugDrawer()->AddOverlayTexture(dbgMap, blockingMap.columnsLow, blockingMap.rowsLow);
		circuit->GetDebugDrawer()->SetOverlayTexturePos(dbgTextureId, 0.50f, 0.25f);
		circuit->GetDebugDrawer()->SetOverlayTextureSize(dbgTextureId, 0.40f, 0.40f);
		circuit->GetDebugDrawer()->SetOverlayTextureLabel(dbgTextureId, "Blocking Map");

		std::string label = utils::int_to_string(circuit->GetSkirmishAIId(), "Circuit AI [%i] :: Blocking Map (low)");
		sdlWindowId = circuit->GetDebugDrawer()->AddSDLWindow(blockingMap.columnsLow, blockingMap.rowsLow, label.c_str());
		circuit->GetDebugDrawer()->DrawMap(sdlWindowId, dbgMap, {220, 220, 0, 0});
	} else {
		circuit->GetDebugDrawer()->DelOverlayTexture(dbgTextureId);
		circuit->GetDebugDrawer()->DelSDLWindow(sdlWindowId);
		dbgTextureId = sdlWindowId = -1;
		delete[] dbgMap;
	}
}

void CTerrainManager::ToggleWidgetDraw()
{
	std::string cmd("ai_thr_draw:");
	std::string result = circuit->GetLua()->CallRules(cmd.c_str(), cmd.size());

	isWidgetDrawing = (result == "1");
	if (isWidgetDrawing) {
		cmd = utils::int_to_string(16, "ai_thr_size:%i");
		cmd += utils::float_to_string(0, " %f");
		circuit->GetLua()->CallRules(cmd.c_str(), cmd.size());

		UpdateVis();
	}
}

void CTerrainManager::LogTerrainAt(CCircuitDef* cdef, const AIFloat3& position)
{
	const int iS = GetSectorIndex(position);
	SMobileType* mobileType = GetMobileTypeById(cdef->GetMobileId());
	SImmobileType* immobileType = GetImmobileTypeById(cdef->GetImmobileId());
	circuit->LOG("TerrainData for %s", cdef->GetDef()->GetName());
	circuit->LOG("mobileType %p", mobileType);
	if (mobileType != nullptr) {  // a factory or mobile unit
		circuit->LOG("mobileType area: %p", mobileType->sector[iS].area);
		circuit->LOG("mobileType->sector[iS].S: %p", mobileType->sector[iS].S);
		if (mobileType->sector[iS].area != nullptr) {
			circuit->LOG("mobile area usable = %i | percentOfMap = %f", mobileType->sector[iS].area->areaUsable, mobileType->sector[iS].area->percentOfMap);
		}
	}
	circuit->LOG("immobileType %p", immobileType);
	if (immobileType != nullptr) {  // buildings
		circuit->LOG("immobile sector present = %i", immobileType->sector.find(iS) != immobileType->sector.end());
	}
}
#endif

} // namespace circuit
