#include "task/builder/FactoryTask.h"
/*
 * InitScript.cpp
 *
 *  Created on: May 13, 2020
 *      Author: rlcevg
 */

#include "script/InitScript.h"
#include "script/SetupScript.h"
#include "script/ScriptManager.h"
#include "script/RefCounter.h"
#include "module/TaskModule.h"
#include "spring/SpringUnit.h"
#include "map/ThreatMap.h"
#include "scheduler/Scheduler.h"
#include "setup/SetupManager.h"
#include "resource/MetalManager.h"
#include "resource/EnergyManager.h"
#include "spring/SpringMap.h"
#include "terrain/TerrainManager.h"
#include "terrain/BattleAnalysis.h"
#include "json/json.h"
#include "UnitDef.h"
#include "task/builder/BuilderTask.h"
#include "task/builder/GuardTask.h"
#include "task/static/SuperTask.h"
#include "task/fighter/RouteTask.h"
#include "task/fighter/FerryTask.h"
#include "task/fighter/AirWaveTask.h"
#include "unit/CircuitUnit.h"
#include "unit/TransportUtils.h"
#include "CircuitAI.h"
#include "AISCommands.h"
#include "util/GameAttribute.h"
#include "util/MaskHandler.h"
#include "util/ExtAS.h"
#include "util/Utils.h"
#include "util/Performance.h"
#include "util/WidgetState.h"

#include "angelscript/include/angelscript.h"
#include "angelscript/add_on/scriptarray/scriptarray.h"
#include "angelscript/add_on/scriptdictionary/scriptdictionary.h"
// FIXME: MinGW didn't like asbind20
//#include "asbind20/asbind.hpp"
//#include "asbind20/operators.hpp"  // _this, const_this, param<T>, ->return<T>()

#include "spring/SpringMap.h"

#include "Log.h"
#include "Drawer.h"
#include "Game.h"
#include "Team.h"
#include "Lua.h"

#include <format>
#include <atomic>

