/*
 * FactoryManager.cpp
 *
 *  Created on: Dec 1, 2014
 *      Author: rlcevg
 */

#include "module/FactoryManager.h"
#include "module/EconomyManager.h"
#include "module/BuilderManager.h"
#include "module/MilitaryManager.h"
#include "resource/MetalManager.h"
#include "scheduler/Scheduler.h"
#include "script/FactoryScript.h"
#include "setup/SetupManager.h"
#include "terrain/TerrainManager.h"
#include "task/NilTask.h"
#include "task/IdleTask.h"
#include "task/static/WaitTask.h"
#include "task/static/RepairTask.h"
#include "task/static/ReclaimTask.h"
#include "task/static/EnemyReclaimPolicy.h"
#include "task/static/PatrolTask.h"
#include "unit/FactoryData.h"
#include "CircuitAI.h"
#include "util/GameAttribute.h"
#include "util/Utils.h"
#include "util/Profiler.h"
#include "json/json.h"

#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"

#include "AIFloat3.h"
#include "AISCommands.h"
#include "Game.h"
#include "Feature.h"
#include "Log.h"

namespace circuit {

using namespace springai;
using namespace terrain;

//#define FACTORY_CHOICE 1
#ifdef FACTORY_CHOICE
static int tierDbg;
static std::string unitTypeDbg;
#endif

CFactoryManager::CFactoryManager(CCircuitAI* circuit)
		: ITaskModule(circuit, new CFactoryScript(circuit->GetScriptManager(), this))
		, metalRequire(0.f)
		, energyRequire(0.f)
		, isAssistRequired(false)
		, isSwitchTime(false)
		, lastSwitchFrame(-1)
		, noT1FacCount(0)
		, bpRatio(1.f)
		, reWeight(.5f)
{
	circuit->GetScheduler()->RunOnInit(CScheduler::GameJob(&CFactoryManager::Init, this));


	for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
		// Auto-assign roles
		auto setRoles = [circuit, &cdef](CCircuitDef::RoleT type) {
			if (circuit->GetBindedRole(cdef.GetMainRole()) != type) {
				cdef.SetMainRole(type);
				cdef.AddEnemyRole(type);
				cdef.AddRole(type);
			}
		};
		if (cdef.IsAbleToFly()) {
			setRoles(ROLE_TYPE(AIR));
		} else if (!cdef.IsMobile() && cdef.IsAttacker() && cdef.HasSurfToLand()) {
			setRoles(ROLE_TYPE(STATIC));
		} else if (cdef.GetDef()->IsBuilder() && cdef.IsBuilder() && !cdef.IsRoleComm()) {
			setRoles(ROLE_TYPE(BUILDER));
		}
		if (cdef.IsRoleComm()) {
			// NOTE: Omit AddRole to exclude commanders from response
//			cdef.SetMainRole(ROLE_TYPE(BUILDER));  // breaks retreat
			cdef.AddEnemyRole(ROLE_TYPE(COMM));
			cdef.AddEnemyRole(ROLE_TYPE(BUILDER));
		}
	}

	factoryData = circuit->GetAllyTeam()->GetFactoryData().get();
}

CFactoryManager::~CFactoryManager()
{
}

void CFactoryManager::InitHandlers()
{
	/*
	 * factory handlers
	 */
	auto factoryCreatedHandler = [this](CCircuitUnit* unit, CCircuitUnit* builder) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			nilTask->AssignTo(unit);
			this->circuit->AddActionUnit(unit);
		}

		CTerrainManager* terrainMgr = this->circuit->GetTerrainManager();
		terrainMgr->AddZoneOwn(unit->GetPos(this->circuit->GetLastFrame()));

		// Mark path from factory to lanePos as blocked
		if (unit->GetCircuitDef()->GetMobileId() >= 0) {  // no air factory
			CSetupManager* setupMgr = this->circuit->GetSetupManager();
			CCircuitDef* largestDef = GetLargestDef(unit->GetCircuitDef());
			if (largestDef == nullptr) {
				largestDef = setupMgr->GetCommChoice();
			}
			terrainMgr->AddBusPath(unit, setupMgr->GetLanePos(), largestDef);
		}
	};
	auto factoryFinishedHandler = [this](CCircuitUnit* unit) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			this->circuit->AddActionUnit(unit);
		}
		nilTask->RemoveAssignee(unit);
		idleTask->AssignTo(unit);

		TRY_UNIT(this->circuit, unit,
			unit->GetUnit()->SetRepeat(false);
			unit->GetUnit()->SetIdleMode(0);
		)

		this->circuit->GetEconomyManager()->AddFactoryInfo(unit);
		UnitAdded(unit, UseAs::FACTORY);

		// UnitAdded runs AngelScript (Factory::AiUnitAdded), and script may give the unit
		// away before returning - ai.GiveUnits() -> economy->SendUnits() -> the engine
		// raises EVENT_UNIT_CAPTURED -> CCircuitAI::UnitCaptured -> IModule::UnitCaptured
		// -> UnitDestroyed -> factoryDestroyedHandler -> DisableFactory (a no-op here,
		// because EnableFactory has not run yet) -> UnregisterTeamUnit -> SetIsDead().
		// Control then returns here, and without this guard EnableFactory would insert a
		// unit that is already dead. CCircuitAI::ActionUpdate later sees IsDead() and
		// calls DeleteTeamUnit, freeing it, so `factories` is left holding a dangling
		// CCircuitUnit*. The next reader of that vector dereferences freed memory:
		// NeedUpgrade does `factoryDefs.find(fac.unit->GetCircuitDef()->GetId())` and
		// GetClosestFactory does `IsT1Factory(fac.unit->GetCircuitDef())`.
		//
		// Observed 2026-09-15, f=0052102: access violation in NeedUpgrade, reached via
		// CScheduler::ProcessJobs -> CEconomyManager::UpdateFactoryTasks ->
		// CheckAssistRequired. The unit pointer was still readable but its circuitDef
		// field was not, i.e. the CCircuitUnit had been freed. The match ran 16 AIs that
		// were donating units continuously (Team::TryDonate -> ai.GiveUnits).
		//
		// CCircuitAI::UnitFinished guards its own post-callback work the same way:
		//     if (!unit->IsDead())  // AiUnitAdded script can give away unit by now
		if (unit->IsDead()) {
			return;
		}

		lastSwitchFrame = this->circuit->GetLastFrame();
		EnableFactory(unit);
	};
	auto factoryIdleHandler = [](CCircuitUnit* unit) {
		unit->GetTask()->OnUnitIdle(unit);
	};
	auto factoryDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		completionRefills.erase(unit->GetId()); // includes transfers and ID reuse
		IUnitTask* task = unit->GetTask();
		task->OnUnitDestroyed(unit, attacker);  // can change task
		unit->GetTask()->RemoveAssignee(unit);  // Remove unit from IdleTask

		// NOTE: Do not del if factory rotation wanted
		DelFactory(unit->GetCircuitDef());
		DisableFactory(unit);
		this->circuit->GetEconomyManager()->DelFactoryInfo(unit);

		CTerrainManager* terrainMgr = this->circuit->GetTerrainManager();
		terrainMgr->DelZoneOwn(unit->GetPos(this->circuit->GetLastFrame()));
		// Remove blocked path from factory to lanePos
		terrainMgr->DelBusPath(unit);

		UnitRemoved(unit, UseAs::FACTORY);
	};

	/*
	 * armnanotc handlers
	 */
	auto assistCreatedHandler = [this](CCircuitUnit* unit, CCircuitUnit* builder) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			nilTask->AssignTo(unit);
			this->circuit->AddActionUnit(unit);
		}
	};
	auto assistFinishedHandler = [this](CCircuitUnit* unit) {
		if (unit->GetTask() == nullptr) {
			unit->SetManager(this);
			this->circuit->AddActionUnit(unit);
		}
		nilTask->RemoveAssignee(unit);
		idleTask->AssignTo(unit);

		int frame = this->circuit->GetLastFrame();
		const AIFloat3& assPos = unit->GetPos(frame);
		TRY_UNIT(this->circuit, unit,
			unit->CmdPriority(0);
			// FIXME: BA
			if (unit->GetCircuitDef()->IsRoleSupport()) {
				unit->CmdBARPriority(0);
			}
			// FIXME: BA
		)

		// check factory nano belongs to
		const float radius = unit->GetCircuitDef()->GetBuildDistance() * 0.9f;
		const float sqRadius = SQUARE(radius);
		SAssistToFactory& af = assists[unit];
		for (SFactory& fac : factories) {
			if (assPos.SqDistance2D(fac.unit->GetPos(frame)) >= sqRadius) {
				continue;
			}
			auto it = fac.nanos.find(unit->GetCircuitDef());
			if (it == fac.nanos.end()) {
				fac.nanos[unit->GetCircuitDef()].incomeMod = unit->GetCircuitDef()->GetWorkerTime() / fac.unit->GetCircuitDef()->GetWorkerTime();
			}
			SAssistant& assist = fac.nanos[unit->GetCircuitDef()];
			const float metalUse = fac.miRequire * assist.incomeMod;
			const float energyUse = fac.eiRequire * assist.incomeMod + unit->GetCircuitDef()->GetUpkeepE();
			af.metalRequire = std::max(af.metalRequire, metalUse);
			af.energyRequire = std::max(af.energyRequire, energyUse);
			fac.miRequireTotal += metalUse;
			fac.eiRequireTotal += energyUse;
			assist.units.insert(unit);
			++fac.nanoSize;
			af.factories.insert(fac.unit);
		}
		if (!af.factories.empty()) {
			metalRequire += af.metalRequire;
			energyRequire += af.energyRequire;

			bool isInHaven = false;
			for (const AIFloat3& hav : havens) {
				if (assPos.SqDistance2D(hav) < sqRadius) {
					isInHaven = true;
					break;
				}
			}
			if (!isInHaven) {
				havens.push_back(assPos);
			}
		}

		UnitAdded(unit, UseAs::ASSIST);
	};
	auto assistIdleHandler = [](CCircuitUnit* unit) {
		unit->GetTask()->OnUnitIdle(unit);
	};
	auto assistDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		IUnitTask* task = unit->GetTask();
		task->OnUnitDestroyed(unit, attacker);  // can change task
		unit->GetTask()->RemoveAssignee(unit);  // Remove unit from IdleTask

		if (task->GetType() == IUnitTask::Type::NIL) {
			return;
		}
		const AIFloat3& assPos = unit->GetPos(this->circuit->GetLastFrame());
		const float radius = unit->GetCircuitDef()->GetBuildDistance();
		const float sqRadius = SQUARE(radius);
		for (SFactory& fac : factories) {
			auto fit = fac.nanos.find(unit->GetCircuitDef());
			if (fit == fac.nanos.end()) {
				continue;
			}
			SAssistant& assist = fit->second;
			if (assist.units.erase(unit) == 0) {
				continue;
			}
			const float metalUse = fac.miRequire * assist.incomeMod;
			const float energyUse = fac.eiRequire * assist.incomeMod + unit->GetCircuitDef()->GetUpkeepE();
			fac.miRequireTotal -= metalUse;
			fac.eiRequireTotal -= energyUse;
			if (--fac.nanoSize > 0) {
				continue;
			}
			auto it = havens.begin();
			while (it != havens.end()) {
				if (it->SqDistance2D(assPos) < sqRadius) {
					*it = havens.back();
					havens.pop_back();
				} else {
					++it;
				}
			}
		}
		SAssistToFactory& af = assists[unit];
		if (!af.factories.empty()) {
			metalRequire -= af.metalRequire;
			energyRequire -= af.energyRequire;
		}
		assists.erase(unit);

		UnitRemoved(unit, UseAs::ASSIST);
	};

	ReadConfig();

	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
		if (cdef.IsMobile() || !cdef.GetDef()->IsBuilder()) {
			continue;
		}

		CCircuitDef::Id unitDefId = cdef.GetId();
		// FIXME: Caretaker can be factory. Make attributes?
		if (cdef.IsBuilder() && (factoryDefs.find(unitDefId) != factoryDefs.end())) {
			createdHandler[unitDefId] = factoryCreatedHandler;
			finishedHandler[unitDefId] = factoryFinishedHandler;
			idleHandler[unitDefId] = factoryIdleHandler;
			destroyedHandler[unitDefId] = factoryDestroyedHandler;
			economyMgr->AddFactoryDef(&cdef);
		} else if (cdef.IsAbleToAssist()
			&& (std::max(cdef.GetDef()->GetXSize(), cdef.GetDef()->GetZSize()) * SQUARE_SIZE < cdef.GetBuildDistance()))
		{
			createdHandler[unitDefId] = assistCreatedHandler;
			finishedHandler[unitDefId] = assistFinishedHandler;
			idleHandler[unitDefId] = assistIdleHandler;
			destroyedHandler[unitDefId] = assistDestroyedHandler;
			economyMgr->AddAssistDef(&cdef);
		}
	}
}

