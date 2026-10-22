#pragma once

#include <cmath>

namespace circuit {

// A live front-of-queue resurrection intent. Converted area commands have
// five parameters: feature+maxUnits, x, y, z, radius. They claim only that
// feature, not the whole original area. See resurrection_claim_test.cpp.
struct ResurrectionClaim {
    int featureId = -1;
    float x = 0, z = 0, radius = -1;

    bool Decode(const float* parameters, int count, int maximumUnits) {
        *this = {};
        if (count == 1 || count == 5) {
            const float encoded = parameters[0];
            if (!std::isfinite(encoded) || encoded < maximumUnits
                || encoded >= 2147483648.0f || std::floor(encoded) != encoded) return false;
            featureId = static_cast<int>(encoded) - maximumUnits;
            return true;
        }
        if (count != 4 || !std::isfinite(parameters[0]) || !std::isfinite(parameters[2])
            || !std::isfinite(parameters[3]) || parameters[3] < 0) return false;
        x = parameters[0]; z = parameters[2]; radius = parameters[3];
        return true;
    }

    bool Contains(int feature, float featureX, float featureZ) const {
        if (featureId >= 0) return featureId == feature;
        const double dx = double(featureX) - x, dz = double(featureZ) - z;
        return radius >= 0 && dx * dx + dz * dz <= double(radius) * radius;
    }
};
}
