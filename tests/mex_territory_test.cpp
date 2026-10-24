// D-352: the engine-free mex territory rules (resource/MexTerritory.h): the
// theatre mask, the four ownership rules, the race, the post-window openings,
// value per second and the deterministic lane partition on synthetic grids.
#include "resource/MexTerritory.h"

#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>

using namespace circuit::mex_territory;
namespace lanes = circuit::mex_lanes;
using circuit::mex_navigation::DistancesMulti;

static void Require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static Entrant Ground(int team, float walk, float start2D, bool laneSpots = false, int lane = -1) {
    Entrant e; e.team = team; e.kind = LAND; e.groundDistance = walk; e.startDistance2D = start2D;
    e.classDistance = walk; e.classSpeed = 60.f; e.laneSpots = laneSpots; e.lane = lane; return e;
}
static Entrant Ship(int team, float sail, int ready = 180 * 30, float walk = Unreachable) {
    Entrant e; e.team = team; e.kind = NAVAL; e.classDistance = sail; e.classSpeed = 65.f; e.readyFrame = ready;
    e.groundDistance = walk; e.startDistance2D = 5000.f; e.secureSeconds = 60.f;
    e.combatDistance = sail; e.combatSpeed = 93.f; e.combatReadyFrame = ready; return e;
}
static Entrant Hover(int team, float hover, int ready = 240 * 30, float secure = 90.f, int combatReady = 200 * 30) {
    Entrant e; e.team = team; e.kind = HOVER; e.classDistance = hover; e.classSpeed = 67.f; e.readyFrame = ready;
    e.startDistance2D = 5000.f; e.secureSeconds = secure;
    e.combatDistance = hover; e.combatSpeed = 114.f; e.combatReadyFrame = combatReady; return e;
}
static Entrant Air(int team, float flight, int ready = 200 * 30, float secure = 150.f) {
    Entrant e; e.team = team; e.kind = AIR; e.classDistance = flight; e.classSpeed = 136.f; e.readyFrame = ready;
    e.startDistance2D = flight; e.secureSeconds = secure; return e;
}

static void TestMaskAndHome() {
    Inputs in;
    in.entrants = { Ground(0, 400.f, 300.f), Ground(1, 250.f, 2000.f), Ship(2, 900.f, 180 * 30, 700.f) };
    const auto r = Resolve(in);
    Require((r.mask & LAND) && (r.mask & NAVAL) && (r.mask & AIR) && !(r.mask & HOVER), "mask: land, naval, air");
    Require(r.rule == Rule::HOME && r.owner == 0, "home radius beats a shorter walk and the sea rule");
    // SEA's own shore spot inside its home radius is SEA's, not the nearer FRONT's.
    Inputs shore;
    shore.entrants = { Ground(0, 500.f, 1500.f), Ship(2, 900.f, 180 * 30, 700.f) };
    shore.entrants[1].startDistance2D = 600.f;
    const auto s = Resolve(shore);
    Require(s.rule == Rule::HOME && s.owner == 2, "SEA keeps the land spots inside its home radius");
}

static void TestSeaAndFord() {
    Inputs in;
    in.entrants = { Ground(0, 300.f, 1500.f), Ship(1, 1200.f), Ship(3, 800.f) };
    const auto r = Resolve(in);
    Require(r.rule == Rule::SEA && r.owner == 3, "a ford is SEA's by sailing distance while a SEA claimant reaches it");
    in.entrants = { Ground(0, 300.f, 1500.f), Ship(1, 800.f), Ship(3, 800.f) };
    Require(Resolve(in).owner == 1, "equal sailing distances tie to the lower team id");
    in.entrants = { Ground(0, 300.f, 1500.f), Ship(1, Unreachable) };
    const auto land = Resolve(in);
    Require(!(land.mask & NAVAL) && land.rule == Rule::LAND_WALK && land.owner == 0, "a land-locked SEA seat announces no naval reach: walking rule");
}

