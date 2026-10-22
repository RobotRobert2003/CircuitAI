/*
 * MilitaryManager.cpp
 *
 *  Created on: Sep 5, 2014
 *      Author: rlcevg
 */

#include "module/MilitaryManager.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/FactoryManager.h"
#include "map/InfluenceMap.h"
#include "map/ThreatMap.h"
#include "resource/MetalManager.h"
#include "scheduler/Scheduler.h"
#include "script/MilitaryScript.h"
#include "setup/SetupManager.h"
#include "setup/DefenceData.h"
#include "task/NilTask.h"
#include "task/IdleTask.h"
#include "task/common/ExternalControlTask.h"
#include "task/common/WaitTask.h"
#include "task/RetreatTask.h"
#include "task/builder/DefenceTask.h"
#include "task/fighter/RallyTask.h"
#include "task/fighter/GuardTask.h"
#include "task/fighter/RouteTask.h"
#include "task/fighter/FerryTask.h"
#include "task/fighter/AirWaveTask.h"
#include "task/fighter/DefendTask.h"
#include "task/fighter/ScoutTask.h"
#include "task/fighter/RaidTask.h"
#include "task/fighter/AttackTask.h"
#include "task/fighter/BombTask.h"
#include "task/fighter/ArtilleryTask.h"
#include "task/fighter/RangedWorld.h"
#include "task/fighter/AntiAirTask.h"
#include "task/fighter/AntiHeavyTask.h"
#include "task/fighter/SupportTask.h"
#include "task/fighter/SquadTask.h"
#include "task/static/SuperTask.h"
#include "terrain/TerrainManager.h"
#include "terrain/path/PathFinder.h"
#include "terrain/path/QueryPathMulti.h"
#include "unit/enemy/EnemyUnit.h"
#include "CircuitAI.h"
#include "util/GameAttribute.h"
#include "util/Utils.h"
#include "util/Profiler.h"
#include "json/json.h"

#include "spring/SpringCallback.h"
#include "Game.h"
#include "spring/SpringMap.h"

#include "AISCommands.h"
#include "Log.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <map>

namespace circuit {

void CMilitaryManager::SetAggressionDelta(float value)
{
    if(std::isfinite(value)) aggressionDelta=std::clamp(value,-1.f,1.f);
}
void CMilitaryManager::SetAutomaticAggression(float value)
{
    if(std::isfinite(value)) automaticAggression=std::clamp(value,-1.f,1.f);
}

using namespace springai;
using namespace terrain;

CMilitaryManager::CMilitaryManager(CCircuitAI* circuit)
		: ITaskModule(circuit, new CMilitaryScript(circuit->GetScriptManager(), this))
		, defenceIdx(0)
		, isEnemyFound(false)
		, armyCost(0.f)
		, bigGunDef(nullptr)
{
	circuit->GetScheduler()->RunOnInit(CScheduler::GameJob(&CMilitaryManager::Init, this));

	defence = circuit->GetAllyTeam()->GetDefenceData().get();

	fightTasks.resize(static_cast<IFighterTask::FT>(IFighterTask::FightType::_SIZE_));
}

CMilitaryManager::~CMilitaryManager()
{
}

void CMilitaryManager::InitHandlers()
{
	/*
	 * Attacker handlers
	 */
	auto attackerCreatedHandler = [this](CCircuitUnit* unit, CCircuitUnit* builder) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			nilTask->AssignTo(unit);
			this->circuit->AddActionUnit(unit);
		}
	};
	auto attackerFinishedHandler = [this](CCircuitUnit* unit) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			this->circuit->AddActionUnit(unit);
		}
		nilTask->RemoveAssignee(unit);
		idleTask->AssignTo(unit);

		army.insert(unit);
        if (externalOwnerDefinitions.count(unit->GetCircuitDef()->GetId())) externalOwnerCandidates.insert(unit->GetId());
		AddArmyCost(unit);

		TRY_UNIT(this->circuit, unit,
			if (unit->GetCircuitDef()->IsAbleToFly()) {
				if (unit->GetCircuitDef()->IsAttrNoStrafe()) {
					unit->CmdAirStrafe(0);
				}
				if (unit->GetCircuitDef()->IsRoleMine()) {
					unit->GetUnit()->SetIdleMode(1);
				}
			}
			if (unit->GetCircuitDef()->IsAttrStock()) {
				unit->GetUnit()->Stockpile(UNIT_COMMAND_OPTION_SHIFT_KEY | UNIT_COMMAND_OPTION_CONTROL_KEY);
				unit->CmdMiscPriority(2);
				stockpilers.insert(unit);
			}
		)

		UnitAdded(unit, UseAs::COMBAT);
	};
	auto attackerIdleHandler = [this](CCircuitUnit* unit) {
		// NOTE: Avoid instant task reassignment, though it may be not relevant for attackers
		if (this->circuit->GetLastFrame() > unit->GetTaskFrame()/* + FRAMES_PER_SEC*/) {
			unit->GetTask()->OnUnitIdle(unit);
		}
	};
	auto attackerDamagedHandler = [](CCircuitUnit* unit, CEnemyInfo* attacker) {
		unit->GetTask()->OnUnitDamaged(unit, attacker);
	};
	auto attackerDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		IUnitTask* task = unit->GetTask();
		task->OnUnitDestroyed(unit, attacker);  // can change task
		unit->GetTask()->RemoveAssignee(unit);  // Remove unit from IdleTask

		if (task->GetType() == IUnitTask::Type::NIL) {
			return;
		}

		DelArmyCost(unit);
		army.erase(unit);
        externalOwnerCandidates.erase(unit->GetId());

		if (unit->GetCircuitDef()->IsAttrStock()) {
			stockpilers.erase(unit);
		}

		UnitRemoved(unit, UseAs::COMBAT);
	};

	/*
	 * Regular defence handlers: for units not in STOCK or SUPER but with FENCE attribute
	 */
	auto fenceFinishedHandler = [this](CCircuitUnit* unit) {
		UnitAdded(unit, UseAs::FENCE);
	};
	auto fenceDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		UnitRemoved(unit, UseAs::FENCE);
	};

	/*
	 * Stockpile handlers: for units with STOCK attribute but not SUPER
	 */
	auto stockFinishedHandler = [this](CCircuitUnit* unit) {
		TRY_UNIT(this->circuit, unit,
			unit->GetUnit()->Stockpile(UNIT_COMMAND_OPTION_SHIFT_KEY | UNIT_COMMAND_OPTION_CONTROL_KEY);
			stockpilers.insert(unit);
		)

		UnitAdded(unit, UseAs::STOCK);
	};
	auto stockDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		stockpilers.erase(unit);

		UnitRemoved(unit, UseAs::STOCK);
	};

	/*
	 * Superweapon handlers
	 */
	auto superCreatedHandler = [this](CCircuitUnit* unit, CCircuitUnit* builder) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			nilTask->AssignTo(unit);
			this->circuit->AddActionUnit(unit);
		}
	};
	auto superFinishedHandler = [this](CCircuitUnit* unit) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			this->circuit->AddActionUnit(unit);
		}
		nilTask->RemoveAssignee(unit);
		idleTask->AssignTo(unit);

		TRY_UNIT(this->circuit, unit,
			unit->GetUnit()->SetTrajectory(1);
			if (unit->GetCircuitDef()->IsAttrStock()) {
				unit->GetUnit()->Stockpile(UNIT_COMMAND_OPTION_SHIFT_KEY | UNIT_COMMAND_OPTION_CONTROL_KEY);
				unit->CmdMiscPriority(2);
				stockpilers.insert(unit);
			}
		)

		UnitAdded(unit, UseAs::SUPER);
	};
	auto superDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		IUnitTask* task = unit->GetTask();
		task->OnUnitDestroyed(unit, attacker);  // can change task
		unit->GetTask()->RemoveAssignee(unit);  // Remove unit from IdleTask

		if (unit->GetCircuitDef()->IsAttrStock()) {
			stockpilers.erase(unit);
		}

		UnitRemoved(unit, UseAs::SUPER);
	};

	/*
	 * Defend buildings handler
	 */
//	auto structDamagedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
//		const std::set<IFighterTask*>& tasks = GetTasks(IFighterTask::FightType::DEFEND);
//		if (tasks.empty()) {
//			return;
//		}
//		int frame = this->circuit->GetLastFrame();
//		const AIFloat3& pos = unit->GetPos(frame);
//		CTerrainManager* terrainMgr = this->circuit->GetTerrainManager();
//		CDefendTask* defendTask = nullptr;
//		float minSqDist = std::numeric_limits<float>::max();
//		for (IFighterTask* task : tasks) {
//			CDefendTask* dt = static_cast<CDefendTask*>(task);
//			const float sqDist = pos.SqDistance2D(dt->GetPosition());
//			if ((minSqDist <= sqDist) || !terrainMgr->CanMoveToPos(dt->GetLeader()->GetArea(), pos)) {
//				continue;
//			}
//			if ((dt->GetTarget() == nullptr) ||
//				(dt->GetTarget()->GetPos().SqDistance2D(dt->GetLeader()->GetPos(frame)) > sqDist))
//			{
//				minSqDist = sqDist;
//				defendTask = dt;
//			}
//		}
//		if (defendTask != nullptr) {
//			defendTask->SetPosition(pos);
//			defendTask->SetWantedTarget(attacker);
//		}
//	};

	// NOTE: IsRole used below
	ReadConfig();

	const Json::Value& root = circuit->GetSetupManager()->GetConfig();
	const Json::Value& retreat = root["retreat"]["fighter"];
	const float minRet = retreat.get((unsigned)0, 0.5f).asFloat();
	const float maxRet = retreat.get((unsigned)1, 0.5f).asFloat();
	const float fighterRet = (float)rand() / RAND_MAX * (maxRet - minRet) + minRet;
	const float retMod = retreat.get((unsigned)2, 1.0f).asFloat();
	const float commMod = root["quota"]["thr_mod"].get("comm", 1.f).asFloat();
	std::vector<CCircuitDef*> builders;

	for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
		if (cdef.IsBuilder()) {
			builders.push_back(&cdef);
		}

		CCircuitDef::Id unitDefId = cdef.GetId();
		if (cdef.IsRoleComm()) {
			cdef.ModDefThreat(commMod);
			for (CCircuitDef::RoleT role = 0; role < CMaskHandler::GetMaxMasks(); ++role) {
				cdef.ModThreatMod(role, commMod);
			}
			cdef.ModPower(commMod);
		}
		if (cdef.GetDef()->IsBuilder() && (cdef.IsBuilder() || cdef.IsAbleToResurrect())) {
//			damagedHandler[unitDefId] = structDamagedHandler;
			continue;
		}
		const std::map<std::string, std::string>& customParams = cdef.GetDef()->GetCustomParams();
		auto it = customParams.find("is_drone");
		if ((it != customParams.end()) && (utils::string_to_int(it->second) == 1)) {
			continue;
		}
		if (cdef.IsMobile()) {
			createdHandler[unitDefId] = attackerCreatedHandler;
			finishedHandler[unitDefId] = attackerFinishedHandler;
			idleHandler[unitDefId] = attackerIdleHandler;
			damagedHandler[unitDefId] = attackerDamagedHandler;
			destroyedHandler[unitDefId] = attackerDestroyedHandler;

			cdef.SetRetreat((cdef.GetRetreat() < 0.f) ? fighterRet : cdef.GetRetreat() * retMod);
		} else {
//			damagedHandler[unitDefId] = structDamagedHandler;
			if (cdef.IsRoleSuper()) {
				if (cdef.IsAttacker() || cdef.IsAttrStock()) {
					createdHandler[unitDefId] = superCreatedHandler;
					finishedHandler[unitDefId] = superFinishedHandler;
					destroyedHandler[unitDefId] = superDestroyedHandler;
				}
			} else if (cdef.IsAttrStock()) {
				finishedHandler[unitDefId] = stockFinishedHandler;
				destroyedHandler[unitDefId] = stockDestroyedHandler;
			} else if (cdef.IsAttrFence()) {
				finishedHandler[unitDefId] = fenceFinishedHandler;
				destroyedHandler[unitDefId] = fenceDestroyedHandler;
			}
			if (cdef.GetDef()->GetRadarRadius() > 1.f) {
				radarDefs.AddDef(&cdef);
				cdef.SetIsRadar(true);
			}
			if (cdef.GetDef()->GetSonarRadius() > 1.f) {
				sonarDefs.AddDef(&cdef);
				cdef.SetIsSonar(true);
			}
		}
	}

	InitEconomyScores(std::move(builders));
}

