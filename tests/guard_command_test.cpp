#include "circuit/spring/GuardCommand.h"
#include "circuit/task/builder/GuardIntent.h"
#include <cassert>
#include <climits>
#include <iostream>
#include <limits>
#include <vector>

using circuit::guard::Command;
using Kind = Command::Kind;

int main()
{
	assert(circuit::guard::LeaseAlive(-1, 15, 100000));
	assert(circuit::guard::LeaseAlive(100, 0, 100000));
	assert(circuit::guard::LeaseAlive(100, 15, 114));
	assert(!circuit::guard::LeaseAlive(100, 15, 115));
	assert(!circuit::guard::LeaseAlive(100, 15, 116));
	assert(circuit::guard::LeaseAlive(INT_MAX-10, 15, INT_MAX));
	int checks = 0;
	auto check = [&](std::vector<Command> queue, bool expected, int target = 42, int frame = 100) {
		const bool got = circuit::guard::HasIntent(static_cast<int>(queue.size()), target, frame,
			[&](int i) { return queue.at(i); });
		assert(got == expected);
		++checks;
	};
	const Command guard{Kind::GUARD, 42, INT_MAX, true};
	const Command repair{Kind::REPAIR, 78, INT_MAX, true};
	const Command move{Kind::MOVE, -1, 1900, true};
	check({}, false);                         // STOP / lost queue recovers
	check({guard}, true);                     // stationary/moving guardee
	check({repair, guard}, true);             // factory frame being assisted
	check({move, guard}, true);               // pending task clearance move
	check({move, repair, guard}, true);       // engine displacement during assist
	check({repair}, false);                   // no parent GUARD remains
	check({move}, false);
	check({guard}, false, 43);                // target change is immediate
	check({{Kind::GUARD,43,INT_MAX,true},guard},false); // not a later queued job
	check({{Kind::OTHER,-1,INT_MAX,true},guard},false); // WAIT / attack / takeover
	check({{Kind::MOVE,-1,INT_MAX,false},guard},false); // unrelated external MOVE
	check({{Kind::REPAIR,78,INT_MAX,false},guard},false); // area/options rejected
	check({{Kind::GUARD,42,INT_MAX,false}},false); // modifier/malformed target
	check({{Kind::GUARD,42,99,true}},false);    // expired, no cooldown
	check({{Kind::GUARD,42,100,true}},true);    // engine expiry boundary is <
	check({{Kind::MOVE,-1,99,true},guard},false);
	check({{Kind::REPAIR,78,99,true},guard},false);
	check({{Kind::GUARD,std::numeric_limits<float>::quiet_NaN(),INT_MAX,true}},false);
	// Same-frame mutations are deliberately visible; there is no target/frame
	// cache to hide a STOP, target replacement, repair completion or transfer.
	std::vector<Command> queue{guard};
	check(queue,true);
	queue.clear(); check(queue,false);
	queue.push_back(guard); check(queue,true);
	queue.insert(queue.begin(),repair); check(queue,true);
	queue.front().target=79; check(queue,true); // next factory frame
	queue.erase(queue.begin()); check(queue,true);
	queue.back().target=43; check(queue,false);
	check(queue,true,43);
	int reads=0;
	assert(!circuit::guard::HasIntent(100000,42,100,[&](int) { ++reads; return Command{}; }));
	assert(reads==1);                         // no scan past a conflicting order
	std::cout << "guard_command_test: " << checks+1 << " checks PASS\n";
}
