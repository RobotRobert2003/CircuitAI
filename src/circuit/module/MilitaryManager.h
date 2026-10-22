/*
 * MilitaryManager.h
 *
 *  Created on: Sep 5, 2014
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_MODULE_MILITARYMANAGER_H_
#define SRC_CIRCUIT_MODULE_MILITARYMANAGER_H_

#include "module/TaskModule.h"
#include "setup/DefenceData.h"
#include "task/fighter/FighterTask.h"
#include "unit/CircuitDef.h"
#include "util/AvailList.h"

#include <vector>
#include <string>
#include <set>
#include <array>
#include <type_traits>

namespace circuit {

class IMainJob;
class CBDefenceTask;
class CFGuardTask;
class CRangedWorld;

namespace TaskF {
	struct SFightTask {
		IFighterTask::FightType type;
		IFighterTask::FightType check;
		IFighterTask::FightType promote;
		float power;
		CCircuitUnit* vip;
	};

	static inline SFightTask Common(IFighterTask::FightType type)
	{
		SFightTask ti;
		ti.type = type;

		ti.check = type;
		ti.promote = type;
		ti.power = 0.f;
		ti.vip = nullptr;
		return ti;
	}
	static inline SFightTask Guard(CCircuitUnit* vip)
	{
		SFightTask ti;
		ti.type = IFighterTask::FightType::GUARD;
		ti.vip = vip;
		return ti;
	}
	static inline SFightTask Defend(IFighterTask::FightType promote, float power)
	{
		SFightTask ti;
		ti.type = IFighterTask::FightType::DEFEND;
		ti.check = IFighterTask::FightType::_SIZE_;  // NONE
		ti.promote = promote;
		ti.power = power;
		return ti;
	}
	static inline SFightTask Defend(IFighterTask::FightType check, IFighterTask::FightType promote, float power)
	{
		SFightTask ti;
		ti.type = IFighterTask::FightType::DEFEND;
		ti.check = check;
		ti.promote = promote;
		ti.power = power;
		return ti;
	}
} // namespace TaskF

class CMilitaryManager final: public ITaskModule {
public:
	friend class CMilitaryScript;

	using BuildVector = std::vector<std::pair<CCircuitDef*, int>>;  // cdef: frame
	using SuperInfos = std::vector<std::pair<CCircuitDef*, float>>;  // cdef: weight
	struct SSideInfo {
		std::vector<CCircuitDef*> landDefenders;
		std::vector<CCircuitDef*> waterDefenders;
		BuildVector baseDefence;

		std::vector<CCircuitDef*> wallDefs;  // land and water
		std::vector<CCircuitDef*> chokeDefs;  // land and water
		CCircuitDef* defaultPorc;

		SuperInfos superInfos;
	};

	CMilitaryManager(CCircuitAI* circuit);
	virtual ~CMilitaryManager();

	void InitHandlers();
private:
	void ReadConfig();
	void InitEconomyScores(const std::vector<CCircuitDef*>&& builders);
	void Init();

public:
	virtual int UnitCreated(CCircuitUnit* unit, CCircuitUnit* builder) override;
	virtual int UnitFinished(CCircuitUnit* unit) override;
	virtual int UnitIdle(CCircuitUnit* unit) override;
	virtual int UnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	virtual int UnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) override;

	const std::set<IFighterTask*>& GetTasks(IFighterTask::FightType type) const {
		return fightTasks[static_cast<IFighterTask::FT>(type)];
	}

	IFighterTask* Enqueue(const TaskF::SFightTask& ti);
	IFighterTask* EnqueueGather(const TaskF::SFightTask& ti, const springai::AIFloat3& pos, int deadline);
	bool SetGatherPower(IUnitTask* task, float power);
	IUnitTask* EnqueueExternalControl(const std::string& ownerRule);
	IUnitTask* EnqueueCargoHold(int transportId);
	virtual CRetreatTask* EnqueueRetreat() override;

	/*
	 * Pulse-weapon target policy (Juno). A pulse weapon does no damage: its
	 * effect is a Lua gadget that deletes flagged defs inside the blast, so
	 * ranking enemy groups by metal cost aims it at armies it cannot hurt.
	 * Instead it picks the highest-priority sensor/EW target it can reach.
	 * Configured under "pulse" in behaviour.json; see doc/juno-targets.md.
	 */
	enum class PulseClass: int {JAMMER_ADVANCED = 0, JAMMER_STATIC, RADAR_ADVANCED, RADAR_STATIC, JAMMER_MOBILE, RADAR_MOBILE, _SIZE_};
	using PulseC = std::underlying_type<PulseClass>::type;
	struct SPulseInfo {
		bool isEnabled = false;  // false when the config names no usable role
		CCircuitDef::RoleM pulseRole = 0;  // defs that carry a pulse weapon
		CCircuitDef::RoleM jammerRole = 0;
		CCircuitDef::RoleM radarRole = 0;
		// rank[class] = priority, lower fires first; -1 excludes the class
		std::array<int, static_cast<PulseC>(PulseClass::_SIZE_)> rank = {-1, -1, -1, -1, -1, -1};
		std::map<int, int> targetClasses; // loaded vulnerable sensor properties, cached once
		std::set<int> unitDefs;
		int pendingFrames = 45 * FRAMES_PER_SEC;
		int coverageFrames = 90 * FRAMES_PER_SEC;
		bool scatter = true;
		float scatterStep = 384.f;
		float scatterDepth = 192.f;
		int mobileMaxAge = 0;  // frames a mobile target's last known position stays usable
		int minTargets = 1;    // do not spend a shot on fewer than this many targets
		/*
		 * Radar-hole inference. A jammer sits inside its own radardistancejam
		 * bubble (360-760 in BAR) and so hides itself from radar: it is only ever
		 * a known target when we have LOS on it, which in practice means a unit
		 * is already standing next to it. The inference runs the other way -
		 * ground we cover with radar, cannot see, believe is enemy-held, and read
		 * no contacts from, is probably jammed. The pulse AoE (1400) is wider
		 * than the widest jam radius, so hitting the hole tends to catch the
		 * jammer that made it. Known targets always outrank suspected ones.
		 */
		bool suspectJammer = true;
		float holeProbeRadius = 760.f;   // widest BAR jam radius: probe this far off a contact
		float holeRadius = 500.f;        // a probe with no contact inside this is a hole
		float holeMinEnemyInfl = 0.05f;  // only where we believe the enemy operates
		int holeProbes = 8;              // probe directions per known contact
	};
	const SPulseInfo& GetPulseInfo() const { return pulseInfo; }

	/*
	 * EMP-weapon target policy. A paralyzer deals no health damage: whether a
	 * shot does anything is `maxHealth < paralysisDamage * paralyzemultiplier`,
	 * so the policy computes the stun it would buy and rejects targets it
	 * cannot hold. Configured under "emp" in behaviour.json; see
	 * doc/emp-targets.md.
	 */
	struct SEmpInfo {
		bool isEnabled = false;
		CCircuitDef::RoleM empRole = 0;       // defs that carry an EMP weapon
		CCircuitDef::RoleM antiNukeRole = 0;  // the one class ranked above raw value
		int empableFlag = 0;                  // BAR EMPABLE category bit
		// modrules.paralyze.paralyzeDeclineRate: paralysis drains at
		// maxHealth / declineRate per second. 40 default, 20 with emprework.
		float declineRate = 40.f;
		float minStunSeconds = 5.f;  // do not spend a shot for less than this
		int mobileMaxAge = 0;        // frames a mobile's last known position stays usable
		int minTargets = 1;
		bool structuresFirst = true;  // only structures get an uncapped stun
		// Only structures at or above this cost keep their rank above mobiles;
		// cheaper ones compete with mobiles on cost. "Large statics first, then
		// the most expensive thing in range" - a 1 020-metal wall should not
		// outrank a 5 000-metal experimental just for being a building.
		float structuresFirstMinCost = 1500.f;
	};
	const SEmpInfo& GetEmpInfo() const { return empInfo; }

	/*
	 * Bomber policy. A bombing pass is alpha: it either kills or is wasted, so
	 * a group picks by value per HP, refuses targets it cannot finish, and
	 * chooses between concentrating on one target and spreading a line across
	 * a front. Configured under "bomber" in behaviour.json; see
	 * doc/bomber-targeting.md.
	 */
	struct SBomberInfo {
		bool isEnabled = false;
		// A target needing more than groupAlpha * killMargin is left for a
		// bigger group while any finishable target exists.
		float killMargin = 1.15f;
		// Concentrate the whole group on one target worth at least this much.
		float focusCost = 1500.f;
		// Spread into a line when this many candidates sit inside areaRadius.
		int areaMinTargets = 3;
		float areaRadius = 900.f;
		// Line geometry. Spacing is clamped into [minSpacing, 2 * weapon AoE]:
		// at the top of that range the bombs tile the front without overlap, at
		// the bottom a large group packs tight and concentrates damage.
		float minSpacing = 96.f;
		// How far past the front the run continues as an attack-move, so
		// survivors clean up and leave rather than circling over the AA.
		float cleanupDistance = 900.f;
		// Approach bearing: sample this many directions on a ring of this
		// radius around the aim point and run in from the quietest one.
		int approachSamples = 8;
		float approachRing = 1200.f;
		// Let bombers of different defs share one task, so a mixed wave forms
		// one line instead of several parallel groups.
		bool groupMixedDefs = true;
	};
	const SBomberInfo& GetBomberInfo() const { return bomberInfo; }

	/*
	 * Stockpile patience. A stockpiled super weapon - nuke, EMP, Juno - only
	 * fires at a group worth at least its shot cost. That floor treats metal
	 * that is ALREADY SPENT as the price of firing, and group value is only
	 * what the AI can currently see, so a silo sat with three missiles while
	 * a discovered base "was not worth it" and died with them. The floor now
	 * decays with how long a shot has been waiting, and collapses once enough
	 * shots are stocked: a wave of a poor target beats a full tube.
	 * Configured under "stockpile" in behaviour.json.
	 */
	struct SStockInfo {
		float patienceSeconds = 240.f;  // floor decays from 1.0 to minFraction over this
		float minFraction = 0.25f;      // never below this fraction of the shot cost
		int fullFireCount = 2;          // at this many stocked, the floor is minFraction now
		// Regional stockpiled launchers (Perdition, Catalyst) aim by unit scan,
		// CSuperTask::SelectLauncherTarget, not by enemy-group centroid.
		int launcherMobileMaxAge = 900;       // frames a mobile's last known position stays usable
		int launcherMinTargets = 1;           // raise to require a clump inside the blast
		bool launcherStructuresFirst = false; // rank any structure above any mobile
	};
	const SStockInfo& GetStockInfo() const { return stockInfo; }
	struct SNuclearInfo {
		bool structuresOnly = true;
		int repeatFrames = 300 * FRAMES_PER_SEC;
		float repeatRadius = 0.f; // zero uses the loaded blast radius
	};
	const SNuclearInfo& GetNuclearInfo() const { return nuclearInfo; }

	/*
	 * Mobile sensor escort policy. Mobile radar and jammer units carry the
	 * `support` main role, and CSupportTask walks each of them to the *nearest*
	 * squad and joins it outright, with no cap - so every sensor on the map
	 * converges on whichever squad happens to be closest (27 radar bots trailing
	 * one sharpshooter in a game on Eight Horses).
	 *
	 * One sensor per squad is all a squad can use: a second jammer adds no
	 * coverage a squad moving as one body does not already have, and a second
	 * radar bot is a duplicate of the first. So the escort is rationed - at most
	 * `max_per_squad` per squad, and the scarce sensors go to the squads worth
	 * covering first, ranked by the value of the squad's leader, which is the
	 * highest-tier unit in it. A sensor with nowhere to go holds near base
	 * rather than joining a squad that is already covered.
	 *
	 * Configured under "sensor" in behaviour.json; see doc/sensor-escort.md.
	 */
	struct SSensorInfo {
		bool isEnabled = false;
		CCircuitDef::RoleM sensorRole = 0;  // jammer | radar: the rationed defs
		int maxPerSquad = 1;   // "unless it dies": the count is of live assignees
		int topCandidates = 3;  // aim at the nearest of the N most valuable squads
		bool rebalance = true;  // release the surplus when two escorted squads merge
	};
	const SSensorInfo& GetSensorInfo() const { return sensorInfo; }
	// A def whose escort is rationed: a mobile radar or jammer.
	bool IsSensorUnit(const CCircuitDef* cdef) const;
	// Live sensors already escorting `task`.
	int CountSensors(const IFighterTask* task) const;
	// Room for one more sensor in `task`.
	bool NeedsSensor(const IFighterTask* task) const;
	// Guard priority: the metal cost of the squad leader, which is the
	// highest-tier unit the squad has. 0 for a squad with no leader.
	float GetSquadValue(const IFighterTask* task) const;

	/*
	 * Porcupine chain, by side. The defaults come from build_chain.json's
	 * "porcupine" block; these let AngelScript read that chain and replace it,
	 * so a role can order its own defences and react to mod options (Legion,
	 * the Extra Units Pack) without the ordering being frozen in JSON.
	 * Names, not defs, because that is what script works in.
	 */
	std::vector<std::string> GetPorcChain(const std::string& sideName, bool isWater) const;
	bool SetPorcChain(const std::string& sideName, bool isWater, const std::vector<std::string>& names);
	// Stocked EMP silos, an upper bound on how many shots can land together.
	int GetEmpSalvoSize() const;
