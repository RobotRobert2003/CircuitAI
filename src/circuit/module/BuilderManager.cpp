/*
 * BuilderManager.cpp
 *
 *  Created on: Dec 1, 2014
 *      Author: rlcevg
 */

#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/MilitaryManager.h"
#include "module/FactoryManager.h"
#include "map/InfluenceMap.h"
#include "map/ThreatMap.h"
#include "resource/MetalManager.h"
#include "scheduler/Scheduler.h"
#include "script/BuilderScript.h"
#include "setup/SetupManager.h"
#include "terrain/TerrainManager.h"
#include "terrain/path/PathFinder.h"
#include "terrain/path/QueryCostMap.h"
#include "task/NilTask.h"
#include "task/IdleTask.h"
#include "task/RetreatTask.h"
#include "task/builder/GenericTask.h"
#include "task/builder/WaitTask.h"
#include "task/builder/FactoryTask.h"
#include "task/builder/NanoTask.h"
#include "task/builder/StoreTask.h"
#include "task/builder/PylonTask.h"
#include "task/builder/EnergyTask.h"
#include "task/builder/GeoTask.h"
#include "task/builder/DefenceTask.h"
#include "task/builder/BunkerTask.h"
#include "task/builder/BigGunTask.h"
#include "task/builder/RadarTask.h"
#include "task/builder/SonarTask.h"
#include "task/builder/ConvertTask.h"
#include "task/builder/MexTask.h"
#include "task/builder/MexUpTask.h"
#include "task/builder/TerraformTask.h"
#include "task/builder/RepairTask.h"
#include "task/builder/ReclaimTask.h"
#include "task/builder/ResurrectTask.h"
#include "task/builder/PatrolTask.h"
#include "task/builder/GuardTask.h"
#include "task/builder/CombatTask.h"
#include "task/builder/CommanderTask.h"
#include "module/CommanderControl.h"
#include "task/builder/BuildChain.h"
#include "CircuitAI.h"
#include "unit/ally/AllyTeam.h"
#include "util/Utils.h"
#include "util/Profiler.h"
#include "util/GameAttribute.h"
#include "json/json.h"

#include "spring/SpringCallback.h"
#include "spring/ResurrectionClaim.h"

#include "Log.h"
#include "Feature.h"
#include "FeatureDef.h"

#include <algorithm>
#include <chrono>
#include <limits>
#include <cmath>
#include <sstream>
#include <cstring>

namespace circuit {

using namespace springai;

CBuilderManager::CBuilderManager(CCircuitAI* circuit)
		: ITaskModule(circuit, new CBuilderScript(circuit->GetScriptManager(), this))
		, assistCount(0)
		, guardCount(0)
		, buildTasksCount(0)
		, buildPower(.0f)
		, dangerHysteresis(MAX_TRAVEL_SEC * FRAMES_PER_SEC)
{
	circuit->GetScheduler()->RunOnInit(CScheduler::GameJob(&CBuilderManager::Init, this));

	buildTasks.resize(static_cast<IBuilderTask::BT>(IBuilderTask::BuildType::_SIZE_));

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	for (auto mtId : workerMobileTypes) {
		for (auto& area : terrainMgr->GetMobileTypeById(mtId)->area) {
			buildAreas[&area] = std::map<CCircuitDef*, int>();
		}
	}
	buildAreas[nullptr] = std::map<CCircuitDef*, int>();  // air
}

CBuilderManager::~CBuilderManager()
{
	for (auto& kv1 : buildChains) {
		for (auto& kv2 : kv1.second) {
			delete kv2.second;
		}
	}
}

void CBuilderManager::InitHandlers()
{
	/*
	 * worker handlers
	 */
	auto workerCreatedHandler = [this](CCircuitUnit* unit, CCircuitUnit* builder) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			nilTask->AssignTo(unit);
			this->circuit->AddActionUnit(unit);
		}
		CEconomyManager* economyMgr = this->circuit->GetEconomyManager();
		if (unit->GetUnit()->IsBeingBuilt() && !economyMgr->IsEnergyStalling() && !economyMgr->IsMetalEmpty()) {
			Enqueue(TaskB::Repair(IBuilderTask::Priority::NORMAL, unit));
		}
	};
	auto workerFinishedHandler = [this](CCircuitUnit* unit) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			this->circuit->AddActionUnit(unit);
		}
		nilTask->RemoveAssignee(unit);
		idleTask->AssignTo(unit);

		++buildAreas[unit->GetArea()][unit->GetCircuitDef()];

		AddBuildPower(unit);
		CMilitaryManager* militaryMgr = this->circuit->GetMilitaryManager();
		militaryMgr->AddResponse(unit);
		workers.insert(unit);
		if (unit->GetCircuitDef()->IsAbleToAssist()) {
			++assistCount;
		}

		AddBuildList(unit, 0);

		UnitAdded(unit, UseAs::BUILDER);

		if (!unit->GetCircuitDef()->IsAttacker()
			&& !unit->GetCircuitDef()->IsAbleToFly()
			&& (militaryMgr->GetTasks(IFighterTask::FightType::GUARD).size() < militaryMgr->GetGuardTaskNum()))
		{
			militaryMgr->Enqueue(TaskF::Guard(unit));
		}
	};
	auto workerIdleHandler = [this](CCircuitUnit* unit) {
		// FIXME: Avoid instant task reassignment, its only valid on build order fail.
		//        Can cause idle builder, but Watchdog should catch it eventually.
		//        Unfortunately can't use EVENT_COMMAND_FINISHED because there is no unique commandId like unitId
		if (this->circuit->GetLastFrame() > unit->GetTaskFrame()/* + FRAMES_PER_SEC*/) {
			unit->GetTask()->OnUnitIdle(unit);
		}
	};
	auto workerDamagedHandler = [](CCircuitUnit* unit, CEnemyInfo* attacker) {
		unit->GetTask()->OnUnitDamaged(unit, attacker);
	};
	auto workerDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		IUnitTask* task = unit->GetTask();
		task->OnUnitDestroyed(unit, attacker);  // can change task
		unit->GetTask()->RemoveAssignee(unit);  // Remove unit from IdleTask

		if (task->GetType() == IUnitTask::Type::NIL) {
			return;
		}
		--buildAreas[unit->GetArea()][unit->GetCircuitDef()];

		DelBuildPower(unit);
		CMilitaryManager* militaryMgr = this->circuit->GetMilitaryManager();
		militaryMgr->DelResponse(unit);

		workers.erase(unit);
		costQueries.erase(unit);
		dangerTime.erase(unit);
		if (unit->GetCircuitDef()->IsAbleToAssist()) {
			--assistCount;
		}

		RemoveBuildList(unit, 0);

		UnitRemoved(unit, UseAs::BUILDER);
	};

	/*
	 * resurrect-bots
	 */
	auto rezzFinishedHandler = [this](CCircuitUnit* unit) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			this->circuit->AddActionUnit(unit);
		}
		nilTask->RemoveAssignee(unit);
		idleTask->AssignTo(unit);

		CMilitaryManager* militaryMgr = this->circuit->GetMilitaryManager();
		militaryMgr->AddResponse(unit);

		workers.insert(unit);

		UnitAdded(unit, UseAs::REZZER);
	};
	auto rezzDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		IUnitTask* task = unit->GetTask();
		task->OnUnitDestroyed(unit, attacker);  // can change task
		unit->GetTask()->RemoveAssignee(unit);  // Remove unit from IdleTask

		if (task->GetType() == IUnitTask::Type::NIL) {
			return;
		}
		CMilitaryManager* militaryMgr = this->circuit->GetMilitaryManager();
		militaryMgr->DelResponse(unit);

		workers.erase(unit);
		costQueries.erase(unit);
		dangerTime.erase(unit);

		UnitRemoved(unit, UseAs::REZZER);
	};

	/*
	 * building handlers
	 */
	auto buildingDamagedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		if (!unit->IsAttrNoRepair() && !IsReclaimUnit(unit)) {
			Enqueue(TaskB::Repair(IBuilderTask::Priority::HIGH, unit));
		}
	};
	auto buildingDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		int frame = this->circuit->GetLastFrame();
		int facing = unit->GetUnit()->GetBuildingFacing();
		this->circuit->GetTerrainManager()->DelBlocker(unit->GetCircuitDef(), unit->GetPos(frame), facing, true);
	};

	/*
	 * mex handlers;
	 */
	auto mexDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		const AIFloat3& pos = unit->GetPos(this->circuit->GetLastFrame());
		CCircuitDef* mexDef = unit->GetCircuitDef();
		const int facing = unit->GetUnit()->GetBuildingFacing();
		this->circuit->GetTerrainManager()->DelBlocker(mexDef, pos, facing, true);
		if (this->circuit->GetEconomyManager()->IsMetalMap()) return;
		int index = this->circuit->GetMetalManager()->FindNearestSpot(pos);
		if ((index < 0) || (reclaimUnits.find(unit) != reclaimUnits.end())) {
			return;
		}

		// check stacked mexes
		const auto& unitIds = this->circuit->GetCallback()->GetFriendlyUnitIdsIn(pos, SQUARE_SIZE, false);
		for (ICoreUnit::Id unitId : unitIds) {
			CCircuitUnit* mex = this->circuit->GetTeamUnit(unitId);
			// FIXME: How to check !unit->IsDead? health can be 0.999 for unit being built and dissipated when this event hits
			if ((mex != nullptr) && mex->GetCircuitDef()->IsMex()
				&& (mex->GetUnit()->GetHealth() > 0.f) && !mex->GetUnit()->IsBeingBuilt())
			{
				return;
			}
		}
		this->circuit->GetMetalManager()->SetOpenSpot(index, true);
		this->circuit->GetEconomyManager()->SetOpenMexSpot(index, true);
	};

	/*
	 * heavy handlers
	 */
//	auto heavyCreatedHandler = [this](CCircuitUnit* unit, CCircuitUnit* builder) {
//		CEconomyManager* economyMgr = this->circuit->GetEconomyManager();
//		if (economyMgr->GetAvgMetalIncome() * economyMgr->GetEcoFactor() > 32.0f) {
//			TRY_UNIT(this->circuit, unit,
//				unit->CmdPriority(2);
//			)
////			EnqueueRepair(IBuilderTask::Priority::LOW, unit);
//		}
//	};

	const Json::Value& root = circuit->GetSetupManager()->GetConfig();
	const Json::Value& retreat = root["retreat"]["builder"];
	const float minRet = retreat.get((unsigned)0, 0.8f).asFloat();
	const float maxRet = retreat.get((unsigned)1, 0.8f).asFloat();
	const float builderRet = (float)rand() / RAND_MAX * (maxRet - minRet) + minRet;
	const float retMod = retreat.get((unsigned)2, 1.0f).asFloat();
	const float goalBuildMod = root["economy"].get("build_mod", 320.f).asFloat();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
		CCircuitDef::Id unitDefId = cdef.GetId();
		if (cdef.IsMobile()) {
			if (cdef.GetDef()->IsBuilder()) {
				if (cdef.IsBuilder()) {
					createdHandler[unitDefId]   = workerCreatedHandler;
					finishedHandler[unitDefId]  = workerFinishedHandler;
					idleHandler[unitDefId]      = workerIdleHandler;
					damagedHandler[unitDefId]   = workerDamagedHandler;
					destroyedHandler[unitDefId] = workerDestroyedHandler;

					int mtId = terrainMgr->GetMobileTypeId(unitDefId);
					if (mtId >= 0) {  // not air
						workerMobileTypes.insert(mtId);
					}
					workerDefs[&cdef] = SWorkExt{false, false};
				} else if (cdef.IsAbleToResurrect()) {
					createdHandler[unitDefId]   = workerCreatedHandler;
					finishedHandler[unitDefId]  = rezzFinishedHandler;
					idleHandler[unitDefId]      = workerIdleHandler;
					damagedHandler[unitDefId]   = workerDamagedHandler;
					destroyedHandler[unitDefId] = rezzDestroyedHandler;
				}

				cdef.SetRetreat((cdef.GetRetreat() < 0.f) ? builderRet : cdef.GetRetreat() * retMod);
//			} else if (cdef->GetCostM() >= 1000.f) {
//				createdHandler[unitDefId] = heavyCreatedHandler;
			}
		} else {
			damagedHandler[unitDefId] = buildingDamagedHandler;
			if (cdef.IsMex()) {
				destroyedHandler[unitDefId] = mexDestroyedHandler;
			} else {
				destroyedHandler[unitDefId] = buildingDestroyedHandler;
			}
		}

		if (cdef.GetGoalBuildMod() < 0.f) {
			cdef.SetGoalBuildMod(goalBuildMod);
		}
	}

	ReadConfig();
}