void CMilitaryManager::ReadConfig()
{
	const Json::Value& root = circuit->GetSetupManager()->GetConfig();
	const std::string& cfgName = circuit->GetSetupManager()->GetConfigName();
	CCircuitDef::RoleName& roleNames = CCircuitDef::GetRoleNames();

	const Json::Value& responses = root["response"];
    // Content policy is explicit JSON, not a faction/unit-name fork. The tag
    // narrows recurring work to possible gadget children; the live rule is
    // still the authority, so an independent drone remains AI-controlled.
    externalOwnerRule = responses.get("_external_owner_rule", "").asString();
    const std::string externalTag = responses.get("_external_owner_tag", "").asString();
    if (!externalOwnerRule.empty() && !externalTag.empty()) {
        for (auto& definition : circuit->GetCircuitDefs()) {
            if (!definition.IsMobile() || definition.GetBuildSpeed() > 0.f) continue;
            const auto& parameters = definition.GetDef()->GetCustomParams();
            const auto found = parameters.find(externalTag);
            if (found != parameters.end() && utils::string_to_int(found->second) == 1)
                externalOwnerDefinitions.insert(definition.GetId());
        }
    }
	const float reImpMod = responses.get("_importance_mod_", 1.f).asFloat();
	const float teamSize = circuit->GetAllyTeam()->GetSize();
	roleInfos.resize(roleNames.size(), {.0f});
	for (const auto& pair : roleNames) {
		SRoleInfo& info = roleInfos[pair.second.type];
		const Json::Value& response = responses[pair.first];

		if (response.isNull()) {
			info.maxPerc = 1.0f;
			info.factor  = teamSize;
			continue;
		}

		info.maxPerc = response.get("max_percent", 1.0f).asFloat();
		const float step = response.get("eps_step", 1.0f).asFloat();
		info.factor  = (teamSize - 1.0f) * step + 1.0f;

		const Json::Value& vs = response["vs"];
		const Json::Value& ratio = response["ratio"];
		const Json::Value& importance = response["importance"];
		for (unsigned i = 0; i < vs.size(); ++i) {
			const std::string& roleName = vs[i].asString();
			auto it = roleNames.find(roleName);
			if (it == roleNames.end()) {
				circuit->LOG("CONFIG %s: response %s vs unknown role '%s'", cfgName.c_str(), pair.first.c_str(), roleName.c_str());
				continue;
			}
			float rat = ratio.get(i, 1.0f).asFloat();
			float imp = importance.get(i, 1.0f).asFloat() * reImpMod;
			info.vs.emplace_back(it->second.type, rat, imp);
		}
	}

	const Json::Value& quotas = root["quota"];
	maxScouts = quotas.get("scout", 3).asUInt();
	const Json::Value& qraid = quotas["raid"];
	raid.min = qraid.get((unsigned)0, 3.f).asFloat();
	raid.avg = qraid.get((unsigned)1, 5.f).asFloat();
	minAttackers = quotas.get("attack", 8.f).asFloat();
	const Json::Value& qthrMod = quotas["thr_mod"];
	const Json::Value& qthrAtk = qthrMod["attack"];
	attackMod.min = qthrAtk.get((unsigned)0, 1.f).asFloat();
	attackMod.len = qthrAtk.get((unsigned)1, 1.f).asFloat() - attackMod.min;
	const Json::Value& qthrDef = qthrMod["defence"];
	defenceMod.min = qthrDef.get((unsigned)0, 1.f).asFloat();
	defenceMod.len = qthrDef.get((unsigned)1, 1.f).asFloat() - defenceMod.min;

	const Json::Value& adaptive_threat_range = root["adaptive_threat_range"];
	threatRangeScaling.enemyCountPerEnemyTeamToStartScaling = adaptive_threat_range.get("enemy_count_per_team_to_start_scaling", 50).asInt();
	threatRangeScaling.enemyCountPerEnemyTeamToEndScaling = adaptive_threat_range.get("enemy_count_per_team_to_end_scaling", 300).asInt();
	threatRangeScaling.endScaleValue = adaptive_threat_range.get("end_scale_value", -1.0f).asFloat();

	/*
	 * Pulse weapons (Juno). "role" names the def role that marks a pulse
	 * weapon, "jammer"/"radar" the roles that mark its worthwhile targets, and
	 * "priority" orders the four target classes; a class left out of the list
	 * is never targeted. Unknown role names disable the policy rather than
	 * silently targeting nothing.
	 */
	const Json::Value& pulse = root["pulse"];
	pulseInfo.rank.fill(-1);
	pulseInfo.isEnabled = false;
	if (pulse.get("enabled", true).asBool()) {
		auto findRole = [&roleNames, &cfgName, this](const std::string& name, CCircuitDef::RoleM& out) {
			auto it = roleNames.find(name);
			if (it == roleNames.end()) {
				circuit->LOG("CONFIG %s: pulse unknown role '%s'", cfgName.c_str(), name.c_str());
				return false;
			}
			out = CCircuitDef::GetMask(it->second.type);
			return true;
		};
		static const std::map<std::string, PulseClass> classNames = {
			{"jammer_advanced", PulseClass::JAMMER_ADVANCED}, {"radar_advanced", PulseClass::RADAR_ADVANCED},
			{"jammer_static", PulseClass::JAMMER_STATIC}, {"radar_static", PulseClass::RADAR_STATIC},
			{"jammer_mobile", PulseClass::JAMMER_MOBILE}, {"radar_mobile", PulseClass::RADAR_MOBILE},
		};
		const bool isRoles = findRole(pulse.get("role", "juno").asString(), pulseInfo.pulseRole)
				&& findRole(pulse.get("jammer", "jammer").asString(), pulseInfo.jammerRole)
				&& findRole(pulse.get("radar", "radar").asString(), pulseInfo.radarRole);
		const Json::Value& prio = pulse["priority"];
		int rank = 0;
		for (unsigned i = 0; i < prio.size(); ++i) {
			auto it = classNames.find(prio[i].asString());
			if (it == classNames.end()) {
				circuit->LOG("CONFIG %s: pulse unknown priority class '%s'", cfgName.c_str(), prio[i].asString().c_str());
				continue;
			}
			pulseInfo.rank[static_cast<PulseC>(it->second)] = rank++;
		}
		if (rank == 0) {  // no list given: the documented default order
			for (int i = 0; i < static_cast<PulseC>(PulseClass::_SIZE_); ++i) pulseInfo.rank[i] = i;
			rank = static_cast<PulseC>(PulseClass::_SIZE_);
		}
		pulseInfo.mobileMaxAge = pulse.get("mobile_max_age", 60).asInt() * FRAMES_PER_SEC;
		pulseInfo.minTargets = std::max(1, pulse.get("min_targets", 1).asInt());
		pulseInfo.suspectJammer = pulse.get("suspect_jammer", true).asBool();
		pulseInfo.holeProbeRadius = pulse.get("hole_probe_radius", 760.f).asFloat();
		pulseInfo.holeRadius = pulse.get("hole_radius", 500.f).asFloat();
		pulseInfo.holeMinEnemyInfl = pulse.get("hole_min_enemy_infl", 0.05f).asFloat();
		pulseInfo.holeProbes = std::max(1, pulse.get("hole_probes", 8).asInt());
		pulseInfo.pendingFrames = std::max(1, pulse.get("pending_seconds", 45).asInt()) * FRAMES_PER_SEC;
		pulseInfo.coverageFrames = std::max(1, pulse.get("coverage_seconds", 90).asInt()) * FRAMES_PER_SEC;
		pulseInfo.scatter = pulse.get("scatter", true).asBool();
		pulseInfo.scatterStep = std::max(128.f, pulse.get("scatter_step", 384.f).asFloat());
		pulseInfo.scatterDepth = std::max(0.f, pulse.get("scatter_depth", 192.f).asFloat());
		pulseInfo.targetClasses.clear();
		pulseInfo.unitDefs.clear();
		Json::Value names = pulse["units"];
		if (names.isNull()) for (const char* name : {"armjuno", "corjuno", "legjuno"}) names.append(name);
		for (CCircuitDef& d : circuit->GetCircuitDefs()) {
			for (const auto& name : names) if (name.asString() == d.GetDef()->GetName()) pulseInfo.unitDefs.insert(d.GetId());
			const auto& cp = d.GetDef()->GetCustomParams();
			const auto kill = cp.find("juno_kill");
			const bool vulnerable = kill != cp.end() && (kill->second == "1" || kill->second == "true");
			const bool jammer = d.IsRespRoleAny(pulseInfo.jammerRole) || (vulnerable && d.GetDef()->GetJammerRadius() > 0);
			const bool radar = d.IsRespRoleAny(pulseInfo.radarRole) || (vulnerable && d.GetDef()->GetRadarRadius() > 0);
			const auto level = cp.find("techlevel");
			const bool advanced = level != cp.end() && std::atoi(level->second.c_str()) >= 2;
			const int cls = strategic::SensorClass(jammer, radar, d.IsMobile(), advanced);
			if (cls >= 0) pulseInfo.targetClasses[d.GetId()] = cls;
		}
		pulseInfo.isEnabled = isRoles;
		circuit->LOG("CONFIG %s: pulse %s | classes=%i mobileMaxAge=%is minTargets=%i",
				cfgName.c_str(), pulseInfo.isEnabled ? "enabled" : "disabled",
				rank, pulseInfo.mobileMaxAge / FRAMES_PER_SEC, pulseInfo.minTargets);
	}

	/*
	 * EMP weapons. Target worth is not metal cost but whether the shot lands a
	 * useful stun, which depends on the target's max health and its
	 * paralyzemultiplier. "role" marks the def carrying the weapon,
	 * "anti_nuke" the one class ranked above raw value; everything else
	 * EMPABLE and stunnable is ranked structures-first, then by metal, so a
	 * Ragnarok, AFUS, gantry or silo is picked up without being tagged.
	 */
	const Json::Value& empCfg = root["emp"];
	empInfo.isEnabled = false;
	if (!empCfg.isNull() && empCfg.get("enabled", true).asBool()) {
		auto findRole = [&roleNames, &cfgName, this](const std::string& name, CCircuitDef::RoleM& out) {
			auto it = roleNames.find(name);
			if (it == roleNames.end()) {
				circuit->LOG("CONFIG %s: emp unknown role '%s'", cfgName.c_str(), name.c_str());
				return false;
			}
			out = CCircuitDef::GetMask(it->second.type);
			return true;
		};
		const bool isRoles = findRole(empCfg.get("role", "emp").asString(), empInfo.empRole)
				&& findRole(empCfg.get("anti_nuke", "anti_nuke").asString(), empInfo.antiNukeRole);
		empInfo.empableFlag = circuit->GetGame()->GetCategoriesFlag(
				empCfg.get("category", "EMPABLE").asString().c_str());
		empInfo.declineRate = empCfg.get("decline_rate", 40.f).asFloat();
		if (empInfo.declineRate < 1.f) {
			empInfo.declineRate = 40.f;
		}
		empInfo.minStunSeconds = empCfg.get("min_stun", 5.f).asFloat();
		empInfo.mobileMaxAge = empCfg.get("mobile_max_age", 30).asInt() * FRAMES_PER_SEC;
		empInfo.minTargets = std::max(1, empCfg.get("min_targets", 1).asInt());
		empInfo.structuresFirst = empCfg.get("structures_first", true).asBool();
		empInfo.structuresFirstMinCost = empCfg.get("structures_first_min_cost", 1500.f).asFloat();
		empInfo.isEnabled = isRoles && (empInfo.empableFlag != 0);
		circuit->LOG("CONFIG %s: emp %s | empable=0x%x declineRate=%.0f minStun=%.1fs mobileMaxAge=%is",
				cfgName.c_str(), empInfo.isEnabled ? "enabled" : "disabled",
				empInfo.empableFlag, empInfo.declineRate, empInfo.minStunSeconds,
				empInfo.mobileMaxAge / FRAMES_PER_SEC);
	}

	/*
	 * Bomber policy. Defaults keep the pre-policy behaviour recognisable:
	 * value ranking and the kill-feasibility filter always apply, the line
	 * formation only engages when a real cluster is present.
	 */
	const Json::Value& bomberCfg = root["bomber"];
	bomberInfo.isEnabled = bomberCfg.isNull() || bomberCfg.get("enabled", true).asBool();
	if (!bomberCfg.isNull()) {
		bomberInfo.killMargin = bomberCfg.get("kill_margin", 1.15f).asFloat();
		bomberInfo.focusCost = bomberCfg.get("focus_cost", 1500.f).asFloat();
		bomberInfo.areaMinTargets = std::max(2, bomberCfg.get("area_min_targets", 3).asInt());
		bomberInfo.areaRadius = bomberCfg.get("area_radius", 900.f).asFloat();
		bomberInfo.minSpacing = std::max(1.f, bomberCfg.get("min_spacing", 96.f).asFloat());
		bomberInfo.cleanupDistance = bomberCfg.get("cleanup_distance", 900.f).asFloat();
		bomberInfo.approachSamples = std::max(1, bomberCfg.get("approach_samples", 8).asInt());
		bomberInfo.approachRing = std::max(1.f, bomberCfg.get("approach_ring", 1200.f).asFloat());
		bomberInfo.groupMixedDefs = bomberCfg.get("group_mixed_defs", true).asBool();
	}
	circuit->LOG("CONFIG %s: bomber %s | killMargin=%.2f focusCost=%.0f areaMin=%i areaRadius=%.0f mixedDefs=%i",
			cfgName.c_str(), bomberInfo.isEnabled ? "enabled" : "disabled",
			bomberInfo.killMargin, bomberInfo.focusCost, bomberInfo.areaMinTargets,
			bomberInfo.areaRadius, int(bomberInfo.groupMixedDefs));

	const Json::Value& stockCfg = root["stockpile"];
	const Json::Value& nuclear = root["nuclear"];
	nuclearInfo.structuresOnly = nuclear.get("structures_only", true).asBool();
	nuclearInfo.repeatFrames = std::max(0, nuclear.get("repeat_seconds", 300).asInt()) * FRAMES_PER_SEC;
	nuclearInfo.repeatRadius = std::max(0.f, nuclear.get("repeat_radius", 0.f).asFloat());
	if (!stockCfg.isNull()) {
		stockInfo.patienceSeconds = std::max(0.f, stockCfg.get("patience_seconds", 240.f).asFloat());
		stockInfo.minFraction = std::min(1.f, std::max(0.f, stockCfg.get("min_fraction", 0.25f).asFloat()));
		stockInfo.fullFireCount = std::max(0, stockCfg.get("full_fire_count", 2).asInt());
		stockInfo.launcherMobileMaxAge = std::max(0, stockCfg.get("launcher_mobile_max_age", 30).asInt()) * FRAMES_PER_SEC;
		stockInfo.launcherMinTargets = std::max(1, stockCfg.get("launcher_min_targets", 1).asInt());
		stockInfo.launcherStructuresFirst = stockCfg.get("launcher_structures_first", false).asBool();
	}
	circuit->LOG("CONFIG %s: stockpile patience=%.0fs minFraction=%.2f fullFireCount=%i launcher(maxAge=%is minTargets=%i structuresFirst=%i)",
			cfgName.c_str(), stockInfo.patienceSeconds, stockInfo.minFraction, stockInfo.fullFireCount,
			stockInfo.launcherMobileMaxAge / FRAMES_PER_SEC, stockInfo.launcherMinTargets, int(stockInfo.launcherStructuresFirst));

	/*
	 * Mobile sensor escort. Reuses the same "jammer" and "radar" role tags the
	 * pulse policy uses to find its targets: a def worth pulsing on the enemy
	 * side is a def worth rationing on ours.
	 */
	const Json::Value& sensorCfg = root["sensor"];
	sensorInfo.isEnabled = false;
	if (sensorCfg.isNull() || sensorCfg.get("enabled", true).asBool()) {
		auto orRole = [&roleNames, &cfgName, this](const std::string& name, CCircuitDef::RoleM& out) {
			auto it = roleNames.find(name);
			if (it == roleNames.end()) {
				circuit->LOG("CONFIG %s: sensor unknown role '%s'", cfgName.c_str(), name.c_str());
				return false;
			}
			out |= CCircuitDef::GetMask(it->second.type);
			return true;
		};
		sensorInfo.sensorRole = 0;
		bool isRoles = orRole(sensorCfg.get("jammer", "jammer").asString(), sensorInfo.sensorRole);
		isRoles &= orRole(sensorCfg.get("radar", "radar").asString(), sensorInfo.sensorRole);
		sensorInfo.maxPerSquad = std::max(1, sensorCfg.get("max_per_squad", 1).asInt());
		sensorInfo.topCandidates = std::max(1, sensorCfg.get("top_candidates", 3).asInt());
		sensorInfo.rebalance = sensorCfg.get("rebalance", true).asBool();
		sensorInfo.isEnabled = isRoles;
	}
	circuit->LOG("CONFIG %s: sensor escort %s | maxPerSquad=%i topCandidates=%i rebalance=%i",
			cfgName.c_str(), sensorInfo.isEnabled ? "enabled" : "disabled",
			sensorInfo.maxPerSquad, sensorInfo.topCandidates, int(sensorInfo.rebalance));

	const Json::Value& porc = root["porcupine"];
	preventCount = porc.get("prevent", 1).asUInt();
	const Json::Value& amount = porc["amount"];
	const Json::Value& amOff = amount["offset"];
	const Json::Value& amFac = amount["factor"];
	const Json::Value& amMap = amount["map"];
	const float minOffset = amOff.get((unsigned)0, -0.2f).asFloat();
	const float maxOffset = amOff.get((unsigned)1, 0.2f).asFloat();
	const float offset = (float)rand() / RAND_MAX * (maxOffset - minOffset) + minOffset;
	const float minFactor = amFac.get((unsigned)0, 2.0f).asFloat();
	const float maxFactor = amFac.get((unsigned)1, 1.0f).asFloat();
	const float minMap = amMap.get((unsigned)0, 8.0f).asFloat();
	const float maxMap = amMap.get((unsigned)1, 24.0f).asFloat();
	const float mapSize = (circuit->GetMap()->GetWidth() / 64) * (circuit->GetMap()->GetHeight() / 64);
	amountFactor = (maxFactor - minFactor) / (SQUARE(maxMap) - SQUARE(minMap)) * (mapSize - SQUARE(minMap)) + minFactor + offset;
//	amountFactor = std::max(amountFactor, 0.f);

	CMaskHandler& sideMasker = circuit->GetGameAttribute()->GetSideMasker();
	sideInfos.resize(sideMasker.GetMasks().size());
	for (const auto& kv : sideMasker.GetMasks()) {
		SSideInfo& sideInfo = sideInfos[kv.second.type];
		const Json::Value& defs = porc["unit"][kv.first];
		std::vector<CCircuitDef*> defenderDefs;
		defenderDefs.reserve(defs.size());
		for (const Json::Value& def : defs) {
			CCircuitDef* cdef = circuit->GetCircuitDef(def.asCString());
			if (cdef == nullptr) {
				circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), def.asCString());
			} else {
				cdef->AddAttribute(ATTR_TYPE(FENCE));
				defenderDefs.push_back(cdef);
			}
		}
		const Json::Value& land = porc["land"];
		sideInfo.landDefenders.reserve(land.size());
		for (const Json::Value& idx : land) {
			unsigned index = idx.asUInt();
			if (index < defenderDefs.size()) {
				sideInfo.landDefenders.push_back(defenderDefs[index]);
			}
		}
		const Json::Value& watr = porc["water"];
		sideInfo.waterDefenders.reserve(watr.size());
		for (const Json::Value& idx : watr) {
			unsigned index = idx.asUInt();
			if (index < defenderDefs.size()) {
				sideInfo.waterDefenders.push_back(defenderDefs[index]);
			}
		}

		const Json::Value& base = porc["base"];
		sideInfo.baseDefence.reserve(base.size());
		for (const Json::Value& pair : base) {
			unsigned index = pair.get((unsigned)0, -1).asUInt();
			if (index >= defenderDefs.size()) {
				continue;
			}
			int frame = pair.get((unsigned)1, 0).asInt() * FRAMES_PER_SEC;
			sideInfo.baseDefence.emplace_back(defenderDefs[index], frame);
		}
		auto compare = [](const std::pair<CCircuitDef*, int>& d1, const std::pair<CCircuitDef*, int>& d2) {
			return d1.second > d2.second;
		};
		std::sort(sideInfo.baseDefence.begin(), sideInfo.baseDefence.end(), compare);

		const Json::Value& super = porc["superweapon"];
		const Json::Value& items = super["unit"][kv.first];
		const Json::Value& probs = super["weight"];
		sideInfo.superInfos.reserve(items.size());
		for (unsigned i = 0; i < items.size(); ++i) {
			CCircuitDef* cdef = circuit->GetCircuitDef(items[i].asCString());
			if (cdef == nullptr) {
				circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), items[i].asCString());
				continue;
			}
			cdef->SetMainRole(ROLE_TYPE(SUPER));  // override mainRole
			cdef->AddEnemyRole(ROLE_TYPE(SUPER));
			cdef->AddRole(ROLE_TYPE(SUPER));
			const float weight = probs.get(i, 1.f).asFloat();
			sideInfo.superInfos.emplace_back(cdef, weight);
		}

		const Json::Value& walls = porc["wall"][kv.first];
		sideInfo.wallDefs.reserve(walls.size());
		for (unsigned i = 0; i < walls.size(); ++i) {
			CCircuitDef* cdef = circuit->GetCircuitDef(walls[i].asCString());
			if (cdef == nullptr) {
				circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), walls[i].asCString());
				continue;
			}
			sideInfo.wallDefs.push_back(cdef);
		}
		const Json::Value& chokes = porc["choke"][kv.first];
		sideInfo.chokeDefs.reserve(chokes.size());
		for (unsigned i = 0; i < chokes.size(); ++i) {
			CCircuitDef* cdef = circuit->GetCircuitDef(chokes[i].asCString());
			if (cdef == nullptr) {
				circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), chokes[i].asCString());
				continue;
			}
			sideInfo.chokeDefs.push_back(cdef);
		}

		const std::string& defName = porc["default"].get(kv.first, "").asString();
		sideInfo.defaultPorc = circuit->GetCircuitDef(defName.c_str());
		if (sideInfo.defaultPorc == nullptr) {
			sideInfo.defaultPorc = circuit->GetEconomyManager()->GetSideInfos()[kv.second.type].defaultDef;
		}
	}
}

