/*
 * TerrainManager.h
 *
 *  Created on: Dec 6, 2014
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TERRAIN_TERRAINMANAGER_H_
#define SRC_CIRCUIT_TERRAIN_TERRAINMANAGER_H_

#include "terrain/BlockingMap.h"
#include "terrain/LocalReservations.h"
#include "terrain/BaseLayoutGeometry.h"
#include "terrain/LayoutRanking.h"
#include "unit/CoreUnit.h"
#include "unit/CircuitDef.h"

#include "AIFloat3.h"

#include <unordered_map>
#include <set>
#include <string>
#include <deque>
#include <functional>
#include <tuple>
#include <cstdint>

namespace terrain {
	struct SArea;
	struct SMobileType;
	struct SImmobileType;
	struct SAreaSector;
	struct SSector;
	struct SAreaData;
}

namespace circuit {

class CCircuitAI;
class IBlockMask;
class IPathQuery;
class IBuilderTask;
class CPathInfo;
class CCircuitUnit;

class CTerrainManager final {  // <=> RAI's cBuilderPlacement
public:
	using TerrainPredicate = std::function<bool (const springai::AIFloat3& p)>;

	CTerrainManager(CCircuitAI* circuit, terrain::CTerrainData* terrainData);
	~CTerrainManager();

	void InitAnalyzer();
private:
	CCircuitAI* circuit;
	void ReadConfig();

public:
	static inline int GetTerrainWidth() { return springai::AIFloat3::maxxpos; }
	static inline int GetTerrainHeight() { return springai::AIFloat3::maxzpos; }
	static inline float GetTerrainDiagonal() {
		return sqrtf(SQUARE(springai::AIFloat3::maxxpos) + SQUARE(springai::AIFloat3::maxzpos));
	}
	static inline springai::AIFloat3 GetTerrainCenter() {
		return springai::AIFloat3(GetTerrainWidth() / 2, 0, GetTerrainHeight() / 2);
	}

	void Init();
	void AddBlocker(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, bool isOffset = false);
	void DelBlocker(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, bool isOffset = false);
	bool IsObstruct(const springai::AIFloat3& pos) const;
//	springai::AIFloat3 CheckObstruct(CCircuitUnit* unit) const;
	void AddBusPath(CCircuitUnit* unit, const springai::AIFloat3& toPos, CCircuitDef* mobileDef);
	void DelBusPath(CCircuitUnit* unit);
	springai::AIFloat3 GetBusPos(CCircuitDef* facDef, const springai::AIFloat3& pos, int& outFacing);
	void ResetBuildFrame() { markFrame = -FRAMES_PER_SEC; }
	// TODO: Use IsInBounds test and Bound operation only if mask or search offsets (endr) are out of bounds
	// TODO: Based on map complexity use BFS or circle to calculate build offset
	// TODO: Consider abstract task position (any area with builder) and task for certain unit-pos-area
	springai::AIFloat3 FindBuildSite(CCircuitDef* cdef,
									 const springai::AIFloat3& pos,
									 float searchRadius,
									 int facing,
									 bool isIgnore = false,
									 bool isHighRes = false);
	springai::AIFloat3 FindBuildSite(CCircuitDef* cdef,
									 const springai::AIFloat3& pos,
									 float searchRadius,
									 int facing,
									 TerrainPredicate& predicate,
									 bool isIgnore = false,
									 bool isHighRes = false);
//	springai::AIFloat3 FindSpringBuildSite(CCircuitDef* cdef, const springai::AIFloat3& pos, float searchRadius, int facing);
	void DoLineOfDef(const springai::AIFloat3& start, const springai::AIFloat3& end, CCircuitDef* buildDef,
			std::function<void (const springai::AIFloat3& pos, CCircuitDef* buildDef)> exec) const;  // FillRowOfBuildPos
	springai::AIFloat3 GetRandomMovePosition(CCircuitUnit* unit);

	const SBlockingMap& GetBlockingMap();
	bool IsZoneAlly(const springai::AIFloat3& pos) const;
	void AddZoneOwn(const springai::AIFloat3& pos) { MarkZoneOwn(pos, true); }
	void DelZoneOwn(const springai::AIFloat3& pos) { MarkZoneOwn(pos, false); }
	float SetAllyZoneRange(float range);  // range/radius in elmos

	/*
	 * Reservations (doc/base-layout.md, D-043). A reservation is a footprint the
	 * placement search treats as occupied by everyone except the construction
	 * it was reserved for. TECH asks the native planner for atomic factory
	 * clusters and a rear economy module. FindBuildSite serves a matching
	 * reserved site before it runs the nearest-free spiral, and every other
	 * search flows around the reserved ground. A served reservation is
	 * consumed (its cells unmarked, the pending build's own blocker takes
	 * over); the task hands it back with RestoreReservation if it is
	 * cancelled before construction starts, and forgets it with
	 * FinishReservation once the structure exists.
	 */
	struct SReservation {
		int id;
		CCircuitDef* def;
		springai::AIFloat3 pos;  // snapped build position
		int facing;
		int group;       // 0 = none; ReserveGrid gives every slot of a grid one group
		int untilFrame;  // 0 = until released
		bool consumed;   // served to a task; cells are unmarked (kept marked inside a zone)
		bool armed;      // servable; a held slot is planned but not yet offered (layout phases)
		bool anyReach;   // a static builder def is served regardless of the search anchor
		bool tenant;     // an early def on a successor's ground: forgotten when its structure goes
		int zone;        // 0 = a plain reservation; else the zone it was laid in
		int unitId;      // the structure built on it (zone slots only), 0 = none
		int order;       // deterministic order inside a named group
		bool claimed;    // an exact pinned task owns the slot, before/while it is served
		int serveFails = 0;  // D-108: the engine refused to build on it this often (runtime only); dead at kDeadSlotFails
	};
	static constexpr int kDeadSlotFails = 3;  // D-108: a slot the engine refuses this often is never served again; its ground stays held
	// One footprint. Refuses (-1, logged) off-map, unbuildable, or overlapping ground.
	int ReserveBuilding(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, int ttlFrames = 0, int group = 0);
	// A single reusable slot. Its private zone preserves frame/unit identity after completion.
	int ReservePersistentBuilding(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing);
	int ReservePackedBuilding(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing);
	// Opt-in finite support geometry. Stores slot IDs under key + ".slot.N";
	// rolls back every new slot if the minimum useful footprint cannot fit.
	int PlanNavalSupport(const std::string& key, CCircuitDef* nano, CCircuitDef* factory,
		const springai::AIFloat3& pos, int facing, int maximum, int minimum, float margin);
	bool IsAreaVisible(const springai::AIFloat3& pos, float radius) const;
	bool PlanNavalBerth(const std::string& key, CCircuitDef* cdef, const springai::AIFloat3& pos,
	                    int facing, float length, float margin);
	bool CanNavalRoute(CCircuitDef* cdef, const springai::AIFloat3& from, const springai::AIFloat3& to);
	void ReleasePersistentBuilding(int id);
	int GetReservationState(int id) const; // -1 absent, 0 free, 1 claimed, 2 framed, 3 complete, 4 dead
	bool IsReservationBuildable(int id) const;
	int GetGroupActivationState(int group) const; // -1 missing, 0 ready, 1 blocked, 2 started
	int GetGroupZone(int group) const;
	int GetZoneActivationState(int zone) const;
	int ReserveClusterEnvelope(int slot, int group);
	bool IsAllyLayoutBlocked(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing) const;
	bool CanReserveArea(const springai::AIFloat3& centre, int facing, float halfAcross, float halfAlong) const;
	bool IsResourceAreaBlocked(const springai::AIFloat3& centre, int facing, float halfAcross, float halfAlong) const;
	bool IsAllyLayoutRectBlocked(const int2& c1, const int2& c2) const;
	void ShareSlot(int id);
	void ShareZone(int id);
	// cols x rows footprints of cdef behind frontCentre (the middle of the grid's
	// front edge), rows receding away from `facing`, `gap` cells between them.
	// Slots the terrain refuses are skipped. Returns the group id, 0 if nothing fit.
	int ReserveGrid(CCircuitDef* cdef, const springai::AIFloat3& frontCentre, int facing, int cols, int rows, int gap, int ttlFrames = 0);
	bool PlanMexCluster(const std::string& name, CCircuitDef* def, const springai::AIFloat3& origin, int facing, int cols, int rows);
	// A nano block tight against the back of a factory footprint (built or reserved).
	int ReserveNanoBlockAt(CCircuitDef* nanoDef, CCircuitDef* facDef, const springai::AIFloat3& facPos, int facing, int cols, int rows, int gap);
	bool CanReserveNanoBlockAt(CCircuitDef* nanoDef, CCircuitDef* facDef, const springai::AIFloat3& facPos, int facing, int cols, int rows, int gap);
	// The same behind a standing factory: position and facing read from the unit.
	int ReserveNanoBlock(CCircuitUnit* factory, CCircuitDef* nanoDef, int cols, int rows, int gap);
	// Dry run of ReserveBuilding: would it be accepted? No marks, no log.
	bool CanReserveBuilding(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing);
	// Fraction of a rectangle - centred at `centre`, halfAcross to each side of
	// `facing`, halfAlong forward and back - on which cdef could be placed now:
	// in the map, not blocked or reserved, terrain-typed for it and accepted
	// by the engine. Probed every 32 elmos. A plan is laid where this is
	// highest, so the nano block keeps open ground on both sides.
	float BuildableFraction(CCircuitDef* cdef, const springai::AIFloat3& centre, float halfAcross, float halfAlong, int facing);
	void ReleaseReservation(int id);
	void ReleaseGroup(int group);
	bool IsReserved(const springai::AIFloat3& pos) const;
	int GetReservationCount(CCircuitDef* cdef) const;  // unconsumed
	// Handshake with IBuilderTask: a FindBuildSite that served a reserved site
	// leaves the reservation's id and facing here for the caller to take.
	int TakeReservedId() { const int id = lastReservedId; lastReservedId = -1; return id; }
	int TakeReservedFacing() { const int f = lastReservedFacing; lastReservedFacing = -1; return f; }
	void RestoreReservation(int id);  // task cancelled before construction: hold the ground again
	void FinishReservation(int id, int unitId = 0);   // construction started: forget a plain slot, remember a zone slot's unit
	bool ClaimReservation(int id);
	void UnclaimReservation(int id);
	// Serve a reservation only within this distance of the search anchor;
	// 0 = any distance, so a planned site wins wherever the builder stands.
	float reservationMatchRadius = 0.f;

	/*
	 * Layout (doc/layout-design.md, D-060). Zones and corridors are rectangles
	 * of cells held RESERVED for the life of the plan. A zone is laid with
	 * bands (grids of one def, LayBand) whose slots are served like any
	 * reservation while armed; a corridor is never laid, so nothing of ours is
	 * placed on it. A slot served inside a zone keeps its cells marked (the
	 * structure's own blocker takes over on top), and when the structure goes
	 * the cells are marked again (DelBlocker), so zone ground never leaks to
	 * the spiral. A final def's slot is restored when its structure dies; a
	 * tenant's slot is forgotten, the ground going to the successor band.
	 * High-level factory/module plans add named groups and exact slot order.
	 * All of it is inert unless JSON permits it and TECH opts in.
	 */
	bool layoutEnabled = false;
	bool SetLayoutEnabled(bool enabled);
	bool IsLayoutEnabled() const { return layoutEnabled; }
	bool IsLayoutConfigured() const { return layoutConfigured; }
	struct SZone {
		int id;
		int2 c1, c2;   // cell rectangle [c1, c2)
		bool corridor;
		int cells;     // cells it holds (the free ones at reserve time)
	};
	// A rectangle centred at `centre`, halfAcross to each side of `facing`,
	// halfAlong forward and back. Free cells are marked, blocked ones are
	// holes. Returns the zone id, 0 when nothing could be marked.
	int ReserveZone(const springai::AIFloat3& centre, int facing, float halfAcross, float halfAlong, bool corridor);
    // Read-only world-space bounds; upper corner is exclusive, -1 if absent.
    springai::AIFloat3 GetZoneCorner(int id, bool upper) const;
	// D-072: would this footprint cut the zone's free cells into a pocket no unit could leave?
	bool LeavesPocket(int zone, CCircuitDef* cdef, const springai::AIFloat3& pos, int facing) const;
	// A corridor in front of a standing factory: its width plus `margin` each
	// side, `length` forward from its front edge (the engine sends new units
	// out through the front). Returns the corridor's zone id, 0 if none.
	int ReserveExitCone(CCircuitUnit* factory, float length, float margin);
	void ReleaseZone(int id);
	bool IsZoneClear(int id) const;  // no structure on any of its cells
	// A grid of cdef inside a zone: every slot on the zone's cells, none on a
	// structure or another slot. Idempotent - a slot that already exists (same
	// def, same position) is not duplicated, so a successor band may be laid
	// again as its tenants' ground clears. group 0 = a new group, else the
	// slots join that group. Returns the group, 0 when nothing was placed and
	// no group was given.
	int LayBand(int zone, CCircuitDef* cdef, const springai::AIFloat3& frontCentre, int facing, int cols, int rows, int gap,
			bool armed, bool anyReach, bool tenant, int group = 0);
	void ArmGroup(int group, bool armed);
	void ReleaseUnconsumed(int group);  // tenants no longer wanted: unserved slots go, built ones stay
	int GetGroupCount(int group, bool unconsumedOnly) const;
	int NextSlot(int group, const springai::AIFloat3& anchor) const;   // nearest armed unconsumed slot, -1 = none
	int NextBuilt(int group, const springai::AIFloat3& anchor) const;  // nearest slot whose structure stands, -1 = none
	springai::AIFloat3 GetReservationPos(int id) const;
	int GetReservationFacing(int id) const;
	// D-116: the engine refused this slot kDeadSlotFails times; it is never served
	// again (its ground stays held), so a plan pinned to it must choose new ground
	bool IsSlotDead(int id) const;
	// D-116: the engine's own build test for a snapped build position (the
	// reservation checks ask it, so no plan holds ground the engine refuses)
	bool IsEngineBuildable(CCircuitDef* cdef, const springai::AIFloat3& buildPos, int facing) const;
	CCircuitUnit* GetReservationUnit(int id) const;
	// Share of the rectangle whose slope is at most maxSlope (engine units, 1 - cos).
	float FlatFraction(const springai::AIFloat3& centre, int facing, float halfAcross, float halfAlong, float maxSlope) const;
	// A builder task calls this right before its FindBuildSite: only then may a
	// search serve a reservation (CR-002: a movement, pylon or terraform search
	// must never consume a planned slot it cannot own). id >= 0 pins the search
	// to that slot (a routed builder's task).
	void BeginReservedSearch(int pinnedId, bool required, int facingFilter = -1) {
		reservationSearch = true;
		pinnedReservation = pinnedId;
		pinnedReservationRequired = required;
		reservationFacingFilter = facingFilter;
	}
	bool PlanFactoryPair(const std::string& name, CCircuitDef* firstFactory, CCircuitDef* secondFactory,
			CCircuitDef* nanoDef, const springai::AIFloat3& base, int facing, int sideOffsetCells, int forwardOffsetCells);
	int AcquireFactoryReservation(CCircuitDef* factoryDef);
	bool PlanAirFactoryCluster(const std::string& name, CCircuitDef* firstFactory, CCircuitDef* repeatedFactory,
			CCircuitDef* nanoDef, const springai::AIFloat3& origin, int facing, int count, int columns, int firstNanos);
	bool PinLayoutTask(IBuilderTask* task, const std::string& groupName, CCircuitUnit* builder);
	bool PinFactoryNanoTask(IBuilderTask* task, CCircuitUnit* builder);
	int GetFactoryNanoAvailable() const;
	int GetFactoryNanoActive() const;
	bool HasLayoutGroup(const std::string& name) const;
	int GetLayoutGroupTotal(const std::string& name) const;
	int GetLayoutGroupBuilt(const std::string& name) const;
	int GetLayoutGroupStarted(const std::string& name) const;
	int GetLayoutGroupAvailable(const std::string& name) const;
	int GetLayoutInt(const std::string& name, int fallback = 0) const;
	springai::AIFloat3 GetLayoutGroupCenter(const std::string& name) const;
	void SetLayoutInt(const std::string& name, int value) { layoutInts[name] = value; }
	// Turret box (D-063): one footprint of cdef packed inside a zone, on the
	// cells nearest to any slot of nanoGroup (the invisible turrets, built or
	// not), no farther than maxReach from the nearest one (0 = that def's own
	// build distance) and no nearer than minNanoDist to any; ties go to the
	// candidate nearest `anchor` (the factory line). Returns the reservation
	// id, armed and any-reach, in `group`; -1 when nothing fits.
	int PackNearGroup(int zone, CCircuitDef* cdef, int nanoGroup, int facing, const springai::AIFloat3& anchor,
			float maxReach, float minNanoDist, int group);
	// D-073: the free footprint of cdef inside the zone that the most slots
	// of nanoGroup (standing or planned) reach within `reach`, front first
	// among equals (the zone's forward side along `facing`), then nearest a
	// slot. PickMost is the dry run (score, position); PackNearGroupMost
	// reserves it like PackNearGroup and returns the id, -1 when none.
	// D-085: served slots (a turret stands or is being built) count SERVED_SLOT_WEIGHT
	// times a planned one; among equals the candidate nearest `seed` (where the
	// block grows from) wins, so the lab stands where the turrets are or will be first.
	int PickMost(int zone, CCircuitDef* cdef, int nanoGroup, int facing, float reach, float flush, const springai::AIFloat3& seed, springai::AIFloat3& outPos) const;  // D-095: flush = LayoutLabFlushElmos
	// D-074: is the ground in front of a factory placed at pos (its exit,
	// `length` deep, the footprint's width plus `margin` each side) free of
	// standing structures and of planned slots? A factory is never placed
	// where anything stands or will stand in its exit.
	bool IsExitClear(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, float length, float margin) const;
	// D-096: the cells a factory's exit lane covers (IsExitClear's rectangle)
	bool ExitLaneCells(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, float length, float margin, int2& c1, int2& c2) const;
	// D-096: the exit lanes of every planned and standing factory of the layout;
	// nothing is packed into one
	std::vector<layout_rank::CellRect> FactoryExitLanes() const;
	// D-096: INV-018 - own structures (not mobile) whose footprint stands in the factory's exit lane
	int CountStructuresInExit(CCircuitUnit* factory) const;
	int GetBuildingFacing(CCircuitUnit* unit) const;
	int PackNearGroupMost(int zone, CCircuitDef* cdef, int nanoGroup, int facing, float reach, float flush, int group, const springai::AIFloat3& seed);
	// slots of a group (standing or planned) within radius of pos
	int CountGroupSlotsWithin(int group, const springai::AIFloat3& pos, float radius) const;
	// The dry run of PackNearGroup: would a footprint fit? Nothing is marked.
	bool CanPackNearGroup(int zone, CCircuitDef* cdef, int nanoGroup, int facing, float maxReach, float minNanoDist);
	int PackNearBuiltPower(int zone, CCircuitDef* cdef, int nanoGroup, int facing,
			const springai::AIFloat3& anchor, float margin);
	// D-066: the experimental system's placement when no planned slot was
	// served: the free footprint of cdef nearest to `pos` within `radius`
	// (cell-exact, deterministic, the def's block mask respected), reserved
	// and served to the asking task like a planned slot. -RgtVector when none.
	springai::AIFloat3 PackNearPoint(CCircuitDef* cdef, const springai::AIFloat3& pos, float radius, int facing, TerrainPredicate& predicate);
	// D-064: a point on the circle of `radius` around `site`, nearest the
	// unit's side, on cells no structure holds (planned ground is walkable)
	// and inside the unit's movement area; -RgtVector when none of sixteen.
	springai::AIFloat3 FindApproachPoint(CCircuitUnit* unit, const springai::AIFloat3& site, float radius);
	// D-091: the nearest point to `around` within maxRadius where `cargo` can stand:
	// its own move type reaches it (no water for a bot), no structure or reserved
	// footprint covers it, and it is at least `avoidRadius` from every point in
	// `avoid` (spots the engine already refused). -RgtVector when none.
	springai::AIFloat3 FindDropSpot(CCircuitUnit* cargo, const springai::AIFloat3& around, float maxRadius,
			const std::vector<springai::AIFloat3>& avoid, float avoidRadius, float maxSurfaceThreat = -1.f, float maxAirThreat = -1.f);
	// Nearest unconsumed, unclaimed slot of a group, armed or held (a pinned
	// task may take a held slot; NextSlot serves the armed ones only).
	int NextSlotAny(int group, const springai::AIFloat3& anchor) const;
	// D-077: the next unconsumed, unclaimed slot of a group growing outward from
	// centre: the first is the one nearest centre; every later one is the slot
	// nearest a consumed slot of the group, ties broken towards centre, so the
	// turrets form one connected cluster around the layout's middle.
	int NextSlotConnected(int group, const springai::AIFloat3& centre) const;
	// "kind:def:x:z:facing:w:d:state;..." for the widget overlay (cells of 16 elmos).
	std::string DescribeLayout() const;
	// Everything of the layout goes: reservations, zones, marks, the flag (a role switch).
	void ResetLayout();
	// Save/load of the whole layout state (CR-003); called by CBuilderManager
	// before its tasks so their reservation ids resolve.
	void SaveLayout(std::ostream& os) const;
	void LoadLayout(std::istream& is);

	bool ResignAllyBuilding(CCircuitUnit* unit);

	void ApplyAuthority();

