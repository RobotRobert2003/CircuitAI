/*
 * EconomyManager.cpp
 *
 *  Created on: Sep 5, 2014
 *      Author: rlcevg
 */

#include "module/EconomyManager.h"
#include "module/BuilderManager.h"
#include "module/FactoryManager.h"
#include "module/MilitaryManager.h"
#include "scheduler/Scheduler.h"
#include "script/EconomyScript.h"
#include "setup/SetupManager.h"
#include "resource/MetalManager.h"
#include "resource/MexNavigation.h"
#include "resource/EnergyManager.h"
#include "resource/EnergyGrid.h"
#include "task/builder/FactoryTask.h"
#include "task/builder/MexTask.h"
#include "terrain/TerrainManager.h"
#include "CircuitAI.h"
#include "util/GameAttribute.h"
#include "util/Utils.h"
#include "util/Profiler.h"
#include "json/json.h"

#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"

#include "AISCommands.h"
#include "Resource.h"
#include "Economy.h"
#include "unit/ally/AllyTeam.h"
#include "Game.h"
#include "Feature.h"
#include "FeatureDef.h"
#include "Team.h"
#include "Log.h"

#include <algorithm>
#include <limits>

namespace circuit {

using namespace springai;

#define PYLON_RANGE		500.0f

const char* RES_NAME_METAL = "Metal";
const char* RES_NAME_ENERGY = "Energy";

CEconomyManager::CEconomyManager(CCircuitAI* circuit)
		: IModule(circuit, new CEconomyScript(circuit->GetScriptManager(), this))
		, energyGrid(nullptr)
		, pylonDef(nullptr)
		, mexCount(0)
		, indexRes(0)
		, metalProduced(.0f)
		, metalUsed(.0f)
		, isMetalEmpty(false)
		, isMetalFull(false)
		, isEnergyStalling(false)
		, isEnergyEmpty(false)
		, isEnergyFull(false)
		, isEnergyRequired(false)
		, reclConvertEff(2.f)
		, reclEnergyEff(20.f)
		, startMexTravel(10.f)
		, metal(SResourceInfo {-1, .0f, .0f, .0f, .0f})
		, energy(SResourceInfo {-1, .0f, .0f, .0f, .0f})
		, metalPullCorFrame(-1)
		, metalPullCor(.0f)
		, energyPullCorFrame(-1)
		, energyPullCor(.0f)
		, airpadCount(0)
		, factoryTask(nullptr)
{
	metalRes = circuit->GetCallback()->GetResourceByName(RES_NAME_METAL);
	energyRes = circuit->GetCallback()->GetResourceByName(RES_NAME_ENERGY);
	economy = circuit->GetCallback()->GetEconomy();

	metalIncomes.resize(INCOME_SAMPLES, 1.0f);  // Init metal income
	energyIncomes.resize(INCOME_SAMPLES, 2.0f);  // Init energy income

	// TODO: Use A* ai planning... or sth... STRIPS https://ru.wikipedia.org/wiki/STRIPS
	//       https://ru.wikipedia.org/wiki/Марковский_процесс_принятия_решений

	circuit->GetScheduler()->RunOnInit(CScheduler::GameJob(&CEconomyManager::Init, this));
}

CEconomyManager::~CEconomyManager()
{
	delete metalRes;
	delete energyRes;
	delete economy;

	delete factoryTask;
}

void CEconomyManager::InitHandlers()
{
	/*
	 * resources
	 */
	auto energyFinishedHandler = [this](CCircuitUnit* unit) {
		const SEnergyExt* energyExt = energyDefs.GetAvailInfo(unit->GetCircuitDef());
		if (energyExt == nullptr) {
			return;
		}
		const float income = energyExt->make;
		for (int i = 0; i < INCOME_SAMPLES; ++i) {
			energyIncomes[i] += income;
		}
		energy.income += income;
		ReclaimOldEnergy(energyExt);

		UnitAdded(unit, UseAs::ENERGY);
	};
	auto energyDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		UnitRemoved(unit, UseAs::ENERGY);
	};
	auto geoFinishedHandler = [this](CCircuitUnit* unit) {
		const SGeoExt* geoExt = geoDefs.GetAvailInfo(unit->GetCircuitDef());
		if (geoExt != nullptr) {
			const float income = geoExt->make;
			for (int i = 0; i < INCOME_SAMPLES; ++i) {
				energyIncomes[i] += income;
			}
			energy.income += income;
		}

		UnitAdded(unit, UseAs::GEO);
	};
	auto geoDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		UnitRemoved(unit, UseAs::GEO);
	};
	auto mexFinishedHandler = [this](CCircuitUnit* unit) {
		if (metalMap) { UnitAdded(unit, UseAs::MEX); return; } // measured income owns field accounting
//		const float income = unit->GetUnit()->GetRulesParamFloat("mexIncome", 0.f);
		CMetalManager* metalMgr = this->circuit->GetMetalManager();
		int index = metalMgr->FindNearestSpot(unit->GetPos(this->circuit->GetLastFrame()));
		if (index < 0) {
			return;
		}
		const float income = metalMgr->GetSpots()[index].income * unit->GetCircuitDef()->GetExtractsM();
		for (int i = 0; i < INCOME_SAMPLES; ++i) {
			metalIncomes[i] += income;
		}
		metal.income += income;

		UnitAdded(unit, UseAs::MEX);
	};
	auto mexDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		UnitRemoved(unit, UseAs::MEX);
	};
	auto convertFinishedHandler = [this](CCircuitUnit* unit) {
		const SConvertExt* convertExt = convertDefs.GetAvailInfo(unit->GetCircuitDef());
		if (convertExt == nullptr) {
			return;
		}
		ReclaimOldConvert(convertExt);

		UnitAdded(unit, UseAs::CONVERT);
	};
	auto convertDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		UnitRemoved(unit, UseAs::CONVERT);
	};
	auto storeFinishedHandler = [this](CCircuitUnit* unit) {
		UnitAdded(unit, UseAs::STORE);
	};
	auto storeDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		UnitRemoved(unit, UseAs::STORE);
	};

	/*
	 * morph & plop
	 */
	auto comFinishedHandler = [this](CCircuitUnit* unit) {
		AddMorphee(unit);
		CSetupManager* setupMgr = this->circuit->GetSetupManager();
		if (setupMgr->GetCommander() == nullptr) {
			setupMgr->SetCommander(unit);
		}

		ICoreUnit::Id unitId = unit->GetId();
		this->circuit->GetScheduler()->RunJobAfter(CScheduler::GameJob([this, unitId]() {
			CCircuitUnit* unit = this->circuit->GetTeamUnit(unitId);
			if (unit == nullptr) {
				return;
			}
			int frame = this->circuit->GetLastFrame();
			bool isStart = (frame < FRAMES_PER_SEC * 10);
			AIFloat3 buildPos = -RgtVector;
			if (unit->GetUnit()->GetRulesParamFloat("facplop", 0) == 1) {
				// TODO: check factory's customparam ploppable=1
				const AIFloat3& pos = unit->GetPos(frame);
				CCircuitDef* facDef = this->circuit->GetFactoryManager()->GetFactoryToBuild(pos, isStart);
				if (facDef != nullptr) {
					// Enqueue factory
					CTerrainManager* terrainMgr = this->circuit->GetTerrainManager();
					const float range = std::max(facDef->GetDef()->GetXSize(), facDef->GetDef()->GetZSize())
							* SQUARE_SIZE / 2 * 1.4f + unit->GetCircuitDef()->GetRadius();
					buildPos = terrainMgr->ShiftPos(facDef, pos, range, true);
					CBuilderManager* builderMgr = this->circuit->GetBuilderManager();
					IBuilderTask* task = builderMgr->Enqueue(TaskB::Factory(IBuilderTask::Priority::NOW,
							facDef, buildPos, nullptr, SQUARE_SIZE, true, true, 0));
					builderMgr->AssignTask(unit, task);
				}
			}

			if (!isStart) {
				return;
			}
			int morphFrame = this->circuit->GetSetupManager()->GetMorphFrame(unit->GetCircuitDef());
			if (morphFrame >= 0) {
				this->circuit->GetScheduler()->RunJobAt(CScheduler::GameJob([this, unitId]() {
					// Force commander level 0 to morph
					CCircuitUnit* unit = this->circuit->GetTeamUnit(unitId);
					if ((unit != nullptr)
						&& (unit->GetTask()->GetType() != IUnitTask::Type::PLAYER))
					{
						const std::map<std::string, std::string>& customParams = unit->GetCircuitDef()->GetDef()->GetCustomParams();
						auto it = customParams.find("level");
						if ((it != customParams.end()) && (utils::string_to_int(it->second) <= 1)) {
							unit->Upgrade();  // Morph();
						}
					}
				}), morphFrame);
			}
		}), FRAMES_PER_SEC);
	};
	auto comDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		RemoveMorphee(unit);

		CSetupManager* setupMgr = this->circuit->GetSetupManager();
		CCircuitUnit* commander = setupMgr->GetCommander();
		if (commander == unit) {
			setupMgr->SetCommander(nullptr);
		}
	};

	/*
	 * Airpad counter
	 */
	auto airpadCreatedHandler = [this](CCircuitUnit* unit, CCircuitUnit* builder) {
		++airpadCount;
	};
	auto airpadFinishedHandler = [this](CCircuitUnit* unit) {
		UnitAdded(unit, UseAs::AIRPAD);
	};
	auto airpadDestroyedHandler = [this](CCircuitUnit* unit, CEnemyInfo* attacker) {
		--airpadCount;

		UnitRemoved(unit, UseAs::AIRPAD);
	};

	float minEInc;
	ReadConfig(minEInc);

	float maxAreaDivCost = .0f;
	const float avgWind = (circuit->GetMap()->GetMaxWind() + circuit->GetMap()->GetMinWind()) * 0.5f;

	for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
		const std::map<std::string, std::string>& customParams = cdef.GetDef()->GetCustomParams();
		if (metalMap) {
			const auto capacity = customParams.find("energyconv_capacity");
			const auto efficiency = customParams.find("energyconv_efficiency");
			if (capacity != customParams.end() && efficiency != customParams.end()
				&& utils::string_to_float(capacity->second) > 0 && utils::string_to_float(efficiency->second) > 0) {
				fieldConverters.insert(cdef.GetId());
				cdef.SetBuildAllowed(false);
			}
		}

		if (!cdef.IsMobile()) {
			// FIXME: Either assign score to different types of structure category,
			//        and assign to single category based on largest score;
			//        Or have a list of handlers instead of single handler per event.
			//        Issue: armfus is energy and e-store.
			bool isCategoryAssigned = false;

			// pylon
			auto it = customParams.find("pylonrange");
			if (it != customParams.end()) {
				const float range = utils::string_to_float(it->second);
				float areaDivCost = M_PI * SQUARE(range) / cdef.GetCostM();
				if (maxAreaDivCost < areaDivCost) {
					maxAreaDivCost = areaDivCost;
					pylonDef = &cdef;  // armestor
					pylonRange = range;
					// Is it cdef.IncPurpose(); ?
				}
			}

			// mex
			// BA: float metalConverts = unitDef->GetMakesResource(metalRes);
			//     float metalExtracts = unitDef->GetExtractsResource(metalRes);
			//     float netMetal = unitDef->GetResourceMake(metalRes) - unitDef->GetUpkeep(metalRes);
			// FIXME: BA
//			if (((it = customParams.find("ismex")) != customParams.end()) && (utils::string_to_int(it->second) == 1)) {
//				finishedHandler[cdef.GetId()] = mexFinishedHandler;
//				mexDef = &cdef;  // cormex
//				cdef.SetIsMex(true);
//			}
			// FIXME: BA
			if (cdef.GetExtractsM() > 0.f) {
				finishedHandler[cdef.GetId()] = mexFinishedHandler;
				destroyedHandler[cdef.GetId()] = mexDestroyedHandler;
				metalDefs.AddDef(&cdef);
				cdef.SetIsMex(true);
				IncPurpose(cdef.GetId());  // avoid reclaiming of multi-purpose old converter/energy
				continue;  // NOTE: won't deal with spot requirement if considered as anything else.
			}

			// energy
			// BA: float netEnergy = unitDef->GetResourceMake(energyRes) - unitDef->GetUpkeep(energyRes);
			cdef.SetIsWind(cdef.GetDef()->GetWindResourceGenerator(energyRes) > minEInc);
			it = customParams.find("income_energy");
			if (((it != customParams.end()) && (utils::string_to_float(it->second) > minEInc))
				|| (cdef.GetDef()->GetResourceMake(energyRes) - cdef.GetUpkeepE() > minEInc)
				|| (cdef.IsWind() && (avgWind > minEInc))
				|| (cdef.GetDef()->GetTidalResourceGenerator(energyRes) * circuit->GetMap()->GetTidalStrength() > minEInc))
			{
				if (cdef.GetDef()->IsNeedGeo()) {
					finishedHandler[cdef.GetId()] = geoFinishedHandler;
					destroyedHandler[cdef.GetId()] = geoDestroyedHandler;
					geoDefs.AddDef(&cdef);
				} else {
					finishedHandler[cdef.GetId()] = energyFinishedHandler;
					destroyedHandler[cdef.GetId()] = energyDestroyedHandler;
					energyDefs.AddDef(&cdef);
				}
				isCategoryAssigned = true;
				IncPurpose(cdef.GetId());  // avoid reclaiming of multi-purpose old converter/energy
			}

			// energy=>metal converter
			if (((it = customParams.find("energyconv_capacity")) != customParams.end()) && (utils::string_to_float(it->second) > 0.f)
				&& ((it = customParams.find("energyconv_efficiency")) != customParams.end()) && (utils::string_to_float(it->second) > 0.f))
			{
				if (!isCategoryAssigned) {
					finishedHandler[cdef.GetId()] = convertFinishedHandler;
					destroyedHandler[cdef.GetId()] = convertDestroyedHandler;
					convertDefs.AddDef(&cdef);
					isCategoryAssigned = true;
				}
				IncPurpose(cdef.GetId());  // avoid reclaiming of multi-purpose old converter/energy
			}

			// storage
			// NOTE: have to manually filter spot units, as mex placement rules are re-defined in game and break in-engine validation
			if ((cdef.GetDef()->GetStorage(metalRes) >= 1000.f)/* && !cdef.IsMex()*/) {
				if (!isCategoryAssigned) {
					finishedHandler[cdef.GetId()] = storeFinishedHandler;
					destroyedHandler[cdef.GetId()] = storeDestroyedHandler;
					storeMDefs.AddDef(&cdef);
					isCategoryAssigned = true;
				}
				IncPurpose(cdef.GetId());  // avoid reclaiming of multi-purpose old converter/energy
			}
			if ((cdef.GetDef()->GetStorage(energyRes) > 1000.f) && !cdef.GetDef()->IsNeedGeo()) {
				if (!isCategoryAssigned) {
					finishedHandler[cdef.GetId()] = storeFinishedHandler;
					destroyedHandler[cdef.GetId()] = storeDestroyedHandler;
					storeEDefs.AddDef(&cdef);
					isCategoryAssigned = true;
				}
				IncPurpose(cdef.GetId());  // avoid reclaiming of multi-purpose old converter/energy
			}

			if (customParams.find("isairbase") != customParams.end()) {
				if (!isCategoryAssigned) {
					createdHandler[cdef.GetId()] = airpadCreatedHandler;
					finishedHandler[cdef.GetId()] = airpadFinishedHandler;
					destroyedHandler[cdef.GetId()] = airpadDestroyedHandler;
					airpadDefs.AddDef(&cdef);
					isCategoryAssigned = true;
				}
				IncPurpose(cdef.GetId());  // avoid reclaiming of multi-purpose old converter/energy
			}

			if ((cdef.GetDef()->GetResourceMake(metalRes) - cdef.GetUpkeepM() > 0.f)
				|| cdef.GetDef()->IsBuilder())
			{
				IncPurpose(cdef.GetId());  // avoid reclaiming of multi-purpose old converter/energy
			}

		} else {

			// commander
			if (cdef.IsRoleComm()) {
				finishedHandler[cdef.GetId()] = comFinishedHandler;
				destroyedHandler[cdef.GetId()] = comDestroyedHandler;
			}

			for (const SSideInfo& sideInfo : sideInfos) {
				if (cdef.CanBuild(sideInfo.defaultDef)) {
					defaultDefs[cdef.GetId()] = sideInfo.defaultDef;
				}
			}
		}
	}

	// FIXME: BA
	for (SSideInfo& sideInfo : sideInfos) {
		if (sideInfo.mexDef == nullptr) {
			sideInfo.mexDef = sideInfo.defaultDef;
		}
		if (sideInfo.geoDef == nullptr) {
			sideInfo.geoDef = sideInfo.defaultDef;
		}
	}
	if (pylonDef == nullptr) {
		pylonDef = sideInfos[0].defaultDef;
		pylonRange = PYLON_RANGE;
	}
	// FIXME: BA
}

