// Deterministic, engine-free admission/recovery predicates. Policy magnitudes
// are supplied by TECH settings; this file performs no scans or engine calls.
namespace GantryMath {
    bool ClusterEligible(bool enabled, bool economyOnline, bool earlyAdmitted,
        bool isGantry, bool ordinaryActive) {
        return ordinaryActive || (enabled && isGantry && (economyOnline || earlyAdmitted));
    }
    bool CanFallback(int currentFrame, int progressFrame, int waitFrames,
        bool hasFrame, bool hasAssignedWorker, bool funded, bool reachable) {
        return waitFrames > 0 && progressFrame >= 0 && currentFrame - progressFrame >= waitFrames
            && !hasFrame && !hasAssignedWorker && funded && reachable;
    }
    bool AdmittedProduct(bool enabled, bool admitted, int producerId, int factoryId,
        int productionFrame, int admissionFrame) {
        return enabled && admitted && producerId >= 0 && producerId == factoryId
            && admissionFrame >= 0 && productionFrame >= admissionFrame;
    }
    bool CanStart(bool completedEconomy, bool incomeReady, float averageMetalIncome,
        float minimumMetalIncome, bool nuclearCommitment, bool heavyCommitment,
        bool funded, float availableBuildPower, float minimumBuildPower) {
        return completedEconomy && incomeReady && averageMetalIncome >= minimumMetalIncome
            && !nuclearCommitment && !heavyCommitment && funded
            && availableBuildPower >= minimumBuildPower;
    }

    // Piecewise-constant, time-weighted mean. One record per distinct frame:
    // O(windowFrames) storage, amortized O(1) Push, O(1) Mean, no hot allocation.
    // Keep the sample spanning the left boundary. Backward time, configuration
    // changes and publication gaps reset readiness rather than reusing history.
    // Owned by one role/AI; tests/gantry_math_tests.as compares irregular samples.
    class IncomeWindow {
        array<int> frames;
        array<float> values;
        array<double> integrals;
        uint head = 0, count = 0;
        int windowFrames = 0, firstFrame = -1, lastFrame = -1;
        double integral = 0.0;
        void Push(int frame, float value, int durationFrames, int maximumGapFrames) {
            if (durationFrames <= 0 || maximumGapFrames <= 0) { count = 0; firstFrame = -1; return; }
            if (windowFrames != durationFrames) {
                windowFrames = durationFrames;
                frames.resize(uint(windowFrames + 1));
                values.resize(frames.length()); integrals.resize(frames.length());
                count = 0;
            }
            if (count == 0 || frame < lastFrame || frame - lastFrame > maximumGapFrames) {
                head = 0; count = 1; firstFrame = frame; lastFrame = frame;
                integral = 0.0; frames[0] = frame; values[0] = value; integrals[0] = 0.0;
                return;
            }
            const uint last = (head + count - 1) % frames.length();
            if (frame == lastFrame) { values[last] = value; return; }
            integral += double(values[last]) * double(frame - lastFrame);
            const int boundary = frame - windowFrames;
            while (count > 1 && frames[(head + 1) % frames.length()] <= boundary) {
                head = (head + 1) % frames.length(); --count;
            }
            const uint next = (head + count) % frames.length();
            frames[next] = frame; values[next] = value; integrals[next] = integral;
            ++count; lastFrame = frame;
        }
        bool Ready(int frame, int maximumGapFrames) const {
            return count > 0 && firstFrame >= 0 && frame >= lastFrame
                && frame - firstFrame >= windowFrames && frame - lastFrame <= maximumGapFrames;
        }
        float Mean() const {
            if (count == 0 || lastFrame - firstFrame < windowFrames) return 0.0f;
            const double before = integrals[head]
                + double(values[head]) * double(lastFrame - windowFrames - frames[head]);
            return float((integral - before) / double(windowFrames));
        }
    }
}
