/*
 * FieldLandmarks.cpp
 *
 * Part B1: see FieldLandmarks.h. Stage order: contact distance, positions,
 * territory, features, labels and openings, landmarks, checks. Cost with G
 * cells, P positions, K sites per box and D demand points:
 *   contact distance and territory: one multi-source Dijkstra each, O(G log G);
 *   positions: greedy then swap k-medoids over a site lattice capped at
 *     kMaxSites per box, O(rounds * P * K * D) with nearest/second-nearest
 *     caching, D = K + metal clusters + geos;
 *   features: one pass over G plus O(P * regions) avenue membership;
 *   landmarks: O(G) for the island and LRPC masks, the rest over the Part A
 *     records (regions, chokes, landings, standoff vertices).
 * The cancel flag is tested between stages. Nothing here allocates per cell
 * per position; the per-position region table is P x regions bytes.
 */

#include "terrain/field/FieldLandmarks.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <numeric>
#include <queue>
#include <set>

namespace circuit::field {

const char* OpeningName(int opening)
{
	switch (opening) {
		case O_BOT: return "bot"; case O_VEH: return "vehicle"; case O_HOVER: return "hover";
		case O_SHIP: return "ship"; case O_AIR: return "air";
	}
	return "bot";
}

const char* LabelName(int label)
{
	switch (label) {
		case L_FRONT: return "front"; case L_SEA: return "sea"; case L_ISLAND: return "island"; case L_POND: return "pond";
		case L_GEO: return "geo"; case L_AIR: return "air"; case L_TECH: return "tech"; case L_FRONT_TECH: return "front/tech";
	}
	return "front";
}

const char* SubLabelName(int sub)
{
	switch (sub) {
		case S_BEACH_SEA: return "beach sea"; case S_GEO_SEA: return "geo sea"; case S_SUICIDE_FRONT: return "suicide front";
	}
	return "-";
}

const char* EnergyName(int energy)
{
	return energy == E_WIND ? "wind" : (energy == E_TIDAL ? "tidal" : "solar");
}

const char* MarkGroupName(int group)
{
	switch (group) {
		case MG_ECONOMY: return "economy"; case MG_LAND: return "land"; case MG_SEA: return "sea"; case MG_LATE: return "late";
	}
	return "economy";
}

const char* MarkKindName(int kind)
{
	static const char* names[_MARK_KINDS_] = {
		"metal", "centre", "geo", "tidal",
		"choke", "killzone", "radar", "perch", "forward",
		"yard", "seazone", "strait", "landing", "emergence", "coastfire", "seaplane", "island",
		"lrpc", "antinuke"};
	return (kind >= 0 && kind < _MARK_KINDS_) ? names[kind] : "metal";
}

namespace {

using Clock = std::chrono::steady_clock;

double Ms(Clock::time_point since)
{
	return std::chrono::duration<double, std::milli>(Clock::now() - since).count();
}

template<typename T>
int Count(const std::vector<T>& v) { return static_cast<int>(v.size()); }

// Sites per box for the k-medoids; the lattice step grows on large boxes so
// the swap rounds stay O(rounds * P * kMaxSites * D) whatever the map size.
constexpr int kMaxSites = 600;

std::string Fmt(const char* format, double a = 0, double b = 0, double c = 0)
{
	char buf[160];
	std::snprintf(buf, sizeof(buf), format, a, b, c);
	return buf;
}

float Dist(const SPoint& a, const SPoint& b) { return std::hypot(a.x - b.x, a.z - b.z); }

class Marks final {
public:
	Marks(const SInput& in, const SSettings& st, const SFieldView& v, const std::atomic<bool>* cancel, SModel& m)
		: in(in), ms(st.marks), st(st), v(v), g(v.g), cell(v.cell), cancel(cancel), m(m) {}

	void Run();

private:
	void Check() const {
		if (cancel != nullptr && cancel->load(std::memory_order_relaxed)) throw Cancelled();
	}
	void BuildContact();
	void BuildPositions();
	void BuildTerritory();
	void BuildFeatures();
	void BuildLabels();
	void BuildOpenings();
	void BuildLandmarks();
	void Finish();

	SPoint Centre(int c) const { return {(g.X(c) + 0.5f) * cell, (g.Z(c) + 0.5f) * cell}; }
	int CellAt(float x, float z) const {
		const int cx = std::clamp((int)(x / cell), 0, g.gw - 1);
		const int cz = std::clamp((int)(z / cell), 0, g.gh - 1);
		return g.Index(cx, cz);
	}
	unsigned char BestGround(int c) const {
		unsigned char best = NO_GO;
		for (int k = 0; k < kGroundClasses; ++k) best = std::max(best, v.mob[k][c]);
		return best;
	}
	int Kind(int c) const {
		const int t = v.theatreOf[c];
		return (t >= 0 && t < Count(m.theatres)) ? m.theatres[t].kind : T_LAND;
	}
	bool IsLandRegion(int r) const { return r >= 0 && r < Count(m.regions) && m.theatres[m.regions[r].theatre].kind == T_LAND; }
	int SideAlly(int s) const { return (s >= 0 && s < Count(m.sides)) ? m.sides[s].allyTeam : -1; }
	float Share(int c) const {
		const int s = v.sideOf[c];
		return (s >= 0 && s < Count(maxContact) && maxContact[s] > 0.f) ? contact[c] / maxContact[s] : 1.f;
	}
	bool Contested(int c) const { return contact[c] * cell <= ms.contestDistance; }
	void Dijkstra(const std::vector<int>& seeds, const std::vector<int>& seedLabel, const std::vector<char>* mask,
				  std::vector<float>& dist, std::vector<int>& label) const;
	void AddMark(int group, int kind, const SPoint& pos, float value, int phaseFrom, int phaseTo, std::string reason,
				 Polyline line = Polyline(), int allyOverride = -2, int contestedOverride = -1);
	int RowLabel(const SPosition& p, bool allowSea, bool allowGeo, int& sub) const;
	bool IsFrontLabel(int label) const { return label == L_FRONT || label == L_FRONT_TECH; }

	const SInput& in;
	const SMarkSettings& ms;
	const SSettings& st;
	const SFieldView& v;
	const SGridShape& g;
	const int cell;
	const std::atomic<bool>* cancel;
	SModel& m;

