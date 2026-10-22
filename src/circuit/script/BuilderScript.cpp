/*
 * BuilderScript.cpp
 *
 *  Created on: Apr 4, 2019
 *      Author: rlcevg
 */

#include "script/BuilderScript.h"
#include "script/ScriptManager.h"
#include "module/BuilderManager.h"
#include "util/ExtAS.h"
#include "angelscript/include/angelscript.h"

namespace circuit {

using namespace springai;

static void ConstructSResourceVal(SResource* mem, float m, float e)
{
	new(mem) SResource{m, e};
}

static IUnitTask* CBuilderManager_FindQueuedTask(CBuilderManager* mgr, CCircuitUnit* builder, int type)
{
	return mgr->FindQueuedTask(builder, static_cast<IBuilderTask::BuildType>(type));
}

static int CBuilderManager_GetQueuedBuildCount(
		CBuilderManager* manager, int type, const CCircuitDef* buildDef)
{
	return manager->GetQueuedBuildCount(
			static_cast<IBuilderTask::BuildType>(type), buildDef);
}

CBuilderScript::CBuilderScript(CScriptManager* scr, CBuilderManager* mgr)
		: ITaskModuleScript(scr, mgr)
{
	asIScriptEngine* engine = script->GetEngine();

	int r = engine->RegisterObjectType("SResource", sizeof(SResource), asOBJ_VALUE | asOBJ_POD | asGetTypeTraits<SResource>()); ASSERT(r >= 0);
	r = engine->RegisterObjectBehaviour("SResource", asBEHAVE_CONSTRUCT, "void f(float, float)", asFUNCTION(ConstructSResourceVal), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResource", "float metal", asOFFSET(SResource, metal)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SResource", "float energy", asOFFSET(SResource, energy)); ASSERT(r >= 0);

	r = engine->RegisterObjectType("SBuildTask", sizeof(TaskB::SBuildTask), asOBJ_VALUE | asOBJ_POD); ASSERT(r >= 0);
	static_assert(sizeof(TaskB::SBuildTask::type) == sizeof(char), "IBuilderTask::BuildType is not uint8!");
	r = engine->RegisterObjectProperty("SBuildTask", "uint8 type", asOFFSET(TaskB::SBuildTask, type)); ASSERT(r >= 0);  // Task::BuildType
	static_assert(sizeof(TaskB::SBuildTask::priority) == sizeof(char), "IBuilderTask::Priority is not uint8!");
	r = engine->RegisterObjectProperty("SBuildTask", "uint8 priority", asOFFSET(TaskB::SBuildTask, priority)); ASSERT(r >= 0);  // Task::Priority
	r = engine->RegisterObjectProperty("SBuildTask", "CCircuitDef@ buildDef", asOFFSET(TaskB::SBuildTask, buildDef)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "AIFloat3 position", asOFFSET(TaskB::SBuildTask, position)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "SResource cost", asOFFSET(TaskB::SBuildTask, cost)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "CCircuitDef@ reprDef", asOFFSET(TaskB::SBuildTask, ref.reprDef)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "CCircuitUnit@ target", asOFFSET(TaskB::SBuildTask, ref.target)); ASSERT(r >= 0);
//	r = engine->RegisterObjectProperty("SBuildTask", "IGridLink@ link", asOFFSET(TaskB::SBuildTask, ref.link)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "int pointId", asOFFSET(TaskB::SBuildTask, i.pointId)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "int spotId", asOFFSET(TaskB::SBuildTask, i.spotId)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "float shake", asOFFSET(TaskB::SBuildTask, f.shake)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "float radius", asOFFSET(TaskB::SBuildTask, f.radius)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "bool isPlop", asOFFSET(TaskB::SBuildTask, b.isPlop)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "bool isMetal", asOFFSET(TaskB::SBuildTask, b.isMetal)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "bool isActive", asOFFSET(TaskB::SBuildTask, isActive)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SBuildTask", "int timeout", asOFFSET(TaskB::SBuildTask, timeout)); ASSERT(r >= 0);

	r = engine->RegisterObjectType("SServBTask", sizeof(TaskB::SServBTask), asOBJ_VALUE | asOBJ_POD); ASSERT(r >= 0);
	static_assert(sizeof(TaskB::SServBTask::type) == sizeof(char), "IBuilderTask::BuildType is not uint8!");
	r = engine->RegisterObjectProperty("SServBTask", "uint8 type", asOFFSET(TaskB::SServBTask, type)); ASSERT(r >= 0);  // Task::BuildType
	static_assert(sizeof(TaskB::SServBTask::priority) == sizeof(char), "IBuilderTask::Priority is not uint8!");
	r = engine->RegisterObjectProperty("SServBTask", "uint8 priority", asOFFSET(TaskB::SServBTask, priority)); ASSERT(r >= 0);  // Task::Priority
	r = engine->RegisterObjectProperty("SServBTask", "AIFloat3 position", asOFFSET(TaskB::SServBTask, position)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SServBTask", "CCircuitUnit@ target", asOFFSET(TaskB::SServBTask, target)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SServBTask", "float powerMod", asOFFSET(TaskB::SServBTask, powerMod)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SServBTask", "bool isInterrupt", asOFFSET(TaskB::SServBTask, isInterrupt)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("SServBTask", "int timeout", asOFFSET(TaskB::SServBTask, timeout)); ASSERT(r >= 0);

	r = engine->RegisterObjectType("CBuilderManager", 0, asOBJ_REF | asOBJ_NOHANDLE); ASSERT(r >= 0);
	r = engine->RegisterGlobalProperty("CBuilderManager aiBuilderMgr", manager); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "void ClearBuildRadii()", asMETHOD(CBuilderManager, ClearBuildRadii), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "void SetBuildRadius(const CCircuitDef@, const AIFloat3& in, float)", asMETHOD(CBuilderManager, SetBuildRadius), asCALL_THISCALL); ASSERT(r >= 0);
	// D-290: script-owned reclaim protection (TECH: energy storage); empty by default
	r = engine->RegisterObjectMethod("CBuilderManager", "void SetReclaimProtected(const CCircuitDef@, bool)", asMETHOD(CBuilderManager, SetReclaimProtected), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "bool IsReclaimProtected(const CCircuitDef@) const", asMETHOD(CBuilderManager, IsReclaimProtected), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "void ClearReclaimProtected()", asMETHOD(CBuilderManager, ClearReclaimProtected), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "float GetRecoveryMetal(CCircuitUnit@, float)", asMETHOD(CBuilderManager, GetRecoveryMetal), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ FindRecoveryTask(CCircuitUnit@, int, float, const CCircuitDef@, int groupLimit = 1, bool highestValue = false, float combatClearance = 0)", asMETHOD(CBuilderManager, FindRecoveryTask), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ DefaultMakeTask(CCircuitUnit@)", asMETHOD(CBuilderManager, DefaultMakeTask), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "void AbortTask(IUnitTask@)", asMETHODPR(CBuilderManager, AbortTask, (IUnitTask*), void), asCALL_THISCALL); ASSERT(r >= 0);  // D-108: a builder handed a dedicated role drops its other job
	r = engine->RegisterObjectMethod("CBuilderManager", "void AssignTask(CCircuitUnit@, IUnitTask@)", asMETHODPR(CBuilderManager, AssignTask, (CCircuitUnit*, IUnitTask*), void), asCALL_THISCALL); ASSERT(r >= 0);  // D-112: one unit onto a task (it leaves its old task, which carries on without it)
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ Enqueue(const SBuildTask& in)", asMETHODPR(CBuilderManager, Enqueue, (const TaskB::SBuildTask&), IBuilderTask*), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ EnqueueLayout(const SBuildTask& in, const string& in, CCircuitUnit@)", asMETHOD(CBuilderManager, EnqueueLayout), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ EnqueueFactoryNano(const SBuildTask& in, CCircuitUnit@)", asMETHOD(CBuilderManager, EnqueueFactoryNano), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ Enqueue(const SServBTask& in)", asMETHODPR(CBuilderManager, Enqueue, (const TaskB::SServBTask&), IUnitTask*), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ FindMatchingGuard(CCircuitUnit@, const SServBTask& in)", asMETHOD(CBuilderManager, FindMatchingGuard), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ EnqueueRetreat()", asMETHOD(CBuilderManager, EnqueueRetreat), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "uint GetWorkerCount() const", asMETHOD(CBuilderManager, GetWorkerCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "float GetBuildPowerNear(const AIFloat3& in, float) const", asMETHOD(CBuilderManager, GetBuildPowerNear), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "float GetStaticBuildPowerNear(const AIFloat3& in, float) const", asMETHOD(CBuilderManager, GetStaticBuildPowerNear), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "int GetQueuedBuildCount(int, const CCircuitDef@) const", asFUNCTION(CBuilderManager_GetQueuedBuildCount), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CBuilderManager", "int dangerHysteresis", asOFFSET(CBuilderManager, dangerHysteresis)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CBuilderManager", "bool experimentalBuild", asOFFSET(CBuilderManager, experimentalBuild)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CBuilderManager", "bool recoverConstruction", asOFFSET(CBuilderManager, recoverConstruction)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CBuilderManager", "int constructionRetrySeconds", asOFFSET(CBuilderManager, constructionRetrySeconds)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CBuilderManager", "int constructionReleaseSeconds", asOFFSET(CBuilderManager, constructionReleaseSeconds)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CBuilderManager", "bool experimentalAirDirect", asOFFSET(CBuilderManager, experimentalAirDirect)); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "CCircuitUnit@ FindReclaimTargetFor(CCircuitUnit@)", asMETHOD(CBuilderManager, FindReclaimTargetFor), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "CCircuitUnit@ FindUnfinishedFor(CCircuitUnit@, const CCircuitDef@)", asMETHOD(CBuilderManager, FindUnfinishedFor), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "int GetUnfinishedCount(const CCircuitDef@) const", asMETHOD(CBuilderManager, GetUnfinishedCount), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "CCircuitUnit@ FindUnfinishedNear(const AIFloat3& in, float, const CCircuitDef@)", asMETHOD(CBuilderManager, FindUnfinishedNear), asCALL_THISCALL); ASSERT(r >= 0);
	r = engine->RegisterObjectMethod("CBuilderManager", "CCircuitUnit@ FindProducedNear(const AIFloat3& in, float)", asMETHOD(CBuilderManager, FindProducedNear), asCALL_THISCALL); ASSERT(r >= 0);  // D-119
	r = engine->RegisterObjectMethod("CBuilderManager", "int CountUnfinishedNear(const AIFloat3& in, float, float, const CCircuitDef@)", asMETHOD(CBuilderManager, CountUnfinishedNear), asCALL_THISCALL); ASSERT(r >= 0);  // D-098
	r = engine->RegisterObjectMethod("CBuilderManager", "float GetBuildPowerNearExcept(const AIFloat3& in, float, const CCircuitDef@, const CCircuitDef@, const CCircuitUnit@) const", asMETHOD(CBuilderManager, GetBuildPowerNearExcept), asCALL_THISCALL); ASSERT(r >= 0);  // D-105
	r = engine->RegisterObjectMethod("CBuilderManager", "CCircuitUnit@ FindOwnNear(const AIFloat3& in, float, const CCircuitDef@)", asMETHOD(CBuilderManager, FindOwnNear), asCALL_THISCALL); ASSERT(r >= 0);  // D-077
	r = engine->RegisterObjectMethod("CBuilderManager", "int TurretsOnReclaim(int, float, bool, bool preserveReclaimPriority = false)", asMETHOD(CBuilderManager, TurretsOnReclaim), asCALL_THISCALL); ASSERT(r >= 0);  // D-078
	r = engine->RegisterObjectProperty("CBuilderManager", "float experimentalDirectRange", asOFFSET(CBuilderManager, experimentalDirectRange)); ASSERT(r >= 0);
	r = engine->RegisterObjectProperty("CBuilderManager", "float experimentalSearchRadius", asOFFSET(CBuilderManager, experimentalSearchRadius)); ASSERT(r >= 0);
    r=engine->RegisterObjectMethod("CBuilderManager","bool SetCommanderCombatOption(const string &in, float)",asMETHOD(CBuilderManager,SetCommanderCombatOption),asCALL_THISCALL); ASSERT(r>=0);
    r=engine->RegisterObjectMethod("CBuilderManager","float GetCommanderEnergyReserve() const",asMETHOD(CBuilderManager,GetCommanderEnergyReserve),asCALL_THISCALL); ASSERT(r>=0);
    r=engine->RegisterObjectMethod("CBuilderManager","float GetCommanderEnergyDeficit() const",asMETHOD(CBuilderManager,GetCommanderEnergyDeficit),asCALL_THISCALL); ASSERT(r>=0);
    r=engine->RegisterObjectMethod("CBuilderManager","int GetCommanderOperation() const",asMETHOD(CBuilderManager,GetCommanderOperation),asCALL_THISCALL); ASSERT(r>=0);
    r=engine->RegisterObjectMethod("CBuilderManager","IUnitTask@+ CommanderFrontWork(CCircuitUnit@, int, CCircuitDef@, float)",asMETHOD(CBuilderManager,CommanderFrontWork),asCALL_THISCALL); ASSERT(r>=0);
	r = engine->RegisterObjectMethod("CBuilderManager", "IUnitTask@+ FindQueuedTask(CCircuitUnit@, int type)", asFUNCTION(CBuilderManager_FindQueuedTask), asCALL_CDECL_OBJFIRST); ASSERT(r >= 0);

}

CBuilderScript::~CBuilderScript()
{
}

bool CBuilderScript::Init()
{
	asIScriptModule* mod = script->GetEngine()->GetModule(CScriptManager::mainName.c_str());
	int r = mod->SetDefaultNamespace("Builder"); ASSERT(r >= 0);
	InitModule(mod);
	builderInfo.taskAssigned = script->GetFunc(mod, "void AiTaskAssigned(CCircuitUnit@)");
	return true;
}

void CBuilderScript::TaskAssigned(CCircuitUnit* unit)
{
	if (builderInfo.taskAssigned == nullptr) {
		return;
	}
	asIScriptContext* ctx = script->PrepareContext(builderInfo.taskAssigned);
	ctx->SetArgObject(0, unit);
	script->Exec(ctx);
	script->ReturnContext(ctx);
}

} // namespace circuit
