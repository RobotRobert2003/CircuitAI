/*
 * FieldCorridors.h
 *
 * D-358: the corridor planner (rjm.bar.docs/projects/circuitai/corridor-planner-proposal.md).
 * Engine-free, header plus FieldCorridors.cpp, run once per process on the
 * field job after the other stages, and the one definition of per-class
 * passability from the engine's own maps that every router reads:
 *
 *  - FinePassability: per movement class at the slope map's 16-elmo
 *    resolution (the lane legend of BattleLanes.cpp and BuildMobility's
 *    limits, applied to one sample each, so a one-cell gap stays open and its
 *    width is measured, not guessed). The 64-elmo lane grid and the field's
 *    32-elmo mobility are downsamples of it, never a second reading of the
 *    slope map.
 *  - BuildCorridors: obstacles (closed 16-elmo components big enough to
 *    matter), candidate routes between the two sides by the penalty method on
 *    the field grid, corridor classes by obstacle separation between laterally
 *    neighbouring routes (a wall over `seamBlocked` of the seam), a maximum
 *    clearance centre line per corridor and its record (length, narrowest
 *    point, width profile, specialist flag). Results in SModel::corridors and
 *    SModel::corridorOf[class].
 *  - Queries over the published model, O(1) or O(centre vertices): the
 *    corridor at a point (with a bounded nearest-open search), progress along
 *    a corridor from a side, the lateral order of a class's corridors.
 *
 * Complexity: O(N16) for passability, obstacles and clearance; O(N log N) per
 * candidate route and per corridor centre on the field grid, at most
 * corridorMax + corridors + 1 searches per class. No allocation after the
 * stage; the model is immutable once published. Tests: field_analysis_test
 * (synthetic isthmus and obstacle field, determinism, dumped-map replay).
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELD_FIELDCORRIDORS_H_
#define SRC_CIRCUIT_TERRAIN_FIELD_FIELDCORRIDORS_H_

#include "terrain/field/FieldGrid.h"
#include "terrain/field/FieldTypes.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

namespace circuit::field {

// The movedef limits (gamedata/movedefs.lua), one value per class family,
// shared with BattleLanes.cpp's legend through this header only.
constexpr float kSlopeTank = 0.109f;    // 1 - cos(27 deg): TANK2..HTANK4
constexpr float kSlopeHover = 0.161f;   // 1 - cos(33 deg): HOVER2..HHOVER4
constexpr float kSlopeBot = 0.412f;     // 1 - cos(54 deg): BOT2..HBOT7, amphibious on land
constexpr float kSlopeAllTerrain = 0.9998f;   // 1 - cos(89 deg): TBOT3, HTBOT6
constexpr float kWadeDepth = 20.f;      // land units stop 20 deep
constexpr float kShipDepth = 8.f;       // BOAT3..5
constexpr float kSubDepth = 15.f;       // UBOAT4
constexpr int kLegSnapCells = 8;        // D-359: field cells (Chebyshev) a leg's start may snap to reach open ground

// Per-class passability at 16 elmos (one slope sample a cell), from the
// engine height map (8-elmo samples) and slope map (16-elmo samples).
struct SFinePass {
	SGridShape g;
	std::vector<unsigned char> pass[_CLASSES_];   // 1 passable
	std::vector<float> hMean, hMax;               // per 16-elmo cell
	bool Pass(int cls, int c) const { return cls >= 0 && cls < _CLASSES_ && c >= 0 && c < g.Size() && pass[cls][c] != 0; }
};
void FinePassability(const std::vector<float>& slope, int slopeStride, int slopeRows,
					 const std::vector<float>& height, int heightStride, int heightRows,
					 bool waterHarmful, SFinePass& out);

// What BuildCorridors needs from the field context besides the input.
struct SCorridorContext {
	SGridShape g;                                   // the field grid
	int cell = 32;
	const std::vector<std::vector<int>>* sideSeeds = nullptr;   // per side, field cells inside the start box
	SPoint sideLabel[2];
	const std::vector<float>* hMean = nullptr;      // per field cell, for centre heights
};
// Fills m.obstacles, m.corridors, m.corridorOf. Throws Cancelled between classes.
void BuildCorridors(const SInput& in, const SCorridorContext& ctx, const SSettings& st,
					const std::atomic<bool>* cancel, SModel& m);

// ------------------------------------------------------------------ queries

// The lane grid's class (BattleAnalysis::LaneClass) to the field's; -1 for air.
inline int FieldClassOfLane(int laneClass)
{
	switch (laneClass) {
		case 0: return C_VEH; case 1: return C_BOT; case 2: return C_AMPH; case 3: return C_HOVER;
		case 4: return C_ALLT; case 5: return C_SHIP; default: return -1;
	}
}

// The corridor owning the open cell at (x, z) for the class, or the nearest
// open cell's within `searchCells` (Chebyshev) when the point stands on a
// closed cell (a start on a cliff edge, a cluster centre on a rock). -1 when
// none. O(searchCells^2).
inline int CorridorAt(const SModel& m, int cls, float x, float z, int searchCells = 4)
{
	if (cls < 0 || cls >= _CLASSES_ || m.gw <= 0 || m.gh <= 0 || m.cell <= 0) return -1;
	const auto& owner = m.corridorOf[cls];
	if (owner.size() != static_cast<std::size_t>(m.gw) * m.gh) return -1;
	const int cx = std::clamp((int)(x / m.cell), 0, m.gw - 1), cz = std::clamp((int)(z / m.cell), 0, m.gh - 1);
	if (owner[(std::size_t)cz * m.gw + cx] >= 0) return owner[(std::size_t)cz * m.gw + cx];
	int best = -1, bestD = searchCells * searchCells * 2 + 1;
	for (int dz = -searchCells; dz <= searchCells; ++dz) {
		for (int dx = -searchCells; dx <= searchCells; ++dx) {
			const int nx = cx + dx, nz = cz + dz;
			if (nx < 0 || nz < 0 || nx >= m.gw || nz >= m.gh) continue;
			const int o = owner[(std::size_t)nz * m.gw + nx];
			const int d = dx * dx + dz * dz;
			if (o >= 0 && (d < bestD || (d == bestD && o < best))) { bestD = d; best = o; }
		}
	}
	return best;
}

// Progress 0..1 along the centre from side 0 to side 1 of the nearest point
// to (x, z); `distance` receives the 2D distance to the centre. O(vertices).
inline float CorridorProgress(const SCorridor& c, float x, float z, float* distance = nullptr)
{
	if (c.centre.size() < 2) { if (distance) *distance = 0.f; return 0.f; }
	float best = 1e30f, at = 0.f, walked = 0.f, total = 0.f;
	for (std::size_t i = 1; i < c.centre.size(); ++i) {
		const SPoint& a = c.centre[i - 1]; const SPoint& b = c.centre[i];
		const float dx = b.x - a.x, dz = b.z - a.z, len2 = dx * dx + dz * dz, len = std::sqrt(len2);
		const float u = len2 > 0.f ? std::clamp(((x - a.x) * dx + (z - a.z) * dz) / len2, 0.f, 1.f) : 0.f;
		const float px = a.x + dx * u - x, pz = a.z + dz * u - z;
		const float d = std::sqrt(px * px + pz * pz);
		if (d < best) { best = d; at = walked + len * u; }
		walked += len;
		total = walked;
	}
	if (distance) *distance = best;
	return total > 0.f ? std::clamp(at / total, 0.f, 1.f) : 0.f;
}

// The side (index into m.sides) an ally team belongs to; -1 unknown (synthetic sides).
inline int SideOfAllyTeam(const SModel& m, int allyTeam)
{
	for (std::size_t s = 0; s < m.sides.size(); ++s) if (m.sides[s].allyTeam == allyTeam) return (int)s;
	return -1;
}

// Progress seen from a side: 0 at that side's end, 1 at the enemy's.
inline float CorridorProgressFrom(const SCorridor& c, int side, float x, float z, float* distance = nullptr)
{
	const float p = CorridorProgress(c, x, z, distance);
	return side == 1 ? 1.f - p : p;
}

// The point at a progress along the centre (0..1 from side 0).
inline SPoint CorridorPoint(const SCorridor& c, float progress)
{
	if (c.centre.empty()) return {-1.f, -1.f};
	if (c.centre.size() == 1) return c.centre.front();
	float total = 0.f;
	for (std::size_t i = 1; i < c.centre.size(); ++i) total += std::hypot(c.centre[i].x - c.centre[i - 1].x, c.centre[i].z - c.centre[i - 1].z);
	float want = std::clamp(progress, 0.f, 1.f) * total, walked = 0.f;
	for (std::size_t i = 1; i < c.centre.size(); ++i) {
		const SPoint& a = c.centre[i - 1]; const SPoint& b = c.centre[i];
		const float len = std::hypot(b.x - a.x, b.z - a.z);
		if (walked + len >= want || i + 1 == c.centre.size()) {
			const float u = len > 0.f ? std::clamp((want - walked) / len, 0.f, 1.f) : 0.f;
			return {a.x + (b.x - a.x) * u, a.z + (b.z - a.z) * u};
		}
		walked += len;
	}
	return c.centre.back();
}

// The corridors of a class at least `minWidth` wide at the choke, in lateral
// order along the given axis (negative side first, the same signed test the
// coverage script sorts its seats with). O(corridors log corridors).
inline std::vector<int> CorridorsOrdered(const SModel& m, int cls, SPoint axisFrom, SPoint axisTo, float minWidth)
{
	std::vector<std::pair<float, int>> order;
	const float ax = axisTo.x - axisFrom.x, az = axisTo.z - axisFrom.z;
	for (const SCorridor& c : m.corridors) {
		if (c.cls != cls || c.centre.empty() || c.narrowest < minWidth) continue;
		const SPoint mid = CorridorPoint(c, 0.5f);
		const float side = -(mid.x - axisFrom.x) * az + (mid.z - axisFrom.z) * ax;
		order.emplace_back(side, c.id);
	}
	std::sort(order.begin(), order.end());
	std::vector<int> out;
	out.reserve(order.size());
	for (const auto& [side, id] : order) out.push_back(id);
	return out;
}

// D-359: a route on the field grid from a point to a corridor's centre line
// over the cells the class's ownership raster marks open (open and connected
// to the corridor system), eight neighbours without corner cutting, unit
// cost: the approach legs of a front lane and the link of an assisting fork,
// so no published lane segment crosses closed ground. The point snaps to the
// nearest open cell within `snapCells` (Chebyshev). Returns the cell-centre
// polyline from the snapped cell to the centre vertex nearest by travel
// (collinear interior points dropped) and sets *vertex to that index; empty
// with *vertex -1 when the corridor is unreachable. O(N log N) on the field
// grid, run once per lane assignment or fork, never per frame.
std::vector<SPoint> RouteToCentre(const SModel& m, int cls, SPoint from, const SCorridor& c, int* vertex, int snapCells = kLegSnapCells);

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDCORRIDORS_H_
