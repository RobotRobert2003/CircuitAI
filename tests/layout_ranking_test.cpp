// D-094: unit tests for the TECH layout's ranking rules (LayoutRanking.h).
// Each test names the owner's rule or the played bug it guards.
#include "circuit/terrain/LayoutRanking.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace {

using namespace circuit::layout_rank;

int failures = 0;
int checks = 0;

void Check(bool condition, const std::string& message)
{
	++checks;
	if (!condition) {
		std::cerr << "FAIL: " << message << '\n';
		++failures;
	}
}

bool Near(float a, float b, float eps = 0.01f) { return std::fabs(a - b) <= eps; }

// A block of turret slots, rows x cols, 48 elmos apart (a nano footprint).
std::vector<Pt> Grid(int rows, int cols, float x0 = 0.f, float z0 = 0.f, float pitch = 48.f)
{
	std::vector<Pt> out;
	for (int r = 0; r < rows; ++r) {
		for (int c = 0; c < cols; ++c) {
			out.push_back(Pt{x0 + c * pitch, z0 + r * pitch});
		}
	}
	return out;
}

// Fill a grid with NextConnected from a seed, returning the order taken.
std::vector<Pt> FillOrder(std::vector<Pt> freeSlots, const Pt& seed, int count)
{
	std::vector<Pt> taken;
	for (int i = 0; i < count; ++i) {
		const int k = NextConnected(freeSlots, taken, seed);
		if (k < 0) {
			break;
		}
		taken.push_back(freeSlots[k]);
		freeSlots.erase(freeSlots.begin() + k);
	}
	return taken;
}

void TestCentroidAndNearest()
{
	Check(Near(Centroid({}, Pt{7, 9}).x, 7) && Near(Centroid({}, Pt{7, 9}).z, 9), "centroid of nothing is the fallback");
	const Pt c = Centroid({Pt{0, 0}, Pt{10, 0}, Pt{10, 10}, Pt{0, 10}}, Pt{});
	Check(Near(c.x, 5) && Near(c.z, 5), "centroid of a square is its middle");
	Check(NearestSq(Pt{0, 0}, {}) == std::numeric_limits<float>::max(), "nearest of nothing is max");
	Check(Near(NearestSq(Pt{0, 0}, {Pt{3, 4}, Pt{10, 0}}), 25), "nearest squared distance");
}

// D-077/D-081: the first turret is the slot nearest the seed.
void TestFirstTurretNearestSeed()
{
	const std::vector<Pt> slots = Grid(4, 13);
	const Pt seed{-200, 72};  // west of the block, level with its middle rows
	const int k = NextConnected(slots, {}, seed);
	Check(k >= 0 && Near(slots[k].x, 0), "the first turret is on the seed's side of the block");
}

// D-081 (owner): "not one row at a time ... all rows concurrently". After a
// dozen turrets the block must span several rows and stay compact, not run
// along one row.
void TestBlockFillsAcrossRows()
{
	const std::vector<Pt> slots = Grid(4, 13);
	const std::vector<Pt> taken = FillOrder(slots, Pt{-200, 72}, 12);
	Check(taken.size() == 12, "twelve turrets placed");
	float minX = 1e9f, maxX = -1e9f, minZ = 1e9f, maxZ = -1e9f;
	for (const Pt& p : taken) {
		minX = std::min(minX, p.x); maxX = std::max(maxX, p.x);
		minZ = std::min(minZ, p.z); maxZ = std::max(maxZ, p.z);
	}
	const int rows = int((maxZ - minZ) / 48.f + 0.5f) + 1;
	const int cols = int((maxX - minX) / 48.f + 0.5f) + 1;
	Check(rows >= 3, "twelve turrets span at least three of the four rows (got " + std::to_string(rows) + ")");
	Check(cols <= 5, "twelve turrets stay within five columns, a block not a line (got " + std::to_string(cols) + ")");
	// every turret after the first touches an earlier one
	for (std::size_t i = 1; i < taken.size(); ++i) {
		std::vector<Pt> before(taken.begin(), taken.begin() + i);
		Check(NearestSq(taken[i], before) <= 2.f * 48.f * 48.f + 1.f, "turret " + std::to_string(i) + " touches the block");
	}
}

