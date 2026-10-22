#ifndef SRC_CIRCUIT_SPRING_GUARDCOMMAND_H_
#define SRC_CIRCUIT_SPRING_GUARDCOMMAND_H_

namespace circuit::guard {

// Small, owned callback snapshot; no engine wrappers or parameter allocations.
struct Command {
	enum class Kind { OTHER, GUARD, REPAIR, MOVE };
	Kind kind = Kind::OTHER;
	float target = -1.f;
	int timeout = -1;
	bool valid = false;
};

// Recoil pushes an *unflagged* REPAIR ahead of GUARD when assisting a factory
// or constructor (BuilderCAI::ExecuteGuard). Internal displacement MOVE and
// our finite right-mouse clearance MOVE may also precede it. Stop at anything
// else: a guard far behind WAIT, ATTACK, or another GUARD is not active intent.
// O(Q) in the inspected prefix, normally one/two commands; O(1) storage. Read
// the live queue on the owning callback thread, never cache across frames:
// STOP, expiry, transfer, task takeover and target changes require recovery.
// tests/guard_command_test.cpp exercises the acceptance and recovery boundary.
template<typename Reader>
bool HasIntent(int count, int target, int frame, Reader&& read)
{
	for (int i = 0; i < count; ++i) {
		const Command c = read(i);
		if (!c.valid || c.timeout < frame) return false; // engine expires on <
		if (c.kind == Command::Kind::GUARD) return c.target == target;
		if (c.kind != Command::Kind::REPAIR && c.kind != Command::Kind::MOVE) return false;
	}
	return false;
}

} // namespace circuit::guard
#endif
