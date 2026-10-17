/*
 * EconomyScript.cpp
 *
 *  Created on: Apr 19, 2019
 *      Author: rlcevg
 */

#include "script/EconomyScript.h"
#include "script/ScriptManager.h"
#include "module/EconomyManager.h"
#include "module/BuilderManager.h"
#include "resource/EnergyManager.h"
#include "spring/SpringMap.h"
#include "task/builder/BuilderTask.h"
#include "CircuitAI.h"
#include "terrain/TerrainManager.h"
#include "spring/SpringCallback.h"
#include "unit/ally/AllyUnit.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitDef.h"
#include "util/Utils.h"
#include "util/ExtAS.h"
#include "angelscript/include/angelscript.h"
#include "angelscript/add_on/scriptarray/scriptarray.h"

namespace circuit {

using namespace springai;

// Explicit script opt-in. BAR permits an advanced geo over an owned T1 geo;
// its upgrade gadget retires/refunds the old unit on completion. Never reclaim
// the source here. Scan immutable vent positions, then only local occupants.
static IUnitTask* EnqueueLocalGeo(CEconomyManager* economy, CCircuitUnit* builder,
        CCircuitDef* definition, const AIFloat3& center, float radius)
{
    if (!builder || !definition || radius <= 0.f || !definition->GetDef()->IsNeedGeo()
        || !builder->GetCircuitDef()->CanBuild(definition)) return nullptr;
    auto* circuit = economy->GetCircuit();
    auto* manager = circuit->GetBuilderManager();
    auto* terrain = circuit->GetTerrainManager();
    const int frame = circuit->GetLastFrame();
    if (!definition->IsAvailable(frame)) return nullptr;
    const auto& sites = circuit->GetEnergyManager()->GetSpots();
    int chosen = -1;
    float best = radius * radius;
    for (size_t index = 0; index < sites.size(); ++index) {
        const auto& position = sites[index];
        const float distance = position.SqDistance2D(center);
        if (distance > best || terrain->IsZoneAlly(position)
            || !terrain->CanReachAtSafe(builder, position, builder->GetCircuitDef()->GetBuildDistance())
            || !terrain->CanBeBuiltAtSafe(definition, position)
            || terrain->IsAllyLayoutBlocked(definition, position, UNIT_NO_FACING)) continue;
        bool occupied = false;
        for (auto* task : manager->GetTasks(IBuilderTask::BuildType::GEO)) {
            if (task->GetPosition().SqDistance2D(position) < 64.f) { occupied = true; break; }
        }
        if (occupied) continue;
        for (int id : circuit->GetCallback()->GetFriendlyUnitIdsIn(position, 32.f, false)) {
            auto* friendly = circuit->GetFriendlyUnit(id);
            if (!friendly || !friendly->GetCircuitDef()->GetDef()->IsNeedGeo()) continue;
            auto* owned = circuit->GetTeamUnit(id);
            if (!owned || !owned->IsFinished()
                || economy->GetEnergyMake(owned->GetCircuitDef()) >= economy->GetEnergyMake(definition)) {
                occupied = true; break;
            }
        }
        if (occupied || !circuit->GetMap()->IsPossibleToBuildAt(definition->GetDef(), position, UNIT_NO_FACING)) continue;
        best = distance;
        chosen = static_cast<int>(index);
    }
    if (chosen < 0) return nullptr;
    return manager->Enqueue(TaskB::Spot(IBuilderTask::BuildType::GEO,
        IBuilderTask::Priority::HIGH, definition, sites[chosen], chosen));
}

static void CEconomyManager_SetEnergyCondition(CEconomyManager* mgr, const CCircuitDef* cdef, int limit, float mi, float ei)
{
	mgr->SetEnergyCondition(const_cast<CCircuitDef*>(cdef), limit, mi, ei);
}

static int CEconomyManager_GetEnergyLimit(CEconomyManager* mgr, const CCircuitDef* cdef)
{
	return mgr->GetEnergyLimit(const_cast<CCircuitDef*>(cdef));
}

// D-290: the metal storage a definition adds to the team (UnitDef metalStorage).
// One engine definition read per call; called only when a reclaim is decided.
static float CEconomyManager_GetMetalStorageOf(CEconomyManager* mgr, const CCircuitDef* cdef)
{
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr) || (mgr->GetMetalRes() == nullptr)) {
		return 0.f;
	}
	return std::max(0.f, cdef->GetDef()->GetStorage(mgr->GetMetalRes()));
}

