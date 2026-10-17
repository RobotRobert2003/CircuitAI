/*
 * MilitaryScript.cpp
 *
 *  Created on: Apr 4, 2019
 *      Author: rlcevg
 */

#include "script/MilitaryScript.h"
#include "script/ScriptManager.h"
#include "module/MilitaryManager.h"
#include "CircuitAI.h"
#include "unit/CircuitUnit.h"
#include "util/ExtAS.h"
#include "angelscript/include/angelscript.h"
#include "angelscript/add_on/scriptarray/scriptarray.h"

#include <string>
#include <vector>

namespace circuit {

using namespace springai;

/*
 * Porcupine chain marshalling. The chain is the ordered list of defences a
 * cluster works through, seeded per side from build_chain.json. Exposing it as
 * unit names lets a role read the default, splice mod-conditional tiers into it
 * (Legion, the Extra Units Pack) and write it back, so the ordering is policy
 * in script rather than frozen in JSON. See doc/porc-chain.md.
 *
 * The array type is looked up by declaration rather than cached: this runs once
 * per game, at role setup.
 */
static CScriptArray* CMilitaryManager_GetPorcChain(CMilitaryManager* militaryMgr,
		const std::string& sideName, bool isWater)
{
	asIScriptEngine* engine = asGetActiveContext()->GetEngine();
	asITypeInfo* strArray = engine->GetTypeInfoByDecl("array<string>");
	const std::vector<std::string> names = militaryMgr->GetPorcChain(sideName, isWater);
	CScriptArray* arr = CScriptArray::Create(strArray, asUINT(names.size()));
	for (asUINT i = 0; i < asUINT(names.size()); ++i) {
		*static_cast<std::string*>(arr->At(i)) = names[i];
	}
	return arr;
}

static bool CMilitaryManager_SetPorcChain(CMilitaryManager* militaryMgr,
		const std::string& sideName, bool isWater, const CScriptArray* array)
{
	if (array == nullptr) {
		return false;
	}
	std::vector<std::string> names;
	names.reserve(array->GetSize());
	for (asUINT i = 0; i < array->GetSize(); ++i) {
		names.push_back(*static_cast<const std::string*>(array->At(i)));
	}
	return militaryMgr->SetPorcChain(sideName, isWater, names);
}

// Explicit regrouping between this manager's live fighter tasks. Refuse the
// cross-manager ownership error guarded by ITaskModule::AssignTask(unit).
static bool CMilitaryManager_TransferUnit(CMilitaryManager* mgr, CCircuitUnit* unit, IUnitTask* task)
{
    if (unit == nullptr || task == nullptr || mgr->GetCircuit()->GetTeamUnit(unit->GetId()) != unit
        || task->IsDead() || task->GetManager() != mgr || unit->GetTask() == nullptr
        || unit->GetTask()->GetManager() != mgr
        || (dynamic_cast<IFighterTask*>(task) == nullptr && !task->IsExternalControlled())) return false;
    if (unit->GetTask() != task) mgr->AssignTask(unit, task);
    return true;
}


CMilitaryScript::CMilitaryScript(CScriptManager* scr, CMilitaryManager* mgr)
		: ITaskModuleScript(scr, mgr)
{
	asIScriptEngine* engine = script->GetEngine();

	int r = engine->RegisterObjectType("SFightTask", sizeof(TaskF::SFightTask), asOBJ_VALUE | asOBJ_POD); ASSERT(r >= 0);
	static_assert(sizeof(TaskF::SFightTask::type) == sizeof(char), "IFighterTask::FightType is not uint8!");
	r = engine->RegisterObjectProperty("SFightTask", "uint8 type", asOFFSET(TaskF::SFightTask, type)); ASSERT(r >= 0);  // Task::FightType
	static_assert(sizeof(TaskF::SFightTask::check) == sizeof(char), "IFighterTask::FightType is not uint8!");
	r = engine->RegisterObjectProperty("SFightTask", "uint8 check", asOFFSET(TaskF::SFightTask, check)); ASSERT(r >= 0);  // Task::FightType
	static_assert(sizeof(TaskF::SFightTask::promote) == sizeof(char), "IFighterTask::FightType is not uint8!");
	r = engine->RegisterObjectProperty("SFightTask", "uint8 promote", asOFFSET(TaskF::SFightTask, promote)); ASSERT(r >= 0);  // Task::FightType
	r = engine->RegisterObjectProperty("SFightTask", "float power", asOFFSET(TaskF::SFightTask, power)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SFightTask", "CCircuitUnit@ vip", asOFFSET(TaskF::SFightTask, vip)); ASSERT(r >= 0);

	r = engine->RegisterObjectType("CMilitaryManager", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CMilitaryManager aiMilitaryMgr", manager); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "IUnitTask@+ DefaultMakeTask(CCircuitUnit@)", asMETHOD(CMilitaryManager, DefaultMakeTask), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "IUnitTask@+ TryMakeRangedTask(CCircuitUnit@)", asMETHOD(CMilitaryManager, TryMakeRangedTask), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "IUnitTask@+ Enqueue(const SFightTask& in)", asMETHODPR(CMilitaryManager, Enqueue, (const TaskF::SFightTask&), IFighterTask*), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "IUnitTask@+ EnqueueGather(const SFightTask& in, const AIFloat3& in, int)", asMETHOD(CMilitaryManager, EnqueueGather), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "bool SetGatherPower(IUnitTask@, float)", asMETHOD(CMilitaryManager, SetGatherPower), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "IUnitTask@+ EnqueueRetreat()", asMETHOD(CMilitaryManager, EnqueueRetreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "IUnitTask@+ EnqueueExternalControl(const string& in)", asMETHOD(CMilitaryManager, EnqueueExternalControl), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "bool TransferUnit(CCircuitUnit@, IUnitTask@)", asFUNCTION(CMilitaryManager_TransferUnit), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "void DefaultMakeDefence(int, const AIFloat3& in)", asMETHOD(CMilitaryManager, DefaultMakeDefence), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "AIFloat3 GetCombatFocusPos() const", asMETHOD(CMilitaryManager, GetCombatFocusPos), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "array<string>@ GetPorcChain(const string& in, bool) const", asFUNCTION(CMilitaryManager_GetPorcChain), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "bool SetPorcChain(const string& in, bool, const array<string>@+)", asFUNCTION(CMilitaryManager_SetPorcChain), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "uint GetGuardTaskNum() const", asMETHOD(CMilitaryManager, GetGuardTaskNum), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CMilitaryManager", "const float armyCost", asOFFSET(CMilitaryManager, armyCost)); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CMilitaryManager", "void SetAggressionDelta(float)", asMETHOD(CMilitaryManager, SetAggressionDelta), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CMilitaryManager", "float GetAggressionDelta() const", asMETHOD(CMilitaryManager, GetAggressionDelta), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CMilitaryManager", "void SetAutomaticAggression(float)", asMETHOD(CMilitaryManager, SetAutomaticAggression), asCALL_THISCALL); ASSERT(r >= 0);
    r = engine->RegisterObjectMethod("CMilitaryManager", "float GetAutomaticAggression() const", asMETHOD(CMilitaryManager, GetAutomaticAggression), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CMilitaryManager", "int porcMode", asOFFSET(CMilitaryManager, porcMode)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CMilitaryManager", "float porcBudgetMod", asOFFSET(CMilitaryManager, porcBudgetMod)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CMilitaryManager", "int porcAllyAA", asOFFSET(CMilitaryManager, porcAllyAA)); ASSERT(r >= 0);

	// NOTE: Config's "quota" scattered across CMilitaryManager, CEnemyManager, CThreatMap, CFactoryManager, CSetupManager
	r = engine->RegisterObjectType("SQuotaMilitary", 0, asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CMilitaryManager", "SQuotaMilitary quota", 0); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SQuotaMilitary", "uint scout", asOFFSET(CMilitaryManager, maxScouts)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SQuotaMilitary", "float attack", asOFFSET(CMilitaryManager, minAttackers)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SQuotaMilitary", "float attackWait", asOFFSET(CMilitaryManager, attackWaitSeconds)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SQuotaMilitary", "float attackScale", asOFFSET(CMilitaryManager, attackScale)); ASSERT(r >= 0);
	r = engine->RegisterObjectType("SRaidQuota", 0, asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SQuotaMilitary", "SRaidQuota raid", 0); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SRaidQuota", "float min", asOFFSET(CMilitaryManager::SRaidQuota, min), asOFFSET(CMilitaryManager, raid), false); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SRaidQuota", "float avg", asOFFSET(CMilitaryManager::SRaidQuota, avg), asOFFSET(CMilitaryManager, raid), false); ASSERT(r >= 0);
	// Alternative "quota" accessors:
//	r = engine->RegisterObjectProperty("CMilitaryManager", "uint quotaScout", asOFFSET(CMilitaryManager, maxScouts)); ASSERT(r >= 0);
//	r = engine->RegisterObjectProperty("CMilitaryManager", "float quotaAttack", asOFFSET(CMilitaryManager, minAttackers)); ASSERT(r >= 0);
//	r = engine->RegisterObjectProperty("CMilitaryManager", "float quotaRaidMin", asOFFSET(CMilitaryManager::SRaidQuota, min), asOFFSET(CMilitaryManager, raid), false); ASSERT(r >= 0);
//	r = engine->RegisterObjectProperty("CMilitaryManager", "float quotaRaidAvg", asOFFSET(CMilitaryManager::SRaidQuota, avg), asOFFSET(CMilitaryManager, raid), false); ASSERT(r >= 0);

	r = engine->RegisterObjectType("SResponseInfo", 0, asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResponseInfo", "float maxPercent", asOFFSET(CMilitaryManager::SRoleInfo, maxPerc)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResponseInfo", "float factor", asOFFSET(CMilitaryManager::SRoleInfo, factor)); ASSERT(r >= 0);
	r = engine->RegisterObjectType("SVsInfo", 0, asOBJ_REF | asOBJ_NOCOUNT); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SVsInfo", "Type role", asOFFSET(CMilitaryManager::SRoleInfo::SVsInfo, role)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SVsInfo", "float ratio", asOFFSET(CMilitaryManager::SRoleInfo::SVsInfo, ratio)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SVsInfo", "float importance", asOFFSET(CMilitaryManager::SRoleInfo::SVsInfo, importance)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("SResponseInfo", "SVsInfo@ GetVsInfo(Type) const", asFUNCTION(CMilitaryScript::GetVsInfo), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CMilitaryManager", "SResponseInfo@ GetResponseInfo(Type) const", asMETHOD(CMilitaryManager, GetRoleInfo), asCALL_THISCALL); ASSERT(r >= 0);
}

CMilitaryScript::~CMilitaryScript()
{
}

bool CMilitaryScript::Init()
{
	asIScriptModule* mod = script->GetEngine()->GetModule(CScriptManager::mainName.c_str());
	int r = mod->SetDefaultNamespace("Military"); ASSERT(r >= 0);
	InitModule(mod);
	militaryInfo.makeDefence = script->GetFunc(mod, "void AiMakeDefence(int, const AIFloat3& in)");
	militaryInfo.groundObjective = script->GetFunc(mod, "AIFloat3 AiGroundObjective(CCircuitUnit@, const AIFloat3& in)");
	return true;
}

AIFloat3 CMilitaryScript::GroundObjective(CCircuitUnit* unit, const AIFloat3& previous)
{
	// Optional, called on cohort objective completion, never per shooter.
	// Copy the value before returning the borrowed context to its pool.
	auto result=previous;
	if (!militaryInfo.groundObjective) return result;
	asIScriptContext* ctx=script->PrepareContext(militaryInfo.groundObjective);
	ctx->SetArgObject(0,unit);
	ctx->SetArgAddress(1,const_cast<AIFloat3*>(&previous));
	if (script->Exec(ctx)) result=*static_cast<AIFloat3*>(ctx->GetReturnObject());
	script->ReturnContext(ctx);
	return result;
}

void CMilitaryScript::MakeDefence(int cluster, const AIFloat3& pos)
{
	if (militaryInfo.makeDefence == nullptr) {
		static_cast<CMilitaryManager*>(manager)->DefaultMakeDefence(cluster, pos);
		return;
	}
	asIScriptContext* ctx = script->PrepareContext(militaryInfo.makeDefence);
	ctx->SetArgDWord(0, cluster);
	ctx->SetArgAddress(1, &const_cast<AIFloat3&>(pos));
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

CMilitaryManager::SRoleInfo::SVsInfo* CMilitaryScript::GetVsInfo(CMilitaryManager::SRoleInfo* info, CCircuitDef::RoleT vsType)
{
	for (CMilitaryManager::SRoleInfo::SVsInfo& vs : info->vs) {
		if (vsType == vs.role) {
			return &vs;
		}
	}
	return &info->vs.emplace_back(vsType, 0.f, 0.f);
}

} // namespace circuit