void CEconomyManager::ReadConfig(float& outMinEInc)
{
	const Json::Value& root = circuit->GetSetupManager()->GetConfig();
	const std::string& cfgName = circuit->GetSetupManager()->GetConfigName();
	const Json::Value& econ = root["economy"];
	InitMetalField();
	ecoStep = econ.get("eps_step", 0.25f).asFloat();
	ecoFactor = (circuit->GetAllyTeam()->GetSize() - 1.0f) * ecoStep + 1.0f;
	metalMod = (1.f - econ.get("excess", -1.f).asFloat());
	numMexUp = econ.get("mex_up", 2).asUInt();

	{
		const Json::Value& bd = econ["build_delay"];
		float value = bd[0].get((unsigned)0, -1.f).asFloat();
		bdInfo.startDelay = (value > 0.f) ? (value * FRAMES_PER_SEC) : 0;
		bdInfo.startFrame = bd[0].get((unsigned)1, 0).asInt() * FRAMES_PER_SEC;
		value = bd[1].get((unsigned)0, -1.f).asFloat();
		bdInfo.endDelay = (value > 0.f) ? (value * FRAMES_PER_SEC) : 0;
		bdInfo.endFrame = bd[1].get((unsigned)1, 0).asInt() * FRAMES_PER_SEC;
		bdInfo.fraction = (bdInfo.endFrame != bdInfo.startFrame)
				? float(bdInfo.endDelay - bdInfo.startDelay) / (bdInfo.endFrame - bdInfo.startFrame)
				: 0.f;
		buildDelay = bdInfo.startDelay;
	}

	const Json::Value& energy = econ["energy"];
	{
		const Json::Value& factor = energy["factor"];
		efInfo.startFactor = factor[0].get((unsigned)0, 0.5f).asFloat();
		efInfo.startFrame = factor[0].get((unsigned)1, 300 ).asInt() * FRAMES_PER_SEC;
		efInfo.endFactor = factor[1].get((unsigned)0, 2.0f).asFloat();
		efInfo.endFrame = factor[1].get((unsigned)1, 3600).asInt() * FRAMES_PER_SEC;
		efInfo.fraction = (efInfo.endFrame != efInfo.startFrame)
				? (efInfo.endFactor - efInfo.startFactor) / (efInfo.endFrame - efInfo.startFrame)
				: 0.f;
		energyFactor = efInfo.startFactor;
	}

	outMinEInc = energy.get("min_income", 5.f).asFloat();
	costRatio = energy.get("cost_ratio", 0.05f).asFloat();
	ecoEMRatio = energy.get("em_ratio", 0.08f).asFloat();
	clusterRange = econ.get("cluster_range", 950.f).asFloat();
	pylonLinkInc = energy.get("link_inc", 16.0f).asFloat();

	std::string type = circuit->GetTerrainManager()->IsWaterMap() ? "water" : "land";
	const Json::Value& surf = energy[type];
	for (const std::string& engy : surf.getMemberNames()) {
		CCircuitDef* cdef = circuit->GetCircuitDef(engy.c_str());
		if (cdef == nullptr) {
			circuit->LOG("CONFIG %s: has unknown UnitDef '%s'", cfgName.c_str(), engy.c_str());
			continue;
		}
		const Json::Value& surfEngy = surf[engy];
		const int min = surfEngy[0].asInt();
		const int max = surfEngy.get(1, min).asInt();
		SEnergyCond cond;
		cond.limit = min + rand() % (max - min + 1);
		cond.metalIncome = surfEngy.get(2, -1.f).asFloat();
		cond.energyIncome = surfEngy.get(3, -1.f).asFloat();
		cond.score = surfEngy.get(4, -1.f).asFloat();
		engyLimits[cdef] = cond;
	}

	CMaskHandler& sideMasker = circuit->GetGameAttribute()->GetSideMasker();
	sideInfos.resize(sideMasker.GetMasks().size());
	const Json::Value& mex = econ["mex"];
	const Json::Value& geo = econ["geo"];
	const Json::Value& deflt = econ["default"];
	for (const auto& kv : sideMasker.GetMasks()) {
		SSideInfo& sideInfo = sideInfos[kv.second.type];

		// Mex
		const char* name = mex[kv.first].asCString();
		CCircuitDef* cdef = circuit->GetCircuitDef(name);
		if (cdef != nullptr) {
			sideInfo.mexDef = cdef;
		} else {
			circuit->LOG("CONFIG %s: has unknown mexDef '%s'", cfgName.c_str(), name);
		}

		// Geo
		name = geo[kv.first].asCString();
		cdef = circuit->GetCircuitDef(name);
		if (cdef != nullptr) {
			sideInfo.geoDef = cdef;
		} else {
			circuit->LOG("CONFIG %s: has unknown geoDef '%s'", cfgName.c_str(), name);
		}

		// Default
		// NOTE: Must have
		sideInfo.defaultDef = circuit->GetCircuitDef(deflt[kv.first].asCString());
		if (sideInfo.defaultDef == nullptr) {
			throw CException("economy.default");
		}
	}
}

void CEconomyManager::InitEconomyScores()
{
	std::vector<CCircuitDef*> builders;
	for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
		if (cdef.IsBuilder()) {
			builders.push_back(&cdef);
		}
	}

	metalDefs.Init(builders, [this](CCircuitDef* cdef, SMetalExt& data) -> float {
//		data.speed = cdef->GetExtractsM();
//		return data.speed * 1e+6f - cdef->GetCostM();
		return 1.f / cdef->GetCostM();
	});
	convertDefs.Init(builders, [this](CCircuitDef* cdef, SConvertExt& data) -> float {
		// old engine way: cdef->GetDef()->GetMakesResource(metalRes)
		auto customParams = cdef->GetDef()->GetCustomParams();
		const float ratio = utils::string_to_float(customParams.find("energyconv_efficiency")->second);  // validated on init
		data.energyUse = utils::string_to_float(customParams.find("energyconv_capacity")->second);  // validated on init
		data.make = data.energyUse * ratio;
		data.isOld = false;
		return data.make;
	});

	energyDefs.Init(builders, [this](CCircuitDef* cdef, SEnergyExt& data) -> float {
		auto customParams = cdef->GetDef()->GetCustomParams();
		auto it = customParams.find("income_energy");
		data.make = (it != customParams.end())
				? utils::string_to_float(it->second)
				: cdef->GetDef()->GetResourceMake(energyRes) - cdef->GetUpkeepE() - cdef->GetCloakCost();
		if (data.make < 1) {
			data.make = cdef->GetDef()->GetWindResourceGenerator(energyRes);
			if (data.make < 1) {
				data.make = cdef->GetDef()->GetTidalResourceGenerator(energyRes) * circuit->GetMap()->GetTidalStrength();
			} else {
				float avgWind = (circuit->GetMap()->GetMaxWind() + circuit->GetMap()->GetMinWind()) * 0.5f;
				data.make = std::min(avgWind, data.make);
			}
		}

		auto lit = engyLimits.find(cdef);
		if (lit != engyLimits.end()) {
			data.cond = lit->second;
		}
		if (data.cond.score < .0f) {
			// TODO: Instead of plain sizeX, sizeZ use AI's yardmap size
			data.cond.score = SQUARE(data.make) / ((cdef->GetCostM()/* + cdef->GetCostE() * 0.05f*/) * cdef->GetDef()->GetXSize() * cdef->GetDef()->GetZSize());
		}
		if (data.cond.metalIncome < 0.f) {
			// TODO: Select proper scale/quadratic function (x*x) and smoothing coefficient (8).
			//       МЕТОД НАИМЕНЬШИХ КВАДРАТОВ ! (income|buildPower, make/cost) - points
			//       solar       geothermal    fusion         singu           ...
			//       (10, 2/70), (15, 25/500), (20, 35/1000), (30, 225/4000), ...
			data.cond.metalIncome = sqrtf(cdef->GetCostM() * 16.0f / MAX_BUILD_SEC);
		}
		if (data.cond.energyIncome < 0.f) {
			data.cond.energyIncome = cdef->GetCostE() * costRatio;
		}

		data.isOld = false;

		return data.cond.score;
	});
	geoDefs.Init(builders, [this](CCircuitDef* cdef, SGeoExt& data) -> float {
		data.make = cdef->GetDef()->GetResourceMake(energyRes) - cdef->GetUpkeepE() - cdef->GetCloakCost();
		return data.make / cdef->GetCostM();
	});

	auto scoreFunc = [](CCircuitDef* cdef, const SStoreExt& data) {
		return data.storage / cdef->GetCostM();
	};
	storeMDefs.Init(builders, [this, scoreFunc](CCircuitDef* cdef, SStoreExt& data) -> float {
		data.storage = cdef->GetDef()->GetStorage(metalRes);
		return scoreFunc(cdef, data);
	});
	storeEDefs.Init(builders, [this, scoreFunc](CCircuitDef* cdef, SStoreExt& data) -> float {
		data.storage = cdef->GetDef()->GetStorage(energyRes);
		return scoreFunc(cdef, data);
	});

	airpadDefs.Init(builders, [](CCircuitDef* cdef, SAirpadExt& data) -> float {
		return cdef->GetBuildSpeed() / cdef->GetCostM();
	});
	assistDefs.Init(builders, [](CCircuitDef* cdef, SAssistExt& data) -> float {
		return cdef->GetBuildSpeed() / cdef->GetCostM();
	});
	factoryDefs.Init(builders, [](CCircuitDef* cdef, SFactoryExt& data) -> float {
		// FIXME: Factory sorting is not used anywhere, hence placeholder:
		return cdef->GetBuildSpeed() / cdef->GetCostM();
	});
}

void CEconomyManager::Init()
{
	energyGrid = circuit->GetAllyTeam()->GetEnergyGrid().get();

	const size_t clSize = circuit->GetMetalManager()->GetClusters().size();
	clusterInfos.resize(clSize, {nullptr, -FRAMES_PER_SEC});
	const size_t spSize = circuit->GetMetalManager()->GetSpots().size();
	mexSpots.resize(spSize, {true, false});
	geoSpots.resize(circuit->GetEnergyManager()->GetSpots().size(), {true, false});

	const Json::Value& econ = circuit->GetSetupManager()->GetConfig()["economy"];
	const Json::Value& mexCap = econ["mex_max"];
	const float mm = mexCap.get((unsigned)0, 2.f).asFloat();
	mexMax = (mm < 1.f) ? decltype(mexMax)(mm * spSize) : std::numeric_limits<decltype(mexMax)>::max();
	isAllyMexMax = mexCap.get((unsigned)1, true).asBool();

	const Json::Value& pull = econ["ms_pull"];
	mspInfos.resize(pull.size());
	mspInfos.push_back(SPullMtoS {
		.pull = pull[0].get((unsigned)0, 1.0f).asFloat(),
		.mex = (int)(pull[0].get((unsigned)1, 0.0f).asFloat() * spSize),
		.fraction = 0.f
	});
	for (unsigned i = 1; i < pull.size(); ++i) {
		SPullMtoS mspInfoEnd;
		mspInfoEnd.pull = pull[i].get((unsigned)0, 0.25f).asFloat();
		mspInfoEnd.mex = pull[i].get((unsigned)1, 0.75f).asFloat() * spSize;
		mspInfoEnd.fraction = 0.f;
		mspInfos.push_back(mspInfoEnd);
		SPullMtoS& mspInfoBegin = mspInfos[i - 1];
		mspInfoBegin.fraction = (mspInfoEnd.mex != mspInfoBegin.mex)
				? (mspInfoEnd.pull - mspInfoBegin.pull) / (mspInfoEnd.mex - mspInfoBegin.mex)
				: 0.f;
	}
	std::sort(mspInfos.begin(), mspInfos.end());
	pullMtoS = mspInfos.front().pull;

	CSetupManager::StartFunc subinit = [this](const AIFloat3& pos) {
		metalProduced = GetMetalCur() * metalMod;

		CSetupManager* setupMgr = circuit->GetSetupManager();
		if (setupMgr->GetCommander() == nullptr) {
			for (const auto& kv : circuit->GetTeamUnits()) {
				if (kv.second->GetCircuitDef()->IsRoleComm()) {
					setupMgr->SetCommander(kv.second);
					break;
				}
			}
		}

		CScheduler* scheduler = circuit->GetScheduler().get();
		CAllyTeam* allyTeam = circuit->GetAllyTeam();
		if (circuit->IsCommMerge() && !circuit->IsSavegame()) {
			allyTeam->ResetStartOnce();  // for the case when game ignores AI start positions
			const int spotId = circuit->GetMetalManager()->FindNearestSpot(pos);
			const int clusterId = (spotId < 0) ? -1 : circuit->GetMetalManager()->GetCluster(spotId);
			int ownerId = allyTeam->GetClusterTeam(clusterId).teamId;
			if (ownerId < 0) {
				allyTeam->OccupyCluster(clusterId, circuit->GetTeamId());
			} else if (ownerId != circuit->GetTeamId()) {
				circuit->Resign(ownerId);
				return;
			}

			CCircuitUnit* commander = setupMgr->GetCommander();
			if (commander == nullptr) {
				commander = circuit->GetTeamUnits().begin()->second;
			}
			ownerId = allyTeam->GetAreaTeam(commander->GetArea()).teamId;
			if (ownerId < 0) {
				allyTeam->OccupyArea(commander->GetArea(), circuit->GetTeamId());
//			} else if (ownerId != circuit->GetTeamId()) {
//				circuit->Resign(ownerId);
//				return;
			}
		}

		scheduler->RunJobAfter(CScheduler::GameJob([this]() {
			ecoFactor = (circuit->GetAllyTeam()->GetAliveSize() - 1.0f) * ecoStep + 1.0f;
		}), FRAMES_PER_SEC * 10);

		const int interval = allyTeam->GetSize() * FRAMES_PER_SEC;
		startFactory = CScheduler::GameJob(&CEconomyManager::StartFactoryJob, this);
		scheduler->RunJobEvery(startFactory, 1, circuit->GetSkirmishAIId() + 0 + 5 * FRAMES_PER_SEC);
		scheduler->RunJobEvery(CScheduler::GameJob(&CEconomyManager::UpdateStorageTasks, this),
								interval, circuit->GetSkirmishAIId() + 1 + interval / 2 + 30 * FRAMES_PER_SEC);

		scheduler->RunJobEvery(CScheduler::GameJob(&CEconomyManager::UpdateEconomy, this),
								TEAM_SLOWUPDATE_RATE, circuit->GetSkirmishAIId());
	};

	circuit->GetSetupManager()->ExecOnFindStart(subinit);
}