void CMilitaryManager::InitEconomyScores(const std::vector<CCircuitDef*>&& builders)
{
	auto scoreFunc = [](CCircuitDef* cdef, const SSensorExt& data) {
		return M_PI * SQUARE(data.radius) / cdef->GetCostM();  // area / cost
//		return data.radius - cdef->GetCostM() * 0.1f;  // absolutely no physical meaning
	};
	radarDefs.Init(builders, [scoreFunc](CCircuitDef* cdef, SSensorExt& data) {
		data.radius = cdef->GetDef()->GetRadarRadius();
		return scoreFunc(cdef, data);
	});
	sonarDefs.Init(builders, [scoreFunc](CCircuitDef* cdef, SSensorExt& data) {
		data.radius = cdef->GetDef()->GetSonarRadius();
		return scoreFunc(cdef, data);
	});
}

void CMilitaryManager::Init()
{
	CMetalManager* metalMgr = circuit->GetMetalManager();
	const CMetalData::Clusters& clusters = metalMgr->GetClusters();

	scoutPoints.resize(clusters.size(), SScoutPoint{0, 0, 0, 0, nullptr});

	CSetupManager::StartFunc subinit = [this, &clusters](const AIFloat3& pos) {
		std::vector<int> sortedIdxs;
		sortedIdxs.reserve(scoutPoints.size());
		for (unsigned int i = 0; i < scoutPoints.size(); ++i) {
			sortedIdxs.push_back(i);
		}
		std::sort(sortedIdxs.begin(), sortedIdxs.end(), [&pos, &clusters](int a, int b) {
			return pos.SqDistance2D(clusters[a].position) > pos.SqDistance2D(clusters[b].position);
		});
		for (unsigned int i = 0; i < scoutPoints.size(); ++i) {
			scoutPoints[sortedIdxs[i]].scouted = i;  // enforce scouting distant areas first
		}

		DiceBigGun();

		CScheduler* scheduler = circuit->GetScheduler().get();
		const int interval = 4;
		const int offset = circuit->GetSkirmishAIId() % interval;
        scheduler->RunJobEvery(CScheduler::GameJob([this]() {
            UpdateExternalControl();
            UpdateIdle();
        }), interval, offset + 0);
		scheduler->RunJobEvery(CScheduler::GameJob(&CMilitaryManager::Update, this), 1/*interval / 2*/, offset + 1);
		scheduler->RunJobEvery(CScheduler::GameJob(&CMilitaryManager::UpdateDefenceTasks, this), FRAMES_PER_SEC * 5, offset + 2);
		scheduler->RunJobEvery(CScheduler::GameJob(&CMilitaryManager::UpdateSensorGuards, this), FRAMES_PER_SEC * 5, offset + 3);

		scheduler->RunJobEvery(CScheduler::GameJob(&CMilitaryManager::Watchdog, this),
								FRAMES_PER_SEC * 60,
								circuit->GetSkirmishAIId() * WATCHDOG_COUNT + 12);
	};

	circuit->GetSetupManager()->ExecOnFindStart(subinit);
}

int CMilitaryManager::UnitCreated(CCircuitUnit* unit, CCircuitUnit* builder)
{
	auto search = createdHandler.find(unit->GetCircuitDef()->GetId());
	if (search != createdHandler.end()) {
		search->second(unit, builder);
	}

	return 0; //signaling: OK
}

int CMilitaryManager::UnitFinished(CCircuitUnit* unit)
{
	auto search = finishedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != finishedHandler.end()) {
		search->second(unit);
	}

	return 0; //signaling: OK
}

int CMilitaryManager::UnitIdle(CCircuitUnit* unit)
{
	auto search = idleHandler.find(unit->GetCircuitDef()->GetId());
	if (search != idleHandler.end()) {
		search->second(unit);
	}

	return 0; //signaling: OK
}

int CMilitaryManager::UnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	auto search = damagedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != damagedHandler.end()) {
		search->second(unit, attacker);
	}

	return 0; //signaling: OK
}

int CMilitaryManager::UnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	if (unit->GetCircuitDef()->IsAttrFence()) {
		UnmarkPorc(unit);
	}

	auto itgt = guardTasks.find(unit);
	if (itgt != guardTasks.end()) {
		CFGuardTask* guard = itgt->second;
		guardTasks.erase(itgt);  // D-089: the entry goes first; AbortTask cannot find this unit by id any more
		AbortTask(guard);
	}

	auto search = destroyedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != destroyedHandler.end()) {
		search->second(unit, attacker);
	}

	return 0; //signaling: OK
}

IFighterTask* CMilitaryManager::Enqueue(const TaskF::SFightTask& ti)
{
	IFighterTask* task;

	switch (ti.type) {
		default:
		case IFighterTask::FightType::RALLY: {
//			CEconomyManager* economyMgr = circuit->GetEconomyManager();
//			float power = economyMgr->GetAvgMetalIncome() * economyMgr->GetEcoFactor() * 32.0f;
			task = new CRallyTask(this, /*power*/1);  // TODO: pass enemy's threat
		} break;
		case IFighterTask::FightType::GUARD: {
			auto it = guardTasks.find(ti.vip);
			if (it != guardTasks.end()) {
				return it->second;
			}
			task = new CFGuardTask(this, ti.vip, 1.0f);
		} break;
		case IFighterTask::FightType::DEFEND: {
			const AIFloat3& pos = circuit->GetSetupManager()->GetBasePos();
			if (ti.check == IFighterTask::FightType::_SIZE_) {
				const float mod = (float)rand() / RAND_MAX * defenceMod.len + defenceMod.min;
				task = new CDefendTask(this, pos, ti.promote, ti.promote, ti.power, 1.0f / mod);
			} else {
				task = new CDefendTask(this, pos, ti.check, ti.promote, ti.power, 1.0f);
			}
		} break;
		case IFighterTask::FightType::SCOUT: {
			const float mod = (float)rand() / RAND_MAX * attackMod.len + attackMod.min;
			task = new CScoutTask(this, 0.75f / mod);
		} break;
		case IFighterTask::FightType::RAID: {
			const float mod = (float)rand() / RAND_MAX * attackMod.len + attackMod.min;
			task = new CRaidTask(this, raid.avg, 0.75f / mod);
		} break;
		case IFighterTask::FightType::ATTACK: {
			const float mod = (float)rand() / RAND_MAX * attackMod.len + attackMod.min;
			task = new CAttackTask(this, minAttackers, 0.8f / mod);
		} break;
		case IFighterTask::FightType::BOMB: {
			const float mod = (float)rand() / RAND_MAX * attackMod.len + attackMod.min;
			task = new CBombTask(this, 2.0f / mod);
		} break;
		case IFighterTask::FightType::ARTY: {
			task = new CArtilleryTask(this);
		} break;
		case IFighterTask::FightType::AA: {
			const float mod = (float)rand() / RAND_MAX * attackMod.len + attackMod.min;
			task = new CAntiAirTask(this, 1.0f / mod);
		} break;
		case IFighterTask::FightType::AH: {
			const float mod = (float)rand() / RAND_MAX * attackMod.len + attackMod.min;
			task = new CAntiHeavyTask(this, 2.0f / mod);
		} break;
		case IFighterTask::FightType::SUPPORT: {
			task = new CSupportTask(this);
		} break;
		case IFighterTask::FightType::SUPER: {
			task = new CSuperTask(this);
		} break;
		case IFighterTask::FightType::ROUTE: {
			task = new CRouteTask(this);  // script-owned waypoint route (Spam::)
		} break;
		case IFighterTask::FightType::FERRY: {
			task = new CFerryTask(this);  // script-owned transport ferry (Team::Ferry)
		} break;
		case IFighterTask::FightType::WAVE: {
			task = new CAirWaveTask(this);  // script-planned bomber wave (AirWaves::)
		} break;
	}

	fightTasks[static_cast<IFighterTask::FT>(ti.type)].insert(task);
	updateTasks.push_back(task);
	TaskAdded(task);
	return task;
}

