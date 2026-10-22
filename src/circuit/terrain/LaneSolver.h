#pragma once

// Engine-free lane geometry. A solver owns its scratch space and borrows only
// an immutable terrain snapshot and a request owned by its job. No engine
// callbacks, AI pointers, AngelScript, logging, or published lanes live here.
// Lanes are a good background candidate: many grid searches, infrequent input
// changes, and an old complete answer remains useful while a refresh runs.
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <map>
#include <stdexcept>
#include <vector>

namespace circuit::lane {
using Grid = std::vector<float>;
enum Class : int { L_LAND, L_BOT, L_AMPH, L_HOVER, L_ALLTERRAIN, L_NAVAL, L_AIR, _LANE_CLASSES_ };
struct Point {
    float x = 0.f, y = 0.f, z = 0.f;
    Point() = default;
    Point(float x, float y, float z) : x(x), y(y), z(z) {}
    float distance2D(const Point& p) const { return std::sqrt((x-p.x)*(x-p.x)+(z-p.z)*(z-p.z)); }
};
struct Terrain {
    int gw = 0, gh = 0, cellSize = 64;
    Grid height, surfaceSlope;
    std::array<std::vector<char>, _LANE_CLASSES_> pass;
    std::vector<int> body8;
    // Optional per-cell outgoing edge bits, NB order. Empty preserves legacy lanes.
    std::vector<unsigned char> edges;
};
struct Settings {
    float specialistMinSpan = 1024.f, specialistSpanFraction = 0.45f;
    int cliffApproachClass = -1;
    float cliffMinDrop = 256.f, cliffMaxRun = 1600.f, cliffMinProgress = 0.6f;
    float mountainGradeWeight = 8.f, mountainPeakTolerance = 256.f;
    float mountainSurfaceWeight = 12.f, mountainHeightWeight = 4.f;
    float cliffPreference = 8.f, cliffQualityTolerance = 0.1f, cliffHeightFraction = 0.5f;
};
struct Request {
    Settings settings;
    std::vector<Point> allyEnds, enemyEnds;
    Grid airThreat, surfThreat; // only this AI's observed threat, captured on main
    int alternatives = 3, highGroundRoutes = 3;
    float mergeRadius = 450.f, threatWeight = 1.f, specialistBias = 1.f;
    float highGroundRise = 128.f, highGroundDetour = 3.f;
};
struct Route {
    bool mountainQualified = false;
    int cls = -1, mask = 0, descent = -1, ascent = -1;
    float cliffQuality[2] = {0.f, 0.f};
    std::vector<int> cells;
    std::vector<char> zone; // scratch during merging; released before publication
    float length = 0.f, width = 0.f, threat = 0.f, front = -1.f;
    int heat = 0, choke = -1;
};
struct Cancelled final : std::exception {
    const char* what() const noexcept override { return "lane request cancelled"; }
};
// One owner/thread per workspace. Generations avoid clearing V cells for a
// short route; the retained heap keeps the legacy (cost, cell) tie order.
// Full-field lane consumers still receive completely initialized arrays.
struct SearchWorkspace {
    std::vector<std::uint32_t> stamps;
    std::vector<std::pair<float, int>> heap;
    std::uint32_t generation = 0;
    void Begin(std::size_t size);
    bool Seen(int cell) const { return stamps[cell] == generation; }
};
struct PointWorkspace {
    SearchWorkspace search;
    Grid penalty, distance;
    std::vector<char> blocked;
    std::vector<int> previous;
    // A zero version deliberately disables cost reuse. Callers must keep the
    // immutable terrain alive and version every threat publication. Obstacles
    // are live inputs and always force recomputation (terrain_route_test).
    const Grid* terrain = nullptr;
    const Grid* threat = nullptr;
    std::uint64_t version = 0;
    float landCost = 0, waterCost = 0, weight = 0, ceiling = 0;
    // Exact solved-cell paths, including unreachable results. Bounded FIFO
    // storage; all entries belong to the cost/terrain publication above.
    // Never used with a live obstacle overlay or publication version zero.
    static constexpr std::size_t maximumCachedRoutes = 64;
    std::map<std::array<int,3>, std::vector<int>> routes;
    std::vector<std::array<int,3>> routeOrder;
    std::size_t nextRoute = 0;
    float surfaceWeight = 0;
};
std::uint64_t Fingerprint(const std::vector<Route>& routes);
class Solver final : private Settings {
public:
    explicit Solver(const Terrain& terrain, Settings settings = {}, const std::atomic<bool>* cancel = nullptr);
    std::vector<Route> Run(const Request& request);
    // Point-to-point terrain route, with policy-supplied travel costs and threat ceiling.
    // Empty means unreachable; never snap either end across an impassable cell.
    std::vector<int> PointRoute(const Point& from, const Point& to, int cls, const Grid& threat,
        float landCost, float waterCost, float threatWeight, float maxWaterThreat,
        const std::vector<char>* obstacles = nullptr, PointWorkspace* workspace = nullptr,
        std::uint64_t threatVersion = 0) const;
    // Pure qualification, also exercised by synthetic route regressions.
    bool HasMountainTraverse(const Route& route, float rise) const;
    // Shared by the legacy choke analyser and lane planner; no second BFS.
    static void Clearance(int gw, int gh, const std::vector<char>& pass, std::vector<int>& out);
    void DijkstraMulti(const std::vector<int>& starts, const Grid& penalty, int cls, const Grid* extra,
        Grid& dist, std::vector<int>& prev, bool reverse = true, float gradeWeight = 0.f,
        const std::vector<char>* blocked = nullptr, float cliffWeight = 0.f, bool preferShelf = true,
        const Grid* initialCost = nullptr, int terminal = -1, SearchWorkspace* workspace = nullptr,
        int escape = -1) const;
    std::uint64_t Searches() const { return searches; }
    std::uint64_t Expanded() const { return expanded; }
private:
    using SLane = Route;
    int Cell(const Point& p) const;
    Point CellPos(int c) const;
    int Snap(const Point& p, int cls) const;
    bool BuildCliffCrossing(int peak, const std::vector<int>& region, int origin,
        const std::vector<int>& targets, int enemy, const Grid& surfCost, float budget);
    bool BuildShelfCrossing(int peak, const std::vector<int>& region, int origin,
        const std::vector<int>& targets, int enemy, const Grid& surfCost, float budget);
    void CheckCancelled() const;
    const int gw, gh, cellSize;
    const Grid& height;
    const Grid& surfaceSlope;
    const std::vector<unsigned char>& edges;
    const std::array<std::vector<char>, _LANE_CLASSES_>& pass;
    const std::vector<int>& body8;
    const std::atomic<bool>* cancel;
    std::vector<Route> lanes;
    mutable std::uint64_t searches = 0, expanded = 0;
};

// Main-thread-only admission/publication gate. Cancellation invalidates the
// generation but keeps its slot occupied until the worker completes: rapid UI
// requests cannot pile up jobs. A stale completion cannot publish or clear a
// newer job. The worker itself never accesses this gate.
class JobGate final {
public:
    std::uint64_t Begin() { if (active) return 0; active = ++generation; return active; }
    void Invalidate() { ++generation; }
    bool Finish(std::uint64_t token) {
        if (!active || active != token) return false;
        active = 0;
        return token == generation;
    }
    bool Pending() const { return active != 0; }
private:
    std::uint64_t generation = 0, active = 0;
};
} // namespace circuit::lane