private:
	virtual void DequeueTask(IUnitTask* task, bool done = false) override;

public:
	void MarkGuardUnit(CCircuitUnit* vip, CFGuardTask* task) {
		guardTasks[vip] = task;
	}

	void MakeDefence(const springai::AIFloat3& pos);
	void MakeDefence(int cluster);
	void MakeDefence(int cluster, const springai::AIFloat3& pos);
	void DefaultMakeDefence(int cluster, const springai::AIFloat3& pos);
	void MarkPorc(CCircuitUnit* unit, int defPointId);
	void UnmarkPorc(CCircuitUnit* unit);
	void AbortDefence(const CBDefenceTask* task, int defPointId);
	bool HasDefence(int cluster);
	void ProcessHubDefence(CBDefenceTask* task);
	springai::AIFloat3 GetScoutPosition(CCircuitUnit* unit);
	springai::AIFloat3 GroundObjective(CCircuitUnit* unit, const springai::AIFloat3& previous);
	void ClearScoutPosition(IUnitTask* task);
	void FillFrontPos(CCircuitUnit* unit, F3Vec& outPositions);
	void FillAttackSafePos(CCircuitUnit* unit, F3Vec& outPositions);
	void FillStaticSafePos(CCircuitUnit* unit, F3Vec& outPositions);
	void FillSafePos(CCircuitUnit* unit, F3Vec& outPositions);
	CCircuitUnit* GetClosestLeader(const std::vector<IFighterTask::FightType>& types, const springai::AIFloat3& position);

	IFighterTask* GetGuardTask(CCircuitUnit* unit) const;

	const std::set<CCircuitUnit*>& GetRoleUnits(CCircuitDef::RoleT type) const {
		return roleInfos[type].units;
	}
	float GetRoleCost(CCircuitDef::RoleT type) const { return roleInfos[type].cost; }
	void AddResponse(CCircuitUnit* unit);
	void DelResponse(CCircuitUnit* unit);
	float GetArmyCost() const { return armyCost; }
    void SetAggressionDelta(float value);
    float GetAggressionDelta() const { return aggressionDelta; }
    void SetAutomaticAggression(float value);
    float GetAutomaticAggression() const { return automaticAggression; }
    float GetAggression() const { return automaticAggression + aggressionDelta; }
	float RoleProbability(const CCircuitDef* cdef) const;
	bool IsNeedBigGun(const CCircuitDef* cdef) const;
	springai::AIFloat3 GetBigGunPos(CCircuitDef* bigDef) const;
	void DiceBigGun();
	float ClampMobileCostRatio() const;
	void UpdateDefenceTasks();
	void UpdateSensorGuards();
	/*
	 * Where this AI is currently fighting: the leader position of the strongest
	 * ATTACK squad, or the enemy centroid when we have no attack squad, or an
	 * invalid position when neither exists. Script has no other way to see the
	 * front - it can reach neither the fighter tasks nor CEnemyManager's groups -
	 * and the spam routes need it to run their lanes through the fight rather
	 * than straight at the enemy start. See doc/spam-routes.md.
	 */
	springai::AIFloat3 GetCombatFocusPos() const;
	float GetMinAttackers() const { return minAttackers; }
	float GetAttackWaitSeconds() const { return attackWaitSeconds; }
	float GetAttackScale() const { return attackScale; }
	void UpdateDefence();
	void MakeBaseDefence(const springai::AIFloat3& pos);

	void AddSensorDefs(const std::set<CCircuitDef*>& buildDefs);  // add available sensor defs
	void RemoveSensorDefs(const std::set<CCircuitDef*>& buildDefs);

	const SSideInfo& GetSideInfo() const;
	const std::vector<SSideInfo>& GetSideInfos() const { return sideInfos; }

	CCircuitDef* GetBigGunDef() const { return bigGunDef; }
	CCircuitDef* GetDefaultPorc() const { return GetSideInfo().defaultPorc; }
	CCircuitDef* GetLowSonar(const CCircuitUnit* builder = nullptr) const;

	void SetBaseDefRange(float range) { defence->SetBaseRange(range); }
	float GetBaseDefRange() const { return defence->GetBaseRange(); }
	float GetCommDefRadBegin() const { return defence->GetCommRadBegin(); }
	float GetCommDefRad(float baseDist) const { return defence->GetCommRad(baseDist); }
	unsigned int GetGuardTaskNum() const { return defence->GetGuardTaskNum(); }
	unsigned int GetGuardsNum() const { return defence->GetGuardsNum(); }
	int GetGuardFrame() const { return defence->GetGuardFrame(); }

	void AddPointOfInterest(CEnemyInfo* enemy) { PointOfInterest(enemy, +3, -1); }
	void DelPointOfInterest(CEnemyInfo* enemy) { PointOfInterest(enemy, -3, +1); }

	// TODO: Create CMilitaryManager::CTargetManager and move all FindTarget variations there.
	//       CMilitaryManager must be responsible for target selection.
	CEnemyInfo* FindBCombatTarget(CCircuitUnit* unit, const springai::AIFloat3& pos,
								  float powerMod, bool isTest);

	float GetRangeUnitCountCompensatorScale();
	IUnitTask* TryMakeRangedTask(CCircuitUnit* unit);
	std::shared_ptr<CRangedWorld> GetRangedWorld();
	bool HasRangedUnits() const;