static void CEconomyManager_ClearAllyStarts(CEconomyManager* mgr) { mgr->ClearAllyStarts(); }
static void CEconomyManager_AddAllyStart(CEconomyManager* mgr, const AIFloat3& pos) { mgr->AddAllyStart(pos); }
static void SetMexOwnership(CEconomyManager* mgr, bool enabled, float seconds) { mgr->SetMexOwnership(enabled, seconds); }
static void SetMexAllyStart(CEconomyManager* mgr, int team, const AIFloat3& pos, int commander) { mgr->SetMexAllyStart(team, pos, commander); }
static bool CanReachMex(CEconomyManager* mgr, CCircuitUnit* unit, const AIFloat3& pos) { return mgr->CanReachMex(unit, pos); }
static bool IsOwnMex(CEconomyManager* mgr, const AIFloat3& pos) { return mgr->IsOwnSpot(pos); }

static IUnitTask* CEconomyManager_EnqueueMexWithinAware(
		CEconomyManager* mgr, CCircuitUnit* builder, const AIFloat3& center, float radius, int maxSpots, bool allyAware)
{
	return mgr->EnqueueMexWithin(builder, center, radius, maxSpots, allyAware);
}

static IUnitTask* CEconomyManager_EnqueueMexWithin(
		CEconomyManager* mgr, CCircuitUnit* builder, const AIFloat3& center, float radius, int maxSpots)
{
	return mgr->EnqueueMexWithin(builder, center, radius, maxSpots);
}

static IUnitTask* CEconomyManager_EnqueueMexAvoiding(CEconomyManager* mgr,
        CCircuitUnit* builder, const AIFloat3& center, float radius, bool allyAware, CScriptArray* avoid)
{
    std::vector<AIFloat3> excluded;
    if (avoid != nullptr) {
        excluded.reserve(avoid->GetSize());
        for (asUINT i=0; i<avoid->GetSize(); ++i) excluded.push_back(*static_cast<AIFloat3*>(avoid->At(i)));
    }
    return mgr->EnqueueMexWithin(builder, center, radius, 0, allyAware, excluded);
}

// Policy-side admission for explicit mex searches. A cached open spot/queued
// order can outlive allied ownership or a completed extractor. Reevaluate
// would immediately reject it, leaving a SEA ship choosing the same job on
// every idle ask. Bounded local callback only for a candidate, not every tick.
// The caller chooses exclusion/backoff; legacy/native task selection is intact.
static bool CEconomyManager_IsMexTaskUsable(CEconomyManager* mgr, IUnitTask* task)
{
    if (!task || task->IsDead() || task->GetType()!=IUnitTask::Type::BUILDER) return false;
    auto* mex=static_cast<IBuilderTask*>(task);
    if (mex->GetBuildType()!=IBuilderTask::BuildType::MEX || !mex->GetBuildDef()) return false;
    if (mex->GetTarget()) return !mex->GetTarget()->IsDead() && !mex->GetTarget()->IsFinished();
    auto* circuit=mgr->GetCircuit();
    auto* terrain=circuit->GetTerrainManager();
    const auto& pos=mex->GetPosition();
    if (!geom::is_valid(pos) || (mgr->IsMexNavigationEnabled() ? !mgr->IsOwnSpot(pos) : terrain->IsZoneAlly(pos))
        || terrain->IsAllyLayoutBlocked(mex->GetBuildDef(),pos,mex->GetFacing())) return false;
    const auto& ids=circuit->GetCallback()->GetFriendlyUnitIdsIn(pos,mex->GetBuildDef()->GetExtrRangeM(),false);
    for (int id:ids) {
        auto* ally=circuit->GetFriendlyUnit(id);
        if (ally && ally->GetCircuitDef()->IsMex()) return false;
    }
    return true;
}

static IUnitTask* CEconomyManager_EnqueueFieldUpgrade(CEconomyManager* mgr, CCircuitUnit* builder, const AIFloat3& center, float radius)
{
	return mgr->EnqueueFieldUpgrade(builder, center, radius);
}

