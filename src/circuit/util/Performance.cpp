#include "util/Performance.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <vector>

namespace circuit::performance {
const bool enabled = std::getenv("CIRCUIT_PERF_PHASES") != nullptr;
namespace {
using Clock = std::chrono::steady_clock;
constexpr std::array<const char*, PHASE_COUNT> names{
    "script", "tech-context", "eco-read", "tech-evaluate", "layout-place",
    "pack-candidates", "pocket", "pack-group", "can-pack", "command-state",
    "ranged-snapshot", "ranged-decision", "ranged-escort",
    "ranged-enemies", "ranged-friends", "ranged-state",
    "unit-route", "unit-terrain-refresh", "unit-terrain-build",
    "unit-route-threat", "unit-route-obstacles", "unit-route-search",
    "ranged-assist", "battle-ground-hazard",
    "commander-observe", "commander-decision",
    "commander-t3", "commander-fallback", "commander-deploy", "commander-handover", "commander-damage"
};
struct Stat {
    uint64_t calls = 0;
    double inclusive = 0, exclusive = 0, maximum = 0;
};
struct Open {
    int phase;
    Clock::time_point start;
    double children = 0;
    Stat* labelled = nullptr;
};
struct Team {
    std::array<Stat, PHASE_COUNT> stats{};
    std::vector<Open> stack;
    std::map<std::string, Stat> labels;
};
// Diagnostics can observe script execution on a worker without sharing mutable
// profiler state. Only the owning thread's AI Update calls Flush.
thread_local std::map<int, Team> teams;
}

void Begin(CCircuitAI* ai, int phase) {
    if (!enabled || phase < 0 || phase >= PHASE_COUNT) return;
    teams[ai->GetSkirmishAIId()].stack.push_back({phase, Clock::now(), 0});
}
void End(CCircuitAI* ai, int phase) {
    if (!enabled || phase < -1 || phase >= PHASE_COUNT) return;
    auto& team = teams[ai->GetSkirmishAIId()];
    if (team.stack.empty() || team.stack.back().phase != phase) return;
    const Open open = team.stack.back();
    team.stack.pop_back();
    const double ms = std::chrono::duration<double, std::milli>(Clock::now() - open.start).count();
    Stat* destination = open.labelled;
    if (destination == nullptr) {
        if (phase < 0) return;
        destination = &team.stats[phase];
    }
    auto& stat = *destination;
    ++stat.calls;
    stat.inclusive += ms;
    stat.exclusive += std::max<double>(0, ms - open.children);
    stat.maximum = std::max(stat.maximum, ms);
    if (!team.stack.empty()) team.stack.back().children += ms;
}
void BeginLabel(CCircuitAI* ai, const std::string& label) {
    if (!enabled) return;
    auto& team = teams[ai->GetSkirmishAIId()];
    team.stack.push_back({-1, Clock::now(), 0, &team.labels[label]});
}
void EndLabel(CCircuitAI* ai) { End(ai, -1); }
void UnwindScript(CCircuitAI* ai) {
    if (!enabled) return;
    auto& stack = teams[ai->GetSkirmishAIId()].stack;
    // A script exception bypasses its explicit End calls. Close only the
    // interrupted invocation's children; the native SCRIPT scope still owns it.
    while (!stack.empty() && stack.back().phase != SCRIPT) End(ai, stack.back().phase);
}
void Flush(CCircuitAI* ai) {
    if (!enabled) return;
    const auto it = teams.find(ai->GetSkirmishAIId());
    if (it == teams.end()) return;
    for (int phase = 0; phase < PHASE_COUNT; ++phase) {
        auto& stat = it->second.stats[phase];
        if (stat.calls == 0) continue;
        ai->LOG("[PerfPhase] team=%i frame=%i phase=%s calls=%llu inclusive_ms=%.6f exclusive_ms=%.6f max_ms=%.6f",
            ai->GetTeamId(), ai->GetLastFrame(), names[phase],
            static_cast<unsigned long long>(stat.calls), stat.inclusive, stat.exclusive, stat.maximum);
        stat = {};
    }
    for (auto& [label, stat] : it->second.labels) {
        if (stat.calls == 0) continue;
        ai->LOG("[PerfLabel] team=%i frame=%i label=%s calls=%llu inclusive_ms=%.6f exclusive_ms=%.6f max_ms=%.6f",
            ai->GetTeamId(), ai->GetLastFrame(), label.c_str(),
            static_cast<unsigned long long>(stat.calls), stat.inclusive, stat.exclusive, stat.maximum);
        stat = {};
    }
}
void Release(CCircuitAI* ai) {
    if (enabled) teams.erase(ai->GetSkirmishAIId());
}
void Garbage(CCircuitAI* ai, unsigned current, unsigned destroyed, unsigned detected) {
    if (enabled) ai->LOG("[PerfGC] team=%i frame=%i current=%u destroyed=%u detected=%u",
        ai->GetTeamId(), ai->GetLastFrame(), current, destroyed, detected);
}
} // namespace circuit::performance
