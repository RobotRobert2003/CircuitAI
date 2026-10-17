#include "unit/TransportUtils.h"
#include <cassert>
#include <initializer_list>

struct Def {
    bool forbidden = false;
    int capacity = 1, size = 4, minimumSize = 1, footprint = 4;
    float mass = 500.f, minimumMass = 100.f, maximumMass = 1000.f;
    bool IsNotTransportable() const { return forbidden; }
    int GetTransportCapacity() const { return capacity; }
    int GetTransportSize() const { return size; }
    int GetMinTransportSize() const { return minimumSize; }
    int GetXSize() const { return footprint; }
    float GetMass() const { return mass; }
    float GetMinTransportMass() const { return minimumMass; }
    float GetTransportMass() const { return maximumMass; }
};
int main() {
    Def carrier, cargo;
    using circuit::transport::CanCarry;
    assert(!CanCarry<Def>(nullptr, &cargo));
    assert(!CanCarry<Def>(&carrier, nullptr));
    assert(CanCarry(&carrier, &cargo));
    cargo.forbidden = true;
    assert(!CanCarry(&carrier, &cargo));
    cargo.forbidden = false;
    carrier.capacity = 0;
    assert(!CanCarry(&carrier, &cargo));
    carrier.capacity = 1;
    for (int footprint = 0; footprint < 12; ++footprint) {
        cargo.footprint = footprint;
        for (float mass : {99.f, 100.f, 500.f, 1000.f, 1001.f}) {
            cargo.mass = mass;
            assert(CanCarry(&carrier, &cargo) ==
                (footprint >= 2 && footprint <= 8 && mass >= 100.f && mass <= 1000.f));
        }
    }
}