int CEconomyManager::UnitCreated(CCircuitUnit* unit, CCircuitUnit* builder)
{
	auto search = createdHandler.find(unit->GetCircuitDef()->GetId());
	if (search != createdHandler.end()) {
		search->second(unit, builder);
	}

	return 0; //signaling: OK
}

int CEconomyManager::UnitFinished(CCircuitUnit* unit)
{
	auto search = finishedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != finishedHandler.end()) {
		search->second(unit);
	}

	return 0; //signaling: OK
}

int CEconomyManager::UnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	// NOTE: If more actions should be done then consider moving into damagedHandler
	if (unit->IsMorphing() && (unit->GetUnit()->GetHealth() < unit->GetUnit()->GetMaxHealth() * 0.5f)) {
		unit->StopUpgrade();  // StopMorph();
		AddMorphee(unit);
	}

	return 0; //signaling: OK
}

int CEconomyManager::UnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	auto search = destroyedHandler.find(unit->GetCircuitDef()->GetId());
	if (search != destroyedHandler.end()) {
		search->second(unit, attacker);
	}

	return 0; //signaling: OK
}

float CEconomyManager::GetMetalMake(CCircuitDef* cdef) const
{
	if (cdef->IsMex()) {
		return circuit->GetMetalManager()->GetSpotAvgIncome() * cdef->GetExtractsM();
	}
	const SConvertExt* convertExt = convertDefs.GetAvailInfo(cdef);
	return (convertExt == nullptr) ? 0.f : convertExt->make;
}

float CEconomyManager::GetEnergyMake(CCircuitDef* cdef) const
{
	if (cdef->GetDef()->IsNeedGeo()) {
		const SGeoExt* geoExt = geoDefs.GetAvailInfo(cdef);
		return (geoExt == nullptr) ? 0.f : geoExt->make;
	}
	const SEnergyExt* energyExt = energyDefs.GetAvailInfo(cdef);
	return (energyExt == nullptr) ? 0.f : energyExt->make;
}

float CEconomyManager::GetEnergyUse(CCircuitDef* cdef) const
{
	const SConvertExt* convertExt = (cdef == nullptr) ? nullptr : convertDefs.GetAvailInfo(cdef);
	return (convertExt == nullptr) ? 0.f : convertExt->energyUse;
}

static CMetalData::IndicesDists GetNearestSpotsWithin(
		const CMetalManager* metalMgr, const AIFloat3& center, float radius)
{
	CMetalData::IndicesDists spots;
	if ((metalMgr == nullptr) || (radius <= 0.f)) {
		return spots;
	}
	metalMgr->FindSpotsInRadius(center, radius, spots);
	std::sort(spots.begin(), spots.end(), [](const auto& lhs, const auto& rhs) {
		return lhs.second < rhs.second;
	});
	return spots;
}

void CEconomyManager::RefreshAllyTeamIds()
{
	allyTeamIds.clear();
	CAllyTeam* allyTeam = circuit->GetAllyTeam();
	if (allyTeam == nullptr) {
		return;
	}
	for (int tid : allyTeam->GetTeamIds()) {
		if (tid != circuit->GetTeamId()) {
			allyTeamIds.push_back(tid);
		}
	}
	std::sort(allyTeamIds.begin(), allyTeamIds.end());
}

bool CEconomyManager::UpdateTeamEconomy(int teamId)
{
	if (allyTeamIds.empty()) {
		RefreshAllyTeamIds();
	}
	if (std::find(allyTeamIds.begin(), allyTeamIds.end(), teamId) == allyTeamIds.end()) {
		return false;
	}
	springai::Game* game = circuit->GetGame();
	STeamEco& te = teamEco[teamId];
	te.teamId = teamId;
	te.frame = circuit->GetLastFrame();
	auto fill = [game, teamId](STeamRes& r, int resId) {
		using F = TeamEcoField;
		r.v[static_cast<int>(F::CURRENT)]  = game->GetTeamResourceCurrent(teamId, resId);
		r.v[static_cast<int>(F::STORAGE)]  = game->GetTeamResourceStorage(teamId, resId);
		r.v[static_cast<int>(F::INCOME)]   = game->GetTeamResourceIncome(teamId, resId);
		r.v[static_cast<int>(F::USAGE)]    = game->GetTeamResourceUsage(teamId, resId);
		r.v[static_cast<int>(F::PULL)]     = game->GetTeamResourcePull(teamId, resId);
		r.v[static_cast<int>(F::SHARE)]    = game->GetTeamResourceShare(teamId, resId);
		r.v[static_cast<int>(F::SENT)]     = game->GetTeamResourceSent(teamId, resId);
		r.v[static_cast<int>(F::RECEIVED)] = game->GetTeamResourceReceived(teamId, resId);
		r.v[static_cast<int>(F::EXCESS)]   = game->GetTeamResourceExcess(teamId, resId);
		r.v[static_cast<int>(F::FREE)]     = std::max(0.f, r.v[static_cast<int>(F::STORAGE)] - HIDDEN_STORAGE - r.v[static_cast<int>(F::CURRENT)]);
	};
	fill(te.metal, metalRes->GetResourceId());
	fill(te.energy, energyRes->GetResourceId());
	te.alive = te.metal.v[static_cast<int>(TeamEcoField::INCOME)] > 0.f;
	return true;
}

int CEconomyManager::UpdateAllTeamEconomy()
{
	RefreshAllyTeamIds();
	int n = 0;
	for (int tid : allyTeamIds) {
		if (UpdateTeamEconomy(tid)) {
			++n;
		}
	}
	return n;
}

int CEconomyManager::GetAllyTeamCount()
{
	if (allyTeamIds.empty()) {
		RefreshAllyTeamIds();
	}
	return int(allyTeamIds.size());
}

int CEconomyManager::GetAllyTeamIdAt(int index)
{
	if (allyTeamIds.empty()) {
		RefreshAllyTeamIds();
	}
	return ((index >= 0) && (index < int(allyTeamIds.size()))) ? allyTeamIds[index] : -1;
}

float CEconomyManager::GetTeamEco(int teamId, int resource, int field) const
{
	auto it = teamEco.find(teamId);
	if ((it == teamEco.end()) || (field < 0) || (field >= static_cast<int>(TeamEcoField::_SIZE_))) {
		return -1.f;
	}
	return (resource == 0) ? it->second.metal.v[field] : it->second.energy.v[field];
}

int CEconomyManager::GetTeamEcoFrame(int teamId) const
{
	auto it = teamEco.find(teamId);
	return (it == teamEco.end()) ? -1 : it->second.frame;
}

bool CEconomyManager::IsTeamAlive(int teamId) const
{
	auto it = teamEco.find(teamId);
	return (it != teamEco.end()) && it->second.alive;
}

bool CEconomyManager::SendResourceTo(int resource, float amount, int teamId)
{
	if ((amount <= 0.f) || (teamId == circuit->GetTeamId())) {
		return false;
	}
	springai::Resource* res = (resource == 0) ? metalRes : energyRes;
	// D-106: the engine's handler answers a resource send with -2 (metal) or -3
	// (energy) and the C bridge turns any non-zero answer into false, although
	// the share message has already gone out (CAICallback::SendResources); the
	// answer is not a result. The send is checked by our SENT field later.
	economy->SendResource(res, amount, teamId);
	circuit->LOG("ECONOMY: sent %.0f %s to team %i", amount, (resource == 0) ? "metal" : "energy", teamId);
	return true;
}

float CEconomyManager::GetOwnEco(int resource, int field)
{
	springai::Resource* res = (resource == 0) ? metalRes : energyRes;
	using F = TeamEcoField;
	switch (static_cast<F>(field)) {
		case F::CURRENT:  return economy->GetCurrent(res);
		case F::STORAGE:  return economy->GetStorage(res);
		case F::INCOME:   return economy->GetIncome(res);
		case F::USAGE:    return economy->GetUsage(res);
		case F::PULL:     return economy->GetPull(res);
		case F::SHARE:    return economy->GetShare(res);
		case F::SENT:     return economy->GetSent(res);
		case F::RECEIVED: return economy->GetReceived(res);
		case F::EXCESS:   return economy->GetExcess(res);
		case F::FREE:     return std::max(0.f, economy->GetStorage(res) - HIDDEN_STORAGE - economy->GetCurrent(res));
		default:          return -1.f;
	}
}

AIFloat3 CEconomyManager::GetMexCentroidWithin(const AIFloat3& center, float radius, int maxSpots) const
{
	if (maxSpots <= 0) {
		maxSpots = std::numeric_limits<int>::max();
	}
	const CMetalData::IndicesDists spots = GetNearestSpotsWithin(circuit->GetMetalManager(), center, radius);
	AIFloat3 sum = ZeroVector;
	int count = 0;
	for (const auto& spot : spots) {
		sum += circuit->GetMetalManager()->GetSpots()[spot.first].position;
		if (++count >= maxSpots) {
			break;
		}
	}
	if (count == 0) {
		return center;
	}
	sum /= float(count);
	sum.y = center.y;
	return sum;
}

int CEconomyManager::GetMexSpotCountWithin(
		CCircuitUnit* builder, const AIFloat3& center, float radius, int maxSpots)
{
	if ((builder == nullptr) || (builder->GetCircuitDef() == nullptr)) {
		return 0;
	}
	if (maxSpots <= 0) {
		maxSpots = std::numeric_limits<int>::max();  // every spot inside the radius (D-063)
	}
	const CMetalData::IndicesDists spots = GetNearestSpotsWithin(
			circuit->GetMetalManager(), center, radius);
	int count = 0;
	for (const auto& spot : spots) {
		if (circuit->GetTerrainManager()->CanReachAtSafe(
				builder, circuit->GetMetalManager()->GetSpots()[spot.first].position,
				builder->GetCircuitDef()->GetBuildDistance())) {
			if (++count >= maxSpots) {
				break;
			}
		}
	}
	return count;
}

int CEconomyManager::GetClaimedMexCountWithin(
		CCircuitUnit* builder, const AIFloat3& center, float radius, int maxSpots)
{
	if ((builder == nullptr) || (builder->GetCircuitDef() == nullptr)) {
		return 0;
	}
	if (maxSpots <= 0) {
		maxSpots = std::numeric_limits<int>::max();
	}
	CMetalManager* metalMgr = circuit->GetMetalManager();
	const CMetalData::IndicesDists spots = GetNearestSpotsWithin(metalMgr, center, radius);
	int count = 0;
	int considered = 0;
	for (const auto& spot : spots) {
		if (!circuit->GetTerrainManager()->CanReachAtSafe(
				builder, metalMgr->GetSpots()[spot.first].position,
				builder->GetCircuitDef()->GetBuildDistance())) {
			continue;
		}
		if (++considered > maxSpots) {
			break;
		}
		if (!metalMgr->IsOpenSpot(spot.first) || !IsOpenMexSpot(spot.first)) {
			++count;
		}
	}
	return count;
}

bool CEconomyManager::IsOwnSpot(const springai::AIFloat3& pos)
{
	// D-322 ownership by walking distance holds for the opening window only;
	// once it ends the D-072 Voronoi split below is the rule again (D-327).
	if (mexNavigationEnabled && IsMexOwnershipActive()) {
		auto* terrain = circuit->GetTerrainManager();
		if (!std::isfinite(pos.x) || !std::isfinite(pos.z) || pos.x < 0 || pos.z < 0
				|| pos.x >= terrain->GetTerrainWidth() || pos.z >= terrain->GetTerrainHeight()) return false;
		const int ownTeam = circuit->GetTeamId();
		if (mexStarts.find(ownTeam) == mexStarts.end()) {
			SMexStart own;
			own.pos = circuit->GetSetupManager()->GetStartPos();
			const auto* def = circuit->GetSetupManager()->GetCommChoice();
			if (def) own.definition = def->GetId();
			mexStarts.emplace(ownTeam, std::move(own));
			mexOwnersDirty = true;
		}
		const auto revision = terrain->GetAreaData()->heightRevision;
		const auto& spots = circuit->GetMetalManager()->GetSpots();
		if (mexOwnersDirty || mexOwnerRevision != revision || mexOwners.size() != spots.size()) {
			mexOwners.assign(spots.size(), -2); // -2 unknown, -1 no ground owner (air may claim)
			mexOwnerRevision = revision;
			mexOwnersDirty = false;
		}
		const int index = metalMap ? -1 : circuit->GetMetalManager()->FindNearestSpot(pos);
		const bool indexed = index >= 0 && std::size_t(index) < spots.size() && spots[index].position.SqDistance2D(pos) < 1.f;
		if (indexed && mexOwners[index] != -2) return mexOwners[index] < 0 || mexOwners[index] == ownTeam;
		int owner = -1;
		float best = mex_navigation::Unreachable;
		for (auto& [team, start] : mexStarts) {
			const float distance = MexStartDistance(start, pos);
			if (mex_navigation::Better(distance, team, best, owner)) { best = distance; owner = team; }
		}
		if (indexed) mexOwners[index] = owner;
		return owner < 0 || owner == ownTeam;
	}
	// D-072: the spot is ours when no ally's start position is nearer to it
	// than our own (a Voronoi split of the map by start positions).
	const float own = circuit->GetSetupManager()->GetStartPos().SqDistance2D(pos);
	for (const springai::AIFloat3& s : allyStarts) {
		if (s.SqDistance2D(pos) < own) {
			return false;
		}
	}
	return true;
}