void CBuilderManager::ReadConfig()
{
	const Json::Value& root = circuit->GetSetupManager()->GetConfig();
	const std::string& cfgName = circuit->GetSetupManager()->GetConfigName();

	const Json::Value& econ = root["economy"];
	terraDef = circuit->GetCircuitDef(econ.get("terra", "").asCString());
	if (terraDef == nullptr) {
		terraDef = circuit->GetEconomyManager()->GetSideInfo().defaultDef;
	}
	goalExecTime = econ.get("goal_exec", 16.f).asFloat();

	const Json::Value& cond = root["porcupine"]["superweapon"]["condition"];
	super.minIncome = cond.get((unsigned)0, 50.f).asFloat();
	super.maxTime = cond.get((unsigned)1, 300.f).asFloat();

	SBuildInfo::DirName& dirNames = SBuildInfo::GetDirNames();
	SBuildInfo::CondName& condNames = SBuildInfo::GetCondNames();
	SBuildInfo::PrioName& prioNames = SBuildInfo::GetPrioNames();
	IBuilderTask::BuildName& buildNames = IBuilderTask::GetBuildNames();
	const Json::Value& build = root["build_chain"];
	for (const std::string& catName : build.getMemberNames()) {
		auto it = buildNames.find(catName);
		if (it == buildNames.end()) {
			circuit->LOG("CONFIG %s: has unknown category '%s'", cfgName.c_str(), catName.c_str());
			continue;
		}

		std::unordered_map<CCircuitDef*, SBuildChain*>& defMap = buildChains[static_cast<IBuilderTask::BT>(it->second)];
		const Json::Value& catChain = build[catName];
		for (const std::string& defName : catChain.getMemberNames()) {
			CCircuitDef* cdef = circuit->GetCircuitDef(defName.c_str());
			if (cdef == nullptr) {
				circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), defName.c_str());
				continue;
			}

			SBuildChain bc;
			const Json::Value& buildQueue = catChain[defName];
			bc.isPylon = buildQueue.get("pylon", false).asBool();
			bc.isPorc = buildQueue.get("porc", false).asBool();
			bc.isTerra = buildQueue.get("terra", false).asBool();

			const Json::Value& engy = buildQueue["energy"];
			bc.energy = engy.get(unsigned(0), -1.f).asFloat();
			bc.isMexEngy = engy[1].isString();

			const Json::Value& hub = buildQueue["hub"];
			bc.hub.reserve(hub.size());
			for (const Json::Value& que : hub) {
				std::vector<SBuildInfo> queue;
				queue.reserve(que.size());
				for (const Json::Value& part : que) {
					SBuildInfo bi;

					const std::string& partName = part.get("unit", "").asString();
					bi.cdef = circuit->GetCircuitDef(partName.c_str());
					if (bi.cdef == nullptr) {
						circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), partName.c_str());
						continue;
					}

					const std::string& cat = part.get("category", "").asString();
					auto it = buildNames.find(cat);
					if (it == buildNames.end()) {
						circuit->LOG("CONFIG %s: has unknown category '%s'", cfgName.c_str(), cat.c_str());
						continue;
					}
					bi.buildType = it->second;

					UnitDef* unitDef = cdef->GetDef();
					bi.offset = ZeroVector;
					bi.direction = SBuildInfo::Direction::NONE;
					const Json::Value& off = part["offset"];
					if (off.isArray()) {
						bi.offset = AIFloat3(off.get((unsigned)0, 0.f).asFloat(), 0.f, off.get((unsigned)1, 0.f).asFloat());
						if (bi.offset.x < -1e-3f) {
							bi.offset.x -= unitDef->GetXSize() * SQUARE_SIZE / 2;
						} else if (bi.offset.x > 1e-3f) {
							bi.offset.x += unitDef->GetXSize() * SQUARE_SIZE / 2;
						}
						if (bi.offset.z < -1e-3f) {
							bi.offset.z -= unitDef->GetZSize() * SQUARE_SIZE / 2;
						} else if (bi.offset.z > 1e-3f) {
							bi.offset.z += unitDef->GetZSize() * SQUARE_SIZE / 2;
						}
					} else if (off.isObject() && !off.empty()) {
						float delta = 0.f;
						std::string dir = off.getMemberNames().front();
						auto it = dirNames.find(dir);
						if (it != dirNames.end()) {
							bi.direction = it->second;
							delta = off[dir].asFloat();
						}
						switch (bi.direction) {
							case DIRECTION(LEFT): {
								bi.offset.x = delta + unitDef->GetXSize() * SQUARE_SIZE / 2;
							} break;
							case DIRECTION(RIGHT): {
								bi.offset.x = -(delta + unitDef->GetXSize() * SQUARE_SIZE / 2);
							} break;
							case DIRECTION(FRONT): {
								bi.offset.z = delta + unitDef->GetZSize() * SQUARE_SIZE / 2;
							} break;
							case DIRECTION(BACK): {
								bi.offset.z = -(delta + unitDef->GetZSize() * SQUARE_SIZE / 2);
							} break;
							default: break;
						}
					}

					bi.condition = SBuildInfo::Condition::ALWAYS;
					const Json::Value& condition = part["condition"];
					if (!condition.isNull()) {
						std::string cond = condition.getMemberNames().front();
						auto it = condNames.find(cond);
						if (it != condNames.end()) {
							bi.condition = it->second;
							const Json::Value& value = condition[cond];
							if (value.isBool()) {
								bi.value = value.asBool() ? 1.f : -1.f;
							} else {
								bi.value = condition.get(cond, 1.f).asFloat();
							}
						}
					}

					{
						const std::string& prio = part.get("priority", "").asString();
						auto it = prioNames.find(prio);
						bi.priority = (it != prioNames.end()) ? it->second : IBuilderTask::Priority::NORMAL;
					}

					queue.push_back(bi);
				}
				bc.hub.push_back(queue);
			}

			defMap[cdef] = new SBuildChain(bc);
		}
	}
}

void CBuilderManager::Init()
{
	CSetupManager::StartFunc subinit = [this](const AIFloat3& pos) {
		CScheduler* scheduler = circuit->GetScheduler().get();
		const int interval = 8;
		const int offset = circuit->GetSkirmishAIId() % interval;
		scheduler->RunJobEvery(CScheduler::GameJob(&CBuilderManager::UpdateIdle, this), interval, offset + 0);
		scheduler->RunJobEvery(CScheduler::GameJob(&CBuilderManager::Update, this), 1/*interval*/, offset + 1);

		scheduler->RunJobEvery(CScheduler::GameJob(&CBuilderManager::Watchdog, this),
								FRAMES_PER_SEC * 5,
								circuit->GetSkirmishAIId() * WATCHDOG_COUNT + 10);
	};

	circuit->GetSetupManager()->ExecOnFindStart(subinit);
}

int CBuilderManager::UnitCreated(CCircuitUnit* unit, CCircuitUnit* builder)
{
	// D-108 crash: a new unit may be allocated where a freed one's stale
	// unfinishedUnits key points; that entry (and its dead task) is not this unit's
	EraseUnfinishedUnit(unit);

	auto search = createdHandler.find(unit->GetCircuitDef()->GetId());
	if (search != createdHandler.end()) {
		search->second(unit, builder);
	}

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	if (builder == nullptr) {
		if (!unit->GetCircuitDef()->IsMobile() && !terrainMgr->ResignAllyBuilding(unit)) {
			// enemy unit captured
			const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
			terrainMgr->AddBlocker(unit->GetCircuitDef(), pos, unit->GetUnit()->GetBuildingFacing(), true);
		}
		return 0; //signaling: OK
	}

	IUnitTask* task = builder->GetTask();
	if (task == nullptr) {
		return 0; //signaling: OK
	} else if (task->GetType() != IUnitTask::Type::BUILDER) {
		if ((task->GetType() == IUnitTask::Type::PLAYER) && !unit->GetCircuitDef()->IsMobile()) {
			// payer resurrected building
			const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
			terrainMgr->AddBlocker(unit->GetCircuitDef(), pos, unit->GetUnit()->GetBuildingFacing(), true);
		}
		return 0; //signaling: OK
	}

	IBuilderTask* taskB = static_cast<IBuilderTask*>(task);
	if (unit->GetUnit()->IsBeingBuilt()) {
		// NOTE: Try to cope with wrong event order, when different units created within same task.
		//       Real example: unit starts building, but hlt kills structure right away. UnitDestroyed invoked and new task assigned to unit.
		//       But for some engine-bugged reason unit is not idle and retries same building. UnitCreated invoked for new task with wrong target.
		//       Next workaround unfortunately doesn't mark bugged building on blocking map.
		if ((taskB->GetTarget() == nullptr) && (taskB->GetBuildDef() != nullptr) &&
			(*taskB->GetBuildDef() == *unit->GetCircuitDef()) && taskB->IsEqualBuildPos(unit))
		{
#if 0
			AIFloat3 bp = taskB->GetBuildPos();
			circuit->GetDrawer()->AddPoint(bp, "bp");
			AIFloat3 up = unit->GetPos(circuit->GetLastFrame());
			circuit->GetDrawer()->AddPoint(up, "up");
			circuit->LOG("%s | bp = %f, %f | up = %f, %f", unit->GetCircuitDef()->GetDef()->GetName(), bp.x, bp.z, up.x, up.z);
#endif
			taskB->UpdateTarget(unit);
			MarkUnfinishedUnit(unit, taskB);
		} else if (IsExperimentalBuild()) {
			// D-074: the builder's task was swapped between the order and the
			// frame; the frame belongs to the task that ordered it (same def,
			// same site), never to a reclaim (played: the commander reclaimed
			// the lab it had just started).
			IBuilderTask* owner = nullptr;
			for (const auto& byType : buildTasks) {
				for (IBuilderTask* t : byType) {
					if ((t != nullptr) && !t->IsDead() && (t->GetTarget() == nullptr) && (t->GetBuildDef() != nullptr)
						&& (*t->GetBuildDef() == *unit->GetCircuitDef()) && t->IsEqualBuildPos(unit))
					{
						owner = t;
						break;
					}
				}
				if (owner != nullptr) {
					break;
				}
			}
			if (owner != nullptr) {
				owner->UpdateTarget(unit);
				MarkUnfinishedUnit(unit, owner);
				circuit->LOG("EXP: frame: %s(%i) adopted by the task that ordered it", unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId());
			} else {
				circuit->LOG("EXP: frame: %s(%i) has no task of its own; left standing for the sequence to assist",
						unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId());
			}
		} else {
			// reclaim lost unit; D-290: a reclaim-protected frame is finished instead
			IBuilderTask* recover = Enqueue(TaskB::Reclaim(IBuilderTask::Priority::HIGH, unit));
			if (recover == nullptr) {
				recover = Enqueue(TaskB::Repair(IBuilderTask::Priority::HIGH, unit));
			}
			if (recover != nullptr) {
				AssignTask(builder, recover);
			}
		}
	} else {
		if ((taskB->GetBuildType() == IBuilderTask::BuildType::RESURRECT) && !unit->GetCircuitDef()->IsMobile()) {
			// FIXME: Ideally this would go into CBResurrectTask::Finish,
			//        but it has no idea about unit being resurrected.
			const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
			terrainMgr->AddBlocker(unit->GetCircuitDef(), pos, unit->GetUnit()->GetBuildingFacing(), true);
		}
		DoneTask(taskB);
	}

	return 0; //signaling: OK
}

int CBuilderManager::UnitFinished(CCircuitUnit* unit)
{
	// Experimental AIR can have a second construction task adopt the same
	// standing frame. Only one is in unfinishedUnits; the other must not keep
	// recruiting workers to repair an already completed structure. Snapshot
	// before dequeuing, and finish the registered owner exactly once below.
	std::vector<IBuilderTask*> staleOwners;
	if (IsExperimentalAirDirect()) {
		for (const auto& byType : buildTasks) for (IBuilderTask* task : byType) {
			if (!task->IsDead() && task->GetBuildType() <= IBuilderTask::BuildType::MEXUP
				&& task->GetTarget() == unit) staleOwners.push_back(task);
		}
	}
	auto iter = unfinishedUnits.find(unit);
	if (iter != unfinishedUnits.end()) {
		DoneTask(iter->second);
	}
	for (IBuilderTask* task : staleOwners) {
		if (!task->IsDead()) {
			circuit->LOG("EXP: retire duplicate construction owner for completed frame %i", unit->GetId());
			AbortTask(task);
		}
	}
	// D-108 crash: the entry goes with the frame even when its task was already
	// dequeued (DequeueTask erases by the task's current target only)
	EraseUnfinishedUnit(unit);
	auto itre = repairUnits.find(unit->GetId());
	if (itre != repairUnits.end()) {
		DoneTask(itre->second);
	}
	auto itcl = reclaimUnits.find(unit);
	if ((itcl != reclaimUnits.end()) && (itcl->second != nullptr)) {
		AbortTask(itcl->second);
	}

	auto search = finishedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != finishedHandler.end()) {
		search->second(unit);
	}

	return 0; //signaling: OK
}

int CBuilderManager::UnitIdle(CCircuitUnit* unit)
{
	auto search = idleHandler.find(unit->GetCircuitDef()->GetId());
	if (search != idleHandler.end()) {
		search->second(unit);
	}

	return 0; //signaling: OK
}

int CBuilderManager::UnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
    if(circuit->GetCommanderControl()) circuit->GetCommanderControl()->Damaged(unit);
	auto search = damagedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != damagedHandler.end()) {
		search->second(unit, attacker);
	}

	return 0; //signaling: OK
}

int CBuilderManager::UnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	auto iter = unfinishedUnits.find(unit);
	if (iter != unfinishedUnits.end()) {
		AbortTask(iter->second);
	}
	// D-108 crash: a dead unit never stays a key; the scans over unfinishedUnits
	// (FindUnfinishedFor, FindUnfinishedNear, CountUnfinishedNear,
	// GetUnfinishedCount) dereference it, and the unit is freed after this event
	EraseUnfinishedUnit(unit);
	auto itre = repairUnits.find(unit->GetId());
	if (itre != repairUnits.end()) {
		AbortTask(itre->second);
	}
	auto itcl = reclaimUnits.find(unit);
	if ((itcl != reclaimUnits.end()) && (itcl->second != nullptr)) {
		DoneTask(itcl->second);
	}

	auto search = destroyedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != destroyedHandler.end()) {
		search->second(unit, attacker);
	}

	return 0; //signaling: OK
}

// D-108 crash (the owner's team game, build78): a unit that leaves our team
// (captured, or given to a teammate) never reaches UnitDestroyed here, and
// CCircuitAI frees it once it is marked dead; its unfinishedUnits key dangled
int CBuilderManager::UnitCaptured(CCircuitUnit* unit, int oldTeamId, int newTeamId)
{
	auto iter = unfinishedUnits.find(unit);
	if (iter != unfinishedUnits.end()) {
		AbortTask(iter->second);
	}
	EraseUnfinishedUnit(unit);
	return IModule::UnitCaptured(unit, oldTeamId, newTeamId);
}

void CBuilderManager::AddBuildPower(CCircuitUnit* unit)
{
	buildPower += unit->GetBuildSpeed();
}

void CBuilderManager::DelBuildPower(CCircuitUnit* unit)
{
	buildPower -= unit->GetBuildSpeed();
}

const std::set<IBuilderTask*>& CBuilderManager::GetTasks(IBuilderTask::BuildType type) const
{
	assert(type < IBuilderTask::BuildType::_SIZE_);
	return buildTasks[static_cast<IBuilderTask::BT>(type)];
}

float CBuilderManager::GetBuildPowerNear(const AIFloat3& position, float radius) const
{
	const float sqRadius = SQUARE(std::max(0.f, radius));
	const int frame = circuit->GetLastFrame();
	float power = 0.f;
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || unit->IsDead() || unit->GetUnit()->IsBeingBuilt()) {
			continue;
		}
		CCircuitDef* cdef = unit->GetCircuitDef();
		if ((cdef == nullptr) || !cdef->IsAbleToAssist()) {
			continue;
		}
		if (unit->GetPos(frame).SqDistance2D(position) <= sqRadius) {
			// The def's build speed is per frame (commander 10, turret 6.7);
			// the game and the planner talk in workertime per second.
			power += cdef->GetBuildSpeed() * FRAMES_PER_SEC;
		}
	}
	return power;
}

float CBuilderManager::GetStaticBuildPowerNear(const AIFloat3& position, float radius) const
{
	const float sqRadius = SQUARE(std::max(0.f, radius));
	const int frame = circuit->GetLastFrame();
	float power = 0.f;
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || unit->IsDead() || unit->GetUnit()->IsBeingBuilt()) {
			continue;
		}
		CCircuitDef* cdef = unit->GetCircuitDef();
		if ((cdef == nullptr) || cdef->IsMobile() || !cdef->IsAbleToAssist()) {
			continue;
		}
		if (unit->GetPos(frame).SqDistance2D(position) <= sqRadius) {
			power += cdef->GetBuildSpeed() * FRAMES_PER_SEC;
		}
	}
	return power;
}

