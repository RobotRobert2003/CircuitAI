/*
 * SetupManager.h
 *
 *  Created on: Dec 9, 2014
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_STATIC_SETUPMANAGER_H_
#define SRC_CIRCUIT_STATIC_SETUPMANAGER_H_

#include "setup/SetupData.h"
#include "unit/CircuitDef.h"
#include "json/json-forwards.h"

#include "AIFloat3.h"

#include <functional>

namespace circuit {

class CCircuitAI;
class CSetupScript;
class CAllyTeam;
class IMainJob;
class CCircuitUnit;

class CSetupManager final {
public:
	friend class CInitScript;
	friend class CSetupScript;

	enum class StartPosType: char {METAL_SPOT = 0, RANDOM = 1};
	// TODO: class CCommander;
	struct SCommInfo {
		struct SMorph {
			std::vector<std::vector<float>> modules;
			int frame;
		} morph;
		struct SHide {
			int frame;
			float threat;
			bool isAir;
			float sqPeaceTaskRad;
			float sqDangerTaskRad;
		} hide;
	};
	using StartFunc = std::function<void (const springai::AIFloat3& pos)>;

	CSetupManager(CCircuitAI* circuit, CSetupData* setupData);
	~CSetupManager();
	void DisabledUnits();

	bool OpenConfig(const std::string& profile, const std::vector<std::string>& parts);
	void CloseConfig();
	const Json::Value& GetConfig() const { return *config; }
	// D-126: the sections scripts read after init (the config is closed then)
	const Json::Value* GetScriptConfig() const { return (config != nullptr) ? config : scriptConfig; }
	const std::string& GetConfigName() const { return configName; }

	const CSetupData::ModOptions& GetModOptions() const;
	bool HasStartBoxes() const;
	// D-127: 1 inside an enemy ally team's start box, 0 not, -1 when no boxes are known
	int EnemyStartBoxAt(const springai::AIFloat3& pos) const;
	// D-127: the playing teams' start positions from the start script (fixed or chosen
	// before the game); a team counts when an AI or a non-spectator player is on it
	int GetScriptStartCount();
	springai::AIFloat3 GetScriptStart(int i);
	bool IsScriptStartEnemy(int i);
	// Part B1 (field landmarks): every playing team of the start script with its ally
	// team, and its start position when the script carries one (`known`)
	struct SScriptTeam { int team; int allyTeam; bool known; springai::AIFloat3 pos; };
	const std::vector<SScriptTeam>& GetScriptTeams();
	bool CanChooseStartPos() const;

	void PickStartPos(StartPosType type);
	void SetStartPos(const springai::AIFloat3& pos) { startPos = basePos = pos; }
	const springai::AIFloat3& GetStartPos() const { return startPos; }
	void SetBasePos(const springai::AIFloat3& pos);
	const springai::AIFloat3& GetBasePos() const { return basePos; }
	void SetLanePos(const springai::AIFloat3& pos) { lanePos = pos; }
	const springai::AIFloat3& GetLanePos() const { return lanePos; }
	const springai::AIFloat3& GetMetalBase() const { return metalBase; }
	const springai::AIFloat3& GetEnergyBase() const { return energyBase; }
	const springai::AIFloat3& GetEnergyBase2() const { return energyBase2; }
	const springai::AIFloat3& GetSmallEnergyPos() const { return smallEnergyPos; }
	void FindNewBase(CCircuitUnit* unit);
	void ExecOnFindStart(StartFunc& func) { startFuncs.push_back(func); }

	bool PickCommander();
	CCircuitDef* GetCommChoice() const { return commChoice; }
	void SetCommander(CCircuitUnit* unit);
	CCircuitUnit* GetCommander() const { return commander; }

	CAllyTeam* GetAllyTeam() const;

	void ReadConfig();
	bool IsAntiCap() const { return antiCapProb > (float)rand() / RAND_MAX; }
	float GetEmptyShield() const { return emptyShield; }
	float GetFullShield() const { return fullShield; }
	int GetAssistFac() const { return assistFac; }

	bool HasModules(const CCircuitDef* cdef, unsigned level) const;
	const std::vector<float>& GetModules(const CCircuitDef* cdef, unsigned level) const;
	int GetMorphFrame(const CCircuitDef* cdef) const;
	const SCommInfo::SHide* GetHide(const CCircuitDef* cdef) const;

	void Welcome() const;

	// Script hooks
	// TODO: Replace injected variables by
	//       separate struct containing setup-related
	//       script-defined states and values
	void SetWaterHarmful(bool value) { isWaterHarmful = value; }
	bool IsWaterHarmful() const { return isWaterHarmful; }

private:
	void ParseScriptStarts();
	struct SScriptStart { springai::AIFloat3 pos; int allyTeam; };
	std::vector<SScriptStart> scriptStarts;
	std::vector<SScriptTeam> scriptTeams;
	bool scriptStartsParsed = false;
	void FindStart();
	void CalcStartPos();
	void CalcLanePos();
	springai::AIFloat3 MakeStartPosOffset(const springai::AIFloat3& pos, int clusterId, float range);
	bool LoadConfig(const std::string& profile, const std::vector<std::string>& parts);
	Json::Value* ReadConfig(const std::string& dirName, const std::string& profile,
							const std::vector<std::string>& parts, const bool isVFS);
	Json::Value* ParseConfig(const std::string& cfgStr, const std::string& cfgName, Json::Value* cfg = nullptr);
	void UpdateJson(Json::Value& a, Json::Value& b);
	void OverrideConfig();

	CCircuitAI* circuit;
	CSetupData* setupData;
	CSetupScript* script;
	Json::Value* config;  // owner;
	Json::Value* scriptConfig;  // owner; D-126: "weapons" and "lanes", kept past CloseConfig
	std::string configName;

	CCircuitUnit* commander;
	springai::AIFloat3 startPos;
	springai::AIFloat3 basePos;
	springai::AIFloat3 lanePos;
	springai::AIFloat3 metalBase;
	springai::AIFloat3 energyBase;
	springai::AIFloat3 energyBase2;
	springai::AIFloat3 smallEnergyPos;
	std::shared_ptr<IMainJob> findStart;
	std::vector<StartFunc> startFuncs;

	float antiCapProb;
	float emptyShield;
	float fullShield;
	int assistFac;

	std::string commPrefix;
	std::string commSuffix;
	CCircuitDef* commChoice;
	std::map<std::string, SCommInfo> commInfos;
	bool isSideSelected;  // FIXME: Random-Side workaround

	std::map<CCircuitDef::Id, std::string> sides;  // comm: side

	bool isWaterHarmful;
};

} // namespace circuit

#endif // SRC_CIRCUIT_STATIC_SETUPMANAGER_H_
