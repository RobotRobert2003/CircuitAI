#ifndef CIRCUIT_CUSTOM_COMMAND_H
#define CIRCUIT_CUSTOM_COMMAND_H

#include <climits>
#include <span>

namespace circuit {
// The C bridge consumes this span synchronously, exactly as the generated
// wrapper consumes its temporary new[] array. It never retains the pointer.
void SendCustomCommand(int aiId, int unitId, int commandId, std::span<float> params,
    short options = 0, int timeout = INT_MAX);
}
#endif
