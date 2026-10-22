#ifndef CIRCUIT_UTIL_PERFORMANCE_H
#define CIRCUIT_UTIL_PERFORMANCE_H

#include <string>

namespace circuit {
class CCircuitAI;
namespace performance {

// Opt-in aggregate diagnostics. No timers or allocations when disabled.
// Numeric script phases are an ABI: append rather than reorder.
enum Phase {
    SCRIPT, TECH_CONTEXT, ECO_READ, TECH_EVALUATE, LAYOUT_PLACE,
    PACK_CANDIDATES, POCKET, PACK_GROUP, CAN_PACK, COMMAND_STATE,
    RANGED_SNAPSHOT, RANGED_DECISION, RANGED_ESCORT,
    RANGED_ENEMIES, RANGED_FRIENDS, RANGED_STATE,
    UNIT_ROUTE, UNIT_TERRAIN_REFRESH, UNIT_TERRAIN_BUILD,
    UNIT_ROUTE_THREAT, UNIT_ROUTE_OBSTACLES, UNIT_ROUTE_SEARCH,
    RANGED_ASSIST, // D-295: nested in RANGED_DECISION
    BATTLE_GROUND_HAZARD, // D-296: lazy observed ground-weapon coverage
    COMMANDER_OBSERVE, COMMANDER_DECISION,
    COMMANDER_T3, COMMANDER_FALLBACK, COMMANDER_DEPLOY, COMMANDER_HANDOVER, // D-294 attribution
    COMMANDER_DAMAGE, // immediate damage callback; separate root from scheduled decision
    PHASE_COUNT
};
extern const bool enabled;
void Begin(CCircuitAI* ai, int phase);
void End(CCircuitAI* ai, int phase);
void BeginLabel(CCircuitAI* ai, const std::string& label);
void EndLabel(CCircuitAI* ai);
void UnwindScript(CCircuitAI* ai);
void Flush(CCircuitAI* ai);
void Release(CCircuitAI* ai);
void Garbage(CCircuitAI* ai, unsigned current, unsigned destroyed, unsigned detected);

class Scope final {
public:
    Scope(CCircuitAI* ai, Phase phase) : ai(ai), phase(phase) { if (enabled) Begin(ai, phase); }
    ~Scope() { if (enabled) End(ai, phase); }
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;
private:
    CCircuitAI* ai;
    Phase phase;
};
} // namespace performance
} // namespace circuit
#endif
