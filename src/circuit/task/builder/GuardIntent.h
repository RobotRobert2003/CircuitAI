#pragma once
#include <cstdint>

namespace circuit::guard {
// Same deadline rule as ITaskModule::UpdateTasks. A deactivated task has no
// running timeout; reuse must neither restart nor extend its original lease.
inline bool LeaseAlive(int lastTouched, int timeout, int frame) {
    return lastTouched == -1 || timeout <= 0
        || int64_t(frame) - int64_t(lastTouched) < int64_t(timeout);
}
}
