/*
 * EconomyManager.h
 *
 *  Created on: Sep 5, 2014
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_MODULE_ECONOMYMANAGER_H_
#define SRC_CIRCUIT_MODULE_ECONOMYMANAGER_H_

#include "module/Module.h"
#include "util/AvailList.h"
#include "resource/MetalField.h"

#include "AIFloat3.h"

#include <set>
#include <map>
#include <vector>
#include <memory>
#include <cstdint>

namespace springai {
	class Resource;
	class Economy;
}

namespace circuit {

#define INCOME_SAMPLES	5
#define HIDDEN_STORAGE	.0f

extern const char* RES_NAME_METAL;
extern const char* RES_NAME_ENERGY;

class IBuilderTask;
class IMainJob;
class CBFactoryTask;
class CEnergyGrid;

class CEconomyManager final: public IModule {
public:
	friend class CEconomyScript;

	struct SEnergyCond {
		float score = -1.f;
		float metalIncome = -1.f;  // condition
		float energyIncome = -1.f;  // condition
		int limit = 0;
	};
	struct SSideInfo {
		CCircuitDef* mexDef;
		CCircuitDef* geoDef;
		CCircuitDef* defaultDef;
	};

	CEconomyManager(CCircuitAI* circuit);
	virtual ~CEconomyManager();

	void InitHandlers();
	void InitEconomyScores();
private:
	void ReadConfig(float& outMinEInc);
	void InitMetalField();
	void Init();

public:
	virtual int UnitCreated(CCircuitUnit* unit, CCircuitUnit* builder) override;
	virtual int UnitFinished(CCircuitUnit* unit) override;
	virtual int UnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	virtual int UnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) override;

	springai::Resource* GetMetalRes() const { return metalRes; }
	springai::Resource* GetEnergyRes() const { return energyRes; }
	CEnergyGrid* GetEnergyGrid() const { return energyGrid; }
	float GetClusterRange() const { return clusterRange; }
	float GetPylonRange() const { return pylonRange; }
	float GetMetalMake(CCircuitDef* cdef) const;  // script
	float GetEnergyMake(CCircuitDef* cdef) const;  // script
	float GetEnergyUse(CCircuitDef* cdef) const;  // script: converter consumption
	bool IsMetalMap() const { return metalMap; }
	bool IsMetalConverter(const CCircuitDef* cdef) const;
	int GetFieldMexCount(const springai::AIFloat3& center, float radius) const;
	float GetFieldYield(CCircuitDef* def, const springai::AIFloat3& pos);
	IBuilderTask* EnqueueFieldMex(CCircuitUnit* builder, const springai::AIFloat3& center, float radius);
	IBuilderTask* EnqueueFieldUpgrade(CCircuitUnit* builder, const springai::AIFloat3& center, float radius);
	bool ClaimFieldSite(metal_field::Key& key, CCircuitDef* def, const springai::AIFloat3& pos, int targetId = -1);
	bool OwnsFieldSite(metal_field::Key key) const;
	void ReleaseFieldSite(metal_field::Key key);
	bool SyncFieldUnits();
	int GetEffectiveUnitLimit() const;
	int GetMexSpotCountWithin(CCircuitUnit* builder, const springai::AIFloat3& center, float radius, int maxSpots);
	// D-086: the centroid of the maxSpots metal spots nearest center within radius
	// (0 = all); center itself when there is none. Known from the map at setup.
	springai::AIFloat3 GetMexCentroidWithin(const springai::AIFloat3& center, float radius, int maxSpots) const;

	// D-106: the latest economic state of every allied team (human or AI), kept
	// per team from the ally team's list (CAllyTeam::GetTeamIds, our own team
	// excluded) and refreshed on demand before a decision that needs it
	enum class TeamEcoField: int { CURRENT = 0, STORAGE, INCOME, USAGE, PULL, SHARE, SENT, RECEIVED, EXCESS, FREE, _SIZE_ };
	struct STeamRes {
		float v[static_cast<int>(TeamEcoField::_SIZE_)] = {};
	};
	struct STeamEco {
		int teamId = -1;
		int frame = -1;   // the frame of the last update, -1 never
		bool alive = false;   // metal income above 0 (the engine has no dead-team query for an AI)
		STeamRes metal, energy;
	};
	bool UpdateTeamEconomy(int teamId);   // false: not an ally, or our own team
	int UpdateAllTeamEconomy();           // how many teammates were updated
	int GetAllyTeamCount();               // teammates, our own team excluded
	int GetAllyTeamIdAt(int index);       // -1 out of range
	float GetTeamEco(int teamId, int resource, int field) const;   // resource 0 metal, 1 energy; -1 unknown
	int GetTeamEcoFrame(int teamId) const;
	bool IsTeamAlive(int teamId) const;
	bool SendResourceTo(int resource, float amount, int teamId);   // resource 0 metal, 1 energy
	// our own economy's fields the script lacked (D-106)
	float GetOwnEco(int resource, int field);
	int GetClaimedMexCountWithin(CCircuitUnit* builder, const springai::AIFloat3& center, float radius, int maxSpots);
	IBuilderTask* EnqueueMexWithin(CCircuitUnit* builder, const springai::AIFloat3& center, float radius, int maxSpots, bool allyAware = false, const std::vector<springai::AIFloat3>& excluded = {});
	// D-072: a metal spot belongs to the team whose start position is nearest
	// to it; the script feeds the allies' starts (the roster) and the ally-aware
	// mex enqueue leaves the others' spots alone.
	void ClearAllyStarts() { allyStarts.clear(); }
	void AddAllyStart(const springai::AIFloat3& pos) { allyStarts.push_back(pos); }
	bool IsOwnSpot(const springai::AIFloat3& pos);
	void SetMexOwnership(bool enabled, float seconds);
	void SetMexAllyStart(int team, const springai::AIFloat3& pos, int commander);
	bool CanReachMex(CCircuitUnit* builder, const springai::AIFloat3& pos);
	bool IsMexExpansionAllowed(const springai::AIFloat3& pos, bool allyAware);
	bool IsMexNavigationEnabled() const { return mexNavigationEnabled; }
	bool IsMexOwnershipActive() const;
	// Live mex tasks (assigned or queued) whose spot lies within radius of center (D-063).
	int GetMexTaskCountWithin(const springai::AIFloat3& center, float radius) const;
	CCircuitDef* GetLowEnergy(const springai::AIFloat3& pos, float& outMake, const CCircuitUnit* builder = nullptr) const;
	void AddEconomyDefs(const std::set<CCircuitDef*>& buildDefs);  // add available economy defs
	void RemoveEconomyDefs(const std::set<CCircuitDef*>& buildDefs);

	const SSideInfo& GetSideInfo() const;
	const std::vector<SSideInfo>& GetSideInfos() const { return sideInfos; }

	CCircuitDef* GetDefaultDef(CCircuitDef* conDef) { return defaultDefs[conDef->GetId()]; }
	CCircuitDef* GetPylonDef() const { return pylonDef; }

	void AddAssistDef(CCircuitDef* cdef) { assistDefs.AddDef(cdef); cdef->SetIsAssist(true); }
	void AddFactoryDef(CCircuitDef* cdef) { factoryDefs.AddDef(cdef); }
	bool IsFactoryDefAvail(CCircuitDef* buildDef) const { return factoryDefs.IsAvail(buildDef); }

	float GetAvgMetalIncome() const { return metal.income; }
	float GetAvgEnergyIncome() const { return energy.income; }
	float GetEcoFactor() const { return ecoFactor; }
	float GetEcoEM() const { return ecoEMRatio; }
	float GetPullMtoS() const { return pullMtoS; }
	float GetMetalCur();
	float GetMetalStore();
	float GetMetalPull();
	float GetEnergyCur();
	float GetEnergyStore();
	float GetEnergyPull();
	bool IsMetalEmpty() const { return isMetalEmpty; }
	bool IsMetalFull() const { return isMetalFull; }
	bool IsEnergyStalling() const { return isEnergyStalling; }
	bool IsEnergyEmpty() const { return isEnergyEmpty; }
	bool IsEnergyFull() const { return isEnergyFull; }
//	bool IsEnergyRequired() const { return isEnergyRequired; }
	void ClearEnergyRequired() { isEnergyRequired = false; }
	bool IsExcessed() const { return metalProduced > metalUsed; }
	int GetBuildDelay() const { return buildDelay; }

	bool IsAllyOpenMexSpot(int spotId) const;
	bool IsOpenMexSpot(int spotId) const;
	void SetOpenMexSpot(int spotId, bool value);
	bool IsUpgradingMexSpot(int spotId) const { return spotId >= 0 && std::size_t(spotId) < mexSpots.size() && mexSpots[spotId].isUp; }
	void SetUpgradingMexSpot(int spotId, bool value) { if (spotId >= 0 && std::size_t(spotId) < mexSpots.size()) mexSpots[spotId].isUp = value; }
	bool IsOpenGeoSpot(int spotId) const { return geoSpots[spotId].isOpen; }
	void SetOpenGeoSpot(int spotId, bool value) { geoSpots[spotId].isOpen = value; }
	bool IsUpgradingGeoSpot(int spotId) const { return geoSpots[spotId].isUp; }
	void SetUpgradingGeoSpot(int spotId, bool value) { geoSpots[spotId].isUp = value; }
	bool IsIgnorePull(const IBuilderTask* task) const;
	bool IsIgnoreStallingPull(const IBuilderTask* task) const;
	void CorrectResourcePull(float metal, float energy);
	float GetMetalPullCor() const { return metal.pull - metalPullCor; }
	float GetEnergyPullCor() const { return energy.pull - energyPullCor; }
	bool IsEnoughEnergy(IBuilderTask const* task, CCircuitDef const* conDef, float mod = 1.f) const;
	bool IsEnoughEnergyIncome(CCircuitDef const* buildDef, CCircuitDef const* conDef) const;

	IBuilderTask* MakeEconomyTasks(const springai::AIFloat3& position, CCircuitUnit* unit);
	IBuilderTask* UpdateMetalTasks(const springai::AIFloat3& position, CCircuitUnit* unit);
	IBuilderTask* UpdateReclaimTasks(const springai::AIFloat3& position, CCircuitUnit* unit, bool isNear = true);
	IBuilderTask* UpdateEnergyTasks(const springai::AIFloat3& position, CCircuitUnit* unit = nullptr);
	IBuilderTask* UpdateGeoTasks(const springai::AIFloat3& position, CCircuitUnit* unit = nullptr);
	IBuilderTask* UpdateFactoryTasks(const springai::AIFloat3& position, CCircuitUnit* unit = nullptr);
	IBuilderTask* UpdateFactoryTasks();
	IBuilderTask* UpdateStorageTasks();
	IBuilderTask* UpdatePylonTasks();
	IBuilderTask* CheckMobileAssistRequired(const springai::AIFloat3& position, CCircuitUnit* unit);
	void StartFactoryJob();
	CBFactoryTask* PickNextFactory(const springai::AIFloat3& position, bool isStart);

	void AddMorphee(CCircuitUnit* unit);
	void RemoveMorphee(CCircuitUnit* unit) { morphees.erase(unit); }
	void UpdateMorph();

	void AddFactoryInfo(CCircuitUnit* unit);
	void DelFactoryInfo(CCircuitUnit* unit);

private:
	bool CheckAirpadRequired(const springai::AIFloat3& position, CCircuitUnit* unit, IBuilderTask*& outTask);
	bool CheckAssistRequired(const springai::AIFloat3& position, CCircuitUnit* unit, IBuilderTask*& outTask);
	float GetStorage(springai::Resource* res);
	void UpdateResourceIncome();
	void UpdateEconomy();

	Handlers2 createdHandler;
	bool metalMap = false;
	float fieldLegacyEnergyRatio = 25.f, fieldHomeRadius = 2400.f;
	int fieldCandidateBudget = 96, fieldCellBudget = 16384;
	float fieldMinYieldFraction = 0.8f;
	std::map<int, int> fieldCursors;
	std::vector<int> fieldCells;
	std::set<int> fieldConverters;
	Handlers1 finishedHandler;
	EHandlers destroyedHandler;

	std::map<int, STeamEco> teamEco;   // D-106
	std::vector<int> allyTeamIds;      // D-106: sorted, our own team excluded
	void RefreshAllyTeamIds();
	springai::Resource* metalRes;
	springai::Resource* energyRes;
	springai::Economy* economy;
	CEnergyGrid* energyGrid;

	struct SClusterInfo {
		CCircuitUnit* factory;
		int metalFrame;
	};
	std::vector<SClusterInfo> clusterInfos;
	float clusterRange = 0.f;
	float pylonRange = 0.f;
	float pylonLinkInc = 0.f;
	CCircuitDef* pylonDef;  // TODO: Move into CEnergyGrid?

	std::unordered_map<CCircuitDef*, SEnergyCond> engyLimits;
	std::vector<SSideInfo> sideInfos;

	// FIXME: finished/destroyed handler is still a single function per DefId
	struct SPurpose {
		int count;  // economy role usage count
	};
	std::unordered_map<CCircuitDef::Id, SPurpose> purposes;
	void IncPurpose(const CCircuitDef::Id defId);
	void DecPurpose(const CCircuitDef::Id defId);
	bool HasNoPurpose(const CCircuitDef::Id defId) const;

	struct SStoreExt {
		float storage;
	};
	CAvailList<SStoreExt> storeMDefs, storeEDefs;

	std::unordered_map<CCircuitDef::Id, CCircuitDef*> defaultDefs;  // builder: default

	// NOTE: MetalManager::SetOpenSpot used by whole allyTeam. Therefore
	//       local spot's state descriptor needed for better expansion
	struct SResSpot {
		bool isOpen : 1;
		bool isUp : 1;  // spot being upgraded
	};
	std::vector<SResSpot> mexSpots;  // AI-local metal info
	int mexCount;
	std::vector<SResSpot> geoSpots;

	struct SMetalExt {
		float speed;
	};
	CAvailList<SMetalExt> metalDefs;

	struct SConvertExt {
		float energyUse;
		float make;
		bool isOld;  // clear space, don't build anymore
	};
	CAvailList<SConvertExt> convertDefs;
	void ReclaimOldConvert(const SConvertExt* convertExt);

	struct SGeoExt {
		float make;
	};
	CAvailList<SGeoExt> geoDefs;

	float costRatio = 0.f;
	struct SEnergyExt {
		float make;
		SEnergyCond cond;  // condition
		bool isOld;  // clear space, don't build anymore
	};
	CAvailList<SEnergyExt> energyDefs;
	void ReclaimOldEnergy(const SEnergyExt* energyExt);
	/*
	 * Script lever on the energy table (D-047). economy.json is shared by every
	 * role; a role that wants a different cap or income gate on one energy def
	 * sets it here after setup and nobody else is affected. -1 leaves a field.
	 */
