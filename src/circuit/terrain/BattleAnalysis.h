/*
 * BattleAnalysis.h
 *
 * D-126: the battlefield analysis TECH's weapon clusters are placed by
 * (doc/roles/tech-weapon-clusters.md). Pure queries: nothing here orders a
 * unit, so no other role changes. The script (roles/tech_weapons.as) is the
 * only caller.
 *
 * - Effective range with height: the engine's own formulas (Weapon.cpp
 *   TestRange, Cannon.cpp GetStaticRange2D).
 * - Approach routes: a 64-elmo grid, Dijkstra from our base, one path to each
 *   enemy source, repeated with the used cells penalised for alternatives;
 *   path density is the route heat. Chokes are route cells whose clearance
 *   (distance to impassable ground) is a local minimum.
 * - Combat and air heat: decaying grids fed by our losses and damage and by
 *   the enemy units we know of.
 * - Enemy composition by movement class and role.
 * - Water: seabed depth, bodies of water 8 and 15 deep, which are hostile,
 *   beach segments and their classes, and the torpedo site rule.
 */

#ifndef SRC_CIRCUIT_TERRAIN_BATTLEANALYSIS_H_
#define SRC_CIRCUIT_TERRAIN_BATTLEANALYSIS_H_

#include "AIFloat3.h"
#include "terrain/LaneSolver.h"

#include <vector>
#include <unordered_map>
#include <string>
#include <chrono>
#include <memory>
#include "terrain/RangedGeometry.h"

namespace circuit {

class CCircuitAI;
class CCircuitDef;
class CWeaponDef;

class CBattleAnalysis final : public std::enable_shared_from_this<CBattleAnalysis> {
public:
	friend class CInitScript;

	// Enemy composition classes (EnemyCost(kind)); tech_weapons.as mirrors them.
	enum Kind: int {LAND = 0, AIR, SHIP, SUB, HOVER, AMPH, ARTY, STATIC_DEF, HEAVY, NUKE, LRPC, _KIND_SIZE_};
	// Beach class flags (GetBeachClass)
	enum Beach: int {CLIFF = 1, WADING = 2, SHIP_WATER = 4, DEEP_WATER = 8, HOVER_BEACH = 16};
	// Lane classes (D-127), least capable first: a lane is kept under the first class that finds it.
	enum LaneClass: int {L_LAND = 0, L_BOT, L_AMPH, L_HOVER, L_ALLTERRAIN, L_NAVAL, L_AIR, _LANE_CLASSES_};

	CBattleAnalysis(CCircuitAI* circuit);
	~CBattleAnalysis();

	void Update(int frame);   // every second from CCircuitAI::Update
	void OnOwnDamaged(const springai::AIFloat3& pos);
	void OnOwnLost(const springai::AIFloat3& pos, float cost);
	void OnEnemyLost(const springai::AIFloat3& pos, float cost);
	void SetHeatHalfLife(float combatSec, float airSec) { combatHalfLife = combatSec; airHalfLife = airSec; }

	// --- terrain and range
	float Height(const springai::AIFloat3& pos) const;
	float Depth(const springai::AIFloat3& pos) const { return -Height(pos); }
	float EffectiveRange(const CCircuitDef* cdef, const springai::AIFloat3& from, const springai::AIFloat3& to) const;
	float MainRange(const CCircuitDef* cdef) const;   // the longest-range weapon's range
	float InterceptorCoverage(const CCircuitDef* cdef) const;
	float ShotEnergy(const CCircuitDef* cdef) const;   // energy one shot (salvo) takes from storage
	float ShotReload(const CCircuitDef* cdef) const;
	bool LineOfFire(const springai::AIFloat3& from, const springai::AIFloat3& to, float muzzle) const;
	float HeightAbove(const springai::AIFloat3& pos, float radius) const;  // height minus the ring's mean at radius

	// --- routes and chokes
	void ClearSources() { sources.clear(); }
	void AddSource(const springai::AIFloat3& pos) { sources.push_back(pos); }
	int Analyse(const springai::AIFloat3& base, int alternatives, float chokeMaxHalfWidth, float chokeMerge);
	bool IsAnalysed() const { return analysed; }
	float RouteHeat(const springai::AIFloat3& pos) const;
	float RouteShare(const springai::AIFloat3& pos) const;   // 0 at our base, 1 at the enemy source
	bool IsFriendlyLane(const springai::AIFloat3& pos) const;
	int GetChokeCount() const { return (int)chokes.size(); }
	springai::AIFloat3 GetChokePos(int i) const;
	springai::AIFloat3 GetChokeDir(int i) const;   // unit vector toward the enemy
	float GetChokeWidth(int i) const;
	float GetChokeHeat(int i) const;
	float GetChokeShare(int i) const;
	int GetRouteCount() const { return (int)routes.size(); }
	springai::AIFloat3 GetRoutePoint(int route, float share) const;   // a point along a route, by share