CEconomyScript::CEconomyScript(CScriptManager* scr, CEconomyManager* mgr)
		: IModuleScript(scr, mgr)
{
	asIScriptEngine* engine = script->GetEngine();

//	r = engine->RegisterObjectType("SResourceInfo", sizeof(CEconomyManager::SResourceInfo), asOBJ_VALUE | asOBJ_POD | asGetTypeTraits<CEconomyManager::SResourceInfo>()); ASSERT(r >= 0);
	int r = engine->RegisterObjectType("SResourceInfo", sizeof(CEconomyManager::SResourceInfo), asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResourceInfo", "const float current", asOFFSET(CEconomyManager::SResourceInfo, current)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResourceInfo", "const float storage", asOFFSET(CEconomyManager::SResourceInfo, storage)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResourceInfo", "const float pull", asOFFSET(CEconomyManager::SResourceInfo, pull)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResourceInfo", "const float income", asOFFSET(CEconomyManager::SResourceInfo, income)); ASSERT(r >= 0);

	r = engine->RegisterObjectType("CEconomyManager", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CEconomyManager aiEconomyMgr", manager); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "IUnitTask@+ EnqueueLocalGeo(CCircuitUnit@, CCircuitDef@, const AIFloat3& in, float)", asFUNCTION(EnqueueLocalGeo), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "bool IsMetalMap() const", asMETHOD(CEconomyManager, IsMetalMap), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetEffectiveUnitLimit() const", asMETHOD(CEconomyManager, GetEffectiveUnitLimit), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetFieldMexCount(const AIFloat3& in, float) const", asMETHOD(CEconomyManager, GetFieldMexCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "float GetFieldYield(const CCircuitDef@, const AIFloat3& in)", asMETHOD(CEconomyManager, GetFieldYield), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "IUnitTask@+ EnqueueFieldUpgrade(CCircuitUnit@, const AIFloat3& in, float)", asFUNCTION(CEconomyManager_EnqueueFieldUpgrade), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "const SResourceInfo metal", asOFFSET(CEconomyManager, metal)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "const SResourceInfo energy", asOFFSET(CEconomyManager, energy)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool isMetalEmpty", asOFFSET(CEconomyManager, isMetalEmpty)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool isMetalFull", asOFFSET(CEconomyManager, isMetalFull)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool isEnergyStalling", asOFFSET(CEconomyManager, isEnergyStalling)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool isEnergyEmpty", asOFFSET(CEconomyManager, isEnergyEmpty)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool isEnergyFull", asOFFSET(CEconomyManager, isEnergyFull)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "float reclConvertEff", asOFFSET(CEconomyManager, reclConvertEff)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "float reclEnergyEff", asOFFSET(CEconomyManager, reclEnergyEff)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool assistNanoEnabled", asOFFSET(CEconomyManager, assistNanoEnabled)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "float assistNanoIncomeMod", asOFFSET(CEconomyManager, assistNanoIncomeMod)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool holdStartFactory", asOFFSET(CEconomyManager, holdStartFactory)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool autoStorageEnabled", asOFFSET(CEconomyManager, autoStorageEnabled)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "bool reclaimOldConvertersAlways", asOFFSET(CEconomyManager, reclaimOldConvertersAlways)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CEconomyManager", "float startMexTravel", asOFFSET(CEconomyManager, startMexTravel)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "float GetMetalMake(const CCircuitDef@) const", asMETHOD(CEconomyManager, GetMetalMake), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "float GetEnergyMake(const CCircuitDef@) const", asMETHOD(CEconomyManager, GetEnergyMake), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "float GetEnergyUse(const CCircuitDef@) const", asMETHOD(CEconomyManager, GetEnergyUse), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetMexSpotCountWithin(CCircuitUnit@, const AIFloat3& in, float, int)", asMETHOD(CEconomyManager, GetMexSpotCountWithin), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "AIFloat3 GetMexCentroidWithin(const AIFloat3& in, float, int) const", asMETHOD(CEconomyManager, GetMexCentroidWithin), asCALL_THISCALL); ASSERT(r >= 0);  // D-086
	// D-106: allied teams' economies (humans included), refreshed on demand, and resource sending
	r = engine->RegisterObjectMethod("CEconomyManager", "bool UpdateTeamEconomy(int)", asMETHOD(CEconomyManager, UpdateTeamEconomy), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int UpdateAllTeamEconomy()", asMETHOD(CEconomyManager, UpdateAllTeamEconomy), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetAllyTeamCount()", asMETHOD(CEconomyManager, GetAllyTeamCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetAllyTeamIdAt(int)", asMETHOD(CEconomyManager, GetAllyTeamIdAt), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "float GetTeamEco(int, int, int) const", asMETHOD(CEconomyManager, GetTeamEco), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetTeamEcoFrame(int) const", asMETHOD(CEconomyManager, GetTeamEcoFrame), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "bool IsTeamAlive(int) const", asMETHOD(CEconomyManager, IsTeamAlive), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "bool SendResourceTo(int, float, int)", asMETHOD(CEconomyManager, SendResourceTo), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "float GetOwnEco(int, int)", asMETHOD(CEconomyManager, GetOwnEco), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetClaimedMexCountWithin(CCircuitUnit@, const AIFloat3& in, float, int)", asMETHOD(CEconomyManager, GetClaimedMexCountWithin), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "IUnitTask@+ EnqueueMexWithin(CCircuitUnit@, const AIFloat3& in, float, int)", asFUNCTION(CEconomyManager_EnqueueMexWithin), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "IUnitTask@+ EnqueueMexWithin(CCircuitUnit@, const AIFloat3& in, float, int, bool allyAware)", asFUNCTION(CEconomyManager_EnqueueMexWithinAware), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "void ClearAllyStarts()", asFUNCTION(CEconomyManager_ClearAllyStarts), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "void AddAllyStart(const AIFloat3& in)", asFUNCTION(CEconomyManager_AddAllyStart), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "void SetMexOwnership(bool, float)", asFUNCTION(SetMexOwnership), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "void SetMexAllyStart(int, const AIFloat3& in, int)", asFUNCTION(SetMexAllyStart), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "bool CanReachMex(CCircuitUnit@, const AIFloat3& in)", asFUNCTION(CanReachMex), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "bool IsOwnMex(const AIFloat3& in)", asFUNCTION(IsOwnMex), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetMexTaskCountWithin(const AIFloat3& in, float) const", asMETHOD(CEconomyManager, GetMexTaskCountWithin), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "IUnitTask@+ EnqueueMexAvoiding(CCircuitUnit@, const AIFloat3& in, float, bool, array<AIFloat3>@)", asFUNCTION(CEconomyManager_EnqueueMexAvoiding), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "bool IsMexTaskUsable(IUnitTask@)", asFUNCTION(CEconomyManager_IsMexTaskUsable), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	// Per-role energy table overrides (D-047); -1 keeps a field.
	r = engine->RegisterObjectMethod("CEconomyManager", "void SetEnergyCondition(const CCircuitDef@, int limit, float metalIncome, float energyIncome)", asFUNCTION(CEconomyManager_SetEnergyCondition), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "int GetEnergyLimit(const CCircuitDef@) const", asFUNCTION(CEconomyManager_GetEnergyLimit), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CEconomyManager", "float GetMetalStorageOf(const CCircuitDef@) const", asFUNCTION(CEconomyManager_GetMetalStorageOf), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);  // D-290
}

CEconomyScript::~CEconomyScript()
{
}

bool CEconomyScript::Init()
{
	asIScriptModule* mod = script->GetEngine()->GetModule(CScriptManager::mainName.c_str());
	int r = mod->SetDefaultNamespace("Economy"); ASSERT(r >= 0);
	InitModule(mod);
	economyInfo.updateEconomy = script->GetFunc(mod, "void AiUpdateEconomy()");
	economyInfo.unitAdded = script->GetFunc(mod, "void AiUnitAdded(CCircuitUnit@, Unit::UseAs)");
	economyInfo.unitRemoved = script->GetFunc(mod, "void AiUnitRemoved(CCircuitUnit@, Unit::UseAs)");
	return true;
}

void CEconomyScript::UpdateEconomy()
{
	if (economyInfo.updateEconomy == nullptr) {
		return;
	}
	asIScriptContext* ctx = script->PrepareContext(economyInfo.updateEconomy);
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

} // namespace circuit