void TestNextConnectedNoneFree()
{
	Check(NextConnected({}, Grid(1, 3), Pt{}) == -1, "no free slot gives -1");
}

// D-083 (owner): "in range of construction turrets first, secondarily where
// they are planned".
void TestServedOutranksPlanned()
{
	const float inf = std::numeric_limits<float>::max();
	// a served turret 200 away beats a planned one 100 away
	Check(TurretDistanceSq(200.f * 200.f, 100.f * 100.f, 256.f) == 200.f * 200.f, "served at 200 beats planned at 100");
	// with nothing served, the planned slot counts penalty further
	Check(Near(std::sqrt(TurretDistanceSq(inf, 100.f * 100.f, 256.f)), 356.f, 0.1f), "planned counts 256 further");
	Check(TurretDistanceSq(inf, inf, 256.f) == inf, "nothing at all stays max");
}

// D-088 (owner): the turbines formed an L; same-def structures must grow as a
// filled rectangle. Simulate packing twelve turbines on a free grid with the
// group rule and check the result is compact.
void TestSameDefGrowsARectangle()
{
	std::vector<Pt> cells = Grid(12, 12, 0, 0, 48);
	const Pt turret{-48, 0};  // one served turret west of the corner cell
	std::vector<Pt> group;
	for (int i = 0; i < 12; ++i) {
		const Pt centroid = Centroid(group, Pt{});
		int best = -1;
		PackKey bestKey;
		for (std::size_t c = 0; c < cells.size(); ++c) {
			PackKey key{TurretDistanceSq(Sq(cells[c], turret), std::numeric_limits<float>::max(), 256.f),
					Sq(cells[c], turret),
					group.empty() ? std::numeric_limits<float>::max() : Sq(cells[c], centroid)};
			if (best < 0 || PackBefore(key, bestKey, !group.empty())) {
				best = int(c);
				bestKey = key;
			}
		}
		group.push_back(cells[best]);
		cells.erase(cells.begin() + best);
	}
	float minX = 1e9f, maxX = -1e9f, minZ = 1e9f, maxZ = -1e9f;
	for (const Pt& p : group) {
		minX = std::min(minX, p.x); maxX = std::max(maxX, p.x);
		minZ = std::min(minZ, p.z); maxZ = std::max(maxZ, p.z);
	}
	const int w = int((maxX - minX) / 48.f + 0.5f) + 1, h = int((maxZ - minZ) / 48.f + 0.5f) + 1;
	Check(w * h <= 20, "twelve turbines fill a box of at most 20 cells, not an L or a line (got " + std::to_string(w) + "x" + std::to_string(h) + ")");
	Check(std::max(w, h) <= 5, "no side longer than five (got " + std::to_string(w) + "x" + std::to_string(h) + ")");
}

void TestPackBeforeOrder()
{
	const PackKey nearGroup{900.f, 0.f, 10.f}, nearTurret{10.f, 0.f, 900.f};
	Check(PackBefore(nearGroup, nearTurret, true), "grouped: the group comes before the turret");
	Check(PackBefore(nearTurret, nearGroup, false), "ungrouped: the turret decides");
	const PackKey a{10.f, 5.f, 0.f}, b{10.f, 50.f, 0.f};
	Check(PackBefore(a, b, false) && !PackBefore(b, a, false), "equal turret distance: the anchor breaks the tie");
}

