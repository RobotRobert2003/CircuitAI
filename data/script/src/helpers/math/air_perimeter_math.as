// Pure policy geometry. Settings are explicit inputs; no engine queries or state.
namespace AirPerimeterMath {
    const float Half = 0.5f;
    const float Zero = 0.0f;
    const float One = 1.0f;
    float SafeInset(float requested, float threatPadding) {
        return requested > threatPadding+One ? requested : threatPadding+One;
    }
    float Bound(float value, float lower, float upper) {
        return value < lower ? lower : (value > upper ? upper : value);
    }
    float CrossCoordinate(float anchor, float extent, float inset, float rearWidth, float progress, float share) {
        inset = Bound(inset, Zero, extent * Half);
        progress = Bound(progress, Zero, One); share = Bound(share, Zero, One);
        const float rear = Bound(anchor + (share-Half)*rearWidth, inset, extent-inset);
        const float front = inset + share*(extent-inset-inset);
        return rear + (front-rear)*progress;
    }
    float StableAdvance(float previous, float candidate, float hysteresis, bool sameGeometry) {
        // Patrol sight flickers as aircraft circle. Loss of sight alone must not
        // pull the line backwards; the shell separately validates current AA.
        return sameGeometry && candidate < previous+hysteresis ? previous : candidate;
    }
    float RejectUnsafeAdvance(float previous, float candidate, bool sameGeometry) {
        // Called only after the proposed corridor fails its current threat test.
        // Keep an existing line before searching farther back. The shell must
        // still test that retained line: newly arriving AA can make it unsafe.
        return sameGeometry && candidate > previous ? previous : candidate;
    }
}