// Opt-in mechanism: precise power, no merging or unrelated-squad promotion.
// Policy owns admission, rally, deadline and cancellation. Ordinary Enqueue is
// unchanged, including its random draws. One cohort task uses the existing
// scheduler; no per-unit polling or new world scans (D-309).
IFighterTask* CMilitaryManager::EnqueueGather(const TaskF::SFightTask& ti, const AIFloat3& pos, int deadline)
{
    using FT = IFighterTask::FightType;
    if (ti.type != FT::DEFEND || (ti.promote != FT::RAID && ti.promote != FT::ATTACK)
        || !std::isfinite(ti.power) || ti.power <= 0.f || deadline < circuit->GetLastFrame()
        || !geom::is_valid(pos)) return nullptr;
    auto* task = new CDefendTask(this, pos, ti.promote, ti.promote, ti.power, 1.f, deadline);
    fightTasks[static_cast<IFighterTask::FT>(FT::DEFEND)].insert(task);
    updateTasks.push_back(task);
    TaskAdded(task);
    return task;
}

bool CMilitaryManager::SetGatherPower(IUnitTask* task, float power)
{
    auto* gather = dynamic_cast<CDefendTask*>(task);
    if (gather == nullptr || gather->IsDead() || gather->GetManager() != this
        || !gather->IsGather() || !std::isfinite(power) || power < 0.f) return false;
    gather->SetMaxPower(power); // zero releases survivors on their next promotion check
    return true;
}

// A transport owns this hold, not a builder manager or a combat squad. One
// constant-time owner lookup per existing task update; no repeated STOP orders.
// Carrier destruction, transfer and Reset all release the hold on that update.
class CTransportCargoHold final : public IWaitTask {
public:
    CTransportCargoHold(ITaskModule* owner, int carrier)
        : IWaitTask(owner, false, 0), transportId(carrier) {}
    void OnUnitDamaged(CCircuitUnit*, CEnemyInfo*) override {}
    void OnUnitMoveFailed(CCircuitUnit*) override {}
    void Update() override {
        auto* transport = manager->GetCircuit()->GetTeamUnit(transportId);
        auto* ferry = transport == nullptr ? nullptr : dynamic_cast<CFerryTask*>(transport->GetTask());
        if (units.empty() || ferry == nullptr || ferry->IsDead()
            || ferry->GetCargoId() != (*units.begin())->GetId()) manager->AbortTask(this);
    }
private:
    int transportId;
};

IUnitTask* CMilitaryManager::EnqueueCargoHold(int transportId)
{
    IUnitTask* task = new CTransportCargoHold(this, transportId);
    updateTasks.push_back(task);
    TaskAdded(task);
    return task;
}

IUnitTask* CMilitaryManager::EnqueueExternalControl(const std::string& ownerRule)
{
    if (ownerRule.empty()) return nullptr;
    IUnitTask* task = new CExternalControlTask(this, ownerRule);
    updateTasks.push_back(task);
    TaskAdded(task);
    return task;
}

CRetreatTask* CMilitaryManager::EnqueueRetreat()
{
	CRetreatTask* task = new CRetreatTask(this);
	updateTasks.push_back(task);
	TaskAdded(task);
	return task;
}

void CMilitaryManager::DequeueTask(IUnitTask* task, bool done)
{
	switch (task->GetType()) {
		case IUnitTask::Type::FIGHTER: {
			IFighterTask* taskF = static_cast<IFighterTask*>(task);
			fightTasks[static_cast<IFighterTask::FT>(taskF->GetFightType())].erase(taskF);
			if (taskF->GetFightType() == IFighterTask::FightType::GUARD) {
				// D-089: erase by the task, not by looking the VIP up: a VIP already gone
				// from the team (dead, given away) returned null, the entry stayed keyed
				// by the freed unit pointer, and a later unit allocated at that address
				// found it in UnitDestroyed and aborted the freed task (played: access
				// violation in DequeueTask at 1:39:24)
				for (auto it = guardTasks.begin(); it != guardTasks.end(); ) {
					it = (it->second == taskF) ? guardTasks.erase(it) : std::next(it);
				}
			}
		} break;
		default: break;
	}
	ITaskModule::DequeueTask(task, done);
}

void CMilitaryManager::MakeDefence(const AIFloat3& pos)
{
	int index = circuit->GetMetalManager()->FindNearestCluster(pos);
	if (index >= 0) {
		MakeDefence(index, pos);
	}
}

void CMilitaryManager::MakeDefence(int cluster)
{
	MakeDefence(cluster, circuit->GetMetalManager()->GetClusters()[cluster].position);
}

void CMilitaryManager::MakeDefence(int cluster, const AIFloat3& pos)
{
	static_cast<CMilitaryScript*>(script)->MakeDefence(cluster, pos);  // DefaultMakeDefence
}

void CMilitaryManager::DefaultMakeDefence(int cluster, const AIFloat3& pos)
{
	// TODO: Rework, depends on mex cluster
	assert(cluster >= 0);

	const int frame = circuit->GetLastFrame();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CBuilderManager* builderMgr = circuit->GetBuilderManager();

	// Inside an ally's zone this AI builds nothing - unless porcAllyAA is set,
	// in which case it builds only the chain's anti-air there and leaves the
	// ground defence to the ally.
	const bool allyAAOnly = terrainMgr->IsZoneAlly(pos);
	if (allyAAOnly && (porcAllyAA == 0)) {
		return;
	}

	// FIXME: New choke defences
//	const CArea* area = terrainMgr->GetTAArea(pos);
//	if (area == nullptr) {
//		return;
//	}
//	const std::vector<const CChokePoint*>& chokes = area->GetChokePoints();
//	constexpr float TEST_SIZE = 64;
//	for (const CChokePoint* ch : chokes) {
//		const CArea* opArea = (ch->GetAreas().first == area) ? ch->GetAreas().second : ch->GetAreas().first;
//		if (((int)opArea->GetChokePoints().size() == opArea->GetNumSmallChokes()) || (opArea->GetAccessibleNeighbours().size() < 2)) {
//			continue;
//		}
//		const AIFloat3& middle = ch->GetCenter();
//		bool isDefIn = false;
//		for (auto task : builderMgr->GetTasks(IBuilderTask::BuildType::DEFENCE)) {
//			if (static_cast<CBDefenceTask*>(task)->GetPosition().SqDistance2D(middle) < SQUARE(TEST_SIZE)) {
//				isDefIn = true;
//				break;
//			}
//		}
//		if (!isDefIn
//			&& !circuit->GetCallback()->IsFriendlyUnitsIn(middle, TEST_SIZE, false)
//			&& !circuit->GetCallback()->IsNeutralUnitsIn(middle, TEST_SIZE, false))
//		{
//			auto selectDef = [terrainMgr, frame, &middle](const std::vector<CCircuitDef*>& defs) -> CCircuitDef* {
//				for (CCircuitDef* cdef : defs) {
//					if (cdef->IsAvailable(frame) && terrainMgr->CanBeBuiltAt(cdef, middle)) {
//						return cdef;
//					}
//				}
//				return nullptr;
//			};
//			if (ch->IsSmall()) {
//				CCircuitDef* bd = selectDef(GetSideInfo().wallDefs);
//				if (bd != nullptr) {
//					terrainMgr->DoLineOfDef(ch->GetEnd1(), ch->GetEnd2(), bd, [builderMgr](const AIFloat3& pos, CCircuitDef* buildDef) {
//						builderMgr->EnqueueTask(IBuilderTask::Priority::NORMAL, buildDef, pos,
//								IBuilderTask::BuildType::DEFENCE, buildDef->GetCostM(), 0.f, true);
//					});
//				}
//			} else {
//				CCircuitDef* bd = selectDef(GetSideInfo().chokeDefs);
//				if (bd != nullptr) {
//					builderMgr->EnqueueTask(IBuilderTask::Priority::NORMAL, bd, middle,
//							IBuilderTask::BuildType::DEFENCE, bd->GetCostM(), 0.f, true);
//				}
//			}
//		}
//	}

	CEconomyManager* em = circuit->GetEconomyManager();
	const float metalIncome = std::min(em->GetAvgMetalIncome(), em->GetAvgEnergyIncome()) * em->GetEcoFactor();
	float maxCost = amountFactor * metalIncome * porcBudgetMod;
	CDefenceData::SDefPoint* closestPoint = FindClosestDefPoint(cluster, pos, [maxCost](const CDefenceData::SDefPoint& pnt) {
		return pnt.cost < maxCost;
	});
	if (closestPoint == nullptr) {
		return;
	}
	float totalCost = .0f;
	IBuilderTask* parentTask = nullptr;

	// Front-line porc
	CMetalManager* mm = circuit->GetMetalManager();
	const CMetalData::Clusters& clusters = mm->GetClusters();
	bool isPorc = mm->GetClusterStdDeviation() > 0.3f * mm->GetClusterAvgIncome();
	if (isPorc) {
		const float income = (mm->GetClusterAvgIncome() + mm->GetClusterMaxIncome()) * 0.5f;
		isPorc = (clusters[cluster].position.SqDistance2D(circuit->GetSetupManager()->GetBasePos()) > SQUARE(1000.f))
			&& clusters[cluster].income > income;
	}
	if (!isPorc) {
		unsigned threatCount = 0;
		CThreatMap* threatMap = circuit->GetThreatMap();
		const CMetalData::Metals& spots = mm->GetSpots();
		const CMetalData::ClusterGraph& clusterGraph = mm->GetClusterGraph();
		CMetalData::ClusterGraph::Node node = clusterGraph.nodeFromId(cluster);
		CMetalData::ClusterGraph::IncEdgeIt edgeIt(clusterGraph, node);
		for (; edgeIt != lemon::INVALID; ++edgeIt) {
			int idx0 = clusterGraph.id(clusterGraph.oppositeNode(node, edgeIt));
			if (mm->IsClusterFinished(idx0)) {
				continue;
			}
			// check if there is enemy neighbor
			for (int idx : clusters[idx0].idxSpots) {
				if (threatMap->GetBuilderThreatAt(spots[idx].position) > THREAT_MIN * 4) {
					threatCount++;
					break;
				}
			}
			if (threatCount >= 2) {  // if 2 nearby clusters are a threat
				isPorc = true;
				break;
			}
		}
	}
	isPorc |= circuit->GetInflMap()->GetInfluenceAt(pos) < INFL_EPS;
	// Script policy override (Military::Porc): the heuristic above only fills
	// front-line clusters, which starves the interior late in the game.
	if (porcMode == 2) {
		isPorc = true;
	} else if (porcMode == 1) {
		isPorc = false;
	}
	if (!isPorc) {
		const float sqPtRange = SQUARE(defence->GetPointRange());
		for (IBuilderTask* t : builderMgr->GetTasks(IBuilderTask::BuildType::DEFENCE)) {
			if ((t->GetTarget() == nullptr) && (t->GetNextTask() != nullptr) &&
				(closestPoint->position.SqDistance2D(t->GetTaskPos()) < sqPtRange))
			{
				builderMgr->AbortTask(t);
				break;
			}
		}
	}
	// NOTE: circuit->GetTerrainManager()->IsWaterSector(pos) checks whole sector
	//       but water recognized as height < 0
	bool isWater = !terrainMgr->IsWaterAVoid() && (circuit->GetMap()->GetElevationAt(pos.x, pos.z) < -SQUARE_SIZE * 2);
	const std::vector<CCircuitDef*>& defenders = isWater ? GetSideInfo().waterDefenders : GetSideInfo().landDefenders;
	unsigned num = std::min<unsigned>(isPorc ? defenders.size() : preventCount, defenders.size());
	std::function<bool (CCircuitDef*)> skip;
//	if (isPorc) {
//		skip = [&totalCost, closestPoint, maxCost](CCircuitDef* cdef) -> bool {
//			return (totalCost <= closestPoint->cost) || (!cdef->IsRoleAA() && (totalCost + cdef->GetCostM() < maxCost));
//		};
//	} else {
		skip = [&totalCost, closestPoint](CCircuitDef* cdef) -> bool {
			return (totalCost <= closestPoint->cost);
		};
//	}

//	CSetupManager* setupMgr = circuit->GetSetupManager();
	// TODO: use footprint size instead of const (SQUARE_SIZE * 16)
//	AIFloat3 frontDir = (setupMgr->GetLanePos() - setupMgr->GetBasePos()).Normalize2D() * (SQUARE_SIZE * 16);
	AIFloat3 frontDir = (circuit->GetEnemyManager()->GetEnemyPos() - pos).Normalize2D() * (SQUARE_SIZE * 10);
	AIFloat3 sideDir(-frontDir.z, 0.f, frontDir.x);  // counter-clockwise
	AIFloat3 backPos = closestPoint->position - frontDir;
	AIFloat3 frontPoses[2] = {closestPoint->position + frontDir, closestPoint->position + frontDir - sideDir};
	AIFloat3 middlePoses[2] = {closestPoint->position, closestPoint->position - sideDir};
	AIFloat3 backPoses[2] = {backPos, backPos - sideDir};
	for (AIFloat3* pos : {&backPos, &frontPoses[0], &frontPoses[1], &middlePoses[0], &middlePoses[1], &backPoses[0], &backPoses[1]}) {
		CTerrainManager::CorrectPosition(*pos);
	}
	std::pair<AIFloat3*, int> poses[3] = {std::make_pair(frontPoses, 0), std::make_pair(middlePoses, 0), std::make_pair(backPoses, 0)};

	CEnemyManager* enemyMgr = circuit->GetEnemyManager();
	for (unsigned i = 0; i < num; ++i) {
		CCircuitDef* defDef = defenders[i];
		if (!builderMgr->IsBuildPositionAllowed(defDef, pos)) continue;
		if (!defDef->IsAvailable(frame) || (defDef->IsRoleAA() && (enemyMgr->GetEnemyCost(ROLE_TYPE(AIR)) < 1.f))) {
			continue;
		}
		if (allyAAOnly && !defDef->IsRoleAA()) {
			continue;  // an ally's cluster: AA only, and its cost does not count against the walk
		}
		totalCost += defDef->GetCostM();
		if (skip(defDef)) {
			continue;
		}
		if (totalCost < maxCost) {
			closestPoint->cost += defDef->GetCostM();
			bool isFirst = (parentTask == nullptr);
			std::pair<AIFloat3*, int>& pose = poses[defDef->IsAttacker() ? ((defDef->GetMaxRange() < 500.f) ? 0 : 1) : 2];
			const int ind = pose.second++ % 2;
			IBuilderTask* task = builderMgr->Enqueue(TaskB::Common(IBuilderTask::BuildType::DEFENCE,
					IBuilderTask::Priority::NORMAL, defDef, pose.first[ind], SQUARE_SIZE * 2, isFirst));
			static_cast<CBDefenceTask*>(task)->SetDefPointId(closestPoint->id);
			pose.first[ind] += (ind == 0) ? sideDir : -sideDir;
			CTerrainManager::CorrectPosition(pose.first[ind]);
			if (parentTask != nullptr) {
				parentTask->SetNextTask(task);
			}
			parentTask = task;
		} else {
			// TODO: Auto-sort defenders by cost OR remove break?
			break;
		}
	}

	// Build sensors
	auto checkSensor = [this, frame, maxCost, &backPos, builderMgr, terrainMgr](IBuilderTask::BuildType type,
			CCircuitDef* cdef, float range, std::function<bool (CCircuitDef*)> isSensor)
	{
		if (!cdef->IsAvailable(frame) || (cdef->GetCostM() > maxCost) || !terrainMgr->CanBeBuiltAt(cdef, backPos)) {
			return false;
		}
		COOAICallback* clb = circuit->GetCallback();
		const auto& friendlies = clb->GetFriendlyUnitIdsIn(backPos, range);
		for (int auId : friendlies) {
			CCircuitDef::Id defId = clb->Unit_GetDefId(auId);
			if (isSensor(circuit->GetCircuitDef(defId))) {
				return true;
			}
		}
		const float qdist = SQUARE(range);
		for (const IBuilderTask* t : builderMgr->GetTasks(type)) {
			if (backPos.SqDistance2D(t->GetTaskPos()) < qdist) {
				return true;
			}
		}
		builderMgr->Enqueue(TaskB::Common(type, IBuilderTask::Priority::NORMAL, cdef, backPos));
		return true;
	};
	// radar
	if (radarDefs.HasAvail()) {
		const float radiusMod = isPorc ? 1 / 4.f : 1 / SQRT_2;
		radarDefs.GetBestDef([&checkSensor, radiusMod](CCircuitDef* cdef, const SSensorExt& data) {
			return checkSensor(IBuilderTask::BuildType::RADAR, cdef, data.radius * radiusMod,
					[](CCircuitDef* cdef) { return cdef->IsRadar(); });
		});
	}
	// sonar
	if (isWater && sonarDefs.HasAvail()) {
		sonarDefs.GetBestDef([&checkSensor](CCircuitDef* cdef, const SSensorExt& data) {
			return checkSensor(IBuilderTask::BuildType::SONAR, cdef, data.radius,
					[](CCircuitDef* cdef) { return cdef->IsSonar(); });
		});
	}
}