bool CFactoryManager::RegisterScriptFactory(CCircuitDef* def, const CCircuitDef* prototype)
{
    if (def == nullptr || prototype == nullptr || def->IsMobile() || !def->IsBuilder()
        || def->GetImmobileId() < 0) return false;
    if (factoryDefs.find(def->GetId()) != factoryDefs.end()) return true;
    auto source = factoryDefs.find(prototype->GetId());
    if (source == factoryDefs.end() || createdHandler.find(prototype->GetId()) == createdHandler.end()) return false;
    // Explicit opt-in only, before construction. Existing definitions are never
    // replaced. Script owns procurement; these uniform weights are a fallback.
    SFactoryDef result = source->second;
    result.startImp = result.switchImp = 0.f;
    result.buildDefs.clear(); result.landDef = result.waterDef = nullptr;
    std::vector<CCircuitDef::Id> options(def->GetBuildOptions().begin(), def->GetBuildOptions().end());
    std::sort(options.begin(), options.end());
    for (auto id : options) {
        CCircuitDef* product = circuit->GetCircuitDef(id);
        if (product == nullptr || !product->IsMobile()) continue;
        result.buildDefs.push_back(product);
        if (result.waterDef == nullptr || product->GetDef()->GetXSize() * product->GetDef()->GetZSize()
            > result.waterDef->GetDef()->GetXSize() * result.waterDef->GetDef()->GetZSize()) result.waterDef = product;
    }
    if (result.buildDefs.empty()) return false;
    result.landDef = result.waterDef;
    const std::vector<float> weights(result.buildDefs.size(), 1.f / result.buildDefs.size());
    for (auto* tiers : {&result.airTiers, &result.landTiers, &result.waterTiers}) {
        tiers->clear(); (*tiers)[0] = weights;
    }
    result.incomes.assign(1, std::numeric_limits<float>::max());
    factoryDefs[def->GetId()] = std::move(result);
    createdHandler[def->GetId()] = createdHandler.at(prototype->GetId());
    finishedHandler[def->GetId()] = finishedHandler.at(prototype->GetId());
    idleHandler[def->GetId()] = idleHandler.at(prototype->GetId());
    destroyedHandler[def->GetId()] = destroyedHandler.at(prototype->GetId());
    circuit->GetEconomyManager()->AddFactoryDef(def);
    return true;
}

void CFactoryManager::ReadConfig()
{
	const Json::Value& root = circuit->GetSetupManager()->GetConfig();
	enemyReclaimEnabled = root["economy"].get("turret_enemy_reclaim", true).asBool();
	const std::string& cfgName = circuit->GetSetupManager()->GetConfigName();

	CMaskHandler& sideMasker = circuit->GetGameAttribute()->GetSideMasker();
	sideInfos.resize(sideMasker.GetMasks().size());

	const Json::Value& econom = root["economy"];
	const Json::Value& nanotc = econom["assist"];
	for (const auto& kv : sideMasker.GetMasks()) {
		SSideInfo& sideInfo = sideInfos[kv.second.type];

		const std::string& nanoName = nanotc.get(kv.first, "").asString();
		CCircuitDef* assistDef = circuit->GetCircuitDef(nanoName.c_str());
		if (assistDef == nullptr) {
			assistDef = circuit->GetEconomyManager()->GetSideInfo().defaultDef;
			circuit->LOG("CONFIG %s: has unknown assistDef '%s'", cfgName.c_str(), nanoName.c_str());
		}
		sideInfo.assistDef = assistDef;
	}

	const Json::Value& product = econom["production"];
	newFacModM = product.get((unsigned)0, 0.8f).asFloat();
	newFacModE = product.get((unsigned)1, 0.8f).asFloat();
	facModM = product.get((unsigned)2, 0.8f).asFloat();
	facModE = product.get((unsigned)3, 0.8f).asFloat();

	numBatch = root["quota"].get("num_batch", 5).asInt();

	/*
	 * Roles, attributes and retreat
	 */
	std::map<CCircuitDef::RoleT, std::set<CCircuitDef::Id>> roleDefs;
	CCircuitDef::RoleName& roleNames = CCircuitDef::GetRoleNames();
	CCircuitDef::AttrName& attrNames = CCircuitDef::GetAttrNames();
	std::set<CCircuitDef::RoleT> modRoles;
	const Json::Value& behaviours = root["behaviour"];
	for (const std::string& defName : behaviours.getMemberNames()) {
		CCircuitDef* cdef = circuit->GetCircuitDef(defName.c_str());
		if (cdef == nullptr) {
			circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), defName.c_str());
			continue;
		}

		// Read roles from config
		const Json::Value& behaviour = behaviours[defName];
		const Json::Value& role = behaviour["role"];
		if (role.empty()) {
			circuit->LOG("CONFIG %s: '%s' has no role", cfgName.c_str(), defName.c_str());
			continue;
		}

		const std::string& mainName = role[0].asString();
		auto it = roleNames.find(mainName);
		if (it == roleNames.end()) {
			circuit->LOG("CONFIG %s: %s has unknown main role '%s'", cfgName.c_str(), defName.c_str(), mainName.c_str());
			continue;
		}
		cdef->SetMainRole(it->second.type);
		cdef->AddRole(it->second.type, circuit->GetBindedRole(it->second.type));
		roleDefs[it->second.type].insert(cdef->GetId());

//		if (role.size() < 2) {
			cdef->AddEnemyRoles(it->second.mask);
//		} else {
			for (unsigned i = 1; i < role.size(); ++i) {
				const std::string& enemyName = role[i].asString();
				it = roleNames.find(enemyName);
				if (it == roleNames.end()) {
					circuit->LOG("CONFIG %s: %s has unknown enemy role '%s'", cfgName.c_str(), defName.c_str(), enemyName.c_str());
					continue;
				}
				cdef->AddEnemyRoles(it->second.mask);
//				cdef->AddRole(it->second.type, circuit->GetBindedRole(it->second.type));
			}