	// --- combat, air, composition
	float CombatHeat(const springai::AIFloat3& pos, float radius) const;
	springai::AIFloat3 CombatNear(const springai::AIFloat3& from, float minHeat) const;   // -1 x when none
	float AirHeat(const springai::AIFloat3& pos, float radius) const;
	springai::AIFloat3 AirCentre(const springai::AIFloat3& pos, float radius) const;   // -1 x when none
	float EnemyCost(int kind) const;
	// Explicitly requested local, visible naval composition. No role policy here.
	void SampleNavalThreat(const springai::AIFloat3& origin, float radius);
	float GetNavalThreatCost(int kind) const { return kind >= 0 && kind < 4 ? navalThreatCost[kind] : 0.f; }
	int EnemyCount(int kind) const;
	float SurfThreat(const springai::AIFloat3& pos) const;
	float AirThreat(const springai::AIFloat3& pos) const;
    float AirThreatAlong(const springai::AIFloat3& from, const springai::AIFloat3& to, float padding) const;
    bool InLos(const springai::AIFloat3& pos) const;
    std::vector<springai::AIFloat3> SafeAirRoute(const springai::AIFloat3& from,
        const springai::AIFloat3& to, float maxThreat, float padding);
    // Opt-in completed combat navy/factory snapshot. Flags: allied=1,
    // submerged=2, anti-sub weapon=4, factory=8. No role decisions here.
    int GetNavalForceCount();
    int GetNavalForceId(int index) const;
    int GetNavalForceDefId(int index) const;
    int GetNavalForceFlags(int index) const;
    int GetNavalForceBody(int index) const;
    float GetNavalForceCost(int index) const;
    springai::AIFloat3 GetNavalForcePos(int index) const;
    // SEA-only extension: legal unidentified sonar contacts (flags 16|2) and
    // visible water statics. AIR retains its original snapshot and cadence.
    int GetSeaForceCount();
    bool OutsideStaticWaterWeapons(const springai::AIFloat3& position, float padding, float formationRadius);
    int GetSeaForceId(int i) const { return i>=0 && i<int(seaForces.size()) ? seaForces[i].id : -1; }
    int GetSeaForceDefId(int i) const { return i>=0 && i<int(seaForces.size()) ? seaForces[i].defId : -1; }
    int GetSeaForceFlags(int i) const { return i>=0 && i<int(seaForces.size()) ? seaForces[i].flags : 0; }
    int GetSeaForceBody(int i) const { return i>=0 && i<int(seaForces.size()) ? seaForces[i].body : -1; }
    float GetSeaForceCost(int i) const { return i>=0 && i<int(seaForces.size()) ? seaForces[i].cost : 0.f; }
    springai::AIFloat3 GetSeaForcePos(int i) const { return i>=0 && i<int(seaForces.size()) ? seaForces[i].pos : springai::AIFloat3(-1.f,0.f,-1.f); }
	int GetAirContactCount() const { return static_cast<int>(airContacts.size()); }
    int GetAirContactId(int index) const { return index >= 0 && static_cast<size_t>(index) < airContacts.size() ? airContacts[index].id : -1; }
	springai::AIFloat3 GetAirContactPos(int index) const;
	float GetAirContactCost(int index) const;
    bool IsAirContactArmed(int index) const;
    float GetArmedAirCost() const;
    float AmphThreat(const springai::AIFloat3& pos) const;
    int GetGroundContactCount() const { return static_cast<int>(groundContacts.size()); }
    int GetGroundContactId(int index) const;
    int GetGroundContactDefId(int index) const;
    springai::AIFloat3 GetGroundContactPos(int index) const;
    float GetGroundContactCost(int index) const;
    bool IsGroundContactEconomy(int index) const;
    // D-296: economy kind flags of a ground contact (static only), O(1).
    enum ContactKind: int {K_MEX = 1, K_WIND = 2, K_NANO = 4, K_OTHER_ECO = 8};
    int GetGroundContactKind(int index) const;
    // D-296: observed armed-ground-weapon coverage dilated by margin, from the
    // current ground snapshot; independent of profile threat multipliers.
    // Lazily rebuilt at most once per Update publication (and per margin).
    float GroundHazard(const springai::AIFloat3& pos, float margin);
    // D-296: a route for the unit's movement class on the shared lane grid
    // (bots L_BOT, vehicles L_LAND, hovers L_HOVER) with that hazard layer as an
    // cell penalty floor (hazardWeight per covered cell). Optional hard
    // avoidance blocks covered cells; callers use soft escape from a covered
    // starting region. The per-definition fine grid was rejected: it found no connection
    // across glitters for a Tick the engine walks, and cost ~255 ms per build.
    std::vector<springai::AIFloat3> GetUnitRaidRoute(const CCircuitDef* def,
        const springai::AIFloat3& from, const springai::AIFloat3& to, float hazardMargin, float hazardWeight,
        bool avoidHazards = false);
    int GetNavalContactCount() const { return static_cast<int>(navalContacts.size()); }
    springai::AIFloat3 GetNavalContactPos(int index) const;
    // Completed allied extractors, geothermal plants and factories. Lazy value
    // snapshot: no borrowed unit/definition escapes and no enemy omniscience.
    int GetAllyAssetCount();
    springai::AIFloat3 GetAllyAssetPos(int index) const;
    float GetAllyAssetCost(int index) const;
    std::vector<springai::AIFloat3> GetTerrainRoute(const springai::AIFloat3& from,
        const springai::AIFloat3& to, int cls, float landCost, float waterCost,
        float threatWeight, float maxWaterThreat);
    std::vector<springai::AIFloat3> GetUnitTerrainRoute(const CCircuitDef* def,
        const springai::AIFloat3& from, const springai::AIFloat3& to, bool dry,
        float landCost, float waterCost, float threatWeight, float maxWaterThreat);