void CMilitaryManager::MarkPorc(CCircuitUnit* unit, int defPointId)
{
	porcToPoint[unit] = defPointId;
}

void CMilitaryManager::UnmarkPorc(CCircuitUnit* unit)
{
	auto it = porcToPoint.find(unit);
	if (it == porcToPoint.end()) {
		return;
	}
	defence->GetDefPoint(it->second)->cost -= unit->GetCircuitDef()->GetCostM();
	porcToPoint.erase(it);
}

void CMilitaryManager::AbortDefence(const CBDefenceTask* task, int defPointId)
{
	float defCost = task->GetBuildDef()->GetCostM();
	CDefenceData::SDefPoint* point = (defPointId < 0)
			? defence->GetDefPoint(task->GetPosition(), defCost)
			: defence->GetDefPoint(defPointId);
	if (point == nullptr) {
		return;
	}
	if ((task->GetTarget() == nullptr) && (point->cost >= defCost)) {
		point->cost -= defCost;
	}
	IBuilderTask* next = task->GetNextTask();
	while (next != nullptr) {
		defCost = (next->GetBuildDef() != nullptr) ? next->GetBuildDef()->GetCostM() : next->GetCostM();
		if (point->cost >= defCost) {
			point->cost -= defCost;
		}
		next = next->GetNextTask();
	}
}

bool CMilitaryManager::HasDefence(int cluster)
{
	const CDefenceData::DefPoints& points = defence->GetDefPoints();
	const CDefenceData::DefIndices& indices = defence->GetDefIndices(cluster);
	for (int idx : indices) {
		if (points[idx].cost > .5f) {
			return true;
		}
	}
	return false;
}

void CMilitaryManager::ProcessHubDefence(CBDefenceTask* task)
{
	const AIFloat3& pos = task->GetPosition();
	CDefenceData::SDefPoint* closestPoint = FindClosestDefPoint(pos);
	if ((closestPoint == nullptr) || (closestPoint->position.SqDistance2D(pos) > SQUARE(300.f))) {
		return;
	}
	closestPoint->cost += task->GetCostM();
	task->SetDefPointId(closestPoint->id);
}

AIFloat3 CMilitaryManager::GroundObjective(CCircuitUnit* unit, const AIFloat3& previous)
{
	return static_cast<CMilitaryScript*>(script)->GroundObjective(unit, previous);
}

AIFloat3 CMilitaryManager::GetScoutPosition(CCircuitUnit* unit)
{
	ClearScoutPosition(unit->GetTask());
	CMetalManager* metalMgr = circuit->GetMetalManager();
	const CMetalData::Clusters& clusters = metalMgr->GetClusters();
	const CMetalData::Metals& spots = metalMgr->GetSpots();
	const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
	SArea* area = unit->GetArea();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CThreatMap* threatMap = circuit->GetThreatMap();
	threatMap->SetThreatType(unit);
	auto canMoveTo = [&](const CMetalData::SCluster& cluster) {
		for (size_t idx : cluster.idxSpots) {
			if (terrainMgr->CanMoveToPos(area, spots[idx].position)
				&& threatMap->GetThreatAt(spots[idx].position) < THREAT_MIN)
			{
				return true;
			}
		}
		return false;
	};
	int bestScore = -1;
	int bestScouted = 0;
	int bestIndex = -1;
	int numToScout = 0;
	for (size_t index = 0; index < scoutPoints.size(); ++index) {
		const SScoutPoint& sp = scoutPoints[index];
		if ((sp.task != nullptr) || metalMgr->IsClusterQueued(index) || metalMgr->IsClusterFinished(index) || !canMoveTo(clusters[index])) {
			continue;
		}
		numToScout++;
		if ((bestScore < sp.score) || ((sp.score == bestScore) && (bestScouted > sp.scouted))) {
			bestScore = sp.score;
			bestIndex = index;
			bestScouted = sp.scouted;
		}
	}
	if ((numToScout <= 1) || (bestIndex == -1)) {
		return -RgtVector;
	}

	SScoutPoint& sp = scoutPoints[bestIndex];
	const CMetalData::SCluster& cluster = clusters[bestIndex];
	while (sp.spotNum < (int)cluster.idxSpots.size()) {
		const CMetalData::SMetal& spot = spots[cluster.idxSpots[sp.spotNum]];
		if (terrainMgr->CanMoveToPos(area, spot.position)
			&& threatMap->GetThreatAt(spot.position) < THREAT_MIN)
		{
			break;
		}
		++sp.spotNum;
	}
	if (sp.spotNum >= (int)cluster.idxSpots.size()) {
		sp.spotNum = 0;
		sp.scouted++;
		return -RgtVector;
	}
	const AIFloat3& spotPos = spots[cluster.idxSpots[sp.spotNum]].position;
	if (pos.SqDistance2D(spotPos) < SQUARE(threatMap->GetSquareSize() * 2)) {  // arrival condition
		++sp.spotNum %= cluster.idxSpots.size();
		if (sp.spotNum == 0) {
			sp.scouted++;
		}
	}
	sp.task = unit->GetTask();
	scoutTasks[unit->GetTask()] = bestIndex;
	return spotPos;
}

void CMilitaryManager::ClearScoutPosition(IUnitTask* task)
{
	auto it = scoutTasks.find(task);
	if (it == scoutTasks.end()) {
		return;
	}
	scoutPoints[it->second].task = nullptr;
	scoutTasks.erase(it);
}

void CMilitaryManager::FillFrontPos(CCircuitUnit* unit, F3Vec& outPositions)
{
	outPositions.clear();

	CInfluenceMap* inflMap = circuit->GetInflMap();
	CMetalManager* metalMgr = circuit->GetMetalManager();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	SArea* area = unit->GetArea();
	const CMetalData::Clusters& clusters = metalMgr->GetClusters();

	CMetalData::PointPredicate predicate = [inflMap, metalMgr, terrainMgr, area, clusters](const int index) {
		return ((inflMap->GetInfluenceAt(clusters[index].position) > -INFL_EPS)
			&& (metalMgr->IsClusterQueued(index) || metalMgr->IsClusterFinished(index))
			&& terrainMgr->CanMoveToPos(area, clusters[index].position));
	};

	CSetupManager* setupMgr = circuit->GetSetupManager();
	int index = metalMgr->FindNearestCluster(setupMgr->GetLanePos(), predicate);

	if (index >= 0) {
		const CDefenceData::DefPoints& points = defence->GetDefPoints();
		const CDefenceData::DefIndices& indices = defence->GetDefIndices(index);
		for (int idx : indices) {
			outPositions.push_back(points[idx].position);
		}
	}
}

void CMilitaryManager::FillAttackSafePos(CCircuitUnit* unit, F3Vec& outPositions)
{
	outPositions.clear();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();

	SArea* area = unit->GetArea();

	const std::array<IFighterTask::FightType, 2> types = {IFighterTask::FightType::ATTACK, IFighterTask::FightType::DEFEND};
	for (IFighterTask::FightType type : types) {
		const std::set<IFighterTask*>& atkTasks = GetTasks(type);
		for (IFighterTask* task : atkTasks) {
			const AIFloat3& ourPos = static_cast<ISquadTask*>(task)->GetLeaderPos(frame);
			if (terrainMgr->CanMoveToPos(area, ourPos)) {
				outPositions.push_back(ourPos);
			}
		}
	}
}

void CMilitaryManager::FillStaticSafePos(CCircuitUnit* unit, F3Vec& outPositions)
{
	outPositions.clear();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();

	const AIFloat3& startPos = unit->GetPos(frame);
	SArea* area = unit->GetArea();

	CDefenceData* defDat = defence;
	const CDefenceData::DefPoints& points = defence->GetDefPoints();
	CMetalData::PointPredicate predicate = [defDat, terrainMgr, area, &points](const int index) {
		const CDefenceData::DefIndices& indices = defDat->GetDefIndices(index);
		for (int idx : indices) {
			if ((points[idx].cost > 100.0f) && terrainMgr->CanMoveToPos(area, points[idx].position)) {
				return true;
			}
		}
		return false;
	};

	CMetalManager* metalMgr = circuit->GetMetalManager();
	int index = metalMgr->FindNearestCluster(startPos, predicate);

	if (index >= 0) {
		const CDefenceData::DefIndices& indices = defence->GetDefIndices(index);
		for (int idx : indices) {
			outPositions.push_back(points[idx].position);
		}
	}
}

void CMilitaryManager::FillSafePos(CCircuitUnit* unit, F3Vec& outPositions)
{
	outPositions.clear();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();

	const springai::AIFloat3& pos = unit->GetPos(frame);
	SArea* area = unit->GetArea();

	const std::array<IFighterTask::FightType, 2> types = {IFighterTask::FightType::ATTACK, IFighterTask::FightType::DEFEND};
	for (IFighterTask::FightType type : types) {
		const std::set<IFighterTask*>& atkTasks = GetTasks(type);
		for (IFighterTask* task : atkTasks) {
			const AIFloat3& ourPos = static_cast<ISquadTask*>(task)->GetLeaderPos(frame);
			if (terrainMgr->CanMoveToPos(area, ourPos)) {
				outPositions.push_back(ourPos);
			}
		}
		if (!outPositions.empty()) {
			return;
		}
	}

	CDefenceData* defDat = defence;
	const CDefenceData::DefPoints& points = defence->GetDefPoints();
	CMetalData::PointPredicate predicate = [defDat, terrainMgr, area, &points](const int index) {
		const CDefenceData::DefIndices& indices = defDat->GetDefIndices(index);
		for (int idx : indices) {
			if ((points[idx].cost > 100.0f) && terrainMgr->CanMoveToPos(area, points[idx].position)) {
				return true;
			}
		}
		return false;
	};
	CMetalManager* metalMgr = circuit->GetMetalManager();
	int index = metalMgr->FindNearestCluster(pos, predicate);
	if (index >= 0) {
		const CDefenceData::DefIndices& indices = defence->GetDefIndices(index);
		for (int idx : indices) {
			outPositions.push_back(points[idx].position);
		}
	}

	if (outPositions.empty()) {
		outPositions.push_back(circuit->GetSetupManager()->GetBasePos());
	}
}