//		}

		// Read optional roles and attributes
		const Json::Value& attributes = behaviour["attribute"];
		for (const Json::Value& attr : attributes) {
			const std::string& attrName = attr.asString();
			it = roleNames.find(attrName);
			if (it == roleNames.end()) {
				auto it = attrNames.find(attrName);
				if (it == attrNames.end()) {
					circuit->LOG("CONFIG %s: %s has unknown attribute '%s'", cfgName.c_str(), defName.c_str(), attrName.c_str());
					continue;
				} else {
					cdef->AddAttribute(it->second.type);
				}
			} else {
				cdef->AddRole(it->second.type, circuit->GetBindedRole(it->second.type));
				roleDefs[it->second.type].insert(cdef->GetId());
			}
		}
		if (cdef->IsAttrNoDGun()) {
			cdef->RemDGun();
		}
		if (cdef->IsAttrRanged()) {
			// Invalid containers/types must disable this opt-in controller, not
			// throw while parsing an otherwise usable profile.
			const Json::Value settings = behaviour["ranged"].isObject() ? behaviour["ranged"] : Json::Value(Json::objectValue);
			RangedPolicy policy;
			bool valid = behaviour["ranged"].isObject();
			const auto modeValue = settings.get("target_mode", "skirmish");
			if (!modeValue.isString()) valid = false;
			const std::string mode = modeValue.isString() ? modeValue.asString() : "";
			if (mode == "precision") policy.mode = RangedPolicy::Mode::PRECISION;
			else if (mode == "bombardment") policy.mode = RangedPolicy::Mode::BOMBARDMENT;
			else if (mode == "carrier") policy.mode = RangedPolicy::Mode::CARRIER;
			else if (mode != "skirmish") valid = false;
			// Validate at load, not in each shooter update. Reject malformed
			// policies explicitly instead of letting NaNs disable safety checks.
			auto number = [&](const char* key, float& value, float low, float high) {
				const auto& setting = settings[key];
				if (setting.isNull()) return;
				if (!setting.isNumeric()) { valid = false; return; }
				const float candidate = setting.asFloat();
				if (!std::isfinite(candidate) || candidate < low || candidate > high) { valid = false; return; }
				value = candidate;
			};
			auto boolean = [&](const char* key, bool& value) {
				const auto& setting = settings[key];
				if (setting.isNull()) return;
				if (!setting.isBool()) { valid = false; return; }
				value = setting.asBool();
			};
			number("range_fraction", policy.rangeFraction, .5f, .99f);
			number("spacing", policy.spacing, 16.f, 1024.f);
			number("safety_margin", policy.safetyMargin, 0.f, 512.f);
			number("range_hysteresis", policy.hysteresis, 8.f, 256.f);
			number("reaction_seconds", policy.reactionSeconds, .1f, 5.f);
			number("target_hysteresis", policy.targetHysteresis, 1.f, 3.f);
			number("move_min_seconds", policy.moveMinSeconds, 0.f, 3.f);
			number("target_min_seconds", policy.targetMinSeconds, 0.f, 3.f);
			number("target_switch_ratio", policy.targetSwitchRatio, 1.f, 5.f);
			number("sensor_offset", policy.sensorOffset, 32.f, 512.f);
			number("cloak_reserve_seconds", policy.cloakReserve, 0.f, 30.f);
			number("repaired_target_penalty", policy.repairedTargetPenalty, .01f, 1.f);
			number("splash_weight", policy.splashWeight, 0.f, 3.f);
			boolean("cloak_on_reload", policy.cloakOnReload);
			boolean("allow_mobile", policy.allowMobile);
			boolean("allow_static", policy.allowStatic);
			boolean("prefer_heavy", policy.preferHeavy);
			boolean("prefer_screen", policy.preferScreen);
			boolean("allow_radar", policy.allowRadar);
			boolean("advance_unknown_radar", policy.advanceUnknownRadar);
			boolean("hold_fireline", policy.holdFireline);
			boolean("stage_when_blocked", policy.stageWhenBlocked);
			boolean("coordinated", policy.coordinated);
            // Fireline holding is an individual forward-arc doctrine. Reject
            // unsupported cohort ownership instead of silently allowing retreats.
            if (policy.holdFireline && policy.coordinated) valid = false;
			number("cohort_size", policy.cohortSize, 1.f, 12.f);
			number("cohort_radius", policy.cohortRadius, 128.f, 1600.f);
			number("regroup_seconds", policy.regroupSeconds, 0.f, 20.f);
			number("rush_ratio", policy.rushRatio, 1.f, 5.f);
			number("catch_seconds", policy.catchSeconds, 0.f, 15.f);
			number("engagement_seconds", policy.engagementSeconds, 0.f, 30.f);
            boolean("sustained_rush", policy.sustainedRush);
            number("sustained_rush_ratio", policy.sustainedRushRatio, 1.f, 10.f);
            number("sustained_rush_radius", policy.sustainedRushRadius, 128.f, 1600.f);
            number("sustained_rush_min_front", policy.sustainedRushMinFront, 1.f, 256.f);
            number("sustained_rush_remaining", policy.sustainedRushRemaining, .01f, 1.f);
            number("sustained_rush_cooldown", policy.sustainedRushCooldown, 1.f, 120.f);
            number("sustained_rush_range", policy.sustainedRushRange, .25f, 1.f);
			number("advantage_enter", policy.advantageEnter, 1.f, 5.f);
			number("advantage_exit", policy.advantageExit, 1.f, 5.f);
			number("loss_fraction", policy.lossFraction, 0.f, .9f);
			number("static_loss_fraction", policy.staticLossFraction, 0.f, .9f);
            boolean("support_allies", policy.supportAllies);
            number("support_loss_fraction", policy.supportLossFraction, 0.f, .9f);
            number("intent_gain", policy.intentGain, 0.f, .5f);
            // D-294: resolve category names once at load. A malformed value or
            // a non-empty name the engine does not know disables the policy
            // with the standard diagnostic rather than silently targeting all.
            const auto& avoid = settings["avoid_categories"];
            if (!avoid.isNull()) {
                if (!avoid.isString()) valid = false;
                else if (!avoid.asString().empty()) {
                    policy.avoidCategory = circuit->GetGame()->GetCategoriesFlag(avoid.asString().c_str());
                    if (policy.avoidCategory == 0) valid = false;
                }
            }
            number("evasion_limit", policy.evasionLimit, 0.f, 10.f);
            // Owner 2026-10-19: the static press.
            number("press_static", policy.pressStatic, 0.f, 3.f);
            // The cohort controller has its own static admission (assault list).
            if (policy.pressStatic > 0.f && policy.coordinated) valid = false;
            // D-295: assist is an individual-controller lever; a coordinated
            // cohort already has support_allies. Reject the combination.
            number("assist_radius", policy.assistRadius, 0.f, 6000.f);
            number("assist_margin", policy.assistMargin, 0.f, 600.f);
            boolean("assist_screen", policy.assistScreen);
            if (policy.assistRadius > 0.f && policy.coordinated) valid = false;
            const auto& formation = settings["formation"];
            if (!formation.isNull()) {
                if (!formation.isObject() || !formation["family"].isString()
                    || !formation["position"].isString()) valid = false;
                else {
                    policy.formationFamily = formation["family"].asString();
                    const auto position = formation["position"].asString();
                    if (position == "front") policy.formationPosition = RangedPolicy::FormationPosition::FRONT;
                    else if (position == "rear") policy.formationPosition = RangedPolicy::FormationPosition::REAR;
                    else valid = false;
                    if (policy.formationFamily.empty() || !policy.coordinated) valid = false;
                    const auto readFormationNumber = [&](const char* name, float& value, float minimum, float maximum) {
                        const auto& setting = formation[name];
                        if (setting.isNull()) return;
                        if (!setting.isNumeric()) { valid = false; return; }
                        const float candidate = setting.asFloat();
                        if (!std::isfinite(candidate) || candidate < minimum || candidate > maximum) valid = false;
                        else value = candidate;
                    };
                    readFormationNumber("separation_minimum", policy.formationSeparationMinimum, 16.f, 512.f);
                    readFormationNumber("separation_maximum", policy.formationSeparationMaximum, 16.f, 1024.f);
                    readFormationNumber("withdrawal_lead_seconds", policy.withdrawalLeadSeconds, 0.f, 5.f);
                    if (policy.formationSeparationMinimum > policy.formationSeparationMaximum) valid = false;
                }
            }
            if (policy.sustainedRush && (!policy.coordinated || policy.engagementSeconds <= 0.f
                || policy.formationPosition == RangedPolicy::FormationPosition::NONE)) valid = false;
			if (policy.advantageExit > policy.advantageEnter) valid = false;
			if (valid) cdef->SetRangedPolicy(policy);
			else {
				circuit->LOG("CONFIG %s: %s has invalid ranged policy; ranged disabled", cfgName.c_str(), defName.c_str());
				cdef->DelAttribute(ATTR_TYPE(RANGED));
			}
		}

		const Json::Value& fire = behaviour["fire_state"];
		if (!fire.isNull()) {
			cdef->SetFireState(fire.asInt());
		}

		const Json::Value& move = behaviour["move_state"];
		if (!move.isNull()) {
			cdef->SetMoveState(move.asInt());
		}

		const Json::Value& slowOnOff = behaviour["slow_target"];
		if (!slowOnOff.isNull()) {
			cdef->AddAttribute(ATTR_TYPE(ONOFF));
			cdef->SetOnSlow(slowOnOff.asBool());
		}
		cdef->SetOn(behaviour.get("on", true).asBool());
		cdef->SetBuildAllowed(behaviour.get("build", true).asBool());
		cdef->SetStandoff(std::clamp(behaviour.get("standoff", 0.f).asFloat(), 0.f, 0.95f));
        const auto& targetCost = behaviour["target_min_cost"];
        // Validate once at profile load. The zero default preserves every
        // unconfigured unit, including other aircraft and all land units.
        if (!targetCost.isNull()) {
            if (targetCost.isNumeric() && std::isfinite(targetCost.asFloat()) && targetCost.asFloat() >= 0.f)
                cdef->SetTargetMinCost(targetCost.asFloat());
            else circuit->LOG("CONFIG %s: %s invalid target_min_cost", cfgName.c_str(), defName.c_str());
        }

		const Json::Value& reload = behaviour["reload"];
		if (!reload.isNull()) {
			cdef->SetReloadTime(reload.asFloat() * FRAMES_PER_SEC);
		}

		const Json::Value& limit = behaviour["limit"];
		if (!limit.isNull()) {
			cdef->SetMaxThisUnit(std::min(limit.asInt(), cdef->GetMaxThisUnit()));
		}

		const Json::Value& since = behaviour["since"];
		if (!since.isNull()) {
			cdef->SetSinceFrame(since.asInt() * FRAMES_PER_SEC);
		}

		const Json::Value& coold = behaviour["cooldown"];
		if (!coold.isNull()) {
			cdef->SetCooldown(coold.asInt() * FRAMES_PER_SEC);
		}

		cdef->SetGoalBuildMod(behaviour.get("build_mod", cdef->GetGoalBuildMod()).asFloat());

		const Json::Value& retreat = behaviour.get("retreat", cdef->GetRetreat());
		if (retreat.isNumeric()) {
			cdef->SetRetreat(retreat.asFloat());
		} else {
			const float min = retreat.get((unsigned)0, cdef->GetRetreat()).asFloat();
			const float max = retreat.get((unsigned)1, cdef->GetRetreat()).asFloat();
			cdef->SetRetreat((float)rand() / RAND_MAX * (max - min) + min);
		}

		const Json::Value& selfDHP = behaviour["selfd_hp"];
		if (!selfDHP.isNull()) {
			cdef->SetSelfDHP(selfDHP.asFloat());
		}

		const Json::Value& pwrMod = behaviour["power"];
		if (!pwrMod.isNull()) {
			cdef->ModPower(pwrMod.asFloat());
		}
		const Json::Value& thrMod = behaviour["threat"];
		if (!thrMod.isNull()) {
			if (thrMod.isNumeric()) {
				const float mod = thrMod.asFloat();
				cdef->ModDefThreat(mod);
				cdef->ModAirThreat(mod);
				cdef->ModSurfThreat(mod);
				cdef->ModWaterThreat(mod);
			} else if (thrMod.isObject()) {
				cdef->ModAirThreat(thrMod.get("air", 1.f).asFloat());
				cdef->ModSurfThreat(thrMod.get("surf", 1.f).asFloat());
				cdef->ModWaterThreat(thrMod.get("water", 1.f).asFloat());
				const float defMod = thrMod.get("default", 1.f).asFloat();
				cdef->ModDefThreat(defMod);
				const Json::Value& thrRole = thrMod["vs"];
				if (!thrRole.isNull()) {
					for (auto& kv : roleNames) {
						const float rolMod = thrRole.get(kv.first, defMod).asFloat();
						if (rolMod != defMod) {
							modRoles.insert(kv.second.type);
						}
						cdef->ModThreatMod(kv.second.type, rolMod);
					}
				}
			}
		}

		const Json::Value& range = behaviour["range"];
		if (!range.isNull()) {
			if (range.isNumeric()) {
				cdef->SetRange(range.asFloat());
			} else if (range.isArray()) {
				cdef->SetRange(CCircuitDef::RangeType::AIR, range.get((unsigned)0, cdef->GetMaxRange(CCircuitDef::RangeType::AIR)).asFloat());
				cdef->SetRange(CCircuitDef::RangeType::LAND, range.get((unsigned)1, cdef->GetMaxRange(CCircuitDef::RangeType::LAND)).asFloat());
				cdef->SetRange(CCircuitDef::RangeType::WATER, range.get((unsigned)2, cdef->GetMaxRange(CCircuitDef::RangeType::WATER)).asFloat());
			} else if (range.isObject()) {
				cdef->SetRange(CCircuitDef::RangeType::AIR, range.get("air", cdef->GetMaxRange(CCircuitDef::RangeType::AIR)).asFloat());
				cdef->SetRange(CCircuitDef::RangeType::LAND, range.get("surf", cdef->GetMaxRange(CCircuitDef::RangeType::LAND)).asFloat());
				cdef->SetRange(CCircuitDef::RangeType::WATER, range.get("water", cdef->GetMaxRange(CCircuitDef::RangeType::WATER)).asFloat());
			}
		}

		cdef->SetIgnore(behaviour.get("ignore", cdef->IsIgnore()).asBool());

		const Json::Value& mpOffset = behaviour["midposoffset"];
		if (!mpOffset.isNull()) {
			float x = mpOffset.get((unsigned)0, 0.f).asFloat();
			float y = mpOffset.get((unsigned)1, 0.f).asFloat();
			float z = mpOffset.get((unsigned)2, 0.f).asFloat();
			cdef->SetMidPosOffset(x, y, z);
		}

		const Json::Value& buildSpeed = behaviour["build_speed"];
		if (!buildSpeed.isNull()) {
			cdef->SetBuildSpeed(buildSpeed.asFloat());
		}
	}
	circuit->GetAllyTeam()->NonDefaultThreats(std::move(modRoles), circuit);

	/*
	 * Factories
	 */
	const bool warnProb = root.get("warn_probability", true).asBool();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const Json::Value& factories = root["factory"];
	float minSpeed = std::numeric_limits<float>::max();
	float maxSpeed = 0.f;
	for (const std::string& fac : factories.getMemberNames()) {
		CCircuitDef* cdef = circuit->GetCircuitDef(fac.c_str());
		if (cdef == nullptr) {
			circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), fac.c_str());
			continue;
		}
		SImmobileType::Id itId = cdef->GetImmobileId();
		if (itId < 0) {  // didn't identify proper type?
			circuit->LOG("CONFIG %s: '%s' has unknown immobile type", cfgName.c_str(), fac.c_str());
			continue;
		}

		const Json::Value& factory = factories[fac];
		SFactoryDef facDef;

		// TODO: Replace importance with proper terrain analysis (size, hardness, unit's power, speed)
		const Json::Value& importance = factory["importance"];
		if (importance.isNull()) {
			facDef.startImp = 1.0f;
			facDef.switchImp = 1.0f;
		} else {
			facDef.startImp = importance.get((unsigned)0, 1.0f).asFloat();
			facDef.switchImp = importance.get((unsigned)1, 1.0f).asFloat();
			// FIXME: DEBUG Silly t1 detection
			facDef.isT1 = (facDef.switchImp <= .0f);
			// FIXME: DEBUG
		}

		facDef.isRequireEnergy = factory.get("require_energy", false).asBool();

		const Json::Value& items = factory["unit"];
		const Json::Value& tiers = factory["income_tier"];
		facDef.buildDefs.reserve(items.size());
		const unsigned tierSize = tiers.size();
		facDef.incomes.reserve(tierSize + 1);

		CCircuitDef* landDef = nullptr;
		CCircuitDef* waterDef = nullptr;
		float landSize = std::numeric_limits<float>::max();
		float waterSize = std::numeric_limits<float>::max();
		std::vector<unsigned> trueIndex;
		unsigned itemsAmount = 0;
		float avgSpeed = 0.f;

		for (unsigned i = 0; i < items.size(); ++i) {
			CCircuitDef* udef = circuit->GetCircuitDef(items[i].asCString());
			if (udef == nullptr) {
				circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), items[i].asCString());
				continue;
			}
			if (!cdef->CanBuild(udef)) {  // buildlist from modoptions
				circuit->LOG("CONFIG %s: factory '%s' can't build '%s'", cfgName.c_str(), fac.c_str(), items[i].asCString());
				continue;
			}
			trueIndex.push_back(i);
			facDef.buildDefs.push_back(udef);

			// identify surface representatives
			if (udef->GetMobileId() < 0) {
				if (landDef == nullptr) {
					landDef = udef;
				}
				if (waterDef == nullptr) {
					waterDef = udef;
				}
				continue;
			}
			SArea* area = terrainMgr->GetMobileTypeById(udef->GetMobileId())->areaLargest;
			if (area == nullptr) {
				continue;
			}
			if ((area->mobileType->maxElevation > 0.f) && (landSize > area->percentOfMap)) {
				landSize = area->percentOfMap;
				landDef = udef;
			}
			if (((area->mobileType->minElevation < 0.f) || udef->IsFloater()) && (waterSize > area->percentOfMap)) {
				waterSize = area->percentOfMap;
				waterDef = udef;
			}

			avgSpeed += udef->GetSpeed();
			++itemsAmount;
		}
		if (facDef.buildDefs.empty()) {
			continue;  // ignore empty factory
		}
		facDef.landDef = landDef;
		facDef.waterDef = waterDef;

		if (itemsAmount > 0) {
			avgSpeed /= itemsAmount;
		}
		minSpeed = std::min(minSpeed, avgSpeed);
		maxSpeed = std::max(maxSpeed, avgSpeed);
		facDef.mapSpeedPerc = avgSpeed;

		auto fillProbs = [this, &cfgName, &facDef, &fac, &factory, &trueIndex, warnProb](unsigned i, const char* type, SFactoryDef::Tiers& tiers) {
			const Json::Value& tierType = factory[type];
			if (tierType.isNull()) {
				return false;
			}
			const Json::Value& tier = tierType[utils::int_to_string(i, "tier%i")];
			if (tier.isNull()) {
				return false;
			}
			std::vector<float>& probs = tiers[i];
			probs.reserve(facDef.buildDefs.size());
			float sum = .0f;
			for (unsigned j : trueIndex) {
				const float p = tier[j].asFloat();
				sum += p;
				probs.push_back(p);
			}
			if (warnProb && (std::fabs(sum - 1.0f) > 0.0001f)) {
				circuit->LOG("CONFIG %s: %s's %s_tier%i total probability = %f", cfgName.c_str(), fac.c_str(), type, i, sum);
			}
			return true;
		};
		unsigned i = 0;
		for (; i < tierSize; ++i) {
			facDef.incomes.push_back(tiers[i].asFloat());
			fillProbs(i, "air", facDef.airTiers);
			fillProbs(i, "land", facDef.landTiers);
			fillProbs(i, "water", facDef.waterTiers);
		}
		fillProbs(i, "air", facDef.airTiers);
		fillProbs(i, "land", facDef.landTiers);
		fillProbs(i, "water", facDef.waterTiers);