IBuilderTask* CEconomyManager::EnqueueMexWithin(
		CCircuitUnit* builder, const AIFloat3& center, float radius, int maxSpots, bool allyAware,
        const std::vector<AIFloat3>& excluded)
{
    // The caller owns a bounded, expiring policy list. Empty is the exact old
    // path; rejected candidates never consume or release another task's claim.
    const auto excludedSpot = [&excluded](const AIFloat3& p) {
        return std::any_of(excluded.begin(), excluded.end(), [&p](const AIFloat3& q) {
            return p.SqDistance2D(q) < SQUARE(64.f);
        });
    };
	if (metalMap) return (maxSpots > 0 && GetFieldMexCount(center, radius) >= maxSpots)
		? nullptr : EnqueueFieldMex(builder, center, radius);
	if ((builder == nullptr) || (builder->GetCircuitDef() == nullptr)) {
		return nullptr;
	}
	if (maxSpots <= 0) {
		maxSpots = std::numeric_limits<int>::max();  // every spot inside the radius (D-063)
	}
	CMetalManager* metalMgr = circuit->GetMetalManager();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();
	const AIFloat3 from = builder->GetPos(frame);
	// Idempotent: a mex task already queued for a spot in the radius and not
	// yet taken is handed back before a new spot is closed. Native re-asks a
	// busy builder every few seconds; without this every ask closed another
	// spot with a task nobody would run (D-063 follow-up).
	{
		IBuilderTask* best = nullptr;
		float bestSq = std::numeric_limits<float>::max();
		const float radiusSq = SQUARE(radius);
		for (IBuilderTask* task : circuit->GetBuilderManager()->GetTasks(IBuilderTask::BuildType::MEX)) {
			// A half-built mex whose builder was taken off it counts too: it is
			// finished before a new spot is opened.
			if ((task == nullptr) || task->IsDead() || !task->GetAssignees().empty()
					|| (task->GetBuildDef() == nullptr) || !builder->GetCircuitDef()->CanBuild(task->GetBuildDef())) {
				continue;
			}
			const AIFloat3& pos = task->GetPosition();
			if ((pos.SqDistance2D(center) > radiusSq) || excludedSpot(pos)
					|| !CanReachMex(builder, pos)
					|| (mexNavigationEnabled && task->GetTarget() == nullptr && !IsOwnSpot(pos))) {
				continue;
			}
			const float sq = from.SqDistance2D(pos);
			if (sq < bestSq) {
				bestSq = sq;
				best = task;
			}
		}
		if (best != nullptr) {
			return best;
		}
	}
	CMetalData::IndicesDists spots = GetNearestSpotsWithin(metalMgr, center, radius);
	// The cap keeps the maxSpots *open, reachable* spots nearest the centre
	// (a taken third spot no longer ends a three-mex opening at two); the
	// order of work among them is nearest the builder first, so the opening
	// walks a chain and not a star (D-063).
	CMetalData::IndicesDists open;
	for (const auto& spot : spots) {
		if (int(open.size()) >= maxSpots) {
			break;
		}
		const AIFloat3& pos = metalMgr->GetSpots()[spot.first].position;
		if (excludedSpot(pos) || !metalMgr->IsOpenSpot(spot.first) || !IsOpenMexSpot(spot.first)
				|| !CanReachMex(builder, pos)
				|| !IsMexExpansionAllowed(pos, allyAware)) {
			continue;
		}
		open.emplace_back(spot.first, from.SqDistance2D(pos));
	}
	std::sort(open.begin(), open.end(), [](const auto& lhs, const auto& rhs) {
		return lhs.second < rhs.second;
	});
	const std::vector<CCircuitDef*>& mexDefs = metalDefs.GetBuildDefs(builder->GetCircuitDef());
	for (const auto& spot : open) {
		const AIFloat3& pos = metalMgr->GetSpots()[spot.first].position;
		for (CCircuitDef* mexDef : mexDefs) {
			if ((mexDef == nullptr) || !mexDef->IsAvailable(frame) || !terrainMgr->CanBeBuiltAt(mexDef, pos)) {
				continue;
			}
			IBuilderTask* task = circuit->GetBuilderManager()->Enqueue(TaskB::Spot(
					IBuilderTask::BuildType::MEX, IBuilderTask::Priority::NOW, mexDef, pos, spot.first));
			if ((task != nullptr) && (task->GetBuildType() == IBuilderTask::BuildType::MEX)) {
				static_cast<CBMexTask*>(task)->SetIgnoreAlly(!allyAware);
				// Task-added callbacks are a mutation boundary. Audit territorial
				// admission once per new order; this is a warm cached spot query.
				if (IsMexOwnershipActive() && !IsOwnSpot(pos))
					circuit->LOG("[INVARIANT] INV-227 mex admitted outside protected ownership team=%i x=%.0f z=%.0f",
						circuit->GetTeamId(), pos.x, pos.z);
			}
			return task;
		}
	}
	return nullptr;
}

int CEconomyManager::GetMexTaskCountWithin(const AIFloat3& center, float radius) const
{
	const float radiusSq = SQUARE(radius);
	int count = 0;
	for (const IBuilderTask* task : circuit->GetBuilderManager()->GetTasks(IBuilderTask::BuildType::MEX)) {
		if ((task != nullptr) && !task->IsDead() && (task->GetPosition().SqDistance2D(center) <= radiusSq)) {
			++count;
		}
	}
	return count;
}

CCircuitDef* CEconomyManager::GetLowEnergy(const AIFloat3& pos, float& outMake, const CCircuitUnit* builder) const
{
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();
	return energyDefs.GetWorstDef([frame, builder, terrainMgr, &pos, &outMake](CCircuitDef* cdef, const SEnergyExt& data) {
		if (!data.isOld && cdef->IsAvailable(frame)
			&& ((builder == nullptr) || builder->GetCircuitDef()->CanBuild(cdef))
			&& terrainMgr->CanBeBuiltAtSafe(cdef, pos))
		{
			outMake = data.make;
			return true;
		}
		return false;
	});
}

void CEconomyManager::AddEconomyDefs(const std::set<CCircuitDef*>& buildDefs)
{
	metalDefs.AddDefs(buildDefs);
	convertDefs.AddDefs(buildDefs);
	energyDefs.AddDefs(buildDefs);
	geoDefs.AddDefs(buildDefs);
	storeMDefs.AddDefs(buildDefs);
	storeEDefs.AddDefs(buildDefs);
	airpadDefs.AddDefs(buildDefs);
	assistDefs.AddDefs(buildDefs);
	factoryDefs.AddDefs(buildDefs);

	// DEBUG
//	circuit->LOG("----Metal----");
//	for (const auto& mi : metalDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | speed=%f | efficiency=%f", mi.cdef->GetDef()->GetName(),
//				mi.cdef->GetCostM(), mi.cdef->GetCostE(), mi.data.speed, mi.score);
//	}
//	circuit->LOG("----Converter----");
//	for (const auto& ci : convertDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | make=%f | efficiency=%f", ci.cdef->GetDef()->GetName(),
//				ci.cdef->GetCostM(), ci.cdef->GetCostE(), ci.data.make, ci.score);
//	}
//	circuit->LOG("----Energy----");
//	for (const auto& ei : energyDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | make=%f | efficiency=%f | limit=%i | m-income=%f | e-income=%f", ei.cdef->GetDef()->GetName(),
//				ei.cdef->GetCostM(), ei.cdef->GetCostE(), ei.data.make, ei.data.cond.score, ei.data.cond.limit, ei.data.cond.metalIncome, ei.data.cond.energyIncome);
//	}
//	circuit->LOG("----Geo----");
//	for (const auto& ci : geoDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | make=%f | efficiency=%f", ci.cdef->GetDef()->GetName(),
//				ci.cdef->GetCostM(), ci.cdef->GetCostE(), ci.data.make, ci.score);
//	}
//	std::vector<std::pair<std::string, CAvailList<SStoreExt>*>> vec = {{"Metal", &storeMDefs}, {"Energy", &storeEDefs}};
//	for (const auto& kv : vec) {
//		circuit->LOG("----%s Storage----", kv.first.c_str());
//		for (const auto& si : kv.second->GetInfos()) {
//			circuit->LOG("%s | costM=%f | costE=%f | storage=%f", si.cdef->GetDef()->GetName(),
//					si.cdef->GetCostM(), si.cdef->GetCostE(), si.data.storage);
//		}
//	}
//	circuit->LOG("----Airpad----");
//	for (const auto& pi : airpadDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | build_speed=%f | efficiency=%f", pi.cdef->GetDef()->GetName(),
//				pi.cdef->GetCostM(), pi.cdef->GetCostE(), pi.cdef->GetBuildSpeed(), pi.score);
//	}
//	circuit->LOG("----Assist----");
//	for (const auto& ni : assistDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | build_speed=%f | efficiency=%f", ni.cdef->GetDef()->GetName(),
//				ni.cdef->GetCostM(), ni.cdef->GetCostE(), ni.cdef->GetBuildSpeed(), ni.score);
//	}
//	circuit->LOG("----Factory----");
//	for (const auto& fi : factoryDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | build_speed=%f | efficiency=%f", fi.cdef->GetDef()->GetName(),
//				fi.cdef->GetCostM(), fi.cdef->GetCostE(), fi.cdef->GetBuildSpeed(), fi.score);
//	}
}

void CEconomyManager::RemoveEconomyDefs(const std::set<CCircuitDef*>& buildDefs)
{
	metalDefs.RemoveDefs(buildDefs);
	convertDefs.RemoveDefs(buildDefs);
	energyDefs.RemoveDefs(buildDefs);
	geoDefs.RemoveDefs(buildDefs);
	storeMDefs.RemoveDefs(buildDefs);
	storeEDefs.RemoveDefs(buildDefs);
	airpadDefs.RemoveDefs(buildDefs);
	assistDefs.RemoveDefs(buildDefs);
	factoryDefs.RemoveDefs(buildDefs);

	// DEBUG
//	circuit->LOG("----Remove Metal----");
//	for (const auto& mi : metalDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | speed=%f | efficiency=%f", mi.cdef->GetDef()->GetName(),
//				mi.cdef->GetCostM(), mi.cdef->GetCostE(), mi.data.speed, mi.score);
//	}
//	circuit->LOG("----Remove Converter----");
//	for (const auto& ci : convertDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | make=%f | efficiency=%f", ci.cdef->GetDef()->GetName(),
//				ci.cdef->GetCostM(), ci.cdef->GetCostE(), ci.data.make, ci.score);
//	}
//	circuit->LOG("----Remove Energy----");
//	for (const auto& ei : energyDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | make=%f | efficiency=%f | limit=%i", ei.cdef->GetDef()->GetName(),
//				ei.cdef->GetCostM(), ei.cdef->GetCostE(), ei.data.make, ei.data.cond.score, ei.data.cond.limit);
//	}
//	circuit->LOG("----Remove Geo----");
//	for (const auto& ci : geoDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | make=%f | efficiency=%f", ci.cdef->GetDef()->GetName(),
//				ci.cdef->GetCostM(), ci.cdef->GetCostE(), ci.data.make, ci.score);
//	}
//	std::vector<std::pair<std::string, CAvailList<SStoreExt>*>> vec = {{"Metal", &storeMDefs}, {"Energy", &storeEDefs}};
//	for (const auto& kv : vec) {
//		circuit->LOG("----Remove %s Storage----", kv.first.c_str());
//		for (const auto& si : kv.second->GetInfos()) {
//			circuit->LOG("%s | costM=%f | costE=%f | storage=%f", si.cdef->GetDef()->GetName(),
//					si.cdef->GetCostM(), si.cdef->GetCostE(), si.data.storage);
//		}
//	}
//	circuit->LOG("----Remove Airpad----");
//	for (const auto& pi : airpadDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | build_speed=%f | efficiency=%f", pi.cdef->GetDef()->GetName(),
//				pi.cdef->GetCostM(), pi.cdef->GetCostE(), pi.cdef->GetBuildSpeed(), pi.score);
//	}
//	circuit->LOG("----Remove Assist----");
//	for (const auto& ni : assistDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | build_speed=%f | efficiency=%f", ni.cdef->GetDef()->GetName(),
//				ni.cdef->GetCostM(), ni.cdef->GetCostE(), ni.cdef->GetBuildSpeed(), ni.score);
//	}
//	circuit->LOG("----Remove Factory----");
//	for (const auto& fi : factoryDefs.GetInfos()) {
//		circuit->LOG("%s | costM=%f | costE=%f | build_speed=%f | efficiency=%f", fi.cdef->GetDef()->GetName(),
//				fi.cdef->GetCostM(), fi.cdef->GetCostE(), fi.cdef->GetBuildSpeed(), fi.score);
//	}
}

const CEconomyManager::SSideInfo& CEconomyManager::GetSideInfo() const
{
	return sideInfos[circuit->GetSideId()];
}

float CEconomyManager::GetMetalCur()
{
	return metal.current = economy->GetCurrent(metalRes);
}

float CEconomyManager::GetMetalStore()
{
	return metal.storage = GetStorage(metalRes);
}

float CEconomyManager::GetMetalPull()
{
	if (metal.pullFrame/* + TEAM_SLOWUPDATE_RATE*/ < circuit->GetLastFrame()) {
		metal.pullFrame = circuit->GetLastFrame();
		metal.pull = economy->GetPull(metalRes) + circuit->GetTeam()->GetRulesParamFloat("extraMetalPull", 0.f);
		if (metalPullCorFrame + TEAM_SLOWUPDATE_RATE < circuit->GetLastFrame()) {
			metalPullCorFrame = -1;
			metalPullCor = 0.f;
		}
	}
	return metal.pull;
}

float CEconomyManager::GetEnergyCur()
{
	return energy.current = economy->GetCurrent(energyRes);
}

float CEconomyManager::GetEnergyStore()
{
	return energy.storage = GetStorage(energyRes);
}

