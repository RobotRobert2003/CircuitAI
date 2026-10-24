/*
 * EscortStrikeRules.h
 *
 * Engine-free decisions of CEscortStrikeTask (tests/escort_strike_test.cpp).
 * The task supplies live state; these say what to order and when not to.
 */
#ifndef CIRCUIT_ESCORT_STRIKE_RULES_H
#define CIRCUIT_ESCORT_STRIKE_RULES_H

namespace circuit::escort_strike {

// A known contact a striker may break off for: an allowed def (priority > 0)
// within reach, seen now or a structure (a structure does not move away).
inline bool StrikeCandidate(float priority, bool visible, bool stationary, float distanceSq, float radius)
{
	return priority > 0.f && (visible || stationary) && radius > 0.f
		&& distanceSq >= 0.f && distanceSq <= radius * radius;
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
