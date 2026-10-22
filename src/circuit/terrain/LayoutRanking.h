#ifndef SRC_CIRCUIT_TERRAIN_LAYOUTRANKING_H_
#define SRC_CIRCUIT_TERRAIN_LAYOUTRANKING_H_

// D-094: the pure ranking rules of the TECH layout, free of engine types so
// they can be unit-tested (tests/layout_ranking_test.cpp). CTerrainManager
// gathers slots, footprints and grid cells from its own state and asks these
// functions which one comes first; every rule lives here once.
//
//   NextConnected      - the next turret slot of a block (D-077, D-081)
//   TurretDistanceSq   - served turrets outrank planned ones (D-083)
//   PackBefore         - the order structures are packed in (D-066, D-088)
//   WeightedSlots,
//   SiteBefore         - the advanced lab's site (D-085, D-087, D-095, D-096)
//   AheadOf            - a site on the side of the block its exit points to (D-096)
//   CellRect, Overlaps - a footprint against the factories' exit lanes (D-096)
//   LeavesPocket       - a footprint may not wall off free cells (D-072, D-090)
//   HullPathClear      - a hull of a given width can still sail between two points (D-343)
//   RingOrder          - the points a drop-spot search tries, nearest first (D-091)

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <limits>
#include <utility>
#include <vector>

