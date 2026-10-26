#ifndef SRC_CIRCUIT_TERRAIN_BASELAYOUTGEOMETRY_H_
#define SRC_CIRCUIT_TERRAIN_BASELAYOUTGEOMETRY_H_

#include <algorithm>
#include <array>
#include <cstddef>
#include <vector>

namespace circuit::base_layout {

constexpr int CELL_ELMOS = 16;
constexpr int HALF_CELL_ELMOS = CELL_ELMOS / 2;
constexpr int FACTORY_EXIT_DEPTH = 20;
constexpr int FACTORY_EXIT_MARGIN = 2;

enum class Facing : int {
	SOUTH = 0,
	EAST = 1,
	NORTH = 2,
	WEST = 3,
};

enum class FactoryTier : int {
	T1 = 1,
	T2 = 2,
};

struct Point {
	int x2 = 0;  // half-cell coordinates
	int z2 = 0;

	constexpr bool operator==(const Point&) const = default;
};

struct Footprint {
	int x = 0;  // blocking-map cells before rotation
	int z = 0;
};

struct Rect {
	int minX = 0;  // cell edges, [min, max)
	int minZ = 0;
	int maxX = 0;
	int maxZ = 0;

	[[nodiscard]] constexpr int Width() const { return maxX - minX; }
	[[nodiscard]] constexpr int Depth() const { return maxZ - minZ; }
	[[nodiscard]] constexpr bool IsValid() const { return (minX < maxX) && (minZ < maxZ); }
};

struct Slot {
	Point centre;
	Footprint footprint;
	int facing = 0;
	int order = 0;
};

struct FactoryCluster {
	Slot factory;
	std::vector<Slot> nanos;
	Rect exit;
	Rect nanoBounds;
	bool valid = false;
};

struct FactoryPair {
	FactoryCluster first;
	FactoryCluster second;
	Point rearEdgeCentre;
	int sideMin2 = 0;
	int sideMax2 = 0;
	bool valid = false;
};

[[nodiscard]] constexpr bool IsFacingValid(int facing)
{
	return (facing >= static_cast<int>(Facing::SOUTH))
		&& (facing <= static_cast<int>(Facing::WEST));
}

[[nodiscard]] constexpr Point Forward(int facing)
{
	switch (static_cast<Facing>(facing)) {
		case Facing::EAST:  return {2, 0};
		case Facing::NORTH: return {0, -2};
		case Facing::WEST:  return {-2, 0};
		case Facing::SOUTH:
		default:            return {0, 2};
	}
}

[[nodiscard]] constexpr Point Side(int facing)
{
	switch (static_cast<Facing>(facing)) {
		case Facing::EAST:  return {0, -2};
		case Facing::NORTH: return {-2, 0};
		case Facing::WEST:  return {0, 2};
		case Facing::SOUTH:
		default:            return {2, 0};
	}
}

[[nodiscard]] constexpr Point Offset(const Point& origin, int facing, int forward2, int side2)
{
	const Point fw = Forward(facing);
	const Point sd = Side(facing);
	return {
		origin.x2 + fw.x2 * forward2 / 2 + sd.x2 * side2 / 2,
		origin.z2 + fw.z2 * forward2 / 2 + sd.z2 * side2 / 2,
	};
}

[[nodiscard]] constexpr int Across(const Footprint& footprint, int facing)
{
	return ((facing & 1) == 0) ? footprint.x : footprint.z;
}

[[nodiscard]] constexpr int Along(const Footprint& footprint, int facing)
{
	return ((facing & 1) == 0) ? footprint.z : footprint.x;
}

[[nodiscard]] constexpr bool IsAligned(const Point& centre, const Footprint& footprint, int facing)
{
	const int worldX = ((facing & 1) == 0) ? footprint.x : footprint.z;
	const int worldZ = ((facing & 1) == 0) ? footprint.z : footprint.x;
	return (((centre.x2 - worldX) & 1) == 0) && (((centre.z2 - worldZ) & 1) == 0);
}

[[nodiscard]] constexpr Rect RectFromCentre(const Point& centre, const Footprint& footprint, int facing)
{
	const int worldX = ((facing & 1) == 0) ? footprint.x : footprint.z;
	const int worldZ = ((facing & 1) == 0) ? footprint.z : footprint.x;
	return {
		(centre.x2 - worldX) / 2,
		(centre.z2 - worldZ) / 2,
		(centre.x2 + worldX) / 2,
		(centre.z2 + worldZ) / 2,
	};
}

[[nodiscard]] constexpr Point CentreOf(const Rect& rect)
{
	return {rect.minX + rect.maxX, rect.minZ + rect.maxZ};
}

[[nodiscard]] constexpr int AlignParity(int value, int parity)
{
	return ((value & 1) == (parity & 1)) ? value : value + 1;
}

[[nodiscard]] constexpr bool Intersects(const Rect& lhs, const Rect& rhs)
{
	return (lhs.minX < rhs.maxX) && (rhs.minX < lhs.maxX)
		&& (lhs.minZ < rhs.maxZ) && (rhs.minZ < lhs.maxZ);
}

[[nodiscard]] constexpr bool TouchesEdge(const Rect& lhs, const Rect& rhs)
{
	const bool xTouch = ((lhs.maxX == rhs.minX) || (rhs.maxX == lhs.minX))
		&& (lhs.minZ < rhs.maxZ) && (rhs.minZ < lhs.maxZ);
	const bool zTouch = ((lhs.maxZ == rhs.minZ) || (rhs.maxZ == lhs.minZ))
		&& (lhs.minX < rhs.maxX) && (rhs.minX < lhs.maxX);
	return xTouch || zTouch;
}

[[nodiscard]] constexpr bool Contains(const Rect& outer, const Rect& inner)
{
	return (outer.minX <= inner.minX) && (inner.maxX <= outer.maxX)
		&& (outer.minZ <= inner.minZ) && (inner.maxZ <= outer.maxZ);
}

[[nodiscard]] constexpr bool InBounds(const Rect& rect, int columns, int rows)
{
	return rect.IsValid() && (rect.minX >= 0) && (rect.minZ >= 0)
		&& (rect.maxX <= columns) && (rect.maxZ <= rows);
}

[[nodiscard]] inline Rect BoundsOf(const std::vector<Slot>& slots)
{
	if (slots.empty()) {
		return {};
	}
	Rect bounds = RectFromCentre(slots.front().centre, slots.front().footprint, slots.front().facing);
	for (std::size_t i = 1; i < slots.size(); ++i) {
		const Rect rect = RectFromCentre(slots[i].centre, slots[i].footprint, slots[i].facing);
		bounds.minX = std::min(bounds.minX, rect.minX);
		bounds.minZ = std::min(bounds.minZ, rect.minZ);
		bounds.maxX = std::max(bounds.maxX, rect.maxX);
		bounds.maxZ = std::max(bounds.maxZ, rect.maxZ);
	}
	return bounds;
}

// Flying output needs no internal ground exit corridor. Geometry only: callers
// own tier/count policy, terrain preflight, reservations and funding.
struct AirFactoryCluster {
	std::vector<Slot> factories;
	std::vector<std::vector<Slot>> nanos;
	Rect bounds;
	bool valid = false;
};

[[nodiscard]] inline AirFactoryCluster MakeAirFactoryCluster(Point origin, int facing,
		Footprint first, Footprint repeated, Footprint nano, int count, int columns,
		int firstNanos, int repeatedNanos, bool centerFirst = false, bool centerRepeated = false)
{
	AirFactoryCluster result;
	if (!IsFacingValid(facing) || count < 1 || count > 6 || columns < 1 || columns > count
			|| first.x <= 0 || first.z <= 0 || repeated.x <= 0 || repeated.z <= 0
			|| nano.x <= 0 || nano.z <= 0 || firstNanos < 0 || firstNanos > 20
			|| repeatedNanos < 0 || repeatedNanos > 20) return result;
	origin.x2 -= origin.x2 & 1;
	origin.z2 -= origin.z2 & 1;
	const int width = std::max(first.x, repeated.x);
	const int supportColumns = std::max(1, width / nano.x);
	const int supportRows = (std::max(firstNanos, repeatedNanos) + supportColumns - 1) / supportColumns;
	const int supportDepth = supportRows * nano.z;
	const int depth = std::max(first.z, repeated.z) + supportDepth;
	const int pitch = std::max(width, nano.x);
	std::vector<Slot> all;
	for (int b = 0; b < count; ++b) {
		const Footprint fp = b == 0 ? first : repeated;
		const Point corner = Offset(origin, facing, 2 * (b / columns) * depth, 2 * (b % columns) * pitch);
		const int centreX2 = AlignParity(pitch, fp.x);
		const int centreZ2 = 2 * supportDepth + fp.z;
		const Slot factory{Offset(corner, facing, centreZ2, centreX2), fp, facing, b};
		result.factories.push_back(factory);
		all.push_back(factory);
		std::vector<Slot> support;
		const int n = b == 0 ? firstNanos : repeatedNanos;
		for (int i = 0; i < n; ++i) {
			const int col = i % supportColumns;
			const int row = i / supportColumns;
			const int x2 = (2 * col + 1) * nano.x;
			const Slot slot{Offset(corner, facing, 2 * supportDepth - (2 * row + 1) * nano.z, x2), nano, facing, i};
			support.push_back(slot);
			all.push_back(slot);
		}
		result.nanos.push_back(std::move(support));
	}
	result.bounds = BoundsOf(all);
	// Preserve the legacy reservation envelope exactly; only rearrange its slots.
	// Planning-only O(total support slots), at most 120, with no extra allocations
	// or callbacks. Persisted reservations retain their original coordinates.
	// Odd support-row counts split floor/ceil: 20 3x3 nanos around a 9x9 lab
	// require 9/11 banks within the original 9x30 bay, rather than a wider bay.
	// Covered across rotations and campus shapes by base_layout_geometry_test.
	for (int b = 0; b < count; ++b) {
		if (!(b == 0 ? centerFirst : centerRepeated)) continue;
		auto& support = result.nanos[b];
		const int rows = (int(support.size()) + supportColumns - 1) / supportColumns;
		const int rearRows = rows / 2;
		const int frontRows = rows - rearRows;
		auto& factory = result.factories[b];
		factory.centre = Offset(factory.centre, facing, -2 * frontRows * nano.z, 0);
		const Point corner = Offset(origin, facing, 2 * (b / columns) * depth, 2 * (b % columns) * pitch);
		const int rearEdge = supportDepth - frontRows * nano.z;
		for (int i = 0; i < int(support.size()); ++i) {
			const int row = i / supportColumns;
			// Fill the shorter rear bank then the front bank, nearest factory first.
			const int z2 = row < rearRows
				? 2 * rearEdge - (2 * row + 1) * nano.z
				: 2 * (rearEdge + factory.footprint.z) + (2 * (row - rearRows) + 1) * nano.z;
			support[i].centre = Offset(corner, facing, z2, (2 * (i % supportColumns) + 1) * nano.x);
		}
	}
	result.valid = true;
	return result;
}

[[nodiscard]] constexpr Rect OrientedRect(
		const Point& origin, int facing, int front2, int back2, int left2, int right2)
{
	const std::array<Point, 4> corners = {
		Offset(origin, facing, front2, left2),
		Offset(origin, facing, front2, right2),
		Offset(origin, facing, back2, left2),
		Offset(origin, facing, back2, right2),
	};
	int minX2 = corners[0].x2;
	int maxX2 = minX2;
	int minZ2 = corners[0].z2;
	int maxZ2 = minZ2;
	for (std::size_t i = 1; i < corners.size(); ++i) {
		minX2 = std::min(minX2, corners[i].x2);
		maxX2 = std::max(maxX2, corners[i].x2);
		minZ2 = std::min(minZ2, corners[i].z2);
		maxZ2 = std::max(maxZ2, corners[i].z2);
	}
	return {minX2 / 2, minZ2 / 2, maxX2 / 2, maxZ2 / 2};
}

[[nodiscard]] inline std::vector<Slot> GridBehind(
		const Point& frontEdgeCentre, int facing, const Footprint& footprint,
		int cols, int rows, int gapCells, bool farToNear, int accessSide)
{
	std::vector<Slot> slots;
	if (!IsFacingValid(facing) || (footprint.x <= 0) || (footprint.z <= 0)
			|| (cols <= 0) || (rows <= 0) || (gapCells < 0)) {
		return slots;
	}
	slots.reserve(static_cast<std::size_t>(cols * rows));
	const int width = Across(footprint, facing);
	const int depth = Along(footprint, facing);
	const int rowStep2 = 2 * (depth + gapCells);
	const int colStep2 = 2 * (width + gapCells);
	const int firstSide2 = -(cols - 1) * (width + gapCells);

	auto appendRow = [&](int row) {
		for (int i = 0; i < cols; ++i) {
			const int col = (accessSide < 0) ? (cols - 1 - i) : i;
			const int side2 = firstSide2 + col * colStep2;
			const int back2 = depth + row * rowStep2;
			slots.push_back({Offset(frontEdgeCentre, facing, -back2, side2), footprint, facing, static_cast<int>(slots.size())});
		}
	};
	if (farToNear) {
		for (int row = rows - 1; row >= 0; --row) {
			appendRow(row);
		}
	} else {
		for (int row = 0; row < rows; ++row) {
			appendRow(row);
		}
	}
	return slots;
}

[[nodiscard]] inline FactoryCluster MakeFactoryCluster(
		const Point& factoryCentre, int facing, const Footprint& factoryFootprint,
		const Footprint& nanoFootprint, FactoryTier tier)
{
	FactoryCluster cluster;
	if (!IsFacingValid(facing) || (factoryFootprint.x <= 0) || (factoryFootprint.z <= 0)
			|| (nanoFootprint.x <= 0) || (nanoFootprint.z <= 0)
			|| !IsAligned(factoryCentre, factoryFootprint, facing)) {
		return cluster;
	}
	const int factoryWidth = Across(factoryFootprint, facing);
	const int factoryDepth = Along(factoryFootprint, facing);
	const int nanoCols = (tier == FactoryTier::T2) ? 3 : 2;
	const int nanoRows = (tier == FactoryTier::T2) ? 2 : 1;
	const int nanoWidth = Across(nanoFootprint, facing);
	if (nanoCols * nanoWidth > factoryWidth) {
		return cluster;
	}

	cluster.factory = {factoryCentre, factoryFootprint, facing, 0};
	const Point rearEdge = Offset(factoryCentre, facing, -factoryDepth, 0);
	cluster.nanos = GridBehind(rearEdge, facing, nanoFootprint, nanoCols, nanoRows, 0, true, 1);
	cluster.nanoBounds = BoundsOf(cluster.nanos);
	cluster.exit = OrientedRect(
			factoryCentre, facing,
			factoryDepth + 2 * FACTORY_EXIT_DEPTH,
			factoryDepth,
			-(factoryWidth + 2 * FACTORY_EXIT_MARGIN),
			factoryWidth + 2 * FACTORY_EXIT_MARGIN);
	cluster.valid = (static_cast<int>(cluster.nanos.size()) == nanoCols * nanoRows)
		&& TouchesEdge(RectFromCentre(cluster.factory.centre, cluster.factory.footprint, facing), cluster.nanoBounds);
	return cluster;
}

[[nodiscard]] inline FactoryPair MakeFactoryPair(
		const Point& rearEdgeCentre, int facing,
		const Footprint& firstFactory, FactoryTier firstTier,
		const Footprint& secondFactory, FactoryTier secondTier,
		const Footprint& nanoFootprint, int gapCells)
{
	FactoryPair pair;
	if (!IsFacingValid(facing) || (gapCells < 0)) {
		return pair;
	}
	const int firstWidth = Across(firstFactory, facing);
	const int secondWidth = Across(secondFactory, facing);
	const int firstDepth = Along(firstFactory, facing);
	const int secondDepth = Along(secondFactory, facing);
	const int totalWidth = firstWidth + gapCells + secondWidth;
	Point alignedRear = rearEdgeCentre;
	if ((facing & 1) == 0) {
		alignedRear.x2 = AlignParity(alignedRear.x2, totalWidth);
		alignedRear.z2 = AlignParity(alignedRear.z2, 0);
	} else {
		alignedRear.x2 = AlignParity(alignedRear.x2, 0);
		alignedRear.z2 = AlignParity(alignedRear.z2, totalWidth);
	}
	const int firstSide2 = -totalWidth + firstWidth;
	const int secondSide2 = -totalWidth + 2 * (firstWidth + gapCells) + secondWidth;
	const Point firstCentre = Offset(alignedRear, facing, firstDepth, firstSide2);
	const Point secondCentre = Offset(alignedRear, facing, secondDepth, secondSide2);
	pair.first = MakeFactoryCluster(firstCentre, facing, firstFactory, nanoFootprint, firstTier);
	pair.second = MakeFactoryCluster(secondCentre, facing, secondFactory, nanoFootprint, secondTier);
	pair.rearEdgeCentre = alignedRear;
	pair.sideMin2 = -totalWidth;
	pair.sideMax2 = totalWidth;
	if (!pair.first.valid || !pair.second.valid) {
		return pair;
	}
	const Rect firstRect = RectFromCentre(pair.first.factory.centre, firstFactory, facing);
	const Rect secondRect = RectFromCentre(pair.second.factory.centre, secondFactory, facing);
	pair.valid = !Intersects(firstRect, secondRect)
		&& !Intersects(pair.first.nanoBounds, pair.second.nanoBounds)
		&& !Intersects(pair.first.exit, secondRect)
		&& !Intersects(pair.second.exit, firstRect);
	return pair;
}

} // namespace circuit::base_layout

#endif // SRC_CIRCUIT_TERRAIN_BASELAYOUTGEOMETRY_H_