private:
	int markFrame;
	struct SStructure {
		ICoreUnit::Id unitId;
		CCircuitDef* cdef;
		springai::AIFloat3 pos;
		int facing;
	};
	std::deque<SStructure> markedAllies;  // sorted by insertion
	void MarkAllyBuildings();

	struct SSearchOffset {
		int dx, dy;
		int qdist;  // dx*dx + dy*dy
	};
	using SearchOffsets = std::vector<SSearchOffset>;
	struct SSearchOffsetLow {
		SearchOffsets ofs;
		int dx, dy;
		int qdist;  // dx*dx + dy*dy
	};
	using SearchOffsetsLow = std::vector<SSearchOffsetLow>;
	static const SearchOffsets& GetSearchOffsetTable(int radius);
	static const SearchOffsetsLow& GetSearchOffsetTableLow(int radius);
	springai::AIFloat3 FindBuildSiteLow(CCircuitDef* cdef,
										const springai::AIFloat3& pos,
										float searchRadius,
										int facing,
										TerrainPredicate& predicate);
	springai::AIFloat3 FindBuildSiteByMask(CCircuitDef* cdef,
										   const springai::AIFloat3& pos,
										   float searchRadius,
										   int facing,
										   IBlockMask* mask,
										   TerrainPredicate& predicate);
	// NOTE: Low-resolution build site is 40-80% faster on fail and 20-50% faster on success (with large objects). But has lower precision.
	springai::AIFloat3 FindBuildSiteByMaskLow(CCircuitDef* cdef,
											  const springai::AIFloat3& pos,
											  float searchRadius,
											  int facing,
											  IBlockMask* mask,
											  TerrainPredicate& predicate);

	int allyZoneCells;  // side of a square
	SBlockingMap blockingMap;
	std::string resourceLayout; // immutable resource footprints, local blueprint export only
	std::map<int, SReservation> reservations;
	local_layout::Reservations localReservations;
	mutable uint64_t localOracleQueries = 0;
	mutable uint64_t localOracleMismatches = 0;
	void IndexLocalSlot(int id);
	std::map<std::string, int> layoutGroups;
	std::map<std::string, int> layoutZones;
	std::map<std::string, int> layoutInts;
	int nextReservationId = 1;
	int nextGroupId = 1;
	int lastReservedId = -1;
	int lastReservedFacing = -1;
	bool ReservationCells(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, int2& c1, int2& c2) const;
	bool IsReservationFree(const int2& c1, const int2& c2) const;
	bool IsResourceFootprintBlocked(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing) const;
	bool IsResourceBuildingSite(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing) const;
	void MarkReservation(const int2& c1, const int2& c2, bool mark);
	void ExpireReservations();
	std::map<int, SZone> zones;
	int nextZoneId = 1;
	std::vector<unsigned short> zoneMap;  // cell -> zone id, 0 = none
	int pinnedReservation = -1;
	bool pinnedReservationRequired = false;
	bool reservationSearch = false;   // set by BeginReservedSearch, consumed by the next FindBuildSite
	int reservationFacingFilter = -1; // one-shot; opening SEA search must test the actual exit facing
	bool layoutRefusalLogged = false;
	bool layoutConfigured = false;
	bool factoryLineReady = false;
	int factoryLineFacing = 0;
	base_layout::Point factoryRearCentre;
	int factoryLineLeft2 = 0;
	int factoryLineRight2 = 0;
	CCircuitDef::Id layoutNanoDefId = -1;
	int nextFactoryCluster = 1;
	bool RectCells(const springai::AIFloat3& centre, int facing, float halfAcross, float halfAlong, int2& c1, int2& c2) const;
	bool IsRectFree(const base_layout::Rect& rect) const;
	int ReserveExactZone(const std::string& name, const base_layout::Rect& rect, bool corridor);
	int EnsureLayoutGroup(const std::string& name);
	int GetLayoutGroupId(const std::string& name) const;
	int GetNextLayoutSlot(const std::string& name, CCircuitUnit* builder, CCircuitDef* buildDef);
	int GetNextLayoutSlot(int group, CCircuitUnit* builder, CCircuitDef* buildDef);
	std::vector<int> GetCompletedFactoryNanoGroups() const;
	bool CanReserveFactoryCluster(const base_layout::FactoryCluster& cluster,
			CCircuitDef* factoryDef, CCircuitDef* nanoDef);
	bool ReserveFactoryCluster(const std::string& name, const base_layout::FactoryCluster& cluster,
			CCircuitDef* factoryDef, CCircuitDef* nanoDef, int& factoryReservation);
	void ReleaseLayoutPrefix(const std::string& prefix);
	int ZoneAt(int x, int z) const;
	// Cells free for a slot: unblocked, or held by `zone` itself (its marks and
	// its other structures' yards), and not under another unconsumed slot.
	bool IsSlotFree(const int2& c1, const int2& c2, int zone, int ignoreId) const;
	bool IsSlotFreeLegacy(const int2& c1, const int2& c2, int zone, int ignoreId) const;
	bool IsSlotFreeIndexed(const int2& c1, const int2& c2, int zone, int ignoreId) const;
	struct SPackCandidate {
		springai::AIFloat3 pos;
		float nanoSq;    // squared distance to the nearest slot of the nano group
		float anchorSq;  // squared distance to the tie-break anchor
		float sameSq;    // squared distance to the nearest standing or planned structure of the same def (max when none)
	};
	std::vector<SPackCandidate> PackCandidates(int zone, CCircuitDef* cdef, int nanoGroup, int facing,
			const springai::AIFloat3& anchor, float maxReach, float minNanoDist, bool alwaysRing = false) const;  // D-104: alwaysRing scans the ring round the zone too
	std::vector<SPackCandidate> ComputePackCandidates(int zone, CCircuitDef* cdef, int nanoGroup, int facing,
			const springai::AIFloat3& anchor, float maxReach, float minNanoDist, bool alwaysRing) const;
	using EmptyPackKey = std::tuple<int,int,int,int,float,float,bool>;
	mutable std::set<EmptyPackKey> emptyPackQueries;
	uint64_t packingRevision = 0;
	mutable uint64_t emptyPackRevision = 0, emptyPackAllyRevision = 0;
	mutable unsigned int emptyPackOwnedRevision = 0;
	mutable int emptyPackFrame = -1;
	void UnmarkSlot(const int2& c1, const int2& c2);  // served: cells go, except a zone's own marks
	int FindSlotAt(CCircuitDef* cdef, const springai::AIFloat3& pos) const;
