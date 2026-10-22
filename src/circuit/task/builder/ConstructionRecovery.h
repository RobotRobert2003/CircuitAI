#pragma once

namespace circuit { namespace construction {
// Empty engine intent and demonstrably stationary, funded, unstarted intent
// are distinct failure signals. A frame, resource stall, pending path, wait or
// moving detour protects the latter. Timings derive from role recovery policy.
enum class Recovery { NONE, RETRY, RELEASE };
// The watchdog collects this once on the simulation thread. In particular,
// resource starvation is NOT a failure signal: a build/repair command remains
// valid even when no resource is being consumed. Keep these gates explicit so
// ownership, pathing and wait regressions are covered without an engine mock.
struct Progress {
    bool owned = true;
    bool waiting = false;
    bool pathReady = true;
    bool commands = false;
    bool moving = false;
    bool MissingCommand() const {
        return owned && !waiting && pathReady && !commands && !moving;
    }
};
inline bool RetireUnstarted(bool frame, bool otherAssignee, bool validSite, bool reachableWorker) {
    return !frame && !otherAssignee && (!validSite || !reachableWorker);
}
inline bool CanStart(float metal, float energy, float costM, float costE,
                     float buildTime, float workerTime, float seconds) {
    if (buildTime <= 0 || workerTime <= 0) return false;
    const float fraction = workerTime * seconds / buildTime;
    const float bounded = fraction < 1.f ? fraction : 1.f;
    return metal >= costM * bounded && energy >= costE * bounded;
}
struct Observation {
    int emptySince = -1;
    bool retried = false;
    int retryAfter = 0; // assignment backoff; unrelated productive jobs remain eligible
    int stationarySince = -1;
    float lastX = 0, lastZ = 0;
    // Compare displacement, not distance-to-goal: progress around a cliff can
    // legitimately increase the latter. Do not gate this on instantaneous
    // velocity: a blocked engine move can shuffle forever inside this disc.
    // Path/wait gates come from the owner; one sample per five-second watchdog.
    bool StalledCommand(int frame, float x, float z, bool candidate, int patience) {
        if (!candidate) { stationarySince=-1; return false; }
        const float dx=x-lastX, dz=z-lastZ;
        if (stationarySince<0 || dx*dx+dz*dz>16*16) {
            stationarySince=frame; lastX=x; lastZ=z; return false;
        }
        return frame-stationarySince>=patience;
    }
    Recovery Observe(int frame, bool eligible, int retryFrames, int releaseFrames) {
        if (!eligible) { emptySince = -1; retried = false; return Recovery::NONE; }
        if (emptySince < 0) { emptySince = frame; return Recovery::NONE; }
        if (retried && frame - emptySince >= releaseFrames) return Recovery::RELEASE;
        if (!retried && frame - emptySince >= retryFrames) {
            retried = true; return Recovery::RETRY;
        }
        return Recovery::NONE;
    }
};
} }