CCircuitUnit* CMilitaryManager::GetClosestLeader(const std::vector<IFighterTask::FightType>& types, const AIFloat3& position)
{
	IFighterTask* task = nullptr;
	float sqMinDist = std::numeric_limits<float>::max();
	for (IFighterTask::FightType type : types) {
		const std::set<IFighterTask*>& tasks = GetTasks(type);
		for (IFighterTask* t : tasks) {
			const float sqDist = t->GetPosition().SqDistance2D(position);
			if (sqMinDist > sqDist) {
				sqMinDist = sqDist;
				task = t;
			}
		}
		if (task != nullptr) {
			break;
		}
	}
	if ((task == nullptr) || task->GetAssignees().empty()) {
		return nullptr;
	}
	return (task->GetAssignees().size() > 1)
			? static_cast<ISquadTask*>(task)->GetLeader()
			: *task->GetAssignees().begin();
}

IFighterTask* CMilitaryManager::GetGuardTask(CCircuitUnit* unit) const
{
	auto it = guardTasks.find(unit);
	return (it != guardTasks.end()) ? it->second : nullptr;
}

void CMilitaryManager::AddResponse(CCircuitUnit* unit)
{
	const CCircuitDef* cdef = unit->GetCircuitDef();
	const float cost = cdef->GetCostM();
	const CCircuitDef::RoleT roleSize = CCircuitDef::GetRoleNames().size();
	assert(roleInfos.size() == (size_t)roleSize);
	for (CCircuitDef::RoleT type = 0; type < roleSize; ++type) {
		if (cdef->IsRespRoleAny(CCircuitDef::GetMask(type))) {
			roleInfos[type].cost += cost;
			roleInfos[type].units.insert(unit);
		}
	}
}

void CMilitaryManager::DelResponse(CCircuitUnit* unit)
{
	const CCircuitDef* cdef = unit->GetCircuitDef();
	const float cost = cdef->GetCostM();
	const CCircuitDef::RoleT roleSize = CCircuitDef::GetRoleNames().size();
	assert(roleInfos.size() == (size_t)roleSize);
	for (CCircuitDef::RoleT type = 0; type < roleSize; ++type) {
		if (cdef->IsRespRoleAny(CCircuitDef::GetMask(type))) {
			float& metal = roleInfos[type].cost;
			metal = std::max(metal - cost, .0f);
			roleInfos[type].units.erase(unit);
		}
	}
}

float CMilitaryManager::RoleProbability(const CCircuitDef* cdef) const
{
	CEnemyManager* enemyMgr = circuit->GetEnemyManager();
	const SRoleInfo& info = roleInfos[cdef->GetMainRole()];
	float maxProb = 0.f;
	for (const SRoleInfo::SVsInfo& vs : info.vs) {
		const float enemyMetal = enemyMgr->GetEnemyCost(vs.role);
		const float prob = enemyMetal / (info.cost + 1.f) * vs.importance;
		if ((prob > maxProb) &&
			(enemyMetal * vs.ratio >= info.cost * info.factor) &&
			(info.cost + cdef->GetCostM() <= (armyCost + cdef->GetCostM()) * info.maxPerc))
		{
			maxProb = prob;
		}
	}
	return maxProb;
}

bool CMilitaryManager::IsNeedBigGun(const CCircuitDef* cdef) const
{
	return armyCost * circuit->GetEconomyManager()->GetEcoFactor() > cdef->GetCostM();
}

AIFloat3 CMilitaryManager::GetBigGunPos(CCircuitDef* bigDef) const
{
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	AIFloat3 pos = circuit->GetSetupManager()->GetBasePos();
	if (bigDef->GetMaxRange() < std::max(terrainMgr->GetTerrainWidth(), terrainMgr->GetTerrainHeight())) {
		CMetalManager* metalMgr = circuit->GetMetalManager();
		const CMetalData::Clusters& clusters = metalMgr->GetClusters();
		unsigned size = 1;
		for (unsigned i = 0; i < clusters.size(); ++i) {
			if (metalMgr->IsClusterFinished(i)) {
				pos += clusters[i].position;
				++size;
			}
		}
		pos /= size;
	}
	return pos;
}

void CMilitaryManager::DiceBigGun()
{
	const SuperInfos& superInfos = GetSideInfo().superInfos;
	if (superInfos.empty()) {
		return;
	}

	SuperInfos candidates;
	candidates.reserve(superInfos.size());
	float magnitude = 0.f;
	for (auto& info : superInfos) {
		if (info.first->IsAvailable(circuit->GetLastFrame())) {
			candidates.push_back(info);
			magnitude += info.second;
		}
	}
	if ((magnitude == 0.f) || candidates.empty()) {
		bigGunDef = superInfos[0].first;
		return;
	}

	unsigned choice = 0;
	float dice = (float)rand() / RAND_MAX * magnitude;
	for (unsigned i = 0; i < candidates.size(); ++i) {
		dice -= candidates[i].second;
		if (dice < 0.f) {
			choice = i;
			break;
		}
	}
	bigGunDef = candidates[choice].first;
}

float CMilitaryManager::ClampMobileCostRatio() const
{
	const float enemyMobileCost = circuit->GetEnemyManager()->GetEnemyMobileCost();
	return (enemyMobileCost > armyCost) ? (armyCost / enemyMobileCost) : 1.f;
}

/*
 * How many EMP shots could land on one point at once. Paralysis accumulates,
 * so a target too healthy for one shot can still be held by a salvo. This
 * counts every stocked EMP silo we own rather than only those whose range
 * covers a specific point: an over-estimate when silos are spread out, but
 * the firing silo always covers its own candidates, so the first shot is
 * never wasted on a target the salvo cannot finish.
 */
/*
 * Porcupine chain accessors. The chain is the ordered list of defence defs a
 * cluster works through; build_chain.json seeds it per side and these let the
 * active role rewrite it at setup. Reading returns unit names so script can
 * splice the list; writing resolves them back, warns on anything unknown, and
 * applies the FENCE attribute the JSON path applies, so a def added by script
 * counts toward cluster defence cost like any other.
 */
std::vector<std::string> CMilitaryManager::GetPorcChain(const std::string& sideName, bool isWater) const
{
	std::vector<std::string> names;
	CMaskHandler& sideMasker = circuit->GetGameAttribute()->GetSideMasker();
	if (!sideMasker.HasType(sideName)) {
		circuit->LOG("PORC: GetPorcChain unknown side '%s'", sideName.c_str());
		return names;
	}
	const CMaskHandler::Type type = sideMasker.GetTypeMask(sideName).type;
	if ((type < 0) || (type >= int(sideInfos.size()))) {
		return names;
	}
	const std::vector<CCircuitDef*>& chain = isWater
			? sideInfos[type].waterDefenders : sideInfos[type].landDefenders;
	names.reserve(chain.size());
	for (CCircuitDef* cdef : chain) {
		if (cdef != nullptr) {
			names.push_back(cdef->GetDef()->GetName());
		}
	}
	return names;
}

bool CMilitaryManager::SetPorcChain(const std::string& sideName, bool isWater, const std::vector<std::string>& names)
{
	CMaskHandler& sideMasker = circuit->GetGameAttribute()->GetSideMasker();
	if (!sideMasker.HasType(sideName)) {
		circuit->LOG("PORC: SetPorcChain unknown side '%s'", sideName.c_str());
		return false;
	}
	const CMaskHandler::Type type = sideMasker.GetTypeMask(sideName).type;
	if ((type < 0) || (type >= int(sideInfos.size()))) {
		return false;
	}
	std::vector<CCircuitDef*> chain;
	chain.reserve(names.size());
	int unknown = 0;
	for (const std::string& name : names) {
		CCircuitDef* cdef = circuit->GetCircuitDef(name.c_str());
		if (cdef == nullptr) {
			++unknown;
			circuit->LOG("PORC: SetPorcChain unknown UnitDef '%s'", name.c_str());
			continue;
		}
		cdef->AddAttribute(ATTR_TYPE(FENCE));
		chain.push_back(cdef);
	}
	if (chain.empty()) {
		circuit->LOG("PORC: SetPorcChain for '%s' %s resolved to nothing; keeping the existing chain",
				sideName.c_str(), isWater ? "water" : "land");
		return false;
	}
	if (isWater) {
		sideInfos[type].waterDefenders = std::move(chain);
	} else {
		sideInfos[type].landDefenders = std::move(chain);
	}
	circuit->LOG("PORC: %s %s chain set to %zu defs (%i unknown skipped)",
			sideName.c_str(), isWater ? "water" : "land",
			isWater ? sideInfos[type].waterDefenders.size() : sideInfos[type].landDefenders.size(), unknown);
	return true;
}

int CMilitaryManager::GetEmpSalvoSize() const
{
	if (!empInfo.isEnabled) {
		return 1;
	}
	int count = 0;
	for (CCircuitUnit* unit : stockpilers) {
		CCircuitDef* cdef = unit->GetCircuitDef();
		if ((cdef == nullptr) || !cdef->IsRespRoleAny(empInfo.empRole)) {
			continue;
		}
		if (unit->GetUnit()->GetStockpile() > 0) {
			++count;
		}
	}
	return std::max(1, count);
}

void CMilitaryManager::UpdateDefenceTasks()
{
	/*
	 * Stockpile
	 */
	for (CCircuitUnit* unit : stockpilers) {
		TRY_UNIT(circuit, unit,
			unit->GetUnit()->Stockpile(UNIT_COMMAND_OPTION_SHIFT_KEY | UNIT_COMMAND_OPTION_CONTROL_KEY);
		)
	}

	/*
	 * Defend expansion
	 */
	const std::set<IFighterTask*>& tasks = GetTasks(IFighterTask::FightType::DEFEND);
	CMetalManager* mm = circuit->GetMetalManager();
//	CEconomyManager* em = circuit->GetEconomyManager();
//	CTerrainManager* tm = circuit->GetTerrainManager();
//	const CMetalData::Metals& spots = mm->GetSpots();
	const CMetalData::Clusters& clusters = mm->GetClusters();
//	const std::vector<CEnemyManager::SEnemyGroup>& enemyGroups = circuit->GetEnemyManager()->GetEnemyGroups();
	for (IFighterTask* task : tasks) {
		CDefendTask* dt = static_cast<CDefendTask*>(task);
//		if (dt->GetTarget() != nullptr) {
//			continue;
//		}
//		STerrainMapArea* area = dt->GetLeader()->GetArea();
//		CMetalData::PointPredicate predicate = [em, tm, area, &spots, &clusters](const int index) {
//			const CMetalData::MetalIndices& idcs = clusters[index].idxSpots;
//			for (int idx : idcs) {
//				if (!em->IsOpenSpot(idx) && tm->CanMoveToPos(area, spots[idx].position)) {
//					return true;
//				}
//			}
//			return false;
//		};
//		AIFloat3 center = tm->GetTerrainCenter();
//		int index = mm->FindNearestCluster(center, predicate);
//		if (index >= 0) {
//			dt->SetPosition(clusters[index].position);
//		}

		if (dt->IsGather() || dt->GetPromote() != IFighterTask::FightType::ATTACK) {
			continue;
		}
//		int groupIdx = -1;
//		float minSqDist = std::numeric_limits<float>::max();
//		const AIFloat3& position = dt->GetPosition();
//		for (unsigned i = 0; i < enemyGroups.size(); ++i) {
//			const CEnemyManager::SEnemyGroup& group = enemyGroups[i];
//			const float sqDist = position.SqDistance2D(group.pos);
//			if (sqDist < minSqDist) {
//				minSqDist = sqDist;
//				groupIdx = i;
//			}
//		}
//		if (groupIdx >= 0) {
//			dt->SetMaxPower(std::max(minAttackers, enemyGroups[groupIdx].threat));
//		}
		if (attackScale <= 0.f) {
			// Legacy: the map-wide second-strongest enemy group, whatever domain it is in.
			dt->SetMaxPower(std::max(minAttackers, circuit->GetEnemyManager()->GetPreMaxGroupThreat()));
			continue;
		}
		// Reachable rule: the strongest enemy group the squad's leader can path
		// to. A cruiser squad is measured against what it can fight, not the
		// enemy's land army; a land squad likewise ignores the enemy navy.
		CCircuitUnit* leader = dt->GetLeader();
		float threat = -1.f;
		if (leader != nullptr) {
			CTerrainManager* terrainMgr = circuit->GetTerrainManager();
			for (const CEnemyManager::SEnemyGroup& g : circuit->GetEnemyManager()->GetEnemyGroups()) {
				if (g.units.empty() || !terrainMgr->CanMoveToPos(leader->GetArea(), g.pos)) {
					continue;
				}
				threat = std::max(threat, g.influence);
			}
		}
		if (threat < 0.f) {  // nothing reachable is known: fall back to the legacy bar
			threat = circuit->GetEnemyManager()->GetPreMaxGroupThreat();
		}
		dt->SetMaxPower(std::max(minAttackers, threat * attackScale));
	}

	/*
	 * Porc update. Our own clusters, plus - with porcAllyAA - every cluster
	 * that sits in an ally's zone, which DefaultMakeDefence then treats as
	 * AA-only.
	 */
	CTerrainManager* porcTerrain = circuit->GetTerrainManager();
	auto wantsPorc = [this, mm, porcTerrain, &clusters](int index) {
		if (mm->IsClusterQueued(index) || mm->IsClusterFinished(index)) {
			return true;
		}
		return (porcAllyAA != 0) && porcTerrain->IsZoneAlly(clusters[index].position);
	};
	decltype(defenceIdx) prevIdx = defenceIdx;
	while (defenceIdx < clusters.size()) {
		int index = defenceIdx++;
		if (wantsPorc(index)) {
			MakeDefence(index);
			return;
		}
	}
	defenceIdx = 0;
	while (defenceIdx < prevIdx) {
		int index = defenceIdx++;
		if (wantsPorc(index)) {
			MakeDefence(index);
			return;
		}
	}
}