public:
	// D-101: our own structure is being reclaimed: when it goes, its layout slot
	// is freed, not restored (the ground returns to the pool)
	void MarkSlotRecycled(CCircuitDef* cdef, const springai::AIFloat3& pos);
	// D-101: a set of up to `count` footprints of cdef, the first flush against a
	// turret slot of nanoGroup, the rest lined up away from it; the first id, -1
	int PackSet(int zone, CCircuitDef* cdef, int nanoGroup, int facing, const springai::AIFloat3& anchor, int count, bool ring = false, int maximumGapCells = -1);
	// D-104: the footprint of cdef nearest flush against a turret slot of nanoGroup
	// (EdgeGap first, then the packer's order); needExit: a factory's exit clear
	bool PickFlushSite(int zone, CCircuitDef* cdef, int nanoGroup, int facing, const springai::AIFloat3& anchor, bool needExit,
			springai::AIFloat3& outPos, int& outGap, springai::AIFloat3& outTouch, int* outServedGap = nullptr, bool ring = false, int maximumGapCells = -1);
	// D-104: the clusters factories are packed against (the script registers them)
	void ClearFactoryZones() { factoryZones.clear(); }
	void AddFactoryZone(int zone, int group) { factoryZones.push_back(std::make_pair(zone, group)); }
	void SetFactoryFront(int facing) { factoryFront = facing; }
	// D-104: any factory, flush against a registered cluster's turrets: a ground
	// factory facing the front (else a side, never away), exit clear; an air
	// factory any facing, no exit test. -1 when no turret stands or no site
	int PackFactoryFlush(CCircuitDef* cdef, const springai::AIFloat3& anchor);
	static bool MakesAircraft(CCircuitAI* circuit, CCircuitDef* cdef);
	// D-101: the next unserved slot of cdef in a set, nearest its turret first; -1
	int NextSetSlot(CCircuitDef* cdef) const;
    // Scoped, bounded round-robin traversal. A rejected slot remains free for
    // other movement classes. -2 means budget exhausted, -1 no free candidates.
    int NextReachableSlot(CCircuitUnit* builder, const CCircuitDef* cdef, int zone, int group, int budget);
    // Physical losses only; queued replacement claims remain losses until a frame exists.
    int GetLostReservationCount(const CCircuitDef* cdef) const;
    int NextLostReservation(CCircuitUnit* builder, const CCircuitDef* cdef, int budget);