static void TestLanes() {
    Inputs in;
    in.lane = 0;
    in.entrants = { Ground(0, 300.f, 2500.f, false, 0), Ground(1, 500.f, 2500.f, true, 0), Ground(2, 200.f, 2500.f, true, 1) };
    const auto r = Resolve(in);
    Require(r.rule == Rule::LANE && r.owner == 1, "a lane cluster goes to the lane's FRONT/SUPPORT member, not the nearer TECH or the other lane");
    in.entrants = { Ground(0, 300.f, 2500.f, false, 0), Ground(2, 200.f, 2500.f, true, 1) };
    Require(Resolve(in).owner == 0, "a lane without a FRONT or SUPPORT member falls back to its members");
    in.forward = true;
    const auto f = Resolve(in);
    Require(f.rule == Rule::FORWARD && f.owner == -1, "a cluster past the midpoint is nobody's during the window");
    in.forward = false; in.lane = -1;
    Require(Resolve(in).rule == Rule::LAND_WALK, "off-lane land spots keep the walking rule");
}

// D-357: a published FRONT coverage corridor is that seat's lane.
static void TestCorridor() {
    Inputs in;
    in.corridor = 1;
    in.entrants = { Ground(0, 300.f, 2500.f, false, 0), Ground(1, 500.f, 2500.f, true, -1), Ground(2, 200.f, 2500.f, true, 1) };
    const auto r = Resolve(in);
    Require(r.rule == Rule::LANE && r.owner == 1, "a corridor cluster goes to the corridor's FRONT, not the nearer walker or the ground lane");
    in.corridorForward = true;
    const auto f = Resolve(in);
    Require(f.rule == Rule::FORWARD && f.owner == -1, "a cluster past the corridor midpoint is nobody's during the window");
    in.corridorForward = false; in.corridor = 0;
    Require(Resolve(in).rule == Rule::LAND_WALK && Resolve(in).owner == 2, "a corridor of a seat that claims no lane spots is ignored");
    in.corridor = 1; in.lane = 1;
    Require(Resolve(in).owner == 1, "the corridor wins over the ground partition's lane");
    in.window = false;
    Require(Resolve(in).rule == Rule::OPEN_LAND, "after the window the corridor no longer reserves");
}

static void TestRace() {
    // Supreme east island: both sides' con air at 273-274 s, TACTICAL's hovers 56 s ahead.
    Inputs in;
    in.entrants = { Hover(8, 5350.f), Air(11, 10000.f) };
    in.enemySeconds = 273.f; in.enemyCombatSeconds = 303.f;
    const auto r = Resolve(in);
    Require(r.mask == (HOVER | AIR), "island mask: hover and air only");
    Require(r.rule == Rule::RACE_CONTESTED && r.owner == 8, "contested island goes to the hover combat class");
    Require(std::fabs(r.secureSeconds - (200.f + 5350.f / 114.f)) < 0.5f, "contested: combat arrival recorded");
    // Enemy far away: AIR is secure first and arrives before the hover.
    in.enemySeconds = 600.f; in.enemyCombatSeconds = 600.f;
    const auto a = Resolve(in);
    Require(a.rule == Rule::RACE_SECURED && a.owner == 11, "secured first by the earliest arrival");
    // The enemy table re-announced closer: nobody can hold it.
    in.entrants = { Air(11, 10000.f) };
    in.enemySeconds = 100.f; in.enemyCombatSeconds = 100.f;
    const auto n = Resolve(in);
    Require(n.rule == Rule::RACE_AIR && n.owner == 11, "only aircraft reach it: AIR owns it whatever the enemy clock");
    in.entrants = { Hover(8, 5350.f, 240 * 30, 90.f, 200 * 30), Air(11, 10000.f) };
    in.enemySeconds = 100.f; in.enemyCombatSeconds = 100.f;
    const auto c = Resolve(in);
    // An enemy constructor landing first does not hold the island: hovers before enemy combat still win it.
    in.enemySeconds = 100.f; in.enemyCombatSeconds = 300.f;
    Require(Resolve(in).rule == Rule::RACE_CONTESTED && Resolve(in).owner == 8, "contested against the enemy's combat clock, not its con air");
    in.enemySeconds = 100.f; in.enemyCombatSeconds = 100.f;
    Require(c.rule == Rule::NONE && c.owner == -1, "contested with no combat holder before the enemy: nobody's");
    // A role leaving the roster: resolve without it.
    in.entrants = { Air(11, 10000.f) };
    in.enemySeconds = 273.f; in.enemyCombatSeconds = 303.f;
    Require(Resolve(in).owner == 11, "race re-run without the hover seat");
    // West island: AIR 100 s lead short of 150 s; with 90 s AIR takes it.
    in.entrants = { Hover(1, 5500.f), Air(3, 2000.f, 200 * 30, 150.f) };
    in.enemySeconds = 315.f; in.enemyCombatSeconds = 410.f;
    Require(Resolve(in).owner == 1, "AIR lead short of its securing time: hovers hold it");
    in.entrants[1].secureSeconds = 90.f;
    Require(Resolve(in).owner == 3 && Resolve(in).rule == Rule::RACE_SECURED, "a shorter securing list lets AIR take it");
}