private:
	std::shared_ptr<CRangedWorld> rangedWorld;
    float aggressionDelta=0.f, automaticAggression=0.f;
    IUnitTask* MakeTask(CCircuitUnit* unit) override;
    void UpdateExternalControl();
    std::string externalOwnerRule;
    std::unordered_set<int> externalOwnerDefinitions;
    std::set<int> externalOwnerCandidates;
    std::vector<int> externalOwnerSnapshot;
	virtual IUnitTask* DefaultMakeTask(CCircuitUnit* unit) override;

	void Watchdog();

	void AddArmyCost(CCircuitUnit* unit);
	void DelArmyCost(CCircuitUnit* unit);
	void PointOfInterest(CEnemyInfo* enemy, int start, int step);
	CDefenceData::SDefPoint* FindClosestDefPoint(const springai::AIFloat3& pos);
	CDefenceData::SDefPoint* FindClosestDefPoint(int cluster, const springai::AIFloat3& pos,
			std::function<bool (const CDefenceData::SDefPoint&)> predicate = nullptr);

	Handlers2 createdHandler;
	Handlers1 finishedHandler;
	Handlers1 idleHandler;
	EHandlers damagedHandler;
	EHandlers destroyedHandler;

	std::vector<std::set<IFighterTask*>> fightTasks;

	CDefenceData* defence;
	unsigned int defenceIdx;
	std::map<CCircuitUnit*, int> porcToPoint;  // unit: defPointId

	struct SScoutPoint {
		int spotNum;  // last used spot number in cluster
		int scouted;  // times this point was scouted
		int score;
		int enemyNum;
		IUnitTask* task;
	};
	std::vector<SScoutPoint> scoutPoints;  // list of clusters, index = custerId
	std::map<IUnitTask*, int> scoutTasks;  // task: clusterId
	bool isEnemyFound;

	struct SRoleInfo {
		float cost;
		float maxPerc;
		float factor;
		std::set<CCircuitUnit*> units;
		struct SVsInfo {
			CCircuitDef::RoleT role;
			float ratio;
			float importance;
		};
		std::vector<SVsInfo> vs;
	};
	std::vector<SRoleInfo> roleInfos;
	// Script hooks
	const SRoleInfo* GetRoleInfo(CCircuitDef::RoleT type) const { return &roleInfos[type]; }

	std::set<CCircuitUnit*> stockpilers;
	std::set<CCircuitUnit*> army;
	float armyCost;

	std::map<CCircuitUnit*, CFGuardTask*> guardTasks;

	struct SRaidQuota {
		float min;
		float avg;
	} raid;
	unsigned int maxScouts = 0;
	float minAttackers = 0.f;
	/*
	 * Attack-wave policy, script-set through quota.attackWait / quota.attackScale.
	 * attackScale > 0 switches a DEFEND squad's promotion bar from the map-wide
	 * second-strongest enemy group to the strongest group the squad can
	 * actually REACH, scaled - a naval squad no longer waits to outweigh a land
	 * army it will never meet. attackWaitSeconds > 0 promotes a squad that has
	 * waited that long at or above minAttackers. Both 0 = legacy behaviour.
	 */
	float attackWaitSeconds = 0.f;
	float attackScale = 0.f;
	struct SThreatQuota {
		float min;
		float len;
	} attackMod, defenceMod;

	struct SThreatRangeScaling {
		int enemyCountPerEnemyTeamToStartScaling = 0;
		int enemyCountPerEnemyTeamToEndScaling = 1;
		float endScaleValue = 1.f;
		float scale = 1.f;  // cache per frame
		int frame = -1;
	} threatRangeScaling;

	SPulseInfo pulseInfo;
	SEmpInfo empInfo;
	SBomberInfo bomberInfo;
	SStockInfo stockInfo;
	SNuclearInfo nuclearInfo;
	SSensorInfo sensorInfo;

	unsigned int preventCount = 0;
	float amountFactor = 0.f;
	// Script overrides read by DefaultMakeDefence (aiMilitaryMgr.porcMode / porcBudgetMod,
	// set per call by Military::Porc in data/script/src/manager/porc_policy.as):
	// mode 0 keeps the native front-line heuristic, 1 forces the preventive count,
	// 2 forces the full porcupine order; budgetMod scales the per-point income budget.
	int porcMode = 0;
	float porcBudgetMod = 1.f;
	// aiMilitaryMgr.porcAllyAA: when set, the porc pass also visits clusters
	// inside an ALLY's zone and builds only anti-air there. An AIR role's whole
	// value to its team is air denial, and its teammates' clusters are where
	// the enemy air actually goes. Ground defence in an ally's zone stays off:
	// that is the ally's own porc.
	int porcAllyAA = 0;
	CCircuitDef* bigGunDef;

	std::vector<SSideInfo> sideInfos;

	struct SSensorExt {
		float radius;
	};
	CAvailList<SSensorExt> radarDefs, sonarDefs;

	std::shared_ptr<IMainJob> defend;
	std::vector<std::pair<springai::AIFloat3, BuildVector>> buildDefence;  // pos: defences
};

} // namespace circuit

#endif // SRC_CIRCUIT_MODULE_MILITARYMANAGER_H_