	// --- water
	void PrepareWater() { BuildWater(); }  // idempotent, without lane/beach policy side effects
	float GetWaterSurveyCoverage(int body, int maxAgeFrames);
	springai::AIFloat3 GetWaterScoutGoal(int body, int maxAgeFrames, const springai::AIFloat3& from, int seed);
	int GetWaterEnemyCount(int body);
	int WaterBody(const springai::AIFloat3& pos, bool subDepth) const;   // -1 when none
	bool IsHostileWater(int body, bool subDepth) const;
	void MarkHostileWater(const springai::AIFloat3& pos, float radius);
	bool TorpedoSiteOK(const CCircuitDef* cdef, const springai::AIFloat3& pos, float range, bool onLand) const;
	int AnalyseBeaches(const springai::AIFloat3& centre, float radius);
	int GetBeachCount() const { return (int)beaches.size(); }
	springai::AIFloat3 GetBeachPos(int i) const;
	springai::AIFloat3 GetBeachSeaward(int i) const;
	int GetBeachClass(int i) const;
	float GetBeachHeat(int i) const;
	float GetBeachDepth(int i, float out) const;   // seabed depth this far out along the normal

	// --- lanes (D-127): between both teams' start positions, per movement class
	void ClearLaneEnds() { allyEnds.clear(); enemyEnds.clear(); }
	void AddAllyEnd(const springai::AIFloat3& pos) { allyEnds.push_back(pos); }
	void AddEnemyEnd(const springai::AIFloat3& pos) { enemyEnds.push_back(pos); }
	int AnalyseLanes(int alternatives, float mergeRadius, float threatWeight, float specialistBias = 1.f,
		float highGroundRise = 128.f, float highGroundDetour = 3.f, int highGroundRoutes = 3);
    bool RequestLanes(int alternatives, float mergeRadius, float threatWeight, float specialistBias = 1.f,
        float highGroundRise = 128.f, float highGroundDetour = 3.f, int highGroundRoutes = 3);
    bool IsLanePending() const { return laneJobs.Pending(); }
    int GetLaneRevision() const { return laneRevision; }
    void CancelLaneRequest();
    void BeginLanePostprocess() { lanePostStart = std::chrono::steady_clock::now(); }
    void EndLanePostprocess();
	int GetLaneCount() const { return (int)lanes.size(); }
	int GetLaneClass(int i) const;
	int GetLaneMask(int i) const;      // classes capable of the complete representative path
	void SetCliffDescentParams(int approachClass, float minDrop, float maxRun, float minProgress);
	void SetMountainPathParams(float gradeWeight, float peakTolerance);
    bool IsLaneSpecialist(int i) const;
    void SetSpecialistSpan(float minimum, float fraction);
	void SetMountainShelfParams(float surfaceWeight, float heightWeight);
	void SetCliffPreference(float weight, float qualityTolerance, float heightFraction);
	springai::AIFloat3 GetLaneAscent(int i) const;
	float GetLaneCliffQuality(int i, int end) const;
	springai::AIFloat3 GetLaneDescent(int i) const; // start of a verified access-then-descent route, or -1
	springai::AIFloat3 GetLanePoint(int i, float share) const;   // 0 at our end, 1 at the enemy's
	float GetLaneLength(int i) const;
	float GetLaneWidth(int i) const;   // the narrowest point, for ground lanes
	springai::AIFloat3 GetLaneChoke(int i) const;
	float GetLaneThreat(int i) const;   // mean threat along it (air lanes: enemy AA)
	float GetLaneFront(int i) const;    // share where enemy threat begins, -1 when none
	int GetLaneHeat(int i) const;       // paths merged into it
	bool IsPassable(const springai::AIFloat3& pos, int cls) const;
	std::vector<springai::AIFloat3> GetLaneRoute(int lane, const springai::AIFloat3& from, int cls) const;

private:
	float navalThreatCost[4] = {}; // surface mobile, submerged, strike aircraft, water static
    struct NavalForce { springai::AIFloat3 pos; float cost; int id, defId, flags, body; };
    std::vector<NavalForce> navalForces;
    std::vector<NavalForce> seaForces;
    int seaForceFrame = -100000;
    unsigned int groundPublication = 0, waterWeaponPublication = ~0u;
    int waterWeaponFrame = -100000;
    struct WaterWeapon { springai::AIFloat3 position; float range; };
    std::vector<WaterWeapon> staticWaterWeapons;
    ranged::SpatialIndex staticWaterWeaponIndex;
    bool staticWaterWeaponIndexValid = true;
    float maximumWaterWeaponRange = 0.f;
    int navalForceFrame = -100000;
    // Lazily requested by the AIR safety query only. Real weapon envelopes
    // remain hazardous when a role profile intentionally assigns zero threat.
    struct AirWeapon { springai::AIFloat3 pos; float range; };
    mutable std::vector<AirWeapon> airWeapons;
    mutable int airWeaponFrame = -100000;
    void RefreshAirWeapons() const;
	// Value snapshots, refreshed each second from current ally-visible contacts.
	struct AirContact {
		springai::AIFloat3 pos;
		float cost;
		bool armed = false;
        int id = -1;
	};
	std::vector<AirContact> airContacts;
    struct GroundContact { springai::AIFloat3 pos; float cost; bool economy; int id; int defId;
        int kind = 0; float hazardRange = 0.f; }; // D-296: ContactKind flags; LAND reach when armed
    std::vector<GroundContact> groundContacts;
    std::vector<springai::AIFloat3> navalContacts;
    std::vector<AirContact> allyAssets;
    int allyAssetFrame = -100000;
	struct SChoke {
		springai::AIFloat3 pos, dir;
		float width, heat, share;
	};
	using SLane = lane::Route;
	struct SBeach {
		springai::AIFloat3 pos, seaward;
		int cls;
		float heat;
	};
	using Grid = std::vector<float>;
    Grid observedWaterWeapons; // current weapon coverage, independent of profile threat multipliers
    // D-296 lazy observed ground-weapon coverage (callback thread only).
    // Owner: EnsureGroundHazard; invalidated by groundPublication or margin.
    Grid observedGroundHazard;
    unsigned int groundHazardPublication = ~0u;
    float groundHazardMargin = -1.f;
    void EnsureGroundHazard(float margin);
    std::vector<springai::AIFloat3> UnitTerrainRoute(const CCircuitDef* def,
        const springai::AIFloat3& from, const springai::AIFloat3& to, bool dry,
        float landCost, float waterCost, float threatWeight, float maxWaterThreat,
        const Grid* hazard, float hazardValue);
    // D-296: unidentified radar dots are painted into the ground hazard with
    // this conservative radius (default 700, about a T1 turret's range).
    void SetUnknownHazardRange(float range);
    std::vector<springai::AIFloat3> radarDots; // observed unidentified land contacts, per Update
    float unknownHazardRange = 700.f;
    // Raid routes solve on the shared per-class lane grid (no per-definition
    // terrain build). Base surface threat is cached by ThreatMap publication;
    // the hazard overlay is applied per solve, so a new dot is seen at once.
    Grid raidBaseThreat, raidRouteThreat;
    std::vector<char> raidRouteBlocked; // rebuilt with the hazard overlay, retained per AI
    Grid ferryAirThreat;
    std::vector<char> ferryAirBlocked;
    lane::PointWorkspace ferryAirWorkspace;
    std::uint64_t raidBaseVersion = 0;
    lane::PointWorkspace raidRouteWorkspace;
    lane::Settings laneSettings;
    std::shared_ptr<const lane::Terrain> laneTerrain;
    // Synchronous callback-only scratch, never shared with lane workers.
    // Keep terrain alive to prevent pointer ABA; threat publication versions
    // prevent double-buffer ABA. Amphibious observed-weapon overlays remain
    // uncached until all of their mutations have a separate version.
    std::shared_ptr<const lane::Terrain> routeSnapshotTerrain;
    struct RouteSnapshot { Grid threat; std::uint64_t version = 0; lane::PointWorkspace workspace; };
    std::array<RouteSnapshot, 2> routeSnapshots; // surface and air
    Grid amphRouteThreat;
    lane::PointWorkspace amphRouteWorkspace;
    // Const lane joining is owner-thread-only; uniform costs need no threat
    // version. Retain scratch but never cache the mutable route result.
    mutable lane::PointWorkspace laneJoinWorkspace;
    lane::JobGate laneJobs;
    std::shared_ptr<std::atomic<bool>> laneCancel;
    int laneRevision = 0;
    std::chrono::steady_clock::time_point lanePostStart;
    lane::Request CaptureLaneRequest(int alternatives, float mergeRadius, float threatWeight, float specialistBias,
        float highGroundRise, float highGroundDetour, int highGroundRoutes);
    bool StartLaneAnalysis(bool background, int alternatives, float mergeRadius, float threatWeight, float specialistBias,
        float highGroundRise, float highGroundDetour, int highGroundRoutes);
	CWeaponDef* MainWeapon(const CCircuitDef* cdef) const;
	mutable std::unordered_map<int, CWeaponDef*> mainWeapon;   // def id -> its longest-range weapon

