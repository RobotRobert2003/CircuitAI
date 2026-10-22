#include "spring/CustomCommand.h"
#include "CombinedCallbackBridge.h"
#include "CallbackAIException.h"

namespace circuit {
void SendCustomCommand(int aiId, int unitId, int commandId, std::span<float> params,
    short options, int timeout)
{
    // The generated C bridge consumes this span synchronously. Borrowing the
    // caller's storage removes wrapper/payload allocation without changing the
    // order count, fields or exception contract. An asynchronous bridge would
    // require ownership instead. Covered by tests/custom_command_test.cpp.
    const int result = bridged_Unit_executeCustomCommand(aiId, unitId, commandId,
        params.data(), static_cast<int>(params.size()), options, timeout);
    if (result != 0) throw springai::CallbackAIException("executeCustomCommand", result);
}
}