float CEconomyManager::GetEnergyPull()
{
	if (energy.pullFrame/* + TEAM_SLOWUPDATE_RATE*/ < circuit->GetLastFrame()) {
		energy.pullFrame = circuit->GetLastFrame();
		float extraEnergyPull = circuit->GetTeam()->GetRulesParamFloat("extraEnergyPull", 0.f);
//		float oddEnergyOverdrive = circuit->GetTeam()->GetRulesParamFloat("OD_energyOverdrive", 0.f);
//		float oddEnergyChange = circuit->GetTeam()->GetRulesParamFloat("OD_energyChange", 0.f);
//		float extraChange = std::min(.0f, oddEnergyChange) - std::min(.0f, oddEnergyOverdrive);
//		float teamEnergyWaste = circuit->GetTeam()->GetRulesParamFloat("OD_team_energyWaste", 0.f);
//		float numAllies = circuit->GetTeam()->GetRulesParamFloat("OD_allies", 1.f);
//		if (numAllies < 1.f) {
//			numAllies = 1.f;
//		}
		energy.pull = economy->GetPull(energyRes) + extraEnergyPull/* + extraChange - teamEnergyWaste / numAllies*/;
		if (energyPullCorFrame + TEAM_SLOWUPDATE_RATE < circuit->GetLastFrame()) {
			energyPullCorFrame = -1;
			energyPullCor = 0.f;
		}
	}
	return energy.pull;
}

bool CEconomyManager::IsAllyOpenMexSpot(int spotId) const
{
	return IsOpenMexSpot(spotId) && circuit->GetMetalManager()->IsOpenSpot(spotId);
}

bool CEconomyManager::IsOpenMexSpot(int spotId) const
{
	if (spotId < 0 || std::size_t(spotId) >= mexSpots.size()) return false;
	return mexSpots[spotId].isOpen && ((isAllyMexMax ? circuit->GetMetalManager()->GetMexCount() : mexCount) < mexMax);
}

void CEconomyManager::SetOpenMexSpot(int spotId, bool value)
{
	if (spotId < 0 || std::size_t(spotId) >= mexSpots.size()) return;
	if (mexSpots[spotId].isOpen == value) {
		return;
	}
	mexSpots[spotId].isOpen = value;
	value ? --mexCount : ++mexCount;
}

bool CEconomyManager::IsIgnorePull(const IBuilderTask* task) const
{
	if (mexMax != std::numeric_limits<decltype(mexMax)>::max()) {
		return false;
	}
	return ((task->GetBuildType() == IBuilderTask::BuildType::MEX) ||
			(task->GetBuildType() == IBuilderTask::BuildType::PYLON));
}

bool CEconomyManager::IsIgnoreStallingPull(const IBuilderTask* task) const
{
//	if (mexMax != std::numeric_limits<decltype(mexMax)>::max()) {
//		return false;  // NOTE: may completely block expansion
//	}
	if ((task->GetBuildType() == IBuilderTask::BuildType::MEX) ||
		(task->GetBuildType() == IBuilderTask::BuildType::PYLON))
	{
		return true;
	}
	return ((task->GetBuildType() == IBuilderTask::BuildType::ENERGY) &&
			circuit->GetEconomyManager()->IsEnergyStalling());
}

void CEconomyManager::CorrectResourcePull(float metal, float energy)
{
	metalPullCor += metal;
	if (metalPullCorFrame == -1) {
		metalPullCorFrame = circuit->GetLastFrame();
	}
	energyPullCor += energy;
	if (energyPullCorFrame == -1) {
		energyPullCorFrame = circuit->GetLastFrame();
	}
}

bool CEconomyManager::IsEnoughEnergy(IBuilderTask const* task, CCircuitDef const* conDef, float mod) const
{
	// FIXME: energy.pull should ignore builders on Wait, as
	//        actual energy.pull is larger than reported by engine.
	// NOTE: Doesn't count time to travel and high priority.
	//       invAvailFraction is for equal distribution.
	if (task->GetBuildType() == IBuilderTask::BuildType::ENERGY) {
		return true;
	}
	CCircuitDef const* buildDef = task->GetBuildDef();
	const float buildTime = buildDef->GetBuildTime() / conDef->GetWorkerTime();
	const float deficit = metal.current - ((GetMetalPullCor() - GetAvgMetalIncome()) * buildTime + buildDef->GetCostM());
	if (deficit >= 0.f) {
		return energy.current > (GetEnergyPullCor() - GetAvgEnergyIncome()) * buildTime + buildDef->GetCostE() * mod;
	}
	const float miRequire = buildDef->GetCostM() / buildTime;
	const float timeToDeficit = metal.current / (GetMetalPullCor() + miRequire - GetAvgMetalIncome());
	const float deficitTime = buildTime - timeToDeficit;
	const float invAvailFraction = (GetMetalPullCor() + miRequire) / GetAvgMetalIncome();
	const float eiRequire = buildDef->GetCostE() / buildTime * mod;
	return energy.current > (GetEnergyPullCor() + eiRequire - GetAvgEnergyIncome()) * timeToDeficit
			+ (GetEnergyPullCor() + eiRequire - GetAvgEnergyIncome() * invAvailFraction) * deficitTime;
}

bool CEconomyManager::IsEnoughEnergyIncome(CCircuitDef const* buildDef, CCircuitDef const* conDef) const
{
	const float buildTime = buildDef->GetBuildTime() / conDef->GetWorkerTime();
	const float eiRequire = buildDef->GetCostE() / std::max<float>(buildTime, EARLY_BUILD_SEC);
	return GetAvgEnergyIncome() > eiRequire;
}

IBuilderTask* CEconomyManager::MakeEconomyTasks(const AIFloat3& position, CCircuitUnit* unit)
{
	ZoneScoped;
	if (circuit->GetBuilderManager()->IsExperimentalBuild()) {
		return nullptr;  // D-093: TECH's layout places its economy; native's own energy and
		                 // mex orders sprawled outside it (played: turbines 400 elmos out)
	}

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (!builderMgr->CanEnqueueTask()) {
		return nullptr;
	}
	CMetalManager* metalMgr = circuit->GetMetalManager();
	int index = metalMgr->FindNearestCluster(position);
	if (index >= 0) {
		if (clusterInfos[index].metalFrame + FRAMES_PER_SEC >= circuit->GetLastFrame()) {
			return nullptr;
		}
		clusterInfos[index].metalFrame = circuit->GetLastFrame();
	}

	IBuilderTask* task = UpdateMetalTasks(position, unit);
	if (task != nullptr) {
		return task;
	}

	return task;
}

IBuilderTask* CEconomyManager::UpdateMetalTasks(const AIFloat3& position, CCircuitUnit* unit)
{
	assert(unit != nullptr);
	ZoneScoped;
	if (metalMap) {
		const float ratio = fieldLegacyEnergyRatio;
		if (IsEnergyStalling() || GetAvgEnergyIncome() < std::max(100.f, GetAvgMetalIncome() * ratio)) {
			IBuilderTask* energyTask = UpdateEnergyTasks(position, unit);
			if (energyTask != nullptr) return energyTask;
		}
		if (IsMetalFull()) return nullptr;
		const auto& home = circuit->GetSetupManager()->GetStartPos();
		const float radius = fieldHomeRadius;
		IBuilderTask* mex = EnqueueFieldMex(unit, home, radius);
		if (mex != nullptr) return mex;
		return IsMetalEmpty() ? EnqueueFieldUpgrade(unit, home, radius) : nullptr;
	}

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (!builderMgr->CanEnqueueTask(16)) {
		return nullptr;
	}

	if (IsEnergyStalling()) {
		return UpdateEnergyTasks(position, unit);
	}

	IBuilderTask* task = nullptr;
	const int frame = circuit->GetLastFrame();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();

	if ((builderMgr->GetTasks(IBuilderTask::BuildType::MEXUP).size() < numMexUp) && (GetAvgMetalIncome() > 10.f)) {
		const std::vector<CCircuitDef*>& mexDefOptions = metalDefs.GetBuildDefs(unit->GetCircuitDef());
		std::vector<std::pair<CCircuitDef*, float>> mexDefs;
		float maxRange = 0.f;
		for (auto it = mexDefOptions.begin(); it != mexDefOptions.end(); ++it) {
			CCircuitDef* mDef = *it;
			if (mDef->IsAvailable(frame)) {
				mexDefs.push_back(std::make_pair(mDef, mDef->GetExtractsM()));
				const float range = mDef->GetExtrRangeM();
				if (maxRange < range) {
					maxRange = range;
				}
			}
		}
		if (!mexDefs.empty()) {
			CMetalManager* metalMgr = circuit->GetMetalManager();
			const CMetalData::Metals& spots = metalMgr->GetSpots();
			CCircuitDef* mexDef = nullptr;
			CMetalData::PointPredicate predicate = [this, &spots, &mexDefs, maxRange, terrainMgr, unit, &mexDef](int index) {
				const AIFloat3& pos = spots[index].position;
				if (true/*!IsOpenMexSpot(index)*/
					&& !IsUpgradingMexSpot(index)
					&& CanReachMex(unit, pos))  // hostile environment
				{
					const auto& unitIds = circuit->GetCallback()->GetFriendlyUnitIdsIn(pos, maxRange, false);
					float curExtract = -1.f;
					for (ICoreUnit::Id unitId : unitIds) {
						CAllyUnit* curMex = circuit->GetFriendlyUnit(unitId);  // CCircuitUnit* curMex = circuit->GetTeamUnit(unitId);
						if (curMex == nullptr) {
							continue;
						}
						const float extract = curMex->GetCircuitDef()->GetExtractsM();
						if (curExtract < extract) {
							curExtract = extract;
						}
					}
					if (curExtract <= 0.f) {
						return false;
					}
					for (const auto& pair : mexDefs) {
						if ((curExtract < pair.second) && terrainMgr->CanBeBuiltAt(pair.first, pos)) {
							mexDef = pair.first;
							return true;
						}
					}
				}
				return false;
			};
//			const AIFloat3& searchPos = circuit->GetSetupManager()->GetBasePos();
			int index = metalMgr->GetSpotToUpgrade(/*searchPos*/position, predicate);
			builderMgr->SetCanUpMex(unit->GetCircuitDef(), index != -1);
			if (index != -1) {
				const AIFloat3& pos = spots[index].position;
				task = builderMgr->Enqueue(TaskB::Spot(IBuilderTask::BuildType::MEXUP,
						IBuilderTask::Priority::HIGH, mexDef, pos, index));
				return task;
			}
		}
	}

	CMetalManager* metalMgr = circuit->GetMetalManager();
	CCircuitDef* mexDef = nullptr;
	const unsigned int mexTaskSize = builderMgr->GetTasks(IBuilderTask::BuildType::MEX).size();
	if (mexTaskSize < (unsigned)mexMax/*builderMgr->GetWorkerCount() * 2 + 1*/
		&& ((GetAvgMetalIncome() < 100.f) || !IsMetalFull())
		&& !builderMgr->CanUpMex(unit->GetCircuitDef()))
	{
		const std::vector<CCircuitDef*>& mexDefOptions = metalDefs.GetBuildDefs(unit->GetCircuitDef());
		std::vector<CCircuitDef*> mexDefs;
		for (CCircuitDef* mDef : mexDefOptions) {
			if (mDef->IsAvailable(frame)) {
				mexDefs.push_back(mDef);
			}
		}
		if (!mexDefs.empty()) {
			const CMetalData::Metals& spots = metalMgr->GetSpots();
			CMap* map = circuit->GetMap();
			// NOTE: threatmap type is set outside
			CMetalData::PointPredicate predicate = [this, &spots, map, &mexDefs, terrainMgr, unit, &mexDef](int index) {
				const AIFloat3& pos = spots[index].position;
				// D-327: the walking-distance ownership replaces the ally-zone veto only
				// while its opening window runs; afterwards the zone veto and the Voronoi split hold
				if (IsAllyOpenMexSpot(index)
					&& (IsMexOwnershipActive() ? IsOwnSpot(pos) : (!terrainMgr->IsZoneAlly(pos) && (!mexNavigationEnabled || IsOwnSpot(pos))))
					&& CanReachMex(unit, pos))  // hostile environment
				{
					for (CCircuitDef* mDef : mexDefs) {
						if (terrainMgr->CanBeBuiltAt(mDef, pos)
							&& map->IsPossibleToBuildAt(mDef->GetDef(), pos, UNIT_NO_FACING))
						{
							mexDef = mDef;
							return true;
						}
					}
				}
				return false;
			};
			int index = metalMgr->GetSpotToBuild(position, predicate);
			if (index != -1) {
				const AIFloat3& pos = spots[index].position;
				task = builderMgr->Enqueue(TaskB::Spot(IBuilderTask::BuildType::MEX,
						IBuilderTask::Priority::HIGH, mexDef, pos, index));
				return task;
			}
		}
	}

	if (convertDefs.HasAvail() && IsEnergyFull() && !IsMetalFull()
		&& (builderMgr->GetTasks(IBuilderTask::BuildType::CONVERT).size() < 2)
		&& ((mexTaskSize == 0) || (builderMgr->GetWorkerCount() > circuit->GetMilitaryManager()->GetGuardTaskNum() + 1)))
	{
		const AIFloat3& pos = circuit->GetSetupManager()->GetMetalBase();
		CCircuitDef* convertDef = convertDefs.GetBestDef([frame, terrainMgr, &pos](CCircuitDef* cdef, const SConvertExt& data) {
			return !data.isOld && cdef->IsAvailable(frame) && terrainMgr->CanBeBuiltAt(cdef, pos);
		});
		if (convertDef != nullptr) {
			// NOTE: Next check may prevent converters even when open mex-spot is far
			//       away in unknown territory.
//			const SConvertExt* convertExt = convertDefs.GetAvailInfo(convertDef);
//			if ((mexDef == nullptr) || (convertExt->make / convertDef->GetCostM() >= metalMgr->GetSpotAvgIncome() * mexDef->GetExtractsM() / mexDef->GetCostM())) {
				task = builderMgr->Enqueue(TaskB::Common(IBuilderTask::BuildType::CONVERT,
										   IBuilderTask::Priority::NORMAL, convertDef, pos, 0.f, true));
				return task;
//			}
		}
	}

	return UpdateReclaimTasks(position, unit);
}