// D-085: planned slots count only near the seed when any is near; served ones
// weigh three and count anywhere in reach.
void TestWeightedSlots()
{
	std::vector<Slot> slots;
	for (const Pt& p : Grid(2, 4, 0, 0)) slots.push_back(Slot{p, false});
	slots.push_back(Slot{Pt{1000, 1000}, false});  // far planned slot
	const Pt seed{0, 0};
	const int n = WeightedSlots(Pt{72, 24}, slots, 260.f, seed, 560.f, 3);
	Check(n == 8, "the eight near planned slots count, the far one does not (got " + std::to_string(n) + ")");
	slots[0].served = true;
	Check(WeightedSlots(Pt{72, 24}, slots, 260.f, seed, 560.f, 3) == 10, "a served slot weighs three");
	const int far = WeightedSlots(Pt{1000, 1000}, slots, 260.f, seed, 560.f, 3);
	Check(far == 0, "a planned slot away from the seed is not counted while slots near the seed exist");
	std::vector<Slot> onlyFar{Slot{Pt{1000, 1000}, false}};
	Check(WeightedSlots(Pt{1000, 1000}, onlyFar, 260.f, seed, 560.f, 3) == 1, "with none near the seed every planned slot counts");
}

// D-087 (played: the lab 1,099 elmos from the seed): past `enough` slots the
// site nearest the seed wins.
void TestSiteNearestSeedPastEnough()
{
	const Pt seed{0, 0};
	const SiteKey farRich = MakeSiteKey(Pt{1000, 0}, 16, 8, seed, 0.f);
	const SiteKey nearEnough = MakeSiteKey(Pt{200, 0}, 9, 8, seed, 0.f);
	const SiteKey nearPoor = MakeSiteKey(Pt{100, 0}, 3, 8, seed, 0.f);
	Check(SiteBefore(nearEnough, farRich), "8+ slots near the seed beat 16 far away");
	Check(SiteBefore(nearEnough, nearPoor), "enough slots beat too few, however near");
	std::vector<SiteKey> keys{farRich, nearPoor, nearEnough};
	std::sort(keys.begin(), keys.end(), SiteBefore);
	Check(Near(keys.front().pos.x, 200), "sorted: the near well-reached site first");
	const SiteKey tieA = MakeSiteKey(Pt{200, 0}, 9, 8, seed, 100.f), tieB = MakeSiteKey(Pt{200.5f, 0}, 9, 8, seed, 50.f);
	Check(SiteBefore(tieB, tieA), "within one elmo of each other, the nearer turret wins");
}

// D-095 (played: the lab reserved 16 elmos from the home centre, its nearest
// turret 176 elmos away, INV-017): among well-reached sites the one flush with
// a turret slot wins over a nearer one that is not.
void TestSiteFlushBeforeNearer()
{
	const Pt seed{0, 0};
	const float flush = 160.f;
	const SiteKey nearGap = MakeSiteKey(Pt{16, 0}, 9, 8, seed, 0.f, 176.f * 176.f, flush);
	const SiteKey flushSite = MakeSiteKey(Pt{48, 0}, 9, 8, seed, 0.f, 160.f * 160.f, flush);
	Check(flushSite.flush && !nearGap.flush, "160 is flush, 176 is not");
	Check(SiteBefore(flushSite, nearGap), "a flush site beats a nearer one with a gap");
	const SiteKey flushPoor = MakeSiteKey(Pt{48, 0}, 3, 8, seed, 0.f, 100.f * 100.f, flush);
	Check(SiteBefore(nearGap, flushPoor), "build power first: flush does not beat too few slots");
	const SiteKey offA = MakeSiteKey(Pt{16, 0}, 9, 8, seed, 0.f, 176.f * 176.f, 0.f);
	const SiteKey offB = MakeSiteKey(Pt{48, 0}, 9, 8, seed, 0.f, 10.f, 0.f);
	Check(!offB.flush && SiteBefore(offA, offB), "flush distance 0: the key is off, D-087 alone");
}

