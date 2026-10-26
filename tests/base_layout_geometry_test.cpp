#include "circuit/terrain/BaseLayoutGeometry.h"

#include <cstdlib>
#include <iostream>
#include <string>
#include <tuple>
#include <vector>

namespace {

using namespace circuit::base_layout;

int failures = 0;

void Check(bool condition, const std::string& message)
{
	if (!condition) {
		std::cerr << "FAIL: " << message << '\n';
		++failures;
	}
}

void CheckNoOverlap(const std::vector<Slot>& slots, const std::string& name)
{
	for (std::size_t i = 0; i < slots.size(); ++i) {
		for (std::size_t j = i + 1; j < slots.size(); ++j) {
			Check(!Intersects(
					RectFromCentre(slots[i].centre, slots[i].footprint, slots[i].facing),
					RectFromCentre(slots[j].centre, slots[j].footprint, slots[j].facing)),
					name + " slots overlap");
		}
	}
}

int ForwardProjection(const Point& origin, const Point& point, int facing)
{
	const Point fw = Forward(facing);
	return (point.x2 - origin.x2) * fw.x2 / 2 + (point.z2 - origin.z2) * fw.z2 / 2;
}

int SideProjection(const Point& origin, const Point& point, int facing)
{
	const Point side = Side(facing);
	return (point.x2 - origin.x2) * side.x2 / 2 + (point.z2 - origin.z2) * side.z2 / 2;
}

void TestFootprintSnapping()
{
	for (int facing = 0; facing < 4; ++facing) {
		const Footprint odd{3, 5};
		const Footprint even{6, 4};
		const Point oddCentre{21, 31};
		const Point evenCentre{20, 32};
		Check(IsAligned(oddCentre, odd, facing), "odd footprint aligns for facing " + std::to_string(facing));
		Check(IsAligned(evenCentre, even, facing), "even footprint aligns for facing " + std::to_string(facing));
		const Rect oddRect = RectFromCentre(oddCentre, odd, facing);
		const Rect evenRect = RectFromCentre(evenCentre, even, facing);
		Check(oddRect.Width() == ((facing & 1) == 0 ? 3 : 5), "odd width rotates exactly");
		Check(oddRect.Depth() == ((facing & 1) == 0 ? 5 : 3), "odd depth rotates exactly");
		Check(evenRect.Width() == ((facing & 1) == 0 ? 6 : 4), "even width rotates exactly");
		Check(evenRect.Depth() == ((facing & 1) == 0 ? 4 : 6), "even depth rotates exactly");
	}
}

void TestFactoryClusters()
{
	const Footprint nano{3, 3};
	for (int facing = 0; facing < 4; ++facing) {
		for (const auto& [factory, tier, expected] : {
				std::tuple{Footprint{6, 6}, FactoryTier::T1, 2},
				std::tuple{Footprint{9, 9}, FactoryTier::T2, 6}}) {
			const Point centre{100 + Across(factory, facing) % 2, 120 + Along(factory, facing) % 2};
			const FactoryCluster cluster = MakeFactoryCluster(centre, facing, factory, nano, tier);
			Check(cluster.valid, "factory cluster valid");
			Check(static_cast<int>(cluster.nanos.size()) == expected, "factory nano count");
			CheckNoOverlap(cluster.nanos, "factory");
			const Rect factoryRect = RectFromCentre(cluster.factory.centre, factory, facing);
			Check(TouchesEdge(factoryRect, cluster.nanoBounds), "nano block touches factory rear");
			for (const Slot& slot : cluster.nanos) {
				Check(ForwardProjection(centre, slot.centre, facing) < 0, "nanos are behind factory");
			}
			for (std::size_t i = 1; i < cluster.nanos.size(); ++i) {
				Check(ForwardProjection(centre, cluster.nanos[i - 1].centre, facing)
						<= ForwardProjection(centre, cluster.nanos[i].centre, facing),
						"factory nano rows are ordered far-to-near");
			}
			Check(cluster.exit.Width() == (((facing & 1) == 0) ? Across(factory, facing) + 4 : 20),
					"exit world width");
			Check(cluster.exit.Depth() == (((facing & 1) == 0) ? 20 : Across(factory, facing) + 4),
					"exit world depth");
			Check(TouchesEdge(factoryRect, cluster.exit), "exit rectangle touches factory front");
			Check(!Intersects(factoryRect, cluster.exit), "exit rectangle does not overlap factory");
		}
	}
}

void TestFactoryPairSymmetry()
{
	const Footprint nano{3, 3};
	for (int facing = 0; facing < 4; ++facing) {
		const Point rear{80, 80};
		const FactoryPair pair = MakeFactoryPair(
				rear, facing, Footprint{6, 6}, FactoryTier::T1,
				Footprint{9, 9}, FactoryTier::T2, nano, 2);
		Check(pair.valid, "factory pair valid");
		const int firstSide = SideProjection(pair.rearEdgeCentre, pair.first.factory.centre, facing);
		const int secondSide = SideProjection(pair.rearEdgeCentre, pair.second.factory.centre, facing);
		Check(firstSide < 0 && secondSide > 0, "factory pair straddles centre");
		Check(pair.sideMin2 == -pair.sideMax2, "factory pair bounds are symmetric");
		Check(!Intersects(
				RectFromCentre(pair.first.factory.centre, pair.first.factory.footprint, facing),
				RectFromCentre(pair.second.factory.centre, pair.second.factory.footprint, facing)),
				"factory pair does not overlap");
	}
}

void TestAirClustersPackSixWithoutOverlap()
{
	for (int facing = 0; facing < 4; ++facing) {
		for (Footprint first : {Footprint{9, 6}, Footprint{6, 6}, Footprint{9, 9}}) {
			const auto plan = MakeAirFactoryCluster({301, 303}, facing, first, {9, 9}, {3, 3}, 6, 3, 5, 20);
			Check(plan.valid && plan.factories.size() == 6, "six air labs planned atomically");
			std::vector<Slot> slots = plan.factories;
			for (std::size_t b = 0; b < plan.nanos.size(); ++b) {
				Check(plan.nanos[b].size() == (b == 0 ? 5u : 20u), "distinct support per bay");
				for (const auto& nano : plan.nanos[b]) {
					const int dx = (nano.centre.x2 - plan.factories[b].centre.x2) * HALF_CELL_ELMOS;
					const int dz = (nano.centre.z2 - plan.factories[b].centre.z2) * HALF_CELL_ELMOS;
					Check(dx * dx + dz * dz <= 400 * 400, "all air support reaches its assigned lab");
					slots.push_back(nano);
				}
			}
			Check(plan.bounds.Width() * plan.bounds.Depth() <= 27 * 60, "rear support removes unused side-bank space");
			Check(TouchesEdge(RectFromCentre(plan.factories[1].centre, plan.factories[1].footprint, facing),
				RectFromCentre(plan.factories[2].centre, plan.factories[2].footprint, facing)), "air factories share an edge without an unused aisle");
			for (std::size_t i = 0; i < slots.size(); ++i) {
				const auto rect = RectFromCentre(slots[i].centre, slots[i].footprint, facing);
				Check(IsAligned(slots[i].centre, slots[i].footprint, facing), "air slot aligned after rotation");
				Check(Contains(plan.bounds, rect), "air slot inside compound");
				for (std::size_t j = 0; j < i; ++j)
					Check(!Intersects(rect, RectFromCentre(slots[j].centre, slots[j].footprint, facing)), "air slots never overlap");
			}
		}
	}
	Check(!MakeAirFactoryCluster({}, 0, {9, 6}, {9, 9}, {3, 3}, 7, 3, 5, 20).valid, "seventh lab needs another cluster");
	Check(!MakeAirFactoryCluster({}, 4, {9, 6}, {9, 9}, {3, 3}, 6, 3, 5, 20).valid, "invalid air facing rejected");
}

void TestCenteredAirClusters()
{
	for (int facing = 0; facing < 4; ++facing) {
		for (int count = 1; count <= 6; ++count) {
			for (int columns = 1; columns <= count; ++columns) {
				for (bool firstT2 : {false, true}) {
					const Footprint first = firstT2 ? Footprint{9, 9} : Footprint{9, 6};
					const int firstNanos = firstT2 ? 20 : 5;
					const auto old = MakeAirFactoryCluster({301, 303}, facing, first, {9, 9}, {3, 3}, count, columns, firstNanos, 20);
					const auto plan = MakeAirFactoryCluster({301, 303}, facing, first, {9, 9}, {3, 3}, count, columns, firstNanos, 20, firstT2, true);
					Check(plan.valid, "centered air plan valid");
					Check(plan.bounds.minX == old.bounds.minX && plan.bounds.maxX == old.bounds.maxX
						&& plan.bounds.minZ == old.bounds.minZ && plan.bounds.maxZ == old.bounds.maxZ,
						"centered plan preserves exact reservation envelope");
					std::vector<Slot> slots = plan.factories;
					for (int b = 0; b < count; ++b) {
						Check(plan.nanos[b].size() == old.nanos[b].size(), "support capacity unchanged");
						if (b == 0 && !firstT2) {
							Check(plan.factories[b].centre.x2 == old.factories[b].centre.x2 && plan.factories[b].centre.z2 == old.factories[b].centre.z2, "T1 lab stays in place");
							for (std::size_t i = 0; i < plan.nanos[b].size(); ++i)
								Check(plan.nanos[b][i].centre.x2 == old.nanos[b][i].centre.x2 && plan.nanos[b][i].centre.z2 == old.nanos[b][i].centre.z2, "T1 support stays in place");
						} else {
							const Point forward = Offset({}, facing, 1, 0);
							int rear = 0, front = 0;
							for (const auto& nano : plan.nanos[b]) {
								const int dx = nano.centre.x2 - plan.factories[b].centre.x2;
								const int dz = nano.centre.z2 - plan.factories[b].centre.z2;
								if (dx * forward.x2 + dz * forward.z2 < 0) ++rear; else ++front;
								Check((dx * dx + dz * dz) * HALF_CELL_ELMOS * HALF_CELL_ELMOS <= 400 * 400, "centered support reaches factory");
							}
							Check(rear == 9 && front == 11, "T2 factory between balanced nine/eleven banks");
						}
						slots.insert(slots.end(), plan.nanos[b].begin(), plan.nanos[b].end());
					}
					for (std::size_t i = 0; i < slots.size(); ++i) {
						const auto rect = RectFromCentre(slots[i].centre, slots[i].footprint, facing);
						Check(IsAligned(slots[i].centre, slots[i].footprint, facing), "centered slot aligned");
						Check(Contains(plan.bounds, rect), "centered slot inside original envelope");
						for (std::size_t j = 0; j < i; ++j)
							Check(!Intersects(rect, RectFromCentre(slots[j].centre, slots[j].footprint, facing)), "centered slots do not overlap");
					}
				}
			}
		}
	}
}

void TestBoundsAndIntersection()
{
	const Rect a{0, 0, 4, 4};
	const Rect b{4, 0, 8, 4};
	const Rect c{3, 3, 6, 6};
	Check(!Intersects(a, b), "touching rectangles do not overlap");
	Check(TouchesEdge(a, b), "touching edge detected");
	Check(Intersects(a, c), "intersection detected");
	Check(Contains(Rect{0, 0, 10, 10}, c), "containment detected");
	Check(InBounds(Rect{0, 0, 10, 10}, 10, 10), "upper edge is in bounds");
	Check(!InBounds(Rect{-1, 0, 2, 2}, 10, 10), "negative edge is out of bounds");
	Check(!InBounds(Rect{0, 0, 11, 2}, 10, 10), "oversized rectangle is out of bounds");
}

} // namespace

int main()
{
	TestFootprintSnapping();
	TestFactoryClusters();
	TestFactoryPairSymmetry();
	TestBoundsAndIntersection();
	TestAirClustersPackSixWithoutOverlap();
	TestCenteredAirClusters();
	if (failures != 0) {
		std::cerr << failures << " base-layout geometry check(s) failed\n";
		return EXIT_FAILURE;
	}
	std::cout << "base-layout geometry tests passed\n";
	return EXIT_SUCCESS;
}
