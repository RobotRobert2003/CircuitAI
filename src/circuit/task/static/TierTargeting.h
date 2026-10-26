#pragma once

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

} // namespace circuit::tier