//		if (facDef.incomes.empty()) {
			facDef.incomes.push_back(std::numeric_limits<float>::max());
//		}
		if (facDef.landTiers.empty()) {
			if (!facDef.airTiers.empty()) {
				facDef.landTiers = facDef.airTiers;
			} else if (!facDef.waterTiers.empty()) {
				facDef.landTiers = facDef.waterTiers;
			} else {
				facDef.landTiers[0];  // create empty tier
			}
		}
		if (facDef.waterTiers.empty()) {
			facDef.waterTiers = facDef.landTiers;
		}
		if (facDef.airTiers.empty()) {
			facDef.airTiers = terrainMgr->IsWaterMap() ? facDef.waterTiers : facDef.landTiers;
		}

		facDef.nanoCount = factory.get("caretaker", 1).asUInt();

		factoryDefs[cdef->GetId()] = facDef;
	}

	const Json::Value& select = root["select"];
	const Json::Value& offset = select["offset"];
	const Json::Value& speed = select["speed"];
	const Json::Value& map = select["map"];
	airMapPerc = select.get("air_map", 80.0f).asFloat();
	minOffset = offset.get((unsigned)0, -20.0f).asFloat();
	const float maxOffset = offset.get((unsigned)1, 20.0f).asFloat();
	lenOffset = maxOffset - minOffset;
	const float minSpPerc = speed.get((unsigned)0, 0.0f).asFloat();
	const float maxSpPerc = speed.get((unsigned)1, 40.0f).asFloat();
	const float minMap = map.get((unsigned)0, 8.0f).asFloat();
	const float maxMap = map.get((unsigned)1, 24.0f).asFloat();
	const float minMapSp = SQUARE(minMap) * minSpeed;
	const float mapSize = (circuit->GetMap()->GetWidth() / 64) * (circuit->GetMap()->GetHeight() / 64);
	const float speedFactor = (maxSpPerc - minSpPerc) / (SQUARE(maxMap) * maxSpeed - minMapSp);
	for (auto& kv : factoryDefs) {
		float avgSpeed = kv.second.mapSpeedPerc;
		kv.second.mapSpeedPerc = speedFactor * (mapSize * avgSpeed - minMapSp) + minSpPerc;
	}

	noAirNum = select.get("no_air", 2).asUInt();

	bpRatio = root["economy"].get("buildpower", 1.f).asFloat();
	reWeight = root["response"].get("_weight_", .5f).asFloat();
}

void CFactoryManager::Init()
{
	CSetupManager::StartFunc subinit = [this](const AIFloat3& pos) {
		CScheduler* scheduler = circuit->GetScheduler().get();
		const int interval = 4;
		const int offset = circuit->GetSkirmishAIId() % interval;
		scheduler->RunJobEvery(CScheduler::GameJob(&CFactoryManager::UpdateIdle, this), interval, offset + 0);
		scheduler->RunJobEvery(CScheduler::GameJob(&CFactoryManager::Update, this), interval, offset + 2);
		scheduler->RunJobEvery(CScheduler::GameJob(&CFactoryManager::UpdateEnemyReclaim, this),
				FRAMES_PER_SEC / 2, circuit->GetSkirmishAIId() % (FRAMES_PER_SEC / 2));

		scheduler->RunJobEvery(CScheduler::GameJob(&CFactoryManager::Watchdog, this),
								FRAMES_PER_SEC * 60,
								circuit->GetSkirmishAIId() * WATCHDOG_COUNT + 11);
	};

	circuit->GetSetupManager()->ExecOnFindStart(subinit);
}

int CFactoryManager::UnitCreated(CCircuitUnit* unit, CCircuitUnit* builder)
{
	CCircuitDef* cdef = unit->GetCircuitDef();
	// FIXME: Why is it here and not in top level, before module call?
	TRY_UNIT(circuit, unit,
		unit->CmdSetFireState(cdef->GetFireState());
		unit->CmdSetMoveState(cdef->GetMoveState());
	)

	auto search = createdHandler.find(cdef->GetId());
	if (search != createdHandler.end()) {
		search->second(unit, builder);
	}

	if (unit->GetTask() == nullptr) {  // all units without handlers
		unit->SetManager(this);
		nilTask->AssignTo(unit);
		circuit->AddActionUnit(unit);
	}

	if (builder == nullptr) {
		return 0; //signaling: OK
	}

	IUnitTask* task = builder->GetTask();
	if ((task == nullptr) || (task->GetType() != IUnitTask::Type::FACTORY)) {
		return 0; //signaling: OK
	}

	if (unit->GetUnit()->IsBeingBuilt()) {
		CRecruitTask* taskR = static_cast<CRecruitTask*>(task);
		if (taskR->GetTarget() == nullptr) {
			taskR->SetTarget(unit);
			unfinishedUnits[unit] = taskR;
		}
	}

	return 0; //signaling: OK
}

int CFactoryManager::UnitFinished(CCircuitUnit* unit)
{
	auto iter = unfinishedUnits.find(unit);
	if (iter != unfinishedUnits.end()) {
		CRecruitTask* task = static_cast<CRecruitTask*>(iter->second);
		if (task->IsRepeat()) {
			// One persistent owner, one engine repeat queue. Finishing an offspring
			// must not call Cancel(), which clears that queue (D-119/D-216).
			// Erase before changing the borrowed target: the next UnitCreated
			// installs its own mapping. Ordinary recruits keep their old lifecycle.
			unfinishedUnits.erase(iter);
			task->SetTarget(nullptr);
		} else {
			// Completion is the earliest safe point to select the next product:
			// after DoneTask, pending counts and script removal hooks are current.
			// Opted-in factories bypass IdleTask's 20-frame quarantine and sliced
			// backlog, without polling armies or queuing stale future priorities.
			// O(assignees), normally one. IDs, not borrowed pointers, cross hooks
			// which can donate, retire or otherwise reassign a factory. See the
			// supplied air factory-throughput regression and D-276.
			std::vector<CCircuitUnit::Id> refill;
			auto* factoryScript = static_cast<CFactoryScript*>(script);
			for (CCircuitUnit* factory : task->GetAssignees()) {
				if (factoryScript->CanRefillImmediately(factory)) refill.push_back(factory->GetId());
			}
			if (!refill.empty()) task->SetCompletionRefill(true);
			DoneTask(task);
			for (const auto id : refill) {
				CCircuitUnit* factory = circuit->GetTeamUnit(id);
				if (factory == nullptr || factory->IsDead() || factory->GetManager() != this
					|| factory->GetTask() != idleTask || !factory->IsProductionEnabled()
					|| !factoryScript->CanRefillImmediately(factory)) continue;
				const auto ticket = ++nextRefillTicket;
				completionRefills[id] = ticket;
				circuit->GetScheduler()->RunJobAfter(CScheduler::GameJob(
					&CFactoryManager::RefillCompletedFactory, this, id, ticket), 1);
			}
		}
	}
	auto itre = repairUnits.find(unit->GetId());
	if (itre != repairUnits.end()) {
		DoneTask(itre->second);
	}

	auto search = finishedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != finishedHandler.end()) {
		search->second(unit);
	}

	return 0; //signaling: OK
}

void CFactoryManager::RefillCompletedFactory(CCircuitUnit::Id id, unsigned long long ticket)
{
	const auto pending = completionRefills.find(id);
	if (pending == completionRefills.end() || pending->second != ticket) return;
	completionRefills.erase(pending);
	CCircuitUnit* factory = circuit->GetTeamUnit(id);
	if (factory == nullptr || factory->IsDead() || factory->GetManager() != this
		|| factory->GetTask() != idleTask || !factory->IsProductionEnabled()
		|| !static_cast<CFactoryScript*>(script)->CanRefillImmediately(factory)) return;
	// One simulation-thread turn lets the engine finish/pop the old build and
	// deliver its idle notification before the new owner emits a command.
	// This is event-driven (one ticket per completion), not a periodic poll or
	// reaction throttle. Destroy/transfer removes the ticket; current ownership
	// and role are revalidated. No borrowed unit/task crosses the scheduler.
	AssignTask(factory);
	factory = circuit->GetTeamUnit(id);
	if (factory != nullptr && !factory->IsDead() && factory->GetManager() == this
		&& factory->GetTask() != idleTask && factory->GetTask()->GetType() != IUnitTask::Type::PLAYER) {
		if (auto* next = dynamic_cast<CRecruitTask*>(factory->GetTask())) next->SetCompletionRefill(true);
		factory->GetTask()->Start(factory);
	}
}

int CFactoryManager::UnitIdle(CCircuitUnit* unit)
{
	auto search = idleHandler.find(unit->GetCircuitDef()->GetId());
	if (search != idleHandler.end()) {
		search->second(unit);
	}

	return 0; //signaling: OK
}

