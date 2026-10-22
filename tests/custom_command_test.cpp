// Exercise the production adapter with the same C bridge boundary as Recoil.
#include "spring/CustomCommand.h"
#include "CombinedCallbackBridge.h"
#include "CallbackAIException.h"
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <vector>

namespace {
int calls = 0, result = 0;
int seenAI, seenUnit, seenCommand, seenTimeout;
short seenOptions;
std::vector<float> seen;
bool countAllocations = false;
unsigned allocations = 0;
void Check(bool value) { if (!value) std::exit(1); }
// The generated WrappUnit::ExecuteCustomCommand implementation, retained as
// the allocation oracle. Its C bridge is the same fake used by production.
void WrapperBefore(int ai, int unit, int cmd, std::vector<float> params, short options, int timeout) {
    float* copy = new float[params.size()];
    for (unsigned i = 0; i < params.size(); ++i) copy[i] = params[i];
    const int error = bridged_Unit_executeCustomCommand(ai, unit, cmd, copy, int(params.size()), options, timeout);
    delete[] copy;
    if (error != 0) throw springai::CallbackAIException("executeCustomCommand", error);
}
}
void* operator new(std::size_t size) {
    if (countAllocations) ++allocations;
    if (void* p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
EXPORT(int) bridged_Unit_executeCustomCommand(int ai, int unit, int command,
    float* params, int count, short options, int timeout)
{
    ++calls; seenAI = ai; seenUnit = unit; seenCommand = command;
    seenOptions = options; seenTimeout = timeout;
    seen.clear();
    for (int i = 0; i < count; ++i) seen.push_back(params[i]);
    return result;
}
int main()
{
    for (int count : {0, 1, 3, 128}) {
        std::vector<float> params(count);
        for (int i = 0; i < count; ++i) params[i] = (i & 1) ? -float(i) : float(i) + 0.25f;
        if (count) params[0] = -0.f;
        for (short options : {short(0), short(32), short(255), short(-1)}) {
            for (int timeout : {0, 30, INT_MAX}) {
                const int previous = calls;
                circuit::SendCustomCommand(7, 123, -42, params, options, timeout);
                Check(calls == previous + 1 && seenAI == 7 && seenUnit == 123 && seenCommand == -42);
                Check(seenTimeout == timeout && seenOptions == options && seen.size() == params.size());
                for (int i = 0; i < count; ++i) Check(std::bit_cast<unsigned>(seen[i]) == std::bit_cast<unsigned>(params[i]));
            }
        }
    }
    circuit::SendCustomCommand(1, 2, 3, {});
    Check(seenTimeout == INT_MAX && seenOptions == 0 && seen.empty());
    result = -17;
    bool caught = false;
    try { circuit::SendCustomCommand(1, 2, 3, {}); }
    catch (const springai::CallbackAIException& e) { caught = e.GetMethodName() == "executeCustomCommand"; }
    Check(caught && calls == 50);
    std::puts("custom command: 50 bridge calls, exact payload/options/timeouts and error propagation passed");
    result = 0;
    seen.reserve(3);
    allocations = 0; countAllocations = true;
    for (int i = 0; i < 10000; ++i) WrapperBefore(1, 2, 3, {1.f, 2.f, 3.f}, 32, 1800);
    countAllocations = false;
    const unsigned old = allocations;
    allocations = 0; countAllocations = true;
    for (int i = 0; i < 10000; ++i) {
        float params[] = {1.f, 2.f, 3.f};
        circuit::SendCustomCommand(1, 2, 3, params, 32, 1800);
    }
    countAllocations = false;
    Check(old == 20000 && allocations == 0);
    std::printf("10000 custom orders: temporary allocations old=%u new=%u; order count unchanged\n", old, allocations);
}
