#include "terrain/AirSafety.h"
#include <cassert>
#include <iostream>

int main() {
    using circuit::air::CorridorThreat;
    using circuit::air::IntersectsCircle;
    assert(IntersectsCircle(0,0,1000,0,500,300,300)); // physical weapon boundary even with zero profile weight
    assert(!IntersectsCircle(0,0,1000,0,500,301,300));
    assert(IntersectsCircle(0,0,0,0,100,0,100));
    assert(!IntersectsCircle(0,0,1000,0,1301,0,300));
    auto tower = [](float x,float z) { return x>=480 && x<544 && z>=480 && z<544 ? 10.f : 0.f; };
    assert(CorridorThreat(100,500,900,500,0,1024,1024,64,tower)==10);
    assert(CorridorThreat(100,300,900,300,0,1024,1024,64,tower)==0);
    assert(CorridorThreat(200,300,800,300,220,1024,1024,64,tower)>0); // outside padded boundary fails closed
    assert(CorridorThreat(250,300,750,300,220,1024,1024,64,tower)==10);
    assert(CorridorThreat(500,100,500,900,0,1024,1024,64,tower)==10);
    assert(CorridorThreat(100,100,900,900,0,1024,1024,64,tower)==10);
    assert(CorridorThreat(500,500,500,500,0,1024,1024,64,tower)==10);
    assert(!std::isfinite(CorridorThreat(10,100,900,500,30,1024,1024,64,tower)));
    assert(!std::isfinite(CorridorThreat(100,100,900,500,-1,1024,1024,64,tower)));
    // Brute-force capsule reference on arbitrary grid obstacles. The optimized
    // raster must never omit an intersected cell, including end caps/reversal.
    for(int seed=1;seed<=60;++seed) {
        float ax=300+(seed*127)%1400, az=300+(seed*257)%1400;
        float bx=300+(seed*359)%1400, bz=300+(seed*83)%1400;
        float pad=(seed%5)*48.f, dx=bx-ax,dz=bz-az,len=dx*dx+dz*dz;
        float reach=pad+64*.707107f, expected=0;
        auto value=[](float x,float z) { return float((int(x/64)*17+int(z/64)*37)%71); };
        for(int z=0;z<32;++z)for(int x=0;x<32;++x) {
            float px=(x+.5f)*64,pz=(z+.5f)*64;
            float t=len>.001f?std::clamp(((px-ax)*dx+(pz-az)*dz)/len,0.f,1.f):0;
            float ex=px-ax-t*dx,ez=pz-az-t*dz;
            if(ex*ex+ez*ez<=reach*reach)expected=std::max(expected,value(px,pz));
        }
        assert(CorridorThreat(ax,az,bx,bz,pad,2048,2048,64,value)==expected);
        assert(CorridorThreat(bx,bz,ax,az,pad,2048,2048,64,value)==expected);
    }
    int probes=0;
    CorridorThreat(512,512,15500,15500,320,16384,16384,64,[&](float,float){++probes;return 0.f;});
    assert(probes<6000); // diagonal work must not become a whole map scan
    std::cout<<"air_safety_test: PASS (capsule reference, bounds, "<<probes<<" diagonal probes)\n";
}