private:
    using SlotScope = std::pair<int, int>; // positive zone / negative group, def ID
    struct SlotCandidates { std::set<int> ids; int after = -1, visited = 0; bool sawFree = false; };
    std::map<SlotScope, SlotCandidates> scopedSlots;
    std::map<int, SlotCandidates> lostSlots;
    void ClearLostReservation(int id);
    void IndexReservation(int id);
    void EraseReservation(int id);
public:
	// D-101: the unserved slots of cdef's sets released; how many
	int ReleaseSetSlots(CCircuitDef* cdef);
	// D-101: cells between the footprint at pos and the nearest turret slot of the group
	int EdgeGapToGroup(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, int group) const;
	// D-101: the role's slot for native's replacement factory (the last factory gone); -1 = none
	void SetResetFactorySlot(int id) { resetFactorySlot = id; }
	int TakeResetFactorySlot() { const int id = resetFactorySlot; resetFactorySlot = -1; return id; }
	int resetFactorySlot = -1;
private:
	std::set<int> recycledSlots;   // D-101: reservation ids freed, not restored, when their structure goes
	std::set<int> setGroups;       // D-101: groups laid by PackSet
	std::vector<std::pair<int, int>> factoryZones;   // D-104: (zone, turret group), the main cluster first
	int factoryFront = -1;                            // D-104: the facing the labs face (Layout::LabFacing)
	void RemarkZoneCells(int2 c1, int2 c2);
	int ReserveZoneMasked(const springai::AIFloat3& centre, int facing, float halfAcross, float halfAlong,
		bool corridor, SBlockingMap::SM blockingMask);
	void OnStructureGone(CCircuitDef* cdef, const springai::AIFloat3& pos);
	int ReserveBuildingEx(CCircuitDef* cdef, const springai::AIFloat3& pos, int facing, int ttlFrames, int group,
			bool armed, bool anyReach, bool tenant, int zone, bool quiet, bool exitsPreflighted = false);
	int ReserveGridEx(CCircuitDef* cdef, const springai::AIFloat3& frontCentre, int facing, int cols, int rows, int gap,
			int ttlFrames, bool armed, bool anyReach, bool tenant, int zone, int group);
	bool FindReservedSite(CCircuitDef* cdef, const springai::AIFloat3& pos, TerrainPredicate& predicate,
			springai::AIFloat3& outPos, int& outFacing, int& outId, int facingFilter);
	std::unordered_map<CCircuitDef::Id, IBlockMask*> blockInfos;  // owner
	void MarkBlockerByMask(const SStructure& building, bool block, IBlockMask* mask);
	void MarkBlocker(const SStructure& building, bool block);
	void MarkZoneAlly(const springai::AIFloat3& pos, bool block);
	void MarkZoneOwn(const springai::AIFloat3& pos, bool block);

	struct FactoryPathQuery {
		std::shared_ptr<IPathQuery> query;
		const CCircuitDef* mobileDef;
		springai::AIFloat3 startPos;
		springai::AIFloat3 endPos;
		IndexVec targets;
	};
	struct WidePathInfo {
		std::shared_ptr<CPathInfo> pPath;
		int howWide;
	};
	std::map<CCircuitUnit*, WidePathInfo> busPath;
	std::map<CCircuitUnit*, FactoryPathQuery> busQueries;
	void MarkBusPath();
	void FillParentBusNodes(CPathInfo* pathInfo);