IBuilderTask* CEconomyManager::UpdateReclaimTasks(const AIFloat3& position, CCircuitUnit* unit, bool isNear)
{
	ZoneScoped;

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (/*!builderManager->CanEnqueueTask() || */(unit == nullptr) || !unit->GetCircuitDef()->IsAbleToReclaim()) {
		return nullptr;
	}

	bool isResurrect = unit->GetCircuitDef()->IsAbleToResurrect();  // false;
	if (IsMetalFull() || (builderMgr->GetTasks(IBuilderTask::BuildType::RECLAIM).size() >= builderMgr->GetWorkerCount() / 2)) {
//		isResurrect = unit->GetCircuitDef()->IsAbleToResurrect();
		if (!isResurrect) {
			return nullptr;
		}
	}

	std::vector<Feature*> features;
	if (isNear) {
		const float distance = unit->GetCircuitDef()->GetSpeed() * ((GetMetalPull() * 0.8f > GetAvgMetalIncome()) ? 60 : 20);
		features = std::move(circuit->GetCallback()->GetFeaturesIn(position, distance));
	} else {
		features = std::move(circuit->GetCallback()->GetFeatures());
	}
	if (features.empty()) {
		return nullptr;
	}

	COOAICallback* clb = circuit->GetCallback();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	AIFloat3 pos;
	float cost = .0f;
	float minSqDist = std::numeric_limits<float>::max();
	for (Feature* feature : features) {
		AIFloat3 featPos = feature->GetPosition();
		CTerrainManager::CorrectPosition(featPos);  // Impulsed flying feature
		if (!terrainMgr->CanReachAtSafe2(unit, featPos, unit->GetCircuitDef()->GetBuildDistance())) {
			continue;
		}
		FeatureDef* featDef;
		if (isResurrect) {
			if (!clb->Feature_IsResurrectable(feature->GetFeatureId())) {
				continue;
			}
			featDef = feature->GetDef();
		} else {
			featDef = feature->GetDef();
			if (!featDef->IsReclaimable()) {
				delete featDef;
				continue;
			}
		}
		float reclaimValue = featDef->GetContainedResource(metalRes)/* * feature->GetReclaimLeft()*/;
		delete featDef;
		if (reclaimValue < 1.0f) {
			continue;
		}
		float sqDist = position.SqDistance2D(featPos);
		if (sqDist < minSqDist) {
			pos = featPos;
			cost = reclaimValue;
			minSqDist = sqDist;
		}
	}
	utils::free_clear(features);

	IBuilderTask* task = nullptr;
	if (minSqDist < std::numeric_limits<float>::max()) {
		task = builderMgr->GetReclaimFeatureTask(pos, 8.0f/*unit->GetCircuitDef()->GetBuildDistance()*/);
		if (task != nullptr) {
			return task;
		}
		task = builderMgr->GetResurrectTask(pos, 8.0f/*unit->GetCircuitDef()->GetBuildDistance()*/);
		if (isResurrect) {
			if (task == nullptr) {
				task = builderMgr->Enqueue(TaskB::Resurrect(IBuilderTask::Priority::HIGH, pos, cost, FRAMES_PER_SEC * 300,
										   8.0f/*unit->GetCircuitDef()->GetBuildDistance()*/));
			}
		} else if (task == nullptr) {
			task = builderMgr->Enqueue(TaskB::Reclaim(IBuilderTask::Priority::HIGH, pos, cost, FRAMES_PER_SEC * 300,
									   8.0f/*unit->GetCircuitDef()->GetBuildDistance()*/));
		} else {
			task = nullptr;
		}
	}

	return task;
}

IBuilderTask* CEconomyManager::UpdateEnergyTasks(const AIFloat3& position, CCircuitUnit* unit)
{
	ZoneScoped;
	if (circuit->GetBuilderManager()->IsExperimentalBuild()) {
		return nullptr;  // D-093: TECH's layout places its economy; native's own energy and
		                 // mex orders sprawled outside it (played: turbines 400 elmos out)
	}

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (!builderMgr->CanEnqueueTask(32)) {
		return nullptr;
	}

	// check energy / metal ratio
	float metalIncome = GetAvgMetalIncome();
	float energyIncome = GetAvgEnergyIncome();
	bool isEnergyStalling = IsEnergyStalling();
	// TODO: e-stalling needs separate array of energy-defs sorted by cost

	// Select proper energy UnitDef to build
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CCircuitDef* bestDef = nullptr;
	CCircuitDef* hopeDef = nullptr;
	metalIncome = std::min(metalIncome, energyIncome) * energyFactor;
	const float buildPower = std::min(builderMgr->GetBuildPower(), metalIncome);
	energyIncome *= isEnergyStalling ? 0.5f : 1.f;
	isEnergyStalling |= isEnergyRequired;
	bool isLastHope = isEnergyStalling;
	const int frame = circuit->GetLastFrame();
	float bestResDist = std::numeric_limits<float>::max();

	std::map<CCircuitDef::Id, int> defCounts;
	for (IBuilderTask* task : builderMgr->GetTasks(IBuilderTask::BuildType::ENERGY)) {
		++defCounts[task->GetBuildDef()->GetId()];
	}

	const auto& infos = energyDefs.GetInfos();
	const float curWind = circuit->GetMap()->GetCurWind();
	auto checkWind = [curWind, terrainMgr, position, metalIncome, energyIncome, &infos](unsigned i) {
		int lowerIdx = -1;
		for (unsigned j = i + 1; j < infos.size(); ++j) {
			if ((infos[j].data.cond.metalIncome < metalIncome)
				&& (infos[j].data.cond.energyIncome < energyIncome)
				&& terrainMgr->CanBeBuiltAtSafe(infos[j].cdef, position))
			{
				lowerIdx = j;
				break;
			}
		}
		return (lowerIdx < 0) || (SQUARE(curWind) / SQUARE(infos[i].data.make) * infos[i].score > infos[lowerIdx].score);
	};

	for (unsigned i = 0; i < infos.size(); ++i) {  // sorted by high-tech first
		const auto& engy = infos[i];
		if (engy.data.isOld || !engy.cdef->IsAvailable(frame)
			|| !terrainMgr->CanBeBuiltAtSafe(engy.cdef, position))
		{
			continue;
		}

		if (engy.cdef->GetCount() < engy.data.cond.limit) {
			isLastHope = false;
			if (defCounts[engy.cdef->GetId()] < (int)(buildPower / engy.cdef->GetCostM() * 4 + 1)) {
				if (engy.cdef->IsWind() && !checkWind(i)) {
					continue;
				}
				if ((engy.data.cond.metalIncome < metalIncome) && (engy.data.cond.energyIncome < energyIncome)) {
					bestDef = engy.cdef;
					break;
				} else {
					const float resDist = ((engy.data.cond.metalIncome < metalIncome) ? 0.f : (engy.data.cond.metalIncome - metalIncome))
							+ ((engy.data.cond.energyIncome < energyIncome) ? 0.f : GetEcoEM() * (engy.data.cond.energyIncome - energyIncome));
					if (bestResDist > resDist) {
						bestResDist = resDist;
						bestDef = engy.cdef;
					}
				}
			} else if ((engy.data.cond.metalIncome < metalIncome)
				&& (engy.data.cond.energyIncome < energyIncome))
			{
				bestDef = nullptr;
				break;
			}
		} else if (!isEnergyStalling) {
			bestDef = nullptr;
			break;
		} else if (hopeDef == nullptr) {
			hopeDef = engy.cdef;
			isLastHope = isLastHope && (defCounts[engy.cdef->GetId()] < (int)(buildPower / engy.cdef->GetCostM() * 4 + 1));
		}
	}

	if (isLastHope) {
		bestDef = hopeDef;
	}
	if (bestDef == nullptr) {
		return UpdateGeoTasks(position, unit);
	}

	// Find place to build
	// TODO: Add place finder
	// 1) at very this position
	// 2) near mex
	// 3) at resource base (separate metal / energy)
	// 4) at production base
	CSetupManager* setupMgr = circuit->GetSetupManager();
	AIFloat3 buildPos = -RgtVector;
	if (bestDef->IsAttrBase()) {
		buildPos = (bestDef->GetCostM() < 1000.0f) ? setupMgr->GetEnergyBase() : setupMgr->GetEnergyBase2();
		CCircuitDef* bdef = (unit == nullptr) ? bestDef : unit->GetCircuitDef();
		buildPos = circuit->GetTerrainManager()->GetBuildPosition(bdef, buildPos);
	} else {
		if (terrainMgr->IsZoneAlly(position)
			|| ((circuit->GetFactoryManager()->GetFactoryCount() > 0) && (position.SqDistance2D(setupMgr->GetSmallEnergyPos()) < SQUARE(600.f))
				&& ((unit == nullptr) || !unit->GetCircuitDef()->IsRoleComm())))  // TODO: instead of isComm check isFast
		{
			buildPos = setupMgr->GetSmallEnergyPos();
		} else {
			buildPos = position + (position - terrainMgr->GetTerrainCenter()).Normalize2D() * (bestDef->GetRadius() + SQUARE_SIZE * 6);  // geom::get_radial_pos(position, bestDef->GetRadius() + SQUARE_SIZE * 6);
		}
		CTerrainManager::CorrectPosition(buildPos);
	}

	if (geom::is_valid(buildPos) && terrainMgr->CanBeBuiltAtSafe(bestDef, buildPos) &&
		((unit == nullptr) || terrainMgr->CanReachAtSafe(unit, buildPos, unit->GetCircuitDef()->GetBuildDistance())))
	{
		IBuilderTask::Priority priority = isEnergyStalling
				? (IsEnergyEmpty() ? IBuilderTask::Priority::NOW : IBuilderTask::Priority::HIGH)
				: IBuilderTask::Priority::NORMAL;
		IBuilderTask* task = builderMgr->Enqueue(TaskB::Common(IBuilderTask::BuildType::ENERGY,
												 priority, bestDef, buildPos, 0.f, true));
		if ((unit == nullptr) || unit->GetCircuitDef()->CanBuild(bestDef)) {
			return task;
		}
	}

	return nullptr;
}

IBuilderTask* CEconomyManager::UpdateGeoTasks(const AIFloat3& position, CCircuitUnit* unit)
{
	ZoneScoped;

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (!builderMgr->CanEnqueueTask(32) || !builderMgr->GetTasks(IBuilderTask::BuildType::GEO).empty() || !geoDefs.HasAvail()) {
		return nullptr;
	}

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	CMap* map = circuit->GetMap();
	CCircuitDef* geoDef = geoDefs.GetFirstDef();
	const CEnergyData::Geos& geos = circuit->GetEnergyManager()->GetSpots();
	float minDistSq = std::numeric_limits<float>::max();
	int index = -1;
	for (unsigned i = 0; i < geoSpots.size(); ++i) {
		const float distSq = geos[i].SqDistance2D(position);
		if (IsOpenGeoSpot(i) && (minDistSq > distSq)
			&& !terrainMgr->IsZoneAlly(geos[i]) && terrainMgr->CanBeBuiltAtSafe(geoDef, geos[i])
			&& map->IsPossibleToBuildAt(geoDef->GetDef(), geos[i], UNIT_NO_FACING))  // lazy check for allies
		{
			minDistSq = distSq;
			index = i;
		}
	}
	if (index == -1) {
		return nullptr;
	}

	float metalIncome = GetAvgMetalIncome();
	const float energyIncome = GetAvgEnergyIncome();
	metalIncome = std::min(metalIncome, energyIncome) * energyFactor;
	const float maxCostM = metalIncome * builderMgr->GetGoalExecTime();
	const float maxCostE = energyIncome * builderMgr->GetGoalExecTime();

	const AIFloat3& pos = geos[index];
	const int frame = circuit->GetLastFrame();
	geoDef = geoDefs.GetBestDef([frame, terrainMgr, &pos, maxCostM, maxCostE](CCircuitDef* cdef, const SGeoExt& data) {
		return cdef->IsAvailable(frame) && (cdef->GetCostM() < maxCostM) && (cdef->GetCostE() < maxCostE)
				&& terrainMgr->CanBeBuiltAt(cdef, pos);
	});
	if (geoDef == nullptr) {
		return nullptr;
	}

	return builderMgr->Enqueue(TaskB::Spot(IBuilderTask::BuildType::GEO, IBuilderTask::Priority::NORMAL, geoDef, pos, index));
}

IBuilderTask* CEconomyManager::UpdateFactoryTasks(const AIFloat3& position, CCircuitUnit* unit)
{
	ZoneScoped;

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (holdStartFactory && (circuit->GetFactoryManager()->GetFactoryCount() == 0)) {
		return nullptr;
	}
	if (!builderMgr->CanEnqueueTask(64) || isEnergyRequired) {
		return nullptr;
	}

	/*
	 * check air pads
	 */
	{
		IBuilderTask* task = nullptr;
		if (CheckAirpadRequired(position, unit, task)) {
			return task;
		}
	}

	/*
	 * check assist
	 */
	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	const bool isSwitchTime = factoryMgr->IsSwitchTime();
	if (!isSwitchTime) {
		IBuilderTask* task = nullptr;
		if (CheckAssistRequired(position, unit, task)) {
			return task;
		}
	}

	/*
	 * check factory
	 */
	if (!builderMgr->GetTasks(IBuilderTask::BuildType::FACTORY).empty()) {
		return nullptr;
	}

	const bool isStart = (factoryMgr->GetFactoryCount() == 0);
	if ((factoryTask == nullptr) && (PickNextFactory(position, isStart) == nullptr)) {
		return nullptr;
	}
	CCircuitDef* facDef = factoryTask->GetBuildDef();
	CCircuitDef* reprDef = factoryTask->GetReprDef();

	/*
	 * check metal and energy levels
	 */
//	const float metalIncome = std::min(GetAvgMetalIncome(), GetAvgEnergyIncome());  // FIXME: ZK
	float miRequire;
	float eiRequire;
	if (isStart && (unit != nullptr)) {
		const float startBuildTime = facDef->GetBuildTime() / unit->GetCircuitDef()->GetWorkerTime();
		miRequire = facDef->GetCostM() / startBuildTime * 0.25f;
		eiRequire = facDef->GetCostE() / startBuildTime;  // * 0.85f;
	} else {
		const float buildTime = reprDef->GetBuildTime() / facDef->GetWorkerTime();
		miRequire = reprDef->GetCostM() / buildTime * factoryMgr->GetNewFacModM();
		eiRequire = reprDef->GetCostE() / buildTime * factoryMgr->GetNewFacModE();
	}
	eiRequire += facDef->GetUpkeepE();
	const float metalFactor = GetAvgMetalIncome() - miRequire/* - builderMgr->GetBuildPower() * 0.2f*/;
	const float engyFactor = (GetAvgEnergyIncome() - eiRequire) * GetEcoEM()/* - builderMgr->GetBuildPower() * 0.2f*/;
	const int nanoQueued = builderMgr->GetTasks(IBuilderTask::BuildType::NANO).size();
	const float factoryPower = factoryMgr->GetMetalRequire() * factoryMgr->GetFacModM() + nanoQueued * factoryMgr->GetAssistSpeed();
	const float energyPower = factoryMgr->GetEnergyRequire() * factoryMgr->GetFacModE() * GetEcoEM() + nanoQueued * factoryMgr->GetAssistSpeed();
	if ((metalFactor < factoryPower) && !isSwitchTime && (isStart || (facDef->GetCostM() > GetMetalCur()))) {
		return nullptr;
	}
	if ((engyFactor < energyPower) || IsEnergyStalling()) {
		isEnergyRequired = true;  // enough metal, request energy
		UpdateEnergyTasks(geom::is_valid(position) ? position : circuit->GetSetupManager()->GetBasePos(), unit);
		return nullptr;
	}
	if (!isStart && !circuit->IsSlave() && !factoryMgr->IsSwitchAllowed(facDef)) {
		return nullptr;
	}

	// desired position
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	AIFloat3 buildPos;
	if (factoryTask->IsPlop()) {
		buildPos = -RgtVector;
	} else {
		const AIFloat3& basePos = circuit->GetSetupManager()->GetBasePos();
		const AIFloat3& enemyPos = circuit->GetEnemyManager()->GetEnemyPos();
		float offset = 200.0f;
		if (isStart) {
			buildPos = basePos;
		} else if (facDef->IsRoleSupport()) {
			if (facDef->GetMobileId() < 0) {  // air factory
				buildPos = basePos;
				offset = -200.0f;
			} else {
				int facing;
				buildPos = terrainMgr->GetBusPos(facDef, basePos, facing);
				factoryTask->SetFacing(facing);
				offset = 0.f;
			}
		} else {
			CMetalManager* metalMgr = circuit->GetMetalManager();
			AIFloat3 pos(basePos);
			AIFloat3 center = (pos + enemyPos) * 0.5f;
			float minSqDist = std::numeric_limits<float>::max();
			const CMetalData::Clusters& clusters = metalMgr->GetClusters();
			for (unsigned i = 0; i < clusters.size(); ++i) {
				if (!metalMgr->IsClusterFinished(i)) {
					continue;
				}
				const float sqDist = center.SqDistance2D(clusters[i].position);
				if (minSqDist > sqDist) {
					minSqDist = sqDist;
					pos = clusters[i].position;
				}
			}

			CMetalData::PointPredicate predicate = [this, facDef, terrainMgr, &clusters](const int index) {
				return (clusterInfos[index].factory == nullptr) && !terrainMgr->IsZoneAlly(clusters[index].position)
						&& terrainMgr->CanBeBuiltAtSafe(facDef, clusters[index].position);
			};
			int index = metalMgr->FindNearestCluster(pos, predicate);
			if (index < 0) {
				return nullptr;
			}
			buildPos = clusters[index].position;

			const float sqStartDist = enemyPos.SqDistance2D(basePos);
			const float sqBuildDist = enemyPos.SqDistance2D(buildPos);
			offset = (sqStartDist > sqBuildDist) ? -200.0f : 200.0f;  // std::max(facUDef->GetXSize(), facUDef->GetZSize()) * SQUARE_SIZE;
		}

		if (factoryTask->GetFacing() != UNIT_NO_FACING) {
			factoryTask->SetBuildPos(buildPos);
		} else {
			buildPos.x += (buildPos.x > enemyPos.x) ? -offset : offset;
			buildPos.z += (buildPos.z > enemyPos.z) ? -offset : offset;

			CTerrainManager::CorrectPosition(buildPos);
			buildPos = terrainMgr->GetBuildPosition(reprDef, buildPos);
		}
	}

	factoryTask->SetPosition(buildPos);

	if (factoryTask->IsPlop()
		|| (terrainMgr->CanBeBuiltAtSafe(facDef, buildPos)
			&& ((unit == nullptr) || terrainMgr->CanReachAtSafe(unit, buildPos, unit->GetCircuitDef()->GetBuildDistance()))))
	{
//		if (factoryMgr->GetNoT1FacCount() == 0) {  // FIXME
//			CCircuitUnit* reclFac = factoryMgr->GetClosestFactory(buildPos);
//			if (reclFac != nullptr) {
////				factoryMgr->DisableFactory(reclFac);
//				builderMgr->EnqueueTask(TaskB::Reclaim(IBuilderTask::Priority::NOW, reclFac));
//			}
//		}
		builderMgr->ActivateTask(factoryTask);
		IBuilderTask* task = factoryTask;
		factoryTask = nullptr;
		return task;
	} else {
		delete factoryTask;
		factoryTask = nullptr;
	}

	return nullptr;
}