namespace circuit::layout_rank {

// Opt-in facing passes must not consume a differently oriented reservation:
// the footprint and exit predicate were evaluated for this pass's facing.
// A negative filter retains the legacy reservation preference for other roles.
inline bool MatchesFacingPass(int actual, int filter) {
    return filter < 0 || actual == filter;
}

struct Pt {
	float x = 0.f;
	float z = 0.f;
};

inline float Sq(const Pt& a, const Pt& b)
{
	const float dx = a.x - b.x, dz = a.z - b.z;
	return dx * dx + dz * dz;
}

inline float Dist(const Pt& a, const Pt& b)
{
	return std::sqrt(Sq(a, b));
}

struct SupportReach {
	Pt position;
	float radius;
};

// Every member of a packed set needs support, not just the seed. The caller
// prepares this small group once per packing operation; no engine callbacks
// or allocations occur per candidate. O(group size), with an existence exit.
inline bool WithinSupport(const Pt& site, const std::vector<SupportReach>& sources)
{
	for (const auto& source : sources) {
		if (source.radius > 0.f && Sq(site, source.position) <= source.radius * source.radius) return true;
	}
	return false;
}

// D-229: only completed, owned static assistants enter this snapshot. Future
// reserved turrets deliberately contribute nothing. Speeds may be expressed
// per frame or per second, provided every source uses the same unit.
struct BuiltPower {
	Pt pos;
	float reachSq;
	float speed;
};

inline float PowerAt(const Pt& site, const std::vector<BuiltPower>& sources)
{
	float sum = 0.f;
	for (const auto& source : sources) {
		if (Sq(site, source.pos) <= source.reachSq) sum += source.speed;
	}
	return sum;
}

inline bool BuiltPowerBefore(float powerA, float distanceA, float powerB, float distanceB)
{
	return powerA != powerB ? powerA > powerB : distanceA < distanceB;
}

// The mean of pts; `fallback` when there is none.
inline Pt Centroid(const std::vector<Pt>& pts, const Pt& fallback)
{
	if (pts.empty()) {
		return fallback;
	}
	Pt c;
	for (const Pt& p : pts) {
		c.x += p.x;
		c.z += p.z;
	}
	c.x /= float(pts.size());
	c.z /= float(pts.size());
	return c;
}

// D-096: the unit forward vector of an engine facing (SOUTH 0 +z, EAST 1 +x,
// NORTH 2 -z, WEST 3 -x).
inline Pt FacingForward(int facing)
{
	switch (facing) {
		case 1: return Pt{1.f, 0.f};
		case 2: return Pt{0.f, -1.f};
		case 3: return Pt{-1.f, 0.f};
		default: return Pt{0.f, 1.f};
	}
}

// D-096: the site stands on the side of the block its exit points to: ahead of
// the slots' centroid along `fwd`. False with no slots.
inline bool AheadOf(const Pt& site, const std::vector<Pt>& slots, const Pt& fwd)
{
	if (slots.empty()) {
		return false;
	}
	const Pt c = Centroid(slots, site);
	return (site.x - c.x) * fwd.x + (site.z - c.z) * fwd.z > 0.f;
}

// D-096: a cell rectangle [x1, x2) x [z1, z2).
struct CellRect {
	int x1 = 0, z1 = 0, x2 = 0, z2 = 0;
};

inline bool Overlaps(const CellRect& a, const CellRect& b)
{
	return (a.x1 < b.x2) && (b.x1 < a.x2) && (a.z1 < b.z2) && (b.z1 < a.z2);
}

// D-099: `inner` lies wholly inside `outer`
inline bool Inside(const CellRect& inner, const CellRect& outer)
{
	return (inner.x1 >= outer.x1) && (inner.x2 <= outer.x2) && (inner.z1 >= outer.z1) && (inner.z2 <= outer.z2);
}

// D-101: the cells between two footprints, 0 when they touch or overlap
// (the larger of the gaps along x and z: a diagonal neighbour one cell off is 1)
inline int EdgeGap(const CellRect& a, const CellRect& b)
{
	const int gx = std::max(0, std::max(b.x1 - a.x2, a.x1 - b.x2));
	const int gz = std::max(0, std::max(b.z1 - a.z2, a.z1 - b.z2));
	return std::max(gx, gz);
}

// D-101: the smallest EdgeGap from `r` to any of `others`; a large number when none
inline int NearestEdgeGap(const CellRect& r, const std::vector<CellRect>& others)
{
	int best = 1 << 20;
	for (const CellRect& o : others) {
		best = std::min(best, EdgeGap(r, o));
	}
	return best;
}

// D-101: the unit step (cells) a set of footprints grows by, away from the
// turret it touches: along the axis where the site lies further from the
// turret's centre, footprint-sized. (0, 0) when the centres coincide.
inline void SetStep(float siteX, float siteZ, float turretX, float turretZ, int sizeX, int sizeZ, int& stepX, int& stepZ)
{
	const float dx = siteX - turretX, dz = siteZ - turretZ;
	stepX = 0; stepZ = 0;
	if ((dx == 0.f) && (dz == 0.f)) {
		return;
	}
	if (std::fabs(dx) >= std::fabs(dz)) {
		stepX = (dx > 0.f) ? sizeX : -sizeX;
	} else {
		stepZ = (dz > 0.f) ? sizeZ : -sizeZ;
	}
}

inline bool OverlapsAny(const CellRect& r, const std::vector<CellRect>& lanes)
{
	for (const CellRect& l : lanes) {
		if (Overlaps(r, l)) {
			return true;
		}
	}
	return false;
}

// Squared distance from p to the nearest of pts; max float when none.
inline float NearestSq(const Pt& p, const std::vector<Pt>& pts)
{
	float best = std::numeric_limits<float>::max();
	for (const Pt& q : pts) {
		best = std::min(best, Sq(p, q));
	}
	return best;
}

// D-077/D-081: the index into `freeSlots` of the next turret of a block. With
// nothing taken, the slot nearest the seed; otherwise the slot touching the
// block (distance to its nearest taken slot) nearest the block's centroid, so
// the block fills across every row from its middle. -1 when none is free.
inline int NextConnected(const std::vector<Pt>& freeSlots, const std::vector<Pt>& taken, const Pt& seed)
{
	const Pt centroid = Centroid(taken, seed);
	int best = -1;
	float bestScore = std::numeric_limits<float>::max();
	for (std::size_t i = 0; i < freeSlots.size(); ++i) {
		const float toCentroid = Dist(freeSlots[i], centroid);
		const float score = taken.empty() ? toCentroid : (std::sqrt(NearestSq(freeSlots[i], taken)) + toCentroid);
		if (score < bestScore) {
			bestScore = score;
			best = int(i);
		}
	}
	return best;
}

// D-083: the rank distance to the turrets. A served slot (a turret stands or is
// being built) counts at its distance; a planned one `plannedPenalty` elmos
// further. Inputs are squared distances (max float for none).
inline float TurretDistanceSq(float servedSq, float plannedSq, float plannedPenalty)
{
	if (plannedSq < std::numeric_limits<float>::max()) {
		const float d = std::sqrt(plannedSq) + plannedPenalty;
		plannedSq = d * d;
	}
	return std::min(servedSq, plannedSq);
}

// The keys a packing candidate is ranked by.
struct PackKey {
	float turretSq = 0.f;  // TurretDistanceSq
	float anchorSq = 0.f;  // to the asking builder or the seed: the tie-break
	float groupSq = std::numeric_limits<float>::max();  // D-088: to the centroid of the same-def group
};

// D-066/D-088: same-def structures first grow their own group as a filled
// block (nearest its centroid), then nearest a turret, then nearest the anchor.
inline bool PackBefore(const PackKey& a, const PackKey& b, bool grouped)
{
	if (grouped && (a.groupSq != b.groupSq)) {
		return a.groupSq < b.groupSq;
	}
	if (a.turretSq != b.turretSq) {
		return a.turretSq < b.turretSq;
	}
	return a.anchorSq < b.anchorSq;
}

struct Slot {
	Pt pos;
	bool served = false;
};

// D-085: true when any slot lies within seedRadius of the seed.
inline bool AnyNearSeed(const std::vector<Slot>& slots, const Pt& seed, float seedRadius)
{
	const float r2 = seedRadius * seedRadius;
	for (const Slot& s : slots) {
		if (Sq(s.pos, seed) <= r2) {
			return true;
		}
	}
	return false;
}

// D-085: the build power a lab site would see. A served slot within reach
// counts servedWeight, a planned one 1 - and only within seedRadius of the
// seed when any slot is that near (the slots the block fills first).
inline int WeightedSlots(const Pt& site, const std::vector<Slot>& slots, float reach,
		const Pt& seed, float seedRadius, int servedWeight)
{
	const bool nearSeed = AnyNearSeed(slots, seed, seedRadius);
	const float reach2 = reach * reach, seed2 = seedRadius * seedRadius;
	int n = 0;
	for (const Slot& s : slots) {
		if (Sq(s.pos, site) > reach2) {
			continue;
		}
		if (s.served) {
			n += servedWeight;
		} else if (!nearSeed || (Sq(s.pos, seed) <= seed2)) {
			n += 1;
		}
	}
	return n;
}

// The keys a lab site is ranked by.
struct SiteKey {
	int slots = 0;          // WeightedSlots capped at `enough` (D-087)
	bool ahead = false;     // D-096: on the side of the block the exit points to
	bool flush = false;     // D-095: a turret slot within the flush distance
	float seedDist = 0.f;   // to the seed: nearer wins among equals (D-085)
	float turretSq = 0.f;   // the last tie-break
	Pt pos;
};

// `slotSq`: to the nearest turret slot of any kind, unpenalised; `flushDist` <= 0
// turns the D-095 key off.
inline SiteKey MakeSiteKey(const Pt& site, int weightedSlots, int enough, const Pt& seed, float turretSq,
		float slotSq = std::numeric_limits<float>::max(), float flushDist = 0.f, bool ahead = false)
{
	const bool flush = (flushDist > 0.f) && (slotSq <= flushDist * flushDist);
	return SiteKey{std::min(weightedSlots, enough), ahead, flush, Dist(site, seed), turretSq, site};
}

// D-085/D-087/D-095/D-096: more slots (up to enough) first, then ahead of the
// block (the owner's rule: the lab stands on the front side, its units walk out
// toward the enemy), then flush with a turret slot (the lab touches its turrets
// as the T1 lab touches its nanos), then nearer the seed (1 elmo counts as
// equal), then nearer a turret.
inline bool SiteBefore(const SiteKey& a, const SiteKey& b)
{
	if (a.slots != b.slots) {
		return a.slots > b.slots;
	}
	if (a.ahead != b.ahead) {
		return a.ahead;
	}
	if (a.flush != b.flush) {
		return a.flush;
	}
	if (std::fabs(a.seedDist - b.seedDist) > 1.f) {
		return a.seedDist < b.seedDist;
	}
	return a.turretSq < b.turretSq;
}

// D-072/D-090: `open` is a w x h grid (row-major) of cells a unit could stand on
// once the footprint stands (the footprint's own cells false). True when some
// open cell is not connected (4-neighbour) to the grid's border.
inline bool LeavesPocket(const std::vector<char>& open, int w, int h)
{
	if ((w <= 0) || (h <= 0) || (int(open.size()) < w * h)) {
		return false;
	}
	std::vector<char> seen(std::size_t(w) * h, 0);
	std::vector<int> stack;
	for (int y = 0; y < h; ++y) {
		for (int x = 0; x < w; ++x) {
			const int i = y * w + x;
			if (((x == 0) || (x == w - 1) || (y == 0) || (y == h - 1)) && open[i] && !seen[i]) {
				seen[i] = 1;
				stack.push_back(i);
			}
		}
	}
	while (!stack.empty()) {
		const int i = stack.back();
		stack.pop_back();
		const int x = i % w, y = i / w;
		const int nb[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
		for (const auto& d : nb) {
			const int nx = x + d[0], ny = y + d[1];
			if ((nx < 0) || (ny < 0) || (nx >= w) || (ny >= h)) {
				continue;
			}
			const int j = ny * w + nx;
			if (open[j] && !seen[j]) {
				seen[j] = 1;
				stack.push_back(j);
			}
		}
	}
	for (int i = 0; i < w * h; ++i) {
		if (open[i] && !seen[i]) {
			return true;
		}
	}
	return false;
}

// D-343: can a hull of half-width `clearance` cells travel between two cells
// of a local window? `open` is 1 for navigable, unoccupied water. A cell is
// usable when every cell within Chebyshev distance `clearance` is open (cells
// outside the window count as open: the caller pads the window). The start
// and goal snap to the nearest usable cell within `snap` cells, because a
// shipyard mouth or a repair spot sits next to the footprints it serves.
// Time and memory O(w*h): one two-pass distance transform, one 4-way flood.
inline bool HullPathClear(const std::vector<char>& open, int w, int h,
	int fromX, int fromZ, int toX, int toZ, int clearance, int snap)
{
	if ((w <= 0) || (h <= 0) || (int(open.size()) < w * h) || (clearance < 0) || (snap < 0)) {
		return false;
	}
	const auto inside = [&](int x, int z) { return (x >= 0) && (z >= 0) && (x < w) && (z < h); };
	if (!inside(fromX, fromZ) || !inside(toX, toZ)) {
		return false;
	}
	// Chebyshev distance to the nearest blocked cell (outside the window is open).
	const int unreached = w + h;  // not "far": a Windows macro
	std::vector<int> dist(std::size_t(w) * h, unreached);
	for (int i = 0; i < w * h; ++i) {
		if (!open[i]) dist[i] = 0;
	}
	for (int z = 0; z < h; ++z) {
		for (int x = 0; x < w; ++x) {
			int& d = dist[z * w + x];
			if (d == 0) continue;
			if (x > 0) d = std::min(d, dist[z * w + x - 1] + 1);
			if (z > 0) {
				d = std::min(d, dist[(z - 1) * w + x] + 1);
				if (x > 0) d = std::min(d, dist[(z - 1) * w + x - 1] + 1);
				if (x + 1 < w) d = std::min(d, dist[(z - 1) * w + x + 1] + 1);
			}
		}
	}
	for (int z = h - 1; z >= 0; --z) {
		for (int x = w - 1; x >= 0; --x) {
			int& d = dist[z * w + x];
			if (d == 0) continue;
			if (x + 1 < w) d = std::min(d, dist[z * w + x + 1] + 1);
			if (z + 1 < h) {
				d = std::min(d, dist[(z + 1) * w + x] + 1);
				if (x + 1 < w) d = std::min(d, dist[(z + 1) * w + x + 1] + 1);
				if (x > 0) d = std::min(d, dist[(z + 1) * w + x - 1] + 1);
			}
		}
	}
	// dist counts the blocked cell itself as 0, so a cell is usable when its
	// nearest blocked cell is more than `clearance` cells away.
	const auto usable = [&](int x, int z) { return dist[z * w + x] > clearance; };
	std::vector<char> seen(std::size_t(w) * h, 0);
	std::vector<int> queue;
	for (int z = std::max(0, fromZ - snap); z <= std::min(h - 1, fromZ + snap); ++z) {
		for (int x = std::max(0, fromX - snap); x <= std::min(w - 1, fromX + snap); ++x) {
			if (usable(x, z)) { seen[z * w + x] = 1; queue.push_back(z * w + x); }
		}
	}
	const auto goal = [&](int x, int z) {
		return std::abs(x - toX) <= snap && std::abs(z - toZ) <= snap;
	};
	for (std::size_t head = 0; head < queue.size(); ++head) {
		const int i = queue[head], x = i % w, z = i / w;
		if (goal(x, z)) return true;
		const int nx[4] = {x - 1, x + 1, x, x}, nz[4] = {z, z, z - 1, z + 1};
		for (int k = 0; k < 4; ++k) {
			if (!inside(nx[k], nz[k])) continue;
			const int j = nz[k] * w + nx[k];
			if (seen[j] || !usable(nx[k], nz[k])) continue;
			seen[j] = 1;
			queue.push_back(j);
		}
	}
	return false;
}

// D-091: the points a spot search tries, nearest first: the centre, then rings
// every `step` elmos out to maxRadius, `bearings` points a ring.
inline std::vector<Pt> RingOrder(const Pt& around, float maxRadius, float step, int bearings)
{
	std::vector<Pt> out;
	if ((step <= 0.f) || (bearings <= 0)) {
		return out;
	}
	for (float r = 0.f; r <= maxRadius; r += step) {
		const int n = (r < 1.f) ? 1 : bearings;
		for (int k = 0; k < n; ++k) {
			const float a = 6.2831853f * float(k) / float(n);
			out.push_back(Pt{around.x + std::cos(a) * r, around.z + std::sin(a) * r});
		}
	}
	return out;
}

// True when p is at least avoidRadius from every point of avoid.
inline bool ClearOf(const Pt& p, const std::vector<Pt>& avoid, float avoidRadius)
{
	return NearestSq(p, avoid) >= avoidRadius * avoidRadius;
}

}  // namespace circuit::layout_rank

#endif  // SRC_CIRCUIT_TERRAIN_LAYOUTRANKING_H_
