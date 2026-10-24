// CEscortStrikeTask decisions (EscortStrikeRules.h): when a Liche breaks off
// for a target, which target it takes, and when it may be given an order.
#include "task/fighter/EscortStrikeRules.h"
#include <cassert>
#include <iostream>
int main()
{
	using namespace circuit::escort_strike;
	// 600 elmos: a third of the T2 bombers' 1800 in-flight radius.
	const float r = 600.f;
	assert(StrikeCandidate(1.f, true, true, 600.f * 600.f, r));
	assert(StrikeCandidate(1.f, true, false, 100.f, r));       // a visible mobile anti-nuke
	assert(StrikeCandidate(1.f, false, true, 100.f, r));       // a structure seen before
	assert(!StrikeCandidate(1.f, false, false, 100.f, r));     // a radar dot that moves
	assert(!StrikeCandidate(1.f, true, true, 601.f * 601.f, r));
	assert(!StrikeCandidate(0.f, true, true, 100.f, r));       // not on the roster
	assert(!StrikeCandidate(1.f, true, true, 100.f, 0.f));     // disabled
	assert(!StrikeCandidate(1.f, true, true, -1.f, r));

	// Tier first: a shield 590 away beats a factory 10 away.
	assert(BetterStrike(3200000.f, 590.f * 590.f, 9, 1.f, 100.f, 4));
	assert(!BetterStrike(1.f, 100.f, 4, 3200000.f, 590.f * 590.f, 9));
	// Same tier: nearer, then lower id.
	assert(BetterStrike(400.f, 100.f, 9, 400.f, 200.f, 4));
	assert(BetterStrike(400.f, 100.f, 3, 400.f, 100.f, 4));
	assert(!BetterStrike(400.f, 100.f, 5, 400.f, 100.f, 4));
	assert(BetterStrike(1.f, 1.e9f, 7, 0.f, 0.f, -1));           // anything beats nothing

	assert(HasStrikeRoom(0, 2));
	assert(HasStrikeRoom(1, 2));
	assert(!HasStrikeRoom(2, 2));
	assert(HasStrikeRoom(50, 0));                               // no cap

	assert(StrikeOver(true, 10, 100));
	assert(StrikeOver(false, 100, 100));
	assert(!StrikeOver(false, 99, 100));

	// One GUARD per escort change, and never twice in 15 frames.
	assert(NeedsGuardOrder(-1, 42, -1000, 0, 15));              // first guard
	assert(!NeedsGuardOrder(42, 42, -1000, 0, 15));             // already guarding it
	assert(NeedsGuardOrder(42, 43, 0, 15, 15));                 // vip died: swap
	assert(!NeedsGuardOrder(42, 43, 0, 14, 15));                // same half second: next update
	assert(!NeedsGuardOrder(-1, -1, -1000, 0, 15));             // no vip left
	// Repeated updates with a standing guard emit nothing.
	int orders = 0, guarding = -1, last = -1000;
	for (int frame = 0; frame < 30 * 60; frame += 30) {
		if (NeedsGuardOrder(guarding, 42, last, frame, 15)) { ++orders; guarding = 42; last = frame; }
	}
	assert(orders == 1);
	assert(OrderAllowed(0, 15, 15));
	assert(!OrderAllowed(0, 14, 15));

	std::cout << "escort_strike_test: OK" << std::endl;
	return 0;
}