int CBuilderManager::GetUnfinishedCount(const CCircuitDef* def) const
{
    const int indexed = def == nullptr ? 0 : unfinishedCounts.Count(def->GetId());
    // Debug oracle deliberately retains the old O(N) scan. Never enable it
    // for timing; it checks ownership, duplicate adoption and load callbacks.
    static const bool verify = std::getenv("CIRCUIT_VERIFY_ECONOMY_INDEX") != nullptr;
    if (!verify) return indexed;
	// D-108 crash: the keys of unfinishedUnits are never dereferenced (one can
	// outlive its unit); our live units are walked and looked up by pointer
	int count = 0;
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if ((unit != nullptr) && !unit->IsDead() && (unit->GetCircuitDef() == def)
			&& (unfinishedUnits.find(unit) != unfinishedUnits.end()))
		{
			++count;
		}
	}
    if (indexed != count) circuit->LOG("[INVARIANT] INV-175 unfinished index=%i scan=%i def=%i", indexed, count, def == nullptr ? -1 : def->GetId());
	return indexed;
}

void CBuilderManager::MarkUnfinishedUnit(CAllyUnit* target, IBuilderTask* task)
{
    unfinishedUnits[target] = task;
    CCircuitUnit* own = circuit->GetTeamUnit(target->GetId());
    if (own == target && !own->IsDead()) unfinishedCounts.Set(target, own->GetCircuitDef()->GetId());
    else unfinishedCounts.Erase(target);
}

void CBuilderManager::EraseUnfinishedUnit(CAllyUnit* target)
{
    // The saved definition in the index permits removal of stale pointer keys
    // without dereferencing them (D-108). Every map erase must use this path.
    unfinishedCounts.Erase(target);
    unfinishedUnits.erase(target);
}

CCircuitUnit* CBuilderManager::FindOwnNear(const AIFloat3& pos, float radius, const CCircuitDef* def)
{
	const int frame = circuit->GetLastFrame();
	const float radiusSq = radius * radius;
	CCircuitUnit* best = nullptr;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || unit->IsDead() || ((def != nullptr) && (unit->GetCircuitDef() != def))) {
			continue;
		}
		if (unit->GetUnit()->IsBeingBuilt()) {
			continue;
		}
		const float sq = pos.SqDistance2D(unit->GetPos(frame));
		if ((sq <= radiusSq) && (sq < bestSq)) {
			bestSq = sq;
			best = unit;
		}
	}
	return best;
}

CCircuitUnit* CBuilderManager::FindUnfinishedNear(const AIFloat3& pos, float radius, const CCircuitDef* def)
{
	// def == nullptr: any structure of ours under construction (D-066).
	const int frame = circuit->GetLastFrame();
	const float radiusSq = SQUARE(radius);
	CCircuitUnit* best = nullptr;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : circuit->GetTeamUnits()) {  // D-108 crash: never the map's keys
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || unit->IsDead() || ((def != nullptr) && (unit->GetCircuitDef() != def))
			|| (unfinishedUnits.find(unit) == unfinishedUnits.end()) || !unit->GetUnit()->IsBeingBuilt())
		{
			continue;
		}
		const float sq = unit->GetPos(frame).SqDistance2D(pos);
		if ((sq <= radiusSq) && (sq < bestSq)) {
			bestSq = sq;
			best = unit;
		}
	}
	return best;
}

CCircuitUnit* CBuilderManager::FindProducedNear(const AIFloat3& pos, float radius)
{
	// D-119: FindUnfinishedNear sees only the structures our builder tasks raise;
	// a unit in a factory's production is none of those. The nearest mobile unit
	// of ours still being built within radius.
	const int frame = circuit->GetLastFrame();
	const float radiusSq = SQUARE(radius);
	CCircuitUnit* best = nullptr;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || unit->IsDead() || (unit->GetCircuitDef() == nullptr) || !unit->GetCircuitDef()->IsMobile()) {
			continue;
		}
		const float sq = unit->GetPos(frame).SqDistance2D(pos);
		if ((sq > radiusSq) || (sq >= bestSq) || !unit->GetUnit()->IsBeingBuilt()) {
			continue;
		}
		bestSq = sq;
		best = unit;
	}
	return best;
}

float CBuilderManager::GetBuildPowerNearExcept(const AIFloat3& position, float radius, const CCircuitDef* ex1, const CCircuitDef* ex2,
		const CCircuitUnit* exUnit) const
{
	const float sqRadius = SQUARE(std::max(0.f, radius));
	const int frame = circuit->GetLastFrame();
	float power = 0.f;
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || (unit == exUnit) || unit->IsDead() || unit->GetUnit()->IsBeingBuilt()) {
			continue;
		}
		CCircuitDef* cdef = unit->GetCircuitDef();
		if ((cdef == nullptr) || !cdef->IsAbleToAssist() || (cdef == ex1) || (cdef == ex2)) {
			continue;
		}
		if (unit->GetPos(frame).SqDistance2D(position) <= sqRadius) {
			power += cdef->GetBuildSpeed() * FRAMES_PER_SEC;
		}
	}
	return power;
}

int CBuilderManager::CountUnfinishedNear(const AIFloat3& pos, float radius, float minCostM, const CCircuitDef* except)
{
	const int frame = circuit->GetLastFrame();
	const float radiusSq = SQUARE(radius);
	int n = 0;
	for (const auto& kv : circuit->GetTeamUnits()) {  // D-108 crash: never the map's keys
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || unit->IsDead()) {
			continue;
		}
		CCircuitDef* cdef = unit->GetCircuitDef();
		if ((cdef == nullptr) || (cdef == except) || cdef->IsMobile() || (cdef->GetCostM() < minCostM)
			|| (unfinishedUnits.find(unit) == unfinishedUnits.end()) || !unit->GetUnit()->IsBeingBuilt())
		{
			continue;
		}
		if (unit->GetPos(frame).SqDistance2D(pos) <= radiusSq) {
			++n;
		}
	}
	return n;
}

// D-065: reach of a builder to a structure, the engine's rule (build distance
// plus the buildee's model radius).
static bool InReachOf(CCircuitUnit* builder, CCircuitUnit* unit, int frame)
{
	const float reach = builder->GetCircuitDef()->GetBuildDistance() + unit->GetCircuitDef()->GetRadius();
	return builder->GetPos(frame).SqDistance2D(unit->GetPos(frame)) <= SQUARE(reach);
}

CCircuitUnit* CBuilderManager::FindReclaimTargetFor(CCircuitUnit* builder)
{
	if ((builder == nullptr) || builder->IsDead()) {
		return nullptr;
	}
	const int frame = circuit->GetLastFrame();
	CCircuitUnit* best = nullptr;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : reclaimIds) {
		CCircuitUnit* unit = circuit->GetTeamUnit(kv.second);
		if ((unit == nullptr) || unit->IsDead() || (unit == builder) || !InReachOf(builder, unit, frame)) {
			continue;
		}
		const float sq = builder->GetPos(frame).SqDistance2D(unit->GetPos(frame));
		if (sq < bestSq) {
			bestSq = sq;
			best = unit;
		}
	}
	return best;
}

CCircuitUnit* CBuilderManager::FindUnfinishedFor(CCircuitUnit* builder, const CCircuitDef* def)
{
	if ((builder == nullptr) || builder->IsDead() || (def == nullptr)) {
		return nullptr;
	}
	const int frame = circuit->GetLastFrame();
	CCircuitUnit* best = nullptr;
	float bestSq = std::numeric_limits<float>::max();
	for (const auto& kv : circuit->GetTeamUnits()) {  // D-108 crash: never the map's keys
		CCircuitUnit* unit = kv.second;
		if ((unit == nullptr) || unit->IsDead() || (unit->GetCircuitDef() != def)
			|| (unfinishedUnits.find(unit) == unfinishedUnits.end()) || !unit->GetUnit()->IsBeingBuilt() || !InReachOf(builder, unit, frame))
		{
			continue;
		}
		const float sq = builder->GetPos(frame).SqDistance2D(unit->GetPos(frame));
		if (sq < bestSq) {
			bestSq = sq;
			best = unit;
		}
	}
	return best;
}

IUnitTask* CBuilderManager::FindQueuedTask(CCircuitUnit* builder, IBuilderTask::BuildType type)
{
	if ((builder == nullptr) || (type < IBuilderTask::BuildType::FACTORY) || (type >= IBuilderTask::BuildType::_SIZE_)) {
		return nullptr;
	}
	const int frame = circuit->GetLastFrame();
	const AIFloat3& from = builder->GetPos(frame);
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	IBuilderTask* best = nullptr;
	float bestSq = std::numeric_limits<float>::max();
	for (IBuilderTask* task : GetTasks(type)) {
		if ((task == nullptr) || task->IsDead() || !task->GetAssignees().empty() || !task->CanAssignTo(builder)) {
			continue;
		}
		// D-093: with the layout on, an economy order the layout did not place is
		// never adopted (played: the chain's take-over walked the commander to a
		// turbine 467 elmos outside the layout)
		if (experimentalBuild && !task->IsLayoutOwned() && IsLayoutEconomy(type))
		{
			continue;
		}
		const AIFloat3& pos = task->GetPosition();
		if (geom::is_valid(pos) && !terrainMgr->CanReachAtSafe(builder, pos, builder->GetCircuitDef()->GetBuildDistance())) {
			continue;
		}
		const float sq = geom::is_valid(pos) ? from.SqDistance2D(pos) : 0.f;
		if (sq < bestSq) {
			bestSq = sq;
			best = task;
		}
	}
	return best;
}

int CBuilderManager::GetQueuedBuildCount(IBuilderTask::BuildType type, const CCircuitDef* buildDef) const
{
	if ((type < IBuilderTask::BuildType::FACTORY) || (type >= IBuilderTask::BuildType::_SIZE_)) {
		return 0;
	}
	int count = 0;
	for (const IBuilderTask* task : GetTasks(type)) {
		if ((task != nullptr) && !task->IsDead() && (task->GetTarget() == nullptr)
				&& ((buildDef == nullptr) || (task->GetBuildDef() == buildDef))) {
			++count;
		}
	}
	return count;
}

void CBuilderManager::ActivateTask(IBuilderTask* task)
{
	if ((task->GetType() == IUnitTask::Type::BUILDER) && (task->GetBuildType() < IBuilderTask::BuildType::_SIZE_)) {
		buildTasks[static_cast<IBuilderTask::BT>(task->GetBuildType())].insert(task);
		buildTasksCount++;
	}
	updateTasks.push_back(task);
	task->Activate();
}