// D-096 (played: the advanced lab faced into its turrets, on the home side of
// the block): among well-reached sites the one ahead of the block along its
// facing wins, before flush and before nearer the seed.
void TestSiteAheadOfTheBlock()
{
	const std::vector<Pt> block{Pt{0, 0}, Pt{48, 0}, Pt{0, 48}, Pt{48, 48}};
	const Pt east = FacingForward(1);
	Check(Near(east.x, 1) && Near(east.z, 0), "facing 1 is +x");
	Check(Near(FacingForward(2).z, -1), "facing 2 is -z");
	Check(AheadOf(Pt{200, 24}, block, east), "east of the block, facing east: ahead");
	Check(!AheadOf(Pt{-200, 24}, block, east), "west of the block, facing east: behind");
	Check(!AheadOf(Pt{200, 24}, {}, east), "no block: not ahead");
	const Pt seed{0, 0};
	const SiteKey behindNearFlush = MakeSiteKey(Pt{-120, 24}, 9, 8, seed, 0.f, 100.f * 100.f, 160.f, false);
	const SiteKey aheadFarGap = MakeSiteKey(Pt{240, 24}, 9, 8, seed, 0.f, 176.f * 176.f, 160.f, true);
	Check(SiteBefore(aheadFarGap, behindNearFlush), "ahead of the block beats flush and nearer behind it");
	const SiteKey aheadPoor = MakeSiteKey(Pt{240, 24}, 2, 8, seed, 0.f, 100.f * 100.f, 160.f, true);
	Check(SiteBefore(behindNearFlush, aheadPoor), "build power first: ahead does not beat too few slots");
	const SiteKey aheadFlush = MakeSiteKey(Pt{300, 24}, 9, 8, seed, 0.f, 150.f * 150.f, 160.f, true);
	Check(SiteBefore(aheadFlush, aheadFarGap), "ahead and flush beats ahead with a gap, though further");
}

// D-096 (played: windmills packed across the advanced lab's exit): a footprint
// overlapping a factory's exit lane is refused, one beside it is not.
void TestExitLanes()
{
	const std::vector<CellRect> lanes{CellRect{10, 0, 20, 30}};
	Check(OverlapsAny(CellRect{12, 5, 14, 7}, lanes), "a windmill inside the lane overlaps");
	Check(OverlapsAny(CellRect{19, 29, 22, 32}, lanes), "a corner in the lane overlaps");
	Check(!OverlapsAny(CellRect{20, 5, 22, 7}, lanes), "touching the lane's edge does not");
	Check(!OverlapsAny(CellRect{0, 0, 10, 30}, lanes), "the other side's edge does not");
	Check(!OverlapsAny(CellRect{12, 5, 14, 7}, {}), "no factory, no lane");
}

// D-099 (owner: build around the turrets, the box need not grow): the ring scan
// skips footprints wholly inside the zone (already scanned) and keeps those that
// reach outside it.
void TestRingSkipsTheZone()
{
	const CellRect zone{10, 10, 50, 60};
	Check(Inside(CellRect{10, 10, 13, 13}, zone), "a footprint on the zone's corner is inside");
	Check(!Inside(CellRect{8, 10, 11, 13}, zone), "one cell past the edge is the ring's");
	Check(!Inside(CellRect{48, 58, 51, 61}, zone), "the far corner, one cell out, is the ring's");
	Check(Inside(CellRect{47, 57, 50, 60}, zone), "flush with the far corner is inside");
}