/*
 * Mobile sensor escort. See SSensorInfo in the header for why the escort is
 * rationed at all; these are the shared predicates CSupportTask picks with and
 * the sweep that undoes a surplus created behind its back.
 */
bool CMilitaryManager::IsSensorUnit(const CCircuitDef* cdef) const
{
	// The parser puts secondary role labels in enemyRole, not respRole.
	// Radar/jammer vehicles commonly carry these labels after assault/support.
	// Include that classification only while the opt-in ranged owner exists;
	// leave legacy squad rationing unchanged when no ranged cohort is present.
	return sensorInfo.isEnabled && (cdef != nullptr)
			&& cdef->IsMobile() && (cdef->IsRespRoleAny(sensorInfo.sensorRole)
				|| (HasRangedUnits() && cdef->IsEnemyRoleAny(sensorInfo.sensorRole)));
}

int CMilitaryManager::CountSensors(const IFighterTask* task) const
{
	if (task == nullptr) {
		return 0;
	}
	int count = 0;
	for (const CCircuitUnit* unit : task->GetAssignees()) {
		if (IsSensorUnit(unit->GetCircuitDef())) {
			++count;
		}
	}
	return count;
}

bool CMilitaryManager::NeedsSensor(const IFighterTask* task) const
{
	return CountSensors(task) < sensorInfo.maxPerSquad;
}

float CMilitaryManager::GetSquadValue(const IFighterTask* task) const
{
	// The leader is the squad's most capable unit, so its cost is the tier
	// ranking asked for without having to walk the whole squad.
	const CCircuitUnit* leader = static_cast<const ISquadTask*>(task)->GetLeader();
	return ((leader == nullptr) || (leader->GetCircuitDef() == nullptr))
			? 0.f : leader->GetCircuitDef()->GetCostM();
}

/*
 * CSupportTask caps sensors at the moment one joins, but two squads that each
 * hold their one sensor can still merge into a squad holding two. Rather than
 * reach into ISquadTask::Merge - which runs mid-iteration over the absorbed
 * squad - the surplus is swept up afterwards: the extra sensors are dropped
 * back to no task, and MakeTask gives each a fresh CSupportTask that re-picks
 * an uncovered squad on its next update.
 */
void CMilitaryManager::UpdateSensorGuards()
{
	if (!sensorInfo.isEnabled || !sensorInfo.rebalance) {
		return;
	}
	ZoneScoped;

	std::vector<CCircuitUnit*> surplus;
	static const bool rangedTrace=std::getenv("CIRCUIT_RANGED_TRACE")!=nullptr;
	for (IFighterTask::FightType type : {IFighterTask::FightType::ATTACK, IFighterTask::FightType::DEFEND,
			IFighterTask::FightType::GUARD}) {
		if (type==IFighterTask::FightType::GUARD && !HasRangedUnits()) continue;
		for (IFighterTask* task : GetTasks(type)) {
			if(rangedTrace && HasRangedUnits()) circuit->LOG("RANGED: sensor group type=%d sensors=%d members=%u",int(type),CountSensors(task),unsigned(task->GetAssignees().size()));
			if (HasRangedUnits() && CountSensors(task)==int(task->GetAssignees().size())) {
				// A sensor built before the first ranged gun may already own a
				// sensor-only staging squad. Let it join an uncovered ranged cohort
				// without stripping a fighting squad of its existing escort.
				for (CCircuitUnit* unit : task->GetAssignees()) {
					AIFloat3 destination;
					if (rangedWorld->Escort(unit,destination)) surplus.push_back(unit);
				}
				continue;
			}
			// Guard groups can contain real defensive combat units. Only an
			// entirely sensor-only guard is eligible for the ranged reassignment.
			if (type==IFighterTask::FightType::GUARD) continue;
			int slack = CountSensors(task) - sensorInfo.maxPerSquad;
			if (slack <= 0) {
				continue;
			}
			for (CCircuitUnit* unit : task->GetAssignees()) {
				if (slack <= 0) {
					break;
				}
				if (IsSensorUnit(unit->GetCircuitDef())) {
					surplus.push_back(unit);
					--slack;
				}
			}
		}
	}
	for (CCircuitUnit* unit : surplus) {
		if (unit->GetTask() == nullptr) {  // an earlier release may have retasked it
			continue;
		}
		// Ranged staging releases need the explicit handover overload: the
		// one-argument AssignTask only removes idle membership, not a live squad.
		// Preserve the legacy rebalancer path outside this opt-in cohort.
		if (HasRangedUnits()) AssignTask(unit, Enqueue(TaskF::Common(IFighterTask::FightType::SUPPORT)));
		else AssignTask(unit);
	}
	if (!surplus.empty()) {
		circuit->LOG("SENSOR: released %i surplus escort(s)", int(surplus.size()));
	}
}

springai::AIFloat3 CMilitaryManager::GetCombatFocusPos() const
{
	const int frame = circuit->GetLastFrame();
	const IFighterTask* best = nullptr;
	float bestPower = 0.f;
	for (const IFighterTask* task : GetTasks(IFighterTask::FightType::ATTACK)) {
		if ((best == nullptr) || (task->GetAttackPower() > bestPower)) {
			bestPower = task->GetAttackPower();
			best = task;
		}
	}
	if (best != nullptr) {
		const CCircuitUnit* leader = static_cast<const ISquadTask*>(best)->GetLeader();
		if (leader != nullptr) {
			return static_cast<const ISquadTask*>(best)->GetLeaderPos(frame);
		}
	}
	// No army out: the enemy centroid is the best available guess at where the
	// fighting is about to be.
	const springai::AIFloat3& ePos = circuit->GetEnemyManager()->GetEnemyPos();
	if (geom::is_valid(ePos)) {
		return ePos;
	}
	return springai::AIFloat3(-RgtVector);
}

void CMilitaryManager::UpdateDefence()
{
	ZoneScoped;

	const int frame = circuit->GetLastFrame();
	decltype(buildDefence)::iterator ibd = buildDefence.begin();
	while (ibd != buildDefence.end()) {
		const auto& defElem = ibd->second.back();
		if (frame >= defElem.second) {
			CCircuitDef* buildDef = defElem.first;
			if (buildDef->IsAvailable(frame)) {
				circuit->GetBuilderManager()->Enqueue(TaskB::Common(IBuilderTask::BuildType::DEFENCE,
						IBuilderTask::Priority::NORMAL, buildDef, ibd->first, 0.f, true, 0));
			}
			ibd->second.pop_back();
		}
		if (ibd->second.empty()) {
			ibd = buildDefence.erase(ibd);
		} else {
			++ibd;
		}
	}
	if (buildDefence.empty()) {
		circuit->GetScheduler()->RemoveJob(defend);
		defend = nullptr;
	}
}

void CMilitaryManager::MakeBaseDefence(const AIFloat3& pos)
{
	if (circuit->IsLoadSave()) {
		return;
	}
	const BuildVector& baseDefence = GetSideInfo().baseDefence;
	if (baseDefence.empty()) {
		return;
	}
	buildDefence.emplace_back(pos, baseDefence);
	if (defend == nullptr) {
		defend = CScheduler::GameJob(&CMilitaryManager::UpdateDefence, this);
		circuit->GetScheduler()->RunJobEvery(defend, FRAMES_PER_SEC);
	}
}

void CMilitaryManager::AddSensorDefs(const std::set<CCircuitDef*>& buildDefs)
{
	radarDefs.AddDefs(buildDefs);
	sonarDefs.AddDefs(buildDefs);

	// DEBUG
//	std::vector<std::pair<std::string, CAvailList<SSensorExt>*>> vec = {{"Radar", &radarDefs}, {"Sonar", &sonarDefs}};
//	for (const auto& kv : vec) {
//		circuit->LOG("----%s Sensor----", kv.first.c_str());
//		for (const auto& si : kv.second->GetInfos()) {
//			circuit->LOG("%s | costM=%f | costE=%f | radius=%f | efficiency=%f", si.cdef->GetDef()->GetName(),
//					si.cdef->GetCostM(), si.cdef->GetCostE(), si.data.radius, si.score);
//		}
//	}
}

void CMilitaryManager::RemoveSensorDefs(const std::set<CCircuitDef*>& buildDefs)
{
	radarDefs.RemoveDefs(buildDefs);
	sonarDefs.RemoveDefs(buildDefs);

	// DEBUG
//	std::vector<std::pair<std::string, CAvailList<SSensorExt>*>> vec = {{"Radar", &radarDefs}, {"Sonar", &sonarDefs}};
//	for (const auto& kv : vec) {
//		circuit->LOG("----Remove %s Sensor----", kv.first.c_str());
//		for (const auto& si : kv.second->GetInfos()) {
//			circuit->LOG("%s | costM=%f | costE=%f | radius=%f | efficiency=%f", si.cdef->GetDef()->GetName(),
//					si.cdef->GetCostM(), si.cdef->GetCostE(), si.data.radius, si.score);
//		}
//	}
}

const CMilitaryManager::SSideInfo& CMilitaryManager::GetSideInfo() const
{
	return sideInfos[circuit->GetSideId()];
}

CCircuitDef* CMilitaryManager::GetLowSonar(const CCircuitUnit* builder) const
{
	const int frame = circuit->GetLastFrame();
	return sonarDefs.GetWorstDef([frame, builder](CCircuitDef* cdef, const SSensorExt& data) {
		return cdef->IsAvailable(frame) && ((builder == nullptr) || builder->GetCircuitDef()->CanBuild(cdef));
	});
}

CEnemyInfo* CMilitaryManager::FindBCombatTarget(CCircuitUnit* unit, const AIFloat3& pos,
		float powerMod, bool isTest)
{
	const AIFloat3& basePos = circuit->GetSetupManager()->GetBasePos();
	if (pos.SqDistance2D(basePos) > SQUARE(GetBaseDefRange())) {
		return nullptr;
	}

	CMap* map = circuit->GetMap();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CThreatMap* threatMap = circuit->GetThreatMap();
	CInfluenceMap* inflMap = circuit->GetInflMap();
	SArea* area = unit->GetArea();
	CCircuitDef* cdef = unit->GetCircuitDef();
	const float maxSpeed = SQUARE(cdef->GetSpeed() / FRAMES_PER_SEC);
	const float maxPower = threatMap->GetUnitPower(unit) * powerMod;
	const float weaponRange = cdef->GetMaxRange() * 0.9f;
	const int canTargetCat = cdef->GetTargetCategory();
	const int noChaseCat = cdef->GetNoChaseCategory();
	const float sqCommRadBegin = SQUARE(GetCommDefRadBegin());
	float minSqDist = SQUARE(GetCommDefRad(pos.distance2D(basePos)));

	CEnemyInfo* bestTarget = nullptr;
	CEnemyInfo* worstTarget = nullptr;
	threatMap->SetThreatType(unit);
	const CCircuitAI::EnemyInfos& enemies = circuit->GetEnemyInfos();
	for (auto& kv : enemies) {
		CEnemyInfo* enemy = kv.second;
		// TODO: check how close is another task, and its movement vector
		if (enemy->IsHidden() || (enemy->GetTasks().size() > 1)) {
			continue;
		}

		const AIFloat3& ePos = enemy->GetPos();
		const float sqDist = pos.SqDistance2D(ePos);
		if ((basePos.SqDistance2D(ePos) > sqCommRadBegin) && (sqDist > minSqDist)) {
			continue;
		}

		const float power = threatMap->GetThreatAt(ePos);
		if ((maxPower <= power)
			|| (inflMap->GetAllyDefendInflAt(ePos) < INFL_EPS)
			|| !terrainMgr->CanMoveToPos(area, ePos))
		{
			continue;
		}

		const AIFloat3& eVel = enemy->GetVel();
		if (eVel.SqLength2D() >= maxSpeed) {  // speed
			const AIFloat3 uVec = pos - ePos;
			const float dotProduct = eVel.dot2D(uVec);
//			if (dotProduct < 0) {  // direction (angle > 90 deg)
//				continue;
//			}
			if (dotProduct < SQRT_3_2 * sqrtf(eVel.SqLength2D() * uVec.SqLength2D())) {  // direction (angle > 30 deg)
				continue;
			}
		}

		int targetCat;
		const float elevation = map->GetElevationAt(ePos.x, ePos.z);
		const bool IsInWater = cdef->IsPredictInWater(elevation);
		CCircuitDef* edef = enemy->GetCircuitDef();
		if (edef != nullptr) {
			targetCat = edef->GetCategory();
			if (((targetCat & canTargetCat) == 0)
				|| circuit->GetCircuitDef(edef->GetId())->IsIgnore()
				|| (edef->IsAbleToFly() && !(IsInWater ? cdef->HasSubToAir() : cdef->HasSurfToAir())))  // notAA
			{
				continue;
			}
			float elevation = map->GetElevationAt(ePos.x, ePos.z);
			if (edef->IsInWater(elevation, ePos.y)) {
				if (!(IsInWater ? cdef->HasSubToWater() : cdef->HasSurfToWater())) {  // notAW
					continue;
				}
			} else {
				if (!(IsInWater ? cdef->HasSubToLand() : cdef->HasSurfToLand())) {  // notAL
					continue;
				}
			}
			if (ePos.y - elevation > weaponRange) {
				continue;
			}
		} else {
			if (!(IsInWater ? cdef->HasSubToWater() : cdef->HasSurfToWater()) && (ePos.y < -SQUARE_SIZE * 5)) {  // notAW
				continue;
			}
			targetCat = UNKNOWN_CATEGORY;
		}

		if (enemy->IsInRadarOrLOS()) {
			if (isTest) {
				return enemy;
			}
			if ((targetCat & noChaseCat) == 0) {
				bestTarget = enemy;
				minSqDist = sqDist;
			} else if (bestTarget == nullptr) {
				worstTarget = enemy;
			}
		}
	}
	if (bestTarget == nullptr) {
		bestTarget = worstTarget;
	}

	return bestTarget;
}

