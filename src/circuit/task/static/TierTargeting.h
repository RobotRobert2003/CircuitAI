#pragma once

#include <algorithm>
#include <vector>

// Engine-free tiered target choice for a super weapon whose script hands it a
// roster of target defs in tiers (lolcannons, owner 2026-10-26). CSuperTask
// feeds every enemy of the roster in range through Better(); the policy - which
// defs, which tier - stays in script (systems/construction/lolcannon.as).
namespace circuit::tier {

struct Candidate {
	int id;        // enemy unit id
	int tier;      // 1 fires first
	float cost;    // metal
	float sqDist;  // squared 2D distance from the weapon
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

// Target areas (owner 2026-10-27): the roster targets in range, best first,
// grouped round each area's best target (a target within `radius` of an area's
// anchor joins it). At most `maxAreas` areas; the rest are dropped.
struct Ranked {
	Candidate c;
	float x, z;
};

struct Area {
	int bestId;    // the area's best target, fired at while the area is chosen
	int tier;
	float cost;
	float x, z;    // the best target's position, the area's anchor
	int members;   // roster targets in the area
};

inline std::vector<Area> BuildAreas(std::vector<Ranked> ranked, float radius, int maxAreas)
{
	std::stable_sort(ranked.begin(), ranked.end(), [](const Ranked& a, const Ranked& b) {
		return Better(a.c, &b.c, -1) && !Better(b.c, &a.c, -1);
	});
	std::vector<Area> areas;
	const float sqRadius = radius * radius;
	for (const Ranked& r : ranked) {
		bool joined = false;
		for (Area& a : areas) {
			const float dx = r.x - a.x, dz = r.z - a.z;
			if (dx * dx + dz * dz <= sqRadius) { ++a.members; joined = true; break; }
		}
		if (joined) continue;
		if (int(areas.size()) >= maxAreas) continue;
		areas.push_back(Area{r.c.id, r.c.tier, r.c.cost, r.x, r.z, 1});
	}
	return areas;
}

// The area rotation (owner 2026-10-27, the nuke's "not the same site twice in a
// row"): fire at area 0, then 1, 2, ... for `dwellFrames` each (rapid fire:
// Ragnarok, Calamity) or for `shotsPerArea` shots each (Starfall), then back to
// area 0 of the fresh list. When the highest-rated target changes (it died, it
// was scouted gone, a better one was seen) the rotation starts over at area 0.
struct Rotation {
	int index = 0;        // the area under fire
	int since = -1;       // the frame it was chosen
	int shots = 0;        // shots fired at it
	int topId = -1;       // area 0's best target when the rotation last started over

	// The area to fire at now, -1 none. `restarted`: the top changed;
	// `moved`: the rotation went on to another area this call.
	int Pick(const std::vector<Area>& areas, int frame, int dwellFrames, int shotsPerArea,
			bool& restarted, bool& moved)
	{
		restarted = moved = false;
		if (areas.empty()) {
			index = 0; since = -1; shots = 0; topId = -1;
			return -1;
		}
		if (areas[0].bestId != topId) {
			topId = areas[0].bestId;
			index = 0; since = frame; shots = 0;
			restarted = true;
			return 0;
		}
		const bool due = ((dwellFrames > 0) && (frame - since >= dwellFrames))
			|| ((shotsPerArea > 0) && (shots >= shotsPerArea));
		if (due && (areas.size() > 1)) {
			index = (index + 1 < int(areas.size())) ? index + 1 : 0;
			since = frame; shots = 0;
			moved = true;
		} else if (due) {
			since = frame; shots = 0;   // one area only: stay on it
		}
		if (index >= int(areas.size())) {
			index = 0; since = frame; shots = 0;
			moved = true;
		}
		return index;
	}
	void OnShot() { ++shots; }
};

} // namespace circuit::tier
