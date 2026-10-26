#include "terrain/FogProximity.h"
#include <cassert>
#include <limits>
#include <iostream>

int main() {
    using circuit::visibility::NearFog;
    std::vector<int> los(100*100,1);
    // Visible map edges are not fog; an internal invisible hole is.
    assert(!NearFog(los,100,16,4,4,600));
    los[50*100+50]=0;
    assert(NearFog(los,100,16,200,808,600));
    assert(!NearFog(los,100,16,199,808,600));
    // Inclusive boundary works on either side, not just the lower cell edge.
    assert(NearFog(los,100,16,1416,808,600));
    assert(!NearFog(los,100,16,1417,808,600));
    // A square-corner cell outside the circular radius must not trigger cloak.
    assert(!NearFog(los,100,16,300,300,600));
    assert(NearFog(los,100,16,808,808,0));
    assert(!NearFog({},100,16,808,808,600));
    assert(!NearFog(los,100,16,-1,808,600));
    assert(!NearFog(los,100,16,1600,808,600));
    assert(!NearFog(los,100,16,808,808,std::numeric_limits<float>::quiet_NaN()));
    std::cout << "fog proximity geometry: PASS\n";
}