// D-101 (owner: advanced fusions flush against the turrets, then lined up
// moving away from them): touching is gap 0, one free cell is gap 1, and a set
// steps along the axis away from the turret it touches.
void TestFlushAndSetStep()
{
	const CellRect turret{10, 10, 12, 12};
	Check(EdgeGap(CellRect{12, 10, 18, 16}, turret) == 0, "sharing an edge is flush");
	Check(EdgeGap(CellRect{13, 10, 19, 16}, turret) == 1, "one free cell between is gap 1");
	Check(EdgeGap(CellRect{12, 12, 18, 18}, turret) == 0, "corner to corner touches");
	Check(NearestEdgeGap(CellRect{20, 20, 26, 26}, {turret, CellRect{26, 20, 28, 22}}) == 0, "the nearest turret decides");
	int sx = 0, sz = 0;
	SetStep(240.f, 176.f, 176.f, 176.f, 6, 6, sx, sz);
	Check(sx == 6 && sz == 0, "east of the turret: the set grows east by one footprint");
	SetStep(176.f, 100.f, 176.f, 176.f, 6, 4, sx, sz);
	Check(sx == 0 && sz == -4, "north of the turret: the set grows north");
}

// D-072/D-090: pockets.
void TestLeavesPocket()
{
	// 5x5 grid, a ring of blocked cells around the centre: the centre is a pocket
	std::vector<char> open(25, 1);
	for (int i : {6, 7, 8, 11, 13, 16, 17, 18}) open[i] = 0;
	Check(LeavesPocket(open, 5, 5), "a free cell ringed by structures is a pocket");
	open[7] = 1;  // open the ring's top
	Check(!LeavesPocket(open, 5, 5), "an opening to the border is no pocket");
	std::vector<char> all(9, 1);
	Check(!LeavesPocket(all, 3, 3), "an open grid has no pocket");
	std::vector<char> none(9, 0);
	Check(!LeavesPocket(none, 3, 3), "a full grid has no pocket");
	Check(!LeavesPocket({}, 0, 0), "an empty grid has no pocket");
}

// D-091: drop spots are tried nearest first and never where the engine refused.
void TestRingOrderAndClearOf()
{
	const std::vector<Pt> ring = RingOrder(Pt{100, 100}, 64.f, 32.f, 16);
	Check(ring.size() == 1 + 16 + 16, "centre plus two rings of sixteen");
	Check(Near(ring.front().x, 100) && Near(ring.front().z, 100), "the centre is tried first");
	bool sorted = true;
	for (std::size_t i = 1; i < ring.size(); ++i) {
		if (Dist(ring[i], Pt{100, 100}) + 0.01f < Dist(ring[i - 1], Pt{100, 100})) sorted = false;
	}
	Check(sorted, "points come nearest first");
	Check(RingOrder(Pt{}, 64.f, 0.f, 16).empty(), "a zero step yields nothing");
	const std::vector<Pt> refused{Pt{100, 100}};
	Check(!ClearOf(Pt{110, 100}, refused, 64.f), "a spot beside a refused one is not clear");
	Check(ClearOf(Pt{200, 100}, refused, 64.f), "a spot far from it is clear");
	Check(ClearOf(Pt{0, 0}, {}, 64.f), "nothing refused: every spot is clear");
	// played (owner's log): every retry returned the same refused spot
	int firstClear = -1;
	for (std::size_t i = 0; i < ring.size(); ++i) {
		if (ClearOf(ring[i], refused, 64.f)) { firstClear = int(i); break; }
	}
	Check(firstClear > 0 && Dist(ring[firstClear], Pt{100, 100}) >= 63.f, "after a refusal the search moves on to new ground");
}

}  // namespace