int CFactoryManager::UnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	auto iter = unfinishedUnits.find(unit);
	if (iter != unfinishedUnits.end()) {
		AbortTask(iter->second);
	}
	auto itre = repairUnits.find(unit->GetId());
	if (itre != repairUnits.end()) {
		AbortTask(itre->second);
	}

	auto search = destroyedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != destroyedHandler.end()) {
		search->second(unit, attacker);
	}

	return 0; //signaling: OK
}

int CFactoryManager::GetPendingRecruitCount(const CCircuitDef* def) const
{
    const int indexed = def == nullptr ? 0 : pendingRecruits.Count(def->GetId());
    static const bool verify = std::getenv("CIRCUIT_VERIFY_ECONOMY_INDEX") != nullptr;
    if (verify) {
        int count = 0;
        for (const CRecruitTask* task : factoryTasks)
            if (!task->IsDead() && task->GetBuildDef() == def && task->GetTarget() == nullptr) ++count;
        if (count != indexed) circuit->LOG("[INVARIANT] INV-175 recruit index=%i scan=%i", indexed, count);
    }
    return indexed;
}

void CFactoryManager::RefreshPendingRecruit(CRecruitTask* task)
{
    // SetTarget covers frame creation and repeat-production completion; Dead
    // covers cancellation before script removal hooks. No snapshot staleness.
    const auto* def = task->GetBuildDef();
    if (!task->IsDead() && task->GetTarget() == nullptr && def != nullptr)
        pendingRecruits.Set(task, def->GetId());
    else pendingRecruits.Erase(task);
}

CRecruitTask* CFactoryManager::Enqueue(const TaskS::SRecruitTask& ti)
{
	CRecruitTask* task = new CRecruitTask(this, ti.priority, ti.buildDef, ti.position, ti.type, ti.radius);
	task->SetRepeat(ti.repeat);
	factoryTasks.push_back(task);
    RefreshPendingRecruit(task); // visible to the synchronous TaskAdded script
	updateTasks.push_back(task);
	TaskAdded(task);
	return task;
}

IUnitTask* CFactoryManager::Enqueue(const TaskS::SServSTask& ti)
{
	IUnitTask* task;

	switch (ti.type) {
		case IBuilderTask::BuildType::REPAIR: {
			auto it = repairUnits.find(ti.target->GetId());
			if (it != repairUnits.end()) {
				return it->second;
			}
			task = new CSRepairTask(this, ti.priority, ti.target);
		} break;
		case IBuilderTask::BuildType::RECLAIM: {
			task = new CSReclaimTask(this, ti.priority, ti.position, {0.f, 0.f}, ti.timeout, ti.radius);
		} break;
		case IBuilderTask::BuildType::PATROL: {
			task = new CSPatrolTask(this, ti.priority, ti.position, ti.timeout);
		} break;
		default:
		case IBuilderTask::BuildType::WAIT: {
			task = new CSWaitTask(this, ti.stop, ti.timeout);
		} break;
	}

	updateTasks.push_back(task);
	TaskAdded(task);
	return task;
}

void CFactoryManager::DequeueTask(IUnitTask* task, bool done)
{
	switch (task->GetType()) {
		case IUnitTask::Type::FACTORY:{
			switch (static_cast<IBuilderTask*>(task)->GetBuildType()) {
				case IBuilderTask::BuildType::RECRUIT: {
                    pendingRecruits.Erase(static_cast<CRecruitTask*>(task));
					auto it = std::find(factoryTasks.begin(), factoryTasks.end(), task);
					if (it != factoryTasks.end()) {
						factoryTasks.erase(it);
					}
					unfinishedUnits.erase(static_cast<CRecruitTask*>(task)->GetTarget());
				} break;
				case IBuilderTask::BuildType::REPAIR: {
					repairUnits.erase(static_cast<CSRepairTask*>(task)->GetTargetId());
				} break;
				default: break;  // RECLAIM
			}
		} break;
		default: break;
	}  // WAIT
	ITaskModule::DequeueTask(task, done);
}

void CFactoryManager::ApplySwitchFrame()
{
	lastSwitchFrame = circuit->GetLastFrame();
	isSwitchTime = false;
}

bool CFactoryManager::IsSwitchTime()
{
	if (!isSwitchTime) {
		isSwitchTime = static_cast<CFactoryScript*>(script)->IsSwitchTime(lastSwitchFrame);
	}
	return isSwitchTime;
}

bool CFactoryManager::IsSwitchAllowed(CCircuitDef* facDef) const
{
	return static_cast<CFactoryScript*>(script)->IsSwitchAllowed(facDef);
}

CCircuitUnit* CFactoryManager::NeedUpgrade(unsigned int nanoQueued)
{
	const int frame = circuit->GetLastFrame();
	unsigned facSize = factories.size();
	for (auto itF = factories.rbegin(); itF != factories.rend(); ++itF) {
		SFactory& fac = *itF;

		auto itD = factoryDefs.find(fac.unit->GetCircuitDef()->GetId());
		if (itD != factoryDefs.end()) {
			const SFactoryDef& facDef = itD->second;

			for (CCircuitDef* cdef : facDef.buildDefs) {
				if (cdef->IsAvailable(frame)) {
					if (fac.nanoSize + nanoQueued < facSize * fac.weight) {
						return fac.unit;
					} else {
						break;
					}
				}
			}
		}
	}
	return nullptr;
}

CCircuitUnit* CFactoryManager::GetClosestFactory(const AIFloat3& position)
{
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
//	CTerrainManager::CorrectPosition(position);
	const int iS = terrainMgr->GetSectorIndex(position);
	CCircuitUnit* factory = nullptr;
	float minSqDist = std::numeric_limits<float>::max();
	const int frame = circuit->GetLastFrame();
	for (SFactory& fac : factories) {
		if (IsT1Factory(fac.unit->GetCircuitDef())) {
			continue;
		}
		SArea* area = fac.unit->GetArea();
		if ((area != nullptr) && (area->sector.find(iS) == area->sector.end())) {
			continue;
		}
		const AIFloat3& facPos = fac.unit->GetPos(frame);
		float sqDist = position.SqDistance2D(facPos);
		if (minSqDist > sqDist) {
			minSqDist = sqDist;
			factory = fac.unit;
		}
	}
	// FIXME: DEBUG lazy t1 factory check
	if (factory == nullptr) {
		for (SFactory& fac : factories) {
			if (!IsT1Factory(fac.unit->GetCircuitDef())) {
				continue;
			}
			SArea* area = fac.unit->GetArea();
			if ((area != nullptr) && (area->sector.find(iS) == area->sector.end())) {
				continue;
			}
			const AIFloat3& facPos = fac.unit->GetPos(frame);
			float sqDist = position.SqDistance2D(facPos);
			if (minSqDist > sqDist) {
				minSqDist = sqDist;
				factory = fac.unit;
			}
		}
	}
	// FIXME: DEBUG
	return factory;
}

//CCircuitDef* CFactoryManager::GetClosestDef(AIFloat3& position, CCircuitDef::RoleT role)
//{
//	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
//	CTerrainManager::CorrectPosition(position);
//	int iS = terrainMgr->GetSectorIndex(position);
//	CCircuitDef* roleDef = nullptr;
//	float minSqDist = std::numeric_limits<float>::max();
//	const int frame = circuit->GetLastFrame();
//	for (SFactory& fac : factories) {
//		STerrainMapArea* area = fac.unit->GetArea();
//		if ((area != nullptr) && (area->sector.find(iS) == area->sector.end())) {
//			continue;
//		}
//		const AIFloat3& facPos = fac.unit->GetPos(frame);
//		float sqDist = position.SqDistance2D(facPos);
//		if (minSqDist < sqDist) {
//			continue;
//		}
//		const SFactoryDef& facDef = factoryDefs.find(fac.unit->GetCircuitDef()->GetId())->second;
//		CCircuitDef* cdef = GetFacRoleDef(role, facDef);
//		if (cdef != nullptr) {
//			roleDef = cdef;
//			minSqDist = sqDist;
//			position = facPos;
//		}
//	}
//	return roleDef;
//}

AIFloat3 CFactoryManager::GetClosestHaven(CCircuitUnit* unit) const
{
	if (havens.empty()) {
		return -RgtVector;
	}
	float metric = std::numeric_limits<float>::max();
	const AIFloat3& position = unit->GetPos(circuit->GetLastFrame());
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	auto it = havens.begin(), havIt = havens.end();
	for (; it != havens.end(); ++it) {
		if (!terrainMgr->CanMoveToPos(unit->GetArea(), *it)) {
			continue;
		}
		float qdist = it->SqDistance2D(position);
		if (qdist < metric) {
			havIt = it;
			metric = qdist;
		}
	}
	return (havIt != havens.end()) ? *havIt : AIFloat3(-RgtVector);
}

AIFloat3 CFactoryManager::GetClosestHaven(const AIFloat3& position) const
{
	if (havens.empty()) {
		return -RgtVector;
	}
	float metric = std::numeric_limits<float>::max();
	auto it = havens.begin(), havIt = havens.end();
	for (; it != havens.end(); ++it) {
		float qdist = it->SqDistance2D(position);
		if (qdist < metric) {
			havIt = it;
			metric = qdist;
		}
	}
	return (havIt != havens.end()) ? *havIt : AIFloat3(-RgtVector);
}

const CFactoryManager::SSideInfo& CFactoryManager::GetSideInfo() const
{
	return sideInfos[circuit->GetSideId()];
}

CRecruitTask* CFactoryManager::UpdateBuildPower(CCircuitUnit* unit, bool isActive)
{
	if (!CanEnqueueTask()) {
		return nullptr;
	}

	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	const float metalIncome = std::min(economyMgr->GetAvgMetalIncome(), economyMgr->GetAvgEnergyIncome());
	const int r = rand();
	if ((circuit->GetBuilderManager()->GetBuildPower() >= metalIncome * bpRatio)
		|| (isActive && (r >= RAND_MAX / 2)))
	{
		return nullptr;
	}

	auto it = factoryDefs.find(unit->GetCircuitDef()->GetId());
	if (it == factoryDefs.end()) {
		return nullptr;
	}
	CCircuitDef* buildDef = GetFacRoleDef(ROLE_TYPE(BUILDER), it->second);

	if ((buildDef != nullptr) && buildDef->IsAvailable(circuit->GetLastFrame())) {
		const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
		CTerrainManager* terrainMgr = circuit->GetTerrainManager();
		if (!terrainMgr->CanBeBuiltAt(buildDef, pos, unit->GetCircuitDef()->GetBuildDistance())) {
			return nullptr;
		}
#ifdef FACTORY_CHOICE
		circuit->LOG("choice = %s | %f < %f or (%i and %i < %i)", buildDef->GetDef()->GetName(),
				circuit->GetBuilderManager()->GetBuildPower(), metalIncome * bpRatio, isActive, r, RAND_MAX / 2);
#endif
		return Enqueue(TaskS::Recruit(CRecruitTask::RecruitType::BUILDPOWER, CRecruitTask::Priority::NORMAL, buildDef, pos, 64.f));
	}
	return nullptr;
}

CRecruitTask* CFactoryManager::UpdateFirePower(CCircuitUnit* builder, bool isActive)
{
	if (!CanEnqueueTask()) {
		return nullptr;
	}

	CFactoryManager* factoryMgr = circuit->IsSlave() ? circuit->GetAllyTeam()->GetLeader()->GetFactoryManager() : this;
	SRecruitDef result = factoryMgr->RequiredFireDef(builder, isActive);
	if (result.id < 0) {
		return nullptr;
	}

	CCircuitDef* buildDef = circuit->GetCircuitDef(result.id);
	const AIFloat3& pos = builder->GetPos(circuit->GetLastFrame());
	float radius = std::max(builder->GetCircuitDef()->GetMoveXSize(), builder->GetCircuitDef()->GetMoveZSize()) * SQUARE_SIZE / 2;
	// FIXME CCircuitDef::RoleType <-> CRecruitTask::RecruitType relations
	return Enqueue(TaskS::Recruit(CRecruitTask::RecruitType::FIREPOWER, result.priority, buildDef, pos, radius));
}