public:
	int GetConvertStoP() const { return terrainData->convertStoP; }
	int GetSectorXSize() const { return terrainData->sectorXSize; }
	int GetSectorZSize() const { return terrainData->sectorZSize; }
	static void CorrectPosition(springai::AIFloat3& position) { terrain::CTerrainData::CorrectPosition(position); }
	static springai::AIFloat3 CorrectPosition(const springai::AIFloat3& pos, const springai::AIFloat3& dir, float& len) {
		return terrain::CTerrainData::CorrectPosition(pos, dir, len);
	}
	static void SnapPosition(springai::AIFloat3& position);
	static springai::AIFloat3 Pos2BuildPos(CCircuitDef* cdef, const springai::AIFloat3& position, int facing);

	std::pair<terrain::SArea*, bool> GetCurrentMapArea(CCircuitDef* cdef, const springai::AIFloat3& position);
	std::pair<terrain::SArea*, bool> GetCurrentMapArea(CCircuitDef* cdef, const int indexSector);
	int GetSectorIndex(const springai::AIFloat3& position) const { return terrainData->GetSectorIndex(position); }
	bool CanMoveToPos(terrain::SArea* area, const springai::AIFloat3& destination);
	springai::AIFloat3 GetBuildPosition(CCircuitDef* cdef, const springai::AIFloat3& position);
	springai::AIFloat3 GetMovePosition(terrain::SArea* sourceArea, const springai::AIFloat3& position);
	springai::AIFloat3 ShiftPos(CCircuitDef* cdef, const springai::AIFloat3& position, float range, bool isOrtho = false);
	springai::AIFloat3 ShiftPos(CCircuitDef* cdef, const springai::AIFloat3& position, int clusterId, float range, bool isOrtho = false);