// D-343: SEA turret and economy reservations may not cut the flagship off.
void TestHullPathClear()
{
	const int w = 40, h = 20;
	std::vector<char> water(w * h, 1);
	Check(HullPathClear(water, w, h, 2, 10, 37, 10, 3, 1), "open water lets a wide hull through");
	// A wall across the window with a 5-cell gap at rows 8..12.
	std::vector<char> wall = water;
	for (int z = 0; z < h; ++z) {
		if (z < 8 || z > 12) wall[z * w + 20] = 0;
	}
	Check(HullPathClear(wall, w, h, 2, 10, 37, 10, 2, 1), "a 5-cell gap passes a hull of half-width 2");
	Check(!HullPathClear(wall, w, h, 2, 10, 37, 10, 3, 1), "a 5-cell gap stops a hull of half-width 3");
	// Sealing the gap blocks every hull, even one cell wide.
	std::vector<char> sealed = wall;
	for (int z = 8; z <= 12; ++z) sealed[z * w + 20] = 0;
	Check(!HullPathClear(sealed, w, h, 2, 10, 37, 10, 0, 1), "a sealed wall blocks the narrowest hull");
	// A start hugging a footprint snaps to clear water within `snap` cells.
	std::vector<char> yard = water;
	for (int z = 5; z < 15; ++z) for (int x = 0; x < 4; ++x) yard[z * w + x] = 0;
	Check(!HullPathClear(yard, w, h, 4, 10, 37, 10, 3, 0), "the mouth cell itself is too close to the yard");
	Check(HullPathClear(yard, w, h, 4, 10, 37, 10, 3, 4), "the mouth snaps to clear water beside the yard");
	Check(!HullPathClear(water, w, h, -1, 10, 37, 10, 1, 1), "an endpoint outside the window is refused");
}

int main()
{
    for (int requested=0;requested<4;++requested) for (int actual=0;actual<4;++actual) {
        Check(MatchesFacingPass(actual,requested)==(actual==requested),
            "opening facing pass tests and serves the same exit orientation");
        Check(MatchesFacingPass(actual,-1), "other roles retain any reserved facing");
    }
	// Real completed power, not a dense reservation of future turrets, owns
	// rush placement. Cover overlap, unequal build speed and exact reach edges.
	const std::vector<BuiltPower> built{{{0, 0}, 100.f, 240.f}, {{10, 0}, 100.f, 300.f}};
	Check(PowerAt({5, 0}, built) == 540.f, "sum overlapping completed assistants");
	Check(PowerAt({20, 0}, built) == 300.f, "include exact reach boundary");
	Check(PowerAt({20.01f, 0}, built) == 0.f, "exclude just beyond reach");
	Check(PowerAt({0, 0}, {}) == 0.f, "planned but unbuilt area has no power");
	Check(BuiltPowerBefore(540, 10000, 300, 1), "working power outranks proximity");
	Check(BuiltPowerBefore(540, 4, 540, 9), "equal power prefers anchor proximity");
	Check(!BuiltPowerBefore(540, 4, 540, 4), "exact ties retain candidate order");
	TestCentroidAndNearest();
	const std::vector<SupportReach> supports{{{0, 0}, 100.f}, {{250, 0}, 20.f}};
	Check(WithinSupport({100, 0}, supports), "packed set includes exact support boundary");
	Check(!WithinSupport({100.1f, 0}, supports), "packed extension stops outside first support");
	Check(WithinSupport({250, 0}, supports), "another support can serve a later member");
	Check(!WithinSupport({0, 0}, {}), "no imaginary support for empty group");
	Check(!WithinSupport({0, 0}, {{{0, 0}, -100.f}}), "invalid reach cannot be squared positive");
	TestFirstTurretNearestSeed();
	TestBlockFillsAcrossRows();
	TestNextConnectedNoneFree();
	TestServedOutranksPlanned();
	TestSameDefGrowsARectangle();
	TestPackBeforeOrder();
	TestWeightedSlots();
	TestSiteNearestSeedPastEnough();
	TestSiteFlushBeforeNearer();
	TestSiteAheadOfTheBlock();
	TestExitLanes();
	TestRingSkipsTheZone();
	TestFlushAndSetStep();
	TestLeavesPocket();
	TestHullPathClear();
	TestRingOrderAndClearOf();
	if (failures > 0) {
		std::cerr << failures << " of " << checks << " checks failed\n";
		return 1;
	}
	std::cout << "layout ranking: " << checks << " checks passed\n";
	return 0;
}