bool CFactoryManager::IsHighPriority(CAllyUnit* unit) const
{
	auto it = unfinishedUnits.find(unit);
	if (it == unfinishedUnits.end()) {
		return false;
	}
	return IBuilderTask::Priority::HIGH == it->second->GetPriority();
}

CCircuitDef* CFactoryManager::GetFactoryToBuild(AIFloat3 position, bool isStart, bool isReset)
{
	return static_cast<CFactoryScript*>(script)->GetFactoryToBuild(position, isStart, isReset);
}

void CFactoryManager::AddFactory(const CCircuitDef* cdef)
{
	factoryData->AddFactory(cdef);
}

void CFactoryManager::DelFactory(const CCircuitDef* cdef)
{
	factoryData->DelFactory(cdef);
}

bool CFactoryManager::IsT1Factory(const CCircuitDef* cdef)
{
	auto it = factoryDefs.find(cdef->GetId());
	if (it != factoryDefs.end()) {
		return it->second.isT1;
	}
	return false;
}

CCircuitDef* CFactoryManager::GetRoleDef(const CCircuitDef* facDef, CCircuitDef::RoleT role) const
{
	auto it = factoryDefs.find(facDef->GetId());
	return (it != factoryDefs.end()) ? GetFacRoleDef(role, it->second) : nullptr;
}

CCircuitDef* CFactoryManager::GetLandDef(const CCircuitDef* facDef) const
{
	auto it = factoryDefs.find(facDef->GetId());
	return (it != factoryDefs.end()) ? it->second.landDef : nullptr;
}

CCircuitDef* CFactoryManager::GetWaterDef(const CCircuitDef* facDef) const
{
	auto it = factoryDefs.find(facDef->GetId());
	return (it != factoryDefs.end()) ? it->second.waterDef : nullptr;
}

CCircuitDef* CFactoryManager::GetRepresenter(const CCircuitDef* facDef) const
{
	CCircuitDef* landDef = GetLandDef(facDef);
	if (landDef != nullptr) {
		if (landDef->GetMobileId() < 0) {
			return landDef;
		} else {
			CTerrainManager* terrainMgr = circuit->GetTerrainManager();
			SArea* area = terrainMgr->GetMobileTypeById(landDef->GetMobileId())->areaLargest;
			// FIXME: area->percentOfMap < 40.0 doesn't seem right as water identifier
			return ((area == nullptr) || (area->percentOfMap < terrainMgr->GetMinLandPercent())) ? GetWaterDef(facDef) : landDef;
		}
	} else {
		return GetWaterDef(facDef);
	}
}

CCircuitDef* CFactoryManager::GetLargestDef(const CCircuitDef* facDef) const
{
	auto it = factoryDefs.find(facDef->GetId());
	if (it == factoryDefs.end()) {
		return nullptr;
	}
	int maxSize = -1;
	CCircuitDef* largestDef = nullptr;
	for (CCircuitDef* bd : it->second.buildDefs) {
		int size = std::max(bd->GetMoveXSize(), bd->GetMoveZSize());
		if (size > maxSize) {
			maxSize = size;
			largestDef = bd;
		}
	}
	return largestDef;
}

const CFactoryManager::SFactoryDef* CFactoryManager::GetFactoryDef(CCircuitDef* facDef) const
{
	auto itF = factoryDefs.find(facDef->GetId());
	if (itF == factoryDefs.end()) {
		return nullptr;
	}
	return &itF->second;
}

const std::vector<float>* CFactoryManager::GetTierWeights(CCircuitDef* facDef, int surfType, int tier) const
{
	const SFactoryDef* sfac = GetFactoryDef(facDef);
	if (sfac == nullptr) {
		return nullptr;
	}

	const SFactoryDef::Tiers* tiers;
	switch (surfType) {
		case SFactoryDef::ESurfType::AIR: {
			tiers = &sfac->airTiers;
		} break;
		case SFactoryDef::ESurfType::LAND: {
			tiers = &sfac->landTiers;
		} break;
		case SFactoryDef::ESurfType::WATER: {
			tiers = &sfac->waterTiers;
		} break;
		default:
			return nullptr;
	}

	auto it = tiers->find(tier);
	if (it == tiers->end()) {
		return nullptr;
	}
	return &it->second;
}

CCircuitDef* CFactoryManager::DefaultGetFactoryToBuild(const AIFloat3& position, bool isStart, bool isReset)
{
	CCircuitDef* facDef = factoryData->GetFactoryToBuild(circuit, position, isStart, isReset);
	if ((facDef == nullptr) && geom::is_valid(position)) {
		facDef = factoryData->GetFactoryToBuild(circuit, -RgtVector, isStart, isReset);
	}
	return facDef;
}

void CFactoryManager::EnableFactory(CCircuitUnit* unit)
{
	// check nanos around
	std::map<CCircuitDef*, SAssistant> nanos;
	const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
	COOAICallback* clb = circuit->GetCallback();
	auto& units = clb->GetFriendlyUnitsIn(pos, GetAssistRange() * 0.9f);
	int teamId = circuit->GetTeamId();
	for (Unit* nano : units) {
		int unitId = nano->GetUnitId();
		CCircuitDef* nDef = circuit->GetCircuitDef(clb->Unit_GetDefId(unitId));
		if (nDef->IsAssist() && (nano->GetTeam() == teamId) && !nano->IsBeingBuilt()) {
			CCircuitUnit* ass = circuit->GetTeamUnit(unitId);
			// NOTE: OOAICallback::GetFriendlyUnits may return yet unregistered units created in GamePreload
			if (ass != nullptr) {
				SAssistant& assist = nanos[nDef];
				assist.units.insert(ass);
			}
		}
		delete nano;
	}
//	utils::free_clear(units);

	float facWorkerTime = unit->GetCircuitDef()->GetWorkerTime();
	float miRequire;
	float eiRequire;
	CCircuitDef* reprDef = GetRepresenter(unit->GetCircuitDef());
	if (reprDef == nullptr) {
		miRequire = unit->GetCircuitDef()->GetBuildSpeed();
		eiRequire = miRequire / circuit->GetEconomyManager()->GetEcoEM();
	} else {
		const float buildTime = reprDef->GetBuildTime() / facWorkerTime;
		miRequire = reprDef->GetCostM() / buildTime;
		eiRequire = reprDef->GetCostE() / buildTime;
	}
	float miRequireTotal = miRequire;
	float eiRequireTotal = eiRequire;
	unsigned int nanoSize = 0;
	for (auto& kv : nanos) {
		const float mod = kv.first->GetWorkerTime() / facWorkerTime;
		kv.second.incomeMod = mod;
		const float metalUse = miRequire * mod;
		const float energyUse = eiRequire * mod + kv.first->GetUpkeepE();
		miRequireTotal += metalUse;
		eiRequireTotal += energyUse;
		nanoSize += kv.second.units.size();

		for (CCircuitUnit* ass : kv.second.units) {
			SAssistToFactory& af = assists[ass];
			if (af.factories.empty()) {
				af.metalRequire = metalUse;
				af.energyRequire = energyUse;
				metalRequire += metalUse;
				energyRequire += energyUse;
			} else {
				if (af.metalRequire < metalUse) {
					metalRequire += metalUse - af.metalRequire;
					af.metalRequire = metalUse;
				}
				if (af.energyRequire < energyUse) {
					energyRequire += energyUse - af.energyRequire;
					af.energyRequire = energyUse;
				}
			}
			af.factories.insert(unit);
		}
	}

	metalRequire += miRequire;
	energyRequire += eiRequire;

	if (factories.empty()) {
		circuit->GetSetupManager()->SetBasePos(pos);
		circuit->GetMilitaryManager()->MakeBaseDefence(pos);
	}

	auto it = factoryDefs.find(unit->GetCircuitDef()->GetId());
	if (it != factoryDefs.end()) {
		const SFactoryDef& facDef = it->second;
		factories.emplace_back(unit, nanos, nanoSize, facDef.nanoCount, GetFacRoleDef(ROLE_TYPE(BUILDER), facDef),
				miRequire, eiRequire, miRequireTotal, eiRequireTotal);
	} else {
		factories.emplace_back(unit, nanos, nanoSize, 0, nullptr, 0.f, 0.f, 0.f, 0.f);
	}

	if (!IsT1Factory(unit->GetCircuitDef())) {
		noT1FacCount++;
	}

	if (unit->GetCircuitDef()->GetMobileId() < 0) {
		validAir.insert(unit);
	}
}

void CFactoryManager::DisableFactory(CCircuitUnit* unit)
{
	std::vector<CRecruitTask*> garbageTasks;
	for (CRecruitTask* task : factoryTasks) {
		if (task->GetAssignees().empty()) {
			garbageTasks.push_back(task);
		}
	}
	for (CRecruitTask* task : garbageTasks) {
		AbortTask(task);
	}

	auto checkBuilderFactory = [this](const int frame) {
		CBuilderManager* builderMgr = this->circuit->GetBuilderManager();
		// check if any factory with builders left
		bool hasBuilder = false;
		for (SFactory& fac : factories) {
			if ((fac.builder != nullptr) && fac.builder->IsAvailable(frame)) {
				hasBuilder = true;
				break;
			}
		}
		if (!hasBuilder) {
			// check queued factories
			std::set<IBuilderTask*> tasks = builderMgr->GetTasks(IBuilderTask::BuildType::FACTORY);
			for (IBuilderTask* task : tasks) {
				auto it = factoryDefs.find(task->GetBuildDef()->GetId());
				if (it != factoryDefs.end()) {
					const SFactoryDef& facDef = it->second;
					CCircuitDef* bdef = GetFacRoleDef(ROLE_TYPE(BUILDER), facDef);
					hasBuilder = ((bdef != nullptr) && bdef->IsAvailable(frame));
					if (hasBuilder) {
						break;
					} else if (task->GetTarget() == nullptr) {
						builderMgr->AbortTask(task);
					}
				}
			}
			if (!hasBuilder) {
				// queue new factory with builder
				CCircuitDef* facDef = GetFactoryToBuild(-RgtVector, true, true);
				if (facDef != nullptr) {
					// D-101: the role reserved the site (the layout, while a turret stands):
					// the task goes there, pinned (played: unpinned, native's own search
					// reserved a footprint beside the old lab and built there)
					CTerrainManager* terrainMgr = circuit->GetTerrainManager();
					const int slot = terrainMgr->TakeResetFactorySlot();
					const AIFloat3 at = (slot >= 0) ? terrainMgr->GetReservationPos(slot) : -RgtVector;
					IBuilderTask* task = builderMgr->Enqueue(TaskB::Factory(IBuilderTask::Priority::NOW, facDef, at, GetRepresenter(facDef)));
					if ((slot >= 0) && (task != nullptr) && !task->PinReservation(slot)) {
						circuit->LOG("RESERVE: replacement %s could not be pinned to slot %i", facDef->GetDef()->GetName(), slot);
					}
				}
			}
		}
	};

	if (unit->GetTask()->GetType() == IUnitTask::Type::NIL) {
		checkBuilderFactory(circuit->GetLastFrame());
		return;
	}

	for (auto it = factories.begin(); it != factories.end(); ++it) {
		if (it->unit != unit) {
			continue;
		}

		metalRequire -= it->miRequire;
		energyRequire -= it->eiRequire;

		for (auto& kv : it->nanos) {
			for (CCircuitUnit* ass : kv.second.units) {
				SAssistToFactory& af = assists[ass];
				af.factories.erase(unit);
				if (af.factories.empty()) {
					metalRequire -= af.metalRequire;
					energyRequire -= af.energyRequire;
					af.metalRequire = 0.f;
					af.energyRequire = 0.f;
				} else {
					float maxMetalUse = 0.f;
					float maxEnergyUse = 0.f;
					for (CCircuitUnit* fac : af.factories) {
						auto fit = factories.begin();  // FIXME: Nested loops
						while ((fit->unit != fac) && (fit != factories.end())) {
							++fit;
						}
						if (fit != factories.end()) {
							const float mod = fit->nanos[ass->GetCircuitDef()].incomeMod;
							maxMetalUse = std::max(maxMetalUse, fit->miRequire * mod);
							maxEnergyUse = std::max(maxEnergyUse, fit->eiRequire * mod + ass->GetCircuitDef()->GetUpkeepE());
						}
					}
					metalRequire -= af.metalRequire - maxMetalUse;
					energyRequire -= af.energyRequire - maxEnergyUse;
					af.metalRequire = maxMetalUse;
					af.energyRequire = maxEnergyUse;
				}
			}
		}

		*it = factories.back();
		factories.pop_back();
		break;
	}

	if (!factories.empty()) {
		const AIFloat3& pos = factories.front().unit->GetPos(circuit->GetLastFrame());
		circuit->GetSetupManager()->SetBasePos(pos);
	}

	if (!IsT1Factory(unit->GetCircuitDef())) {
		noT1FacCount--;
	}

	if (unit->GetCircuitDef()->GetMobileId() < 0) {
		validAir.erase(unit);
	}

	checkBuilderFactory(circuit->GetLastFrame());
}

