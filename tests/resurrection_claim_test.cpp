#include "circuit/spring/ResurrectionClaim.h"
#include <cassert>
#include <limits>
int main() {
    circuit::ResurrectionClaim claim;
    const float direct[] = {32775};
    assert(claim.Decode(direct,1,32768) && claim.Contains(7,0,0));
    assert(!claim.Contains(8,0,0));
    const float converted[] = {32775,100,0,100,500};
    assert(claim.Decode(converted,5,32768));
    assert(claim.Contains(7,1000,1000) && !claim.Contains(8,100,100));
    const float area[] = {100,0,100,50};
    assert(claim.Decode(area,4,32768));
    assert(claim.Contains(8,130,140) && !claim.Contains(8,131,140));
    const float unit[] = {7};
    assert(!claim.Decode(unit,1,32768) && !claim.Contains(7,0,0));
    const float invalid[] = {std::numeric_limits<float>::infinity()};
    assert(!claim.Decode(invalid,1,32768));
    const float fractional[] = {32775.5f};
    assert(!claim.Decode(fractional,1,32768));
    const float negativeArea[] = {100,0,100,-1};
    assert(!claim.Decode(negativeArea,4,32768));
    assert(!claim.Decode(area,3,32768));
}