	std::vector<float> contact;         // travel cost (cells) to the nearest cell of another side
	std::vector<float> maxContact;      // per side
	std::vector<std::vector<char>> touches;   // [position][region]
	struct SYard { int cell; float clear; };
	std::vector<std::vector<SYard>> yardCells;   // per theatre: shipyard-capable cells
	std::vector<int> killzones;         // mark ids
	// the input clusters with their income in T1 metal per second (the engine's
	// spot value times metalScale, the T1 extractor's extractsmetal)
	std::vector<SClusterInput> clusters;
	std::vector<SPoint> geos;
};

void Marks::Dijkstra(const std::vector<int>& seeds, const std::vector<int>& seedLabel, const std::vector<char>* mask,
					 std::vector<float>& dist, std::vector<int>& label) const
{
	const int n = g.Size();
	dist.assign(n, 1e30f);
	label.assign(n, -1);
	using Item = std::pair<float, int>;
	std::priority_queue<Item, std::vector<Item>, std::greater<Item>> pq;
	for (int i = 0; i < Count(seeds); ++i) {
		const int c = seeds[i];
		if (c < 0 || c >= n || (mask != nullptr && !(*mask)[c])) continue;
		if (dist[c] > 0.f || seedLabel[i] < label[c]) {
			dist[c] = 0.f; label[c] = seedLabel[i];
			pq.emplace(0.f, c);
		}
	}
	while (!pq.empty()) {
		const auto [d, c] = pq.top();
		pq.pop();
		if (d > dist[c]) continue;
		const int x = g.X(c), z = g.Z(c);
		for (int k = 0; k < 8; ++k) {
			const int nx = x + kDx[k], nz = z + kDz[k];
			if (!g.Inside(nx, nz)) continue;
			const int nc = g.Index(nx, nz);
			if (mask != nullptr && !(*mask)[nc]) continue;
			const unsigned char mb = BestGround(nc);
			const float base = (mb == GO) ? 1.f : (mb == SLOW_GO ? 2.f : 8.f);   // the BuildSides costs
			const float nd = d + base * (k < 4 ? 1.f : 1.41421356f);
			if (nd < dist[nc] || (nd == dist[nc] && label[c] < label[nc])) {
				dist[nc] = nd; label[nc] = label[c];
				pq.emplace(nd, nc);
			}
		}
	}
}

// ---------------------------------------------------------------- contact

void Marks::BuildContact()
{
	const int n = g.Size();
	std::vector<int> seeds, labels;
	for (int c = 0; c < n; ++c) {
		const int x = g.X(c), z = g.Z(c);
		for (int k = 0; k < 4; ++k) {
			const int nx = x + kDx[k], nz = z + kDz[k];
			if (g.Inside(nx, nz) && v.sideOf[g.Index(nx, nz)] != v.sideOf[c]) { seeds.push_back(c); labels.push_back(0); break; }
		}
	}
	std::vector<int> unused;
	if (seeds.empty()) {
		contact.assign(n, 0.f);
	} else {
		Dijkstra(seeds, labels, nullptr, contact, unused);
	}
	maxContact.assign(m.sides.size(), 0.f);
	for (int c = 0; c < n; ++c) {
		const int s = v.sideOf[c];
		if (s >= 0 && s < Count(maxContact) && contact[c] < 1e29f) maxContact[s] = std::max(maxContact[s], contact[c]);
	}
	// shipyard-capable cells per water theatre: deep enough and with open water around
	yardCells.assign(m.theatres.size(), {});
	const int clearThirds = (int)std::lround(3.f * ms.yardClear / cell);
	for (int c = 0; c < n; ++c) {
		const int t = v.theatreOf[c];
		if (t < 0 || m.theatres[t].kind == T_LAND || v.hMean[c] > -ms.yardDepth || v.waterClr[c] < clearThirds) continue;
		yardCells[t].push_back({c, v.waterClr[c] / 3.f * cell});
	}
}

// ---------------------------------------------------------------- positions

void Marks::BuildPositions()
{
	const int sides = Count(m.sides);
	m.positions.clear();
	for (int s = 0; s < sides; ++s) {
		const int ally = SideAlly(s);
		// teams of this side: by ally team, or (synthetic sides, merged enemies)
		// by the side their known start lies in
		std::vector<SPoint> fixed;
		int count = 0;
		for (const STeamInput& t : in.teams) {
			int side = -1;
			if (ally >= 0) {
				for (int o = 0; o < sides; ++o) if (m.sides[o].allyTeam == t.allyTeam) side = o;
			}
			if (side < 0 && t.known) side = v.sideOf[CellAt(t.x, t.z)];
			if (side != s) continue;
			++count;
			if (t.known) fixed.push_back({t.x, t.z});
		}
		if (count == 0) count = 1;   // no team list: one position per side
		// the site lattice inside the box, on ground a commander stands on
		const std::vector<int>& box = v.sideSeeds[s];
		int step = std::max(1, ms.siteStep);
		while ((int)box.size() / (step * step) > kMaxSites) ++step;
		std::vector<SPoint> sites;
		for (int c : box) {
			if (g.X(c) % step != 0 || g.Z(c) % step != 0) continue;
			if (v.hMean[c] < 0.f || BestGround(c) == NO_GO) continue;
			sites.push_back(Centre(c));
		}
		if (sites.empty()) for (int c : box) if (g.X(c) % step == 0 && g.Z(c) % step == 0) sites.push_back(Centre(c));
		if (sites.empty() && !box.empty()) sites.push_back(Centre(box.front()));
		// demand: metal clusters and geos in the side within walkRadius of the box, plus buildable area
		float x0 = 1e30f, x1 = -1e30f, z0 = 1e30f, z1 = -1e30f;
		for (const SPoint& p : m.sides[s].box) { x0 = std::min(x0, p.x); x1 = std::max(x1, p.x); z0 = std::min(z0, p.z); z1 = std::max(z1, p.z); }
		auto nearBox = [&](float x, float z) {
			return x >= x0 - ms.walkRadius && x <= x1 + ms.walkRadius && z >= z0 - ms.walkRadius && z <= z1 + ms.walkRadius
				&& v.sideOf[CellAt(x, z)] == s;
		};
		struct SDemand { SPoint p; float w; };
		std::vector<SDemand> demand;
		for (const SClusterInput& cl : clusters) if (nearBox(cl.x, cl.z)) demand.push_back({{cl.x, cl.z}, std::max(0.1f, cl.income)});
		for (const SPoint& geo : geos) if (nearBox(geo.x, geo.z)) demand.push_back({geo, ms.geoWeight});
		for (const SPoint& p : sites) demand.push_back({p, ms.areaWeight});
		const int want = std::max(count, Count(fixed));
		std::vector<SPoint> chosen = fixed;
		std::vector<char> isFixed(chosen.size(), 1);
		const int D = Count(demand);
		std::vector<float> best(D, 1e30f), second(D, 1e30f);
		std::vector<int> owner(D, -1);
		auto refresh = [&]() {
			for (int d = 0; d < D; ++d) {
				best[d] = second[d] = 1e30f; owner[d] = -1;
				for (int j = 0; j < Count(chosen); ++j) {
					const float dd = Dist(demand[d].p, chosen[j]);
					if (dd < best[d]) { second[d] = best[d]; best[d] = dd; owner[d] = j; }
					else if (dd < second[d]) second[d] = dd;
				}
			}
		};
		// minSpacing first; when the greedy picks leave no spaced site (a small box,
		// many teams) the spacing shrinks by a quarter until every team has a place
		float spacing = ms.minSpacing;
		auto spaced = [&](const SPoint& p, int except) {
			for (int j = 0; j < Count(chosen); ++j) if (j != except && Dist(p, chosen[j]) < spacing) return false;
			return true;
		};
		refresh();
		// greedy: add the site that leaves the smallest weighted distance (the
		// first pick is the side's 1-medoid, the dense middle of its value)
		while (Count(chosen) < want && !sites.empty()) {
			int pick = -1;
			double pickCost = 1e30;
			for (int i = 0; i < Count(sites); ++i) {
				if (!spaced(sites[i], -1)) continue;
				double cost = 0.0;
				for (int d = 0; d < D; ++d) cost += demand[d].w * std::min(best[d], Dist(demand[d].p, sites[i]));
				if (cost < pickCost) { pickCost = cost; pick = i; }
			}
			if (pick < 0) {
				if (spacing < cell) break;   // the box has fewer sites than teams
				spacing *= 0.75f;
				continue;
			}
			chosen.push_back(sites[pick]); isFixed.push_back(0);
			refresh();
		}
		// swap rounds over the predicted medoids only
		for (int round = 0; round < ms.kmedoidsRounds; ++round) {
			bool changed = false;
			for (int j = 0; j < Count(chosen); ++j) {
				if (isFixed[j]) continue;
				double baseCost = 0.0;
				for (int d = 0; d < D; ++d) baseCost += demand[d].w * best[d];
				int pick = -1;
				double pickCost = baseCost - 1e-3;
				for (int i = 0; i < Count(sites); ++i) {
					if (!spaced(sites[i], j)) continue;
					double cost = 0.0;
					for (int d = 0; d < D; ++d) {
						const float other = owner[d] == j ? second[d] : best[d];
						cost += demand[d].w * std::min(other, Dist(demand[d].p, sites[i]));
					}
					if (cost < pickCost) { pickCost = cost; pick = i; }
				}
				if (pick >= 0) { chosen[j] = sites[pick]; changed = true; refresh(); }
			}
			if (!changed) break;
			Check();
		}
		for (int j = 0; j < Count(chosen); ++j) {
			SPosition p;
			p.side = s; p.allyTeam = ally; p.pos = chosen[j]; p.predicted = !isFixed[j];
			p.cell = CellAt(p.pos.x, p.pos.z);
			m.positions.push_back(p);
		}
		Check();
	}
	// number each side's positions from the rear (largest cost to the contact line)
	std::vector<int> order(m.positions.size());
	std::iota(order.begin(), order.end(), 0);
	std::sort(order.begin(), order.end(), [&](int a, int b) {
		const SPosition& pa = m.positions[a];
		const SPosition& pb = m.positions[b];
		if (pa.side != pb.side) return pa.side < pb.side;
		if (contact[pa.cell] != contact[pb.cell]) return contact[pa.cell] > contact[pb.cell];
		if (pa.pos.x != pb.pos.x) return pa.pos.x < pb.pos.x;
		return pa.pos.z < pb.pos.z;
	});
	std::vector<SPosition> sorted;
	int side = -1, n = 0;
	for (int i : order) {
		SPosition p = m.positions[i];
		if (p.side != side) { side = p.side; n = 0; }
		p.n = ++n; p.rearRank = n - 1;
		p.index = Count(sorted);
		p.frontShare = Share(p.cell);
		p.name = (p.allyTeam >= 0 ? "P" + std::to_string(p.allyTeam) : "S" + std::to_string(p.side)) + "." + std::to_string(p.n);
		sorted.push_back(std::move(p));
	}
	m.positions.swap(sorted);
}

// ---------------------------------------------------------------- territory

void Marks::BuildTerritory()
{
	const int n = g.Size();
	m.posOf.assign(n, -1);
	for (int s = 0; s < Count(m.sides); ++s) {
		std::vector<char> mask(n, 0);
		for (int c = 0; c < n; ++c) mask[c] = v.sideOf[c] == s ? 1 : 0;
		std::vector<int> seeds, labels;
		for (const SPosition& p : m.positions) if (p.side == s) { seeds.push_back(p.cell); labels.push_back(p.index); }
		if (seeds.empty()) continue;
		std::vector<float> dist;
		std::vector<int> label;
		Dijkstra(seeds, labels, &mask, dist, label);
		for (int c = 0; c < n; ++c) if (mask[c] && label[c] >= 0) m.posOf[c] = label[c];
		Check();
	}
}

// ---------------------------------------------------------------- features

void Marks::BuildFeatures()
{
	const int n = g.Size();
	const int P = Count(m.positions), R = Count(m.regions);
	touches.assign(P, std::vector<char>(R, 0));
	std::vector<int> groundCount(P * 8, 0);
	for (int c = 0; c < n; ++c) {
		const int p = m.posOf[c];
		if (p < 0) continue;
		SFeatures& f = m.positions[p].f;
		++f.cells;
		const int gnd = std::min<int>(m.groundOf[c], G_HARM);
		++groundCount[p * 8 + (gnd == G_HARM ? G_WATER : gnd)];
		if (gnd == G_FLAT) f.landArea += (float)cell * cell;
		if (Kind(c) == T_POND) ++f.pondCells;
		const int r = v.regionOf[c];
		if (r >= 0 && r < R) touches[p][r] = 1;
	}
	for (int p = 0; p < P; ++p) {
		SFeatures& f = m.positions[p].f;
		for (int k = 0; k < 8; ++k) f.ground[k] = f.cells > 0 ? (float)groundCount[p * 8 + k] / f.cells : 0.f;
	}
	for (const SClusterInput& cl : clusters) {
		const int p = m.posOf[CellAt(cl.x, cl.z)];
		if (p >= 0) { m.positions[p].f.metal += cl.income; ++m.positions[p].f.clusters; }
	}
	for (int i = 0; i < Count(geos); ++i) {
		const SPoint& geo = geos[i];
		const int c = CellAt(geo.x, geo.z);
		const int p = m.posOf[c];
		if (p >= 0) ++m.positions[p].f.geos;
		for (SPosition& pos : m.positions) {
			if (v.sideOf[c] != pos.side) continue;
			const float d = Dist(pos.pos, geo);
			if (pos.f.geoDist < 0.f || d < pos.f.geoDist) { pos.f.geoDist = d; pos.f.geoNear = i; }
		}
	}
	// Seas: the sea a position holds is the contested sea (T_SEA) with the most
	// cells in its territory, when they are at least seaShareMin of it (the sea
	// player starts beside the water it owns, not always at the shore: Supreme
	// Isthmus's west sea player is 2,800 from it). Failing that, a shipyard site
	// within seaYardReach still makes the position a sea candidate. The yard is
	// the nearest shipyard-capable cell of that sea on the own side. O(G + P*Y).
	std::vector<std::vector<int>> seaCells(m.positions.size(), std::vector<int>(m.theatres.size(), 0));
	for (int c = 0; c < n; ++c) {
		const int p = m.posOf[c];
		const int t = v.theatreOf[c];
		if (p >= 0 && t >= 0 && m.theatres[t].kind == T_SEA) ++seaCells[p][t];
	}
	for (SPosition& pos : m.positions) {
		SFeatures& f = pos.f;
		int held = -1;
		for (const STheatre& t : m.theatres) {
			if (t.kind != T_SEA) continue;
			if (held < 0 || seaCells[pos.index][t.id] > seaCells[pos.index][held]) held = t.id;
		}
		if (held >= 0 && f.cells > 0 && seaCells[pos.index][held] >= ms.seaShareMin * f.cells) {
			f.sea = held;
			f.seaCells = seaCells[pos.index][held];
		}
		for (const STheatre& t : m.theatres) {
			if (t.kind != T_SEA || (f.sea >= 0 && t.id != f.sea)) continue;
			for (const SYard& y : yardCells[t.id]) {
				if (v.sideOf[y.cell] != pos.side) continue;
				const float d = Dist(pos.pos, Centre(y.cell));
				if ((f.sea >= 0 || d <= ms.seaYardReach) && (f.yardDist < 0.f || d < f.yardDist)) { f.yardDist = d; f.yard = Centre(y.cell); if (f.sea < 0) f.sea = t.id; }
			}
		}
		if (f.sea >= 0 && f.seaCells == 0) f.seaCells = seaCells[pos.index][f.sea];
		// an island: no other side's box shares this land theatre
		const int theatre = v.theatreOf[pos.cell];
		if (theatre >= 0 && m.theatres[theatre].kind == T_LAND) {
			bool shared = false;
			for (int s = 0; s < Count(v.sideSeeds) && !shared; ++s) {
				if (s == pos.side) continue;
				for (int c : v.sideSeeds[s]) if (v.theatreOf[c] == theatre) { shared = true; break; }
			}
			f.island = !shared && Count(m.sides) >= 2;
		}
	}
	for (const SLanding& ld : m.landings) {
		if (ld.rank <= 0 || ld.sea < 0 || m.theatres[ld.sea].kind != T_SEA) continue;
		const int p = m.posOf[CellAt(ld.mid.x, ld.mid.z)];
		if (p < 0) continue;
		int& best = m.positions[p].f.assaultRank;
		if (best == 0 || ld.rank < best) best = ld.rank;
	}
	// the ground the position's front avenues cross on its own side
	for (SPosition& pos : m.positions) {
		SFeatures& f = pos.f;
		std::set<int> front;
		for (const SAvenue& av : m.avenues) {
			bool enters = false;
			for (int r : av.regions) if (r >= 0 && r < R && touches[pos.index][r]) { enters = true; break; }
			if (!enters) continue;
			if (av.cls == C_HOVER) f.hoverAvenue = true;
			if (av.specialist) continue;
			f.landAvenue = true;
			for (int r : av.regions) {
				const SRegion& reg = m.regions[r];
				if (IsLandRegion(r) && reg.labelCell >= 0 && v.sideOf[reg.labelCell] == pos.side) front.insert(r);
			}
		}
		if (front.empty()) for (int r = 0; r < R; ++r) if (touches[pos.index][r] && IsLandRegion(r)) front.insert(r);
		double cells = 0.0, veh = 0.0, width = 0.0;
		for (int r : front) {
			const SRegion& reg = m.regions[r];
			// lowWidth (the region's 25th-percentile clearance): a front fights in the narrow parts
			cells += reg.cells; veh += reg.cells * reg.vehFraction; width += reg.cells * reg.lowWidth;
		}
		f.vehShare = cells > 0.0 ? (float)(veh / cells) : 0.f;
		f.openWidth = cells > 0.0 ? (float)(width / cells) : 0.f;
	}
}

// ---------------------------------------------------------------- labels

int Marks::RowLabel(const SPosition& p, bool allowSea, bool allowGeo, int& sub) const
{
	const SFeatures& f = p.f;
	sub = S_NONE;
	const bool geo = allowGeo && f.geoDist >= 0.f && f.geoDist <= ms.geoReach;
	if (allowSea && f.sea >= 0) {
		if (geo) sub = S_GEO_SEA;
		else if (f.assaultRank >= 1 && f.assaultRank <= 2) sub = S_BEACH_SEA;
		return L_SEA;
	}
	if (f.island && f.landArea < ms.islandBaseArea) return L_ISLAND;
	if (f.pondCells >= ms.pondMinCells) return L_POND;
	if (geo && p.frontShare >= ms.geoShareMin) return L_GEO;
	return L_FRONT;
}

// Row labels first (sea, island, pond, geo, plain), then a pass per side that
// enforces the meta's counts: one sea position per contested sea, one geo
// position per vent (the nearest keeps it), one air and at most one tech taken
// from the rear part of the plain positions, the rest fronts; the richest
// front can be front/tech and the nearest of three or more fronts is the
// suicide front. O(P log P) per side.
void Marks::BuildLabels()
{
	const int P = Count(m.positions);
	std::vector<char> allowSea(P, 1), allowGeo(P, 1);
	for (int s = 0; s < Count(m.sides); ++s) {
		std::vector<int> mine;
		for (const SPosition& p : m.positions) if (p.side == s) mine.push_back(p.index);
		auto relabel = [&]() {   // this side only: the other sides keep their passes
			for (int i : mine) {
				SPosition& p = m.positions[i];
				int sub;
				p.label = RowLabel(p, allowSea[i], allowGeo[i], sub);
				p.sub = sub;
			}
		};
		relabel();
		// seas: the nearest yard keeps the sea; then vents: the nearest position keeps the
		// geo or geo-sea word (repeat until stable, since a dropped sea can become geo)
		for (int pass = 0; pass < 4; ++pass) {
			bool changed = false;
			std::map<int, std::vector<int>> bySea, byGeo;
			for (int i : mine) {
				const SPosition& p = m.positions[i];
				// a territory that is nearly all water is a sea seat of its own (Glacial
				// Gap's and Pinch Point's water starts); the others share seaPerSea
				if (p.label == L_SEA && p.f.seaCells < ms.seaFullShare * p.f.cells) bySea[p.f.sea].push_back(i);
				if (p.label == L_GEO || p.sub == S_GEO_SEA) byGeo[p.f.geoNear].push_back(i);
			}
			auto keepNearest = [&](std::map<int, std::vector<int>>& groups, int keep, auto distOf, std::vector<char>& allow) {
				for (auto& kv : groups) {
					std::vector<int>& list = kv.second;
					std::sort(list.begin(), list.end(), [&](int a, int b) { return distOf(a) != distOf(b) ? distOf(a) < distOf(b) : a < b; });
					for (int k = std::max(0, keep); k < Count(list); ++k) { allow[list[k]] = 0; changed = true; }
				}
			};
			// the position holding the most of the sea keeps it (negated: smallest first)
			keepNearest(bySea, ms.seaPerSea, [&](int i) { return -(float)m.positions[i].f.seaCells; }, allowSea);
			keepNearest(byGeo, 1, [&](int i) { return m.positions[i].f.geoDist; }, allowGeo);
			if (!changed) break;
			relabel();
		}
		auto metalOf = [&](int i) { return m.positions[i].f.metal; };
		const int count = Count(mine);
		// the plain positions, rear first; air and tech come from the rear part
		std::vector<int> plain;
		for (int i : mine) if (m.positions[i].label == L_FRONT) plain.push_back(i);
		std::sort(plain.begin(), plain.end(), [&](int a, int b) {
			const SPosition& pa = m.positions[a];
			const SPosition& pb = m.positions[b];
			if (pa.frontShare != pb.frontShare) return pa.frontShare > pb.frontShare;
			return a < b;
		});
		std::vector<int> rear(plain.begin(), plain.begin() + std::min<int>(Count(plain), (int)std::ceil(ms.rearFraction * Count(plain))));
		// Tech first: the eco player takes the rear position with the most metal
		// plus room to build (flat Mm2 at techAreaWeight metal each; Supreme
		// Isthmus's two rear corners tie on metal and differ in flat ground).
		// Then air: the rearmost of the rest, less metal on a tie; with no plain
		// position left the air player takes the rearmost geo or pond.
		auto techValue = [&](int i) { return metalOf(i) + ms.techAreaWeight * m.positions[i].f.landArea / 1e6f; };
		if (count >= ms.techMinPositions && ms.techPerSide > 0) {
			std::vector<int> pool = rear;
			std::sort(pool.begin(), pool.end(), [&](int a, int b) { return techValue(a) != techValue(b) ? techValue(a) > techValue(b) : a < b; });
			for (int k = 0; k < std::min(ms.techPerSide, Count(pool)); ++k) {
				m.positions[pool[k]].label = L_TECH;
				rear.erase(std::remove(rear.begin(), rear.end(), pool[k]), rear.end());
			}
		}
		if (count >= ms.airMinPositions && ms.airPerSide > 0) {
			std::vector<int> pool = rear;
			if (pool.empty()) {
				for (int i : mine) if (m.positions[i].label == L_GEO || m.positions[i].label == L_POND) pool.push_back(i);
			}
			std::sort(pool.begin(), pool.end(), [&](int a, int b) {
				const SPosition& pa = m.positions[a];
				const SPosition& pb = m.positions[b];
				if (pa.frontShare != pb.frontShare) return pa.frontShare > pb.frontShare;
				if (metalOf(a) != metalOf(b)) return metalOf(a) < metalOf(b);
				return a < b;
			});
			for (int k = 0; k < std::min(ms.airPerSide, Count(pool)); ++k) {
				m.positions[pool[k]].label = L_AIR;
				m.positions[pool[k]].sub = S_NONE;
			}
		}
		std::vector<int> fronts;
		for (int i : mine) if (m.positions[i].label == L_FRONT) fronts.push_back(i);
		if (count >= ms.techMinPositions) {
			int rich = -1;
			for (int i : fronts) if (metalOf(i) > ms.frontTechMetal && (rich < 0 || metalOf(i) > metalOf(rich))) rich = i;
			if (rich >= 0) m.positions[rich].label = L_FRONT_TECH;
		}
		if (Count(fronts) >= 3) {
			int nearest = -1;
			for (int i : fronts) {
				if (m.positions[i].label != L_FRONT) continue;
				if (nearest < 0 || m.positions[i].frontShare < m.positions[nearest].frontShare) nearest = i;
			}
			if (nearest >= 0) m.positions[nearest].sub = S_SUICIDE_FRONT;
		}
	}
}

// ---------------------------------------------------------------- openings

void Marks::BuildOpenings()
{
	const float avgWind = 0.5f * (in.minWind + in.maxWind);
	const float diag = std::hypot((float)in.mapWidth, (float)in.mapHeight);
	for (SPosition& p : m.positions) {
		const SFeatures& f = p.f;
		const float wet = f.ground[G_DEEP] + f.ground[G_WATER] + f.ground[G_SHALLOW];
		std::vector<std::string>& why = p.reasons;
		why.clear();
		p.fallbacks.clear();
		switch (p.label) {
			case L_SEA:
				p.opening = f.yardDist >= 0.f ? O_SHIP : O_HOVER;
				p.fallbacks = {O_HOVER, O_BOT};
				if (f.sea >= 0) why.push_back("contested sea " + m.theatres[f.sea].name);
				if (f.yardDist >= 0.f) why.push_back(Fmt("yard site %.0f deep, %.0f clear, %.0f away", ms.yardDepth, ms.yardClear, f.yardDist));
				if (p.sub == S_GEO_SEA) why.push_back(Fmt("geo vent %.0f away", f.geoDist));
				else if (f.assaultRank > 0) why.push_back(Fmt("landing rank %.0f in the territory", f.assaultRank));
				break;
			case L_ISLAND:
				p.opening = O_HOVER;
				p.fallbacks = {O_SHIP, O_AIR};
				why.push_back("island: no land route to the enemy");
				why.push_back(Fmt("%.2f Mm2 flat ground", f.landArea / 1e6));
				break;
			case L_POND:
				p.opening = O_VEH;
				p.fallbacks = {O_HOVER, O_BOT};
				why.push_back(Fmt("pond of %.0f cells in the territory", f.pondCells));
				why.push_back("vehicle plant: its amphibious constructor builds tidals");
				break;
			case L_GEO:
				p.opening = O_BOT;
				p.fallbacks = {O_VEH};
				why.push_back(Fmt("geo vent %.0f away, %.0f%% back from the front", f.geoDist, 100.0 * p.frontShare));
				why.push_back("throwaway lab, then T2 off the vent");
				break;
			case L_TECH: case L_FRONT_TECH:
				p.opening = O_BOT;
				p.fallbacks = {O_VEH};
				why.push_back(Fmt("%.1f metal income in %.0f clusters", f.metal, f.clusters));
				if (p.label == L_TECH) why.push_back(Fmt("rear: %.0f%% back from the front", 100.0 * p.frontShare));
				break;
			case L_AIR:
				p.opening = O_AIR;
				p.fallbacks = {O_BOT};
				why.push_back(Fmt("farthest back: %.0f%% from the front", 100.0 * p.frontShare));
				why.push_back(Fmt("%.1f metal income in its territory: the eco player wants the spots", f.metal));
				break;
			default: {
				const bool open = f.vehShare >= ms.vehShare && f.openWidth >= ms.openWidth && diag >= ms.vehMapScale;
				if (open) { p.opening = O_VEH; p.fallbacks = {O_BOT}; }
				else if (f.hoverAvenue && !f.landAvenue) { p.opening = O_HOVER; p.fallbacks = {O_BOT}; }
				else { p.opening = O_BOT; p.fallbacks = {O_VEH}; }
				if (wet > 0.2f && p.opening != O_HOVER) p.fallbacks.push_back(O_HOVER);
				why.push_back(Fmt("front ground: %.0f%% vehicle ground, %.0f open width", 100.0 * f.vehShare, f.openWidth));
				if (!open) {
					if (f.vehShare < ms.vehShare) why.push_back(Fmt("below the %.0f%% vehicle share", 100.0 * ms.vehShare));
					else if (f.openWidth < ms.openWidth) why.push_back(Fmt("narrower than %.0f", ms.openWidth));
					else why.push_back(Fmt("map diagonal %.0f below %.0f", diag, ms.vehMapScale));
				}
				why.push_back(Fmt("%.0f%% back from the front", 100.0 * p.frontShare));
				break;
			}
		}
		const bool waterish = p.label == L_SEA || p.label == L_POND || p.label == L_ISLAND || wet > 0.1f;
		if (waterish && in.tidal > avgWind + ms.tidalMargin) p.energy = E_TIDAL;
		else if (avgWind >= ms.windMin) p.energy = E_WIND;
		else if (waterish && in.tidal >= ms.windMin) p.energy = E_TIDAL;
		else p.energy = E_SOLAR;
		if (why.size() > 3) why.resize(3);
	}
}

// ---------------------------------------------------------------- landmarks

void Marks::AddMark(int group, int kind, const SPoint& pos, float value, int phaseFrom, int phaseTo, std::string reason,
					Polyline line, int allyOverride, int contestedOverride)
{
	SMark mk;
	mk.id = Count(m.marks); mk.group = group; mk.kind = kind; mk.pos = pos; mk.value = value;
	const int c = CellAt(pos.x, pos.z);
	mk.position = m.posOf.empty() ? -1 : m.posOf[c];
	mk.allyTeam = allyOverride != -2 ? allyOverride : SideAlly(v.sideOf[c]);
	mk.contested = contestedOverride >= 0 ? contestedOverride != 0 : Contested(c);
	mk.phaseFrom = phaseFrom; mk.phaseTo = phaseTo;
	for (char& ch : reason) if (ch == '|' || ch == '\n' || ch == '\r') ch = ' ';
	mk.reason = std::move(reason);
	mk.line = std::move(line);
	m.marks.push_back(std::move(mk));
}

void Marks::BuildLandmarks()
{
	const int n = g.Size();
	const int sides = Count(m.sides);
	const float avgWind = 0.5f * (in.minWind + in.maxWind);
	// economy: metal clusters, the centre cluster, geo vents, tidal fields
	int centre = -1;
	if (sides >= 2) {
		float bestRatio = 0.15f;
		for (int i = 0; i < Count(clusters); ++i) {
			const int c = CellAt(clusters[i].x, clusters[i].z);
			const float a = v.boxDist[0][c], b = v.boxDist[1][c];
			if (a + b <= 0.f || a > 1e29f || b > 1e29f) continue;
			const float ratio = std::fabs(a - b) / (a + b);
			if (ratio < bestRatio || (ratio == bestRatio && centre >= 0 && clusters[i].income > clusters[centre].income)) { bestRatio = ratio; centre = i; }
		}
	}
	for (int i = 0; i < Count(clusters); ++i) {
		const SClusterInput& cl = clusters[i];
		if (i == centre) AddMark(MG_ECONOMY, MK_CENTRE, {cl.x, cl.z}, cl.income, 5, 15, Fmt("centre cluster, %.1f metal, equidistant from both sides", cl.income), {}, -1, 1);
		else AddMark(MG_ECONOMY, MK_METAL, {cl.x, cl.z}, cl.income, 0, 15, Fmt("metal cluster, %.1f income", cl.income));
	}
	for (const SPoint& geo : geos) AddMark(MG_ECONOMY, MK_GEO, geo, 1.f, 0, 25, "geothermal vent: 300 E/s, forward-base anchor");
	for (const STheatre& t : m.theatres) {
		if (t.kind != T_POND || in.tidal <= 0.f) continue;
		AddMark(MG_ECONOMY, MK_TIDAL, t.centre, t.cells * in.tidal, 0, 15,
			Fmt("tidal field: tidal %.0f against %.1f average wind, %.0f cells", in.tidal, avgWind, t.cells));
	}
	Check();
	// land control: chokes and kill zones on ground avenues, radar hills, perches, forward bases
	std::map<std::pair<int, int>, int> avenueThrough;
	for (const SAvenue& av : m.avenues) {
		if (av.specialist) continue;
		for (int i = 0; i + 1 < Count(av.regions); ++i) {
			const int a = std::min(av.regions[i], av.regions[i + 1]), b = std::max(av.regions[i], av.regions[i + 1]);
			++avenueThrough[{a, b}];
		}
	}
	killzones.clear();
	for (const SChoke& ch : m.chokes) {
		if (!IsLandRegion(ch.a) || !IsLandRegion(ch.b)) continue;
		const auto it = avenueThrough.find({std::min(ch.a, ch.b), std::max(ch.a, ch.b)});
		if (it == avenueThrough.end()) continue;
		const int side = v.sideOf[ch.cell];
		float nearest = -1.f;
		for (const SPosition& p : m.positions) {
			if (p.side != side || !(IsFrontLabel(p.label))) continue;
			const float d = Dist(p.pos, ch.pos);
			if (nearest < 0.f || d < nearest) nearest = d;
		}
		if (nearest >= 0.f && nearest <= ms.killReach) {
			killzones.push_back(Count(m.marks));
			AddMark(MG_LAND, MK_KILL, ch.pos, (float)it->second, 5, 25,
				Fmt("kill zone: choke %.0f wide on %.0f avenue(s), %.0f from a front", ch.width, it->second, nearest));
		} else {
			AddMark(MG_LAND, MK_CHOKE, ch.pos, (float)it->second, 5, 25, Fmt("choke %.0f wide on %.0f avenue(s)", ch.width, it->second));
		}
	}
	for (const SRegion& reg : m.regions) {
		if (reg.character != R_PLATEAU || reg.labelCell < 0) continue;
		const float rise = (reg.id < Count(v.regionRise)) ? v.regionRise[reg.id] : 0.f;
		const int side = v.sideOf[reg.labelCell];
		if (Share(reg.labelCell) <= ms.radarFrontShare) {
			AddMark(MG_LAND, MK_RADAR, reg.label, rise, 5, 15, Fmt("radar hill: %.0f above its neighbours, front half of the side", rise));
		}
		float over = -1.f;
		for (int id : killzones) {
			const SMark& k = m.marks[id];
			if (v.sideOf[CellAt(k.pos.x, k.pos.z)] != side) continue;
			const float d = Dist(k.pos, reg.label);
			if (d <= ms.perchRange && (over < 0.f || d < over)) over = d;
		}
		for (const SLanding& ld : m.landings) {
			if (ld.side != side || ld.rank < 1 || ld.rank > 3) continue;
			const float d = Dist(ld.mid, reg.label);
			if (d <= ms.perchRange && (over < 0.f || d < over)) over = d;
		}
		if (over >= 0.f) AddMark(MG_LAND, MK_PERCH, reg.label, rise, 10, 25, Fmt("artillery perch: %.0f high, %.0f from a kill zone or landing", rise, over));
	}
	for (const SClusterInput& cl : clusters) {
		const int c = CellAt(cl.x, cl.z);
		const float share = Share(c);
		if (cl.income < ms.forwardIncome || share <= 0.15f || share > ms.forwardShareMax) continue;
		AddMark(MG_LAND, MK_FORWARD, {cl.x, cl.z}, cl.income, 15, 25, Fmt("forward-base site: %.1f metal, %.0f%% back from the front", cl.income, 100.0 * share));
	}
	Check();
	// sea control: yard sites, sea control zones, straits, landings, emergence bands, coast fire, seaplane ponds
	std::vector<SPoint> yards;
	for (const SPosition& p : m.positions) {
		if (p.f.yardDist < 0.f || p.label != L_SEA) continue;
		bool dup = false;
		for (const SPoint& y : yards) if (Dist(y, p.f.yard) < 300.f) dup = true;
		if (dup) continue;
		yards.push_back(p.f.yard);
		const float clear = v.waterClr[CellAt(p.f.yard.x, p.f.yard.z)] / 3.f * cell;   // open water around the site
		AddMark(MG_SEA, MK_YARD, p.f.yard, clear, 0, 5, "shipyard site for " + p.name + Fmt(": %.0f deep, %.0f open water around, %.0f from the start", ms.yardDepth, clear, p.f.yardDist));
	}
	if (sides >= 2) {
		for (const STheatre& t : m.theatres) {
			if (t.kind != T_SEA) continue;
			int pick = -1;
			float bestGap = 1e30f;
			for (int r : t.regions) {
				const SRegion& reg = m.regions[r];
				if (reg.labelCell < 0 || reg.deepFraction < 0.3f) continue;
				const float a = v.boxDist[0][reg.labelCell], b = v.boxDist[1][reg.labelCell];
				if (a > 1e29f || b > 1e29f) continue;
				const float gap = std::fabs(a - b);
				if (gap < bestGap) { bestGap = gap; pick = r; }
			}
			if (pick < 0) continue;
			const SRegion& reg = m.regions[pick];
			AddMark(MG_SEA, MK_SEAZONE, reg.label, (float)t.cells, 5, 25, "sea control zone of " + t.name + ": deep water halfway between the holders",
				reg.outline.empty() ? Polyline() : reg.outline.front(), -1, 1);
		}
	}
	for (const SRegion& reg : m.regions) {
		if (reg.character != R_STRAIT) continue;
		AddMark(MG_SEA, MK_STRAIT, reg.label, reg.medianWidth, 5, 25, Fmt("strait %.0f wide", reg.medianWidth));
	}
	for (const SChoke& ch : m.chokes) {
		if (IsLandRegion(ch.a) || IsLandRegion(ch.b) || ch.a < 0 || ch.b < 0) continue;
		AddMark(MG_SEA, MK_STRAIT, ch.pos, ch.width, 5, 25, Fmt("narrows between waters, %.0f wide", ch.width));
	}
	std::vector<int> targetLandings;
	for (const SLanding& ld : m.landings) {
		if (ld.rank < 1 || ld.rank > 3 || ld.sea < 0 || m.theatres[ld.sea].kind != T_SEA) continue;
		const int ally = SideAlly(ld.side);
		std::string classes;
		const char* names[kGroundClasses] = {"vehicle", "bot", "amphibious", "hover", "all-terrain"};
		for (int k = 0; k < kGroundClasses; ++k) if (ld.classMask & (1 << k)) { if (!classes.empty()) classes += ", "; classes += names[k]; }
		AddMark(MG_SEA, MK_LANDING, ld.mid, (float)ld.rank, 10, 25,
			Fmt("landing rank %.0f into ally %.0f, %.0f inland; ", ld.rank, ally, ld.inland) + classes, ld.line, ally);
		if (ld.rank <= 2) targetLandings.push_back(ld.id);
		if (ld.rank > 2) continue;
		// the emergence band: the nearest wadeable water off the landing
		const int mc = CellAt(ld.mid.x, ld.mid.z);
		int bestCell = -1;
		float bestD = 1e30f;
		for (int dz = -8; dz <= 8; ++dz) for (int dx = -8; dx <= 8; ++dx) {
			const int x = g.X(mc) + dx, z = g.Z(mc) + dz;
			if (!g.Inside(x, z)) continue;
			const int c = g.Index(x, z);
			if (v.hMean[c] >= 0.f || v.hMean[c] < -20.f) continue;
			const float d = (float)(dx * dx + dz * dz);
			if (d < bestD) { bestD = d; bestCell = c; }
		}
		if (bestCell >= 0) AddMark(MG_SEA, MK_EMERGE, Centre(bestCell), ld.width, 10, 25, "emergence band: shallows where landers surface", {}, ally);
	}
	// coast-fire stations: standoff vertices at 85% of the artillery ship's range from enemy coast targets
	if (sides >= 2) {
		struct STarget { SPoint p; int side; std::string what; };
		std::vector<STarget> targets;
		for (int id : targetLandings) targets.push_back({m.landings[id].mid, m.landings[id].side, "landing"});
		for (int s = 0; s < sides; ++s) {
			std::vector<std::pair<float, int>> coastal;
			for (int i = 0; i < Count(clusters); ++i) {
				const int c = CellAt(clusters[i].x, clusters[i].z);
				if (v.sideOf[c] != s) continue;
				float nearSea = 1e30f;
				for (const SStandoff& so : m.standoffs) {
					if (so.sea < 0 || so.depth != st.standoffDepths[0] || m.theatres[so.sea].kind != T_SEA) continue;
					for (const SPoint& q : so.line) nearSea = std::min(nearSea, Dist(q, {clusters[i].x, clusters[i].z}));
				}
				if (nearSea <= ms.artilleryShipRange) coastal.push_back({-clusters[i].income, i});
			}
			std::sort(coastal.begin(), coastal.end());
			for (int k = 0; k < std::min(ms.coastTargets, Count(coastal)); ++k) {
				const SClusterInput& cl = clusters[coastal[k].second];
				targets.push_back({{cl.x, cl.z}, s, Fmt("%.1f metal cluster", cl.income)});
			}
		}
		std::vector<SPoint> stations;
		const float R = ms.artilleryShipRange;
		for (const STarget& t : targets) {
			SPoint best{-1.f, -1.f};
			float bestErr = 1e30f;
			for (const SStandoff& so : m.standoffs) {
				if (so.sea < 0 || so.depth != st.standoffDepths[0] || m.theatres[so.sea].kind != T_SEA) continue;
				for (const SPoint& q : so.line) {
					const float d = Dist(q, t.p);
					if (d < 0.6f * R || d > R) continue;
					const float err = std::fabs(d - 0.85f * R);
					if (err < bestErr) { bestErr = err; best = q; }
				}
			}
			if (best.x < 0.f) continue;
			bool dup = false;
			for (const SPoint& q : stations) if (Dist(q, best) < 400.f) dup = true;
			if (dup) continue;
			stations.push_back(best);
			int inRange = 0;
			for (const STarget& o : targets) if (o.side == t.side && Dist(o.p, best) <= R) ++inRange;
			const int attacker = t.side == 0 ? 1 : 0;
			AddMark(MG_SEA, MK_COASTFIRE, best, (float)inRange, 10, 25,
				Fmt("coast-fire station: %.0f target(s) of ally %.0f within %.0f; ", inRange, SideAlly(t.side), R) + t.what, {}, SideAlly(attacker), 0);
		}
	}
	for (const STheatre& t : m.theatres) {
		if (t.kind != T_POND) continue;
		float deepest = 0.f;
		for (int c = 0; c < n; ++c) if (v.theatreOf[c] == t.id) deepest = std::min(deepest, v.hMean[c]);
		if (-deepest >= ms.yardDepth) AddMark(MG_SEA, MK_SEAPLANE, t.centre, (float)t.cells, 5, 15, Fmt("seaplane pond: %.0f deep, out of fleet reach", -deepest));
	}
	// islands, classed by the largest flat square they hold (96 / 144 / 192 elmos)
	{
		std::vector<char> flat(n, 0);
		for (int c = 0; c < n; ++c) flat[c] = m.groundOf[c] == G_FLAT ? 1 : 0;
		std::vector<int> clr;
		ChamferDistance(g, flat, clr);
		std::vector<float> square(m.theatres.size(), 0.f);
		for (int c = 0; c < n; ++c) {
			const int t = v.theatreOf[c];
			if (t < 0 || !flat[c]) continue;
			square[t] = std::max(square[t], 2.f * (clr[c] / 3.f) * cell / 1.41421356f);
		}
		for (const SKey& k : m.keys) {
			if (k.kind != K_ISLAND) continue;
			const int c = CellAt(k.pos.x, k.pos.z);
			const int t = v.theatreOf[c];
			const bool theatre = t >= 0 && m.theatres[t].kind == T_LAND && !m.theatres[t].hasBox && Dist(m.theatres[t].centre, k.pos) < 1.f;
			const float side = theatre ? square[t] : 0.f;
			const float area = k.value * cell * cell;
			const char* cls = side < 96.f ? "rock" : (side < 144.f ? "outpost" : (side < 192.f || area < ms.islandBaseArea ? "forward base" : "island base"));
			float metal = 0.f;
			if (theatre) for (const SClusterInput& cl : clusters) if (v.theatreOf[CellAt(cl.x, cl.z)] == t) metal += cl.income;
			AddMark(MG_SEA, MK_ISLAND, k.pos, metal, 5, 25, std::string("island (") + cls + Fmt("): largest flat square %.0f, %.1f metal", side, metal));
		}
	}
	Check();
	// late game: LRPC perches 20-40% of the range behind the contact line on the highest ground; anti-nuke districts
	for (int s = 0; s < sides; ++s) {
		std::vector<std::pair<float, int>> cand;
		for (int c = 0; c < n; ++c) {
			if (v.sideOf[c] != s || v.hMean[c] < 0.f) continue;
			if (m.groundOf[c] != G_FLAT && m.groundOf[c] != G_ROUGH) continue;
			const float behind = contact[c] * cell;
			if (behind < 0.2f * ms.lrpcRange || behind > 0.4f * ms.lrpcRange) continue;
			cand.push_back({-v.hMean[c], c});
		}
		std::sort(cand.begin(), cand.end());
		std::vector<SPoint> picked;
		for (const auto& kv : cand) {
			if (Count(picked) >= ms.lrpcPerSide) break;
			const SPoint p = Centre(kv.second);
			bool near = false;
			for (const SPoint& q : picked) if (Dist(p, q) < ms.lrpcRange / 3.f) near = true;
			if (near) continue;
			picked.push_back(p);
			AddMark(MG_LATE, MK_LRPC, p, -kv.first, 25, -1, Fmt("LRPC perch: %.0f high, %.0f behind the front", -kv.first, contact[kv.second] * cell));
		}
		// anti-nuke: the sites whose coverage holds the most position and economy value
		std::vector<std::pair<SPoint, float>> value;
		for (const SPosition& p : m.positions) if (p.side == s) value.push_back({p.pos, 1.f + p.f.metal});
		for (const SMark& mk : m.marks) {
			// metal-income units: a cluster its income, a geo vent or a tidal field a fixed weight
			if (mk.group != MG_ECONOMY || v.sideOf[CellAt(mk.pos.x, mk.pos.z)] != s) continue;
			value.push_back({mk.pos, (mk.kind == MK_METAL || mk.kind == MK_CENTRE) ? mk.value : ms.geoWeight});
		}
		std::vector<SPoint> sites;
		for (int k = 0; k < ms.antinukePerSide; ++k) {
			int pick = -1;
			float pickValue = 0.f;
			for (int i = 0; i < Count(m.positions); ++i) {
				const SPosition& p = m.positions[i];
				if (p.side != s) continue;
				bool near = false;
				for (const SPoint& q : sites) if (Dist(q, p.pos) < ms.antinukeCoverage) near = true;
				if (near) continue;
				float covered = 0.f;
				for (const auto& kv : value) if (Dist(kv.first, p.pos) <= ms.antinukeCoverage) covered += kv.second;
				if (covered > pickValue) { pickValue = covered; pick = i; }
			}
			if (pick < 0) break;
			sites.push_back(m.positions[pick].pos);
			AddMark(MG_LATE, MK_ANTINUKE, m.positions[pick].pos, pickValue, 25, -1,
				Fmt("anti-nuke district: %.0f value inside %.0f coverage", pickValue, ms.antinukeCoverage));
		}
	}
	// labels: the most valuable marks of each kind get text
	std::vector<std::vector<int>> byKind(_MARK_KINDS_);
	for (const SMark& mk : m.marks) byKind[mk.kind].push_back(mk.id);
	for (std::vector<int>& ids : byKind) {
		std::sort(ids.begin(), ids.end(), [&](int a, int b) {
			const SMark& ma = m.marks[a];
			const SMark& mb = m.marks[b];
			const bool lowFirst = ma.kind == MK_LANDING;   // landing value is a rank
			if (ma.value != mb.value) return lowFirst ? ma.value < mb.value : ma.value > mb.value;
			return a < b;
		});
		for (int k = 0; k < std::min(ms.labelsPerKind, Count(ids)); ++k) m.marks[ids[k]].labelled = true;
	}
}

// ---------------------------------------------------------------- finish

void Marks::Finish()
{
	std::uint64_t h = 1469598103934665603ULL;
	h = Fnv1a(h, m.posOf.data(), m.posOf.size() * sizeof(int));
	for (const SPosition& p : m.positions) {
		const int fields[] = {p.side, p.label, p.sub, p.opening, p.energy, (int)std::lround(p.pos.x), (int)std::lround(p.pos.z)};
		h = Fnv1a(h, fields, sizeof(fields));
	}
	for (const SMark& mk : m.marks) {
		const int fields[] = {mk.kind, (int)std::lround(mk.pos.x), (int)std::lround(mk.pos.z), mk.position};
		h = Fnv1a(h, fields, sizeof(fields));
	}
	m.marksFingerprint = h;
	std::vector<int> perSide(m.sides.size(), 0);
	for (const SPosition& p : m.positions) {
		if (p.f.cells <= 0) { m.marksFailures.push_back("a position has no territory"); break; }
		if (p.side >= 0 && p.side < Count(perSide)) ++perSide[p.side];
	}
	for (int count : perSide) if (count == 0) { m.marksFailures.push_back("a side has no position"); break; }
	m.minWind = in.minWind; m.maxWind = in.maxWind; m.tidal = in.tidal;
	m.mapDiagonal = std::hypot((float)in.mapWidth, (float)in.mapHeight);
	m.marksBuilt = true;
}

void Marks::Run()
{
	const auto t0 = Clock::now();
	// The engine reports geo vents (and possibly clusters) in a different order
	// from game to game; sorting by position makes every tie and id independent
	// of it, so the same map gives the same file. O(S log S).
	clusters = in.clusters;
	for (SClusterInput& cl : clusters) cl.income *= ms.metalScale;
	std::sort(clusters.begin(), clusters.end(), [](const SClusterInput& a, const SClusterInput& b) {
		return a.x != b.x ? a.x < b.x : (a.z != b.z ? a.z < b.z : a.income < b.income);
	});
	geos = in.geos;
	std::sort(geos.begin(), geos.end(), [](const SPoint& a, const SPoint& b) { return a.x != b.x ? a.x < b.x : a.z < b.z; });
	auto stage = [&](double* slot, void (Marks::*fn)()) {
		const auto s = Clock::now();
		(this->*fn)();
		if (slot != nullptr) *slot += Ms(s);
		Check();
	};
	stage(&m.timings.positionsMs, &Marks::BuildContact);
	stage(&m.timings.positionsMs, &Marks::BuildPositions);
	stage(&m.timings.territoryMs, &Marks::BuildTerritory);
	stage(&m.timings.territoryMs, &Marks::BuildFeatures);
	stage(&m.timings.labelsMs, &Marks::BuildLabels);
	stage(&m.timings.labelsMs, &Marks::BuildOpenings);
	stage(&m.timings.marksMs, &Marks::BuildLandmarks);
	Finish();
	m.timings.marksTotalMs = Ms(t0);
}

} // namespace

void BuildMarks(const SInput& in, const SSettings& st, const SFieldView& v, const std::atomic<bool>* cancel, SModel& m)
{
	if (!st.marks.enabled || m.sides.empty()) return;
	Marks marks(in, st, v, cancel, m);
	marks.Run();
}

} // namespace circuit::field
