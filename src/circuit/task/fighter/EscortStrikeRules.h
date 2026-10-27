/*
 * EscortStrikeRules.h
 *
 * Engine-free decisions of CEscortStrikeTask (tests/escort_strike_test.cpp).
 * The task supplies live state; these say what to order and when not to.
 */
#ifndef CIRCUIT_ESCORT_STRIKE_RULES_H
#define CIRCUIT_ESCORT_STRIKE_RULES_H

namespace circuit::escort_strike {

// A contact a striker may break off for: an allowed def (priority > 0) within
// reach and in sight now. A radar dot or a structure only remembered keeps the
// striker on its guard (owner 2026-10-25: they broke off before seeing one).
inline bool StrikeCandidate(float priority, bool visible, float distanceSq, float radius)
{
	return priority > 0.f && visible && radius > 0.f
		&& distanceSq >= 0.f && distanceSq <= radius * radius;
}

// Siege mode (TECH capital rush without an AIR ally, owner 2026-10-26): any
// allowed def that has been scouted, wherever it is and whether or not it is in
// sight now; out of sight the strike bombs its last known spot (as a Juno does).
inline bool SiegeCandidate(float priority, bool scouted)
{
	return priority > 0.f && scouted;
}

// A siege strike ends only when its target no longer exists; an expired or
// finished order is given again on the same target.
inline bool SiegeStrikeOver(bool targetGone)
{
	return targetGone;
}

// A strike follows its target by unit while it is in sight; once it drops out
// of sight it bombs the spot where it was last seen (one ATTACK ground), and
// takes the unit again if it is seen again.
inline bool NeedsGroundStrike(bool groundOrder, bool visible)
{
	return !groundOrder && !visible;
}
inline bool NeedsUnitStrike(bool groundOrder, bool visible)
{
	return groundOrder && visible;
}

// Highest priority first, then nearest, then the lower id (deterministic).
inline bool BetterStrike(float priority, float distanceSq, int id, float bestPriority, float bestDistanceSq, int bestId)
{
	if (bestId < 0) return true;
	if (priority != bestPriority) return priority > bestPriority;
	if (distanceSq != bestDistanceSq) return distanceSq < bestDistanceSq;
	return id < bestId;
}

// cap <= 0: no limit on strikers per target.
inline bool HasStrikeRoom(int attackers, int cap)
{
	return cap <= 0 || attackers < cap;
}

// An attack ends when its target is gone or its order expired; the striker
// then rejoins the escort.
inline bool StrikeOver(bool targetGone, int frame, int until)
{
	return targetGone || frame >= until;
}

// One GUARD per escort change: only when the striker is not already guarding
// this vip, and never twice inside minGap frames (an idle storm or a swap in
// the same second must not re-issue orders every frame).
inline bool NeedsGuardOrder(int guardingId, int vipId, int lastOrderFrame, int frame, int minGap)
{
	return vipId >= 0 && guardingId != vipId && frame - lastOrderFrame >= minGap;
}

// No new order of any kind inside minGap frames of the last one.
inline bool OrderAllowed(int lastOrderFrame, int frame, int minGap)
{
	return frame - lastOrderFrame >= minGap;
}

} // namespace circuit::escort_strike

#endif // CIRCUIT_ESCORT_STRIKE_RULES_H
