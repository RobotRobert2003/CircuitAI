// Frozen pre-D-221 implementation: exact ordered oracle, never production code.
#pragma once
#include "terrain/RangedGeometry.h"
namespace ranged_reference {
using circuit::ranged::Point;
class SpatialIndex {
public:
    explicit SpatialIndex(float cell=512.f): cell(cell) {}
    void Clear() { for (auto& [key, values]: cells) values.clear(); }
    void Add(Point p, int id) { cells[Key(p)].push_back(id); }
    void Remove(Point p, int id) {
        auto it=cells.find(Key(p));
        if(it!=cells.end()) std::erase(it->second,id);
    }
    template<class F> void Query(Point p, float radius, F&& visit) const {
        const int x0=Coord(p.x-radius), x1=Coord(p.x+radius);
        const int z0=Coord(p.z-radius), z1=Coord(p.z+radius);
        for (int z=z0;z<=z1;++z) for(int x=x0;x<=x1;++x) {
            const auto it=cells.find(Key(x,z));
            if (it!=cells.end()) for(int id:it->second) visit(id);
        }
    }
private:
    int Coord(float v) const { return int(std::floor(v/cell)); }
    static std::uint64_t Key(int x,int z) { return (std::uint64_t(std::uint32_t(x))<<32)|std::uint32_t(z); }
    std::uint64_t Key(Point p) const { return Key(Coord(p.x),Coord(p.z)); }
    float cell;
    std::unordered_map<std::uint64_t,std::vector<int>> cells;
};
}
