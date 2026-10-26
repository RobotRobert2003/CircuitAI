#include "terrain/CommanderJammerCoverage.h"
#include <cassert>
#include <iostream>
using namespace circuit::commander;
int main() {
    assert(JammerCoverage().NearUnjammed({0,0},100));
    JammerCoverage single({{{0,0},500}});
    assert(!single.NearUnjammed({399,0},100));
    assert(single.NearUnjammed({400,0},100));
    assert(single.NearUnjammed({500,0},0));
    assert(single.NearUnjammed({800,0},100));
    JammerCoverage duplicate({{{0,0},500},{{0,0},500},{{0,0},200}});
    assert(!duplicate.NearUnjammed({399,0},100));
    assert(duplicate.NearUnjammed({400,0},100));
    // The individual circle boundaries at x=0 are buried in the union. A
    // nearest-circle-edge rule would wrongly permit another central jammer.
    JammerCoverage overlap({{{-200,0},500},{{200,0},500}});
    assert(!overlap.NearUnjammed({280,0},100));
    assert(!overlap.NearUnjammed({0,350},100));
    assert(overlap.NearUnjammed({0,370},100));
    assert(overlap.NearUnjammed({610,0},100));
    JammerCoverage asymmetric({{{0,0},500},{{450,0},250}});
    assert(!asymmetric.NearUnjammed({450,0},100));
    assert(asymmetric.NearUnjammed({620,0},100));
    // Internal unjammed holes count too, unlike a convex hull of coverage.
    JammerCoverage hole({{{-110,0},100},{{110,0},100},{{0,110},100},{{0,-110},100}});
    assert(hole.NearUnjammed({0,0},10));
    assert(hole.NearUnjammed({15,0},10));
    std::cout<<"commander_jammer_coverage_test passed\n";
}