private:
	std::vector<terrain::SAreaSector>& GetSectorList(terrain::SArea* sourceArea = nullptr);
	terrain::SAreaSector* GetClosestSectorWithAltitude(terrain::SArea* sourceArea, const int destinationSIndex, const int altitude);
	terrain::SAreaSector* GetClosestSector(terrain::SArea* sourceArea, const int destinationSIndex);
	terrain::SSector* GetClosestSector(terrain::SImmobileType* sourceIT, const int destinationSIndex);
	// TODO: Refine brute-force algorithms
	terrain::SAreaSector* GetAlternativeSector(terrain::SArea* sourceArea, const int sourceSIndex, terrain::SMobileType* destinationMT);
	terrain::SSector* GetAlternativeSector(terrain::SArea* destinationArea, const int sourceSIndex, terrain::SImmobileType* destinationIT); // can return 0
	const terrain::SSector& GetSector(int sIndex) const { return areaData->sector[sIndex]; }
public:
	const std::vector<terrain::SMobileType>& GetMobileTypes() const {
		return areaData->mobileType;
	}
	terrain::SMobileType* GetMobileType(CCircuitDef::Id unitDefId) const {
		return GetMobileTypeById(terrainData->udMobileType[unitDefId]);
	}
	terrain::SMobileType::Id GetMobileTypeId(CCircuitDef::Id unitDefId) const {
		return terrainData->udMobileType[unitDefId];
	}
	terrain::SMobileType* GetMobileTypeById(terrain::SMobileType::Id id) const {
		return (id < 0) ? nullptr : &areaData->mobileType[id];
	}
	const std::vector<terrain::SImmobileType>& GetImmobileTypes() const {
		return areaData->immobileType;
	}
	terrain::SImmobileType* GetImmobileType(CCircuitDef::Id unitDefId) const {
		return GetImmobileTypeById(terrainData->udImmobileType[unitDefId]);
	}
	terrain::SImmobileType::Id GetImmobileTypeId(CCircuitDef::Id unitDefId) const {
		return terrainData->udMobileType[unitDefId];
	}
	terrain::SImmobileType* GetImmobileTypeById(terrain::SImmobileType::Id id) const {
		return (id < 0) ? nullptr : &areaData->immobileType[id];
	}

	// position must be valid
	bool CanBeBuiltAt(CCircuitDef* cdef, const springai::AIFloat3& position, const float range);  // NOTE: returns false if the area was too small to be recorded
	bool CanBeBuiltAt(CCircuitDef* cdef, const springai::AIFloat3& position);
	bool CanBeBuiltAtSafe(CCircuitDef* cdef, const springai::AIFloat3& position);
	bool CanReachAt(CCircuitUnit* unit, const springai::AIFloat3& destination, const float range);
	bool CanReachAtSafe(CCircuitUnit* unit, const springai::AIFloat3& destination, const float range, const float threat = THREAT_MIN);
	bool CanReachAtSafe2(CCircuitUnit* unit, const springai::AIFloat3& destination, const float range);
	bool CanMobileReachAt(terrain::SArea* area, const springai::AIFloat3& destination, const float range);
	bool CanMobileReachAtSafe(terrain::SArea* area, const springai::AIFloat3& destination, const float range, const float threat = THREAT_MIN);

	float GetLandPercent() const { return areaData->percentLand; }
	float GetMinLandPercent() const { return minLandPercent; }
	bool IsWaterAVoid() const { return terrainData->waterIsAVoid; }
	bool IsWaterMap() const { return !IsWaterAVoid() && GetLandPercent() < GetMinLandPercent(); }
	bool IsWaterSector(const springai::AIFloat3& position) const { return IsWaterSector(GetSectorIndex(position)); }
	bool IsWaterSector(const int sIndex) const { return areaData->sector[sIndex].isWater; }

	const bwem::CArea* GetTAArea(const springai::AIFloat3& pos) const;
	const std::vector<bwem::CChokePoint*>& GetTAChokePoints() const { return terrainData->GetChokePoints(); }
	const int GetTAMinAltitude(const springai::AIFloat3& pos) const {
		return terrainData->GetTASector(terrainData->GetSectorIndex(pos)).GetMinAltitude();
	}

	terrain::SAreaData* GetAreaData() const { return areaData; }
	void UpdateAreaUsers(int interval);
	void OnAreaUsersUpdated() { terrainData->OnAreaUsersUpdated(); }

	bool IsEnemyInArea(terrain::SArea* area) const {
		return enemyAreas.find(area) != enemyAreas.end();
	}

private:
	terrain::SAreaData* areaData;
	terrain::CTerrainData* terrainData;

	float minLandPercent;

	std::unordered_set<const terrain::SArea*> enemyAreas;

#ifdef DEBUG_VIS
private:
	int dbgTextureId;
	uint32_t sdlWindowId;
	float* dbgMap;
	bool isWidgetDrawing = false;
	void UpdateVis();
public:
	void ToggleVis();
	void ToggleWidgetDraw();

	void LogTerrainAt(CCircuitDef* cdef, const springai::AIFloat3& position);
#endif
};

} // namespace circuit

#endif // SRC_CIRCUIT_TERRAIN_TERRAINMANAGER_H_