IBuilderTask* CEconomyManager::UpdateFactoryTasks()
{
	return UpdateFactoryTasks(circuit->GetSetupManager()->GetBasePos());
}

IBuilderTask* CEconomyManager::UpdateStorageTasks()
{
	ZoneScoped;

	if (circuit->GetBuilderManager()->IsExperimentalBuild()) {
		return nullptr;  // D-066: storage and pylons are the script's
	}
	if (!autoStorageEnabled) {
		return UpdatePylonTasks();
	}
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (!builderMgr->CanEnqueueTask(32)) {
		return nullptr;
	}

	if (!builderMgr->GetTasks(IBuilderTask::BuildType::STORE).empty()) {
		return UpdatePylonTasks();
	}

	CCircuitDef* storeDef = nullptr;
	if (storeMDefs.HasAvail()) {
		storeDef = storeMDefs.GetFirstDef();

		if (!storeDef->IsAvailable(circuit->GetLastFrame())
//			|| (GetMetalStore() > 60 * GetAvgMetalIncome())
			|| !IsMetalFull())
		{
			storeDef = nullptr;
		}
	}

	if ((storeDef == nullptr) && storeEDefs.HasAvail()) {
		storeDef = storeEDefs.GetFirstDef();

		if (!storeDef->IsAvailable(circuit->GetLastFrame())
			|| (GetEnergyStore() > 5 * GetAvgEnergyIncome())
			|| IsEnergyEmpty())
		{
			storeDef = nullptr;
		}
	}

	if (storeDef != nullptr) {
		AIFloat3 buildPos = circuit->GetSetupManager()->GetBasePos();
		return builderMgr->Enqueue(TaskB::Common(IBuilderTask::BuildType::STORE,
								   IBuilderTask::Priority::HIGH, storeDef, buildPos));
	}

	return UpdatePylonTasks();
}

IBuilderTask* CEconomyManager::UpdatePylonTasks()
{
	return nullptr;
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (!builderMgr->CanEnqueueTask()) {
		return nullptr;
	}

	const float energyIncome = GetAvgEnergyIncome();
	const float metalIncome = std::min(GetAvgMetalIncome(), energyIncome);
	if (metalIncome < pylonLinkInc) {
		return nullptr;
	}

	const float cost = pylonDef->GetCostM();
	unsigned count = builderMgr->GetBuildPower() / cost * 8 + 1;
	if (builderMgr->GetTasks(IBuilderTask::BuildType::PYLON).size() >= count) {
		return nullptr;
	}

	energyGrid->SetAuthority(circuit);
	energyGrid->Update();

	CCircuitDef* buildDef;
	AIFloat3 buildPos;
	IGridLink* link = energyGrid->GetLinkToBuild(buildDef, buildPos);
	if ((link == nullptr) || (buildDef == nullptr)) {
		return nullptr;
	}

	if (geom::is_valid(buildPos)) {
		IBuilderTask::Priority priority = metalIncome < 40 ? IBuilderTask::Priority::NORMAL : IBuilderTask::Priority::HIGH;
		return builderMgr->Enqueue(TaskB::Pylon(priority, buildDef, buildPos, link, buildDef->GetCostM()));
	} else {
		link->SetValid(false);
		energyGrid->SetForceRebuild(true);
		// TODO: Optimize: when invalid link appears start watchdog gametask
		//       that will traverse invalidLinks vector and enable link on timeout.
		//       When invalidLinks is empty remove watchdog gametask.
		circuit->GetScheduler()->RunJobAfter(CScheduler::GameJob([link](CEnergyGrid* energyGrid) {
			link->SetValid(true);
			energyGrid->SetForceRebuild(true);
		}, energyGrid), FRAMES_PER_SEC * 120);
	}

	return nullptr;
}

IBuilderTask* CEconomyManager::CheckMobileAssistRequired(const AIFloat3& position, CCircuitUnit* unit)
{
	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (!factoryMgr->IsAssistRequired() || !builderMgr->HasFreeAssists(unit)
		|| factoryMgr->GetTasks().empty() || factoryMgr->GetTasks().front()->GetAssignees().empty())
	{
		return nullptr;
	}
	CRecruitTask* recrTask = factoryMgr->GetTasks().front();
	CCircuitUnit* vip = *recrTask->GetAssignees().begin();
	if (vip->GetPos(circuit->GetLastFrame()).SqDistance2D(position) > SQUARE(600.f)) {
		return nullptr;
	}
	constexpr int SEC = 10;  // are there enough resources for 8-10 seconds?
	CCircuitDef* recrDef = recrTask->GetBuildDef();
	const float buildTime = recrDef->GetBuildTime() / unit->GetCircuitDef()->GetWorkerTime();
	const float miRequire = recrDef->GetCostM() / buildTime;  // + recrTask->GetBuildPowerM();
	const float eiRequire = recrDef->GetCostE() / buildTime;  // + recrTask->GetBuildPowerE();
	if ((metal.current > (metal.pull + miRequire - GetAvgMetalIncome()) * (SEC - 2))
		&& (energy.current > (energy.pull + eiRequire - GetAvgEnergyIncome()) * (SEC - 2)))
	{
		return builderMgr->EnqueueB(TaskB::Guard(IBuilderTask::Priority::HIGH, vip, false, FRAMES_PER_SEC * SEC));
	}
	return nullptr;
}

void CEconomyManager::StartFactoryJob()
{
	if (circuit->GetBuilderManager()->IsExperimentalBuild()) {
		return;  // D-066: the script places and orders every factory
	}
	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	if ((factoryMgr->GetFactoryCount() == 0) && circuit->GetBuilderManager()->GetTasks(IBuilderTask::BuildType::FACTORY).empty()) {
		CCircuitUnit* comm = circuit->GetSetupManager()->GetCommander();
		const AIFloat3 pos = (comm != nullptr) ? comm->GetPos(circuit->GetLastFrame()) : AIFloat3(-RgtVector);
		if (!factoryMgr->IsSwitchTime() && (comm != nullptr) && (comm->GetTask()->GetType() == IUnitTask::Type::BUILDER)) {
			IBuilderTask* taskB = static_cast<IBuilderTask*>(comm->GetTask());
			const float maxDist = comm->GetCircuitDef()->GetBuildDistance() + comm->GetCircuitDef()->GetSpeed() * startMexTravel;
			if (taskB->GetPosition().SqDistance2D(pos) > SQUARE(maxDist)) {
				factoryMgr->RaiseSwitchTime();
			}
			// FIXME: Alternative WIP
//			IBuilderTask* taskB = static_cast<IBuilderTask*>(comm->GetTask());
//			const float dist = taskB->GetPosition().distance2D(pos) - comm->GetCircuitDef()->GetBuildDistance();
//			const float moveETA = dist / comm->GetCircuitDef()->GetSpeed();
//			const float moveMetal = GetMetalCur() + GetAvgMetalIncome() * (moveETA + 1);  // 1 seconds - buffer
//			const float store = GetMetalStore();
//			if (moveMetal >= store) {
//				factoryMgr->RaiseSwitchTime();
//			} else {
//				const float buildTime = taskB->GetBuildDef()->GetBuildTime() / comm->GetCircuitDef()->GetWorkerTime();
//				const float pull = GetAvgMetalIncome() * buildTime - taskB->GetBuildDef()->GetCostM();
//				if (moveMetal + pull >= store) {
//					factoryMgr->RaiseSwitchTime();
//				}
//			}
			// FIXME
		}
		IBuilderTask* factoryTask = UpdateFactoryTasks(pos, comm);
		if (factoryTask == nullptr) {
//			if (isEnergyRequired) {
//				if (comm != nullptr) {
//					UpdateEnergyTasks(pos, comm);
//				}
//			}
			return;
		}
//		if (comm != nullptr) {
//			circuit->GetBuilderManager()->AssignTask(comm, factoryTask);
//		}
	}

	CScheduler* scheduler = circuit->GetScheduler().get();
	scheduler->RemoveJob(startFactory);
	startFactory = nullptr;

	const int interval = circuit->GetAllyTeam()->GetSize() * FRAMES_PER_SEC;
	auto update = static_cast<IBuilderTask* (CEconomyManager::*)(void)>(&CEconomyManager::UpdateFactoryTasks);
	scheduler->RunJobEvery(CScheduler::GameJob(update, this),
							interval, circuit->GetSkirmishAIId() + 0 + 10 * interval);
}

CBFactoryTask* CEconomyManager::PickNextFactory(const AIFloat3& position, bool isStart)
{
	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	CCircuitDef* facDef = factoryMgr->GetFactoryToBuild(position, isStart);
	if (facDef == nullptr) {
		return nullptr;
	}
	CCircuitDef* reprDef = factoryMgr->GetRepresenter(facDef);
	if (reprDef == nullptr) {  // identify area to build by factory representatives
		return nullptr;
	}
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	IBuilderTask::Priority priority = (builderMgr->GetWorkerCount() <= 2)
									  ? IBuilderTask::Priority::NOW
									  : IBuilderTask::Priority::HIGH;
	const bool isPlop = (factoryMgr->GetFactoryCount() <= 0);
	// hold selected facDef - create non-active task
	factoryTask = static_cast<CBFactoryTask*>(builderMgr->Enqueue(TaskB::Factory(priority,
			facDef, -RgtVector, reprDef, SQUARE_SIZE, isPlop, false, FRAMES_PER_SEC * 120)));
	return factoryTask;
}

void CEconomyManager::AddMorphee(CCircuitUnit* unit)
{
	if (!unit->IsUpgradable() || (unit->GetTask()->GetType() == IUnitTask::Type::NIL)) {
		return;
	}
	morphees.insert(unit);
	if (morph == nullptr) {
		morph = CScheduler::GameJob(&CEconomyManager::UpdateMorph, this);
		circuit->GetScheduler()->RunJobEvery(morph, FRAMES_PER_SEC * 10);
	}
}

void CEconomyManager::UpdateMorph()
{
	ZoneScoped;

	if (morphees.empty()) {
		circuit->GetScheduler()->RemoveJob(morph);
		morph = nullptr;
		return;
	}

	const float energyIncome = GetAvgEnergyIncome();
	const float metalIncome = std::min(GetAvgMetalIncome(), energyIncome);
	if ((metalIncome < 10) || !IsExcessed() || !IsMetalFull() || (GetMetalPull() * 0.8f > metalIncome)) {
		return;
	}

	auto it = morphees.begin();
	while (it != morphees.end()) {
		CCircuitUnit* unit = *it;
		if ((unit->GetTask()->GetType() == IUnitTask::Type::PLAYER) ||
			(unit->GetUnit()->GetHealth() < unit->GetUnit()->GetMaxHealth() * 0.8f))
		{
			++it;
		} else {
			unit->Upgrade();  // Morph();
			it = morphees.erase(it);
			break;  // one unit at a time
		}
	}
}

void CEconomyManager::AddFactoryInfo(CCircuitUnit* unit)
{
	const int index = circuit->GetMetalManager()->FindNearestCluster(unit->GetPos(circuit->GetLastFrame()));
	if (index >= 0) {
		clusterInfos[index].factory = unit;
	}
}

void CEconomyManager::DelFactoryInfo(CCircuitUnit* unit)
{
	for (auto& info : clusterInfos) {
		if (info.factory == unit) {
			info.factory = nullptr;
		}
	}
}