static void TestWindowOpenings() {
    Inputs in;
    in.window = false; in.theatreWindow = false;
    in.entrants = { Ground(0, 900.f, 1000.f), Ground(1, 300.f, 1400.f) };
    const auto l = Resolve(in);
    Require(l.rule == Rule::OPEN_LAND && l.owner == 0, "after the window land follows the horizontal start split (D-072)");
    in.entrants = { Ground(0, Unreachable, 500.f), Ship(1, 2000.f), Hover(2, 900.f) };
    const auto w = Resolve(in);
    Require(w.rule == Rule::OPEN_CLASS && w.owner == 2, "after the window water goes to the nearest class that stands there");
    in.entrants = { Ground(0, Unreachable, 500.f), Ship(1, 2000.f) };
    Require(Resolve(in).owner == 1, "the ship when no hover reaches it");
    in.entrants = { Ground(0, Unreachable, 500.f) };
    Require(Resolve(in).rule == Rule::NONE, "nothing reaches it: open to anyone");
    in.window = true;
    in.entrants = { Ground(0, 900.f, 1000.f), Ground(1, 300.f, 1400.f) };
    Require(Resolve(in).owner == 1, "inside the window the walk decides");
    // The ford after the land window but inside the theatre window stays SEA's.
    in.window = false; in.theatreWindow = true;
    in.entrants = { Ground(0, 300.f, 1500.f), Ship(1, 800.f) };
    Require(Resolve(in).rule == Rule::SEA && Resolve(in).owner == 1, "a longer theatre window keeps the sea exclusive");
}

static void TestBalance() {
    // Three seats on one body, the central one nearest to most spots: shares of 3/3/2, each nearest its own.
    std::vector<std::vector<std::pair<int, float>>> c;
    for (int i = 0; i < 8; ++i) c.push_back({ {4, 100.f + i * 100.f}, {5, 300.f + i * 100.f}, {6, 900.f + i * 100.f} });
    const auto owner = BalanceSea(c);
    int n4 = 0, n5 = 0, n6 = 0;
    for (int o : owner) { n4 += o == 4; n5 += o == 5; n6 += o == 6; }
    Require(n4 == 3 && n5 == 3 && n6 == 2, "spots are dealt out in rounds: 3/3/2");
    Require(owner[0] == 4 && owner[1] == 5 && owner[2] == 6, "each seat takes its nearest spot in turn");
    c.push_back({ {5, 10.f} });
    const auto again = BalanceSea(c);
    Require(again[8] == 5, "a spot only one seat reaches goes to it");
    Require(BalanceSea({ { {4, Unreachable} } })[0] == -1, "nobody reaches: nobody's");
}

static void TestValue() {
    const float before = Value(2.f, 210 * 30, 1300.f, 65.f, 12.f, 30.f);
    const float after = Value(2.f, 0.f, 1300.f, 65.f, 12.f, 30.f);
    Require(after > before, "a SEA seat with no ship yet values every water spot by its readiness");
    Require(Value(2.f, 0.f, 500.f, 65.f, 12.f, 30.f) > Value(2.f, 0.f, 4000.f, 65.f, 12.f, 30.f), "nearer first");
    Require(Value(4.f, 0.f, 4000.f, 65.f, 12.f, 30.f) > Value(1.f, 0.f, 1300.f, 65.f, 12.f, 30.f), "richer can beat nearer");
    Require(Value(2.f, 0.f, Unreachable, 65.f, 12.f, 30.f) == 0.f, "unreachable is worthless");
}