	void EnsureGrid();
	void BuildWater();
	int Cell(const springai::AIFloat3& pos) const;
	springai::AIFloat3 CellPos(int c) const;
	float CellHeight(int c) const;
	float CellMaxHeight(int c) const;   // the shallowest point: water bodies are conservative
	bool Passable(int from, int to, bool amph) const;
	void BuildPass();
	void Clearance(std::vector<int>& clr, int cls = L_BOT) const;
	void Dijkstra(int start, const Grid& penalty, bool amph, Grid& dist, std::vector<int>& prev) const;
	void Decay(Grid& g, float factor);
	void AddHeat(Grid& g, const springai::AIFloat3& pos, float v);
	float SumHeat(const Grid& g, const springai::AIFloat3& pos, float radius) const;
	void Label(std::vector<int>& body, float minDepth);

	CCircuitAI* circuit;
	int cellSize;
	int gw, gh;
	Grid height, maxHeight;   // per cell: mean and highest point
	Grid surfaceSlope;   // mean engine slope: catches sideways travel along a cliff
    struct UnitTerrain {
        lane::Terrain grid;
        Grid slope;
        std::uint64_t heightRevision = 0;
        int frame = -100000;
    };
    std::unordered_map<int, UnitTerrain> unitTerrain;
    // One callback-thread scratch set per AI, shared across definition/dry keys.
    // Retain allocations, never route results or live obstacle observations.
    Grid unitRouteSlope, unitRouteThreat;
    std::vector<char> unitRouteObstacles;
    lane::PointWorkspace unitRouteWorkspace;
	std::vector<springai::AIFloat3> sources;
	Grid routeHeat, routeShare;
	std::vector<char> lane;
	std::vector<std::vector<int>> routes;   // cells, base first
	std::vector<SChoke> chokes;
	bool analysed;

	int heatCell, hw, hh;
	Grid combat, air;
	int lastDecay;
	float combatHalfLife, airHalfLife;
	float cost[_KIND_SIZE_];
	int count[_KIND_SIZE_];

	std::vector<int> body8, body15;
	std::vector<char> hostile8, hostile15;
	bool waterBuilt;
	// Lazily sampled legal ally sensor maps. Reset on load/reconstruction: a
	// saved claim of control must never substitute for renewed reconnaissance.
	void UpdateWaterSurvey(int body);
	std::vector<std::vector<int>> surveyCells;
	std::vector<int> surveySeen, surveyFrame;
	std::vector<SBeach> beaches;

	std::vector<char> pass[_LANE_CLASSES_];
	std::vector<springai::AIFloat3> allyEnds, enemyEnds;
	std::vector<SLane> lanes;
};

} // namespace circuit

#endif // SRC_CIRCUIT_TERRAIN_BATTLEANALYSIS_H_