bool CEconomyManager::CheckAirpadRequired(const AIFloat3& position, CCircuitUnit* unit, IBuilderTask*& outTask)
{
	outTask = nullptr;

	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	CMilitaryManager* militaryMgr = circuit->GetMilitaryManager();
	const unsigned airpadFactor = SQUARE((airpadCount + builderMgr->GetTasks(IBuilderTask::BuildType::FACTORY).size() + 1) * 3);
	if (militaryMgr->GetRoleUnits(ROLE_TYPE(AIR)).size() <= airpadFactor) {
		return false;
	}

	const int frame = circuit->GetLastFrame();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	AIFloat3 buildPos = position;
	CCircuitDef* airpadDef = nullptr;
	if (unit == nullptr) {
		airpadDef = airpadDefs.GetBestDef([frame, terrainMgr, &buildPos](CCircuitDef* cdef, const SAirpadExt& data) {
			return cdef->IsAvailable(frame) && terrainMgr->CanBeBuiltAt(cdef, buildPos);
		});
	} else {
		const std::vector<CCircuitDef*>& padDefOptions = airpadDefs.GetBuildDefs(unit->GetCircuitDef());
		for (CCircuitDef* apDef : padDefOptions) {
			if (apDef->IsAvailable(frame) && terrainMgr->CanBeBuiltAt(apDef, buildPos)) {
				airpadDef = apDef;
				break;
			}
		}
	}
	if (airpadDef == nullptr) {
		return false;
	}

	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	CCircuitDef* bdef;
	if (unit == nullptr) {
		bdef = airpadDef;
		buildPos = factoryMgr->GetClosestHaven(circuit->GetSetupManager()->GetBasePos());
	} else {
		bdef = unit->GetCircuitDef();
		buildPos = factoryMgr->GetClosestHaven(unit);
	}
	if (!geom::is_valid(buildPos)) {
		buildPos = circuit->GetSetupManager()->GetBasePos();
	}
	buildPos = terrainMgr->GetBuildPosition(bdef, buildPos);

	if (terrainMgr->CanBeBuiltAtSafe(airpadDef, buildPos) &&
		((unit == nullptr) || terrainMgr->CanReachAtSafe(unit, buildPos, unit->GetCircuitDef()->GetBuildDistance())))
	{
		outTask = builderMgr->Enqueue(TaskB::Factory(IBuilderTask::Priority::NORMAL, airpadDef, buildPos, nullptr));
		return true;
	}

	return false;
}

bool CEconomyManager::CheckAssistRequired(const AIFloat3& position, CCircuitUnit* unit, IBuilderTask*& outTask)
{
	outTask = nullptr;

	if (!assistNanoEnabled) {
		return false;  // the role's script owns nano policy
	}
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	const int nanoQueued = builderMgr->GetTasks(IBuilderTask::BuildType::NANO).size();
	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	CCircuitUnit* factory = factoryMgr->NeedUpgrade(nanoQueued);
	if (factory == nullptr) {
		return false;
	}

	const int frame = circuit->GetLastFrame();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	AIFloat3 buildPos = factory->GetPos(frame);
	CCircuitDef* assistDef = assistDefs.GetBestDef([frame, terrainMgr, &buildPos](CCircuitDef* cdef, const SAssistExt& data) {
		return cdef->IsAvailable(frame) && terrainMgr->CanBeBuiltAt(cdef, buildPos);
	});
	if (assistDef == nullptr) {
		return true;
	}

	/*
	 * check metal and energy
	 */
//	const float metalIncome = std::min(GetAvgMetalIncome(), GetAvgEnergyIncome());  // FIXME: ZK
	float miRequire;
	float eiRequire;
	CCircuitDef* facDef = factory->GetCircuitDef();
	CCircuitDef* reprDef = factoryMgr->GetRepresenter(facDef);
	if (reprDef == nullptr) {
		miRequire = assistDef->GetBuildSpeed();
		eiRequire = miRequire / GetEcoEM();
	} else {
		const float buildTime = reprDef->GetBuildTime() / assistDef->GetWorkerTime();
		miRequire = reprDef->GetCostM() / buildTime;
		eiRequire = reprDef->GetCostE() / buildTime;
	}
	miRequire *= factoryMgr->GetNewFacModM();
	eiRequire *= factoryMgr->GetNewFacModE();
	eiRequire += assistDef->GetUpkeepE();
	// FIXME: Mex and other buildings have energy upkeep that's not counted.
	//        It also doesn't count mobile buildpower
	if (GetAvgMetalIncome() < factoryMgr->GetMetalRequire() * factoryMgr->GetFacModM() + (nanoQueued + 1) * miRequire * assistNanoIncomeMod) {
		return true;
	}
	if ((GetAvgEnergyIncome() < factoryMgr->GetEnergyRequire() * factoryMgr->GetFacModE() + (nanoQueued + 1) * eiRequire)
		|| IsEnergyStalling())
	{
		isEnergyRequired = true;  // enough metal, request energy
		UpdateEnergyTasks(position, unit);
		return true;
	}

	switch (factory->GetUnit()->GetBuildingFacing()) {
		default:
		case UNIT_FACING_SOUTH:
			buildPos.z -= 64.0f;  // def->GetZSize() * SQUARE_SIZE * 2;
			break;
		case UNIT_FACING_EAST:
			buildPos.x -= 64.0f;  // def->GetXSize() * SQUARE_SIZE * 2;
			break;
		case UNIT_FACING_NORTH:
			buildPos.z += 64.0f;  // def->GetZSize() * SQUARE_SIZE * 2;
			break;
		case UNIT_FACING_WEST:
			buildPos.x += 64.0f;  // def->GetXSize() * SQUARE_SIZE * 2;
			break;
	}
	CTerrainManager::CorrectPosition(buildPos);
	CCircuitDef* bdef = (unit == nullptr) ? facDef : unit->GetCircuitDef();
	buildPos = terrainMgr->GetBuildPosition(bdef, buildPos);

	if (terrainMgr->CanBeBuiltAtSafe(assistDef, buildPos)
		&& ((unit == nullptr) || terrainMgr->CanReachAtSafe(unit, buildPos, unit->GetCircuitDef()->GetBuildDistance())))
	{
		outTask = builderMgr->Enqueue(TaskB::Common(IBuilderTask::BuildType::NANO, IBuilderTask::Priority::HIGH,
									  assistDef, buildPos, SQUARE_SIZE * 8, true));
		return true;
	}
	return false;
}

float CEconomyManager::GetStorage(Resource* res)
{
	return economy->GetStorage(res) - HIDDEN_STORAGE;
}

void CEconomyManager::UpdateResourceIncome()
{
	float oddEnergyIncome = circuit->GetTeam()->GetRulesParamFloat("OD_energyIncome", 0.f);
	float oddEnergyChange = circuit->GetTeam()->GetRulesParamFloat("OD_energyChange", 0.f);

	energyIncomes[indexRes] = economy->GetIncome(energyRes) + oddEnergyIncome - std::max(.0f, oddEnergyChange);
	metalIncomes[indexRes] = economy->GetIncome(metalRes) + economy->GetReceived(metalRes);
	++indexRes %= INCOME_SAMPLES;

	metal.income = .0f;
	for (int i = 0; i < INCOME_SAMPLES; i++) {
		metal.income += metalIncomes[i];
	}
	metal.income /= INCOME_SAMPLES;

	energy.income = .0f;
	for (int i = 0; i < INCOME_SAMPLES; i++) {
		energy.income += energyIncomes[i];
	}
	energy.income /= INCOME_SAMPLES;

	metalProduced += metal.income * metalMod;
	metalUsed += economy->GetUsage(metalRes);
}

void CEconomyManager::UpdateEconomy()
{
	ZoneScoped;

	UpdateResourceIncome();

	int ecoFrame = circuit->GetLastFrame();

	/*const float curMetal = */GetMetalCur();
	/*const float storMetal = */GetMetalStore();
	/*const float incMetal = */GetAvgMetalIncome();
	/*const float pullMetal = */GetMetalPull();

	/*const float curEnergy = */GetEnergyCur();
	/*const float storEnergy = */GetEnergyStore();
	/*const float incEnergy = */GetAvgEnergyIncome();
	/*const float pullEnergy = */GetEnergyPull();

	// Update isMetalEmpty, isMetalFull, isEnergyEmpty, isEnergyStalling
	static_cast<CEconomyScript*>(script)->UpdateEconomy();

	if (ecoFrame <= efInfo.startFrame) {
		energyFactor = efInfo.startFactor;
	} else if (ecoFrame >= efInfo.endFrame) {
		energyFactor = efInfo.endFactor;
	} else {
		energyFactor = efInfo.fraction * (ecoFrame - efInfo.startFrame) + efInfo.startFactor;
	}

	if (ecoFrame <= bdInfo.startFrame) {
		buildDelay = bdInfo.startDelay;
	} else if (ecoFrame >= bdInfo.endFrame) {
		buildDelay = bdInfo.endDelay;
	} else {
		buildDelay = int(bdInfo.fraction * (ecoFrame - bdInfo.startFrame)) + bdInfo.startDelay;
	}

	if (mexCount <= mspInfos.front().mex) {
		pullMtoS = mspInfos.front().pull;
	} else if (mexCount >= mspInfos.back().mex) {
		pullMtoS = mspInfos.back().pull;
	} else {
		auto it = std::lower_bound(mspInfos.cbegin(), mspInfos.cend(), mexCount, SPullMtoS());
		const SPullMtoS& mspInfo = *--it;
		pullMtoS = mspInfo.fraction * (mexCount - mspInfo.mex) + mspInfo.pull;
	}
	pullMtoS *= circuit->GetMilitaryManager()->ClampMobileCostRatio();
}

void CEconomyManager::IncPurpose(const CCircuitDef::Id defId)
{
	auto it = purposes.find(defId);
	if (it == purposes.end()) {
		purposes[defId].count = 1;
	} else {
		++it->second.count;
	}
}

void CEconomyManager::DecPurpose(const CCircuitDef::Id defId)
{
	assert(purposes.find(defId) != purposes.end());
	--purposes[defId].count;
}

bool CEconomyManager::HasNoPurpose(const CCircuitDef::Id defId) const
{
	auto it = purposes.find(defId);
	assert(it != purposes.end());
	return (it == purposes.end()) || (it->second.count <= 0);
}

void CEconomyManager::ReclaimOldConvert(const SConvertExt* convertExt)
{
	if (circuit->IsLoadSave() || (reclConvertEff <= 0.f)
			|| (!reclaimOldConvertersAlways && IsEnergyFull() && !IsEnergyStalling())) {
		return;
	}
	float energyNet = GetAvgEnergyIncome() - GetEnergyPull();
	auto ids = circuit->GetCallback()->GetFriendlyUnitIdsIn(circuit->GetSetupManager()->GetMetalBase(), 1000.f, false);
	for (int id : ids) {
		CCircuitUnit* unit = circuit->GetTeamUnit(id);
		if (unit == nullptr) {
			continue;
		}
		CCircuitDef* cdef = unit->GetCircuitDef();
		if (!convertDefs.IsAvail(cdef)) {
			continue;
		}
		auto info = convertDefs.GetAvailInfo(cdef);
		if (convertExt->make > info->make * reclConvertEff) {
			if (!info->isOld) {
				const_cast<SConvertExt*>(info)->isOld = true;
				DecPurpose(cdef->GetId());
			}
		} else {
			if (info->isOld) {
				const_cast<SConvertExt*>(info)->isOld = false;
				IncPurpose(cdef->GetId());
			}
		}
		if (HasNoPurpose(cdef->GetId())) {
			circuit->GetBuilderManager()->Enqueue(TaskB::Reclaim(IUnitTask::Priority::HIGH, unit, FRAMES_PER_SEC * 1200));
			energyNet += convertExt->energyUse;
			if (energyNet > 0) {
				break;
			}
		}
	}
}

void CEconomyManager::SetEnergyCondition(CCircuitDef* cdef, int limit, float metalIncome, float energyIncome)
{
	if (cdef == nullptr) {
		return;
	}
	const SEnergyExt* info = energyDefs.GetAvailInfo(cdef);
	if (info == nullptr) {
		circuit->LOG("ECONOMY: SetEnergyCondition: %s is not an energy def", cdef->GetDef()->GetName());
		return;
	}
	// Both the canonical entry and the selection list's copy (CR-009).
	energyDefs.UpdateInfo(cdef, [limit, metalIncome, energyIncome](SEnergyExt& ext) {
		if (limit >= 0) {
			ext.cond.limit = limit;
		}
		if (metalIncome >= 0.f) {
			ext.cond.metalIncome = metalIncome;
		}
		if (energyIncome >= 0.f) {
			ext.cond.energyIncome = energyIncome;
		}
	});
	info = energyDefs.GetAvailInfo(cdef);
	circuit->LOG("ECONOMY: %s energy condition now limit %i, metal income %.0f, energy income %.0f",
			cdef->GetDef()->GetName(), info->cond.limit, info->cond.metalIncome, info->cond.energyIncome);
}

int CEconomyManager::GetEnergyLimit(CCircuitDef* cdef) const
{
	const SEnergyExt* info = (cdef == nullptr) ? nullptr : energyDefs.GetAvailInfo(cdef);
	return (info == nullptr) ? -1 : info->cond.limit;
}

void CEconomyManager::ReclaimOldEnergy(const SEnergyExt* energyExt)
{
	if (metalMap) return; // density retirement belongs to the metal-map script policy
	float energyIncome = GetAvgEnergyIncome();
	if (circuit->IsLoadSave() || (reclEnergyEff <= 0.f) || (energyIncome < energyExt->cond.energyIncome)) {
		return;
	}
	auto ids = circuit->GetCallback()->GetFriendlyUnitIdsIn(circuit->GetSetupManager()->GetBasePos(), 1000.f, false);
	for (int id : ids) {
		CCircuitUnit* unit = circuit->GetTeamUnit(id);
		if (unit == nullptr) {
			continue;
		}
		CCircuitDef* cdef = unit->GetCircuitDef();
		if (!energyDefs.IsAvail(cdef)) {
			continue;
		}
		auto info = energyDefs.GetAvailInfo(cdef);
		if (energyExt->cond.score > info->cond.score * reclEnergyEff) {
			if (!info->isOld) {
				const_cast<SEnergyExt*>(info)->isOld = true;
				DecPurpose(cdef->GetId());
			}
		} else {
			if (info->isOld) {
				const_cast<SEnergyExt*>(info)->isOld = false;
				IncPurpose(cdef->GetId());
			}
		}
		if (HasNoPurpose(cdef->GetId())) {
			energyIncome -= info->make;
			if (energyIncome < energyExt->cond.energyIncome) {
				break;
			}
			circuit->GetBuilderManager()->Enqueue(TaskB::Reclaim(IUnitTask::Priority::HIGH, unit, FRAMES_PER_SEC * 1200));
		}
	}
}

} // namespace circuit