IUnitTask* CFactoryManager::DefaultMakeTask(CCircuitUnit* unit)
{
	return MakeFactoryTask(unit, false);
}

IUnitTask* CFactoryManager::GetPendingFactoryTask(CCircuitUnit* unit) const
{
    if (unit == nullptr || unit->GetCircuitDef()->IsAssist()) return nullptr;
    // Preserve the manager's ordered eligibility/ownership test. Selection only:
    // O(P) existing recruit tasks, no queue mutation, new orders or retained handle.
    for (CRecruitTask* task : factoryTasks) {
        if (task->CanAssignTo(unit)) return task;
    }
    return nullptr;
}

IUnitTask* CFactoryManager::MakeFactoryTask(CCircuitUnit* unit, bool keepActive, bool keepQueued)
{
	const IUnitTask* task = nullptr;

	if (unit->GetCircuitDef()->IsAssist()) {
		task = CreateAssistTask(unit);

	} else {

        task = GetPendingFactoryTask(unit);

		if (task == nullptr) {
			task = CreateFactoryTask(unit, keepActive, keepQueued);
		}
	}

	return const_cast<IUnitTask*>(task);  // if nullptr then continue to Wait (or Idle)
}

IUnitTask* CFactoryManager::CreateFactoryTask(CCircuitUnit* unit, bool keepActive, bool keepQueued)
{
	if (unit->GetCircuitDef()->GetMobileId() < 0) {
		if (circuit->GetEnemyManager()->IsAirValid()) {
			if (validAir.find(unit) == validAir.end()) {
				EnableFactory(unit);
			}
		} else {
			if (validAir.find(unit) != validAir.end()) {
				DisableFactory(unit);
			}
			return Enqueue(TaskS::Wait(false, FRAMES_PER_SEC * 10));
		}
	}

	// Script may retain a complementary low-tier factory after teching.
	// This per-request lever changes no metadata or global tier counts. Keep
	// normal availability, AA viability, resource and pending-task checks.
	// O(1) policy input: no extra unit scan, cache or engine command.
	const bool isActive = keepActive || (noT1FacCount <= 0) || !IsT1Factory(unit->GetCircuitDef());

	IUnitTask* task = UpdateBuildPower(unit, isActive);
	if (task != nullptr) {
		return task;
	}

	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	const bool isStalling = economyMgr->IsMetalEmpty() &&
							(economyMgr->GetAvgMetalIncome() * 1.2f < economyMgr->GetMetalPull()) &&
							(metalPull * economyMgr->GetPullMtoS() > circuit->GetBuilderManager()->GetMetalPull());
	const bool isNotReady = !economyMgr->IsExcessed() || isStalling;
	// D-211: script can keep one valid recruit queued through a resource dip.
	// The existing recruit task still gates energy and lowers spending priority
	// under metal pressure. Other roles retain admission waits by default.
	// O(1) extra policy input; no polling, extra recruit, or repeated command.
	if (isNotReady && !keepQueued) {
		return Enqueue(TaskS::Wait(false, FRAMES_PER_SEC * 3));
	}

	task = UpdateFirePower(unit, isActive);
	if (task != nullptr) {
		return task;
	}

	return Enqueue(TaskS::Wait(false, isActive ? (FRAMES_PER_SEC * 3) : (FRAMES_PER_SEC * 10)));
}

IUnitTask* CFactoryManager::CreateAssistTask(CCircuitUnit* unit)
{
	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	bool isMetalEmpty = economyMgr->IsMetalEmpty();
	CAllyUnit* repairTarget = nullptr;
	CAllyUnit* buildTarget = nullptr;
	const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
	float radius = unit->GetCircuitDef()->GetBuildDistance();

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	CCircuitDef* terraDef = builderMgr->GetTerraDef();
	const float maxCost = MAX_BUILD_SEC * economyMgr->GetAvgMetalIncome() * economyMgr->GetEcoFactor();
	float curCost = std::numeric_limits<float>::max();
	circuit->UpdateFriendlyUnits();
	// NOTE: OOAICallback::GetFriendlyUnitsIn depends on unit's radius
    // Keep the engine quad-field order/radius (first repair wins), but borrow
    // the already refreshed ally/owned wrapper instead of allocating one per
    // candidate. No callbacks below mutate membership or invoke script.
    const auto& candidates = circuit->GetCallback()->GetFriendlyUnitIdsIn(pos, radius * 0.9f);
    for (int candidateId : candidates) {
        const bool isTeam = circuit->GetCallback()->Unit_Team(candidateId) == circuit->GetTeamId();
        CAllyUnit* cand = isTeam ? circuit->GetTeamUnit(candidateId) : circuit->GetFriendlyUnit(candidateId);
		if ((cand == nullptr) || (cand == unit)
			|| builderMgr->IsReclaimUnit(cand)
			|| (isTeam ? static_cast<CCircuitUnit*>(cand)->IsAttrNoRepair() : cand->GetCircuitDef()->IsAttrNoRepair()))
		{
			continue;
		}
		Unit* u = cand->GetUnit();
		if (u->IsBeingBuilt()) {
			CCircuitDef* cdef = cand->GetCircuitDef();
			const float maxHealth = u->GetMaxHealth();
			const float buildTime = cdef->GetBuildTime() * (maxHealth - u->GetHealth()) / maxHealth;
			if (buildTime >= curCost) {
				continue;
			}
			if (IsHighPriority(cand) ||
				(!isMetalEmpty && cdef->IsAssistable()) ||
				(*cdef == *terraDef) ||
				(buildTime < maxCost))
			{
				curCost = buildTime;
				buildTarget = cand;
			}
		} else if ((repairTarget == nullptr) && (u->GetHealth() < u->GetMaxHealth())) {
			repairTarget = cand;
			if (isMetalEmpty) {
				break;
			}
		}
	}
	if (/*!isMetalEmpty && */(buildTarget != nullptr)) {
		// Construction task
		IBuilderTask::Priority priority = buildTarget->GetCircuitDef()->IsMobile() ?
										  IBuilderTask::Priority::HIGH :
										  IBuilderTask::Priority::NORMAL;
		return Enqueue(TaskS::Repair(priority, buildTarget));
	}
	if (repairTarget != nullptr) {
		// Repair task
		return Enqueue(TaskS::Repair(IBuilderTask::Priority::NORMAL, repairTarget));
	}
	if (isMetalEmpty) {
		// Reclaim task
		if (circuit->GetCallback()->IsFeaturesIn(pos, radius) && !builderMgr->IsResurrect(pos, radius)) {
			return Enqueue(TaskS::Reclaim(IBuilderTask::Priority::NORMAL, pos, radius));
		}
	}

	return Enqueue(TaskS::Wait(false, FRAMES_PER_SEC * 3));
}

CEnemyInfo* CFactoryManager::GetReclaimEnemy(CCircuitUnit* turret, int enemyId) const
{
	if (turret == nullptr || turret->IsDead() || enemyId < 0) return nullptr;
	CEnemyInfo* enemy = circuit->GetEnemyInfo(enemyId);
	if (enemy == nullptr || enemy->GetCircuitDef() == nullptr || enemy->GetUnit() == nullptr) return nullptr;
	const CEnemyUnit* data = enemy->GetData();
	Unit* target = enemy->GetUnit();
	// Role target preferences must not hide an enemy next to a construction turret.
	// Engine LOS, current allegiance and game-level exclusions still apply.
	if (!enemy_reclaim::EligibleTarget(enemy->IsInLOS(),
			target->GetAllyTeam() != circuit->GetAllyTeamId() && !target->IsNeutral(),
			enemy->GetCircuitDef()->IsReclaimable(), !data->IsDead() && !data->IsDying() && target->GetHealth() > 0.f,
			target->GetRulesParamFloat("ignoredByAI", 0.f) > 0.f)) return nullptr;
	const AIFloat3& pos = turret->GetPos(circuit->GetLastFrame());
	const AIFloat3 targetPos = target->GetPos(); // live visible position, not the slow threat snapshot
	CCircuitDef* def = turret->GetCircuitDef();
	const float distance = def->GetDef()->IsBuildRange3D() ? pos.SqDistance(targetPos) : pos.SqDistance2D(targetPos);
	return enemy_reclaim::InRange(distance, def->GetBuildDistance(), enemy->GetCircuitDef()->GetRadius()) ? enemy : nullptr;
}

void CFactoryManager::UpdateEnemyReclaim()
{
	ZoneScopedN(__PRETTY_FUNCTION__);
	enemyReclaimMisses = 0;
	// Snapshot IDs: task removal/assignment dispatches script callbacks.
	enemyReclaimUnits.clear();
	enemyReclaimUnits.reserve(assists.size());
	for (const auto& entry : assists) enemyReclaimUnits.push_back(entry.first->GetId());
	for (int id : enemyReclaimUnits) {
		CCircuitUnit* unit = circuit->GetTeamUnit(id);
		if (unit == nullptr || unit->IsDead() || unit->GetTask() == nullptr) continue;
		IUnitTask* current = unit->GetTask();
		CCircuitDef* def = unit->GetCircuitDef();
		if (!enemy_reclaim::EligibleTurret(def->IsMobile(), def->IsAssist(), def->IsAbleToReclaim(),
				!unit->GetUnit()->IsBeingBuilt(), current->GetType() == IUnitTask::Type::PLAYER)) continue;
		CSReclaimTask* active = current->IsEnemyReclaim() ? static_cast<CSReclaimTask*>(current) : nullptr;
		int targetId = active == nullptr ? -1 : active->GetEnemyId();
		CEnemyInfo* target = enemyReclaimEnabled ? GetReclaimEnemy(unit, targetId) : nullptr;
		if (enemyReclaimEnabled && target == nullptr) {
			const AIFloat3 pos = unit->GetPos(circuit->GetLastFrame());
			float best = std::numeric_limits<float>::max();
			// Engine quad-field query includes target model radii and filters LOS.
			const auto& enemies = circuit->GetCallback()->GetEnemyUnitIdsIn(pos, def->GetBuildDistance(), false);
			for (int candidate : enemies) {
				CEnemyInfo* enemy = GetReclaimEnemy(unit, candidate);
				if (enemy == nullptr) continue;
				const float distance = pos.SqDistance2D(enemy->GetUnit()->GetPos());
				if (distance < best || (distance == best && candidate < targetId)) {
					best = distance; target = enemy; targetId = candidate;
				}
			}
		}
		if (target == nullptr) {
			if (active != nullptr) {
				circuit->LOG("[TurretReclaim] release turret=%i target=%i", id, active->GetEnemyId());
				DoneTask(active); // returns to ordinary role decisions
			}
			continue;
		}
		if (active == nullptr) {
			active = new CSReclaimTask(this, targetId); // ownership transfers to updateTasks
			updateTasks.push_back(active);
			TaskAdded(active);
			unit = circuit->GetTeamUnit(id);
			if (unit == nullptr || unit->IsDead() || active->IsDead() || unit->GetTask() != current) {
				if (!active->IsDead()) AbortTask(active);
				continue;
			}
			// Remove the old manager's idle membership as well as its assignment.
			// TECH recycling can temporarily lend a factory-owned nano to Builder.
			ITaskModule* oldManager = current->GetManager();
			current->RemoveAssignee(unit);
			unit = circuit->GetTeamUnit(id);
			if (unit == nullptr || unit->IsDead() || active->IsDead()
				|| unit->GetTask() != oldManager->GetIdleTask()) {
				if (!active->IsDead()) AbortTask(active);
				continue;
			}
			oldManager->GetIdleTask()->RemoveAssignee(unit);
			active->AssignTo(unit);
			active->Start(unit);
			circuit->LOG("[TurretReclaim] interrupt turret=%i def=%s target=%i", id, def->GetDef()->GetName(), targetId);
		} else {
			active->ReclaimEnemy(unit, targetId);
		}
		if (unit->GetTask() != active || active->IsDead() || active->GetPriority() != IUnitTask::Priority::NOW) ++enemyReclaimMisses;
	}
}