float CMilitaryManager::GetRangeUnitCountCompensatorScale()
{
	if (threatRangeScaling.frame < circuit->GetLastFrame()) {
		threatRangeScaling.frame = circuit->GetLastFrame() + TEAM_SLOWUPDATE_RATE - 1;
		const int enemyTeamSize = circuit->GetEnemyTeamSize();
		const int totalEnemies = circuit->GetEnemyInfos().size();
		const int enemyCountMinToStartScaling = threatRangeScaling.enemyCountPerEnemyTeamToStartScaling * enemyTeamSize;
		const int enemyCountForMaxScale = threatRangeScaling.enemyCountPerEnemyTeamToEndScaling * enemyTeamSize;
		const float rateAdjPerUnit = 1.0f / (float)(enemyCountForMaxScale - enemyCountMinToStartScaling);
		threatRangeScaling.scale = std::min(1.0f, std::max(threatRangeScaling.endScaleValue, 1.0f - (totalEnemies - enemyCountMinToStartScaling) * rateAdjPerUnit));
//		circuit->LOG("getRangeUnitCountCompensatorScale: %f, totalEnemies %i, minEnemyCountBeforeScaling %i, rateAdjPerUnit %f",
//				threatRangeScaling.scale, totalEnemies, enemyCountMinToStartScaling, rateAdjPerUnit);
	}
	return threatRangeScaling.scale;
}

std::shared_ptr<CRangedWorld> CMilitaryManager::GetRangedWorld()
{
	if (!rangedWorld) rangedWorld = std::make_shared<CRangedWorld>(circuit);
	return rangedWorld;
}

bool CMilitaryManager::HasRangedUnits() const
{
	return rangedWorld && rangedWorld->HasMembers();
}

IUnitTask* CMilitaryManager::TryMakeRangedTask(CCircuitUnit* unit)
{
	if (unit == nullptr) return nullptr;
	CCircuitDef* def = unit->GetCircuitDef();
	// Ordinary assignment only: specialist missions and player control keep
	// their owner. No polling loop steals already assigned units.
	if (!def->IsAttrRanged() || !def->IsMobile() || !def->IsLander()
			|| def->IsAbleToFly() || def->IsRoleTrans()) return nullptr;
	return Enqueue(TaskF::Common(IFighterTask::FightType::ARTY));
}

IUnitTask* CMilitaryManager::MakeTask(CCircuitUnit* unit)
{
    if (!externalOwnerRule.empty() && externalOwnerCandidates.count(unit->GetId())
        && unit->GetUnit()->GetRulesParamFloat(externalOwnerRule.c_str(),-1.f) >= 0.f)
        return EnqueueExternalControl(externalOwnerRule);
    return ITaskModule::MakeTask(unit);
}

void CMilitaryManager::UpdateExternalControl()
{
    if (externalOwnerRule.empty()) return;
    // Lifecycle membership avoids an army census. Creation can precede BAR's
    // attachment RulesParam, so inspect these few candidates at the EXISTING
    // idle-dispatch cadence. O(candidate drones), no per-army wrappers/orders.
    // Reacquire IDs; capture/destruction clears membership. External tasks
    // release themselves when the gadget clears its owner, including death.
    // AssignTask invokes script hooks; those may destroy another candidate.
    // Retain an ID snapshot (capacity reused), never a set iterator across it.
    externalOwnerSnapshot.assign(externalOwnerCandidates.begin(),externalOwnerCandidates.end());
    for (const int id : externalOwnerSnapshot) {
        auto* unit=circuit->GetTeamUnit(id);
        if (!unit || unit->IsDead()) { externalOwnerCandidates.erase(id); continue; }
        auto* task=unit->GetTask();
        if (!task || task->GetManager()!=this || task->IsExternalControlled()
            || task->GetType()==IUnitTask::Type::PLAYER) continue;
        if (unit->GetUnit()->GetRulesParamFloat(externalOwnerRule.c_str(),-1.f) < 0.f) continue;
        auto* external=EnqueueExternalControl(externalOwnerRule);
        AssignTask(unit,external); // external AssignTo/Start never alter gadget commands
    }
}

IUnitTask* CMilitaryManager::DefaultMakeTask(CCircuitUnit* unit)
{
	if (IUnitTask* ranged = TryMakeRangedTask(unit)) return ranged;
	// FIXME: Make central task assignment system.
	//        MilitaryManager should decide what tasks to merge.
	static const std::map<CCircuitDef::RoleT, IFighterTask::FightType> types = {
		{ROLE_TYPE(SCOUT),   IFighterTask::FightType::SCOUT},
		{ROLE_TYPE(RAIDER),  IFighterTask::FightType::RAID},
		{ROLE_TYPE(RIOT),    IFighterTask::FightType::DEFEND},
		{ROLE_TYPE(ARTY),    IFighterTask::FightType::ARTY},
		{ROLE_TYPE(AA),      IFighterTask::FightType::AA},
		{ROLE_TYPE(AH),      IFighterTask::FightType::AH},
		{ROLE_TYPE(BOMBER),  IFighterTask::FightType::BOMB},
		{ROLE_TYPE(SUPPORT), IFighterTask::FightType::SUPPORT},
		{ROLE_TYPE(MINE),    IFighterTask::FightType::SCOUT},  // FIXME
		{ROLE_TYPE(SUPER),   IFighterTask::FightType::SUPER},
		// NOTE: no TRANS entry here on purpose - this map is keyed on the main
		//       role, and a flying transport's main role is forced to AIR. The
		//       transport case is handled by IsRoleTrans() above.
	};
	CEnemyManager* enemyMgr = circuit->GetEnemyManager();
	IFighterTask* task = nullptr;
	CCircuitDef* cdef = unit->GetCircuitDef();
	/*
	 * Transports first, and by role *mask* rather than main role. A flying unit
	 * has its main role overwritten with AIR in the CFactoryManager constructor
	 * (`if (cdef.IsAbleToFly()) setRoles(ROLE_TYPE(AIR))`), so the
	 * {ROLE_TYPE(TRANS), FERRY} entry in the map below can never match an air
	 * transport - the mask keeps TRANS, the main role does not. Without this a
	 * transport fell through to Defend/ATTACK and was flown at the enemy, and a
	 * Legion transport tagged "support" went to CSupportTask and trailed the
	 * nearest squad instead.
	 */
	if (cdef->IsRoleTrans()) {
		task = Enqueue(TaskF::Common(IFighterTask::FightType::FERRY));
	} else if (cdef->IsRoleScout() && (GetTasks(IFighterTask::FightType::SCOUT).size() < maxScouts)) {
		task = Enqueue(TaskF::Common(IFighterTask::FightType::SCOUT));
	} else if (cdef->IsRoleSupport()) {
		if (!HasRangedUnits() && /*cdef->IsAttacker() && */GetTasks(IFighterTask::FightType::ATTACK).empty() && GetTasks(IFighterTask::FightType::DEFEND).empty()) {
			task = Enqueue(TaskF::Defend(IFighterTask::FightType::ATTACK, IFighterTask::FightType::SUPPORT, minAttackers));
		} else {
			task = Enqueue(TaskF::Common(IFighterTask::FightType::SUPPORT));
		}
	} else {
		auto it = types.find(circuit->GetBindedRole(cdef->GetMainRole()));
		if (it != types.end()) {
			switch (it->second) {
				case IFighterTask::FightType::RAID: {
					const std::set<IFighterTask*>& guards = GetTasks(IFighterTask::FightType::GUARD);
					for (IFighterTask* t : guards) {
						if (t->CanAssignTo(unit)) {
							task = t;
							break;
						}
					}
					if (task == nullptr) {
//						if (GetTasks(IFighterTask::FightType::RAID).empty()
//							|| enemyMgr->IsEnemyNear(unit->GetPos(circuit->GetLastFrame())))
//						{
							task = Enqueue(TaskF::Defend(IFighterTask::FightType::RAID, raid.min));
//						}
					}
				} break;
				case IFighterTask::FightType::AH: {
					if (!cdef->IsRoleMine() && (enemyMgr->GetEnemyCost(ROLE_TYPE(HEAVY)) < 1.f)) {
						task = Enqueue(TaskF::Common(IFighterTask::FightType::ATTACK));
					}
				} break;
				case IFighterTask::FightType::DEFEND: {
					const std::set<IFighterTask*>& guards = GetTasks(IFighterTask::FightType::GUARD);
					for (IFighterTask* t : guards) {
						if (t->CanAssignTo(unit)) {
							task = t;
							break;
						}
					}
					if (task == nullptr) {
						const float power = std::max(minAttackers, enemyMgr->GetPreMaxGroupThreat());
						task = Enqueue(TaskF::Defend(IFighterTask::FightType::ATTACK, power));
					}
				} break;
				case IFighterTask::FightType::SUPER: {
					task = Enqueue(TaskF::Common(cdef->IsMobile() ? IFighterTask::FightType::ATTACK : it->second));
				} break;
				default: break;
			}
			if (task == nullptr) {
				task = Enqueue(TaskF::Common(it->second));
			}
		} else {
//			const bool isDefend = GetTasks(IFighterTask::FightType::ATTACK).empty() || enemyMgr->IsEnemyNear(unit->GetPos(circuit->GetLastFrame()));
			const float power = std::max(minAttackers, enemyMgr->GetPreMaxGroupThreat());
			task = /*isDefend ? */Enqueue(TaskF::Defend(IFighterTask::FightType::ATTACK, power))
							/*: EnqueueTask(IFighterTask::FightType::ATTACK)*/;
		}
	}

	return task;
}

void CMilitaryManager::Watchdog()
{
	ZoneScopedN(__PRETTY_FUNCTION__);

	for (CCircuitUnit* unit : army) {
		if (unit->GetTask()->GetType() == IUnitTask::Type::PLAYER) {
			continue;
		}
		if (!circuit->GetCallback()->Unit_HasCommands(unit->GetId())) {
			UnitIdle(unit);
		}
	}
}

void CMilitaryManager::AddArmyCost(CCircuitUnit* unit)
{
	AddResponse(unit);
	armyCost += unit->GetCircuitDef()->GetCostM();
}

void CMilitaryManager::DelArmyCost(CCircuitUnit* unit)
{
	DelResponse(unit);
	armyCost = std::max(armyCost - unit->GetCircuitDef()->GetCostM(), .0f);
}

void CMilitaryManager::PointOfInterest(CEnemyInfo* enemy, int start, int step)
{
	if ((enemy->GetCircuitDef() == nullptr)
		|| (!enemy->GetCircuitDef()->IsMex() && (isEnemyFound || enemy->GetCircuitDef()->IsMobile())))
	{
		return;
	}

	CMetalManager* metalMgr = circuit->GetMetalManager();
	int clusterId = metalMgr->FindNearestCluster(enemy->GetPos());
	if (clusterId < 0) {
		return;
	}

	SScoutPoint& sp = scoutPoints[clusterId];
	sp.scouted = 0;
	if (!isEnemyFound) {
		isEnemyFound = true;
		sp.score++;
		if (!enemy->GetCircuitDef()->IsMex()) {
			return;
		}
	}
	sp.enemyNum += (start > 0) ? 1 : -1;
	if ((sp.enemyNum != ((start > 0) ? 1 : 0))) {
		return;
	}

	std::set<int> visited{clusterId};
	std::vector<std::pair<int, int>> toVisit{std::make_pair(clusterId, start)};  // clusterId, level
	const CMetalData::ClusterGraph& clusterGraph = metalMgr->GetClusterGraph();

	while (!toVisit.empty()) {
		std::pair<int, int> q = toVisit.back();
		toVisit.pop_back();

		SScoutPoint& sp = scoutPoints[q.first];
		sp.scouted = 0;
		sp.score += q.second;

		if (q.second + step == 0) {
			continue;
		}
		CMetalData::ClusterGraph::Node node = clusterGraph.nodeFromId(q.first);
		CMetalData::ClusterGraph::IncEdgeIt edgeIt(clusterGraph, node);
		for (; edgeIt != lemon::INVALID; ++edgeIt) {
			const int childId = clusterGraph.id(clusterGraph.oppositeNode(node, edgeIt));
			if (visited.find(childId) == visited.end()) {
				visited.insert(childId);
				toVisit.emplace_back(childId, q.second + step);
			}
		}
	}
#if 0
	if (circuit->GetTeamId() == 0) {
		for (size_t index = 0; index < scoutPoints.size(); ++index) {
			circuit->GetDrawer()->DeletePointsAndLines(metalMgr->GetClusters()[index].position);
		}
		circuit->GetScheduler()->RunJobAfter(CScheduler::GameJob([this]() {
			for (size_t index = 0; index < scoutPoints.size(); ++index) {
				const SScoutPoint& sp = scoutPoints[index];
				if (sp.score > 0) {
					circuit->GetDrawer()->AddPoint(circuit->GetMetalManager()->GetClusters()[index].position, utils::int_to_string(sp.score).c_str());
				}
			}
		}), FRAMES_PER_SEC);
	}
#endif
}

CDefenceData::SDefPoint* CMilitaryManager::FindClosestDefPoint(const AIFloat3& pos)
{
	int cluster = circuit->GetMetalManager()->FindNearestCluster(pos);
	return (cluster < 0) ? nullptr : FindClosestDefPoint(cluster, pos);
}

CDefenceData::SDefPoint* CMilitaryManager::FindClosestDefPoint(int cluster, const AIFloat3& pos,
		std::function<bool (const CDefenceData::SDefPoint& pnt)> predicate)
{
	if (predicate == nullptr) {
		predicate = [](const CDefenceData::SDefPoint&) { return true; };
	}
	CDefenceData::SDefPoint* closestPoint = nullptr;
	float minDist = std::numeric_limits<float>::max();
	const CDefenceData::DefPoints& points = defence->GetDefPoints();
	const CDefenceData::DefIndices& indices = defence->GetDefIndices(cluster);
	for (int idx : indices) {
		if (!predicate(points[idx])) {
			continue;
		}
		float dist = points[idx].position.SqDistance2D(pos);
		if ((closestPoint == nullptr) || (dist < minDist)) {
			closestPoint = const_cast<CDefenceData::SDefPoint*>(&points[idx]);
			minDist = dist;
		}
	}
	return closestPoint;
}

} // namespace circuit