public:
	void SetEnergyCondition(CCircuitDef* cdef, int limit, float metalIncome, float energyIncome);
	int GetEnergyLimit(CCircuitDef* cdef) const;
private:

	float ecoStep = 0.f;
	float ecoFactor = 0.f;
	float ecoEMRatio = 0.f;  // energy to metal ratio

	struct SEnergyFactorInfo {
		float startFactor;
		float endFactor;
		int startFrame;
		int endFrame;
		float fraction;
	} efInfo;
	float energyFactor = 0.f;

	struct SBuildDelayInfo {
		int startDelay;
		int endDelay;
		int startFrame;
		int endFrame;
		float fraction;
	} bdInfo;
	int buildDelay = 0;  // frames

	std::vector<float> metalIncomes;
	std::vector<float> energyIncomes;
	int indexRes;
	float metalProduced;
	float metalUsed;
	float metalMod = 0.f;
	int mexMax = 0;
	bool isAllyMexMax = false;
	unsigned numMexUp = 0;

	struct SPullMtoS {
		float pull;
		int mex;
		float fraction;
		inline bool operator< (const SPullMtoS& rhs) const { return mex < rhs.mex; }
		inline bool operator() (const SPullMtoS& lhs, const int rhs) const { return lhs.mex < rhs; }
	};
	std::vector<SPullMtoS> mspInfos;
	float pullMtoS = 0.f;  // mobile to static metal pull ratio

	bool isMetalEmpty;
	bool isMetalFull;
	bool isEnergyStalling;
	bool isEnergyEmpty;
	bool isEnergyFull;
	bool isEnergyRequired;
	float reclConvertEff;
	float reclEnergyEff;
	// Native assist nanos (CheckAssistRequired): a factory that "needs upgrade"
	// gets a HIGH-priority construction turret whenever income covers it. Per
	// instance, so a role can hand nano policy to its script (D-051).
	bool assistNanoEnabled = true;
	float assistNanoIncomeMod = 1.f;  // multiplies the income a new assist nano must be covered by
	bool holdStartFactory = false;  // TECH bootstrap: native factory scheduling waits
	bool autoStorageEnabled = true;  // TECH owns storage ordering in script
	bool reclaimOldConvertersAlways = false;  // TECH recycles T1 converters into advanced economy
	float startMexTravel;

	struct SResourceInfo {
		int pullFrame;
		float current;
		float storage;
		float pull;
		float income;
	} metal, energy;
	int metalPullCorFrame;
	float metalPullCor;
	int energyPullCorFrame;
	float energyPullCor;

	struct SAirpadExt {
	};
	CAvailList<SAirpadExt> airpadDefs;
	int airpadCount;

	struct SAssistExt {
	};
	CAvailList<SAssistExt> assistDefs;

	struct SFactoryExt {
	};
	CAvailList<SFactoryExt> factoryDefs;

	std::shared_ptr<IMainJob> startFactory;
	CBFactoryTask* factoryTask;

	std::shared_ptr<IMainJob> morph;
	std::set<CCircuitUnit*> morphees;
	std::vector<springai::AIFloat3> allyStarts;  // D-072
	bool mexNavigationEnabled = false;
	int mexOwnershipUntil = 0;
	struct SMexStart {
		springai::AIFloat3 pos;
		int definition = -1;
		std::uint64_t revision = 0;
		std::vector<float> distance;
	};
	// Stable start/definition values survive commander loss; never retain SArea
	// pointers across a terrain publication. Roster reconstructs these after load.
	std::map<int, SMexStart> mexStarts;
	std::vector<int> mexOwners;
	std::uint64_t mexOwnerRevision = 0;
	bool mexOwnersDirty = true;
	float MexStartDistance(SMexStart& start, const springai::AIFloat3& pos);
};

} // namespace circuit

#endif // SRC_CIRCUIT_MODULE_ECONOMYMANAGER_H_
