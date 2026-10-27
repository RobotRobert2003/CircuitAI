#pragma once

// Engine-free tiered target choice for a super weapon whose script hands it a
// roster of target defs in tiers (lolcannons, owner 2026-10-26). CSuperTask
// feeds every enemy of the roster in range through Better(); the policy - which
// defs, which tier - stays in script (systems/construction/lolcannon.as).

#include <algorithm>
#include <numeric>
#include <vector>

namespace circuit::tier {

struct Candidate {
	int id;        // enemy unit id
	int tier;      // 1 fires first
	float cost;    // metal
	float sqDist;  // squared 2D distance from the weapon
	float x = 0.f, z = 0.f;  // map position (areas)
};

// Does `c` beat `best`? The lower tier wins. Inside a tier the target already
// under fire (currentId) is kept while it is a candidate, so a rapid-fire gun
// does not swing between two equal targets; else the dearer, then the nearer.
inline bool Better(const Candidate& c, const Candidate* best, int currentId)
{
	if (best == nullptr) return true;
	if (c.tier != best->tier) return c.tier < best->tier;
	if (best->id == currentId) return false;
	if (c.id == currentId) return true;
	if (c.cost != best->cost) return c.cost > best->cost;
	return c.sqDist < best->sqDist;
}

// The rank before any grouping: lower tier, dearer, nearer, lower id.
inline bool Ranks(const Candidate& a, const Candidate& b)
{
	if (a.tier != b.tier) return a.tier < b.tier;
	if (a.cost != b.cost) return a.cost > b.cost;
	if (a.sqDist != b.sqDist) return a.sqDist < b.sqDist;
	return a.id < b.id;
}

/*
 * Areas (owner 2026-10-27): the gun works through target areas, not single
 * targets. The best target left seeds an area; every candidate left within
 * `radius` of it joins. An area ranks by its best tier, then by the metal of
 * its roster targets; it is aimed at its best target (Better, so the one under
 * fire is kept inside its tier). O(candidates x areas), and it stops once
 * maxAreas are formed and no later seed can rank among them.
 */
struct Area {
	int seedId;    // the area's best target: it names the area
	int tier;      // the best tier in it
	float metal;   // the metal of all roster targets in it
	float x, z;    // the seed's position
	int aim;       // index into the candidates: the target to fire at
};

inline bool AreaRanks(const Area& a, const Area& b)
{
	if (a.tier != b.tier) return a.tier < b.tier;
	return a.metal > b.metal;
}

inline std::vector<Area> BuildAreas(const std::vector<Candidate>& cs, float radius, int currentId, size_t maxAreas)
{
	std::vector<size_t> order(cs.size());
	std::iota(order.begin(), order.end(), size_t(0));
	std::sort(order.begin(), order.end(), [&cs](size_t a, size_t b) { return Ranks(cs[a], cs[b]); });
	std::vector<bool> taken(cs.size(), false);
	std::vector<Area> areas;
	const float sqRadius = radius * radius;
	for (size_t o = 0; o < order.size(); ++o) {
		const Candidate& seed = cs[order[o]];
		if (taken[order[o]]) continue;
		if ((areas.size() >= maxAreas) && (seed.tier > areas.back().tier)) break;
		Area a{seed.id, seed.tier, 0.f, seed.x, seed.z, int(order[o])};
		for (size_t k = o; k < order.size(); ++k) {
			const size_t j = order[k];
			if (taken[j]) continue;
			const float dx = cs[j].x - seed.x, dz = cs[j].z - seed.z;
			if (dx * dx + dz * dz > sqRadius) continue;
			taken[j] = true;
			a.metal += cs[j].cost;
			if (Better(cs[j], &cs[a.aim], currentId)) a.aim = int(j);
		}
		areas.push_back(a);
	}
	std::stable_sort(areas.begin(), areas.end(), AreaRanks);
	if (areas.size() > maxAreas) areas.resize(maxAreas);
	return areas;
}

/*
 * The rotation through the areas (owner 2026-10-27), like the nuke silo's
 * no-repeat: Ragnarok and Calamity dwell on an area for a time, Starfall for a
 * number of shots, then the next area down, and from the last back to the top.
 */
struct Rotation {
	int index = 0;    // the area under fire, 0 = the top
	int since = 0;    // the frame it took that area
	int shots = 0;    // shots fired at that area
	int topId = -1;   // the top area's seed at the last scan
};

// Fresh scouting changed the top area: its old seed is gone (dead, or out of
// sight for a mobile one), or the new seed is a target the last scan did not
// have. A reshuffle among targets already known is not fresh news.
inline bool TopChanged(int oldTop, int newTop, bool oldTopStill, bool newTopSeenBefore)
{
	return (newTop != oldTop) && ((oldTop < 0) || !oldTopStill || !newTopSeenBefore);
}

inline void Restart(Rotation& r, int frame)
{
	r.index = 0;
	r.since = frame;
	r.shots = 0;
}

// The next area once the dwell is up (dwellShots > 0 counts shots, else
// frames); areas is how many there are now. True when the area changed.
inline bool Advance(Rotation& r, int areas, int frame, int dwellFrames, int dwellShots)
{
	if (r.index >= areas) {
		const bool moved = (r.index != 0);
		Restart(r, frame);
		return moved;
	}
	const bool due = (dwellShots > 0) ? (r.shots >= dwellShots) : (frame - r.since >= dwellFrames);
	if (!due) return false;
	const int next = (r.index + 1) % areas;
	const bool moved = (next != r.index);
	r.index = next;
	r.since = frame;
	r.shots = 0;
	return moved;
}

} // namespace circuit::tier