void CFactoryManager::Watchdog()
{
	ZoneScopedN(__PRETTY_FUNCTION__);

	auto checkIdler = [this](CCircuitUnit* unit) {
		if (unit->GetTask()->GetType() == IUnitTask::Type::PLAYER) {
			return;
		}
		if (!this->circuit->GetCallback()->Unit_HasCommands(unit->GetId())) {
			UnitIdle(unit);
		}
	};

	for (SFactory& fac : factories) {
		checkIdler(fac.unit);
	}

	for (auto& kv : assists) {
		checkIdler(kv.first);
	}
}

void CFactoryManager::SetLastRequiredDef(CCircuitDef::Id facId, CCircuitDef* cdef,
		const std::vector<float>& probs, bool isResp)
{
	SFireDef& lastDef = lastFireDef[facId];
	lastDef.cdef = cdef;
	lastDef.probs = &probs;
	lastDef.buildCount = 0;
	lastDef.isResponse = isResp;
}

std::pair<CCircuitDef*, bool> CFactoryManager::GetLastRequiredDef(CCircuitDef::Id facId,
		const std::vector<float>& probs, const std::function<bool (CCircuitDef*)>& isAvailable)
{
	SFireDef& lastDef = lastFireDef[facId];
	if ((lastDef.cdef != nullptr) && (++lastDef.buildCount < numBatch) && isAvailable(lastDef.cdef)
		&& (!lastDef.isResponse || ((&probs == lastDef.probs) && (circuit->GetMilitaryManager()->RoleProbability(lastDef.cdef) > 0.f))))
	{
		return std::make_pair(lastDef.cdef, lastDef.isResponse);
	}
	return std::make_pair(nullptr, false);
}

CFactoryManager::SRecruitDef CFactoryManager::RequiredFireDef(CCircuitUnit* builder, bool isActive)
{
	auto it = factoryDefs.find(builder->GetCircuitDef()->GetId());
	if (it == factoryDefs.end()) {
		return {-1};
	}
	const SFactoryDef& facDef = it->second;

	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();
	const bool isMetalFull = economyMgr->IsMetalFull();
	// spoiled by metal converters, using isEnergyStalling
//	const float energyNet = economyMgr->GetAvgEnergyIncome() - economyMgr->GetEnergyPull();
	const bool isEnergyStalling = economyMgr->IsEnergyStalling();
	const float range = builder->GetCircuitDef()->GetBuildDistance();
	const AIFloat3& pos = builder->GetPos(frame);

	const int iS = terrainMgr->GetSectorIndex(pos);
	auto isEnemyInArea = [&](CCircuitDef* bd) {
		if (isMetalFull || (frame < FRAMES_PER_SEC * 60 * 10)) {  // TODO: Change to minimum required army power
			return true;
		}
		SArea* area;
		bool isValid;
		std::tie(area, isValid) = terrainMgr->GetCurrentMapArea(bd, iS);
		return isValid && ((area == nullptr) || terrainMgr->IsEnemyInArea(area));
	};
	auto isAvailableDef = [&](CCircuitDef* bd) {
		return (((bd->GetCloakCost() < .1f)/* || (energyNet > bd->GetCloakCost())*/ || !isEnergyStalling)
			&& bd->IsAvailable(frame)
			&& (isActive || bd->IsAttrRare())
			&& terrainMgr->CanBeBuiltAt(bd, pos, range)
			&& isEnemyInArea(bd));
	};

	const std::vector<float>& probs = GetFacTierProbs(facDef);
	auto getPriority = [](const bool isResponse) {
		return isResponse ? CRecruitTask::Priority::NORMAL : CRecruitTask::Priority::LOW;
	};

#ifdef FACTORY_CHOICE
	circuit->LOG("---- FACTORY AI = %i | %s | %s | tier%i ----", circuit->GetSkirmishAIId(), builder->GetCircuitDef()->GetDef()->GetName(), unitTypeDbg.c_str(), tierDbg);
#endif
	CCircuitDef* buildDef = nullptr;
	bool isResponse = false;
	std::tie(buildDef, isResponse) = GetLastRequiredDef(it->first, probs, isAvailableDef);
	if ((buildDef != nullptr) && isResponse) {
#ifdef FACTORY_CHOICE
		circuit->LOG("batch %s", buildDef->GetDef()->GetName());
#endif
		return {buildDef->GetId(), getPriority(isResponse)};
	}

	struct SCandidate {
		CCircuitDef* cdef;
		float weight;
		bool isResponse;
	};
	std::vector<SCandidate> candidates;
	candidates.reserve(facDef.buildDefs.size());

	CMilitaryManager* militaryMgr = circuit->GetMilitaryManager();
	const float maxCost = militaryMgr->GetArmyCost();
	float magnitude = 0.f;
	for (unsigned i = 0; i < facDef.buildDefs.size(); ++i) {
		CCircuitDef* bd = facDef.buildDefs[i];
		if (!isAvailableDef(bd)) {
#ifdef FACTORY_CHOICE
			std::string reason;
			if ((bd->GetCloakCost() > .1f)/* && (energyNet < bd->GetCloakCost())*/ && isEnergyStalling) {
				reason = "no energy";
			} else if (!bd->IsAvailable(frame)) {
				reason = "limit exceeded or frame < since";
			} else if (!isActive && !bd->IsAttrRare()) {
				reason = "non-rare from inactive factory";
			} else if (!terrainMgr->CanBeBuiltAt(bd, pos, range)) {
				reason = "can't build unit at unusable map position";
			} else if (!isEnemyInArea(bd)) {
				reason = "no enemies in related map area";
			}
			circuit->LOG("ignore %s | reason = %s", bd->GetDef()->GetName(), reason.c_str());
#endif
			continue;
		}

		if (probs[i] > 0.f) {
			// (probs[i] + response_weight) hints preferable buildDef within same role
			float prob = militaryMgr->RoleProbability(bd) * (probs[i] + reWeight);
			// NOTE: with probs=[n1, n2, n3, n4, n5]
			//       previous response system provided probs2=[0, res(n2), 0, 0, res(n5)]
			//       current is probs2=[n1, res(n2), n3, n4, res(n5)]
			bool isResp = (prob > 0.f) && (bd->GetCostM() <= maxCost);
			isResponse |= isResp;
			prob = isResp ? prob : probs[i];
			candidates.push_back({bd, prob, isResp});
			magnitude += prob;
#ifdef FACTORY_CHOICE
			circuit->LOG("%s | %s | %f", isResp ? "response" : "regular", bd->GetDef()->GetName(), prob);
#endif
		}
	}

	if ((buildDef != nullptr) && !isResponse) {
#ifdef FACTORY_CHOICE
		circuit->LOG("batch %s", buildDef->GetDef()->GetName());
#endif
		return {buildDef->GetId(), getPriority(isResponse)};
	}

	if (magnitude == 0.f) {  // workaround for disabled units
		if (!candidates.empty()) {
			buildDef = candidates[rand() % candidates.size()].cdef;
		}
	} else {
		float dice = (float)rand() / RAND_MAX * magnitude;
		for (const SCandidate& candy : candidates) {
			dice -= candy.weight;
			if (dice < 0.f) {
				buildDef = candy.cdef;
				isResponse = candy.isResponse;
				break;
			}
		}
	}

	SetLastRequiredDef(it->first, buildDef, probs, isResponse);
	if (buildDef != nullptr) {
#ifdef FACTORY_CHOICE
		circuit->LOG("choice = %s", buildDef->GetDef()->GetName());
#endif
		return {buildDef->GetId(), getPriority(isResponse)};
	}
	return {-1};
}

const std::vector<float>& CFactoryManager::GetFacTierProbs(const SFactoryDef& facDef) const
{
	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	const float metalIncome = std::min(economyMgr->GetAvgMetalIncome(), economyMgr->GetAvgEnergyIncome()) * economyMgr->GetEcoFactor();
	const bool isWaterMap = circuit->GetTerrainManager()->IsWaterMap();
	const float enemyTotalAirCost = circuit->GetEnemyManager()->GetEnemyCost(ROLE_TYPE(AIR));
	const float allyAACost = circuit->GetMilitaryManager()->GetRoleCost(ROLE_TYPE(AA)) * circuit->GetAllyTeam()->GetAliveSize();
	const bool isAir = enemyTotalAirCost > allyAACost;
	const SFactoryDef::Tiers& tiers = isAir ? facDef.airTiers : isWaterMap ? facDef.waterTiers : facDef.landTiers;
#ifdef FACTORY_CHOICE
	unitTypeDbg = isAir ? "air" : isWaterMap ? "water" : "land";
	tierDbg = 0;
#endif
	auto facIt = tiers.begin();
	if ((metalIncome >= facDef.incomes[facIt->first]) && !(facDef.isRequireEnergy && economyMgr->IsEnergyEmpty())) {
		while (facIt != tiers.end()) {
			if (metalIncome < facDef.incomes[facIt->first]) {
				break;
			}
			++facIt;
#ifdef FACTORY_CHOICE
			tierDbg++;
#endif
		}
		if (facIt == tiers.end()) {
			--facIt;
#ifdef FACTORY_CHOICE
			tierDbg--;
#endif
		}
	}
	return facIt->second;
}

CCircuitDef* CFactoryManager::GetFacRoleDef(CCircuitDef::RoleT role, const SFactoryDef& facDef) const
{
	const std::vector<float>& probs = GetFacTierProbs(facDef);

	static std::vector<std::pair<CCircuitDef*, float>> candidates;  // NOTE: micro-opt
//	candidates.reserve(facDef.buildDefs.size());

	const int frame = circuit->GetLastFrame();
	float magnitude = 0.f;
	for (unsigned i = 0; i < facDef.buildDefs.size(); ++i) {
		CCircuitDef* bd = facDef.buildDefs[i];
		if (((bd->GetMainRole() != role) && (circuit->GetBindedRole(bd->GetMainRole()) != role))
			|| !bd->IsAvailable(frame))  // builderT2 -> builder conversion
		{
			continue;
		}

		if (probs[i] > 0.f) {
			candidates.push_back(std::make_pair(bd, probs[i]));
			magnitude += probs[i];
		}
	}

	CCircuitDef* buildDef = nullptr;
	if (magnitude == 0.f) {  // workaround for disabled units
		// FIXME: for previous algo with probs[i]==0; never true with probs[i]>0
		if (!candidates.empty()) {
			buildDef = candidates[rand() % candidates.size()].first;
		}
	} else {
		float dice = (float)rand() / RAND_MAX * magnitude;
		for (auto& pair : candidates) {
			dice -= pair.second;
			if (dice < 0.f) {
				buildDef = pair.first;
				break;
			}
		}
	}
	candidates.clear();

	return buildDef;
}

} // namespace circuit
