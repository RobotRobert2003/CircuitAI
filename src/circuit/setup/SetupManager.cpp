/*
 * SetupManager.cpp
 *
 *  Created on: Dec 9, 2014
 *      Author: rlcevg
 */

#include "setup/SetupManager.h"
#include "script/SetupScript.h"
#include "map/InfluenceMap.h"
#include "module/EconomyManager.h"
#include "module/MilitaryManager.h"  // Only for CalcLanePos
#include "resource/MetalManager.h"
#include "scheduler/Scheduler.h"
#include "terrain/TerrainManager.h"
#include "task/builder/FactoryTask.h"
#include "CircuitAI.h"
#include "util/GameAttribute.h"
#include "util/FileSystem.h"
#include "util/Utils.h"
#include "json/json.h"

#include <regex>
#include <map>
#include <set>
#include <algorithm>

#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"

#include "OptionValues.h"
#include "SkirmishAI.h"
#include "Info.h"
#include "Game.h"
#include "Log.h"
#include "Lua.h"

#include <regex>
#include <random>

namespace circuit {

using namespace springai;
using namespace terrain;

CSetupManager::CSetupManager(CCircuitAI* circuit, CSetupData* setupData)
		: circuit(circuit)
		, setupData(setupData)
		, script(new CSetupScript(circuit->GetScriptManager(), this))
		, config(nullptr)
		, scriptConfig(nullptr)
		, commander(nullptr)
		, startPos(-RgtVector)
		, basePos(-RgtVector)
		, lanePos(-RgtVector)
		, metalBase(-RgtVector)
		, energyBase(-RgtVector)
		, energyBase2(-RgtVector)
		, smallEnergyPos(-RgtVector)
		, antiCapProb(2.f)
		, emptyShield(0.f)
		, fullShield(0.f)
		, assistFac(0)
		, commChoice(nullptr)
		, isSideSelected(false)
		, isWaterHarmful(false)
{
	if (!setupData->IsInitialized()) {
		setupData->ParseSetupScript(circuit, circuit->GetGame()->GetSetupScript());
	}
	ParseScriptStarts();  // D-127: the script is readable here (later calls return nothing)

	findStart = CScheduler::GameJob(&CSetupManager::FindStart, this);
	circuit->GetScheduler()->RunJobEvery(findStart, 1);
}

CSetupManager::~CSetupManager()
{
	delete script;
	delete config;
	delete scriptConfig;
}

void CSetupManager::DisabledUnits()
{
	auto disableUnits = [this](const std::string& opt_str) {
		std::string::const_iterator start = opt_str.begin();
		std::string::const_iterator end = opt_str.end();
		std::regex patternUnit("\\w+");
		std::smatch section;
		while (std::regex_search(start, end, section, patternUnit)) {
			CCircuitDef* cdef = circuit->GetCircuitDef(std::string(section[0]).c_str());
			if (cdef != nullptr) {
				cdef->SetMaxThisUnit(0);
			}
			start = section[0].second;
		}
	};

	auto it = GetModOptions().find("disabledunits");
	if (it != GetModOptions().end()) {
		// !setoptions disabledunits=armwar+armpw+raveparty+zenith+mahlazer
		disableUnits(it->second);
	}

	OptionValues* options = circuit->GetSkirmishAI()->GetOptionValues();
	const char* value = options->GetValueByKey("disabledunits");
	delete options;
	if (value != nullptr) {
		disableUnits(value);
	}
}

bool CSetupManager::OpenConfig(const std::string& profile, const std::vector<std::string>& parts)
{
	bool isOk = LoadConfig(profile, parts);
	if (isOk) {
		OverrideConfig();
	}
	return isOk;
}

void CSetupManager::CloseConfig()
{
	if (config != nullptr) {  // D-126: the script-read sections outlive the config
		delete scriptConfig;
		scriptConfig = new Json::Value(Json::objectValue);
		// Commander policy and the scout-raid switch are read after init too.
		for (const char* key : {"weapons", "lanes", "commander", "scout_raid", "field"}) {
			if (config->isMember(key)) {
				(*scriptConfig)[key] = (*config)[key];
			}
		}
	}
	delete config;
	config = nullptr;
}

const CSetupData::ModOptions& CSetupManager::GetModOptions() const
{
	return setupData->GetModOptions();
}

bool CSetupManager::HasStartBoxes() const
{
	return setupData->IsInitialized();
}

int CSetupManager::EnemyStartBoxAt(const AIFloat3& pos) const
{
	if (!setupData->IsInitialized()) {
		return -1;
	}
	const int own = circuit->GetAllyTeamId();
	for (int i = 0; i < setupData->GetAllyTeamCount(); ++i) {
		if (i == own) {
			continue;
		}
		CAllyTeam* at = setupData->GetAllyTeam(i);
		if ((at != nullptr) && at->GetStartBox().ContainsPoint(pos)) {
			return 1;
		}
	}
	return 0;
}

void CSetupManager::ParseScriptStarts()
{
	if (scriptStartsParsed) {
		return;
	}
	scriptStartsParsed = true;
	const char* raw = circuit->GetGame()->GetSetupScript();
	if (raw == nullptr) {
		return;
	}
	const std::string script(raw);
	// Direct fields: [team0] { startposx=...; allyteam=...; }, [ai1] { team=1; },
	// [player0] { team=2; spectator=1; }. A plain scan: std::regex threw on this
	// compiler ("Invalid range in '{}'") and the AI failed to start.
	auto trim = [](std::string s) {
		const size_t b = s.find_first_not_of(" \t\r\n");
		const size_t e = s.find_last_not_of(" \t\r\n");
		return (b == std::string::npos) ? std::string() : s.substr(b, e - b + 1);
	};
	std::map<int, SScriptStart> teams;
	std::set<int> playing;
	size_t pos = 0;
	while ((pos = script.find('[', pos)) != std::string::npos) {
		const size_t close = script.find(']', pos);
		if (close == std::string::npos) {
			break;
		}
		std::string name = script.substr(pos + 1, close - pos - 1);
		std::transform(name.begin(), name.end(), name.begin(), ::tolower);
		pos = close + 1;
		if (name.rfind("team", 0) != 0 && name.rfind("ai", 0) != 0 && name.rfind("player", 0) != 0) continue;
		const size_t open = script.find('{', close);
		if (open == std::string::npos) continue;
		// AI blocks normally contain [OPTIONS]. Keep their own Team field,
		// skipping nested sections rather than discarding the entire AI.
		std::string body;
		int depth = 1;
		bool quoted = false, childHeader = false;
		for (size_t i = open + 1; i < script.size() && depth > 0; ++i) {
			const char ch = script[i];
			if (ch == '"' && script[i - 1] != '\\') quoted = !quoted;
			if (!quoted && ch == '{') { ++depth; continue; }
			if (!quoted && ch == '}') {
				--depth;
				if (depth == 1) { childHeader = false; body += ';'; }
				continue;
			}
			if (!quoted && depth == 1 && ch == '[') childHeader = true;
			if (depth == 1 && !childHeader) body += ch;
		}
		if (depth != 0) continue;
		std::map<std::string, std::string> vals;
		size_t s = 0;
		while (s < body.size()) {
			size_t semi = body.find(';', s);
			if (semi == std::string::npos) {
				semi = body.size();
			}
			const std::string item = body.substr(s, semi - s);
			const size_t eq = item.find('=');
			if (eq != std::string::npos) {
				std::string k = trim(item.substr(0, eq));
				std::transform(k.begin(), k.end(), k.begin(), ::tolower);
				vals[k] = trim(item.substr(eq + 1));
			}
			s = semi + 1;
		}
		if ((name.rfind("team", 0) == 0) && vals.count("startposx") && vals.count("startposz")) {
			const int id = std::atoi(name.c_str() + 4);
			SScriptStart st;
			st.pos = AIFloat3(std::atof(vals["startposx"].c_str()), 0.f, std::atof(vals["startposz"].c_str()));
			st.allyTeam = vals.count("allyteam") ? std::atoi(vals["allyteam"].c_str()) : -1;
			teams[id] = st;
		} else if ((name.rfind("ai", 0) == 0) && vals.count("team")) {
			playing.insert(std::atoi(vals["team"].c_str()));
		} else if ((name.rfind("player", 0) == 0) && vals.count("team")
			&& !(vals.count("spectator") && (std::atoi(vals["spectator"].c_str()) != 0)))
		{
			playing.insert(std::atoi(vals["team"].c_str()));
		}
	}
	for (const auto& kv2 : teams) {
		if (playing.count(kv2.first)) {
			scriptStarts.push_back(kv2.second);
		}
	}
	circuit->LOG("LANES: %i playing team start(s) in the start script", (int)scriptStarts.size());
}

int CSetupManager::GetScriptStartCount()
{
	ParseScriptStarts();
	return (int)scriptStarts.size();
}

AIFloat3 CSetupManager::GetScriptStart(int i)
{
	ParseScriptStarts();
	return ((i >= 0) && (i < (int)scriptStarts.size())) ? scriptStarts[i].pos : AIFloat3(-1.f, 0.f, 0.f);
}

bool CSetupManager::IsScriptStartEnemy(int i)
{
	ParseScriptStarts();
	return (i >= 0) && (i < (int)scriptStarts.size()) && (scriptStarts[i].allyTeam != circuit->GetAllyTeamId());
}

bool CSetupManager::CanChooseStartPos() const
{
	return setupData->CanChooseStartPos();
}

void CSetupManager::PickStartPos(StartPosType type)
{
	CAllyTeam* allyTeam = circuit->GetAllyTeam();
	const geom::CRegion& box = allyTeam->GetStartBox();
	AIFloat3 pos;

	switch (type) {
		case StartPosType::METAL_SPOT: {
			// 1) Select suitable factory to build
//			CBFactoryTask* factoryTask = circuit->GetEconomyManager()->PickNextFactory(-RgtVector, true);
//			if (factoryTask != nullptr) {
//				circuit->LOG("fac: %s | repr: %s", factoryTask->GetBuildDef()->GetDef()->GetName(), factoryTask->GetReprDef()->GetDef()->GetName());
//			}
//			circuit->GetTerrainManager()->GetMobileTypeById(factoryTask->GetReprDef()->GetMobileId())->sector;

			const CMetalData::Clusters& clusters = circuit->GetMetalManager()->GetClusters();
			const CMetalData::Metals& spots = circuit->GetMetalManager()->GetSpots();
			CTerrainManager* terrainMgr = circuit->GetTerrainManager();
			SMobileType* mobileType = terrainMgr->GetMobileTypeById(commChoice->GetMobileId());

			std::map<int, CMetalData::MetalIndices> validPoints;
			for (unsigned idx = 0; idx < clusters.size(); ++idx) {
				for (int i : clusters[idx].idxSpots) {
					// ZK has "ai_is_valid_startpos:123.12/321.32" command, @see LuaRules/Gadgets/start_boxes.lua
					if (!box.ContainsPoint(spots[i].position)) {
						continue;
					}

					const int iS = terrainMgr->GetSectorIndex(spots[i].position);
					SArea* area = mobileType->sector[iS].area;
					if ((area != nullptr) && area->areaUsable) {
						validPoints[idx].push_back(i);
					}
				}
			}

			if (!validPoints.empty()) {
				struct SCluster {
					unsigned count;
					float distDivIncome;
				};
				const AIFloat3 mapCenter = terrainMgr->GetTerrainCenter();
				std::vector<std::pair<int, SCluster>> validClusters;
				for (auto& kv : validPoints) {
					SCluster c;
					c.count = allyTeam->GetClusterTeam(kv.first).count;
					const CMetalData::SCluster& cl = clusters[kv.first];
					const float income = cl.income + (float)rand() / RAND_MAX - 0.5f;
					c.distDivIncome = mapCenter.distance(cl.position) / income;
					validClusters.push_back(std::make_pair(kv.first, c));
				}
				std::random_device rd;
				std::mt19937 g(rd());
				std::shuffle(validClusters.begin(), validClusters.end(), g);

				auto cmp = [](const std::pair<int, SCluster>& a, const std::pair<int, SCluster>& b) {
					if (a.second.count < b.second.count) {
						return true;
					} else if (a.second.count > b.second.count) {
						return false;
					}
					return a.second.distDivIncome < b.second.distDivIncome;
				};
				std::sort(validClusters.begin(), validClusters.end(), cmp);

				int clusterId = validClusters.front().first;
				allyTeam->OccupyCluster(clusterId, circuit->GetTeamId());

				const CMetalData::MetalIndices& indices = validPoints[clusterId];
				const CMetalData::SMetal& spot = spots[indices[rand() % indices.size()]];
				CCircuitDef* mexDef = circuit->GetEconomyManager()->GetSideInfo().mexDef;
				const float range = std::max(mexDef->GetDef()->GetXSize(), mexDef->GetDef()->GetZSize())
						* SQUARE_SIZE / 2 * 1.4f + commChoice->GetRadius();
				pos = MakeStartPosOffset(spot.position, clusterId, range);
			} else {
				pos = box.Random();
			}
		} break;
		case StartPosType::RANDOM:
		default: {
			pos = box.Random();
		} break;
	}

	pos.y = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
	SetBasePos(pos);
	circuit->GetGame()->SendStartPosition(false, pos);
}

void CSetupManager::SetBasePos(const AIFloat3& pos)
{
	basePos = pos;
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const AIFloat3 mapCenter = terrainMgr->GetTerrainCenter();
	AIFloat3 refPos;
//	if (circuit->GetMetalManager()->GetClusters().empty()) {
		refPos = pos;
//	} else {
//		int index = circuit->GetMetalManager()->FindNearestCluster(pos);
//		refPos = circuit->GetMetalManager()->GetClusters()[index].position;
//	}
	const AIFloat3 enemyDir = (mapCenter - refPos).Normalize2D();
	const AIFloat3 normal = AIFloat3(-enemyDir.z, 0, enemyDir.x) * ((rand() < RAND_MAX / 2) ? -1.f : 1.f);
	const AIFloat3 backPos = refPos - enemyDir * 400.f;
	metalBase = backPos + normal * 200.f;
	energyBase = backPos - normal * 200.f;
	energyBase2 = backPos - enemyDir * 400.f;
	CTerrainManager::CorrectPosition(metalBase);
	CTerrainManager::CorrectPosition(energyBase);
	CTerrainManager::CorrectPosition(energyBase2);

	AIFloat3 smallPos1 = basePos + normal * 200.f;
	AIFloat3 smallPos2 = basePos - normal * 200.f;
	CTerrainManager::CorrectPosition(smallPos1);
	CTerrainManager::CorrectPosition(smallPos2);
	smallEnergyPos = (terrainMgr->GetTAMinAltitude(smallPos1) > terrainMgr->GetTAMinAltitude(smallPos2)) ? smallPos1 : smallPos2;
}

void CSetupManager::FindNewBase(CCircuitUnit* unit)
{
	CInfluenceMap* inflMap = circuit->GetInflMap();
	CMetalManager* metalMgr = circuit->GetMetalManager();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const CMetalData::Clusters& clusters = metalMgr->GetClusters();
	CMetalData::PointPredicate pred = [inflMap, terrainMgr, unit, &clusters](const int index) {
		const AIFloat3& pos = clusters[index].position;
		return (inflMap->GetInfluenceAt(pos) > INFL_SAFE) && terrainMgr->CanReachAt(unit, pos, DEFAULT_SLACK);
	};
	const int clusterId = metalMgr->FindNearestCluster(basePos, pred);
	if (clusterId >= 0) {
		circuit->GetSetupManager()->SetBasePos(clusters[clusterId].position);
	}
}

bool CSetupManager::PickCommander()
{
	std::vector<CCircuitDef*> comms;
	float bestPower = .0f;

	if (commChoice == nullptr) {
		for (CCircuitDef& cdef : circuit->GetCircuitDefs()) {
			std::string lvl1 = cdef.GetDef()->GetName();
			if ((lvl1.find(commPrefix) != 0) || (lvl1.find(commSuffix) != lvl1.size() - 5)) {
				continue;
			}

			const std::map<std::string, std::string>& customParams = cdef.GetDef()->GetCustomParams();
			auto it = customParams.find("level");
			if ((it == customParams.end()) || (utils::string_to_int(it->second) != 1)) {
				continue;
			}
			comms.push_back(&cdef);

			if (bestPower < cdef.GetBuildDistance()) {  // No more UnitDef->GetAutoHeal() :(
				bestPower = cdef.GetBuildDistance();
				commChoice = &cdef;
			}
		}
		if (comms.empty()) {
			return false;
		}
	}

	std::string cmd("ai_commander:");
	cmd += ((commChoice == nullptr) ? comms[rand() % comms.size()] : commChoice)->GetDef()->GetName();
	circuit->GetLua()->CallRules(cmd.c_str(), cmd.size());

	return true;
}

void CSetupManager::SetCommander(CCircuitUnit* unit)
{
	commander = unit;
	if (unit == nullptr) {
		return;
	}
	commChoice = commander->GetCircuitDef();
	if (!geom::is_valid(basePos)) {
		SetBasePos(unit->GetPos(circuit->GetLastFrame()));
	}

	if (isSideSelected) {
		return;
	}
	auto it = sides.find(unit->GetCircuitDef()->GetId());
	if (it != sides.end()) {
		circuit->SetSide(it->second);
		isSideSelected = true;
	}
}

CAllyTeam* CSetupManager::GetAllyTeam() const
{
	return setupData->GetAllyTeam(circuit->GetAllyTeamId());
}

void CSetupManager::ReadConfig()
{
	const Json::Value& root = GetConfig();
	const std::string& cfgName = GetConfigName();

	antiCapProb = root["quota"].get("anti_cap", 2.0f).asFloat();

	const Json::Value& shield = root["retreat"]["shield"];
	emptyShield = shield.get((unsigned)0, 0.1f).asFloat();
	fullShield = shield.get((unsigned)1, 0.6f).asFloat();

	const Json::Value& comm = root["commander"];
	const Json::Value& items = comm["unit"];
	commPrefix = comm["prefix"].asString();
	commSuffix = comm["suffix"].asString();
//	std::vector<CCircuitDef*> commChoices;
//	commChoices.reserve(items.size());
//	float magnitude = 0.f;
	std::vector<float> weight;
	weight.reserve(items.size());

	for (const std::string& commName : items.getMemberNames()) {
		CCircuitDef* cdef = circuit->GetCircuitDef((commPrefix + commName + commSuffix).c_str());
		if (cdef == nullptr) {
			circuit->LOG("CONFIG %s: has unknown commander '%s'", cfgName.c_str(), commName.c_str());
			continue;
		}

//		commChoices.push_back(cdef);

		const Json::Value& comm = items[commName];
		const float imp = comm.get("importance", 0.f).asFloat();
//		magnitude += imp;
		weight.push_back(imp);

		const Json::Value& mrph = comm["upgrade"];
		SCommInfo& commInfo = commInfos[commName];
		SCommInfo::SMorph& morph = commInfo.morph;
		morph.frame = mrph.get("time", -1).asInt() * FRAMES_PER_SEC;

		const Json::Value& upgr = mrph["module"];
		morph.modules.reserve(upgr.size());
		for (const Json::Value& lvl : upgr) {
			std::vector<float> mdls;
			for (const Json::Value& m : lvl) {
				mdls.push_back(m.asFloat());
			}
			morph.modules.push_back(mdls);
		}

		const Json::Value& hhdd = comm["hide"];
		SCommInfo::SHide& hide = commInfo.hide;
		hide.frame = hhdd.get("time", -1).asInt() * FRAMES_PER_SEC;
		hide.threat = hhdd.get("threat", 0.f).asFloat();
		hide.isAir = hhdd.get("air", false).asBool();
		const Json::Value& taskRad = hhdd["task_rad"];
		hide.sqPeaceTaskRad = std::min(taskRad.get((unsigned)0, 2000.f).asFloat(), CTerrainManager::GetTerrainDiagonal() * 0.5f);
		if (hide.sqPeaceTaskRad > 0.f) {
			hide.sqPeaceTaskRad = SQUARE(hide.sqPeaceTaskRad);
		}
		hide.sqDangerTaskRad = SQUARE(taskRad.get((unsigned)1, 1000.f).asFloat());

		CCircuitDef* commDef = circuit->GetCircuitDef(commName.c_str());
		const std::string& commSide = comm.get("side", "").asString();
		sides[commDef->GetId()] = commSide;
		if (circuit->GetSideName() == commSide) {
			commChoice = commDef;
			assistFac = comm.get("assist_fac", 0).asInt();
		}
	}

//	if (!commChoices.empty()) {
//		unsigned choice = 0;
//		float dice = (float)rand() / RAND_MAX * magnitude;
//		for (unsigned i = 0; i < weight.size(); ++i) {
//			dice -= weight[i];
//			if (dice < 0.f) {
//				choice = i;
//				break;
//			}
//		}
//		commChoice = commChoices[choice];
//	}
}

bool CSetupManager::HasModules(const CCircuitDef* cdef, unsigned level) const
{
	std::string name = cdef->GetDef()->GetName();
	for (auto& kv : commInfos) {
		if (name.find(kv.first) != std::string::npos) {
			return kv.second.morph.modules.size() > level;
		}
	}
	return false;
}

const std::vector<float>& CSetupManager::GetModules(const CCircuitDef* cdef, unsigned level) const
{
	std::string name = cdef->GetDef()->GetName();
	for (auto& kv : commInfos) {
		if (name.find(kv.first) != std::string::npos) {
			const std::vector<std::vector<float>>& modules = kv.second.morph.modules;
			return modules[std::min<unsigned>(level, modules.size() - 1)];
		}
	}
	const std::vector<std::vector<float>>& modules = commInfos.begin()->second.morph.modules;
	return modules[std::min<unsigned>(level, modules.size() - 1)];
}

int CSetupManager::GetMorphFrame(const CCircuitDef* cdef) const
{
	std::string name = cdef->GetDef()->GetName();
	for (auto& kv : commInfos) {
		if (name.find(kv.first) != std::string::npos) {
			return kv.second.morph.frame;
		}
	}
	return -1;
}

const CSetupManager::SCommInfo::SHide* CSetupManager::GetHide(const CCircuitDef* cdef) const
{
	std::string name = cdef->GetDef()->GetName();
	for (auto& kv : commInfos) {
		if (name.find(kv.first) != std::string::npos) {
			return &kv.second.hide;
		}
	}
	return nullptr;
}

void CSetupManager::Welcome() const
{
	Info* info = circuit->GetSkirmishAI()->GetInfo();
	const char* name = info->GetValueByKey("name");
//	OptionValues* options = circuit->GetSkirmishAI()->GetOptionValues();
//	const char* value = options->GetValueByKey("version");
//	const char* version = (value != nullptr) ? value : info->GetValueByKey("version");
	delete info;
//	delete options;

	const int id = circuit->GetSkirmishAIId();
#ifdef DEBUG_LOG
	std::string welcome("/say "/*"a:"*/);
	welcome += std::string(name) + " " + std::string(version) +
			utils::int_to_string(id, " (%i)  Good fun, have luck!");
	circuit->GetGame()->SendTextMessage(welcome.c_str(), 0);
#else
	std::string welcome = std::string(name) + " " + std::string(version) +
			utils::int_to_string(id, " (%i) Initialized!");
	circuit->LOG("%s", welcome.c_str());
#endif
}

void CSetupManager::FindStart()
{
	if (geom::is_valid(startPos)) {
		circuit->GetScheduler()->RemoveJob(findStart);
		findStart = nullptr;

		for (StartFunc& func : startFuncs) {
			func(startPos);
		}

		circuit->GetScheduler()->RunJobAfter(CScheduler::GameJob(&CSetupManager::CalcLanePos, this), FRAMES_PER_SEC);
		return;
	}

	if (circuit->GetTeamUnits().empty()) {
		return;
	}

	CalcStartPos();
}

void CSetupManager::CalcStartPos()
{
	const int frame = circuit->GetLastFrame();
	AIFloat3 midPos = ZeroVector;
	for (auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		midPos += unit->GetPos(frame);
	}
	midPos /= circuit->GetTeamUnits().size();

	float minSqDist = std::numeric_limits<float>::max();
	AIFloat3 bestPos;
	for (auto& kv : circuit->GetTeamUnits()) {
		CCircuitUnit* unit = kv.second;
		const AIFloat3& pos = unit->GetPos(frame);
		float sqDist = pos.SqDistance2D(midPos);
		if (minSqDist > sqDist) {
			minSqDist = sqDist;
			bestPos = pos;
		}
	}
	SetStartPos(bestPos);
}

void CSetupManager::CalcLanePos()
{
	std::vector<std::pair<int, AIFloat3>> points;
	AIFloat3 midPos = ZeroVector;
	for (CCircuitAI* ai : circuit->GetGameAttribute()->GetCircuits()) {
		if (ai->IsInitialized() && (ai->GetAllyTeamId() == circuit->GetAllyTeamId())) {
			const AIFloat3& pos = ai->GetSetupManager()->GetBasePos();
			points.push_back(std::make_pair(ai->GetSkirmishAIId(), pos));
			midPos += pos;
		}
	}
	midPos /= points.size();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	float width = terrainMgr->GetTerrainWidth();
	float height = terrainMgr->GetTerrainHeight();
	AIFloat3 p1(width - width / 3, 0, height / 3);
	AIFloat3 p2(width / 3, 0, height / 3);
	AIFloat3 p3(width / 3, 0, height - height / 3);
	AIFloat3 p4(width - width / 3, 0, height - height / 3);
	AIFloat3 centerPos(width / 2, 0, height / 2);
	AIFloat3 step, offset;
	if ((midPos.x > p1.x && midPos.z < p1.z) || (midPos.x < p3.x && midPos.z > p3.z)) {  // I, III
		step = AIFloat3(width / (points.size() + 1), 0, height / (points.size() + 1));
		offset = AIFloat3(0, 0, 0);
	} else if ((midPos.x < p2.x && midPos.z < p2.z) || (midPos.x > p4.x && midPos.z > p4.z)) {  // II, IV
		step = AIFloat3(width / (points.size() + 1), 0, -height / (points.size() + 1));
		offset = AIFloat3(0, 0, height);
	} else if (std::fabs(centerPos.x - midPos.x) * height < std::fabs(centerPos.z - midPos.z) * width) {  // x-aligned (dX/dZ < w/h)
		step = AIFloat3(width / (points.size() + 1), 0, 0);
		offset = AIFloat3(0, 0, height / 2);
	} else {  // z-aligned
		step = AIFloat3(0, 0, height / (points.size() + 1));
		offset = AIFloat3(width / 2, 0, 0);
	}

	auto sqLenOfProjPointOnLine = [](const AIFloat3& p/*, const AIFloat3& v1*/, const AIFloat3& v2) {
		// simplified, v1 = ZeroPoint
		float e1x = v2.x/* - v1.x*/, e1z = v2.z/* - v1.z*/;  // v2-ZeroPoint
		float e2x = p.x/* - v1.x*/, e2z = p.z/* - v1.z*/;  // p-ZeroPoint
		float valDp = e1x * e2x + e1z * e2z;  // dotProduct(e1, e2)
		float sqLen = e1x * e1x + e1z * e1z;
		float resX = /*v1.x + */(valDp * e1x) / sqLen;
		float resZ = /*v1.z + */(valDp * e1z) / sqLen;
		return resX * resX + resZ * resZ;
	};
	std::vector<std::pair<int, float>> sortedPoints;
	for (const std::pair<int, AIFloat3>& pos : points) {
		sortedPoints.push_back(std::make_pair(pos.first, sqLenOfProjPointOnLine(pos.second, step)));
	}
	auto compare = [](const std::pair<int, float>& p1, const std::pair<int, float>& p2) {
		return p1.second < p2.second;
	};
	std::sort(sortedPoints.begin(), sortedPoints.end(), compare);
	int i = 0;
	while (i < (int)sortedPoints.size() && circuit->GetSkirmishAIId() != sortedPoints[i].first) {
		i++;
	}
	AIFloat3 bestPos = step * (i + 1) + offset;

	SetLanePos(bestPos);
#ifdef DEBUG_VIS
	circuit->GetDrawer()->AddPoint(basePos, utils::int_to_string(circuit->GetTeamId()).c_str());
	circuit->GetDrawer()->AddLine(basePos, lanePos);
	circuit->LOG("baseRange: %f", lanePos.distance2D(basePos));
#endif  // DEBUG_VIS

	// NOTE: #include "module/MilitaryManager.h"
	circuit->GetMilitaryManager()->SetBaseDefRange(lanePos.distance2D(basePos));

	// FIXME: Influence map gets broken
	// FIXED: @see CThreatMap::CopyDefs
	// FIXME: Authority should be first one who gets message from the engine
//	const AIFloat3 mapCenter = CTerrainManager::GetTerrainCenter();
//	CAllyTeam* allyTeam = circuit->GetAllyTeam();
//	if (mapCenter.SqDistance2D(lanePos) < mapCenter.SqDistance2D(allyTeam->GetAuthority()->GetSetupManager()->GetLanePos())) {
//		allyTeam->SetAuthority(circuit);
//	}
}

AIFloat3 CSetupManager::MakeStartPosOffset(const AIFloat3& pos, int clusterId, float range)
{
	// offset towards cluster center
	const AIFloat3 newPos = circuit->GetTerrainManager()->ShiftPos(commChoice, pos, clusterId, range);
	// check new position
	if (!geom::is_valid(newPos)) {
		return pos;
	}
	Lua* lua = circuit->GetLua();
	std::string cmd("ai_is_valid_startpos:");
	cmd += utils::int_to_string(newPos.x) + "/" + utils::int_to_string(newPos.z);
	std::string result = lua->CallRules(cmd.c_str(), cmd.size());
	if (result != "1") {
		return pos;
	}
	return newPos;
}

bool CSetupManager::LoadConfig(const std::string& profile, const std::vector<std::string>& parts)
{
	configName = profile;
	std::string dirname;

	/*
	 * Locate game-side config
	 */
	OptionValues* options = circuit->GetSkirmishAI()->GetOptionValues();
	const char* value = options->GetValueByKey("game_config");
	delete options;
	if ((value != nullptr) && StringToBool(value)) {
		dirname = utils::GetAIDataGameDir(circuit->GetSkirmishAI(), "config");
		config = ReadConfig(dirname, profile, parts, true);
		if (config != nullptr) {
			return true;
		} else {
			circuit->LOG("Game-side config: '%s' is missing!", (dirname + profile + SLASH).c_str());
		}
	}

	/*
	 * Locate AI config
	 */
	dirname = "config" SLASH;
	if (utils::LocatePath(circuit->GetCallback(), dirname)) {
		config = ReadConfig(dirname, profile, parts, false);
	} else {
		circuit->LOG("AI config: '%s' is missing!", (dirname + profile + SLASH).c_str());
	}
	return (config != nullptr);
}

Json::Value* CSetupManager::ReadConfig(const std::string& dirname, const std::string& profile,
		const std::vector<std::string>& parts, const bool isVFS)
{
	Json::Value* cfg = nullptr;
	bool isForceLoad = !isVFS;
	if (!isForceLoad) {
		for (const std::string& name : parts) {
			std::string filename = dirname + profile + SLASH + name + ".json";
			if (utils::FileExists(circuit->GetCallback(), filename)) {
				isForceLoad = true;
				break;
			}
		}
	}
	if (isForceLoad) {
		for (const std::string& name : parts) {
			std::string filename = dirname + profile + SLASH + name + ".json";
			auto cfgStr = utils::ReadFile(circuit->GetCallback(), filename);
			if (cfgStr.empty()) {
				filename = dirname + name + ".json";
				cfgStr = utils::ReadFile(circuit->GetCallback(), filename);
				if (cfgStr.empty()) {
					circuit->LOG("No config file! (%s)", filename.c_str());
					continue;
				}
			}
			circuit->LOG("Load config: %s", filename.c_str());
			cfg = ParseConfig(cfgStr, name, cfg);
		}
	}
	return cfg;
}

Json::Value* CSetupManager::ParseConfig(const std::string& cfgStr, const std::string& cfgName, Json::Value* cfg)
{
	Json::CharReader* reader = Json::CharReaderBuilder().newCharReader();
	JSONCPP_STRING errs;
	Json::Value json;
	bool ok = reader->parse(cfgStr.c_str(), cfgStr.c_str() + cfgStr.size(), &json, &errs);
	delete reader;
	if (!ok) {
		circuit->LOG("Malformed config format! (%s)\n%s", cfgName.c_str(), errs.c_str());
		return nullptr;
	}

	if (cfg == nullptr) {
		cfg = new Json::Value;
		*cfg = json;
	} else {
		UpdateJson(*cfg, json);
	}
	return cfg;
}

void CSetupManager::UpdateJson(Json::Value& a, Json::Value& b) {
	if (!a.isObject() || !b.isObject()) {
		return;
	}

	for (const auto& key : b.getMemberNames()) {
		if (a[key].isObject()) {
			UpdateJson(a[key], b[key]);
		} else {
			if (!a[key].isNull()) {
				// TODO: Make path for key
				circuit->LOG("Config override: %s", key.c_str());
			}
			a[key] = b[key];
		}
	}
}

void CSetupManager::OverrideConfig()
{
	/*
	 * Check startscript specific config
	 */
	OptionValues* options = circuit->GetSkirmishAI()->GetOptionValues();
	const char* value = options->GetValueByKey("json");
	std::string cfgStr = ((value != nullptr) && strlen(value) > 0) ? value : "";
	delete options;
	if (!cfgStr.empty()) {
		circuit->LOG("Override config %s by startscript", configName.c_str());
		config = ParseConfig(cfgStr, "startscript", config);
	}
}

} // namespace circuit