namespace circuit {

using namespace springai;

CInitScript::SInitInfo::SInitInfo(const SInitInfo& o)
{
	armor = o.armor;
	category = o.category;
	if (profile != nullptr) {
		profile->Release();
	}
	profile = o.profile;
	if (profile != nullptr) {
		profile->AddRef();
	}
}

CInitScript::SInitInfo::~SInitInfo()
{
	if (profile != nullptr) {
		profile->Release();
	}
}

static void AddAirArmor(CCircuitDef::SArmorInfo* mem, int type)
{
	mem->airTypes.push_back(type);
}

static void AddSurfaceArmor(CCircuitDef::SArmorInfo* mem, int type)
{
	mem->surfTypes.push_back(type);
}

static void AddWaterArmor(CCircuitDef::SArmorInfo* mem, int type)
{
	mem->waterTypes.push_back(type);
}

static void ConstructVec3(float3* mem)
{
	new(mem) float3();
}

static void ConstructCopyVec3(float3* mem, const float3& o)
{
	new(mem) float3(o);
}

static void ConstructVec3Val1(float3* mem, float a)
{
	new(mem) float3(a);
}

static void ConstructVec3Val3(float3* mem, float x, float y, float z)
{
	new(mem) float3(x, y, z);
}

static std::string ConvertVec3ToStr(const float3& f)
{
	return f.str();  // static_cast<const AIFloat3&>(f).ToString();
}

static geom::CPolygon* FactoryCPolygon(const CScriptArray* array)
{
	F3Vec points;
	points.reserve(array->GetSize());
	for (asUINT i = 0; i < array->GetSize(); ++i) {
		points.push_back(*static_cast<const AIFloat3*>(array->At(i)));
	}
	return new geom::CPolygon(std::move(points));
}

static CScriptArray* CBattleAnalysis_GetLaneRoute(CBattleAnalysis* battle, int lane, const AIFloat3& from, int cls)
{
	asIScriptEngine* engine = asGetActiveContext()->GetEngine();
	auto* cache = static_cast<CScriptManager::STypeInfoCache*>(engine->GetUserData());
	const auto points = battle->GetLaneRoute(lane, from, cls);
	CScriptArray* array = CScriptArray::Create(cache->vec3Array, static_cast<asUINT>(points.size()));
	for (asUINT i = 0; i < array->GetSize(); ++i) *static_cast<AIFloat3*>(array->At(i)) = points[i];
	return array;
}

static bool CFerryTask_SetCargoRoute(CFerryTask* task, int id, const CScriptArray* array,
        float surfaceThreat, float airThreat, float padding, float blockedSeconds)
{
    if (array==nullptr || array->GetSize()>32) return false;
    F3Vec points;
    points.reserve(array->GetSize());
    for (asUINT i=0; i<array->GetSize(); ++i) points.push_back(*static_cast<const AIFloat3*>(array->At(i)));
    return task->SetCargoRoute(id,points,surfaceThreat,airThreat,padding,blockedSeconds);
}

static CScriptArray* CBattleAnalysis_GetTerrainRoute(CBattleAnalysis* battle, const AIFloat3& from,
        const AIFloat3& to, int cls, float landCost, float waterCost, float threatWeight, float maxWaterThreat)
{
    auto* cache = static_cast<CScriptManager::STypeInfoCache*>(asGetActiveContext()->GetEngine()->GetUserData());
    const auto points = battle->GetTerrainRoute(from, to, cls, landCost, waterCost, threatWeight, maxWaterThreat);
    CScriptArray* array = CScriptArray::Create(cache->vec3Array, static_cast<asUINT>(points.size()));
    for (asUINT i = 0; i < array->GetSize(); ++i) *static_cast<AIFloat3*>(array->At(i)) = points[i];
    return array;
}

static CScriptArray* CBattleAnalysis_GetUnitTerrainRoute(CBattleAnalysis* battle, const CCircuitDef* def,
        const AIFloat3& from, const AIFloat3& to, bool dry, float landCost, float waterCost,
        float threatWeight, float maxWaterThreat)
{
    auto* cache=static_cast<CScriptManager::STypeInfoCache*>(asGetActiveContext()->GetEngine()->GetUserData());
    const auto points=battle->GetUnitTerrainRoute(def,from,to,dry,landCost,waterCost,threatWeight,maxWaterThreat);
    auto* array=CScriptArray::Create(cache->vec3Array,static_cast<asUINT>(points.size()));
    for (asUINT i=0;i<array->GetSize();++i) *static_cast<AIFloat3*>(array->At(i))=points[i];
    return array;
}

// D-296: scout raid route over the observed ground-hazard layer.
static CScriptArray* CBattleAnalysis_GetUnitRaidRoute(CBattleAnalysis* battle, const CCircuitDef* def,
        const AIFloat3& from, const AIFloat3& to, float hazardMargin, float hazardWeight, bool avoidHazards)
{
    auto* cache=static_cast<CScriptManager::STypeInfoCache*>(asGetActiveContext()->GetEngine()->GetUserData());
    const auto points=battle->GetUnitRaidRoute(def,from,to,hazardMargin,hazardWeight,avoidHazards);
    auto* array=CScriptArray::Create(cache->vec3Array,static_cast<asUINT>(points.size()));
    for (asUINT i=0;i<array->GetSize();++i) *static_cast<AIFloat3*>(array->At(i))=points[i];
    return array;
}

static CScriptArray* CPolygon_GetVerts(geom::CPolygon* poly)
{
	asIScriptEngine* engine = asGetActiveContext()->GetEngine();
	auto cache = static_cast<CScriptManager::STypeInfoCache*>(engine->GetUserData());
	CScriptArray* arr = CScriptArray::Create(cache->vec3Array, poly->GetVerts().size());
	asUINT i = 0;
	for (const AIFloat3& vert : poly->GetVerts()) {
		*(AIFloat3*)arr->At(i++) = vert;  // arr->SetValue(i++, (void*)&vert);
	}
	return arr;
}

static void ConstructSArmorInfo(CCircuitDef::SArmorInfo* mem)
{
	new(mem) CCircuitDef::SArmorInfo();
}

static void ConstructCopySArmorInfo(CCircuitDef::SArmorInfo* mem, const CCircuitDef::SArmorInfo& o)
{
	new(mem) CCircuitDef::SArmorInfo(o);
}

static void DestructSArmorInfo(CCircuitDef::SArmorInfo *mem)
{
	mem->~SArmorInfo();
}

static CCircuitDef::SArmorInfo& AssignSArmorInfoToSArmorInfo(CCircuitDef::SArmorInfo& mem, const CCircuitDef::SArmorInfo& o)
{
	mem = o;
	return mem;
}

static void ConstructSCategoryInfo(CInitScript::SInitInfo::SCategoryInfo* mem)
{
	new(mem) CInitScript::SInitInfo::SCategoryInfo();
}

static void ConstructCopySCategoryInfo(CInitScript::SInitInfo::SCategoryInfo* mem, const CInitScript::SInitInfo::SCategoryInfo& o)
{
	new(mem) CInitScript::SInitInfo::SCategoryInfo(o);
}

static void DestructSCategoryInfo(CInitScript::SInitInfo::SCategoryInfo *mem)
{
	mem->~SCategoryInfo();
}

static CInitScript::SInitInfo::SCategoryInfo& AssignSCategoryInfoToSCategoryInfo(CInitScript::SInitInfo::SCategoryInfo& mem, const CInitScript::SInitInfo::SCategoryInfo& o)
{
	mem = o;
	return mem;
}

static void ConstructSInitInfo(CInitScript::SInitInfo* mem)
{
	new(mem) CInitScript::SInitInfo();
}

static void ConstructCopySInitInfo(CInitScript::SInitInfo* mem, const CInitScript::SInitInfo& o)
{
	new(mem) CInitScript::SInitInfo(o);
}

static void DestructSInitInfo(CInitScript::SInitInfo *mem)
{
	mem->~SInitInfo();
}

static CCircuitDef* CCircuitAI_GetCircuitDef(CCircuitAI* circuit, const std::string& name)
{
	return circuit->GetCircuitDef(name.c_str());
}

static std::string CCircuitAI_GetMapName(CCircuitAI* circuit)
{
	return circuit->GetMap()->GetName();
}

static int CCircuitAI_GetLeadTeamId(CCircuitAI* circuit)
{
	return circuit->GetAllyTeam()->GetLeaderId();
}

static CScriptArray* CCircuitAI_GetTeamIds(CCircuitAI* circuit)
{
	asIScriptEngine* engine = asGetActiveContext()->GetEngine();
	auto cache = static_cast<CScriptManager::STypeInfoCache*>(engine->GetUserData());
	CAllyTeam* allyTeam = circuit->GetAllyTeam();
	CScriptArray* arr = CScriptArray::Create(cache->idArray, allyTeam->GetSize());
	asUINT i = 0;
	for (CAllyTeam::Id teamId : allyTeam->GetTeamIds()) {
		*(CAllyTeam::Id*)arr->At(i++) = teamId;
	}
	return arr;
}

static int CTerrainManager_ReserveBuilding(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& pos, int facing, int ttlFrames)
{
	return terrainMgr->ReserveBuilding(const_cast<CCircuitDef*>(cdef), pos, facing, ttlFrames, 0);
}

static int CTerrainManager_ReservePersistentBuilding(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& pos, int facing)
{
	return terrainMgr->ReservePersistentBuilding(const_cast<CCircuitDef*>(cdef), pos, facing);
}

static AIFloat3 CTerrainManager_FindSafeDropSpot(CTerrainManager* mgr, CCircuitUnit* cargo,
        const AIFloat3& at, float radius, float surface, float air)
{
    return mgr->FindDropSpot(cargo, at, radius, {}, 0.f, surface, air);
}

// Owned IDs only: scripts resolve each ID at use time, never retain borrowed units.
static CScriptArray* CCircuitAI_GetOwnedUnitIds(CCircuitAI* circuit)
{
	asIScriptEngine* engine = asGetActiveContext()->GetEngine();
	auto* cache = static_cast<CScriptManager::STypeInfoCache*>(engine->GetUserData());
	const auto& units = circuit->GetTeamUnits();
	CScriptArray* arr = CScriptArray::Create(cache->idArray, static_cast<asUINT>(units.size()));
	asUINT index = 0;
	for (const auto& [id, unit] : units) {
		*static_cast<ICoreUnit::Id*>(arr->At(index++)) = id;
	}
	return arr;
}

static int CTerrainManager_ReserveGrid(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& frontCentre,
		int facing, int cols, int rows, int gap, int ttlFrames)
{
	return terrainMgr->ReserveGrid(const_cast<CCircuitDef*>(cdef), frontCentre, facing, cols, rows, gap, ttlFrames);
}

static int CTerrainManager_ReserveNanoBlockAt(CTerrainManager* terrainMgr, const CCircuitDef* nanoDef, const CCircuitDef* facDef,
		const AIFloat3& facPos, int facing, int cols, int rows, int gap)
{
	return terrainMgr->ReserveNanoBlockAt(const_cast<CCircuitDef*>(nanoDef), const_cast<CCircuitDef*>(facDef), facPos, facing, cols, rows, gap);
}

static int CTerrainManager_ReserveNanoBlock(CTerrainManager* terrainMgr, CCircuitUnit* factory, const CCircuitDef* nanoDef, int cols, int rows, int gap)
{
	return terrainMgr->ReserveNanoBlock(factory, const_cast<CCircuitDef*>(nanoDef), cols, rows, gap);
}

static bool CTerrainManager_CanReserveBuilding(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& pos, int facing)
{
	return terrainMgr->CanReserveBuilding(const_cast<CCircuitDef*>(cdef), pos, facing);
}

// Terrain-only upgrade test: the old extractor occupies the footprint until
// CMexTask reclaims it, so ordinary engine buildability is not the right query.
static bool CTerrainManager_CanUpgradeTerrain(CTerrainManager* mgr, CCircuitDef* def, const AIFloat3& pos)
{
	if (def == nullptr || pos.x < 0 || pos.z < 0 || pos.x >= CTerrainManager::GetTerrainWidth()
	    || pos.z >= CTerrainManager::GetTerrainHeight()) return false;
	const float height = mgr->GetAreaData()->GetElevationAt(pos.x,pos.z);
	return (def->GetDef()->GetMinWaterDepth() <= 0.f || height <= -def->GetDef()->GetMinWaterDepth())
	    && height >= -def->GetDef()->GetMaxWaterDepth()
	    && mgr->CanBeBuiltAtSafe(def,pos);
}

static float CTerrainManager_BuildableFraction(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& centre, float halfAcross, float halfAlong, int facing)
{
	return terrainMgr->BuildableFraction(const_cast<CCircuitDef*>(cdef), centre, halfAcross, halfAlong, facing);
}

static int CTerrainManager_GetReservationCount(CTerrainManager* terrainMgr, const CCircuitDef* cdef)
{
	return terrainMgr->GetReservationCount(const_cast<CCircuitDef*>(cdef));
}

static int CTerrainManager_LayBand(CTerrainManager* terrainMgr, int zone, const CCircuitDef* cdef, const AIFloat3& frontCentre,
		int facing, int cols, int rows, int gap, bool armed, bool anyReach, bool tenant, int group)
{
	return terrainMgr->LayBand(zone, const_cast<CCircuitDef*>(cdef), frontCentre, facing, cols, rows, gap, armed, anyReach, tenant, group);
}

static int CTerrainManager_PackNearGroup(CTerrainManager* terrainMgr, int zone, const CCircuitDef* cdef, int nanoGroup,
		int facing, const AIFloat3& anchor, float maxReach, float minNanoDist, int group)
{
	return terrainMgr->PackNearGroup(zone, const_cast<CCircuitDef*>(cdef), nanoGroup, facing, anchor, maxReach, minNanoDist, group);
}

static bool CTerrainManager_IsExitClear(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& pos, int facing, float length, float margin)
{
	return terrainMgr->IsExitClear(const_cast<CCircuitDef*>(cdef), pos, facing, length, margin);
}
static int CTerrainManager_PackSet(CTerrainManager* terrainMgr, int zone, const CCircuitDef* cdef, int nanoGroup, int facing, const AIFloat3& anchor, int count, bool ring, int maximumGapCells)
{
	return terrainMgr->PackSet(zone, const_cast<CCircuitDef*>(cdef), nanoGroup, facing, anchor, count, ring, maximumGapCells);
}

static float CCircuitUnit_GetBuildProgress(CCircuitUnit* u)
{
	return ((u == nullptr) || (u->GetUnit() == nullptr)) ? 1.f : u->GetUnit()->GetBuildProgress();   // D-105
}

// Read-only mechanism for script resource policy. Call on the AI thread;
// stockpile readiness is engine state, not an estimated construction timer.
static int CCircuitUnit_GetStockpile(CCircuitUnit* u)
{
	return ((u == nullptr) || (u->GetUnit() == nullptr)) ? 0 : std::max(0, u->GetUnit()->GetStockpile());
}

static int CTerrainManager_PackFactoryFlush(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& anchor)
{
	return terrainMgr->PackFactoryFlush(const_cast<CCircuitDef*>(cdef), anchor);
}

static bool IBuilderTask_PreferFactoryFacing(IUnitTask* task, int facing)
{
    auto* factory = dynamic_cast<CBFactoryTask*>(task);
    if (!factory || factory->GetTarget() || facing < 0 || facing > 3) return false;
    factory->PreferFacing(facing);
    return true;
}

static int CTerrainManager_NextSetSlot(CTerrainManager* terrainMgr, const CCircuitDef* cdef)
{
	return terrainMgr->NextSetSlot(const_cast<CCircuitDef*>(cdef));
}

static int CTerrainManager_ReleaseSetSlots(CTerrainManager* terrainMgr, const CCircuitDef* cdef)
{
	return terrainMgr->ReleaseSetSlots(const_cast<CCircuitDef*>(cdef));
}

static int CTerrainManager_EdgeGapToGroup(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& pos, int facing, int group)
{
	return terrainMgr->EdgeGapToGroup(const_cast<CCircuitDef*>(cdef), pos, facing, group);
}

static int CTerrainManager_PickMost(CTerrainManager* terrainMgr, int zone, const CCircuitDef* cdef, int nanoGroup, int facing, float reach, float flush, const AIFloat3& seed, AIFloat3& outPos)
{
	return terrainMgr->PickMost(zone, const_cast<CCircuitDef*>(cdef), nanoGroup, facing, reach, flush, seed, outPos);
}
static int CTerrainManager_PackNearGroupMost(CTerrainManager* terrainMgr, int zone, const CCircuitDef* cdef, int nanoGroup, int facing, float reach, float flush, int group, const AIFloat3& seed)
{
	return terrainMgr->PackNearGroupMost(zone, const_cast<CCircuitDef*>(cdef), nanoGroup, facing, reach, flush, group, seed);
}
static bool CTerrainManager_CanPackNearGroup(CTerrainManager* terrainMgr, int zone, const CCircuitDef* cdef, int nanoGroup,
		int facing, float maxReach, float minNanoDist)
{
	return terrainMgr->CanPackNearGroup(zone, const_cast<CCircuitDef*>(cdef), nanoGroup, facing, maxReach, minNanoDist);
}

static bool CTerrainManager_PlanFactoryPair(CTerrainManager* terrainMgr, const std::string& name,
		const CCircuitDef* firstFactory, const CCircuitDef* secondFactory, const CCircuitDef* nanoDef,
		const AIFloat3& base, int facing, int sideOffsetCells, int forwardOffsetCells)
{
	return terrainMgr->PlanFactoryPair(name, const_cast<CCircuitDef*>(firstFactory),
			const_cast<CCircuitDef*>(secondFactory), const_cast<CCircuitDef*>(nanoDef),
			base, facing, sideOffsetCells, forwardOffsetCells);
}

static bool CTerrainManager_PlanAirFactoryCluster(CTerrainManager* terrainMgr, const std::string& name,
		const CCircuitDef* firstFactory, const CCircuitDef* repeatedFactory, const CCircuitDef* nanoDef,
		const AIFloat3& origin, int facing, int count, int columns, int firstNanos)
{
	return terrainMgr->PlanAirFactoryCluster(name, const_cast<CCircuitDef*>(firstFactory),
			const_cast<CCircuitDef*>(repeatedFactory), const_cast<CCircuitDef*>(nanoDef),
			origin, facing, count, columns, firstNanos);
}

static bool IBuilderTask_PinReservation(IUnitTask* task, int id)
{
	IBuilderTask* bt = dynamic_cast<IBuilderTask*>(task);
	return (bt != nullptr) && bt->PinReservation(id);
}

// The map's economy constants for the eco planner (D-058).
static float CCircuitAI_WindMin(CCircuitAI* circuit) { return circuit->GetMap()->GetMinWind(); }
static float CCircuitAI_WindMax(CCircuitAI* circuit) { return circuit->GetMap()->GetMaxWind(); }
static float CCircuitAI_WindCur(CCircuitAI* circuit) { return circuit->GetMap()->GetCurWind(); }
static float CCircuitAI_Tidal(CCircuitAI* circuit) { return circuit->GetMap()->GetTidalStrength(); }
// D-072: the engine's per-team income multiplier (the lobby's handicap / bonus)
static float CCircuitAI_IncomeMultiplier(CCircuitAI* circuit) { return circuit->GetGame()->GetTeamIncomeMultiplier(circuit->GetTeamId()); }
static int CCircuitAI_MetalSpots(CCircuitAI* circuit) { return (int)circuit->GetMetalManager()->GetSpots().size(); }
// Read-only strategic survey; reuse the resource manager's engine feature scan.
static int CCircuitAI_GeoSpots(CCircuitAI* circuit) { return (int)circuit->GetEnergyManager()->GetSpots().size(); }
static AIFloat3 CCircuitAI_GeoSpot(CCircuitAI* circuit, int index) {
	const auto& spots = circuit->GetEnergyManager()->GetSpots();
	return (index >= 0 && index < (int)spots.size()) ? spots[index] : AIFloat3(-1.f, 0.f, -1.f);
}

// D-127: the intro is drawn by skirmish AI 0; the other AI instances in this
// library wait for it before drawing their lanes. Every AI of a game runs in
// one process, so a library-wide value carries it.
static std::atomic<int> introDoneFrame(-1);
static void AiMarkIntroDone(int frame) { introDoneFrame = frame; }
static int AiIntroDoneFrame() { return introDoneFrame; }

static AIFloat3 CSetupManager_GetLanePos(CSetupManager* setupMgr)
{
	return setupMgr->GetLanePos();
}

// D-126: settings from the merged JSON config ("weapons/budget/share"). A path
// that is missing, or of another type, returns the script's default.
static const Json::Value* ConfigAt(CSetupManager* setupMgr, const std::string& path)
{
	const Json::Value* v = setupMgr->GetScriptConfig();
	if (v == nullptr) {
		return nullptr;
	}
	size_t start = 0;
	while (start <= path.size()) {
		const size_t end = path.find('/', start);
		const std::string key = path.substr(start, (end == std::string::npos) ? std::string::npos : end - start);
		if (!v->isObject() || !v->isMember(key)) {
			return nullptr;
		}
		v = &(*v)[key];
		if (end == std::string::npos) {
			break;
		}
		start = end + 1;
	}
	return v;
}

static float CSetupManager_ConfigFloat(CSetupManager* setupMgr, const std::string& path, float def)
{
	const Json::Value* v = ConfigAt(setupMgr, path);
	return ((v != nullptr) && v->isNumeric()) ? v->asFloat() : def;
}

static int CSetupManager_ConfigInt(CSetupManager* setupMgr, const std::string& path, int def)
{
	const Json::Value* v = ConfigAt(setupMgr, path);
	return ((v != nullptr) && v->isNumeric()) ? v->asInt() : def;
}

static bool CSetupManager_ConfigBool(CSetupManager* setupMgr, const std::string& path, bool def)
{
	const Json::Value* v = ConfigAt(setupMgr, path);
	return ((v != nullptr) && v->isBool()) ? v->asBool() : def;
}

static std::string CSetupManager_ConfigString(CSetupManager* setupMgr, const std::string& path, const std::string& def)
{
	const Json::Value* v = ConfigAt(setupMgr, path);
	return ((v != nullptr) && v->isString()) ? v->asString() : def;
}

static bool IBuilderTask_IsLayoutOwned(IUnitTask* task)
{
    const auto* builderTask = dynamic_cast<IBuilderTask*>(task);
    return builderTask != nullptr && builderTask->IsLayoutOwned();
}

static int IBuilderTask_GetReservationId(IUnitTask* task)
{
	IBuilderTask* bt = dynamic_cast<IBuilderTask*>(task);
	return (bt != nullptr) ? bt->GetReservationId() : -1;
}

// Footprint in blocking-map cells (16 elmos), what the reservation API measures in.
// D-121: a builder can walk (or float) to within range of pos (its movement
// area's sectors). Threat is not asked: a site is planned for the game, and a
// scout near it would veto it (played: every site refused with the Safe test)
static bool CTerrainManager_CanReachAt(CTerrainManager* mgr, CCircuitUnit* unit, const AIFloat3& pos, float range)
{
	return (unit != nullptr) && mgr->CanReachAt(unit, pos, range);
}

static int CCircuitDef_GetFootprintX(const CCircuitDef* cdef)
{
	return (cdef->GetDef() == nullptr) ? 0 : cdef->GetDef()->GetXSize() / 2;
}

static bool CCircuitDef_CanTransport(const CCircuitDef* carrier, const CCircuitDef* cargo)
{
    return cargo != nullptr && transport::CanCarry(carrier->GetDef(), cargo->GetDef());
}

static int CCircuitDef_GetFootprintZ(const CCircuitDef* cdef)
{
	return (cdef->GetDef() == nullptr) ? 0 : cdef->GetDef()->GetZSize() / 2;
}

static int CTerrainManager_GetTerrainWidth(CTerrainManager* terrainMgr)
{
	return CTerrainManager::GetTerrainWidth();
}

static bool CTerrainManager_CanMoveTo(CTerrainManager* terrainMgr, CCircuitUnit* unit, const AIFloat3& pos)
{
    // Area membership is a read-only terrain lookup; no path search or orders.
    return unit != nullptr && std::isfinite(pos.x) && std::isfinite(pos.z)
        && pos.x >= 0.f && pos.z >= 0.f && pos.x < CTerrainManager::GetTerrainWidth()
        && pos.z < CTerrainManager::GetTerrainHeight()
        && terrainMgr->CanMoveToPos(unit->GetArea(), pos);
}

static int CTerrainManager_GetTerrainHeight(CTerrainManager* terrainMgr)
{
	return CTerrainManager::GetTerrainHeight();
}

static bool CTerrainManager_CanTraverse(CTerrainManager* mgr, CCircuitDef* def,
        const AIFloat3& from, const AIFloat3& to)
{
    const auto valid = [](const AIFloat3& p) {
        return std::isfinite(p.x) && std::isfinite(p.z) && p.x >= 0.f && p.z >= 0.f
            && p.x < CTerrainManager::GetTerrainWidth() && p.z < CTerrainManager::GetTerrainHeight();
    };
    if (!def || def->GetMobileId() < 0 || !valid(from) || !valid(to)) return false;
    const auto area = mgr->GetCurrentMapArea(def, from);
    return area.second && area.first && mgr->CanMoveToPos(area.first, to);
}

// Confirm transfers against engine ownership, not the donor's local registry:
// GiveUnits removes local task ownership before the engine processes the gift.
static int CCircuitAI_GetFriendlyUnitTeam(CCircuitAI* circuit, int unitId)
{
    auto* unit = circuit->GetFriendlyUnit(unitId);
    return unit ? unit->GetUnit()->GetTeam() : -1;
}

// A roster publishes identity, not movement. Resolve one allied unit through the
// existing ally index (O(log F), no army census/allocation). Copy the position;
// never expose a borrowed ally wrapper to script. Engine ownership is checked
// because an announced commander may die or be transferred between updates.
static AIFloat3 CCircuitAI_GetFriendlyUnitPosition(CCircuitAI* circuit, int unitId, int expectedTeam)
{
    auto* unit = circuit->GetFriendlyUnit(unitId);
    if (unit == nullptr || unit->GetUnit()->GetTeam() != expectedTeam
            || unit->GetUnit()->GetHealth() <= 0.f) return AIFloat3(-1.f, 0.f, -1.f);
    return unit->GetPos(circuit->GetLastFrame());
}

static bool CTerrainManager_CanReserveNanoBlockAt(CTerrainManager* terrainMgr, const CCircuitDef* nanoDef, const CCircuitDef* facDef,
        const AIFloat3& facPos, int facing, int cols, int rows, int gap)
{
    return terrainMgr->CanReserveNanoBlockAt(const_cast<CCircuitDef*>(nanoDef), const_cast<CCircuitDef*>(facDef), facPos, facing, cols, rows, gap);
}

static bool CTerrainManager_CanReachAtSafe(CTerrainManager* mgr, CCircuitUnit* unit, const AIFloat3& pos, float range)
{
	return unit != nullptr && mgr->CanReachAtSafe(unit, pos, range);
}

static void CCircuitAI_GiveUnits(CCircuitAI* circuit, const CScriptArray* array, int newTeamId)
{
	std::vector<CCircuitUnit*> units;
	units.reserve(array->GetSize());
	for (asUINT i = 0; i < array->GetSize(); ++i) {
		units.push_back(*static_cast<CCircuitUnit* const*>(array->At(i)));
	}
	circuit->GiveUnits(std::move(units), newTeamId);
}

static std::string CCircuitAI_CallRules(CCircuitAI* circuit, const std::string& data)
{
	return circuit->GetLua()->CallRules(data.c_str(), data.size());
}

static std::string CCircuitAI_CallUI(CCircuitAI* circuit, const std::string& data)
{
	return circuit->GetLua()->CallUI(data.c_str(), data.size());
}

// D-300: AI -> widget state file (BAR's user-widget sandbox drops CallUI).
static void CCircuitAI_SetWidgetState(CCircuitAI* circuit, const std::string& key, const std::string& value)
{
	CWidgetState* state = circuit->GetWidgetState();
	if (state != nullptr) {
		state->SetState(key, value);
	}
}

static void CCircuitAI_PushWidgetEvent(CCircuitAI* circuit, const std::string& line)
{
	CWidgetState* state = circuit->GetWidgetState();
	if (state != nullptr) {
		state->PushEvent(line);
	}
}

static void CCircuitAI_SetWidgetStateTiming(CCircuitAI* circuit, int quietMs, int maxDelayMs)
{
	CWidgetState* state = circuit->GetWidgetState();
	if (state != nullptr) {
		state->SetTiming(quietMs, maxDelayMs);
	}
}

static float CCircuitAI_GetGameRulesParamFloat(CCircuitAI* circuit, const std::string& key, float defVal)
{
	return circuit->GetGame()->GetRulesParamFloat(key.c_str(), defVal);
}

static std::string CCircuitAI_GetGameRulesParamString(CCircuitAI* circuit, const std::string& key, const std::string& defVal)
{
	return circuit->GetGame()->GetRulesParamString(key.c_str(), defVal.c_str());
}

static float CCircuitAI_GetTeamRulesParamFloat(CCircuitAI* circuit, const std::string& key, float defVal)
{
	return circuit->GetTeam()->GetRulesParamFloat(key.c_str(), defVal);
}

static std::string CCircuitAI_GetTeamRulesParamString(CCircuitAI* circuit, const std::string& key, const std::string& defVal)
{
	return circuit->GetTeam()->GetRulesParamString(key.c_str(), defVal.c_str());
}

static const std::string CCircuitDef_GetName(CCircuitDef* cdef)
{
	return cdef->GetDef()->GetName();
}

static float CCircuitUnit_GetRulesParamFloat(CCircuitUnit* unit, const std::string& key, float defVal)
{
	return unit->GetUnit()->GetRulesParamFloat(key.c_str(), defVal);
}

static std::string CCircuitUnit_GetRulesParamString(CCircuitUnit* unit, const std::string& key, const std::string& defVal)
{
	return unit->GetUnit()->GetRulesParamString(key.c_str(), defVal.c_str());
}

static CScriptArray* IUnitTask_GetUnits(IUnitTask* task)
{
	asIScriptEngine* engine = asGetActiveContext()->GetEngine();
	auto cache = static_cast<CScriptManager::STypeInfoCache*>(engine->GetUserData());
	CScriptArray* arr = CScriptArray::Create(cache->unitArray, task->GetAssignees().size());
	asUINT i = 0;
	for (CCircuitUnit* unit : task->GetAssignees()) {
		arr->SetValue(i++, &unit);
	}
	return arr;
}

template<class From, class To>
To* RefCast(From* src)
{
	// If the handle already is a null handle, then just return the null handle
	if (!src) return nullptr;

	// Now try to dynamically cast the pointer to the wanted type
	To* dst = dynamic_cast<To*>(src);
	if (dst != nullptr) {
		// Since the cast was made, we need to increase the ref counter for the returned handle
		dst->AddRef();
	}
	return dst;
}

template <class Base, class Derived>
void RegisterCast(asIScriptEngine *engine, const char *base, const char* derived)
{
	int r;
	r = engine->RegisterObjectMethod(base, std::format("{}@ opCast()", derived).c_str(), asFUNCTION((RefCast<Base, Derived>)), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(derived, std::format("{}@ opImplCast()", base).c_str(), asFUNCTION((RefCast<Derived, Base>)), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(base, std::format("const {}@ opCast() const", derived).c_str(), asFUNCTION((RefCast<Base, Derived>)), asCALL_CDECL_OBJLAST); ASSERT( r >= 0 );
	r = engine->RegisterObjectMethod(derived, std::format("const {}@ opImplCast() const", base).c_str(), asFUNCTION((RefCast<Derived, Base>)), asCALL_CDECL_OBJLAST); ASSERT( r >= 0 );
}

CInitScript::CInitScript(CScriptManager* scr, CCircuitAI* ai)
		: IScript(scr)
		, circuit(ai)
{
}

CInitScript::~CInitScript()
{
	for (auto& kv : takenContexts) {
		if (kv.second) {
			kv.second->Release();  // dictionary param
		}
		script->ReleaseContext(kv.first);
	}
}

bool CInitScript::InitConfig(const std::string& profile,
		std::vector<std::string>& outCfgParts, CCircuitDef::SArmorInfo& outArmor)
{
	asIScriptEngine* engine = script->GetEngine();
	// FIXME: asASSERT( refCount == 0 ); at lib/angelscript/source/as_configgroup.cpp:157
	//        on exit
//	int r = engine->BeginConfigGroup(CScriptManager::initName.c_str()); ASSERT(r >= 0);
	int r = engine->RegisterObjectType("SArmorInfo", sizeof(CCircuitDef::SArmorInfo), asOBJ_VALUE | asGetTypeTraits<CCircuitDef::SArmorInfo>()); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SArmorInfo", asBEHAVE_CONSTRUCT, "void f()", asFUNCTION(ConstructSArmorInfo), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SArmorInfo", asBEHAVE_CONSTRUCT, "void f(const SArmorInfo& in)", asFUNCTION(ConstructCopySArmorInfo), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SArmorInfo", asBEHAVE_DESTRUCT, "void f()", asFUNCTION(DestructSArmorInfo), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("SArmorInfo", "SArmorInfo &opAssign(const SArmorInfo &in)", asFUNCTION(AssignSArmorInfoToSArmorInfo), asCALL_CDECL_OBJFIRST); assert( r >= 0 );
	r = engine->RegisterObjectMethod("SArmorInfo", "void AddAir(int)", asFUNCTION(AddAirArmor), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("SArmorInfo", "void AddSurface(int)", asFUNCTION(AddSurfaceArmor), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("SArmorInfo", "void AddWater(int)", asFUNCTION(AddWaterArmor), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectType("SCategoryInfo", sizeof(SInitInfo::SCategoryInfo), asOBJ_VALUE | asGetTypeTraits<SInitInfo::SCategoryInfo>()); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SCategoryInfo", asBEHAVE_CONSTRUCT, "void f()", asFUNCTION(ConstructSCategoryInfo), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SCategoryInfo", asBEHAVE_CONSTRUCT, "void f(const SCategoryInfo& in)", asFUNCTION(ConstructCopySCategoryInfo), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SCategoryInfo", asBEHAVE_DESTRUCT, "void f()", asFUNCTION(DestructSCategoryInfo), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("SCategoryInfo", "SCategoryInfo &opAssign(const SCategoryInfo &in)", asFUNCTION(AssignSCategoryInfoToSCategoryInfo), asCALL_CDECL_OBJFIRST); assert( r >= 0 );
	r = engine->RegisterObjectProperty("SCategoryInfo", "string air", asOFFSET(SInitInfo::SCategoryInfo, air)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SCategoryInfo", "string land", asOFFSET(SInitInfo::SCategoryInfo, land)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SCategoryInfo", "string water", asOFFSET(SInitInfo::SCategoryInfo, water)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SCategoryInfo", "string bad", asOFFSET(SInitInfo::SCategoryInfo, bad)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SCategoryInfo", "string good", asOFFSET(SInitInfo::SCategoryInfo, good)); ASSERT(r >= 0);
	r = engine->RegisterObjectType("SInitInfo", sizeof(SInitInfo), asOBJ_VALUE | asGetTypeTraits<SInitInfo>()); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SInitInfo", asBEHAVE_CONSTRUCT, "void f()", asFUNCTION(ConstructSInitInfo), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SInitInfo", asBEHAVE_CONSTRUCT, "void f(const SInitInfo& in)", asFUNCTION(ConstructCopySInitInfo), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SInitInfo", asBEHAVE_DESTRUCT, "void f()", asFUNCTION(DestructSInitInfo), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SInitInfo", "SArmorInfo armor", asOFFSET(SInitInfo, armor)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SInitInfo", "SCategoryInfo category", asOFFSET(SInitInfo, category)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SInitInfo", "array<string>@ profile", asOFFSET(SInitInfo, profile)); ASSERT(r >= 0);
//	r = engine->EndConfigGroup(); ASSERT(r >= 0);

	folderName = profile;
	if (!script->Load(CScriptManager::initName.c_str(), folderName, CScriptManager::initName + ".as")) {
		return false;
	}
	asIScriptModule* mod = script->GetEngine()->GetModule(CScriptManager::initName.c_str());
	r = mod->SetDefaultNamespace("Init"); ASSERT(r >= 0);
	asIScriptFunction* init = script->GetFunc(mod, "SInitInfo AiInit()");

	if (init != nullptr) {
		asIScriptContext* ctx = script->PrepareContext(init);
		SInitInfo* result = script->Exec(ctx) ? (SInitInfo*)ctx->GetReturnObject() : nullptr;
		if (result != nullptr) {
			outArmor = result->armor;
			if (outArmor.airTypes.empty()) {
				outArmor.airTypes.push_back(0);  // default
			}
			if (outArmor.surfTypes.empty()) {
				outArmor.surfTypes.push_back(0);  // default
			}
			if (outArmor.waterTypes.empty()) {
				outArmor.waterTypes.push_back(0);  // default
			}

			Game* game = circuit->GetGame();
			circuit->category.air = game->GetCategoriesFlag(result->category.air.c_str());
			circuit->category.land = game->GetCategoriesFlag(result->category.land.c_str());
			circuit->category.water = game->GetCategoriesFlag(result->category.water.c_str());
			circuit->category.bad = game->GetCategoriesFlag(result->category.bad.c_str());
			circuit->category.good = game->GetCategoriesFlag(result->category.good.c_str());

			if (result->profile != nullptr) {
				for (unsigned j = 0; j < result->profile->GetSize(); ++j) {
					outCfgParts.push_back(*(std::string*)result->profile->At(j));
				}
			}
		}
		// NOTE: Init context shouldn't be used again, hence release;
		//       assuming it contains references to unused types.
		script->ReleaseContext(ctx);
	}

	mod->Discard();
	// NOTE: destroys "array<T>". "main" should be registered and loaded first,
	//       then "array<T>" will be in defaultGroup. But main-first is not a viable option.
	//       And re-creating CScriptManager is not worth the effort.
//	r = script->GetEngine()->RemoveConfigGroup(CScriptManager::initName.c_str()); ASSERT(r >= 0);
	return true;
}

// D-076: a retiring structure ends its production and queue at once.
static void CCircuitUnit_CmdStop(CCircuitUnit* unit)
{
	unit->CmdStop();
}

static int CTerrainManager_ReservePackedBuilding(CTerrainManager* terrainMgr, const CCircuitDef* cdef, const AIFloat3& pos, int facing)
{
	return terrainMgr->ReservePackedBuilding(const_cast<CCircuitDef*>(cdef), pos, facing);
}

// A factory STOP clears its offspring's rally orders, not its build queue.
// Explicit script-owned retirement uses the recruitment cancellation contract:
// remove queued build IDs, including repeats, without touching other orders.
// O(queue length), once at the lifecycle transition; never a periodic scan.
static void CCircuitUnit_CmdClearBuildQueue(CCircuitUnit* unit)
{
	auto* api = unit->GetManager()->GetCircuit()->GetUnitAPI();
	const int count = api->GetCMDQueueSize(unit->GetId());
	std::vector<float> commands;
	commands.reserve(count);
	for (int index = 0; index < count; ++index) {
		const int command = api->GetCMD(unit->GetId(), index);
		if (command < 0) commands.push_back(command);
	}
	if (!commands.empty()) unit->CmdRemove(std::move(commands), UNIT_COMMAND_OPTION_ALT_KEY | UNIT_COMMAND_OPTION_CONTROL_KEY);
}

// D-112: one move order (a gift constructor walks to its parking spot)
static void CCircuitUnit_CmdMoveTo(CCircuitUnit* unit, const AIFloat3& pos)
{
	unit->CmdMoveTo(pos);
}

// D-111: a factory's repeat flag (a spam lab keeps its one build cycling)
static void CCircuitUnit_CmdRepeat(CCircuitUnit* unit, bool on)
{
	unit->GetUnit()->SetRepeat(on);
}

// D-111: a factory's route: the move orders every unit it builds leaves with.
// The first replaces the factory's previous orders; the rest are queued behind.
// Build orders are the factory's own queue and are untouched.
static void CCircuitUnit_CmdFactoryRoute(CCircuitUnit* unit, const CScriptArray* route)
{
	if (route == nullptr) {
		return;
	}
	for (asUINT i = 0; i < route->GetSize(); ++i) {
		const AIFloat3& p = *static_cast<const AIFloat3*>(route->At(i));
		unit->CmdMoveTo(p, (i == 0) ? 0 : UNIT_COMMAND_OPTION_SHIFT_KEY);
	}
}

void CInitScript::RegisterCore()
{
	asIScriptEngine* engine = script->GetEngine();

	auto cache = static_cast<CScriptManager::STypeInfoCache*>(engine->GetUserData());
	cache->floatArray = engine->GetTypeInfoByDecl("array<float>");

	// RegisterSpringai
	static_assert(std::is_base_of<float3, AIFloat3>::value, "AIFloat3 must be a subclass of float3!");
	static_assert(sizeof(AIFloat3) == sizeof(float3), "Memory layout of AIFloat3 must be same as float3");
	// FIXME: MinGW didn't like asbind20; 1st value_class<float3> => value_class<AIFloat3>?
//	asbind20::value_class<float3>(
//		engine,
//		"AIFloat3",
//		// value_class is asOBJ_VALUE. Other flags will be automatically set using asGetTypeTraits<T>()
//		asOBJ_POD | asOBJ_APP_CLASS_ALLFLOATS | asOBJ_APP_CLASS_MORE_CONSTRUCTORS
//	)
//		.behaviours_by_traits()
//		.constructor<float>("float", asbind20::use_explicit)
//		.constructor_function("float, float, float", &ConstructVec3Val)
//		.property("float x", &float3::x)
//		.property("float y", &float3::y)
//		.property("float z", &float3::z)
//		.opAdd()                                             // float3 operator+ (const float3& f) const
//		.use(asbind20::const_this + asbind20::param<float>)  // float3 operator+ (const float f) const
//		.opAddAssign()                                       // float3& operator+= (const float3& f)
//		.opSub()                                             // float3 operator- (const float3& f) const
//		.use(asbind20::const_this - asbind20::param<float>)  // float3 operator- (const float f) const
//		.method("void opSubAssign(const AIFloat3& in)", &float3::operator-=)  // bad opSubAssign in float3
//		.opNeg()                                             // constexpr float3 operator- () const
//		.opMul()                                             // float3 operator* (const float3& f) const
//		.use(asbind20::const_this * asbind20::param<float>)  // float3 operator* (const float f) const
////		.use(asbind20::param<float> * asbind20::const_this)  // inline float3 operator*(float f, const float3& v)
//		.method("void opMulAssign(const AIFloat3& in)", asbind20::overload_cast<float>(&float3::operator*=))  // bad opMulAssign in float3
//		.use(asbind20::_this *= asbind20::param<float>)      // float3& operator*= (float f)
//		.opDiv()                                             // float3 operator/ (const float3& f) const
//		.use(asbind20::const_this / asbind20::param<float>)  // float3 operator/ (const float f) const
//		.method("void opDivAssign(const AIFloat3& in)", asbind20::overload_cast<const float3&>(&float3::operator/=))  // bad opDivAssign in float3
//		.method("void opDivAssign(const float)", asbind20::overload_cast<float>(&float3::operator/=))  // void operator/= (const float f)
//		.opEquals()                                          // bool operator== (const float3& f) const
//		.use(asbind20::_this[asbind20::param<int>])          // float& operator[] (const int t)
//		.use(asbind20::const_this[asbind20::param<int>])     // const float& operator[] (const int t) const
//		.method("bool equals(const AIFloat3& in, const AIFloat3& in) const", &float3::equals)
//		.method("bool same(const AIFloat3& in) const", &float3::same)
//		.method("bool binarySame(const AIFloat3& in) const", &float3::binarySame)
//		.method("float dot(const AIFloat3& in) const", &float3::dot)
//		.method("float dot2D(const AIFloat3& in) const", &float3::dot2D)
//		.method("AIFloat3 cross(const AIFloat3& in) const", &float3::cross)
//		.method("AIFloat3 rotate(float, const AIFloat3& in) const", &float3::rotate<false>)
//		.method("AIFloat3 rotateByUpVector(const AIFloat3& in, const AIFloat3& in) const", &float3::rotateByUpVector)
//		.method("AIFloat3 rotate2D(const AIFloat3& in) const", &float3::rotate2D)
//		.method("AIFloat3 snapToAxis() const", &float3::snapToAxis)
//		.method("float distance(const AIFloat3& in) const", &float3::distance)
//		.method("float distance2D(const AIFloat3& in) const", asbind20::overload_cast<const float3&>(&float3::distance2D, asbind20::const_))
//		.method("float SqDistance(const AIFloat3& in) const", &float3::SqDistance)
//		.method("float SqDistance2D(const AIFloat3& in) const", asbind20::overload_cast<const float3&>(&float3::SqDistance2D, asbind20::const_))
//		.method("float Length() const", &float3::Length)
//		.method("float Length2D() const", &float3::Length2D)
//		.method("float SqLength() const", &float3::SqLength)
//		.method("float SqLength2D() const", &float3::SqLength2D)
//		.method("float LengthNormalize()", &float3::LengthNormalize)
//		.method("float LengthNormalize2D()", &float3::LengthNormalize2D)
//		.method("AIFloat3& Normalize()", &float3::Normalize)
//		.method("AIFloat3& Normalize2D()", &float3::Normalize2D)
//		.method("AIFloat3& SafeNormalize()", &float3::SafeNormalize)
//		.method("AIFloat3& SafeNormalize2D()", &float3::SafeNormalize2D)
//		.method("AIFloat3 PickNonParallel() const", &float3::PickNonParallel)
//		.method("bool Normalized() const", &float3::Normalized)
//		.method("bool CheckNaNs() const", &float3::CheckNaNs)
//		.method("bool IsInMap() const", &float3::IsInMap)
//		.method("void ClampInMap()", &float3::ClampInMap)
//		.method("string str() const", &float3::str)
//		.method("string ToString() const", &AIFloat3::ToString)  // HAX
//		.method("string opImplConv() const", [](const float3& f) {
//			return f.str();  // static_cast<const AIFloat3&>(f).ToString();
//		});
//
//	// NOTE: ".use(asbind20::param<float> * asbind20::const_this)" makes IDE go "Syntax error" (but compiles)
//	int r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opMul_r(float) const", asFUNCTIONPR(operator*, (float, const float3&), float3), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
//	asbind20::global(engine)
//		.function("AIFloat3 AiMin(const AIFloat3, const AIFloat3)", &float3::min)
//		.function("AIFloat3 AiMax(const AIFloat3, const AIFloat3)", &float3::max)
//		.function("AIFloat3 AiFabs(const AIFloat3)", &float3::fabs)
//		.function("AIFloat3 AiSign(const AIFloat3)", &float3::sign);

	// WARNING: asGetTypeTraits<float3>() has no asOBJ_APP_CLASS_COPY_CONSTRUCTOR flag, unlike AIFloat3
	//     and fails with this==nullptr if method/function returns AIFloat3
	int r = engine->RegisterObjectType("AIFloat3", sizeof(AIFloat3),
			asOBJ_VALUE | asOBJ_POD | asOBJ_APP_CLASS_ALLFLOATS | asOBJ_APP_CLASS_MORE_CONSTRUCTORS | asGetTypeTraits<AIFloat3>()); ASSERT(r >= 0);
	cache->vec3Array = engine->GetTypeInfoByDecl("array<AIFloat3>");
	r = engine->RegisterObjectBehaviour("AIFloat3", asBEHAVE_CONSTRUCT, "void f()", asFUNCTION(ConstructVec3), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("AIFloat3", asBEHAVE_CONSTRUCT, "void f(const AIFloat3& in)", asFUNCTION(ConstructCopyVec3), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("AIFloat3", asBEHAVE_CONSTRUCT, "void f(float)", asFUNCTION(ConstructVec3Val1), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("AIFloat3", asBEHAVE_CONSTRUCT, "void f(float, float, float)", asFUNCTION(ConstructVec3Val3), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("AIFloat3", "float x", asOFFSET(float3, x)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("AIFloat3", "float y", asOFFSET(float3, y)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("AIFloat3", "float z", asOFFSET(float3, z)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opAdd(const AIFloat3& in) const", asMETHODPR(float3, operator+, (const float3&) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opAdd(float) const", asMETHODPR(float3, operator+, (const float) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3& opAddAssign(const AIFloat3& in)", asMETHOD(float3, operator+=), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opSub(const AIFloat3& in) const", asMETHODPR(float3, operator-, (const float3&) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opSub(float) const", asMETHODPR(float3, operator-, (const float) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "void opSubAssign(const AIFloat3& in)", asMETHOD(float3, operator-=), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opNeg() const", asMETHODPR(float3, operator-, () const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opMul(const AIFloat3& in) const", asMETHODPR(float3, operator*, (const float3&) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opMul(float) const", asMETHODPR(float3, operator*, (const float) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opMul_r(float) const", asFUNCTIONPR(operator*, (float, const float3&), float3), asCALL_CDECL_OBJLAST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "void opMulAssign(const AIFloat3& in)", asMETHODPR(float3, operator*=, (const float3&), void), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3& opMulAssign(float)", asMETHODPR(float3, operator*=, (float), float3&), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opDiv(const AIFloat3& in) const", asMETHODPR(float3, operator/, (const float3&) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 opDiv(float) const", asMETHODPR(float3, operator/, (const float) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "void opDivAssign(const AIFloat3& in)", asMETHODPR(float3, operator/=, (const float3&), void), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "void opDivAssign(float)", asMETHODPR(float3, operator/=, (const float), void), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "bool opEquals(const AIFloat3& in) const", asMETHOD(float3, operator==), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float& opIndex(int)", asMETHODPR(float3, operator[], (const int), float&), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "const float& opIndex(int) const", asMETHODPR(float3, operator[], (const int) const, const float&), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "bool equals(const AIFloat3& in, const AIFloat3& in) const", asMETHOD(float3, equals), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "bool same(const AIFloat3& in) const", asMETHOD(float3, same), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "bool binarySame(const AIFloat3& in) const", asMETHOD(float3, binarySame), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float dot(const AIFloat3& in) const", asMETHOD(float3, dot), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float dot2D(const AIFloat3& in) const", asMETHOD(float3, dot2D), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 cross(const AIFloat3& in) const", asMETHOD(float3, cross), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 rotate(float, const AIFloat3& in) const", asMETHODPR(float3, rotate<false>, (float angle, const float3& axis) const, float3), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 rotateByUpVector(const AIFloat3& in, const AIFloat3& in) const", asMETHOD(float3, rotateByUpVector), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 rotate2D(const AIFloat3& in) const", asMETHOD(float3, rotate2D), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 snapToAxis() const", asMETHOD(float3, snapToAxis), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float distance(const AIFloat3& in) const", asMETHOD(float3, distance), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float distance2D(const AIFloat3& in) const", asMETHODPR(float3, distance2D, (const float3&) const, float), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float SqDistance(const AIFloat3& in) const", asMETHOD(float3, SqDistance), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float SqDistance2D(const AIFloat3& in) const", asMETHODPR(float3, SqDistance2D, (const float3&) const, float), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float Length() const", asMETHOD(float3, Length), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float Length2D() const", asMETHOD(float3, Length2D), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float SqLength() const", asMETHOD(float3, SqLength), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float SqLength2D() const", asMETHOD(float3, SqLength2D), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float LengthNormalize()", asMETHOD(float3, LengthNormalize), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "float LengthNormalize2D()", asMETHOD(float3, LengthNormalize2D), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3& Normalize()", asMETHOD(float3, Normalize), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3& Normalize2D()", asMETHOD(float3, Normalize2D), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3& SafeNormalize()", asMETHOD(float3, SafeNormalize), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3& SafeNormalize2D()", asMETHOD(float3, SafeNormalize2D), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "AIFloat3 PickNonParallel() const", asMETHOD(float3, PickNonParallel), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "bool Normalized() const", asMETHOD(float3, Normalized), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "bool CheckNaNs() const", asMETHOD(float3, CheckNaNs), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "bool IsInMap() const", asMETHOD(float3, IsInMap), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "void ClampInMap()", asMETHOD(float3, ClampInMap), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "string str() const", asMETHOD(float3, str), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("AIFloat3", "string ToString() const", asMETHOD(AIFloat3, ToString), asCALL_THISCALL); ASSERT(r >= 0);  // HAX
	r = engine->RegisterObjectMethod("AIFloat3", "string opImplConv() const", asFUNCTION(ConvertVec3ToStr), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("AIFloat3 AiMin(const AIFloat3, const AIFloat3)", asFUNCTION(float3::min), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("AIFloat3 AiMax(const AIFloat3, const AIFloat3)", asFUNCTION(float3::max), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("AIFloat3 AiFabs(const AIFloat3)", asFUNCTION(float3::fabs), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("AIFloat3 AiSign(const AIFloat3)", asFUNCTION(float3::sign), asCALL_CDECL); ASSERT(r >= 0);

	r = engine->RegisterObjectMethod("AIFloat3", "bool IsInRange(const AIFloat3& in, float) const", asFUNCTION(geom::is_in_range), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);

	// RegisterGeometry
	geom::CPolygon::RegisterRefCounted(engine, "CPolygon");
	r = engine->RegisterObjectBehaviour("CPolygon", asBEHAVE_FACTORY, "CPolygon@ f(const array<AIFloat3>@+)", asFUNCTION(FactoryCPolygon), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CPolygon", "array<AIFloat3>@ GetVerts() const", asFUNCTION(CPolygon_GetVerts), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CPolygon", "const float area", asOFFSET(geom::CPolygon, area)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CPolygon", "bool ContainsPoint(const AIFloat3& in) const", asMETHOD(geom::CPolygon, ContainsPoint), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CPolygon", "AIFloat3 Random() const", asMETHOD(geom::CPolygon, Random), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CPolygon", "void Scale(float)", asMETHOD(geom::CPolygon, Scale), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CPolygon", "void Extend(float)", asMETHOD(geom::CPolygon, Extend), asCALL_THISCALL); ASSERT(r >= 0);

	// RegisterUtils
//	asbind20::global(engine)
//		.function("void AiLog(const string& in)", &CInitScript::Log, asbind20::auxiliary(this));
	r = engine->RegisterGlobalFunction("void AiLog(const string& in)", asMETHOD(CInitScript, Log), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("const bool AiPerfEnabled", const_cast<bool*>(&performance::enabled)); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiPerfBegin(int)", asMETHOD(CInitScript, PerfBegin), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiPerfEnd(int)", asMETHOD(CInitScript, PerfEnd), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiPerfBeginLabel(const string &in)", asMETHOD(CInitScript, PerfBeginLabel), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiPerfEndLabel()", asMETHOD(CInitScript, PerfEndLabel), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiAddPoint(const AIFloat3& in, const string& in)", asMETHOD(CInitScript, AddPoint), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiDelPoint(const AIFloat3& in)", asMETHOD(CInitScript, DelPoint), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiAddLine(const AIFloat3& in, const AIFloat3& in)", asMETHOD(CInitScript, AddLine), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiQueueLine(const AIFloat3& in, const AIFloat3& in)", asMETHOD(CInitScript, QueueLine), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);  // D-118
	r = engine->RegisterGlobalFunction("void AiQueuePoint(const AIFloat3& in, const string& in)", asMETHOD(CInitScript, QueuePoint), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiQueueErase(const AIFloat3& in)", asMETHOD(CInitScript, QueueErase), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiMarkIntroDone(int)", asFUNCTION(AiMarkIntroDone), asCALL_CDECL); ASSERT(r >= 0);  // D-127
	r = engine->RegisterGlobalFunction("int AiIntroDoneFrame()", asFUNCTION(AiIntroDoneFrame), asCALL_CDECL); ASSERT(r >= 0);  // D-127
	r = engine->RegisterGlobalFunction("int AiDrawQueueSize()", asMETHOD(CInitScript, DrawQueueSize), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiDrawQueueClear()", asMETHOD(CInitScript, DrawQueueClear), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiDrawPace(int, int)", asMETHOD(CInitScript, DrawPace), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiPause(bool, const string& in)", asMETHOD(CInitScript, Pause), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiDice(const array<float>@+)", asMETHOD(CInitScript, Dice), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiNearestPointIdx(const AIFloat3& in, const array<AIFloat3>@+)", asMETHOD(CInitScript, NearestPointIdx), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiMin(int, int)", asMETHODPR(CInitScript, Min<int>, (int, int) const, int), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("float AiMin(float, float)", asMETHODPR(CInitScript, Min<float>, (float, float) const, float), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiMax(int, int)", asMETHODPR(CInitScript, Max<int>, (int, int) const, int), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("float AiMax(float, float)", asMETHODPR(CInitScript, Max<float>, (float, float) const, float), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiRandom(int, int)", asMETHOD(CInitScript, Random), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiSendMessage(const string& in, int = -1)", asMETHOD(CInitScript, SendMessage), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterFuncdef("void AiOnFinish(dictionary@+)"); ASSERT(r >= 0);
	r = engine->RegisterFuncdef("AiOnFinish@+ AiExec(dictionary@+)"); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiRun(AiExec@+, dictionary@)", asMETHOD(CInitScript, Run), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("void AiSleep(uint64)", asFUNCTION(utils::sleep), asCALL_CDECL); ASSERT(r >= 0);

	r = engine->RegisterObjectType("IStream", sizeof(std::istream), asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectType("OStream", sizeof(std::ostream), asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(bool& out)", asFUNCTION(utils::binary_read<bool>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(int8& out)", asFUNCTION(utils::binary_read<int8_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(int16& out)", asFUNCTION(utils::binary_read<int16_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(int& out)", asFUNCTION(utils::binary_read<int32_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(int64& out)", asFUNCTION(utils::binary_read<int64_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(uint8& out)", asFUNCTION(utils::binary_read<uint8_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(uint16& out)", asFUNCTION(utils::binary_read<uint16_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(uint& out)", asFUNCTION(utils::binary_read<uint32_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(uint64& out)", asFUNCTION(utils::binary_read<uint64_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(float& out)", asFUNCTION(utils::binary_read<float>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("IStream", "IStream& opShr(double& out)", asFUNCTION(utils::binary_read<double>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const bool& in)", asFUNCTION(utils::binary_write<bool>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const int8& in)", asFUNCTION(utils::binary_write<int8_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const int16& in)", asFUNCTION(utils::binary_write<int16_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const int& in)", asFUNCTION(utils::binary_write<int32_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const int64& in)", asFUNCTION(utils::binary_write<int64_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const uint8& in)", asFUNCTION(utils::binary_write<uint8_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const uint16& in)", asFUNCTION(utils::binary_write<uint16_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const uint& in)", asFUNCTION(utils::binary_write<uint32_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const uint64& in)", asFUNCTION(utils::binary_write<uint64_t>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const float& in)", asFUNCTION(utils::binary_write<float>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("OStream", "OStream& opShl(const double& in)", asFUNCTION(utils::binary_write<double>), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);

	r = engine->RegisterObjectMethod("string", "string toLower() const", asFUNCTION(utils::StringToLower), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("string", "string toUpper() const", asFUNCTION(utils::StringToUpper), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);

	// RegisterCircuitAI
	r = engine->RegisterTypedef("Id", "int"); ASSERT(r >= 0);
	cache->idArray = engine->GetTypeInfoByDecl("array<Id>");

	r = engine->RegisterObjectType("TypeMask", sizeof(CMaskHandler::TypeMask), asOBJ_VALUE | asOBJ_POD | asGetTypeTraits<CMaskHandler::TypeMask>()); ASSERT(r >= 0);
	r = engine->RegisterTypedef("Type", "int"); ASSERT(r >= 0);
	r = engine->RegisterTypedef("Mask", "uint"); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("TypeMask", "Type type", asOFFSET(CMaskHandler::TypeMask, type)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("TypeMask", "Mask mask", asOFFSET(CMaskHandler::TypeMask, mask)); ASSERT(r >= 0);

//	r = engine->SetDefaultNamespace("Task"); ASSERT(r >= 0);
//	r = engine->RegisterEnum("RecruitType"); ASSERT(r >= 0);
//	r = engine->RegisterEnumValue("RecruitType", "BUILDPOWER", static_cast<int>(CRecruitTask::RecruitType::BUILDPOWER)); ASSERT(r >= 0);
//	r = engine->RegisterEnumValue("RecruitType", "FIREPOWER", static_cast<int>(CRecruitTask::RecruitType::FIREPOWER)); ASSERT(r >= 0);
//	r = engine->SetDefaultNamespace(""); ASSERT(r >= 0);

	r = engine->RegisterObjectType("CCircuitAI", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CCircuitAI ai", circuit); ASSERT(r >= 0);

	r = engine->RegisterObjectType("CCircuitDef", 0, asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectType("CCircuitUnit", 0, asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	cache->unitArray = engine->GetTypeInfoByDecl("array<CCircuitUnit@>");
	RegisterUnitTasks(engine);

	r = engine->RegisterObjectProperty("CCircuitAI", "const int frame", asOFFSET(CCircuitAI, lastFrame)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitAI", "const int skirmishAIId", asOFFSET(CCircuitAI, skirmishAIId)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitAI", "const int teamId", asOFFSET(CCircuitAI, teamId)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitAI", "const int allyTeamId", asOFFSET(CCircuitAI, allyTeamId)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "CCircuitDef@ GetCircuitDef(const string& in)", asFUNCTION(CCircuitAI_GetCircuitDef), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "CCircuitDef@ GetCircuitDef(Id)", asMETHODPR(CCircuitAI, GetCircuitDef, (CCircuitDef::Id), CCircuitDef*), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "int GetDefCount() const", asMETHOD(CCircuitAI, GetDefCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "CCircuitUnit@ GetTeamUnit(Id)", asMETHOD(CCircuitAI, GetTeamUnit), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "array<Id>@ GetOwnedUnitIds() const", asFUNCTION(CCircuitAI_GetOwnedUnitIds), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CCircuitAI", "uint GetOwnedUnitRevision() const", asMETHOD(CCircuitAI, GetOwnedUnitRevision), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "string GetMapName() const", asFUNCTION(CCircuitAI_GetMapName), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "int GetEnemyTeamSize() const", asMETHOD(CCircuitAI, GetEnemyTeamSize), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "bool IsLoadSave() const", asMETHOD(CCircuitAI, IsLoadSave), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "Type GetBindedRole(Type) const", asMETHOD(CCircuitAI, GetBindedRole), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "int GetLeadTeamId() const", asFUNCTION(CCircuitAI_GetLeadTeamId), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "Type GetSideId() const", asMETHOD(CCircuitAI, GetSideId), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "const string& GetSideName() const", asMETHOD(CCircuitAI, GetSideName), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "array<Id>@ GetTeamIds() const", asFUNCTION(CCircuitAI_GetTeamIds), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "void GiveUnits(const array<CCircuitUnit@>@+, int)", asFUNCTION(CCircuitAI_GiveUnits), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CCircuitAI", "int GetFriendlyUnitTeam(int) const", asFUNCTION(CCircuitAI_GetFriendlyUnitTeam), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CCircuitAI", "AIFloat3 GetFriendlyUnitPosition(int, int) const", asFUNCTION(CCircuitAI_GetFriendlyUnitPosition), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "bool UnitControl(CCircuitUnit@, bool)", asMETHODPR(CCircuitAI, UnitControl, (CCircuitUnit*, bool), bool), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "bool UnitControl(Id, bool)", asMETHODPR(CCircuitAI, UnitControl, (ICoreUnit::Id, bool), bool), asCALL_THISCALL); ASSERT(r >= 0);
	// Lua<-->AI communications [in Spring 0.83+]
	r = engine->RegisterObjectMethod("CCircuitAI", "string CallRules(const string& in)", asFUNCTION(CCircuitAI_CallRules), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "string CallUI(const string& in)", asFUNCTION(CCircuitAI_CallUI), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	// D-300: widget state file; an empty value removes the key
	r = engine->RegisterObjectMethod("CCircuitAI", "void SetWidgetState(const string& in, const string& in)", asFUNCTION(CCircuitAI_SetWidgetState), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "void PushWidgetEvent(const string& in)", asFUNCTION(CCircuitAI_PushWidgetEvent), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "void SetWidgetStateTiming(int, int)", asFUNCTION(CCircuitAI_SetWidgetStateTiming), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	// RulesParams accessors on AI (game/team)
	r = engine->RegisterObjectMethod("CCircuitAI", "float GetGameRulesParam(const string& in, float) const", asFUNCTION(CCircuitAI_GetGameRulesParamFloat), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "string GetGameRulesParam(const string& in, const string& in) const", asFUNCTION(CCircuitAI_GetGameRulesParamString), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "float GetTeamRulesParam(const string& in, float) const", asFUNCTION(CCircuitAI_GetTeamRulesParamFloat), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "string GetTeamRulesParam(const string& in, const string& in) const", asFUNCTION(CCircuitAI_GetTeamRulesParamString), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);

	CMaskHandler* sideMasker = &circuit->GetGameAttribute()->GetSideMasker();
	CMaskHandler* roleMasker = &circuit->GetGameAttribute()->GetRoleMasker();
	CMaskHandler* attrMasker = &circuit->GetGameAttribute()->GetAttrMasker();
	r = engine->RegisterObjectType("CMaskHandler", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CMaskHandler aiSideMasker", sideMasker); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CMaskHandler aiRoleMasker", roleMasker); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CMaskHandler aiAttrMasker", attrMasker); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMaskHandler", "TypeMask GetTypeMask(const string& in)", asMETHOD(CMaskHandler, GetTypeMask), asCALL_THISCALL); ASSERT(r >= 0);

	r = engine->RegisterGlobalFunction("TypeMask AiAddRole(const string& in, Type)", asMETHOD(CInitScript, AddRole), asCALL_THISCALL_ASGLOBAL, this); ASSERT(r >= 0);

	r = engine->RegisterObjectMethod("CCircuitDef", "void SetMainRole(Type)", asMETHOD(CCircuitDef, SetMainRole), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "Type GetMainRole() const", asMETHOD(CCircuitDef, GetMainRole), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsRespRoleAny(Mask) const", asMETHOD(CCircuitDef, IsRespRoleAny), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsRoleAny(Mask) const", asMETHOD(CCircuitDef, IsRoleAny), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void AddAttribute(Type)", asMETHOD(CCircuitDef, AddAttribute), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void DelAttribute(Type)", asMETHOD(CCircuitDef, DelAttribute), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void TglAttribute(Type)", asMETHOD(CCircuitDef, TglAttribute), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsAttrAny(Mask) const", asMETHOD(CCircuitDef, IsAttrAny), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "const string GetName() const", asFUNCTION(CCircuitDef_GetName), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const Id id", asOFFSET(CCircuitDef, id)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsAvailable(int)", asMETHODPR(CCircuitDef, IsAvailable, (int) const, bool), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const int count", asOFFSET(CCircuitDef, count)); ASSERT(r >= 0);
	// The def's build options: what a constructor of this def can build (CR-006).
	r = engine->RegisterObjectMethod("CCircuitDef", "bool CanBuild(const CCircuitDef@) const", asMETHODPR(CCircuitDef, CanBuild, (const CCircuitDef*) const, bool), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float health", asOFFSET(CCircuitDef, health)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float speed", asOFFSET(CCircuitDef, speed)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float losRadius", asOFFSET(CCircuitDef, losRadius)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float sonarRadius", asOFFSET(CCircuitDef, sonarRadius)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float costM", asOFFSET(CCircuitDef, costM)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetTargetMinCost() const", asMETHOD(CCircuitDef, GetTargetMinCost), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float costE", asOFFSET(CCircuitDef, costE)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float threat", asOFFSET(CCircuitDef, defThreat)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float power", asOFFSET(CCircuitDef, power)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float defDmg", asOFFSET(CCircuitDef, defThrDmg)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float pwrDmg", asOFFSET(CCircuitDef, pwrDmg)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float airThrDmg", asOFFSET(CCircuitDef, airThrDmg)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float surfThrDmg", asOFFSET(CCircuitDef, surfThrDmg)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float waterThrDmg", asOFFSET(CCircuitDef, waterThrDmg)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "const float minRange", asOFFSET(CCircuitDef, minRange)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetMaxRange(Type) const", asMETHODPR(CCircuitDef, GetMaxRange, (CCircuitDef::RangeType) const, float), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetMaxRange() const", asMETHODPR(CCircuitDef, GetMaxRange, () const, float), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void SetRange(Type, float)", asMETHODPR(CCircuitDef, SetRange, (CCircuitDef::RangeType, float), void), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void SetRange(float)", asMETHODPR(CCircuitDef, SetRange, (float), void), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetAirThreat() const", asMETHOD(CCircuitDef, GetAirThreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetSurfThreat() const", asMETHOD(CCircuitDef, GetSurfThreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetWaterThreat() const", asMETHOD(CCircuitDef, GetWaterThreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsAbleToFly() const", asMETHOD(CCircuitDef, IsAbleToFly), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsMobile() const", asMETHOD(CCircuitDef, IsMobile), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool HasSurfToAir() const", asMETHOD(CCircuitDef, HasSurfToAir), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool HasSurfToLand() const", asMETHOD(CCircuitDef, HasSurfToLand), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool HasSurfToWater() const", asMETHOD(CCircuitDef, HasSurfToWater), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool HasSubToWater() const", asMETHOD(CCircuitDef, HasSubToWater), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "int GetFootprintX() const", asFUNCTION(CCircuitDef_GetFootprintX), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool CanTransport(const CCircuitDef@) const", asFUNCTION(CCircuitDef_CanTransport), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetSpeed() const", asMETHOD(CCircuitDef, GetSpeed), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetBuildTime() const", asMETHOD(CCircuitDef, GetBuildTime), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetExtractsMetal() const", asMETHOD(CCircuitDef, GetExtractsM), asCALL_THISCALL); ASSERT(r >= 0);
	// Physical engine work/second, before JSON build_speed policy overrides.
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetBuildSpeed() const", asMETHOD(CCircuitDef, GetWorkerTime), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetBuildDistance() const", asMETHOD(CCircuitDef, GetBuildDistance), asCALL_THISCALL); ASSERT(r >= 0);
	// Cached model radius, read only on the AI callback thread. Build/reclaim
	// reach includes the target's radius; footprint or bare centre distance
	// incorrectly excludes assistants that the engine is already using.
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetModelRadius()", asMETHOD(CCircuitDef, GetRadius), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "float GetLosRadius() const", asMETHOD(CCircuitDef, GetLosRadius), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool HasSubToLand() const", asMETHOD(CCircuitDef, HasSubToLand), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "int GetFootprintZ() const", asFUNCTION(CCircuitDef_GetFootprintZ), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "int maxThisUnit", asOFFSET(CCircuitDef, maxThisUnit)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "int sinceFrame", asOFFSET(CCircuitDef, sinceFrame)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitDef", "int cooldown", asOFFSET(CCircuitDef, cooldown)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void SetIgnore(bool)", asMETHOD(CCircuitDef, SetIgnore), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsIgnore() const", asMETHOD(CCircuitDef, IsIgnore), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "bool IsBuildAllowed() const", asMETHOD(CCircuitDef, IsBuildAllowed), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void SetThreatKernel(float)", asMETHOD(CCircuitDef, SetThreatKernel), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "void SetFireState(int)", asMETHOD(CCircuitDef, SetFireState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitDef", "int GetFireState() const", asMETHOD(CCircuitDef, GetFireState), asCALL_THISCALL); ASSERT(r >= 0);

	r = engine->RegisterObjectProperty("CCircuitUnit", "const Id id", asOFFSET(CCircuitUnit, id)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "int GetProducerId() const", asMETHOD(CCircuitUnit, GetProducerId), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "int GetProductionFrame() const", asMETHOD(CCircuitUnit, GetProductionFrame), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void SetProductionEnabled(bool)", asMETHOD(CCircuitUnit, SetProductionEnabled), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "bool IsProductionEnabled() const", asMETHOD(CCircuitUnit, IsProductionEnabled), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CCircuitUnit", "const CCircuitDef@ circuitDef", asOFFSET(CCircuitUnit, circuitDef)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "const AIFloat3& GetPos(int)", asMETHODPR(CCircuitUnit, GetPos, (int), const AIFloat3&), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void AddAttribute(Type)", asMETHOD(CCircuitUnit, AddAttribute), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "float GetHealthPercent()", asMETHOD(CCircuitUnit, GetHealthPercent), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "float GetBuildProgress()", asFUNCTION(CCircuitUnit_GetBuildProgress), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-105
    r = engine->RegisterObjectMethod("CCircuitUnit", "void SetRetreatWaypoint(const AIFloat3& in, int, int)", asMETHOD(CCircuitUnit, SetRetreatWaypoint), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "int GetStockpile()", asFUNCTION(CCircuitUnit_GetStockpile), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-229
	r = engine->RegisterObjectMethod("CCircuitUnit", "void DelAttribute(Type)", asMETHOD(CCircuitUnit, DelAttribute), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void TglAttribute(Type)", asMETHOD(CCircuitUnit, TglAttribute), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "bool IsAttrAny(Mask) const", asMETHOD(CCircuitUnit, IsAttrAny), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void SetFireState(int)", asMETHOD(CCircuitUnit, TrySetFireState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void SetIdleMode(int)", asMETHOD(CCircuitUnit, TrySetIdleMode), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void SetMoveState(int)", asMETHOD(CCircuitUnit, TrySetMoveState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void SelfDestruct(bool)", asMETHOD(CCircuitUnit, CmdSelfD), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void CmdStop()", asFUNCTION(CCircuitUnit_CmdStop), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void CmdClearBuildQueue()", asFUNCTION(CCircuitUnit_CmdClearBuildQueue), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void SetBuildPriorityOverride(int)", asMETHOD(CCircuitUnit, SetBuildPriorityOverride), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "void CmdMoveTo(const AIFloat3& in)", asFUNCTION(CCircuitUnit_CmdMoveTo), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-112
	r = engine->RegisterObjectMethod("CCircuitUnit", "void CmdRepeat(bool)", asFUNCTION(CCircuitUnit_CmdRepeat), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-111
	r = engine->RegisterObjectMethod("CCircuitUnit", "void CmdFactoryRoute(const array<AIFloat3>@+)", asFUNCTION(CCircuitUnit_CmdFactoryRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-111
	r = engine->RegisterObjectProperty("CCircuitUnit", "IUnitTask@ const task", asOFFSET(CCircuitUnit, task)); ASSERT(r >= 0);
	// RulesParams accessor on Unit
	r = engine->RegisterObjectMethod("CCircuitUnit", "float GetRulesParam(const string& in, float) const", asFUNCTION(CCircuitUnit_GetRulesParamFloat), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitUnit", "string GetRulesParam(const string& in, const string& in) const", asFUNCTION(CCircuitUnit_GetRulesParamString), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
}

void CInitScript::RegisterMgr()
{
	asIScriptEngine* engine = script->GetEngine();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	int r = engine->RegisterObjectType("CTerrainManager", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CTerrainManager aiTerrainMgr", terrainMgr); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiTerrainWidth()", asFUNCTION(CTerrainManager::GetTerrainWidth), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiTerrainHeight()", asFUNCTION(CTerrainManager::GetTerrainHeight), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("float AiTerrainDiagonal()", asFUNCTION(CTerrainManager::GetTerrainDiagonal), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("AIFloat3 AiTerrainCenter()", asFUNCTION(CTerrainManager::GetTerrainCenter), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsWaterAVoid() const", asMETHOD(CTerrainManager, IsWaterAVoid), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "float GetLandPercent() const", asMETHOD(CTerrainManager, GetLandPercent), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "float SetAllyZoneRange(float)", asMETHOD(CTerrainManager, SetAllyZoneRange), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetTerrainWidth() const", asFUNCTION(CTerrainManager_GetTerrainWidth), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CTerrainManager", "bool CanMoveTo(CCircuitUnit@, const AIFloat3& in) const", asFUNCTION(CTerrainManager_CanMoveTo), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CTerrainManager", "bool CanTraverse(CCircuitDef@, const AIFloat3& in, const AIFloat3& in) const", asFUNCTION(CTerrainManager_CanTraverse), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "AIFloat3 FindSafeDropSpot(CCircuitUnit@, const AIFloat3& in, float radius, float surfaceThreat, float airThreat)", asFUNCTION(CTerrainManager_FindSafeDropSpot), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	// Reservations: doc/base-layout.md
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReserveBuilding(const CCircuitDef@, const AIFloat3& in, int facing, int ttlFrames = 0)", asFUNCTION(CTerrainManager_ReserveBuilding), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReservePersistentBuilding(const CCircuitDef@, const AIFloat3& in, int facing)", asFUNCTION(CTerrainManager_ReservePersistentBuilding), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReservePackedBuilding(const CCircuitDef@, const AIFloat3& in, int facing)", asFUNCTION(CTerrainManager_ReservePackedBuilding), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "void ReleasePersistentBuilding(int)", asMETHOD(CTerrainManager, ReleasePersistentBuilding), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetReservationState(int) const", asMETHOD(CTerrainManager, GetReservationState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsReservationBuildable(int) const", asMETHOD(CTerrainManager, IsReservationBuildable), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetGroupActivationState(int) const", asMETHOD(CTerrainManager, GetGroupActivationState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetGroupZone(int) const", asMETHOD(CTerrainManager, GetGroupZone), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetZoneActivationState(int) const", asMETHOD(CTerrainManager, GetZoneActivationState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReserveClusterEnvelope(int, int)", asMETHOD(CTerrainManager, ReserveClusterEnvelope), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsAllyLayoutBlocked(CCircuitDef@, const AIFloat3& in, int) const", asMETHOD(CTerrainManager, IsAllyLayoutBlocked), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanReserveArea(const AIFloat3& in, int, float, float) const", asMETHOD(CTerrainManager, CanReserveArea), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsResourceAreaBlocked(const AIFloat3& in, int, float, float) const", asMETHOD(CTerrainManager, IsResourceAreaBlocked), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReserveGrid(const CCircuitDef@, const AIFloat3& in frontCentre, int facing, int cols, int rows, int gap, int ttlFrames = 0)", asFUNCTION(CTerrainManager_ReserveGrid), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool PlanMexCluster(const string& in, CCircuitDef@, const AIFloat3& in, int, int, int)", asMETHOD(CTerrainManager, PlanMexCluster), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReserveNanoBlockAt(const CCircuitDef@ nanoDef, const CCircuitDef@ facDef, const AIFloat3& in facPos, int facing, int cols, int rows, int gap)", asFUNCTION(CTerrainManager_ReserveNanoBlockAt), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanReserveNanoBlockAt(const CCircuitDef@ nanoDef, const CCircuitDef@ facDef, const AIFloat3& in facPos, int facing, int cols, int rows, int gap)", asFUNCTION(CTerrainManager_CanReserveNanoBlockAt), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReserveNanoBlock(CCircuitUnit@ factory, const CCircuitDef@ nanoDef, int cols, int rows, int gap)", asFUNCTION(CTerrainManager_ReserveNanoBlock), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanReserveBuilding(const CCircuitDef@, const AIFloat3& in, int facing)", asFUNCTION(CTerrainManager_CanReserveBuilding), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "float BuildableFraction(const CCircuitDef@, const AIFloat3& in centre, float halfAcross, float halfAlong, int facing)", asFUNCTION(CTerrainManager_BuildableFraction), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "void ReleaseReservation(int)", asMETHOD(CTerrainManager, ReleaseReservation), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "void ReleaseGroup(int)", asMETHOD(CTerrainManager, ReleaseGroup), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsReserved(const AIFloat3& in) const", asMETHOD(CTerrainManager, IsReserved), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetReservationCount(const CCircuitDef@) const", asFUNCTION(CTerrainManager_GetReservationCount), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CTerrainManager", "float reservationMatchRadius", asOFFSET(CTerrainManager, reservationMatchRadius)); ASSERT(r >= 0);
	// Layout: JSON permits the mechanism and TECH opts its own AI instance in.
	r = engine->RegisterObjectMethod("CTerrainManager", "bool SetLayoutEnabled(bool)", asMETHOD(CTerrainManager, SetLayoutEnabled), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsLayoutEnabled() const", asMETHOD(CTerrainManager, IsLayoutEnabled), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsLayoutConfigured() const", asMETHOD(CTerrainManager, IsLayoutConfigured), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool PlanNavalBerth(const string& in, CCircuitDef@, const AIFloat3& in, int, float, float)", asMETHOD(CTerrainManager, PlanNavalBerth), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int PlanNavalSupport(const string& in, CCircuitDef@, CCircuitDef@, const AIFloat3& in, int, int, int, float)", asMETHOD(CTerrainManager, PlanNavalSupport), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsAreaVisible(const AIFloat3& in, float) const", asMETHOD(CTerrainManager, IsAreaVisible), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanNavalRoute(CCircuitDef@, const AIFloat3& in, const AIFloat3& in)", asMETHOD(CTerrainManager, CanNavalRoute), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanUpgradeTerrain(CCircuitDef@, const AIFloat3& in)", asFUNCTION(CTerrainManager_CanUpgradeTerrain), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool PlanFactoryPair(const string& in, const CCircuitDef@, const CCircuitDef@, const CCircuitDef@, const AIFloat3& in, int facing, int sideOffsetCells, int forwardOffsetCells)", asFUNCTION(CTerrainManager_PlanFactoryPair), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool PlanAirFactoryCluster(const string& in, const CCircuitDef@, const CCircuitDef@, const CCircuitDef@, const AIFloat3& in, int, int, int, int)", asFUNCTION(CTerrainManager_PlanAirFactoryCluster), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetFactoryNanoAvailable() const", asMETHOD(CTerrainManager, GetFactoryNanoAvailable), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetFactoryNanoActive() const", asMETHOD(CTerrainManager, GetFactoryNanoActive), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool HasLayoutGroup(const string& in) const", asMETHOD(CTerrainManager, HasLayoutGroup), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetLayoutGroupTotal(const string& in) const", asMETHOD(CTerrainManager, GetLayoutGroupTotal), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetLayoutGroupBuilt(const string& in) const", asMETHOD(CTerrainManager, GetLayoutGroupBuilt), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetLayoutGroupStarted(const string& in) const", asMETHOD(CTerrainManager, GetLayoutGroupStarted), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetLayoutGroupAvailable(const string& in) const", asMETHOD(CTerrainManager, GetLayoutGroupAvailable), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetLayoutInt(const string& in, int fallback = 0) const", asMETHOD(CTerrainManager, GetLayoutInt), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "AIFloat3 GetLayoutGroupCenter(const string& in) const", asMETHOD(CTerrainManager, GetLayoutGroupCenter), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReserveZone(const AIFloat3& in centre, int facing, float halfAcross, float halfAlong, bool corridor)", asMETHOD(CTerrainManager, ReserveZone), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "void ReleaseZone(int)", asMETHOD(CTerrainManager, ReleaseZone), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CTerrainManager", "AIFloat3 GetZoneCorner(int, bool) const", asMETHOD(CTerrainManager, GetZoneCorner), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReserveExitCone(CCircuitUnit@ factory, float length, float margin)", asMETHOD(CTerrainManager, ReserveExitCone), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsZoneClear(int) const", asMETHOD(CTerrainManager, IsZoneClear), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int LayBand(int zone, const CCircuitDef@, const AIFloat3& in frontCentre, int facing, int cols, int rows, int gap, bool armed, bool anyReach, bool tenant, int group = 0)", asFUNCTION(CTerrainManager_LayBand), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "void ArmGroup(int group, bool armed)", asMETHOD(CTerrainManager, ArmGroup), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "void ReleaseUnconsumed(int group)", asMETHOD(CTerrainManager, ReleaseUnconsumed), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetGroupCount(int group, bool unconsumedOnly) const", asMETHOD(CTerrainManager, GetGroupCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int NextSlot(int group, const AIFloat3& in anchor) const", asMETHOD(CTerrainManager, NextSlot), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int NextBuilt(int group, const AIFloat3& in anchor) const", asMETHOD(CTerrainManager, NextBuilt), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int NextSlotAny(int group, const AIFloat3& in anchor) const", asMETHOD(CTerrainManager, NextSlotAny), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int NextSlotConnected(int group, const AIFloat3& in centre) const", asMETHOD(CTerrainManager, NextSlotConnected), asCALL_THISCALL); ASSERT(r >= 0);  // D-077
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsZoneAlly(const AIFloat3& in) const", asMETHOD(CTerrainManager, IsZoneAlly), asCALL_THISCALL); ASSERT(r >= 0);  // D-081
	r = engine->RegisterObjectMethod("CTerrainManager", "void SetLayoutInt(const string& in, int)", asMETHOD(CTerrainManager, SetLayoutInt), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int PackNearGroup(int zone, const CCircuitDef@, int nanoGroup, int facing, const AIFloat3& in anchor, float maxReach, float minNanoDist, int group)", asFUNCTION(CTerrainManager_PackNearGroup), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int PickMost(int zone, const CCircuitDef@, int nanoGroup, int facing, float reach, float flush, const AIFloat3& in seed, AIFloat3& out)", asFUNCTION(CTerrainManager_PickMost), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsExitClear(const CCircuitDef@, const AIFloat3& in, int facing, float length, float margin) const", asFUNCTION(CTerrainManager_IsExitClear), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int PackNearGroupMost(int zone, const CCircuitDef@, int nanoGroup, int facing, float reach, float flush, int group, const AIFloat3& in seed)", asFUNCTION(CTerrainManager_PackNearGroupMost), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int CountGroupSlotsWithin(int group, const AIFloat3& in, float) const", asMETHOD(CTerrainManager, CountGroupSlotsWithin), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanPackNearGroup(int zone, const CCircuitDef@, int nanoGroup, int facing, float maxReach, float minNanoDist)", asFUNCTION(CTerrainManager_CanPackNearGroup), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int PackNearBuiltPower(int zone, CCircuitDef@, int nanoGroup, int facing, const AIFloat3& in anchor, float margin)", asMETHOD(CTerrainManager, PackNearBuiltPower), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "AIFloat3 GetReservationPos(int) const", asMETHOD(CTerrainManager, GetReservationPos), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "bool IsSlotDead(int) const", asMETHOD(CTerrainManager, IsSlotDead), asCALL_THISCALL); ASSERT(r >= 0);  // D-116
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanReachAt(CCircuitUnit@, const AIFloat3& in, float)", asFUNCTION(CTerrainManager_CanReachAt), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-121
	r = engine->RegisterObjectMethod("CTerrainManager", "bool CanReachAtSafe(CCircuitUnit@, const AIFloat3& in, float)", asFUNCTION(CTerrainManager_CanReachAtSafe), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetReservationFacing(int) const", asMETHOD(CTerrainManager, GetReservationFacing), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int PackSet(int zone, const CCircuitDef@, int nanoGroup, int facing, const AIFloat3& in anchor, int count, bool ring, int maximumGapCells = -1)", asFUNCTION(CTerrainManager_PackSet), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int NextReachableSlot(CCircuitUnit@, const CCircuitDef@, int zone, int group, int budget)", asMETHOD(CTerrainManager, NextReachableSlot), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CTerrainManager", "int GetLostReservationCount(const CCircuitDef@) const", asMETHOD(CTerrainManager, GetLostReservationCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CTerrainManager", "int NextLostReservation(CCircuitUnit@, const CCircuitDef@, int budget)", asMETHOD(CTerrainManager, NextLostReservation), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int NextSetSlot(const CCircuitDef@) const", asFUNCTION(CTerrainManager_NextSetSlot), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-101
	r = engine->RegisterObjectMethod("CTerrainManager", "void SetResetFactorySlot(int)", asMETHOD(CTerrainManager, SetResetFactorySlot), asCALL_THISCALL); ASSERT(r >= 0);  // D-101
	r = engine->RegisterObjectMethod("CTerrainManager", "void ClearFactoryZones()", asMETHOD(CTerrainManager, ClearFactoryZones), asCALL_THISCALL); ASSERT(r >= 0);  // D-104
	r = engine->RegisterObjectMethod("CTerrainManager", "void AddFactoryZone(int, int)", asMETHOD(CTerrainManager, AddFactoryZone), asCALL_THISCALL); ASSERT(r >= 0);  // D-104
	r = engine->RegisterObjectMethod("CTerrainManager", "void SetFactoryFront(int)", asMETHOD(CTerrainManager, SetFactoryFront), asCALL_THISCALL); ASSERT(r >= 0);  // D-104
	r = engine->RegisterObjectMethod("CTerrainManager", "int PackFactoryFlush(const CCircuitDef@, const AIFloat3& in)", asFUNCTION(CTerrainManager_PackFactoryFlush), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-104
	r = engine->RegisterObjectMethod("CTerrainManager", "int ReleaseSetSlots(const CCircuitDef@)", asFUNCTION(CTerrainManager_ReleaseSetSlots), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-101
	r = engine->RegisterObjectMethod("CTerrainManager", "int EdgeGapToGroup(const CCircuitDef@, const AIFloat3& in, int facing, int group) const", asFUNCTION(CTerrainManager_EdgeGapToGroup), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-101
	r = engine->RegisterObjectMethod("CTerrainManager", "int CountStructuresInExit(CCircuitUnit@) const", asMETHOD(CTerrainManager, CountStructuresInExit), asCALL_THISCALL); ASSERT(r >= 0);  // D-096
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetBuildingFacing(CCircuitUnit@) const", asMETHOD(CTerrainManager, GetBuildingFacing), asCALL_THISCALL); ASSERT(r >= 0);  // D-096
	r = engine->RegisterObjectMethod("CTerrainManager", "CCircuitUnit@ GetReservationUnit(int) const", asMETHOD(CTerrainManager, GetReservationUnit), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "float FlatFraction(const AIFloat3& in centre, int facing, float halfAcross, float halfAlong, float maxSlope) const", asMETHOD(CTerrainManager, FlatFraction), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "string DescribeLayout() const", asMETHOD(CTerrainManager, DescribeLayout), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "void ResetLayout()", asMETHOD(CTerrainManager, ResetLayout), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("bool AiPreferFactoryFacing(IUnitTask@, int)", asFUNCTION(IBuilderTask_PreferFactoryFacing), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("bool AiPinReservation(IUnitTask@, int)", asFUNCTION(IBuilderTask_PinReservation), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "float GetWindMin() const", asFUNCTION(CCircuitAI_WindMin), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "float GetWindMax() const", asFUNCTION(CCircuitAI_WindMax), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "float GetWindCur() const", asFUNCTION(CCircuitAI_WindCur), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "float GetTidalStrength() const", asFUNCTION(CCircuitAI_Tidal), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "int GetMetalSpotCount() const", asFUNCTION(CCircuitAI_MetalSpots), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "int GetGeoSpotCount() const", asFUNCTION(CCircuitAI_GeoSpots), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "AIFloat3 GetGeoSpot(int) const", asFUNCTION(CCircuitAI_GeoSpot), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CCircuitAI", "float GetIncomeMultiplier() const", asFUNCTION(CCircuitAI_IncomeMultiplier), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterGlobalFunction("int AiTaskReservationId(IUnitTask@)", asFUNCTION(IBuilderTask_GetReservationId), asCALL_CDECL); ASSERT(r >= 0);
    r = engine->RegisterGlobalFunction("bool AiTaskOwnsLayout(IUnitTask@)", asFUNCTION(IBuilderTask_IsLayoutOwned), asCALL_CDECL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CTerrainManager", "int GetTerrainHeight() const", asFUNCTION(CTerrainManager_GetTerrainHeight), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);

	r = engine->RegisterObjectProperty("CSetupManager", "const CCircuitDef@ commChoice", asOFFSET(CSetupManager, commChoice)); ASSERT(r >= 0);
	// The lane point native computes for the front (CalcLanePos); a layout faces it (D-053).
	r = engine->RegisterObjectMethod("CSetupManager", "AIFloat3 GetLanePos() const", asFUNCTION(CSetupManager_GetLanePos), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	// D-126: settings from JSON (data/config/weapons.json and its profile overrides)
	r = engine->RegisterObjectMethod("CSetupManager", "int EnemyStartBoxAt(const AIFloat3& in) const", asMETHOD(CSetupManager, EnemyStartBoxAt), asCALL_THISCALL); ASSERT(r >= 0);  // D-127
	r = engine->RegisterObjectMethod("CSetupManager", "int GetScriptStartCount()", asMETHOD(CSetupManager, GetScriptStartCount), asCALL_THISCALL); ASSERT(r >= 0);  // D-127
	r = engine->RegisterObjectMethod("CSetupManager", "AIFloat3 GetScriptStart(int)", asMETHOD(CSetupManager, GetScriptStart), asCALL_THISCALL); ASSERT(r >= 0);  // D-127
	r = engine->RegisterObjectMethod("CSetupManager", "bool IsScriptStartEnemy(int)", asMETHOD(CSetupManager, IsScriptStartEnemy), asCALL_THISCALL); ASSERT(r >= 0);  // D-127
	r = engine->RegisterObjectMethod("CSetupManager", "float ConfigFloat(const string& in, float)", asFUNCTION(CSetupManager_ConfigFloat), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CSetupManager", "int ConfigInt(const string& in, int)", asFUNCTION(CSetupManager_ConfigInt), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CSetupManager", "bool ConfigBool(const string& in, bool)", asFUNCTION(CSetupManager_ConfigBool), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CSetupManager", "string ConfigString(const string& in, const string& in)", asFUNCTION(CSetupManager_ConfigString), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);

	// D-126: battlefield analysis for TECH's weapon clusters (terrain/BattleAnalysis.h)
	CBattleAnalysis* battle = circuit->GetBattle();
	r = engine->RegisterObjectType("CBattleAnalysis", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CBattleAnalysis aiBattle", battle); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float Height(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, Height), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetWaterSurveyCoverage(int, int)", asMETHOD(CBattleAnalysis, GetWaterSurveyCoverage), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetWaterScoutGoal(int, int, const AIFloat3& in, int)", asMETHOD(CBattleAnalysis, GetWaterScoutGoal), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetWaterEnemyCount(int)", asMETHOD(CBattleAnalysis, GetWaterEnemyCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float Depth(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, Depth), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float HeightAbove(const AIFloat3& in, float) const", asMETHOD(CBattleAnalysis, HeightAbove), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float EffectiveRange(const CCircuitDef@, const AIFloat3& in, const AIFloat3& in) const", asMETHOD(CBattleAnalysis, EffectiveRange), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float MainRange(const CCircuitDef@) const", asMETHOD(CBattleAnalysis, MainRange), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float InterceptorCoverage(const CCircuitDef@) const", asMETHOD(CBattleAnalysis, InterceptorCoverage), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetAirContactCount() const", asMETHOD(CBattleAnalysis, GetAirContactCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetAirContactId(int) const", asMETHOD(CBattleAnalysis, GetAirContactId), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetGroundContactCount() const", asMETHOD(CBattleAnalysis, GetGroundContactCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetGroundContactId(int) const", asMETHOD(CBattleAnalysis, GetGroundContactId), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetGroundContactDefId(int) const", asMETHOD(CBattleAnalysis, GetGroundContactDefId), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetGroundContactPos(int) const", asMETHOD(CBattleAnalysis, GetGroundContactPos), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetGroundContactCost(int) const", asMETHOD(CBattleAnalysis, GetGroundContactCost), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsGroundContactEconomy(int) const", asMETHOD(CBattleAnalysis, IsGroundContactEconomy), asCALL_THISCALL); ASSERT(r >= 0);
    // D-296 scout raids: economy kind flags, observed ground hazard, raid route.
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetGroundContactKind(int) const", asMETHOD(CBattleAnalysis, GetGroundContactKind), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float GroundHazard(const AIFloat3& in, float)", asMETHOD(CBattleAnalysis, GroundHazard), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "void SetUnknownHazardRange(float)", asMETHOD(CBattleAnalysis, SetUnknownHazardRange), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "array<AIFloat3>@ GetUnitRaidRoute(const CCircuitDef@, const AIFloat3& in, const AIFloat3& in, float, float, bool avoidHazards = false)", asFUNCTION(CBattleAnalysis_GetUnitRaidRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetNavalContactCount() const", asMETHOD(CBattleAnalysis, GetNavalContactCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetNavalContactPos(int) const", asMETHOD(CBattleAnalysis, GetNavalContactPos), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetAllyAssetCount()", asMETHOD(CBattleAnalysis, GetAllyAssetCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetAllyAssetPos(int) const", asMETHOD(CBattleAnalysis, GetAllyAssetPos), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetAllyAssetCost(int) const", asMETHOD(CBattleAnalysis, GetAllyAssetCost), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float AmphThreat(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, AmphThreat), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "array<AIFloat3>@ GetTerrainRoute(const AIFloat3& in, const AIFloat3& in, int, float, float, float, float)", asFUNCTION(CBattleAnalysis_GetTerrainRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "array<AIFloat3>@ GetUnitTerrainRoute(const CCircuitDef@, const AIFloat3& in, const AIFloat3& in, bool, float, float, float, float)", asFUNCTION(CBattleAnalysis_GetUnitTerrainRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetAirContactPos(int) const", asMETHOD(CBattleAnalysis, GetAirContactPos), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetAirContactCost(int) const", asMETHOD(CBattleAnalysis, GetAirContactCost), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsAirContactArmed(int) const", asMETHOD(CBattleAnalysis, IsAirContactArmed), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetArmedAirCost() const", asMETHOD(CBattleAnalysis, GetArmedAirCost), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float ShotEnergy(const CCircuitDef@) const", asMETHOD(CBattleAnalysis, ShotEnergy), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float ShotReload(const CCircuitDef@) const", asMETHOD(CBattleAnalysis, ShotReload), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool LineOfFire(const AIFloat3& in, const AIFloat3& in, float) const", asMETHOD(CBattleAnalysis, LineOfFire), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void SetHeatHalfLife(float, float)", asMETHOD(CBattleAnalysis, SetHeatHalfLife), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void ClearSources()", asMETHOD(CBattleAnalysis, ClearSources), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void AddSource(const AIFloat3& in)", asMETHOD(CBattleAnalysis, AddSource), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int Analyse(const AIFloat3& in, int, float, float)", asMETHOD(CBattleAnalysis, Analyse), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsAnalysed() const", asMETHOD(CBattleAnalysis, IsAnalysed), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float RouteHeat(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, RouteHeat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float RouteShare(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, RouteShare), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsFriendlyLane(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, IsFriendlyLane), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetChokeCount() const", asMETHOD(CBattleAnalysis, GetChokeCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetChokePos(int) const", asMETHOD(CBattleAnalysis, GetChokePos), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetChokeDir(int) const", asMETHOD(CBattleAnalysis, GetChokeDir), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetChokeWidth(int) const", asMETHOD(CBattleAnalysis, GetChokeWidth), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetChokeHeat(int) const", asMETHOD(CBattleAnalysis, GetChokeHeat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetChokeShare(int) const", asMETHOD(CBattleAnalysis, GetChokeShare), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetRouteCount() const", asMETHOD(CBattleAnalysis, GetRouteCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetRoutePoint(int, float) const", asMETHOD(CBattleAnalysis, GetRoutePoint), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float CombatHeat(const AIFloat3& in, float) const", asMETHOD(CBattleAnalysis, CombatHeat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 CombatNear(const AIFloat3& in, float) const", asMETHOD(CBattleAnalysis, CombatNear), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float AirHeat(const AIFloat3& in, float) const", asMETHOD(CBattleAnalysis, AirHeat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 AirCentre(const AIFloat3& in, float) const", asMETHOD(CBattleAnalysis, AirCentre), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float EnemyCost(int) const", asMETHOD(CBattleAnalysis, EnemyCost), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void SampleNavalThreat(const AIFloat3& in, float)", asMETHOD(CBattleAnalysis, SampleNavalThreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetNavalThreatCost(int) const", asMETHOD(CBattleAnalysis, GetNavalThreatCost), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int EnemyCount(int) const", asMETHOD(CBattleAnalysis, EnemyCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float SurfThreat(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, SurfThreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float AirThreat(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, AirThreat), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "bool InLos(const AIFloat3& in) const", asMETHOD(CBattleAnalysis, InLos), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float AirThreatAlong(const AIFloat3& in, const AIFloat3& in, float) const", asMETHOD(CBattleAnalysis, AirThreatAlong), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetSeaForceCount()", asMETHOD(CBattleAnalysis, GetSeaForceCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "bool OutsideStaticWaterWeapons(const AIFloat3& in, float, float)", asMETHOD(CBattleAnalysis, OutsideStaticWaterWeapons), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetSeaForceId(int) const", asMETHOD(CBattleAnalysis, GetSeaForceId), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetSeaForceDefId(int) const", asMETHOD(CBattleAnalysis, GetSeaForceDefId), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetSeaForceFlags(int) const", asMETHOD(CBattleAnalysis, GetSeaForceFlags), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetSeaForceBody(int) const", asMETHOD(CBattleAnalysis, GetSeaForceBody), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetSeaForceCost(int) const", asMETHOD(CBattleAnalysis, GetSeaForceCost), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetSeaForcePos(int) const", asMETHOD(CBattleAnalysis, GetSeaForcePos), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetNavalForceCount()", asMETHOD(CBattleAnalysis, GetNavalForceCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetNavalForceId(int) const", asMETHOD(CBattleAnalysis, GetNavalForceId), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetNavalForceDefId(int) const", asMETHOD(CBattleAnalysis, GetNavalForceDefId), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetNavalForceFlags(int) const", asMETHOD(CBattleAnalysis, GetNavalForceFlags), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetNavalForceBody(int) const", asMETHOD(CBattleAnalysis, GetNavalForceBody), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetNavalForceCost(int) const", asMETHOD(CBattleAnalysis, GetNavalForceCost), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetNavalForcePos(int) const", asMETHOD(CBattleAnalysis, GetNavalForcePos), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int WaterBody(const AIFloat3& in, bool) const", asMETHOD(CBattleAnalysis, WaterBody), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void PrepareWater()", asMETHOD(CBattleAnalysis, PrepareWater), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsHostileWater(int, bool) const", asMETHOD(CBattleAnalysis, IsHostileWater), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void MarkHostileWater(const AIFloat3& in, float)", asMETHOD(CBattleAnalysis, MarkHostileWater), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool TorpedoSiteOK(const CCircuitDef@, const AIFloat3& in, float, bool) const", asMETHOD(CBattleAnalysis, TorpedoSiteOK), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int AnalyseBeaches(const AIFloat3& in, float)", asMETHOD(CBattleAnalysis, AnalyseBeaches), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetBeachCount() const", asMETHOD(CBattleAnalysis, GetBeachCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetBeachPos(int) const", asMETHOD(CBattleAnalysis, GetBeachPos), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetBeachSeaward(int) const", asMETHOD(CBattleAnalysis, GetBeachSeaward), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetBeachClass(int) const", asMETHOD(CBattleAnalysis, GetBeachClass), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetBeachHeat(int) const", asMETHOD(CBattleAnalysis, GetBeachHeat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetBeachDepth(int, float) const", asMETHOD(CBattleAnalysis, GetBeachDepth), asCALL_THISCALL); ASSERT(r >= 0);
	// D-127: lanes between both teams' starts, per movement class
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void ClearLaneEnds()", asMETHOD(CBattleAnalysis, ClearLaneEnds), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void AddAllyEnd(const AIFloat3& in)", asMETHOD(CBattleAnalysis, AddAllyEnd), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void AddEnemyEnd(const AIFloat3& in)", asMETHOD(CBattleAnalysis, AddEnemyEnd), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void BeginLanePostprocess()", asMETHOD(CBattleAnalysis, BeginLanePostprocess), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void EndLanePostprocess()", asMETHOD(CBattleAnalysis, EndLanePostprocess), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool RequestLanes(int, float, float, float = 1, float = 128, float = 3, int = 3)", asMETHOD(CBattleAnalysis, RequestLanes), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsLanePending() const", asMETHOD(CBattleAnalysis, IsLanePending), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetLaneRevision() const", asMETHOD(CBattleAnalysis, GetLaneRevision), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void CancelLaneRequest()", asMETHOD(CBattleAnalysis, CancelLaneRequest), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int AnalyseLanes(int, float, float, float = 1, float = 128, float = 3, int = 3)", asMETHOD(CBattleAnalysis, AnalyseLanes), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetLaneMask(int) const", asMETHOD(CBattleAnalysis, GetLaneMask), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void SetCliffDescentParams(int, float, float, float)", asMETHOD(CBattleAnalysis, SetCliffDescentParams), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void SetMountainPathParams(float, float)", asMETHOD(CBattleAnalysis, SetMountainPathParams), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsLaneSpecialist(int) const", asMETHOD(CBattleAnalysis, IsLaneSpecialist), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void SetSpecialistSpan(float, float)", asMETHOD(CBattleAnalysis, SetSpecialistSpan), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void SetMountainShelfParams(float, float)", asMETHOD(CBattleAnalysis, SetMountainShelfParams), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "void SetCliffPreference(float, float, float)", asMETHOD(CBattleAnalysis, SetCliffPreference), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetLaneAscent(int) const", asMETHOD(CBattleAnalysis, GetLaneAscent), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetLaneCliffQuality(int, int) const", asMETHOD(CBattleAnalysis, GetLaneCliffQuality), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetLaneDescent(int) const", asMETHOD(CBattleAnalysis, GetLaneDescent), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetLaneCount() const", asMETHOD(CBattleAnalysis, GetLaneCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetLaneClass(int) const", asMETHOD(CBattleAnalysis, GetLaneClass), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetLanePoint(int, float) const", asMETHOD(CBattleAnalysis, GetLanePoint), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "array<AIFloat3>@ GetLaneRoute(int, const AIFloat3& in, int) const", asFUNCTION(CBattleAnalysis_GetLaneRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetLaneLength(int) const", asMETHOD(CBattleAnalysis, GetLaneLength), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetLaneWidth(int) const", asMETHOD(CBattleAnalysis, GetLaneWidth), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "AIFloat3 GetLaneChoke(int) const", asMETHOD(CBattleAnalysis, GetLaneChoke), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetLaneThreat(int) const", asMETHOD(CBattleAnalysis, GetLaneThreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "float GetLaneFront(int) const", asMETHOD(CBattleAnalysis, GetLaneFront), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "int GetLaneHeat(int) const", asMETHOD(CBattleAnalysis, GetLaneHeat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBattleAnalysis", "bool IsPassable(const AIFloat3& in, int) const", asMETHOD(CBattleAnalysis, IsPassable), asCALL_THISCALL); ASSERT(r >= 0);

	CEnemyManager* enemyMgr = circuit->GetEnemyManager();
	r = engine->RegisterObjectType("CEnemyManager", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CEnemyManager aiEnemyMgr", enemyMgr); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEnemyManager", "float GetEnemyThreat(Type) const", asMETHODPR(CEnemyManager, GetEnemyThreat, (CCircuitDef::RoleT) const, float), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEnemyManager", "const float mobileThreat", asOFFSET(CEnemyManager, mobileThreat)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEnemyManager", "float GetEnemyCost(Type) const", asMETHOD(CEnemyManager, GetEnemyCost), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEnemyManager", "AIFloat3 GetNearestGroupPos(const AIFloat3& in, float minCost) const", asMETHOD(CEnemyManager, GetNearestGroupPos), asCALL_THISCALL); ASSERT(r >= 0);  // D-096
	r = engine->RegisterObjectProperty("CEnemyManager", "float maxAAThreat", asOFFSET(CEnemyManager, maxAAThreat)); ASSERT(r >= 0);

	CThreatMap* thrMap = circuit->GetThreatMap();
	r = engine->RegisterObjectType("CThreatMap", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CThreatMap aiThreat", thrMap); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CThreatMap", "void ApplyRange(CCircuitDef@)", asMETHOD(CThreatMap, ApplyRange), asCALL_THISCALL); ASSERT(r >= 0);
}

bool CInitScript::Init()
{
	if (!script->Load(CScriptManager::mainName.c_str(), folderName, CScriptManager::mainName + ".as")) {
		return false;
	}

	asIScriptModule* mod = script->GetEngine()->GetModule(CScriptManager::mainName.c_str());
	int r = mod->SetDefaultNamespace("Main"); ASSERT(r >= 0);
	mainInfo.update = script->GetFunc(mod, "void AiUpdate()");
	mainInfo.luaMessage = script->GetFunc(mod, "void AiLuaMessage(const string& in)");
	mainInfo.receiveMessage = script->GetFunc(mod, "void AiMessage(const string& in, int)");
	mainInfo.unitFinished = script->GetFunc(mod, "void AiUnitFinished(CCircuitUnit@)");
	mainInfo.unitDestroyed = script->GetFunc(mod, "void AiUnitDestroyed(CCircuitUnit@)");
	mainInfo.superWeaponFired = script->GetFunc(mod, "void AiSuperWeaponFired(CCircuitUnit@, const AIFloat3& in)");
	asIScriptFunction* main = script->GetFunc(mod, "void AiMain()");
	if (main == nullptr) {
		return false;
	}

	asIScriptContext* ctx = script->PrepareContext(main);
	script->Exec(ctx);
	script->ReturnContext(ctx);
	return true;
}

void CInitScript::Update()
{
	if (mainInfo.update == nullptr) {
		return;
	}
	asIScriptContext* ctx = script->PrepareContext(mainInfo.update);
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

void CInitScript::LuaMessage(const char* inData)
{
	if (mainInfo.luaMessage == nullptr) {
		return;
	}
	asIScriptContext* ctx = script->PrepareContext(mainInfo.luaMessage);
	std::string data(inData);
	ctx->SetArgAddress(0, &data);
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

void CInitScript::UnitFinished(CCircuitUnit* unit)
{
	if (mainInfo.unitFinished == nullptr) {
		return;
	}
	asIScriptContext* ctx = script->PrepareContext(mainInfo.unitFinished);
	ctx->SetArgObject(0, unit);
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

void CInitScript::UnitDestroyed(CCircuitUnit* unit)
{
	if (mainInfo.unitDestroyed == nullptr) {
		return;
	}
	asIScriptContext* ctx = script->PrepareContext(mainInfo.unitDestroyed);
	ctx->SetArgObject(0, unit);
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

void CInitScript::SuperWeaponFired(CCircuitUnit* unit, const AIFloat3& aim)
{
	if (mainInfo.superWeaponFired == nullptr) return;
	asIScriptContext* ctx = script->PrepareContext(mainInfo.superWeaponFired);
	ctx->SetArgObject(0, unit);
	ctx->SetArgObject(1, const_cast<AIFloat3*>(&aim));
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

template <class T>
void CInitScript::RegisterIUnitTask(asIScriptEngine* engine, const char* cls)
{
	T::RegisterRefCounted(engine, cls);
	int r;
	r = engine->RegisterObjectMethod(cls, "Type GetType() const", asMETHODPR(T, GetType, () const, IUnitTask::Type), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "bool IsEnemyReclaim() const", asMETHOD(T, IsEnemyReclaim), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "bool IsExternalControlled() const", asMETHOD(T, IsExternalControlled), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "array<CCircuitUnit@>@ GetUnits() const", asFUNCTION(IUnitTask_GetUnits), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "void Abort()", asMETHOD(T, Abort), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "void Done()", asMETHOD(T, Done), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "bool IsDead() const", asMETHODPR(T, IsDead, () const, bool), asCALL_THISCALL); ASSERT(r >= 0);  // D-114: a kept task handle is checked before reuse
}

static int IBuilderTask_GuardTargetId(const IBuilderTask* task)
{
	// Guard uses an ID-owned VIP, not BuilderTask::target (which is null).
	// Expose observation without changing that ownership or any task behavior.
	const auto* guard=dynamic_cast<const CBGuardTask*>(task);
	return guard ? guard->GetGuardTargetId() : -1;
}

template <class T>
void CInitScript::RegisterIBuilderTask(asIScriptEngine* engine, const char* cls)
{
	RegisterIUnitTask<T>(engine, cls);
	RegisterCast<IUnitTask, T>(engine, "IUnitTask", cls);
	int r;
	r = engine->RegisterObjectMethod(cls, "Type GetBuildType() const", asMETHODPR(T, GetBuildType, () const, IBuilderTask::BuildType), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "const AIFloat3& GetBuildPos() const", asMETHODPR(T, GetPosition, () const, const AIFloat3&), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty(cls, "CCircuitDef@ const buildDef", asOFFSET(T, buildDef)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty(cls, "CCircuitUnit@ const target", asOFFSET(T, target)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty(cls, "bool canAutoAbort", asOFFSET(T, canAutoAbort)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod(cls, "int GetGuardTargetId() const", asFUNCTION(IBuilderTask_GuardTargetId), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
}

template <class T>
void CInitScript::RegisterIFighterTask(asIScriptEngine* engine, const char* cls)
{
	RegisterIUnitTask<T>(engine, cls);
	RegisterCast<IUnitTask, T>(engine, "IUnitTask", cls);
	int r = engine->RegisterObjectMethod(cls, "Type GetFightType() const", asMETHODPR(T, GetFightType, () const, IFighterTask::FightType), asCALL_THISCALL); ASSERT(r >= 0);
}

void CInitScript::RegisterCSuperTask(asIScriptEngine* engine)
{
	RegisterIFighterTask<CSuperTask>(engine, "CSuperTask");
	RegisterCast<IFighterTask, CSuperTask>(engine, "IFighterTask", "CSuperTask");
	int r = engine->RegisterObjectMethod("CSuperTask", "void SetTargetPos(const AIFloat3& in)", asMETHOD(CSuperTask, SetTargetPos), asCALL_THISCALL); ASSERT(r >= 0);
}

static void CRouteTask_SetRoute(CRouteTask* task, const CScriptArray* array)
{
	std::vector<AIFloat3> route;
	route.reserve(array->GetSize());
	for (asUINT i = 0; i < array->GetSize(); ++i) {
		route.push_back(*static_cast<const AIFloat3*>(array->At(i)));
	}
	task->SetRoute(std::move(route));
}

static bool CRouteTask_SetUnitRoute(CRouteTask* task, CCircuitUnit* unit, const CScriptArray* array, float radius)
{
    if (array==nullptr) return false;
    std::vector<AIFloat3> route;
    route.reserve(array->GetSize());
    for (asUINT i=0;i<array->GetSize();++i) route.push_back(*static_cast<const AIFloat3*>(array->At(i)));
    return task->SetUnitRoute(unit,std::move(route),radius);
}

void CInitScript::RegisterCRouteTask(asIScriptEngine* engine)
{
	RegisterIFighterTask<CRouteTask>(engine, "CRouteTask");
	RegisterCast<IFighterTask, CRouteTask>(engine, "IFighterTask", "CRouteTask");
	int r = engine->RegisterObjectMethod("CRouteTask", "void SetRoute(const array<AIFloat3>@+)", asFUNCTION(CRouteTask_SetRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "bool SetUnitRoute(CCircuitUnit@, const array<AIFloat3>@+, float)", asFUNCTION(CRouteTask_SetUnitRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CRouteTask", "int GetRouteVersion() const", asMETHOD(CRouteTask, GetRouteVersion), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CRouteTask", "uint GetRouteSize() const", asMETHOD(CRouteTask, GetRouteSize), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CRouteTask", "bool IsAtEnd(CCircuitUnit@) const", asMETHOD(CRouteTask, IsAtEnd), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CRouteTask", "void SetLanes(int, float, float)", asMETHOD(CRouteTask, SetLanes), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CRouteTask", "void SetTraversal(bool, float, bool)", asMETHOD(CRouteTask, SetTraversal), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CRouteTask", "void SetPatrol(bool)", asMETHOD(CRouteTask, SetPatrol), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "void SetAirControl(bool)", asMETHOD(CRouteTask, SetAirControl), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "void SetSeaControl(bool)", asMETHOD(CRouteTask, SetSeaControl), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "void SetMoveCompaction(bool)", asMETHOD(CRouteTask, SetMoveCompaction), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "void SetRowSpacing(float)", asMETHOD(CRouteTask, SetRowSpacing), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "bool SetNavalTarget(int)", asMETHOD(CRouteTask, SetNavalTarget), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "bool SetLandTarget(int)", asMETHOD(CRouteTask, SetLandTarget), asCALL_THISCALL); ASSERT(r >= 0); // D-296
    r = engine->RegisterObjectMethod("CRouteTask", "int GetPriorityTarget() const", asMETHOD(CRouteTask, GetPriorityTarget), asCALL_THISCALL); ASSERT(r >= 0); // D-296
    r = engine->RegisterObjectMethod("CRouteTask", "void SetRepairThreshold(float)", asMETHOD(CRouteTask, SetRepairThreshold), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "void SetCombatRetreat(bool)", asMETHOD(CRouteTask, SetCombatRetreat), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "bool SetSeaTarget(int)", asMETHOD(CRouteTask, SetSeaTarget), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "void SetAirTarget(int)", asMETHOD(CRouteTask, SetAirTarget), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CRouteTask", "void SetHoldPosition(bool)", asMETHOD(CRouteTask, SetHoldPosition), asCALL_THISCALL); ASSERT(r >= 0);
}

void CInitScript::RegisterCFerryTask(asIScriptEngine* engine)
{
	RegisterIFighterTask<CFerryTask>(engine, "CFerryTask");
	RegisterCast<IFighterTask, CFerryTask>(engine, "IFighterTask", "CFerryTask");
	// Cargo is addressed by unit id, not by handle: the script side holds ids
	// across frames (the donation it is waiting on may outlive any handle it
	// captured) and CFerryTask resolves them through CCircuitAI::GetTeamUnit.
	int r = engine->RegisterObjectMethod("CFerryTask", "void SetHoldPos(const AIFloat3& in)", asMETHOD(CFerryTask, SetHoldPos), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CFerryTask", "bool SetCargo(int, const AIFloat3& in, float surfaceThreat = -1, float airThreat = -1)", asMETHOD(CFerryTask, SetCargo), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CFerryTask", "bool CanCarry(int) const", asMETHOD(CFerryTask, CanCarry), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CFerryTask", "bool SetCargoRoute(int, const array<AIFloat3>& in, float, float, float, float = 90.0f)", asFUNCTION(CFerryTask_SetCargoRoute), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CFerryTask", "int GetState() const", asMETHOD(CFerryTask, GetState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CFerryTask", "int GetCargoId() const", asMETHOD(CFerryTask, GetCargoId), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CFerryTask", "void Reset()", asMETHOD(CFerryTask, Reset), asCALL_THISCALL); ASSERT(r >= 0);
}

static AIFloat3 CAirWaveTask_GetAim(CAirWaveTask* task)
{
	return task->GetAim();
}

void CInitScript::RegisterCAirWaveTask(asIScriptEngine* engine)
{
	RegisterIFighterTask<CAirWaveTask>(engine, "CAirWaveTask");
	RegisterCast<IFighterTask, CAirWaveTask>(engine, "IFighterTask", "CAirWaveTask");
	// doc/air-wave-attacks.md. Modes are Task::WaveMode; 999 as the bearing
	// means "sample the threat map".
	int r = engine->RegisterObjectMethod("CAirWaveTask", "void SetPlan(int mode, const AIFloat3& in aim, float formDistance, float spacing, float overrun, int formTimeout, int holdFrames, float bearingDeg, int groups)", asMETHOD(CAirWaveTask, SetPlan), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void SetFlightPolicy(float, float, float, const AIFloat3& in)", asMETHOD(CAirWaveTask, SetFlightPolicy), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void SetStrikePolicy(CCircuitDef@, int, float, float, float, float)", asMETHOD(CAirWaveTask, SetStrikePolicy), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "int GetRequiredBombers() const", asMETHOD(CAirWaveTask, GetRequiredBombers), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void ConsiderStrikeAircraft(CCircuitDef@)", asMETHOD(CAirWaveTask, ConsiderStrikeAircraft), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void SetMissionPolicy(float, float, float, float, float, float, bool)", asMETHOD(CAirWaveTask, SetMissionPolicy), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void ExcludeStrikeRegion(const AIFloat3& in, float)", asMETHOD(CAirWaveTask, ExcludeStrikeRegion), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void SetAssemblyPolicy(float, float, int)", asMETHOD(CAirWaveTask, SetAssemblyPolicy), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CAirWaveTask", "bool PickStrikeTarget(const AIFloat3& in from, int preference, float minStaticCost, bool includeHeavy)", asMETHOD(CAirWaveTask, PickStrikeTarget), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void SetOperationPolicy(bool, int, const AIFloat3& in, float, float, float)", asMETHOD(CAirWaveTask, SetOperationPolicy), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void SetAttackHandoffPolicy(bool, float, float)", asMETHOD(CAirWaveTask, SetAttackHandoffPolicy), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void AddTargetFallback(int)", asMETHOD(CAirWaveTask, AddTargetFallback), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "bool PickOperationTarget(const AIFloat3& in, float, bool includePrimary = true)", asMETHOD(CAirWaveTask, PickOperationTarget), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void AllowStrikeDef(CCircuitDef@, float)", asMETHOD(CAirWaveTask, AllowStrikeDef), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "void AddSearchPoint(const AIFloat3& in)", asMETHOD(CAirWaveTask, AddSearchPoint), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "int GetBomberCount() const", asMETHOD(CAirWaveTask, GetBomberCount), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "int GetTargetsDestroyed() const", asMETHOD(CAirWaveTask, GetTargetsDestroyed), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CAirWaveTask", "float GetDamageDealt() const", asMETHOD(CAirWaveTask, GetDamageDealt), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CAirWaveTask", "int GetState() const", asMETHOD(CAirWaveTask, GetState), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CAirWaveTask", "int GetMode() const", asMETHOD(CAirWaveTask, GetMode), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CAirWaveTask", "AIFloat3 GetAim() const", asFUNCTION(CAirWaveTask_GetAim), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CAirWaveTask", "int GetStrikeTargetId() const", asMETHOD(CAirWaveTask, GetStrikeTargetId), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CAirWaveTask", "float GetBearingDeg() const", asMETHOD(CAirWaveTask, GetBearingDeg), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CAirWaveTask", "int GetFormedCount() const", asMETHOD(CAirWaveTask, GetFormedCount), asCALL_THISCALL); ASSERT(r >= 0);
}

void CInitScript::RegisterUnitTasks(asIScriptEngine* engine)
{
	RegisterIUnitTask<IUnitTask>(engine, "IUnitTask");
	RegisterIBuilderTask<IBuilderTask>(engine, "IBuilderTask");
	RegisterIFighterTask<IFighterTask>(engine, "IFighterTask");
	RegisterCSuperTask(engine);
	RegisterCRouteTask(engine);
	RegisterCFerryTask(engine);
	RegisterCAirWaveTask(engine);
}

CMaskHandler::TypeMask CInitScript::AddRole(const std::string& name, int actAsRole)
{
	CMaskHandler::TypeMask result = circuit->GetGameAttribute()->GetRoleMasker().GetTypeMask(name);
	if (result.type < 0) {
		return result;
	}
	circuit->BindRole(result.type, actAsRole);
	return result;
}

void CInitScript::PerfBegin(int phase) const { performance::Begin(circuit, phase); }
void CInitScript::PerfEnd(int phase) const { performance::End(circuit, phase); }
void CInitScript::PerfBeginLabel(const std::string& label) const { performance::BeginLabel(circuit, label); }
void CInitScript::PerfEndLabel() const { performance::EndLabel(circuit); }

void CInitScript::Log(const std::string& msg) const
{
	std::lock_guard<spring::mutex> mlock(mtx);
	circuit->LOG("%s", msg.c_str());
}

void CInitScript::AddPoint(const AIFloat3& pos, const std::string& msg) const
{
	circuit->GetDrawer()->AddPoint(pos, msg.c_str());
}

void CInitScript::DelPoint(const AIFloat3& pos) const
{
	circuit->GetDrawer()->DeletePointsAndLines(pos);
}

void CInitScript::AddLine(const AIFloat3& posA, const AIFloat3& posB) const
{
	circuit->GetDrawer()->AddLine(posA, posB);
}

void CInitScript::QueueLine(const AIFloat3& posA, const AIFloat3& posB) const
{
	circuit->QueueDrawLine(posA, posB);
}

void CInitScript::QueuePoint(const AIFloat3& pos, const std::string& msg) const
{
	circuit->QueueDrawPoint(pos, msg);
}

void CInitScript::QueueErase(const AIFloat3& pos) const
{
	circuit->QueueDrawErase(pos);
}

int CInitScript::DrawQueueSize() const
{
	return circuit->GetDrawQueueSize();
}

void CInitScript::DrawQueueClear() const
{
	circuit->ClearDrawQueue();
}

void CInitScript::DrawPace(int perBatch, int ms) const
{
	circuit->SetDrawPace(perBatch, ms);
}

void CInitScript::Pause(bool enable, const std::string& msg) const
{
	circuit->GetGame()->SetPause(enable, msg.c_str());
}

int CInitScript::Dice(const CScriptArray* array) const
{
	float magnitude = 0.f;
	for (asUINT i = 0; i < array->GetSize(); ++i) {
		magnitude += *static_cast<const float*>(array->At(i));
	}
	float dice = (float)rand() / RAND_MAX * magnitude;
	for (asUINT i = 0; i < array->GetSize(); ++i) {
		dice -= *static_cast<const float*>(array->At(i));
		if (dice < 0.f) {
			return i;
		}
	}
	return -1;
}

int CInitScript::NearestPointIdx(const AIFloat3& pos, const CScriptArray* array)
{
	float bestSqDist = std::numeric_limits<float>::max();
	int bestIdx = -1;
	for (asUINT i = 0; i < array->GetSize(); ++i) {
		float d = pos.SqDistance2D(*static_cast<const AIFloat3*>(array->At(i)));
		if (d < bestSqDist) {
			bestSqDist = d;
			bestIdx = i;
		}
	}
	return bestIdx;
}

void CInitScript::SendMessage(const std::string& msg, int toTeamId)
{
	// NOTE: Can access ai->script because of "friend class CInitScript;"
	if (toTeamId < 0) {
		for (CCircuitAI* ai : circuit->GetGameAttribute()->GetCircuits()) {
			if (ai->IsInitialized()
				&& (ai->GetTeamId() != circuit->GetTeamId())
				&& (ai->GetAllyTeamId() == circuit->GetAllyTeamId())
				&& ai->script->mainInfo.receiveMessage != nullptr)
			{
				int fromTeamId = circuit->GetTeamId();
				ai->GetScheduler()->RunJobAfter(CScheduler::GameJob([ai, msg, fromTeamId]() {
					ai->script->ReceiveMessage(msg, fromTeamId);
				}));
			}
		}
	} else {
		for (CCircuitAI* ai : circuit->GetGameAttribute()->GetCircuits()) {
			if (ai->IsInitialized()
				&& (ai->GetTeamId() == toTeamId)
				&& (ai->GetAllyTeamId() == circuit->GetAllyTeamId())
				&& ai->script->mainInfo.receiveMessage != nullptr)
			{
				int fromTeamId = circuit->GetTeamId();
				ai->GetScheduler()->RunJobAfter(CScheduler::GameJob([ai, msg, fromTeamId]() {
					ai->script->ReceiveMessage(msg, fromTeamId);
				}));
				return;
			}
		}
	}
}

void CInitScript::ReceiveMessage(const std::string& msg, int fromTeamId)
{
	// NOTE: Check done in CInitScript::SendMessage
//	if (mainInfo.receiveMessage == nullptr) {
//		return;
//	}
	asIScriptContext* ctx = script->PrepareContext(mainInfo.receiveMessage);
	ctx->SetArgAddress(0, &const_cast<std::string&>(msg));
	ctx->SetArgDWord(1, fromTeamId);
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

void CInitScript::Run(asIScriptFunction* exec, CScriptDictionary* arg)
{
	// NOTE: If engines created in threads:
	// asPrepareMultithread, asUnprepareMultithread, asThreadCleanup, asGetThreadManager;
	// asAtomicInc, asAtomicDec, asAcquireExclusiveLock, asReleaseExclusiveLock, asAcquireSharedLock, asReleaseSharedLock;
	// ensure garbage collection behaviours are thread safe.
	if (exec == nullptr) {
		return;
	}
	asIScriptContext* ctx = script->RequestContext();  // in main thread to avoid mutexes
	takenContexts[ctx] = arg;
	circuit->GetScheduler()->RunParallelJob(CScheduler::WorkJob([this, ctx, exec, arg]() {
		int r = ctx->Prepare(exec); ASSERT(r >= 0);
		ctx->SetArgObject(0, arg);
		script->Exec(ctx);
		asIScriptFunction* finish = (asIScriptFunction*)ctx->GetReturnObject();
		if (finish != nullptr) {
			r = ctx->Prepare(finish); ASSERT(r >= 0);
			ctx->SetArgObject(0, arg);
		}
		return CScheduler::GameJob([this, ctx, finish, arg]() {
			takenContexts.erase(ctx);
			if (finish != nullptr) {
				script->Exec(ctx);
			}
			if (arg) {
				arg->Release();
			}
			script->ReturnContext(ctx);
		});
	}));
}

} // namespace circuit