IBuilderTask* CBuilderManager::Enqueue(const TaskB::SBuildTask& ti)
{
	// Positional requests from older role helpers still enter the field claim
	// lifecycle. They may never fall back to nearest synthetic spot ownership.
	if (circuit->GetEconomyManager()->IsMetalMap()
		&& (ti.type == IBuilderTask::BuildType::MEX || ti.type == IBuilderTask::BuildType::MEXUP)
		&& ti.i.spotId != metal_field::SiteTagV1) {
		auto field = ti;
		field.i.spotId = metal_field::SiteTagV1;
		return Enqueue(field);
	}
	// Only construction types (the contiguous range before REPAIR) initialize
	// buildDef. Service tasks such as Repair/Reclaim leave that field unset.
	// A profile's construction veto survives scripts lifting temporary caps.
	if ((ti.type < IBuilderTask::BuildType::REPAIR)
			&& (ti.buildDef != nullptr) && (!ti.buildDef->IsBuildAllowed()
				|| circuit->GetEconomyManager()->IsMetalConverter(ti.buildDef))) {
		return nullptr;
	}
	IBuilderTask* task;

	switch (ti.type) {
		case IBuilderTask::BuildType::FACTORY: {
			const SResource cost = ti.b.isPlop ? SResource{1.f, 0.f} : SResource{ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBFactoryTask(this, ti.priority, ti.buildDef, ti.ref.reprDef, ti.position, cost, ti.f.shake, ti.b.isPlop, ti.timeout);
			if (ti.isActive) {
				task->Activate();  // circuit->GetFactoryManager()->ApplySwitchFrame();
			}
		} break;
		case IBuilderTask::BuildType::NANO: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBNanoTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::STORE: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBStoreTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::PYLON: {
			task = new CBPylonTask(this, ti.priority, ti.buildDef, ti.position, ti.ref.link, ti.cost, ti.timeout);
		} break;
		case IBuilderTask::BuildType::ENERGY: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBEnergyTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::GEO: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBGeoTask(this, ti.priority, ti.buildDef, ti.i.spotId, ti.position, cost, ti.timeout);
		} break;
//		case IBuilderTask::BuildType::GEOUP: {
//		} break;
		case IBuilderTask::BuildType::DEFENCE: {  // lotus, defender, stardust, stinger
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBDefenceTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::BUNKER: {  // ddm, anni
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBBunkerTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::BIG_GUN: {  // super weapons
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBBigGunTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::RADAR: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBRadarTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::SONAR: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBSonarTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::CONVERT: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBConvertTask(this, ti.priority, ti.buildDef, ti.position, cost, ti.f.shake, ti.timeout);
		} break;
		case IBuilderTask::BuildType::MEX: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBMexTask(this, ti.priority, ti.buildDef, ti.i.spotId, ti.position, cost, ti.timeout);
		} break;
		case IBuilderTask::BuildType::MEXUP: {
			const SResource cost = {ti.buildDef->GetCostM(), ti.buildDef->GetCostE()};
			task = new CBMexUpTask(this, ti.priority, ti.buildDef, ti.i.spotId, ti.position, cost, ti.timeout);
		} break;
		case IBuilderTask::BuildType::REPAIR: {
			auto it = repairUnits.find(ti.ref.target->GetId());
			if ((it != repairUnits.end()) && (it->second != nullptr)) {
				return it->second;
			}
			task = new CBRepairTask(this, ti.priority, ti.ref.target, ti.timeout);
		} break;
		case IBuilderTask::BuildType::RECLAIM: {
			if (ti.ref.target != nullptr) {
				auto it = reclaimUnits.find(ti.ref.target);
				if ((it != reclaimUnits.end()) && (it->second != nullptr)) {  // TODO: Rework RegisterReclaim() that puts nullptr into reclaimUnits
					return it->second;
				}
				CCircuitUnit* own = circuit->GetTeamUnit(ti.ref.target->GetId());
				// D-290: a script-protected definition of ours is never reclaimed.
				// Refused before MarkSlotRecycled so its layout ground stays held.
				// Every caller handles nullptr (the frame-adoption path repairs).
				if ((own != nullptr) && IsReclaimProtected(own->GetCircuitDef())) {
					circuit->LOG("RECLAIM: refused protected %s(%i)", own->GetCircuitDef()->GetDef()->GetName(), own->GetId());
					return nullptr;
				}
				task = new CBReclaimTask(this, ti.priority, ti.ref.target, ti.timeout);
				// D-101: our own structure reclaimed on purpose: its layout ground is freed when it goes
				if ((own != nullptr) && (own->GetCircuitDef() != nullptr) && !own->GetCircuitDef()->IsMobile()) {
					circuit->GetTerrainManager()->MarkSlotRecycled(own->GetCircuitDef(), own->GetPos(circuit->GetLastFrame()));
				}
			} else {
				task = new CBReclaimTask(this, ti.priority, ti.position, ti.cost, ti.timeout, ti.f.radius, ti.b.isMetal);
			}
		} break;
		case IBuilderTask::BuildType::RESURRECT: {
			task = new CBResurrectTask(this, ti.priority, ti.position, ti.cost, ti.timeout, ti.f.radius);
		} break;
//		case IBuilderTask::BuildType::RECRUIT: {
//		} break;
		case IBuilderTask::BuildType::TERRAFORM: {
			if (ti.ref.target != nullptr) {
				task = new CBTerraformTask(this, ti.priority, ti.ref.target, ti.cost, ti.timeout);
			} else {
				task = new CBTerraformTask(this, ti.priority, ti.position, ti.cost, ti.timeout);
			}
		} break;
		default: {
			// FIXME: CBGenericTask is a workaround and should be fixed to remain as crash handler.
			//        Currently used by build_chain->hub config.
			//        There's no way for AS to distinguish generic from real BuildType task. Save/Load gets confused.
			task = new CBGenericTask(this, ti.type, ti.priority, ti.buildDef, ti.position, ti.cost, ti.f.shake, ti.timeout);
		} break;
	}

	if (ti.isActive) {
		buildTasks[static_cast<IBuilderTask::BT>(ti.type)].insert(task);
		buildTasksCount++;
		updateTasks.push_back(task);
	} else {
		task->Deactivate();
	}
	lastEnqueued = task;
	TaskAdded(task);
	if ((ti.type == IBuilderTask::BuildType::MEX && ti.i.spotId == metal_field::SiteTagV1 && !static_cast<CBMexTask*>(task)->HasFieldClaim())
		|| (ti.type == IBuilderTask::BuildType::MEXUP && ti.i.spotId == metal_field::SiteTagV1 && !static_cast<CBMexUpTask*>(task)->HasFieldClaim())) {
		AbortTask(task);
		return nullptr;
	}
	return task;
}

IBuilderTask* CBuilderManager::EnqueueLayout(
		const TaskB::SBuildTask& ti, const std::string& groupName, CCircuitUnit* builder)
{
	IBuilderTask* task = Enqueue(ti);
	if ((task == nullptr) || !circuit->GetTerrainManager()->PinLayoutTask(task, groupName, builder)) {
		if (task != nullptr) {
			AbortTask(task);
		}
		return nullptr;
	}
	return task;
}

IBuilderTask* CBuilderManager::EnqueueFactoryNano(const TaskB::SBuildTask& ti, CCircuitUnit* builder)
{
	if ((builder == nullptr) || (circuit->GetTerrainManager()->GetFactoryNanoAvailable() <= 0)) {
		return nullptr;
	}
	IBuilderTask* task = Enqueue(ti);
	if ((task == nullptr) || !circuit->GetTerrainManager()->PinFactoryNanoTask(task, builder)) {
		if (task != nullptr) {
			AbortTask(task);
		}
		return nullptr;
	}
	return task;
}

IUnitTask* CBuilderManager::FindMatchingGuard(CCircuitUnit* unit, const TaskB::SServBTask& ti)
{
	if (unit == nullptr || ti.target == nullptr || ti.type != IBuilderTask::BuildType::GUARD
		|| unit->IsDead() || ti.target->IsDead()) return nullptr;
	auto* current = dynamic_cast<CBGuardTask*>(unit->GetTask());
	// Reevaluate hides an assignee from accounting while calling policy, but
	// retains task ownership. Compare that owner, not a global guard inventory.
	return current && current->GetManager() == this
		&& current->MatchesGuard(unit->GetId(), ti.target->GetId(), ti.priority, ti.isInterrupt, ti.timeout, circuit->GetLastFrame())
		? current : nullptr;
}

CCommanderTask* CBuilderManager::EnqueueCommander(IUnitTask* previous) {
    auto* task=new CCommanderTask(this,previous);
    updateTasks.push_back(task); lastEnqueued=task; TaskAdded(task); return task;
}
bool CBuilderManager::SetCommanderCombatOption(const std::string& name,float value) {
    return circuit->GetCommanderControl()->SetOption(name,value);
}
float CBuilderManager::GetCommanderEnergyReserve() const { return circuit->GetCommanderControl()->GetReserve(); }
float CBuilderManager::GetCommanderEnergyDeficit() const { return circuit->GetCommanderControl()->GetDeficit(); }
int CBuilderManager::GetCommanderOperation() const { return circuit->GetCommanderControl()->GetOperation(); }
IUnitTask* CBuilderManager::CommanderFrontWork(CCircuitUnit* unit,int kind,CCircuitDef* def,float radius) {
    return circuit->GetCommanderControl()->FrontWork(unit,kind,def,radius);
}

IUnitTask* CBuilderManager::Enqueue(const TaskB::SServBTask& ti)
{
	IUnitTask* task;

	switch (ti.type) {
		case IBuilderTask::BuildType::PATROL: {
			task = new CBPatrolTask(this, ti.priority, ti.position, ti.timeout);
		} break;
		case IBuilderTask::BuildType::GUARD: {
			task = new CBGuardTask(this, ti.priority, ti.target, ti.isInterrupt, ti.timeout);
		} break;
		case IBuilderTask::BuildType::COMBAT: {
			task = new CCombatTask(this, ti.powerMod);
		} break;
		default:
		case IBuilderTask::BuildType::WAIT: {
			task = new CBWaitTask(this, ti.timeout);
		} break;
	}

	updateTasks.push_back(task);
	lastEnqueued = task;
	TaskAdded(task);
	return task;
}

CRetreatTask* CBuilderManager::EnqueueRetreat()
{
	CRetreatTask* task = new CRetreatTask(this);
	updateTasks.push_back(task);
	lastEnqueued = task;
	TaskAdded(task);
	return task;
}

void CBuilderManager::AssignTask(CCircuitUnit* unit, IUnitTask* task)
{
	ITaskModule::AssignTask(unit, task);
	static_cast<CBuilderScript*>(script)->TaskAssigned(unit);
}

void CBuilderManager::AssignTask(CCircuitUnit* unit)
{
	ITaskModule::AssignTask(unit);
	static_cast<CBuilderScript*>(script)->TaskAssigned(unit);
}

void CBuilderManager::DequeueTask(IUnitTask* task, bool done)
{
	switch (task->GetType()) {
		case IUnitTask::Type::BUILDER: {
			IBuilderTask* taskB = static_cast<IBuilderTask*>(task);
			if (taskB->GetBuildType() >= IBuilderTask::BuildType::_SIZE_) {
				break;
			}
			std::set<IBuilderTask*>& tasks = buildTasks[static_cast<IBuilderTask::BT>(taskB->GetBuildType())];
			auto it = tasks.find(taskB);
			if (it == tasks.end()) {
				break;
			}
			switch (taskB->GetBuildType()) {
				case IBuilderTask::BuildType::REPAIR: {
					repairUnits.erase(static_cast<CBRepairTask*>(taskB)->GetTargetId());
				} break;
				case IBuilderTask::BuildType::RECLAIM: {
					if (taskB->GetTarget() != nullptr) {
						UnregisterReclaim(taskB->GetTarget());
					}
				} break;
				case IBuilderTask::BuildType::RESURRECT: {
				} break;
				default: {
					EraseUnfinishedUnit(taskB->GetTarget());
					// D-108 crash: and every other entry of this task (a task whose
					// target changed left its old frame behind, a dangling key once freed)
					for (auto itu = unfinishedUnits.begin(); itu != unfinishedUnits.end();) {
						if (itu->second == taskB) { unfinishedCounts.Erase(itu->first); itu = unfinishedUnits.erase(itu); }
						else ++itu;
					}
				} break;
			}
			tasks.erase(it);
			buildTasksCount--;
		} break;
		default: break;
	}
	ITaskModule::DequeueTask(task, done);
}

void CBuilderManager::MarkReclaimUnit(CAllyUnit* target, CBReclaimTask* task)
{
	if ((reclaimUnits.find(target) == reclaimUnits.end()) && (circuit->GetAllyTeam() != nullptr)) {
		circuit->GetAllyTeam()->MarkReclaim(target->GetId());
	}
	reclaimUnits[target] = task;
	reclaimIds[target] = target->GetId();
}

void CBuilderManager::RegisterReclaim(CAllyUnit* unit)
{
	if ((reclaimUnits.find(unit) == reclaimUnits.end()) && (circuit->GetAllyTeam() != nullptr)) {
		circuit->GetAllyTeam()->MarkReclaim(unit->GetId());
	}
	reclaimUnits[unit] = nullptr;
	reclaimIds[unit] = unit->GetId();
}

void CBuilderManager::UnregisterReclaim(CAllyUnit* unit)
{
	// `unit` is only a key here, never dereferenced: the mex-upgrade task calls
	// this for the extractor it reclaimed, which may already be freed (CR-001).
	auto it = reclaimIds.find(unit);
	const bool known = (it != reclaimIds.end());
	const ICoreUnit::Id id = known ? it->second : -1;
	if (known) {
		reclaimIds.erase(it);
	}
	if ((reclaimUnits.erase(unit) > 0) && known && (circuit->GetAllyTeam() != nullptr)) {
		circuit->GetAllyTeam()->UnmarkReclaim(id);
	}
}

bool CBuilderManager::IsReclaimUnit(CAllyUnit* unit) const
{
	if (reclaimUnits.find(unit) != reclaimUnits.end()) {
		return true;
	}
	const CAllyTeam* allyTeam = circuit->GetAllyTeam();
	return (allyTeam != nullptr) && allyTeam->IsReclaimMarked(unit->GetId());
}

int CBuilderManager::TurretsOnReclaim(int targetId, float margin, bool apply, bool preserveReclaimPriority)
{
	const auto t0 = std::chrono::steady_clock::now();
	struct SAtExit { CCircuitAI* c; std::chrono::steady_clock::time_point t0; ~SAtExit() { const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count(); if (ms > 20.0) c->LOG("SLOW: TurretsOnReclaim took %.0f ms", ms); } } atExit{circuit, t0};
	CCircuitUnit* target = circuit->GetTeamUnit(targetId);
	if ((target == nullptr) || target->IsDead()) {
		return -1;
	}
	if (IsReclaimProtected(target->GetCircuitDef())) {
		return 0;  // D-290: never reclaimed, so no turret is pulled onto it
	}
	const int frame = circuit->GetLastFrame();
	const AIFloat3& tpos = target->GetPos(frame);
	const auto requested = reclaimUnits.find(target);
	const auto requestedPriority = (requested != reclaimUnits.end() && requested->second != nullptr)
		? requested->second->GetPriority() : IUnitTask::Priority::HIGH;
	IBuilderTask* join = nullptr;
	int off = 0;
	for (const auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* u = kv.second;
		if ((u == nullptr) || u->IsDead() || (u == target)) {
			continue;
		}
		CCircuitDef* cdef = u->GetCircuitDef();
		if (cdef->IsMobile() || !cdef->IsAbleToAssist() ||  // a turret has no build options: IsBuilder is false for it (played)
				 u->GetUnit()->IsBeingBuilt()) {
			continue;
		}
		const float reach = cdef->GetBuildDistance() + margin;
		if (u->GetPos(frame).SqDistance2D(tpos) > reach * reach) {
			continue;
		}
		IUnitTask* t = u->GetTask();
		if ((t != nullptr) && (t->GetType() == IUnitTask::Type::PLAYER)) {
			continue;
		}
		if (t != nullptr && t->IsEnemyReclaim()) continue; // enemy denial precedes friendly recycling (D-184)
		if (u->IsAttrNoDisrupt()) {
			continue;  // D-117: bound to its duty (a spam lab's turret assists that lab only)
		}
		if ((t != nullptr) && (t->GetType() == IUnitTask::Type::BUILDER)) {
			IBuilderTask* bt = static_cast<IBuilderTask*>(t);
			if ((bt->GetBuildType() == IBuilderTask::BuildType::RECLAIM) && (bt->GetTarget() == target)) {
				continue;  // already on it
			}
			// TECH supplies the task priorities (lab HIGH, obsolete energy NORMAL).
			// Keep an equally urgent live reclaim stable instead of pulling the same
			// turret between overlapping targets. Apply and inspection use identical
			// eligibility; one turret cannot serve two simultaneous reclaim jobs.
			// This adds no scan or command and leaves legacy callers unchanged.
			if (preserveReclaimPriority && !bt->IsDead()
					&& bt->GetBuildType() == IBuilderTask::BuildType::RECLAIM
					&& bt->GetTarget() != nullptr && !bt->GetTarget()->IsDead()
					&& bt->GetPriority() >= requestedPriority) continue;
		}
		++off;
		if (!apply) {
			continue;
		}
		if (join == nullptr) {
			// Enqueue before detaching the turret: a refused reclaim (D-290)
			// must leave it on its current task, not stranded with none.
			join = Enqueue(TaskB::Reclaim(IBuilderTask::Priority::HIGH, target, FRAMES_PER_SEC * 300));
			if (join == nullptr) {
				--off;
				break;
			}
		}
		if (t != nullptr) {
			ITaskModule* previousManager = t->GetManager();
			t->RemoveAssignee(u);
			// Factory-owned nanos can temporarily join Builder's explicit reclaim.
			// RemoveAssignee puts them in the OLD manager's idle set; AssignTo only
			// clears the NEW manager's idle set. Leaving the old membership lets its
			// next update overwrite this assignment and retain stale unit pointers.
			// Match the existing enemy-reclaim ownership handoff, with O(1) owners
			// and no extra engine commands.
			if (previousManager != this) previousManager->GetIdleTask()->RemoveAssignee(u);
		}
		join->AssignTo(u);
		join->Start(u);
		static_cast<CBuilderScript*>(script)->TaskAssigned(u);
	}
	if (apply && (off > 0)) {
		circuit->LOG("EXP: turrets: %i join the reclaim of %s(%i)", off, target->GetCircuitDef()->GetDef()->GetName(), targetId);
	}
	return off;
}

void CBuilderManager::FallbackTask(CCircuitUnit* unit)
{
	DequeueTask(unit->GetTask());

	const int frame = circuit->GetLastFrame();
	const AIFloat3& pos = unit->GetPos(frame);
	IUnitTask* task = Enqueue(TaskB::Patrol(IBuilderTask::Priority::LOW, pos, FRAMES_PER_SEC * 5));
	task->AssignTo(unit);
	task->Start(unit);
	static_cast<CBuilderScript*>(script)->TaskAssigned(unit);
}

bool CBuilderManager::IsBuilderInArea(CCircuitDef* buildDef, const AIFloat3& position) const
{
	if (!geom::is_valid(position)) {  // any-area task
		return true;
	}
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	for (auto& kv : buildAreas) {
		for (auto& kvw : kv.second) {
			if ((kvw.second > 0) && kvw.first->CanBuild(buildDef) &&
				terrainMgr->CanMobileReachAt(kv.first, position, kvw.first->GetBuildDistance()))
			{
				return true;
			}
		}
	}
	return false;
}

bool CBuilderManager::HasFreeAssists(CCircuitUnit* builder) const
{
	CCircuitDef* conDef = builder->GetCircuitDef();
	const auto conTaskCnt = GetTasks(IBuilderTask::BuildType::FACTORY).size() + GetTasks(IBuilderTask::BuildType::NANO).size();
	return (guardCount <= (conTaskCnt == 0 ? assistCount / 2 : 2))
			&& conDef->IsAbleToAssist() && !builder->IsAttrSolo()
			&& (!conDef->IsRoleComm() || ((int)assistCount <= circuit->GetSetupManager()->GetAssistFac()));
}

SBuildChain* CBuilderManager::GetBuildChain(IBuilderTask::BuildType buildType, CCircuitDef* cdef) const
{
	auto it1 = buildChains.find(static_cast<IBuilderTask::BT>(buildType));
	if (it1 == buildChains.end()) {
		return nullptr;
	}
	auto it2 = it1->second.find(cdef);
	if (it2 == it1->second.end()) {
		return nullptr;
	}
	return it2->second;
}

IBuilderTask* CBuilderManager::GetRepairTask(ICoreUnit::Id unitId) const
{
	auto it = repairUnits.find(unitId);
	if (it != repairUnits.end()) {
		return it->second;
	}
	return nullptr;
}

IBuilderTask* CBuilderManager::GetReclaimFeatureTask(const AIFloat3& pos, float radius) const
{
	for (IBuilderTask* t : GetTasks(IBuilderTask::BuildType::RECLAIM)) {
		CBReclaimTask* rt = static_cast<CBReclaimTask*>(t);
		if ((rt->GetTarget() == nullptr) && rt->IsInRange(pos, radius)) {
			return rt;
		}
	}
	return nullptr;
}

IBuilderTask* CBuilderManager::GetResurrectTask(const AIFloat3& pos, float radius) const
{
	for (IBuilderTask* t : GetTasks(IBuilderTask::BuildType::RESURRECT)) {
		CBResurrectTask* rt = static_cast<CBResurrectTask*>(t);
		if (rt->IsInRange(pos, radius)) {
			return rt;
		}
	}
	return nullptr;
}

void CBuilderManager::SetCanUpMex(CCircuitDef* cdef, bool value)
{
	auto it = workerDefs.find(cdef);
	if (it != workerDefs.end()) {
		it->second.canUpMex = value;
	}
}

bool CBuilderManager::CanUpMex(CCircuitDef* cdef) const
{
	auto it = workerDefs.find(cdef);
	return (it != workerDefs.end()) && it->second.canUpMex;
}

void CBuilderManager::SetCanUpGeo(CCircuitDef* cdef, bool value)
{
	auto it = workerDefs.find(cdef);
	if (it != workerDefs.end()) {
		it->second.canUpGeo = value;
	}
}

bool CBuilderManager::CanUpGeo(CCircuitDef* cdef) const
{
	auto it = workerDefs.find(cdef);
	return (it != workerDefs.end()) && it->second.canUpGeo;
}

IUnitTask* CBuilderManager::MakeTask(CCircuitUnit* unit)
{
	freshDefaults.clear();
	freshMade = nullptr;
	IUnitTask* task = ITaskModule::MakeTask(unit);  // script policy, DefaultMakeTask inside
	for (IUnitTask* def : freshDefaults) {
		if (def == task) {
			freshMade = task;
		} else if (!def->IsDead() && def->GetAssignees().empty()) {
			AbortTask(def);
			++discardCount;
		}
	}
	freshDefaults.clear();
	const int frame = circuit->GetLastFrame();
	if ((discardCount > 0) && (frame - discardLogFrame >= FRAMES_PER_SEC * 60)) {
		circuit->LOG("BUILDER: discarded %i unused default task(s) in the last minute", discardCount);
		discardCount = 0;
		discardLogFrame = frame;
	}
	return task;
}

void CBuilderManager::DiscardUnusedTask(IUnitTask* task)
{
	if ((task != nullptr) && (task == freshMade) && !task->IsDead() && task->GetAssignees().empty()) {
		AbortTask(task);
		++discardCount;
	}
	freshMade = nullptr;
}

void CBuilderManager::AbortLayoutTasks()
{
	std::vector<IBuilderTask*> tasks;
	for (const auto& byType : buildTasks) {
		for (IBuilderTask* task : byType) {
			if ((task != nullptr) && task->IsLayoutOwned() && !task->IsDead()) {
				tasks.push_back(task);
			}
		}
	}
	for (IBuilderTask* task : tasks) {
		AbortTask(task);
	}
}

IUnitTask* CBuilderManager::DefaultMakeTask(CCircuitUnit* unit)
{
	if (experimentalBuild) {
		return nullptr;  // D-066: the script's sequence is the only source of work
	}
	IUnitTask* const before = lastEnqueued;
	IUnitTask* task = DefaultMakeTaskImpl(unit);
	// Fresh: this call created the task it returns. Not fresh: it returned a
	// task already in the queue, which belongs to whoever queued it.
	if ((task != nullptr) && (task == lastEnqueued) && (task != before)) {
		freshDefaults.push_back(task);
	}
	return task;
}

IUnitTask* CBuilderManager::DefaultMakeTaskImpl(CCircuitUnit* unit)
{
	const int frame = circuit->GetLastFrame();
	const AIFloat3& pos = unit->GetPos(frame);

	const CCircuitDef* cdef = unit->GetCircuitDef();
	constexpr float POWER_MOD = 1.5f;
	if ((cdef->GetPower() > THREAT_MIN)
        && !(circuit->GetCommanderControl() && circuit->GetCommanderControl()->Handles(unit))
		&& (circuit->GetMilitaryManager()->FindBCombatTarget(unit, pos, POWER_MOD, true) != nullptr))
	{
		return Enqueue(TaskB::Combat(POWER_MOD));
	}

	const auto it = costQueries.find(unit);
	std::shared_ptr<IPathQuery> query = (it == costQueries.end()) ? nullptr : it->second;
	if ((query != nullptr) && (query->GetState() != IPathQuery::State::READY)) {  // not ready
		return nullptr;
	}

	CPathFinder* pathfinder = circuit->GetPathfinder();
	std::shared_ptr<IPathQuery> q = pathfinder->CreateCostMapQuery(unit, circuit->GetThreatMap(),
			/*unit->IsAttrBase() ? circuit->GetSetupManager()->GetBasePos() : */pos, cdef->GetPower());
	costQueries[unit] = q;
	pathfinder->RunQuery(circuit->GetScheduler().get(), q);

	if (query == nullptr) {
		return Enqueue(TaskB::Wait(FRAMES_PER_SEC));  // 1st run
	}

	std::shared_ptr<CQueryCostMap> pQuery = std::static_pointer_cast<CQueryCostMap>(query);

	if (cdef->IsRoleComm() && (circuit->GetFactoryManager()->GetFactoryCount() > 0)) {  // hide commander?
		CEnemyManager* enemyMgr = circuit->GetEnemyManager();
		const CSetupManager::SCommInfo::SHide* hide = circuit->GetSetupManager()->GetHide(cdef);
		if (hide != nullptr) {
			if ((frame < hide->frame) || (GetWorkerCount() <= 2)) {
				return (hide->sqPeaceTaskRad < 0.f)
						? MakeBuilderTask(unit, pQuery.get())
						: MakeCommTask(unit, pQuery.get(), hide->sqPeaceTaskRad);
			}
			if (circuit->GetInflMap()->GetEnemyInflAt(pos) >= hide->threat) {
				dangerTime[unit] = frame;
			}
//			if ((enemyMgr->GetMobileThreat() / circuit->GetAllyTeam()->GetAliveSize() >= hide->threat)
			if ((dangerTime[unit] + dangerHysteresis >= frame)
				|| ((hide->isAir) && (enemyMgr->GetEnemyCost(ROLE_TYPE(AIR)) > 1.f)))
			{
				return MakeCommTask(unit, pQuery.get(), hide->sqDangerTaskRad);
			}
			return (hide->sqPeaceTaskRad < 0.f)
					? MakeBuilderTask(unit, pQuery.get())
					: MakeCommTask(unit, pQuery.get(), hide->sqPeaceTaskRad);
		}
	}

	return unit->IsAttrBase()
			? MakeEnergizerTask(unit, pQuery.get())
			: MakeBuilderTask(unit, pQuery.get());
}

IBuilderTask* CBuilderManager::MakeEnergizerTask(CCircuitUnit* unit, const CQueryCostMap* query)
{
	CThreatMap* threatMap = circuit->GetThreatMap();
	threatMap->SetThreatType(unit);
	const IBuilderTask* task = nullptr;
	const int frame = circuit->GetLastFrame();
	const AIFloat3& pos = unit->GetPos(frame);
//	CTerrainManager::CorrectPosition(pos);

	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	economyMgr->MakeEconomyTasks(pos, unit);
	// TODO: Add excess mechanics for lower difficulties, @see MakeBuilderTask

	CMetalManager* metalMgr = circuit->GetMetalManager();
	const CMetalData::Clusters& clusters = metalMgr->GetClusters();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CInfluenceMap* inflMap = circuit->GetInflMap();
	CPathFinder* pathfinder = circuit->GetPathfinder();

	CCircuitDef* cdef = unit->GetCircuitDef();
	const float maxSpeed = cdef->GetSpeed() / pathfinder->GetSquareSize() * COST_BASE;
	const int buildDistance = std::max<int>(cdef->GetBuildDistance(), pathfinder->GetSquareSize());
	const float buildSqDistance = SQUARE(buildDistance);
	const AIFloat3& basePos = circuit->GetSetupManager()->GetBasePos();
	const float maxSqBaseDist = pos.SqDistance2D(basePos);
	float metric = std::numeric_limits<float>::max();

	constexpr std::array<std::pair<IBuilderTask::BuildType, float>, (int)IBuilderTask::BuildType::_SIZE_> prioTasks = {
		std::make_pair(IBuilderTask::BuildType::ENERGY, SQUARE(10000.f)),
		std::make_pair(IBuilderTask::BuildType::STORE, SQUARE(10000.f)),
		std::make_pair(IBuilderTask::BuildType::FACTORY, SQUARE(10000.f)),
		std::make_pair(IBuilderTask::BuildType::NANO, SQUARE(10000.f)),
		std::make_pair(IBuilderTask::BuildType::MEXUP, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::MEX, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::GEO, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::GEOUP, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::CONVERT, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::PYLON, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::RADAR, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::SONAR, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::BUNKER, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::BIG_GUN, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::DEFENCE, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::REPAIR, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::RECLAIM, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::RESURRECT, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::RECRUIT, SQUARE(2000.f)),
		std::make_pair(IBuilderTask::BuildType::TERRAFORM, SQUARE(2000.f)),
	};

	for (const std::pair<IBuilderTask::BuildType, float>& pair : prioTasks) {
		const float maxSqTaskDist = std::max(maxSqBaseDist, pair.second);
		for (const IBuilderTask* candidate : GetTasks(pair.first)) {
			if (!candidate->CanAssignTo(unit)) {
				continue;
			}

			// Check time-distance to target
			const AIFloat3& bp = candidate->GetPosition();
			AIFloat3 buildPos = geom::is_valid(bp) ? bp : pos;

			if (candidate->GetPriority() == IBuilderTask::Priority::NOW) {
				// Disregard safety
				if (!terrainMgr->CanReachAt(unit, buildPos, cdef->GetBuildDistance())) {  // ensure that path always exists
					continue;
				}

			} else {

				int index = metalMgr->FindNearestCluster(buildPos);
				const AIFloat3& testPos = (index < 0) ? buildPos : clusters[index].position;
				if ((pos.SqDistance2D(testPos) > pair.second)
					|| (basePos.SqDistance2D(testPos) > maxSqTaskDist)  // take task closer to base, related to con created out of base. TODO: use query->GetCostAt()?
					|| !terrainMgr->CanReachAt(unit, buildPos, cdef->GetBuildDistance())  // ensure that path always exists
					|| (inflMap->GetInfluenceAt(testPos) < -INFL_EPS))  // safety check
				{
					continue;
				}
			}

			float distCost;
			const float rawSqDist = pos.SqDistance2D(buildPos);
			const bool isClose = rawSqDist < buildSqDistance;
			if (isClose) {
				distCost = sqrtf(rawSqDist) / pathfinder->GetSquareSize() * COST_BASE * 0.5f;
			} else {
				distCost = query->GetCostAt(buildPos, buildDistance);
				if (distCost < 0.f) {  // path blocked by buildings or threat too high
					continue;
				}
			}

			distCost = std::max(distCost, COST_BASE);

			float weight = (static_cast<float>(candidate->GetPriority()) + 1.0f);
			weight = 1.0f / SQUARE(weight);
			bool valid = distCost * weight < metric;

			if (valid && !isClose) {
				CCircuitUnit* target = candidate->GetTarget();
				if (target != nullptr) {
					Unit* tu = target->GetUnit();
					const float maxHealth = tu->GetMaxHealth();
					const float health = tu->GetHealth() - maxHealth * 0.005f;
					const float healthSpeed = maxHealth * candidate->GetBuildPowerM() / candidate->GetCostM();
					valid = ((maxHealth - health) * 0.6f) * maxSpeed > healthSpeed * distCost;
				} else {
					valid = distCost < MAX_TRAVEL_SEC * maxSpeed;
				}
			}

			if (valid) {
				task = candidate;
				metric = distCost * weight;
			}
		}

		if (task != nullptr) {
			break;
		}
	}

	if ((task == nullptr) &&
		((unit->GetTask()->GetType() != IUnitTask::Type::BUILDER) || (static_cast<IBuilderTask*>(unit->GetTask())->GetBuildType() != IBuilderTask::BuildType::GUARD)))
	{
		CCircuitUnit* vip = circuit->GetFactoryManager()->GetClosestFactory(pos);
		if (vip != nullptr) {
			task = EnqueueB(TaskB::Guard(IBuilderTask::Priority::NORMAL, vip, true, FRAMES_PER_SEC * 10));
		} else {
			task = EnqueueB(TaskB::Patrol(IBuilderTask::Priority::LOW, pos, FRAMES_PER_SEC * 5));
		}
	}

	return const_cast<IBuilderTask*>(task);
}

// D-211: query mechanism, opt-in from role script. Modes do not impose an
// order: SEA chooses reclaim/flagship/resurrection/repair in its own policy.
// One feature snapshot per simulation second per AI avoids engine wrapper
// creation per sub. Feature selection is O(F * (1 + R)) in the worst case:
// eligible improving candidates query the existing R reclaim/rez task claims.
// Repair selection scans U friendly units. Reach tests run only for improving
// candidates or the current job. Cache holds values/IDs, never borrowed wrappers.
void CBuilderManager::RefreshRecoveryFeatures()
{
    const int frame = circuit->GetLastFrame();
    auto* clb = circuit->GetCallback();
    if (frame - recoveryFrame >= FRAMES_PER_SEC || frame < recoveryFrame) {
        recoveryFrame = frame;
        recoveryFeatures.clear(); // capacity retained across snapshots
        auto features = clb->GetFeatures();
        for (Feature* f : features) {
            FeatureDef* def = f->GetDef();
            const float metal = def->GetContainedResource(circuit->GetEconomyManager()->GetMetalRes()) * f->GetReclaimLeft();
            const int rezId = clb->Feature_ResurrectDef(f->GetFeatureId());
            CCircuitDef* rez = rezId > 0 ? circuit->GetCircuitDef(rezId) : nullptr;
            if (def->IsReclaimable() && metal > 0) {
                const bool ship = rez != nullptr && rez->IsMobile() && !rez->IsAbleToFly()
                    && rez->GetDef()->GetMinWaterDepth() > 0;
                recoveryFeatures.push_back({f->GetFeatureId(), f->GetPosition(), metal, ship, ship ? rez->GetCostM() : 0.f});
            }
            delete def;
        }
        utils::free_clear(features);
    }
}

float CBuilderManager::GetRecoveryMetal(CCircuitUnit* worker, float radius)
{
    if (worker == nullptr || !std::isfinite(radius) || radius <= 0) return 0.f;
    RefreshRecoveryFeatures();
    circuit->GetThreatMap()->SetThreatType(worker);
    const auto& origin=worker->GetPos(circuit->GetLastFrame());
    float value=0;
    for (const auto& feature : recoveryFeatures) {
        if (!feature.resurrect || origin.SqDistance2D(feature.pos)>radius*radius) continue;
        if (circuit->GetTerrainManager()->CanReachAtSafe2(worker,feature.pos,worker->GetCircuitDef()->GetBuildDistance()))
            value+=feature.metal;
    }
    return value;
}

bool CBuilderManager::ReceiveResurrectionClaim(const char* message)
{
    constexpr const char* prefix = "barb-resurrection ";
    if (std::strncmp(message, prefix, std::strlen(prefix)) != 0) return false;
    // Host-local observation only, not permission to command an allied unit.
    // Bounded payload and live team/capability checks prevent stale ID reuse.
    if (std::strlen(message) > 256) return true;
    std::istringstream input(message + std::strlen(prefix));
    int unitId, count;
    if (!(input >> unitId >> count) || unitId < 0 || count < 0 || count > 5) return true;
    auto* callback = circuit->GetCallback();
    const int team = callback->Unit_Team(unitId);
    const auto* definition = circuit->GetCircuitDef(callback->Unit_GetDefId(unitId));
    if (!circuit->GetAllyTeam()->GetTeamIds().count(team) || definition == nullptr
        || !definition->IsAbleToResurrect()) return true;
    const int frame = circuit->GetLastFrame();
    for (auto entry = relayedResurrections.begin(); entry != relayedResurrections.end();) {
        if (entry->second.expires < frame) entry = relayedResurrections.erase(entry);
        else ++entry;
    }
    if (count == 0) { relayedResurrections.erase(unitId); return true; }
    float parameters[5];
    for (int index = 0; index < count; ++index) if (!(input >> parameters[index])) return true;
    ResurrectionClaim claim;
    if (claim.Decode(parameters, count, callback->Unit_Maximum()))
        relayedResurrections[unitId] = {claim, team, frame + 3 * FRAMES_PER_SEC};
    return true;
}

IBuilderTask* CBuilderManager::FindRecoveryTask(CCircuitUnit* unit, int mode, float radius, const CCircuitDef* preferred,
        int groupLimit, bool highestValue, float combatClearance)
{
    if (unit == nullptr || !unit->GetCircuitDef()->IsAbleToResurrect()
        || !std::isfinite(radius) || radius <= 0 || mode < 0 || mode > 2
        || groupLimit < 1 || !std::isfinite(combatClearance) || combatClearance < 0) return nullptr;
    IUnitTask* current = unit->GetTask();
    if (current != nullptr && (current->GetType() == IUnitTask::Type::PLAYER
        || current->GetType() == IUnitTask::Type::RETREAT || current->IsEnemyReclaim())) return nullptr;
    const int frame = circuit->GetLastFrame();
    const AIFloat3 pos = unit->GetPos(frame);
    const float reach = unit->GetCircuitDef()->GetBuildDistance();
    auto* terrain = circuit->GetTerrainManager();
    circuit->GetThreatMap()->SetThreatType(unit);
    auto* clb = circuit->GetCallback();
    IBuilderTask* old = (current != nullptr && current->GetType() == IUnitTask::Type::BUILDER)
        ? static_cast<IBuilderTask*>(current) : nullptr;
    const auto type = mode == 0 ? IBuilderTask::BuildType::RECLAIM
        : mode == 1 ? IBuilderTask::BuildType::REPAIR : IBuilderTask::BuildType::RESURRECT;
    float best = radius * radius;
    if (mode == 1) {
        CAllyUnit* selected = nullptr;
        // Callback wrapper storage is borrowed for this loop only. Reuse the
        // existing repair task for a target; never abort another worker's job.
        for (Unit* candidate : clb->GetFriendlyUnits()) {
            const int id = candidate->GetUnitId();
            CCircuitDef* def = circuit->GetCircuitDef(clb->Unit_GetDefId(id));
            if (id == unit->GetId() || def == nullptr || !def->IsMobile() || def->IsAbleToFly()
                || def->GetDef()->GetMinWaterDepth() <= 0 || (preferred != nullptr && def != preferred)
                || candidate->IsBeingBuilt() || candidate->GetHealth() >= candidate->GetMaxHealth() * .995f) continue;
            CAllyUnit* ally = circuit->GetFriendlyUnit(candidate);
            if (ally == nullptr || IsReclaimUnit(ally)) continue;
            const AIFloat3 at = candidate->GetPos();
            const float distance = pos.SqDistance2D(at);
            // Opt-in rear repair: use current legal sensor contacts, not global
            // omniscient state. Safe reach also rejects weapon coverage farther
            // away than this script-selected combat buffer. Never cache safety.
            if (combatClearance > 0.f && !clb->GetEnemyUnitIdsIn(at, combatClearance).empty()) continue;
            const bool continuing = old != nullptr && old->GetBuildType() == type
                && static_cast<CBRepairTask*>(old)->GetTargetId() == id;
            if (distance > radius * radius || (!continuing && distance > best)
                || !terrain->CanReachAtSafe2(unit, at, reach)) continue;
            // A still-valid selected repair is sticky within its priority.
            if (old != nullptr && old->GetBuildType() == type
                && static_cast<CBRepairTask*>(old)->GetTargetId() == id) return old;
            best = distance;
            selected = ally;
        }
        if (selected == nullptr) return nullptr;
        IBuilderTask* task = GetRepairTask(selected->GetId());
        if (task == nullptr) {
            task = new CBRepairTask(this, IBuilderTask::Priority::HIGH, selected, FRAMES_PER_SEC * 300);
            ActivateTask(task);
            lastEnqueued = task;
            TaskAdded(task);
        }
        return task;
    }
    RefreshRecoveryFeatures();
    // Observe every friendly resurrection-capable worker, including human
    // allies and different AI binaries. Local task claims alone cannot see
    // them. Read once per selection, never once per wreck; no stale cross-frame
    // claims survive STOP, death, transfer or a changed target. Existing reclaim
    // tasks also pass this admission check on each SEA recovery update.
    std::unordered_set<int> alliedResurrectionFeatures;
    std::vector<ResurrectionClaim> alliedResurrectionAreas;
    if (mode == 0) {
        for (Unit* friendly : clb->GetFriendlyUnits()) {
            const int id = friendly->GetUnitId();
            if (id == unit->GetId()) continue;
            const CCircuitDef* definition = circuit->GetCircuitDef(clb->Unit_GetDefId(id));
            if (definition == nullptr || !definition->IsAbleToResurrect()) continue;
            ResurrectionClaim claim;
            COOAICallback* ownerCallback = nullptr;
            const int team = clb->Unit_Team(id);
            // Recoil restricts command queues to the requesting AI's own team.
            // Same-DLL allies can read through their owning callback on this
            // simulation thread. Human/remote/different-DLL allies use the
            // optional host LuaUI relay, with short-lived observations.
            for (auto* ally : circuit->GetGameAttribute()->GetCircuits()) {
                if (ally->GetTeamId() == team && ally->GetAllyTeamId() == circuit->GetAllyTeamId()) {
                    ownerCallback = ally->GetCallback(); break;
                }
            }
            if (ownerCallback != nullptr) {
                if (!ownerCallback->Unit_ResurrectionClaim(id, frame, claim)) continue;
            } else {
                const auto observation = relayedResurrections.find(id);
                if (observation == relayedResurrections.end() || observation->second.team != team
                    || observation->second.expires < frame) continue;
                claim = observation->second.claim;
            }
            if (claim.featureId >= 0) alliedResurrectionFeatures.insert(claim.featureId);
            else alliedResurrectionAreas.push_back(claim);
        }
    }
    const SRecoveryFeature* selected = nullptr;
    IBuilderTask* selectedTask = nullptr;
    float bestVesselMetal = -1.f;
    for (const auto& f : recoveryFeatures) {
        // Expected O(1) for active feature claims. Unresolved area orders are
        // uncommon and become direct feature commands on the engine update.
        if (mode == 0 && (alliedResurrectionFeatures.count(f.id) != 0
            || std::any_of(alliedResurrectionAreas.begin(), alliedResurrectionAreas.end(),
                [&](const ResurrectionClaim& claim) { return claim.Contains(f.id, f.pos.x, f.pos.z); }))) continue;
        if (mode == 2 && (!f.resurrect || clb->Feature_ResurrectDef(f.id) <= 0)) continue;
        const float distance = pos.SqDistance2D(f.pos);
        const bool continuing = old != nullptr && old->GetBuildType() == type
            && old->GetPosition().SqDistance2D(f.pos) < 64.f;
        const bool valuePriority = mode == 2 && highestValue;
        if (distance > radius * radius || (!continuing && (valuePriority
            ? (f.vesselMetal < bestVesselMetal || (f.vesselMetal == bestVesselMetal && distance > best))
            : distance > best))) continue;
        // Don't fight a different reclaim/resurrection order over one wreck.
        IBuilderTask* reclaim = GetReclaimFeatureTask(f.pos, 8.f);
        IBuilderTask* resurrect = GetResurrectTask(f.pos, 8.f);
        IBuilderTask* matching = mode == 0 ? reclaim : resurrect;
        IBuilderTask* conflicting = mode == 0 ? resurrect : reclaim;
        // Shared native task owns the wreck and completion for the entire
        // group. Default limit one preserves legacy exclusive claims. Only
        // recovery-controlled tasks may be joined; never steal another policy.
        if (conflicting != nullptr && (conflicting != old || conflicting->GetAssignees().size() > 1)) continue;
        if (matching != nullptr && matching != old
            && (groupLimit == 1 || !matching->recoveryControlled || matching->IsDead()
                || matching->GetAssignees().size() >= static_cast<size_t>(groupLimit))) continue;
        if (!terrain->CanReachAtSafe2(unit, f.pos, reach)) continue;
        if (continuing) {
            old->recoveryControlled = true; // re-adopt a restored native task after load
            return old;
        }
        best = distance;
        bestVesselMetal = f.vesselMetal;
        selected = &f;
        selectedTask = matching;
    }
    if (selected == nullptr) return nullptr;
    // Guard the admission invariant as this selector evolves; this is one
    // final membership check, not a second engine scan or a new command.
    if (mode == 0 && (alliedResurrectionFeatures.count(selected->id) != 0
        || std::any_of(alliedResurrectionAreas.begin(), alliedResurrectionAreas.end(),
            [&](const ResurrectionClaim& claim) { return claim.Contains(selected->id, selected->pos.x, selected->pos.z); }))) {
        circuit->LOG("[INVARIANT] INV-183 recovery selected allied resurrection feature=%i", selected->id);
        return nullptr;
    }
    if (selectedTask != nullptr) return selectedTask;
    IBuilderTask* task = mode == 0
        ? Enqueue(TaskB::Reclaim(IBuilderTask::Priority::HIGH, selected->pos, selected->metal, FRAMES_PER_SEC * 300, 8.f))
        : Enqueue(TaskB::Resurrect(IBuilderTask::Priority::HIGH, selected->pos, selected->metal, FRAMES_PER_SEC * 300, 8.f));
    task->recoveryControlled = true;
    return task;
}

IBuilderTask* CBuilderManager::EnqueueRepairFor(CAllyUnit* target, int timeout, CCircuitUnit* commander)
{
    if (target == nullptr) return nullptr;
    IBuilderTask* task = GetRepairTask(target->GetId());
    if (task == nullptr) {
        // Same construction as FindRecoveryTask's repair branch.
        task = new CBRepairTask(this, IBuilderTask::Priority::HIGH, target, timeout);
        ActivateTask(task);
        lastEnqueued = task;
        TaskAdded(task);
    }
    if (commander != nullptr) {
        if (auto* repair = dynamic_cast<CBRepairTask*>(task)) repair->InviteCommander(commander->GetId());
    }
    return task;
}

IBuilderTask* CBuilderManager::MakeCommTask(CCircuitUnit* unit, const CQueryCostMap* query, float sqMaxBaseRange)
{
	CThreatMap* threatMap = circuit->GetThreatMap();
	threatMap->SetThreatType(unit);
	const IBuilderTask* task = nullptr;
	const int frame = circuit->GetLastFrame();
	const AIFloat3& pos = unit->GetPos(frame);
//	CTerrainManager::CorrectPosition(pos);

	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	task = economyMgr->CheckMobileAssistRequired(pos, unit);
	if (task != nullptr) {
		return const_cast<IBuilderTask*>(task);
	}

	economyMgr->MakeEconomyTasks(pos, unit);
	const bool isNotReady = !economyMgr->IsExcessed();

	CMetalManager* metalMgr = circuit->GetMetalManager();
	const CMetalData::Clusters& clusters = metalMgr->GetClusters();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CInfluenceMap* inflMap = circuit->GetInflMap();
	CPathFinder* pathfinder = circuit->GetPathfinder();

	CCircuitDef* cdef = unit->GetCircuitDef();
	const float maxSpeed = cdef->GetSpeed() / pathfinder->GetSquareSize() * COST_BASE;
	const int buildDistance = std::max<int>(cdef->GetBuildDistance(), pathfinder->GetSquareSize());
	const float buildSqDistance = SQUARE(buildDistance);
	const AIFloat3& basePos = circuit->GetSetupManager()->GetBasePos();
	float metric = std::numeric_limits<float>::max();

	// Help early economy by weights
	const float toBaseDist = pos.distance2D(circuit->GetSetupManager()->GetBasePos());
	const float toCenterDist = pos.distance2D(terrainMgr->GetTerrainCenter());  // circuit->GetEnemyManager()->GetEnemyPos()
	const float baseDivEnemy = toBaseDist / toCenterDist;
	const float enemyDivBase = 1.f / baseDivEnemy;
	const float energyDivMetal = economyMgr->GetAvgEnergyIncome() * economyMgr->GetEcoEM() / economyMgr->GetAvgMetalIncome();
	const float metalDivEnergy = 1.f / energyDivMetal;
	std::array<float, (int)IBuilderTask::BuildType::_SIZE_> taskWeights;
	taskWeights.fill(1.f);
	taskWeights[(int)IBuilderTask::BuildType::ENERGY]  = baseDivEnemy * energyDivMetal * 8.f;
	taskWeights[(int)IBuilderTask::BuildType::DEFENCE] = (inflMap->GetEnemyInflAt(pos) < INFL_EPS) ? enemyDivBase : (baseDivEnemy * 2.f);
	taskWeights[(int)IBuilderTask::BuildType::RADAR]   = enemyDivBase;
	taskWeights[(int)IBuilderTask::BuildType::SONAR]   = enemyDivBase;
	taskWeights[(int)IBuilderTask::BuildType::MEX]     = baseDivEnemy * metalDivEnergy;

	for (const std::set<IBuilderTask*>& tasks : buildTasks) {
		for (const IBuilderTask* candidate : tasks) {
			if (!candidate->CanAssignTo(unit)
				|| (isNotReady
					&& (candidate->GetBuildDef() != nullptr)
					&& (candidate->GetPriority() != IBuilderTask::Priority::NOW)))
			{
				continue;
			}

			// Check time-distance to target
			const AIFloat3& bp = candidate->GetPosition();
			AIFloat3 buildPos = geom::is_valid(bp) ? bp : pos;

			if (candidate->GetPriority() == IBuilderTask::Priority::NOW) {
				// Disregard safety
				if (!terrainMgr->CanReachAt(unit, buildPos, cdef->GetBuildDistance())) {  // ensure that path always exists
					continue;
				}

			} else {

				int index = metalMgr->FindNearestCluster(buildPos);
				const AIFloat3& testPos = (index < 0) ? buildPos : clusters[index].position;
				if ((basePos.SqDistance2D(testPos) > sqMaxBaseRange)
					|| !terrainMgr->CanReachAt(unit, buildPos, cdef->GetBuildDistance())  // ensure that path always exists
					|| (inflMap->GetInfluenceAt(testPos) < -INFL_EPS))  // safety check
				{
					continue;
				}
				/*
				 * Essence of MakeCommDangerTask
				 */
//				if ((basePos.SqDistance2D(buildPos) > sqMaxBaseRange)
//					|| !terrainMgr->CanReachAtSafe(unit, buildPos, cdef->GetBuildDistance())  // ensure that path always exists
//					|| (inflMap->GetEnemyInflAt(buildPos) > INFL_EPS))  // safety check
//				{
//					continue;
//				}
			}

			float distCost;
			const float rawSqDist = pos.SqDistance2D(buildPos);
			const bool isClose = rawSqDist < buildSqDistance;
			if (isClose) {
				distCost = sqrtf(rawSqDist) / pathfinder->GetSquareSize() * COST_BASE * 0.5f;
			} else {
				distCost = query->GetCostAt(buildPos, buildDistance);
				if (distCost < 0.f) {  // path blocked by buildings or threat too high
					continue;
				}
			}

			distCost = std::max(distCost, COST_BASE);

			float weight = (static_cast<float>(candidate->GetPriority()) + 1.0f);
			weight = 1.0f / SQUARE(weight) * taskWeights[(int)candidate->GetBuildType()];
			bool valid = distCost * weight < metric;

			if (valid && !isClose) {
				CCircuitUnit* target = candidate->GetTarget();
				if (target != nullptr) {
					Unit* tu = target->GetUnit();
					const float maxHealth = tu->GetMaxHealth();
					const float health = tu->GetHealth() - maxHealth * 0.005f;
					const float healthSpeed = maxHealth * candidate->GetBuildPowerM() / candidate->GetCostM();
					valid = ((maxHealth - health) * 0.6f) * maxSpeed > healthSpeed * distCost;
				} else {
					valid = distCost < MAX_TRAVEL_SEC * maxSpeed;
				}
			}

			if (valid) {
				task = candidate;
				metric = distCost * weight;
			}
		}
	}

	if ((task == nullptr) &&
		((unit->GetTask()->GetType() != IUnitTask::Type::BUILDER) || (static_cast<IBuilderTask*>(unit->GetTask())->GetBuildType() != IBuilderTask::BuildType::GUARD)))
	{
		CCircuitUnit* vip = circuit->GetFactoryManager()->GetClosestFactory(pos);
		if (vip != nullptr) {
			task = EnqueueB(TaskB::Guard(IBuilderTask::Priority::NORMAL, vip, true, FRAMES_PER_SEC * 60));
		} else {
			task = EnqueueB(TaskB::Patrol(IBuilderTask::Priority::LOW, pos, FRAMES_PER_SEC * 5));
		}
	}

	return const_cast<IBuilderTask*>(task);
}

IBuilderTask* CBuilderManager::MakeBuilderTask(CCircuitUnit* unit, const CQueryCostMap* query)
{
	CThreatMap* threatMap = circuit->GetThreatMap();
	threatMap->SetThreatType(unit);
	const IBuilderTask* task = nullptr;
	const int frame = circuit->GetLastFrame();
	const AIFloat3& pos = unit->GetPos(frame);
//	CTerrainManager::CorrectPosition(pos);

	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	task = economyMgr->CheckMobileAssistRequired(pos, unit);
	if (task != nullptr) {
		return const_cast<IBuilderTask*>(task);
	}

	// FIXME: MakeEconomyTasks doesn't check CanAssignTo() and may create task irrelevant for unit
	/*task = */economyMgr->MakeEconomyTasks(pos, unit);
//	if (task != nullptr) {
//		return const_cast<IBuilderTask*>(task);
//	}

	const bool isStalling = economyMgr->IsMetalEmpty() &&
							(economyMgr->GetAvgMetalIncome() * 1.2f < economyMgr->GetMetalPull()) &&
							(metalPull > economyMgr->GetPullMtoS() * circuit->GetFactoryManager()->GetMetalPull());
	const bool isNotReady = !economyMgr->IsExcessed() || isStalling/* || economyMgr->IsEnergyStalling()*/;

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CInfluenceMap* inflMap = circuit->GetInflMap();
	CPathFinder* pathfinder = circuit->GetPathfinder();

	CCircuitDef* cdef = unit->GetCircuitDef();
	const float maxThreat = threatMap->GetUnitPower(unit);
	std::function<bool (const AIFloat3&)> checkThreat;
	if (cdef->IsAbleToFly()) {
		checkThreat = [threatMap, maxThreat](const AIFloat3& pos) {
			return threatMap->GetThreatAt(pos) > maxThreat;
		};
	} else {
		checkThreat = [threatMap, maxThreat](const AIFloat3& pos) {
			return threatMap->GetThreatAt(pos) > maxThreat || threatMap->GetBuilderThreatAt(pos) > maxThreat;
		};
	}
	const float maxSpeed = cdef->GetSpeed() / pathfinder->GetSquareSize() * COST_BASE;
	const int buildDistance = std::max<int>(cdef->GetBuildDistance(), pathfinder->GetSquareSize());
	const float buildSqDistance = SQUARE(buildDistance);
	float metric = std::numeric_limits<float>::max();
	for (const std::set<IBuilderTask*>& tasks : buildTasks) {
		for (const IBuilderTask* candidate : tasks) {
			if (!candidate->CanAssignTo(unit)
				|| (isNotReady
					&& (candidate->GetPriority() != IBuilderTask::Priority::NOW)
					&& (candidate->GetBuildDef() != nullptr)
					&& !economyMgr->IsIgnoreStallingPull(candidate)))
			{
				continue;
			}

			// Check time-distance to target
			const AIFloat3& bp = candidate->GetPosition();
			AIFloat3 buildPos = geom::is_valid(bp) ? bp : pos;

			if (candidate->GetPriority() == IBuilderTask::Priority::NOW) {
				// Disregard safety
				if (!terrainMgr->CanReachAt(unit, buildPos, cdef->GetBuildDistance())) {  // ensure that path always exists
					continue;
				}

			} else {

				CCircuitDef* buildDef = candidate->GetBuildDef();
				const float buildThreat = (buildDef != nullptr) ? buildDef->GetPower() : 0.f;
				if (!terrainMgr->CanReachAt(unit, buildPos, cdef->GetBuildDistance())  // ensure that path always exists
					|| ((buildThreat < THREAT_MIN) && checkThreat(buildPos) && (inflMap->GetInfluenceAt(buildPos) < -INFL_EPS)))  // safety check
				{
					continue;
				}
			}

			float distCost;
			const float rawSqDist = pos.SqDistance2D(buildPos);  // TODO: add target's radius to rawSqDist
			const bool isClose = rawSqDist < buildSqDistance;
			if (rawSqDist < buildSqDistance) {
				distCost = sqrtf(rawSqDist) / pathfinder->GetSquareSize() * COST_BASE * 0.5f;
			} else {
				distCost = query->GetCostAt(buildPos, buildDistance);
				if (distCost < 0.f) {  // path blocked by buildings or threat too high
					continue;
				}
			}

			distCost = std::max(distCost, COST_BASE);

			float weight = (static_cast<float>(candidate->GetPriority()) + 1.0f);
			weight = 1.0f / SQUARE(weight);
			bool valid = distCost * weight < metric;

			if (valid && !isClose) {
				CCircuitUnit* target = candidate->GetTarget();
				if (target != nullptr) {
					// BA: float time_to_build = targetDef->GetBuildTime() / workerDef->GetBuildSpeed();
					Unit* tu = target->GetUnit();
					const float maxHealth = tu->GetMaxHealth();
					const float health = tu->GetHealth() - maxHealth * 0.005f;
					const float healthSpeed = maxHealth * candidate->GetBuildPowerM() / candidate->GetCostM();
					valid = ((maxHealth - health) * 0.6f) * maxSpeed > healthSpeed * distCost;
				} else {
					// valid = distCost < MAX_TRAVEL_SEC * maxSpeed;  // NOTE: distCost was too high in sectors occupied by structure
				}
			}

			if (valid) {
				task = candidate;
				metric = distCost * weight;
			}
		}
	}

	if (task == nullptr) {
		if ((unit->GetTask() != idleTask) || isNotReady) {
			return nullptr;  // current task is in danger or unreachable
		}
		task = CreateBuilderTask(pos, unit);
	}

	return const_cast<IBuilderTask*>(task);
}

IBuilderTask* CBuilderManager::CreateBuilderTask(const AIFloat3& position, CCircuitUnit* unit)
{
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	if (terrainMgr->IsZoneAlly(position)) {
		return EnqueueB(TaskB::Patrol(IBuilderTask::Priority::LOW, position, FRAMES_PER_SEC * 10));
	}

	CEconomyManager* ecoMgr = circuit->GetEconomyManager();
	IBuilderTask* task = ecoMgr->UpdateEnergyTasks(position, unit);
	if (task != nullptr) {
		return task;
	}
	task = ecoMgr->UpdateReclaimTasks(position, unit, false);
//	if (task != nullptr) {
//		return task;
//	}

	// FIXME: Eco rules. It should never get here
	CMilitaryManager* militaryMgr = circuit->GetMilitaryManager();
	const float energyIncome = ecoMgr->GetAvgEnergyIncome() * ecoMgr->GetEcoFactor();
	const float metalIncome = std::min(ecoMgr->GetAvgMetalIncome() * ecoMgr->GetEcoFactor(), energyIncome);
	if ((metalIncome >= super.minIncome) && (energyIncome * ecoMgr->GetEcoEM() >= super.minIncome)) {
		CCircuitDef* buildDef = militaryMgr->GetBigGunDef();
		if ((buildDef != nullptr) && (buildDef->GetCostM() < super.maxTime * metalIncome)
			&& ((buildDef->GetWeaponDef() == nullptr) || (energyIncome > buildDef->GetWeaponDef()->GetCostE() * 2)))
		{
			const std::set<IBuilderTask*>& tasks = GetTasks(IBuilderTask::BuildType::BIG_GUN);
			if (tasks.empty()) {
				if (buildDef->IsAvailable(circuit->GetLastFrame())
					&& militaryMgr->IsNeedBigGun(buildDef)
					&& unit->GetCircuitDef()->CanBuild(buildDef))
				{
					AIFloat3 pos = militaryMgr->GetBigGunPos(buildDef);
					return Enqueue(TaskB::Common(IBuilderTask::BuildType::BIG_GUN,
								   IBuilderTask::Priority::NORMAL, buildDef, pos));
				}
			} else if (unit->GetCircuitDef()->CanBuild(buildDef)) {
				return *tasks.begin();
			}
		}
	}

	CCircuitUnit* vip = unit->GetCircuitDef()->IsAbleToAssist()
			? circuit->GetFactoryManager()->GetClosestFactory(position)
			: militaryMgr->GetClosestLeader({IFighterTask::FightType::ATTACK, IFighterTask::FightType::DEFEND}, position);
	if (vip != nullptr) {
		return EnqueueB(TaskB::Guard(IBuilderTask::Priority::NORMAL, vip, true, FRAMES_PER_SEC * 60));
	}

	CSetupManager* setupMgr = circuit->GetSetupManager();
	if (setupMgr->GetCommander() != nullptr) {
		return EnqueueB(TaskB::Guard(IBuilderTask::Priority::LOW, setupMgr->GetCommander(), true, FRAMES_PER_SEC * 20));
	}
	return EnqueueB(TaskB::Patrol(IBuilderTask::Priority::LOW, position, FRAMES_PER_SEC * 20));
}

void CBuilderManager::AddBuildList(CCircuitUnit* unit, int hiddenDefs)
{
	CCircuitDef* cDef = unit->GetCircuitDef();
	if (cDef->GetCount() - hiddenDefs > 1) {
		return;
	}

	const std::unordered_set<CCircuitDef::Id>& buildOptions = cDef->GetBuildOptions();
	std::set<CCircuitDef*> buildDefs;
	for (CCircuitDef::Id build : buildOptions) {
		CCircuitDef* cdef = circuit->GetCircuitDef(build);
		if (cdef->GetBuildCount() == 0) {
			buildDefs.insert(cdef);
		}
		cdef->IncBuild();
	}

	if (!buildDefs.empty()) {
		circuit->GetEconomyManager()->AddEconomyDefs(buildDefs);
		circuit->GetMilitaryManager()->AddSensorDefs(buildDefs);
	}
}

void CBuilderManager::RemoveBuildList(CCircuitUnit* unit, int hiddenDefs)
{
	CCircuitDef* cDef = unit->GetCircuitDef();
	if (cDef->GetCount() - hiddenDefs > 1) {
		return;
	}

	const std::unordered_set<CCircuitDef::Id>& buildOptions = cDef->GetBuildOptions();
	std::set<CCircuitDef*> buildDefs;
	for (CCircuitDef::Id build : buildOptions) {
		CCircuitDef* cdef = circuit->GetCircuitDef(build);
		cdef->DecBuild();
		if (cdef->GetBuildCount() == 0) {
			buildDefs.insert(cdef);
		}
	}

	if (!buildDefs.empty()) {  // throws exception on set::erase otherwise
		circuit->GetEconomyManager()->RemoveEconomyDefs(buildDefs);
		circuit->GetMilitaryManager()->RemoveSensorDefs(buildDefs);
	}
}

void CBuilderManager::Watchdog()
{
	ZoneScopedN(__PRETTY_FUNCTION__);

	const int frame = circuit->GetLastFrame();
    const bool legacyDue = frame >= nextLegacyWatchdog;
    if (legacyDue) nextLegacyWatchdog = frame + 60 * FRAMES_PER_SEC;
    if (!recoverConstruction && !legacyDue) return;
    if (recoverConstruction && experimentalBuild) {
        // Recovery of old queued chains after load/role adoption. These exact
        // task kinds are refused by FindQueuedTask: counting one forever can
        // block a layout prerequisite (played: 4 nanos + one timeout=0 ghost).
        // Do not cancel a frame or detach productive owners. Enqueue/pin is
        // atomic within a callback, so no new layout order is half-pinned here.
        std::vector<IBuilderTask*> abandoned;
        for (const auto& byType : buildTasks) for (auto* task : byType) {
            if (!task->IsDead() && IsLayoutEconomy(task->GetBuildType()) && !task->IsLayoutOwned()
                && !task->GetTarget() && task->GetAssignees().empty()) abandoned.push_back(task);
        }
        for (auto* task : abandoned) {
            circuit->LOG("BUILD_RECOVERY: team=%d action=discard-unowned-chain def=%s",circuit->GetTeamId(),task->GetBuildDef()->GetDef()->GetName());
            AbortTask(task);
        }
    }
    // Opt-in fixture diagnostics: a queued task can block a script prerequisite
    // even without a worker owning it. No callbacks/logging in normal games.
    static const bool traceConstruction = std::getenv("CIRCUIT_BUILD_TRACE") != nullptr;
    if (recoverConstruction && legacyDue && traceConstruction) {
        for (const auto& byType : buildTasks) for (const auto* task : byType) {
            if (task->IsDead() || task->GetTarget() || !task->GetBuildDef()) continue;
            const auto& p = task->GetPosition();
            circuit->LOG("BUILD_QUEUE: def=%s kind=%d owners=%u touched=%d timeout=%d layout=%d slot=%d power=%.2f pos=%.0f,%.0f",
                task->GetBuildDef()->GetDef()->GetName(), int(task->GetBuildType()), unsigned(task->GetAssignees().size()),
                task->GetLastTouched(), task->GetTimeout(), int(task->IsLayoutOwned()), task->GetReservationId(),
                task->GetBuildPowerM(), p.x, p.z);
            for (auto* owner : task->GetAssignees()) circuit->LOG("BUILD_QUEUE: owner=%d current=%d matches=%d commands=%d",
                owner->GetId(), int(owner->GetTask()->GetType()), int(owner->GetTask()==task), int(circuit->GetCallback()->Unit_HasCommands(owner->GetId())));
            for (auto* worker : workers) if (worker->GetCircuitDef()->CanBuild(task->GetBuildDef())) {
                circuit->LOG("BUILD_QUEUE: candidate=%d can=%d reachable=%d", worker->GetId(), int(task->CanAssignTo(worker)),
                    int(!geom::is_valid(p) || circuit->GetTerrainManager()->CanReachAtSafe(worker,p,worker->GetCircuitDef()->GetBuildDistance())));
            }
        }
    }
	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	Resource* metalRes = economyMgr->GetMetalRes();
	// somehow workers get stuck
	for (CCircuitUnit* worker : workers) {
        IUnitTask* current = worker->GetTask();
        if (recoverConstruction && current == idleTask) {
            const bool listed = idleTask->GetAssignees().count(worker) != 0;
            if (legacyDue && traceConstruction) circuit->LOG("BUILD_IDLE: team=%d worker=%d listed=%d taskFrame=%d state=%d commands=%d",
                circuit->GetTeamId(),worker->GetId(),int(listed),worker->GetTaskFrame(),int(worker->GetTaskState()),
                int(circuit->GetCallback()->Unit_HasCommands(worker->GetId())));
            if (!listed) {
                // Restore the exact idle owner's scheduling membership. This
                // does not choose a build or interrupt a command; without it
                // the normal idle slice can never ask this worker for a job.
                circuit->LOG("BUILD_RECOVERY: team=%d builder=%d action=restore-idle-membership",circuit->GetTeamId(),worker->GetId());
                idleTask->AssignTo(worker);
            }
        }
        if (recoverConstruction && current && current->GetType() == IUnitTask::Type::BUILDER) {
            auto* build = static_cast<IBuilderTask*>(current);
            if (build->GetBuildDef() && build->GetBuildType() < IBuilderTask::BuildType::REPAIR) {
                build->RecoverConstruction(worker, std::max(5, constructionRetrySeconds) * FRAMES_PER_SEC,
                    std::max(constructionRetrySeconds + 5, constructionReleaseSeconds) * FRAMES_PER_SEC);
                continue; // one recovery owner; no random radial move from legacy watchdog
            }
        }
        if (!legacyDue) continue;
		if (CCircuitUnit::ETaskState::EXECUTE != worker->GetTaskState()) {  // FIXME: Doesn't deal with Reclaim and Resurrect of Features
			continue;
		}
		IUnitTask* task = worker->GetTask();
		bool isLost = !circuit->GetCallback()->Unit_HasCommands(worker->GetId());
		if (!isLost && (task->GetType() == IUnitTask::Type::BUILDER)) {
			IBuilderTask* taskB = static_cast<IBuilderTask*>(task);
			Unit* u = worker->GetUnit();
			if (u->GetVel().SqLength2D() < 1e-3f) {  // FIXME: turn in-place may produce false-positive
				if ((taskB->GetBuildType() == IBuilderTask::BuildType::RECLAIM) && (taskB->GetTarget() != nullptr)) {
					const AIFloat3& pos = worker->GetPos(circuit->GetLastFrame());
					const float objRadius = taskB->GetTarget()->GetCircuitDef()->GetRadius();
					isLost = taskB->GetPosition().SqDistance2D(pos) > SQUARE(worker->GetCircuitDef()->GetBuildDistance() + objRadius);
				} else if (!worker->IsWaiting() && (taskB->GetBuildDef() != nullptr) && (u->GetResourceUse(metalRes) < 1e-3f)) {
					const AIFloat3& pos = worker->GetPos(circuit->GetLastFrame());
					const float objRadius = taskB->GetBuildDef()->GetRadius();
					isLost = taskB->GetPosition().SqDistance2D(pos) > SQUARE(worker->GetCircuitDef()->GetBuildDistance() + objRadius);
				}
			}
		}
		if (isLost) {
			if (experimentalBuild) {
				// D-066 diagnostics: a builder standing still with no resource
				// use outside its range - or with its command queue empty.
				const AIFloat3& wpos = worker->GetPos(circuit->GetLastFrame());
				const IBuilderTask* taskB = (task->GetType() == IUnitTask::Type::BUILDER) ? static_cast<const IBuilderTask*>(task) : nullptr;
				const AIFloat3 tpos = (taskB != nullptr) ? taskB->GetPosition() : AIFloat3(-RgtVector);
				circuit->LOG("EXP: watchdog: %s(%i) lost on %s at (%.0f, %.0f), site (%.0f, %.0f), dist %.0f, reach %.0f, commands %s, waiting %s",
						worker->GetCircuitDef()->GetDef()->GetName(), worker->GetId(),
						((taskB != nullptr) && (taskB->GetBuildDef() != nullptr)) ? taskB->GetBuildDef()->GetDef()->GetName() : "task",
						wpos.x, wpos.z, tpos.x, tpos.z, std::sqrt(wpos.SqDistance2D(tpos)),
						worker->GetCircuitDef()->GetBuildDistance() + (((taskB != nullptr) && (taskB->GetBuildDef() != nullptr)) ? taskB->GetBuildDef()->GetRadius() : 0.f),
						circuit->GetCallback()->Unit_HasCommands(worker->GetId()) ? "yes" : "no", worker->IsWaiting() ? "yes" : "no");
			}
			task->OnUnitMoveFailed(worker);
		}
	}

	if (!legacyDue) return;

	// find unfinished abandoned buildings
	float maxCost = MAX_BUILD_SEC * std::min(economyMgr->GetAvgMetalIncome(), buildPower) * economyMgr->GetEcoFactor();
	// TODO: Include special units
	for (auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if (!unit->GetCircuitDef()->IsMobile()
			&& (unfinishedUnits.find(unit) == unfinishedUnits.end())
			&& (repairUnits.find(unit->GetId()) == repairUnits.end())
			&& !IsReclaimUnit(unit))
		{
			Unit* u = unit->GetUnit();
			if (!unit->IsFinished()) {  // u->IsBeingBuilt()
				float maxHealth = u->GetMaxHealth();
				float buildPercent = (maxHealth - u->GetHealth()) / maxHealth;
				CCircuitDef* cdef = unit->GetCircuitDef();
				// D-290: a reclaim-protected frame (TECH: energy storage) is finished, never torn down
				if ((cdef->GetBuildTime() * buildPercent < maxCost) || cdef->IsMex() || (*cdef == *terraDef)
					|| IsReclaimProtected(cdef))
				{
					Enqueue(TaskB::Repair(IBuilderTask::Priority::NORMAL, unit));
				} else {
					Enqueue(TaskB::Reclaim(IBuilderTask::Priority::NORMAL, unit));
				}
//			} else if (u->GetHealth() < u->GetMaxHealth()) {
//				Enqueue(TaskB::Repair(IBuilderTask::Priority::NORMAL, unit));
			}
		}
	}
}

void CBuilderManager::UpdateAreaUsers()
{
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	buildAreas.clear();
	for (auto mtId : workerMobileTypes) {
		for (auto& area : terrainMgr->GetMobileTypeById(mtId)->area) {
			buildAreas[&area] = std::map<CCircuitDef*, int>();
		}
	}
	buildAreas[nullptr] = std::map<CCircuitDef*, int>();  // air

	for (auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		if (workerDefs.find(unit->GetCircuitDef()) != workerDefs.end()) {
			++buildAreas[unit->GetArea()][unit->GetCircuitDef()];
		}
	}

	std::set<IBuilderTask*> removeTasks;
	for (auto& tasks : buildTasks) {
		for (IBuilderTask* task : tasks) {
			CCircuitDef* cdef = task->GetBuildDef();
			if ((cdef != nullptr) && (task->GetTarget() == nullptr) && !IsBuilderInArea(cdef, task->GetPosition())) {
				removeTasks.insert(task);
			}
		}
	}
	for (IBuilderTask* task : removeTasks) {
		AbortTask(task);
	}
}

void CBuilderManager::Load(std::istream& is)
{
	/*
	 * Restore data
	 */
	circuit->GetTerrainManager()->LoadLayout(is);  // before the tasks: they hold reservation ids (CR-003)
	for (size_t i = 0; i < buildTasks.size(); ++i) {
		uint32_t size;
		utils::binary_read(is, size);
#ifdef DEBUG_SAVELOAD
		circuit->LOG("%s | buildType=%i | size=%i", __PRETTY_FUNCTION__, i, size);
#endif
		for (unsigned j = 0; j < size; ++j) {
			IBuilderTask* task = nullptr;
			bool isGeneric = false;
			utils::binary_read(is, isGeneric);
			if (isGeneric) {
				task = new CBGenericTask(this, IBuilderTask::BuildType(i));
			} else switch (IBuilderTask::BuildType(i)) {
				case IBuilderTask::BuildType::FACTORY: {
					task = new CBFactoryTask(this);
				} break;
				case IBuilderTask::BuildType::NANO: {
					task = new CBNanoTask(this);
				} break;
				case IBuilderTask::BuildType::STORE: {
					task = new CBStoreTask(this);
				} break;
				case IBuilderTask::BuildType::PYLON: {
					task = new CBPylonTask(this);
				} break;
				case IBuilderTask::BuildType::ENERGY: {
					task = new CBEnergyTask(this);
				} break;
				case IBuilderTask::BuildType::GEO: {
					task = new CBGeoTask(this);
				} break;
//				case IBuilderTask::BuildType::GEOUP: {
//				} break;
				case IBuilderTask::BuildType::DEFENCE: {
					task = new CBDefenceTask(this);
				} break;
				case IBuilderTask::BuildType::BUNKER: {
					task = new CBBunkerTask(this);
				} break;
				case IBuilderTask::BuildType::BIG_GUN: {
					task = new CBBigGunTask(this);
				} break;
				case IBuilderTask::BuildType::RADAR: {
					task = new CBRadarTask(this);
				} break;
				case IBuilderTask::BuildType::SONAR: {
					task = new CBSonarTask(this);
				} break;
				case IBuilderTask::BuildType::CONVERT: {
					task = new CBConvertTask(this);
				} break;
				case IBuilderTask::BuildType::MEX: {
					task = new CBMexTask(this);
				} break;
				case IBuilderTask::BuildType::MEXUP: {
					task = new CBMexUpTask(this);
				} break;
				case IBuilderTask::BuildType::REPAIR: {
					task = new CBRepairTask(this);
				} break;
				case IBuilderTask::BuildType::RECLAIM: {
					task = new CBReclaimTask(this);
				} break;
				case IBuilderTask::BuildType::RESURRECT: {
					task = new CBResurrectTask(this);
				} break;
				case IBuilderTask::BuildType::TERRAFORM: {
					task = new CBTerraformTask(this);
				} break;
				default: break;
			}
			if (task != nullptr) {
				bool isValid = is >> *task;
				if (circuit->GetEconomyManager()->IsMetalConverter(task->GetBuildDef())
					&& task->GetBuildType() < IBuilderTask::BuildType::REPAIR) isValid = false;
				buildTasks[i].insert(task);
				buildTasksCount++;
				updateTasks.push_back(task);
				if (!isValid) {
#ifdef DEBUG_SAVELOAD
					circuit->LOG("Invalid task");
#endif
					AbortTask(task);
				}
			}
		}
	}
}

void CBuilderManager::Save(std::ostream& os) const
{
	/*
	 * Save tasks
	 */
	circuit->GetTerrainManager()->SaveLayout(os);
	for (size_t i = 0; i < buildTasks.size(); ++i) {
		const std::set<IBuilderTask*>& tasks = buildTasks[i];
		uint32_t size = tasks.size();
		if ((size > 0) && ((*tasks.begin())->GetBuildType() == IBuilderTask::BuildType::PYLON)) {
			// FIXME: Get pylon's link
			size = 0;
			utils::binary_write(os, size);
#ifdef DEBUG_SAVELOAD
			circuit->LOG("%s | buildType=%i | size=%i", __PRETTY_FUNCTION__, i, size);
#endif
			continue;
		}

		utils::binary_write(os, size);
#ifdef DEBUG_SAVELOAD
		circuit->LOG("%s | buildType=%i | size=%i", __PRETTY_FUNCTION__, i, size);
#endif
		for (const IBuilderTask* task : tasks) {
			utils::binary_write(os, task->IsGeneric());
			os << *task;
		}
	}
}

#ifdef DEBUG_VIS
void CBuilderManager::Log()
{
	for (const std::set<IBuilderTask*>& tasks : buildTasks) {
		for (const IBuilderTask* task : tasks) {
			std::string desc = (task->GetBuildDef() != nullptr) ? task->GetBuildDef()->GetDef()->GetName() : "?";
			desc += utils::int_to_string(static_cast<int>(task->GetBuildType()), "|%i");
			circuit->GetDrawer()->AddPoint(task->GetPosition(), desc.c_str());
		}
	}
}
#endif

} // namespace circuit
