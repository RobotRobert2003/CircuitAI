#pragma once

namespace circuit::transport {
// Immutable definition preflight shared by planning and live ferry dispatch.
// O(1), no allocation; wrappers remain borrowed on the simulation thread.
// Dynamic mass, Lua restrictions and loading state still belong to dispatch.
template<class Def>
bool CanCarry(Def* carrier, Def* cargo)
{
    return carrier != nullptr && cargo != nullptr && !cargo->IsNotTransportable()
        && carrier->GetTransportCapacity() > 0
        && cargo->GetXSize() <= carrier->GetTransportSize() * 2
        && cargo->GetXSize() >= carrier->GetMinTransportSize() * 2
        && cargo->GetMass() >= carrier->GetMinTransportMass()
        && cargo->GetMass() <= carrier->GetTransportMass();
}
}