// A 24 x 16 isthmus: a wall at x = 12 with gaps at rows 3-4 and 11-12.
static void TestPartition() {
    const int w = 24, h = 16; const float pitch = 64.f;
    auto passable = [&](int i) { const int x = i % w, z = i / w; return x != 12 || z == 3 || z == 4 || z == 11 || z == 12; };
    auto cost = [&](int a, int b) { return pitch * std::hypot(float(a % w - b % w), float(a / w - b / w)); };
    std::vector<std::pair<int, float>> enemySeeds, ourSeeds;
    for (int z = 0; z < h; ++z) enemySeeds.emplace_back(z * w + 22, 0.f);
    const std::vector<int> starts = { 4 * w + 2, 12 * w + 2, 7 * w + 2 };
    for (int s : starts) ourSeeds.emplace_back(s, 0.f);
    const auto enemy = DistancesMulti(w, h, enemySeeds, passable, cost);
    const auto ours = DistancesMulti(w, h, ourSeeds, passable, cost);
    std::vector<std::pair<float, float>> centres = { {12.5f * pitch, 4.5f * pitch}, {15.5f * pitch, 11.5f * pitch}, {5.5f * pitch, 4.5f * pitch}, {5.5f * pitch, 15.5f * pitch} };
    std::vector<int> cells = { 4 * w + 12, 11 * w + 15, 4 * w + 5, 15 * w + 5 };
    lanes::Settings settings; settings.mergeRadius = 450.f; settings.mergeShare = 0.6f; settings.bandRadius = 200.f;
    const auto p = lanes::Build(w, h, pitch, starts, enemy, ours, passable, centres, cells, settings);
    Require(p.lanes.size() == 2, "two gaps give two lanes");
    Require(p.startLane[0] == 0 && p.startLane[1] == 1, "each outer start founds its own lane");
    Require(p.startLane[2] == 0, "the middle start (nearer the top gap) merges into the first lane");
    Require(p.lanes[0].members.size() == 2 && p.lanes[1].members.size() == 1, "membership follows the merge");
    Require(p.lanes[0].choke >= 0 && p.lanes[0].choke % w == 12, "the choke is the gap");
    Require(p.lanes[0].midpoint >= 0 && std::abs(p.lanes[0].midpoint % w - 12) <= 1, "the midpoint is the terrain halfway mark");
    Require(p.clusterLane[0] == 0 && !p.clusterForward[0], "the gap cluster belongs to the first lane and is not forward");
    Require(p.clusterLane[1] == 1 && p.clusterForward[1], "a cluster past the second lane's midpoint is forward");
    Require(p.clusterLane[2] == 0 && !p.clusterForward[2], "a home-side cluster near the spine is a lane cluster");
    Require(p.clusterLane[3] == -1, "a cluster beyond the band belongs to no lane");
    const auto again = lanes::Build(w, h, pitch, starts, enemy, ours, passable, centres, cells, settings);
    Require(again.lanes[0].spine == p.lanes[0].spine && again.clusterLane == p.clusterLane, "the partition is a function of its inputs");
    // An L-shaped enemy box (south edge) bends the routes without any mirror assumption.
    std::vector<std::pair<int, float>> south;
    for (int x = 8; x < w; ++x) south.emplace_back(15 * w + x, 0.f);
    auto open = [](int) { return true; };
    const auto enemyS = DistancesMulti(w, h, south, open, cost);
    const auto oursS = DistancesMulti(w, h, ourSeeds, open, cost);
    const auto q = lanes::Build(w, h, pitch, starts, enemyS, oursS, open, {}, {}, settings);
    Require(!q.lanes.empty() && q.lanes[0].spine.back() / w == 15, "routes end at the south box");
    const int last = q.lanes[0].spine.back();
    Require(last % w >= 8, "the route bends to the adjacent box instead of a mirrored point");
}

int main() {
    try {
        TestMaskAndHome(); TestSeaAndFord(); TestLanes(); TestCorridor(); TestRace(); TestWindowOpenings(); TestBalance(); TestValue(); TestPartition();
    } catch (const std::exception& e) {
        std::cerr << "mex_territory_test: FAIL " << e.what() << "\n";
        return 1;
    }
    std::cout << "mex_territory_test: PASS mask, home, sea, lanes, race, openings, balance, value, partition\n";
    return 0;
}
