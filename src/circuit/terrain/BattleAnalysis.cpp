/*
 * BattleAnalysis.cpp
 *
 * D-126: see BattleAnalysis.h and doc/roles/tech-weapon-clusters.md.
 */

#include "terrain/BattleAnalysis.h"
#include "terrain/AirSafety.h"
#include "terrain/WaterSurvey.h"
#include "map/MapManager.h"
#include "terrain/TerrainManager.h"
#include "terrain/TerrainData.h"
#include "map/ThreatMap.h"
#include "unit/CircuitDef.h"
#include "unit/CircuitWDef.h"
#include "unit/enemy/EnemyManager.h"
#include "unit/enemy/EnemyUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "util/Performance.h"
#include "spring/SpringMap.h"
#include "spring/SpringCallback.h"
#include "unit/ally/AllyUnit.h"

#include "UnitDef.h"
#include "WeaponDef.h"
#include "WeaponMount.h"
#include "Log.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <string>
#include <cstdlib>

namespace circuit {

using namespace springai;
using namespace terrain;

#define BA_CELL          64    // route and water grid, elmos
#define BA_HEAT_CELL     256   // combat and air heat grid, elmos
#define BA_WADE_DEPTH    20.f  // BOT/TANK movedefs: land units stop 20 deep
#define BA_SHIP_DEPTH    8.f   // BOAT3/4/5
#define BA_SUB_DEPTH     15.f  // UBOAT4: submarines
#define BA_CLIFF_GRADE   0.75f // steeper than this from the water: nothing climbs out
#define BA_HOVER_GRADE   0.45f
#define BA_NEAR_WATER    600.f // a beach's water must be this close to count

static const int NB8[8][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}};

CBattleAnalysis::CBattleAnalysis(CCircuitAI* circuit)
		: circuit(circuit)
		, cellSize(BA_CELL)
		, gw(0), gh(0)
		, analysed(false)
		, heatCell(BA_HEAT_CELL)
		, hw(0), hh(0)
		, lastDecay(0)
		, combatHalfLife(180.f)
		, airHalfLife(300.f)
		, waterBuilt(false)
{
	for (int i = 0; i < _KIND_SIZE_; ++i) {
		cost[i] = 0.f;
		count[i] = 0;
	}
}

CBattleAnalysis::~CBattleAnalysis()
{
    CancelLaneRequest();
}

// ---------------------------------------------------------------- grid

void CBattleAnalysis::EnsureGrid()
{
	if (gw > 0) {
		return;
	}
	gw = std::max(1, CTerrainManager::GetTerrainWidth() / cellSize);
	gh = std::max(1, CTerrainManager::GetTerrainHeight() / cellSize);
	height.assign(gw * gh, 0.f);
	maxHeight.assign(gw * gh, 0.f);
	const SAreaData* ad = circuit->GetTerrainManager()->GetAreaData();
	const float W = CTerrainManager::GetTerrainWidth() - 1, H = CTerrainManager::GetTerrainHeight() - 1;
	for (int z = 0; z < gh; ++z) {
		for (int x = 0; x < gw; ++x) {
			float sum = 0.f, hi = -1e9f;
			int n = 0;
			for (int sz = 0; sz < 4; ++sz) {
				for (int sx = 0; sx < 4; ++sx) {
					const float px = std::min(W, float(x * cellSize + 8 + sx * 16));
					const float pz = std::min(H, float(z * cellSize + 8 + sz * 16));
					const float h = ad->GetElevationAt(px, pz);
					sum += h;
					hi = std::max(hi, h);
					++n;
				}
			}
			height[z * gw + x] = sum / n;
			maxHeight[z * gw + x] = hi;
		}
	}
	hw = std::max(1, CTerrainManager::GetTerrainWidth() / heatCell);
	hh = std::max(1, CTerrainManager::GetTerrainHeight() / heatCell);
	combat.assign(hw * hh, 0.f);
	air.assign(hw * hh, 0.f);
	BuildPass();   // D-127: per movement class, from the engine's slope map
}

int CBattleAnalysis::Cell(const AIFloat3& pos) const
{
	const int x = std::max(0, std::min(gw - 1, int(pos.x) / cellSize));
	const int z = std::max(0, std::min(gh - 1, int(pos.z) / cellSize));
	return z * gw + x;
}

AIFloat3 CBattleAnalysis::CellPos(int c) const
{
	const float x = (c % gw) * cellSize + cellSize * 0.5f;
	const float z = (c / gw) * cellSize + cellSize * 0.5f;
	return AIFloat3(x, height[c], z);
}

float CBattleAnalysis::CellHeight(int c) const { return height[c]; }
float CBattleAnalysis::CellMaxHeight(int c) const { return maxHeight[c]; }

float CBattleAnalysis::Height(const AIFloat3& pos) const
{
	const float x = std::max(0.f, std::min(float(CTerrainManager::GetTerrainWidth() - 1), pos.x));
	const float z = std::max(0.f, std::min(float(CTerrainManager::GetTerrainHeight() - 1), pos.z));
	return circuit->GetTerrainManager()->GetAreaData()->GetElevationAt(x, z);
}

float CBattleAnalysis::HeightAbove(const AIFloat3& pos, float radius) const
{
	float sum = 0.f;
	for (int i = 0; i < 8; ++i) {
		const float a = i * float(M_PI) / 4.f;
		sum += Height(AIFloat3(pos.x + std::cos(a) * radius, 0.f, pos.z + std::sin(a) * radius));
	}
	return Height(pos) - sum / 8.f;
}

// ---------------------------------------------------------------- range

// The engine's range test (Weapon.cpp TestRange, Cannon.cpp GetStaticRange2D):
// beams and missiles use a sphere scaled by heightmod; a cylinder-targeting
// weapon keeps its flat range; a cannon gains range firing downhill.
// the unit's longest-range weapon (played: the Starfall's recorded weapon is a
// short auxiliary mount, so its reach read 1 to 4 elmos)
CWeaponDef* CBattleAnalysis::MainWeapon(const CCircuitDef* cdef) const
{
	if ((cdef == nullptr) || (cdef->GetDef() == nullptr)) {
		return nullptr;
	}
	auto it = mainWeapon.find(cdef->GetId());
	if (it != mainWeapon.end()) {
		return it->second;
	}
	CWeaponDef* best = cdef->GetWeaponDef();
	float bestRange = (best != nullptr) ? best->GetRange() : 0.f;
	for (WeaponMount* mount : cdef->GetDef()->GetWeaponMounts()) {
		WeaponDef* wd = mount->GetWeaponDef();
		CWeaponDef* cw = circuit->GetWeaponDef(wd->GetWeaponDefId());
		if ((cw != nullptr) && (cw->GetRange() > bestRange)) {
			bestRange = cw->GetRange();
			best = cw;
		}
		delete wd;
		delete mount;
	}
	mainWeapon[cdef->GetId()] = best;
	return best;
}

float CBattleAnalysis::MainRange(const CCircuitDef* cdef) const
{
	CWeaponDef* w = MainWeapon(cdef);
	return (w == nullptr) ? 0.f : w->GetRange();
}

float CBattleAnalysis::InterceptorCoverage(const CCircuitDef* cdef) const
{
	if (cdef == nullptr || cdef->GetDef() == nullptr) return 0.f;
	float coverage = 0.f;
	// Generated wrapper children are caller-owned; the UnitDef is borrowed.
	for (WeaponMount* raw : cdef->GetDef()->GetWeaponMounts()) {
		const std::unique_ptr<WeaponMount> mount(raw);
		const std::unique_ptr<WeaponDef> weapon(mount->GetWeaponDef());
		if (weapon != nullptr && weapon->GetInterceptor() != 0) {
			const float range = weapon->GetCoverageRange();
			if (std::isfinite(range)) coverage = std::max(coverage, range);
		}
	}
	return coverage;
}

AIFloat3 CBattleAnalysis::GetAirContactPos(int index) const
{
	return index >= 0 && static_cast<size_t>(index) < airContacts.size()
		? airContacts[index].pos : AIFloat3(-1.f, 0.f, -1.f);
}

float CBattleAnalysis::GetAirContactCost(int index) const
{
	return index >= 0 && static_cast<size_t>(index) < airContacts.size() ? airContacts[index].cost : 0.f;
}

bool CBattleAnalysis::IsAirContactArmed(int index) const
{
    return index >= 0 && static_cast<size_t>(index) < airContacts.size() && airContacts[index].armed;
}

float CBattleAnalysis::GetArmedAirCost() const
{
    float value = 0.f;
    for (const auto& contact : airContacts) if (contact.armed) value += contact.cost;
    return value;
}

float CBattleAnalysis::EffectiveRange(const CCircuitDef* cdef, const AIFloat3& from, const AIFloat3& to) const
{
	CWeaponDef* main = MainWeapon(cdef);
	if (main == nullptr) {
		return 0.f;
	}
	WeaponDef* wd = main->GetDef();
	const float range = wd->GetRange();
	// a weapon on or over water stands, and aims, at the surface
	const float heightDiff = (std::max(0.f, Height(to)) - std::max(0.f, Height(from))) * wd->GetHeightMod();   // negative: firing downhill
	const float cyl = wd->GetCylinderTargetting();
	if (cyl > 0.f) {
		return (cyl * range > std::fabs(heightDiff)) ? range : 0.f;
	}
	const std::string type = wd->GetType();
	if (type != "Cannon") {
		return std::sqrt(std::max(0.f, range * range - heightDiff * heightDiff));
	}
	const float speed = wd->GetProjectileSpeed();   // elmos per frame
	float grav = wd->GetMyGravity();
	grav = (grav > 0.f) ? -grav : circuit->GetMap()->GetGravity();
	if ((speed <= 0.f) || (grav >= 0.f)) {
		return range;
	}
	auto calc = [speed, grav](float hd, float rbf, float hbf) {
		const float speed2D = speed * 0.7071067f;
		const float sq = speed2D * speed2D;
		if (hd < -100.f) {
			hd *= hbf;
		} else if (hd < 0.f) {
			hd *= (1.f + (hbf - 1.f) * -hd / 100.f);
		}
		const float root = sq + 2.f * grav * hd;
		if (root < 0.f) {
			return 0.f;
		}
		return rbf * (sq + speed2D * std::sqrt(root)) / -grav;
	};
	const float hbfDef = wd->GetHeightBoostFactor();
	const float base = calc(0.f, 1.f, hbfDef);
	const float rbf = (base > 0.f) ? std::max(0.f, std::min(1.f, range / base)) : 0.f;
	float hbf = hbfDef;
	if ((hbf < 0.f) && (rbf > 0.f)) {
		hbf = (2.f - rbf) / std::sqrt(rbf);
	}
	return calc(heightDiff, rbf, hbf);
}

float CBattleAnalysis::ShotEnergy(const CCircuitDef* cdef) const
{
	CWeaponDef* w = MainWeapon(cdef);
	return (w == nullptr) ? 0.f : w->GetCostEShot();
}

float CBattleAnalysis::ShotReload(const CCircuitDef* cdef) const
{
	CWeaponDef* w = MainWeapon(cdef);
	return (w == nullptr) ? 0.f : w->GetDef()->GetReload();
}

bool CBattleAnalysis::LineOfFire(const AIFloat3& from, const AIFloat3& to, float muzzle) const
{
	const float h0 = Height(from) + muzzle;
	const float h1 = Height(to) + 16.f;
	const float dx = to.x - from.x, dz = to.z - from.z;
	const float len = std::sqrt(dx * dx + dz * dz);
	const int steps = std::max(1, int(len / 32.f));
	for (int i = 1; i < steps; ++i) {
		const float t = float(i) / steps;
		const float ground = Height(AIFloat3(from.x + dx * t, 0.f, from.z + dz * t));
		if (ground > h0 + (h1 - h0) * t) {
			return false;
		}
	}
	return true;
}

// ---------------------------------------------------------------- routes

// D-127: the engine's own test, per cell: the bot class (54 degrees, 20 deep)
// for the weapon routes, the amphibious class for landing routes
bool CBattleAnalysis::Passable(int from, int to, bool amph) const
{
	const std::vector<char>& p = pass[amph ? L_AMPH : L_BOT];
	return p[from] && p[to];
}

void CBattleAnalysis::Dijkstra(int start, const Grid& penalty, bool amph, Grid& dist, std::vector<int>& prev) const
{
	const int N = gw * gh;
	dist.assign(N, std::numeric_limits<float>::max());
	prev.assign(N, -1);
	using QE = std::pair<float, int>;
	std::priority_queue<QE, std::vector<QE>, std::greater<QE>> q;
	dist[start] = 0.f;
	q.push({0.f, start});
	while (!q.empty()) {
		const QE e = q.top();
		q.pop();
		const int c = e.second;
		if (e.first > dist[c]) {
			continue;
		}
		const int cx = c % gw, cz = c / gw;
		for (const auto& d : NB8) {
			const int nx = cx + d[0], nz = cz + d[1];
			if ((nx < 0) || (nz < 0) || (nx >= gw) || (nz >= gh)) {
				continue;
			}
			const int n = nz * gw + nx;
			if (!Passable(c, n, amph)) {
				continue;
			}
			const float step = cellSize * ((d[0] != 0 && d[1] != 0) ? 1.4142f : 1.f);
			const float grade = std::fabs(height[n] - height[c]) / step;
			const float w = step * (1.f + 2.f * grade) * penalty[n];
			if (dist[c] + w < dist[n]) {
				dist[n] = dist[c] + w;
				prev[n] = c;
				q.push({dist[n], n});
			}
		}
	}
}

int CBattleAnalysis::Analyse(const AIFloat3& base, int alternatives, float chokeMaxHalfWidth, float chokeMerge)
{
	EnsureGrid();
	const int N = gw * gh;
	routeHeat.assign(N, 0.f);
	routeShare.assign(N, -1.f);
	lane.assign(N, 0);
	routes.clear();
	chokes.clear();

	std::vector<int> clr;
	Clearance(clr);

	const int baseCell = Cell(base);
	Grid penalty(N, 1.f);
	Grid dist;
	std::vector<int> prev;
	for (int it = 0; it < std::max(1, alternatives); ++it) {
		Dijkstra(baseCell, penalty, false, dist, prev);
		for (const AIFloat3& s : sources) {
			const int sc = Cell(s);
			if (dist[sc] == std::numeric_limits<float>::max()) {
				continue;   // no land route: the water analysis covers it
			}
			std::vector<int> path;
			for (int c = sc; c >= 0; c = prev[c]) {
				path.push_back(c);
				if (c == baseCell) {
					break;
				}
			}
			std::reverse(path.begin(), path.end());   // base first
			const float total = std::max(1.f, dist[sc]);
			for (int c : path) {
				routeHeat[c] += 1.f;
				const float sh = dist[c] / total;
				if ((routeShare[c] < 0.f) || (sh < routeShare[c])) {
					routeShare[c] = sh;
				}
				penalty[c] *= 4.f;
				if (it == 0) {
					const int cx = c % gw, cz = c / gw;
					lane[c] = 1;
					for (const auto& d : NB8) {
						const int nx = cx + d[0], nz = cz + d[1];
						if ((nx >= 0) && (nz >= 0) && (nx < gw) && (nz < gh)) {
							lane[nz * gw + nx] = 1;
						}
					}
				}
			}
			routes.push_back(std::move(path));
		}
	}

	// chokes: along each route, the narrowest points within the corridor limit
	std::vector<SChoke> cand;
	const int maxClr = std::max(1, int(chokeMaxHalfWidth / cellSize));
	for (const std::vector<int>& path : routes) {
		const int L = (int)path.size();
		for (int i = 3; i < L - 3; ++i) {
			const int c = path[i];
			if (clr[c] > maxClr) {
				continue;
			}
			bool isMin = true;
			for (int k = i - 3; k <= i + 3; ++k) {
				if (clr[path[k]] < clr[c]) {
					isMin = false;
					break;
				}
			}
			const float sh = routeShare[c];
			if (!isMin || (sh < 0.05f) || (sh > 0.95f)) {
				continue;
			}
			AIFloat3 a = CellPos(path[i - 3]), b = CellPos(path[i + 3]);
			AIFloat3 dir(b.x - a.x, 0.f, b.z - a.z);
			const float len = std::sqrt(dir.x * dir.x + dir.z * dir.z);
			if (len > 0.f) {
				dir.x /= len;
				dir.z /= len;
			}
			cand.push_back({CellPos(c), dir, float(2 * clr[c] * cellSize), routeHeat[c], sh});
		}
	}
	std::sort(cand.begin(), cand.end(), [](const SChoke& l, const SChoke& r) {
		return (l.heat != r.heat) ? (l.heat > r.heat) : (l.width < r.width);
	});
	for (const SChoke& k : cand) {
		bool close = false;
		for (const SChoke& o : chokes) {
			if (k.pos.SqDistance2D(o.pos) < chokeMerge * chokeMerge) {
				close = true;
				break;
			}
		}
		if (!close) {
			chokes.push_back(k);
		}
	}
	analysed = true;
	circuit->LOG("BATTLE: analysed from (%i, %i): %i sources, %i routes, %i chokes", int(base.x), int(base.z),
			(int)sources.size(), (int)routes.size(), (int)chokes.size());
	return (int)chokes.size();
}

float CBattleAnalysis::RouteHeat(const AIFloat3& pos) const
{
	return routeHeat.empty() ? 0.f : routeHeat[Cell(pos)];
}

float CBattleAnalysis::RouteShare(const AIFloat3& pos) const
{
	return routeShare.empty() ? -1.f : routeShare[Cell(pos)];
}

bool CBattleAnalysis::IsFriendlyLane(const AIFloat3& pos) const
{
	return !lane.empty() && lane[Cell(pos)];
}

AIFloat3 CBattleAnalysis::GetChokePos(int i) const { return ((i >= 0) && (i < (int)chokes.size())) ? chokes[i].pos : AIFloat3(-1.f, 0.f, 0.f); }
AIFloat3 CBattleAnalysis::GetChokeDir(int i) const { return ((i >= 0) && (i < (int)chokes.size())) ? chokes[i].dir : AIFloat3(1.f, 0.f, 0.f); }
float CBattleAnalysis::GetChokeWidth(int i) const { return ((i >= 0) && (i < (int)chokes.size())) ? chokes[i].width : 0.f; }
float CBattleAnalysis::GetChokeHeat(int i) const { return ((i >= 0) && (i < (int)chokes.size())) ? chokes[i].heat : 0.f; }
float CBattleAnalysis::GetChokeShare(int i) const { return ((i >= 0) && (i < (int)chokes.size())) ? chokes[i].share : 0.f; }

AIFloat3 CBattleAnalysis::GetRoutePoint(int route, float share) const
{
	if ((route < 0) || (route >= (int)routes.size()) || routes[route].empty()) {
		return AIFloat3(-1.f, 0.f, 0.f);
	}
	const std::vector<int>& p = routes[route];
	const int i = std::max(0, std::min((int)p.size() - 1, int(share * (p.size() - 1))));
	return CellPos(p[i]);
}

// ---------------------------------------------------------------- heat

void CBattleAnalysis::Decay(Grid& g, float factor)
{
	for (float& v : g) {
		v *= factor;
	}
}

void CBattleAnalysis::AddHeat(Grid& g, const AIFloat3& pos, float v)
{
	if (g.empty()) {
		return;
	}
	const int x = std::max(0, std::min(hw - 1, int(pos.x) / heatCell));
	const int z = std::max(0, std::min(hh - 1, int(pos.z) / heatCell));
	g[z * hw + x] += v;
}

float CBattleAnalysis::SumHeat(const Grid& g, const AIFloat3& pos, float radius) const
{
	if (g.empty()) {
		return 0.f;
	}
	const int r = std::max(0, int(radius / heatCell));
	const int x0 = int(pos.x) / heatCell, z0 = int(pos.z) / heatCell;
	float sum = 0.f;
	for (int z = std::max(0, z0 - r); z <= std::min(hh - 1, z0 + r); ++z) {
		for (int x = std::max(0, x0 - r); x <= std::min(hw - 1, x0 + r); ++x) {
			sum += g[z * hw + x];
		}
	}
	return sum;
}

void CBattleAnalysis::OnOwnDamaged(const AIFloat3& pos)
{
	EnsureGrid();
	AddHeat(combat, pos, 1.f);
}

void CBattleAnalysis::OnOwnLost(const AIFloat3& pos, float c)
{
	EnsureGrid();
	AddHeat(combat, pos, 1.f + c / 100.f);
}

void CBattleAnalysis::OnEnemyLost(const AIFloat3& pos, float c)
{
	EnsureGrid();
	AddHeat(combat, pos, 1.f + c / 100.f);
}

void CBattleAnalysis::Update(int frame)
{
	++groundPublication;
	EnsureGrid();
	airContacts.clear();
    groundContacts.clear();
    radarDots.clear();
    navalContacts.clear();
    observedWaterWeapons.assign(height.size(), 0.f);
	const float dt = float(frame - lastDecay) / FRAMES_PER_SEC;
	if (dt > 0.f) {
		Decay(combat, std::pow(0.5f, dt / combatHalfLife));
		Decay(air, std::pow(0.5f, dt / airHalfLife));
		lastDecay = frame;
	}
	for (int i = 0; i < _KIND_SIZE_; ++i) {
		cost[i] = 0.f;
		count[i] = 0;
	}
	for (const auto& kv : circuit->GetEnemyManager()->GetEnemyUnits()) {
		const CEnemyUnit* e = kv.second;
		const CCircuitDef* d = e->GetCircuitDef();
		if (d == nullptr) {
            // D-296: an unidentified dot is still an enemy to avoid. Same
            // visibility rules as identified contacts; land only.
            if (e->IsInRadarOrLOS() && !e->IsIgnore()
                && !(e->GetData().losStatus & (SEnemyData::LosMask::HIDDEN | SEnemyData::LosMask::NEUTRAL
                    | SEnemyData::LosMask::DYING | SEnemyData::LosMask::DEAD))
                && std::isfinite(e->GetPos().x) && std::isfinite(e->GetPos().z) && Height(e->GetPos()) >= 0.f)
                radarDots.push_back(e->GetPos());
			continue;
		}
		const float m = d->GetCostM();
        // Role-level target preferences (e.g. TECH ignoring T1 combat) must not
        // label an occupied foothold empty. Still respect hidden/dead/neutral
        // contacts and the game's explicit ignoredByAI exclusion.
        const bool observed = e->IsInRadarOrLOS()
            && !(e->GetData().losStatus & (SEnemyData::LosMask::HIDDEN | SEnemyData::LosMask::NEUTRAL
                | SEnemyData::LosMask::DYING | SEnemyData::LosMask::DEAD))
            && (!e->IsIgnore() || (d->IsIgnore() && e->GetUnit()->GetRulesParamFloat("ignoredByAI", 0.f) <= 0.f));
        // Current ally-visible contacts only. No hidden mobile or destroyed-memory targets.
        if (!d->IsAbleToFly() && observed && Height(e->GetPos()) >= 0.f) {
            const bool economy = !d->IsMobile() && (d->IsMex() || d->IsBuilder() || d->IsWind()
                || d->GetMaxRange() <= 0.f);
            // D-296: O(1) per contact, cached definition flags only.
            int kind = 0;
            if (!d->IsMobile()) {
                if (d->IsMex()) kind |= K_MEX;
                if (d->IsWind()) kind |= K_WIND;
                if (d->IsAssist()) kind |= K_NANO;
                if (kind == 0 && economy) kind |= K_OTHER_ECO;
            }
            // BAR lets construction turrets reclaim enemy units (modrules
            // reclaim.allowEnemies = true): a static reclaimer's build distance
            // is lethal to a scout (round 12: two Ticks reclaimed by cornanotc).
            const float hazardRange = e->IsBeingBuilt() ? 0.f : std::max(
                d->HasSurfToLand() ? d->GetMaxRange(CCircuitDef::RangeType::LAND) : 0.f,
                (!d->IsMobile() && d->IsAbleToReclaim()) ? d->GetBuildDistance() : 0.f);
            groundContacts.push_back({e->GetPos(), m, economy, e->GetId(), d->GetId(), kind, hazardRange});
        }
        if (observed && !d->IsAbleToFly() && d->IsMobile()
            && (d->IsFloater() || d->IsSubmarine()) && Height(e->GetPos()) < 0.f) {
            navalContacts.push_back(e->GetPos());
        }
        // Some profiles intentionally zero torpedo-tower combat weights. The new
        // route query must still see an observed underwater weapon's coverage.
        // This does not alter the legacy threat maps or their callers.
        if (observed) {
            const AIFloat3& p = e->GetPos();
            const bool submerged = e->GetCircuitDef()->IsInWater(Height(p), p.y);
            if (submerged ? d->HasSubToWater() : d->HasSurfToWater()) {
                // Include cell discretisation and the moving unit's footprint.
                const float reach = d->GetMaxRange(CCircuitDef::RangeType::WATER) + 2.f * cellSize;
                const int x0 = std::max(0, int((p.x - reach) / cellSize));
                const int z0 = std::max(0, int((p.z - reach) / cellSize));
                const int x1 = std::min(gw - 1, int((p.x + reach) / cellSize));
                const int z1 = std::min(gh - 1, int((p.z + reach) / cellSize));
                for (int z = z0; z <= z1; ++z) for (int x = x0; x <= x1; ++x) {
                    const int cell = z * gw + x;
                    if (height[cell] < 0.f && CellPos(cell).SqDistance2D(p) <= reach * reach)
                        observedWaterWeapons[cell] = 1.f;
                }
            }
        }
		auto add = [this, m](Kind k) { cost[k] += m; ++count[k]; };
		if (d->IsAbleToFly()) {
			add(AIR);
			const AIFloat3& pos = e->GetPos();
			if (observed && std::isfinite(pos.x) && std::isfinite(pos.z)
				&& pos.x >= 0.f && pos.z >= 0.f && pos.x < circuit->GetTerrainManager()->GetTerrainWidth()
				&& pos.z < circuit->GetTerrainManager()->GetTerrainHeight()) {
				// One entry per enemy ID. Do not discard armed scout/fighter hybrids,
                // or inflate the sum with overlapping role labels.
				airContacts.push_back({pos, m, d->HasSurfToAir() || d->HasSurfToLand() || d->HasSurfToWater(), e->GetId()});
			}
			if (!e->IsHidden()) {
				AddHeat(air, e->GetPos(), 1.f);
			}
			continue;
		}
		if (d->IsMobile()) {
			if (d->IsSubmarine()) {
				add(SUB);
			} else if (d->IsFloater()) {
				add(SHIP);
			} else if (d->IsSurfer()) {
				add(HOVER);
			} else if (d->IsAmphibious()) {
				add(AMPH);
			} else {
				add(LAND);
			}
			if (d->IsRoleArty()) {
				add(ARTY);
			}
			if (m >= 3000.f) {
				add(HEAVY);
			}
			if (!e->IsHidden() && (d->IsSubmarine() || d->IsFloater() || d->IsSurfer())) {
				MarkHostileWater(e->GetPos(), 256.f);
			}
			continue;
		}
		if (d->IsRoleSuper() && d->IsAttrStock()) {
			add(NUKE);
		} else if (d->GetMaxRange() >= 3000.f) {
			add(LRPC);
		} else if (d->GetMaxRange() > 0.f) {
			add(STATIC_DEF);
		}
	}
}

void CBattleAnalysis::SampleNavalThreat(const AIFloat3& origin, float radius)
{
	std::fill(std::begin(navalThreatCost), std::end(navalThreatCost), 0.f);
	if (!std::isfinite(origin.x) || !std::isfinite(origin.z) || !std::isfinite(radius) || radius <= 0.f) return;
	PrepareWater();
	const int basin = WaterBody(origin, false);
	for (const auto& entry : circuit->GetEnemyManager()->GetEnemyUnits()) {
		const CEnemyUnit* enemy = entry.second;
		CCircuitDef* def = enemy->GetCircuitDef();
		// IsHidden() includes the profile IGNORE bit. Using it here made the
		// deliberate profile-ignore exception below unreachable. This sampler is
		// requested by SEA only; true fog and game-level ignoredByAI still apply.
		if (def == nullptr || !enemy->IsInRadarOrLOS()
			|| (enemy->GetData().losStatus & (SEnemyData::LosMask::HIDDEN | SEnemyData::LosMask::NEUTRAL | SEnemyData::LosMask::DYING | SEnemyData::LosMask::DEAD))) continue;
		if (enemy->IsIgnore() && (!def->IsIgnore() || enemy->GetUnit()->GetRulesParamFloat("ignoredByAI", 0.f) > 0.f)) continue;
		const AIFloat3& pos = enemy->GetPos();
		if (origin.SqDistance2D(pos) > radius * radius) continue;
		if (def->IsAbleToFly()) {
			if (def->HasSurfToLand() || def->HasSurfToWater()) navalThreatCost[2] += def->GetCostM();
			continue;
		}
		if (Height(pos) >= 0.f || (basin >= 0 && WaterBody(pos, false) != basin)) continue;
		const int kind = !def->IsMobile() ? 3 : def->IsInWater(Height(pos), pos.y) ? 1 : 0;
		navalThreatCost[kind] += def->GetCostM();
	}
}

float CBattleAnalysis::AmphThreat(const AIFloat3& pos) const {
    const float coverage = observedWaterWeapons.empty() ? 0.f : observedWaterWeapons[Cell(pos)];
    return std::max(coverage, circuit->GetThreatMap()->GetAmphThreatAtPos(pos));
}
AIFloat3 CBattleAnalysis::GetGroundContactPos(int i) const {
    return i >= 0 && i < int(groundContacts.size()) ? groundContacts[i].pos : AIFloat3(-1.f, 0.f, -1.f);
}
int CBattleAnalysis::GetGroundContactId(int i) const {
    return i >= 0 && i < int(groundContacts.size()) ? groundContacts[i].id : -1;
}
int CBattleAnalysis::GetGroundContactDefId(int i) const {
    return i >= 0 && i < int(groundContacts.size()) ? groundContacts[i].defId : -1;
}
float CBattleAnalysis::GetGroundContactCost(int i) const {
    return i >= 0 && i < int(groundContacts.size()) ? groundContacts[i].cost : 0.f;
}
bool CBattleAnalysis::IsGroundContactEconomy(int i) const {
    return i >= 0 && i < int(groundContacts.size()) && groundContacts[i].economy;
}
int CBattleAnalysis::GetGroundContactKind(int i) const {
    return i >= 0 && i < int(groundContacts.size()) ? groundContacts[i].kind : 0;
}
void CBattleAnalysis::EnsureGroundHazard(float margin)
{
    if (!std::isfinite(margin)) margin = 0.f;
    margin = std::clamp(margin, 0.f, 2048.f);
    if (groundHazardPublication == groundPublication && groundHazardMargin == margin
        && observedGroundHazard.size() == height.size()) return;
    // Lazy: only a caller (D-296 scout raids) pays, at most once per Update
    // publication (1 s) per margin. O(G) clear + O(A * (r+margin)^2 / cell^2)
    // paint over A armed observed ground contacts; no allocation after the
    // first build (assign reuses capacity).
    performance::Scope measured(circuit, performance::BATTLE_GROUND_HAZARD);
    EnsureGrid();
    groundHazardPublication = groundPublication; groundHazardMargin = margin;
    observedGroundHazard.assign(height.size(), 0.f);
    for (const auto& c : groundContacts) {
        if (c.hazardRange <= 0.f) continue;
        // Include cell discretisation, like the water-weapon layer.
        ranged::PaintDisc(observedGroundHazard, gw, gh, float(cellSize), c.pos.x, c.pos.z,
            c.hazardRange + margin + float(cellSize), 1.f);
    }
    // Unidentified dots (played: raiders ran into an LLT line that was only a
    // dot until inside its range). Conservative radius; identification later
    // replaces it with the real range. O(D * (r+margin)^2 / cell^2).
    for (const auto& p : radarDots)
        ranged::PaintDisc(observedGroundHazard, gw, gh, float(cellSize), p.x, p.z,
            unknownHazardRange + margin + float(cellSize), 1.f);
}
void CBattleAnalysis::SetUnknownHazardRange(float range)
{
    const float value = std::isfinite(range) ? std::clamp(range, 0.f, 2048.f) : 700.f;
    if (value != unknownHazardRange) { unknownHazardRange = value; groundHazardPublication = ~0u; }
}
float CBattleAnalysis::GroundHazard(const AIFloat3& pos, float margin)
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.z)) return 0.f;
    EnsureGroundHazard(margin);
    return observedGroundHazard.empty() ? 0.f : observedGroundHazard[Cell(pos)];
}
AIFloat3 CBattleAnalysis::GetNavalContactPos(int i) const {
    return i >= 0 && i < int(navalContacts.size()) ? navalContacts[i] : AIFloat3(-1.f, 0.f, -1.f);
}
int CBattleAnalysis::GetAllyAssetCount() {
    const int frame = circuit->GetLastFrame();
    if (frame >= allyAssetFrame + 5 * FRAMES_PER_SEC) {
        allyAssetFrame = frame;
        allyAssets.clear();
        circuit->UpdateFriendlyUnits();
        for (const auto& kv : circuit->GetFriendlyUnits()) {
            // AllyUnit's definition may belong to another AI that has resigned.
            // Resolve through this AI's definition table, using only the stable ID.
            const CCircuitDef* d = circuit->GetCircuitDefSafe(circuit->GetCallback()->Unit_GetDefId(kv.first));
            if (d == nullptr || d->IsMobile() || !(d->IsMex() || d->IsBuilder() || d->GetDef()->IsNeedGeo())
                || kv.second->GetUnit()->IsBeingBuilt()) continue;
            allyAssets.push_back({kv.second->GetPos(frame), d->GetCostM()});
        }
    }
    return static_cast<int>(allyAssets.size());
}
AIFloat3 CBattleAnalysis::GetAllyAssetPos(int i) const {
    return i >= 0 && i < int(allyAssets.size()) ? allyAssets[i].pos : AIFloat3(-1.f, 0.f, -1.f);
}
float CBattleAnalysis::GetAllyAssetCost(int i) const {
    return i >= 0 && i < int(allyAssets.size()) ? allyAssets[i].cost : 0.f;
}
float CBattleAnalysis::CombatHeat(const AIFloat3& pos, float radius) const { return SumHeat(combat, pos, radius); }
float CBattleAnalysis::AirHeat(const AIFloat3& pos, float radius) const { return SumHeat(air, pos, radius); }

AIFloat3 CBattleAnalysis::CombatNear(const AIFloat3& from, float minHeat) const
{
	float best = std::numeric_limits<float>::max();
	AIFloat3 res(-1.f, 0.f, 0.f);
	for (int c = 0; c < (int)combat.size(); ++c) {
		if (combat[c] < minHeat) {
			continue;
		}
		const AIFloat3 p((c % hw) * heatCell + heatCell * 0.5f, 0.f, (c / hw) * heatCell + heatCell * 0.5f);
		const float d = from.SqDistance2D(p);
		if (d < best) {
			best = d;
			res = p;
		}
	}
	return res;
}

AIFloat3 CBattleAnalysis::AirCentre(const AIFloat3& pos, float radius) const
{
	const int r = std::max(0, int(radius / heatCell));
	const int x0 = int(pos.x) / heatCell, z0 = int(pos.z) / heatCell;
	float sum = 0.f, sx = 0.f, sz = 0.f;
	for (int z = std::max(0, z0 - r); z <= std::min(hh - 1, z0 + r); ++z) {
		for (int x = std::max(0, x0 - r); x <= std::min(hw - 1, x0 + r); ++x) {
			const float v = air.empty() ? 0.f : air[z * hw + x];
			sum += v;
			sx += v * (x * heatCell + heatCell * 0.5f);
			sz += v * (z * heatCell + heatCell * 0.5f);
		}
	}
	return (sum > 0.01f) ? AIFloat3(sx / sum, 0.f, sz / sum) : AIFloat3(-1.f, 0.f, 0.f);
}

float CBattleAnalysis::EnemyCost(int kind) const { return ((kind >= 0) && (kind < _KIND_SIZE_)) ? cost[kind] : 0.f; }
int CBattleAnalysis::EnemyCount(int kind) const { return ((kind >= 0) && (kind < _KIND_SIZE_)) ? count[kind] : 0; }

float CBattleAnalysis::SurfThreat(const AIFloat3& pos) const { return circuit->GetThreatMap()->GetSurfThreatAtPos(pos); }
float CBattleAnalysis::AirThreat(const AIFloat3& pos) const { return circuit->GetThreatMap()->GetAirThreatAtPos(pos); }
bool CBattleAnalysis::InLos(const AIFloat3& pos) const {
    return std::isfinite(pos.x) && std::isfinite(pos.z) && pos.x >= 0.f && pos.z >= 0.f
        && pos.x < CTerrainManager::GetTerrainWidth() && pos.z < CTerrainManager::GetTerrainHeight()
        && circuit->GetMapManager()->IsInLOS(AIFloat3(pos.x, 0.f, pos.z));
}
float CBattleAnalysis::AirThreatAlong(const AIFloat3& from, const AIFloat3& to, float padding) const {
    const auto* threat = circuit->GetThreatMap();
    float result = air::CorridorThreat(from.x, from.z, to.x, to.z, padding,
        CTerrainManager::GetTerrainWidth(), CTerrainManager::GetTerrainHeight(), threat->GetSquareSize(),
        [threat](float x, float z) { return threat->GetAirThreatAtPos(AIFloat3(x,0.f,z)); });
    if (!std::isfinite(result) || result >= 1.f) return result;
    RefreshAirWeapons();
    for (const auto& weapon : airWeapons) {
        if (air::IntersectsCircle(from.x,from.z,to.x,to.z,weapon.pos.x,weapon.pos.z,
            weapon.range+padding+2.f*threat->GetSquareSize())) return std::max(1.f,result);
    }
    return result;
}
void CBattleAnalysis::RefreshAirWeapons() const {
    const int frame=circuit->GetLastFrame();
    if (frame<airWeaponFrame+FRAMES_PER_SEC) return;
    airWeaponFrame=frame;airWeapons.clear();
    for (const auto& kv:circuit->GetEnemyManager()->GetEnemyUnits()) {
        const auto* e=kv.second;const auto* d=e->GetCircuitDef();
        if (d==nullptr || !d->HasSurfToAir() || !e->IsInRadarOrLOS() || e->IsBeingBuilt()
            || (e->GetData().losStatus & (SEnemyData::LosMask::HIDDEN | SEnemyData::LosMask::NEUTRAL
                | SEnemyData::LosMask::DYING | SEnemyData::LosMask::DEAD))) continue;
        if (e->IsIgnore() && (!d->IsIgnore() || e->GetUnit()->GetRulesParamFloat("ignoredByAI",0.f)>0.f)) continue;
        const float range=d->GetMaxRange(CCircuitDef::RangeType::AIR);
        if (range>0.f) airWeapons.push_back({e->GetPos(),range});
    }
}

int CBattleAnalysis::GetNavalForceCount() {
    const int frame = circuit->GetLastFrame();
    if (frame < navalForceFrame + 5 * FRAMES_PER_SEC) return int(navalForces.size());
    navalForceFrame = frame;
    navalForces.clear(); PrepareWater();
    auto add = [this](int id, CCircuitDef* d, const AIFloat3& p, bool allied) {
        if (d == nullptr || d->IsAbleToFly() || d->IsSurfer() || Height(p) >= -8.f) return;
        const bool factory = !d->IsMobile() && d->IsBuilder();
        const bool submerged = d->IsInWater(Height(p), p.y);
        const bool antiSub = submerged ? d->HasSubToWater() : d->HasSurfToWater();
        const bool armed = antiSub || d->HasSurfToLand() || d->HasSurfToAir();
        // Builders/hovercraft are not a combat fleet. Include naval factories
        // as friendly support anchors only; their metal is never fleet strength.
        if (!factory && (!d->IsMobile() || d->IsBuilder() || !armed
            || !(d->IsFloater() || d->IsSubmarine() || (d->IsAmphibious() && submerged)))) return;
        const int body = WaterBody(p,false);
        if (body < 0) return;
        navalForces.push_back({p, d->GetCostM(), id, d->GetId(),
            (allied ? 1 : 0) | (submerged ? 2 : 0) | (antiSub ? 4 : 0) | (factory ? 8 : 0), body});
    };
    circuit->UpdateFriendlyUnits();
    for (const auto& kv : circuit->GetFriendlyUnits()) {
        if (kv.second->GetUnit()->IsBeingBuilt()) continue;
        auto* d = circuit->GetCircuitDefSafe(circuit->GetCallback()->Unit_GetDefId(kv.first));
        add(kv.first, d, kv.second->GetPos(frame), true);
    }
    for (const auto& kv : circuit->GetEnemyManager()->GetEnemyUnits()) {
        const auto* e = kv.second;
        auto* d = e->GetCircuitDef();
        if (d == nullptr || !e->IsInRadarOrLOS() || e->IsBeingBuilt()
            || (e->GetData().losStatus & (SEnemyData::LosMask::HIDDEN | SEnemyData::LosMask::NEUTRAL
                | SEnemyData::LosMask::DYING | SEnemyData::LosMask::DEAD))) continue;
        if (e->IsIgnore() && (!d->IsIgnore() || e->GetUnit()->GetRulesParamFloat("ignoredByAI",0.f)>0.f)) continue;
        add(e->GetId(),d,e->GetPos(),false);
    }
    // Reproducible ties independent of native unordered containers.
    std::sort(navalForces.begin(),navalForces.end(),[](const NavalForce& a,const NavalForce& b) { return a.id<b.id; });
    return int(navalForces.size());
}
int CBattleAnalysis::GetNavalForceId(int i) const { return i>=0 && i<int(navalForces.size()) ? navalForces[i].id : -1; }
bool CBattleAnalysis::OutsideStaticWaterWeapons(const AIFloat3& position, float padding, float formationRadius)
{
    GetSeaForceCount();
    // Derived from the exact snapshots used by the old script loops, not a
    // timed observation cache. Ground can republish within the same frame.
    if (waterWeaponFrame != seaForceFrame || waterWeaponPublication != groundPublication) {
        waterWeaponFrame = seaForceFrame; waterWeaponPublication = groundPublication;
        staticWaterWeapons.clear(); staticWaterWeaponIndex.Clear(); maximumWaterWeaponRange = 0.f;
        staticWaterWeaponIndexValid = true;
        const auto add = [&](const AIFloat3& point, const CCircuitDef* definition) {
            const float range = definition->GetMaxRange(CCircuitDef::RangeType::WATER);
            if (staticWaterWeaponIndex.CanQuery({point.x,point.z},0.f) && std::isfinite(range) && range>=0.f)
                staticWaterWeaponIndex.Add({point.x, point.z}, int(staticWaterWeapons.size()));
            else staticWaterWeaponIndexValid = false;
            staticWaterWeapons.push_back({point, range});
            maximumWaterWeaponRange = std::max(maximumWaterWeaponRange, range);
        };
        for (int i = 0; i < GetGroundContactCount(); ++i) {
            const int id = GetGroundContactDefId(i);
            const auto* definition = id >= 0 ? circuit->GetCircuitDef(id) : nullptr;
            if (definition && !definition->IsMobile() && (definition->HasSurfToWater() || definition->HasSubToWater()))
                add(GetGroundContactPos(i), definition);
        }
        for (const auto& force : seaForces) {
            if ((force.flags & 1) || !(force.flags & 8) || !(force.flags & 4)) continue;
            const auto* definition = force.defId >= 0 ? circuit->GetCircuitDef(force.defId) : nullptr;
            if (definition) add(force.pos, definition);
        }
    }
    const auto inside = [&](int index) {
        const auto& weapon = staticWaterWeapons[index];
        const float radius = (weapon.range + padding) + formationRadius;
        return position.SqDistance2D(weapon.position) < radius * radius;
    };
    // Broad phase is conservative even for an unusual negative policy margin.
    // Exact squared-radius test and the strict boundary remain unchanged.
    const float queryRadius=(maximumWaterWeaponRange + std::fabs(padding)) + std::fabs(formationRadius);
    bool safe = true;
    if (staticWaterWeaponIndexValid && staticWaterWeaponIndex.CanQuery({position.x,position.z},queryRadius))
        safe = !staticWaterWeaponIndex.Any({position.x, position.z},queryRadius,inside);
    else {
        // Preserve the original scan for exceptional policy/contact values;
        // never feed NaN, infinity or overflowing coordinates to grid indexing.
        for (size_t index=0; index<staticWaterWeapons.size(); ++index)
            if (inside(int(index))) { safe=false; break; }
    }
    static const bool verify = std::getenv("CIRCUIT_VERIFY_SEA_STATIC_INDEX") != nullptr;
    if (verify) {
        // Independent legacy traversal also verifies snapshot membership, not
        // merely the broad-phase arithmetic. Validation only, never timings.
        bool legacy = true;
        const auto threatens = [&](const AIFloat3& point, const CCircuitDef* definition) {
            const float radius = (definition->GetMaxRange(CCircuitDef::RangeType::WATER) + padding) + formationRadius;
            return position.SqDistance2D(point) < radius * radius;
        };
        for (int index = 0; index < GetGroundContactCount(); ++index) {
            const int definitionId = GetGroundContactDefId(index);
            const auto* definition = definitionId >= 0 ? circuit->GetCircuitDef(definitionId) : nullptr;
            if (definition && !definition->IsMobile() && (definition->HasSurfToWater() || definition->HasSubToWater())
                && threatens(GetGroundContactPos(index), definition)) legacy = false;
        }
        for (const auto& force : seaForces) {
            if ((force.flags & 1) || !(force.flags & 8) || !(force.flags & 4)) continue;
            const auto* definition = force.defId >= 0 ? circuit->GetCircuitDef(force.defId) : nullptr;
            if (definition && threatens(force.pos, definition)) legacy = false;
        }
        if (safe != legacy) circuit->LOG("[INVARIANT] SEA static weapon index diverged");
    }
    return safe;
}

int CBattleAnalysis::GetSeaForceCount() {
    const int frame=circuit->GetLastFrame();
    if (frame==seaForceFrame) return int(seaForces.size());
    seaForceFrame=frame;
    GetNavalForceCount();
    // SEA engagement observations are fresh on each requesting frame. Keep
    // AIR's five-second membership snapshot untouched. One O(F+E) pass with
    // retained vector capacity; no per-ship scans or hidden-position callbacks.
    seaForces.clear();
    for (const auto& force : navalForces) {
        if (!(force.flags & 1)) continue;
        auto it = circuit->GetFriendlyUnits().find(force.id);
        if (it == circuit->GetFriendlyUnits().end()) continue;
        NavalForce fresh = force;
        fresh.pos = it->second->GetPos(frame);
        fresh.body = WaterBody(fresh.pos,false);
        seaForces.push_back(fresh);
    }
    for (const auto& kv : circuit->GetEnemyManager()->GetEnemyUnits()) {
        const auto* e=kv.second;
        auto* d=e->GetCircuitDef();
        if (e->GetData().losStatus & (SEnemyData::LosMask::HIDDEN|SEnemyData::LosMask::NEUTRAL
            | SEnemyData::LosMask::DYING|SEnemyData::LosMask::DEAD)) continue;
        const bool observed=e->IsInRadarOrLOS();
        // Static memory is a search objective (flag 128), never fire authority.
        if (!observed && (d==nullptr || d->IsMobile())) continue;
        if (e->IsIgnore() && (d==nullptr || !d->IsIgnore() || (observed
            && e->GetUnit()->GetRulesParamFloat("ignoredByAI",0.f)>0.f))) continue;
        const auto& p=e->GetPos(); // only the last legal observation
        // D-301: hovers on water are SEA contacts too (flag 512). Only surface
        // guns can hit them; script filters torpedo-only cohorts (KI-611).
        if (Height(p)>=-8.f || (d!=nullptr && d->IsAbleToFly())) continue;
        const int body=WaterBody(p,false);
        if (body<0) continue;
        if (d==nullptr) {
            if (p.y < -1.f) seaForces.push_back({p,0.f,e->GetId(),-1,2|16,body});
            continue;
        }
        const bool submerged=d->IsInWater(Height(p),p.y);
        const bool antiSub=submerged ? d->HasSubToWater() : d->HasSurfToWater();
        if (d->IsMobile() && !(d->IsFloater() || d->IsSubmarine() || d->IsSurfer() || (d->IsAmphibious() && submerged))) continue;
        // Unfinished yards and mobile constructors are denial targets too.
        const int flags=(submerged?2:0)|(antiSub?4:0)|(!d->IsMobile()?8:0)
            |(!d->IsMobile() && !d->GetBuildOptions().empty()?32:0)
            |(d->IsMex()?64:0)|(!observed?128:0)
            |(d->IsMobile() && d->IsAmphibious() && submerged?256:0)
            |(d->IsMobile() && d->IsSurfer()?512:0);
        seaForces.push_back({p,d->GetCostM(),e->GetId(),d->GetId(),flags,body});
    }
    std::sort(seaForces.begin(),seaForces.end(),[](const NavalForce& a,const NavalForce& b){return a.id<b.id;});
    return int(seaForces.size());
}
int CBattleAnalysis::GetNavalForceDefId(int i) const { return i>=0 && i<int(navalForces.size()) ? navalForces[i].defId : -1; }
int CBattleAnalysis::GetNavalForceFlags(int i) const { return i>=0 && i<int(navalForces.size()) ? navalForces[i].flags : 0; }
int CBattleAnalysis::GetNavalForceBody(int i) const { return i>=0 && i<int(navalForces.size()) ? navalForces[i].body : -1; }
float CBattleAnalysis::GetNavalForceCost(int i) const { return i>=0 && i<int(navalForces.size()) ? navalForces[i].cost : 0.f; }
AIFloat3 CBattleAnalysis::GetNavalForcePos(int i) const { return i>=0 && i<int(navalForces.size()) ? navalForces[i].pos : AIFloat3(-1.f,0.f,-1.f); }

// ---------------------------------------------------------------- water

void CBattleAnalysis::Label(std::vector<int>& body, float minDepth)
{
	const int N = gw * gh;
	body.assign(N, -1);
	int next = 0;
	for (int s = 0; s < N; ++s) {
		if ((body[s] >= 0) || (maxHeight[s] > -minDepth)) {
			continue;
		}
		std::queue<int> q;
		q.push(s);
		body[s] = next;
		while (!q.empty()) {
			const int c = q.front();
			q.pop();
			const int cx = c % gw, cz = c / gw;
			for (int k = 0; k < 4; ++k) {
				const int nx = cx + NB8[k][0], nz = cz + NB8[k][1];
				if ((nx < 0) || (nz < 0) || (nx >= gw) || (nz >= gh)) {
					continue;
				}
				const int n = nz * gw + nx;
				if ((body[n] < 0) && (maxHeight[n] <= -minDepth)) {
					body[n] = next;
					q.push(n);
				}
			}
		}
		++next;
	}
}

void CBattleAnalysis::BuildWater()
{
	EnsureGrid();
	if (waterBuilt) {
		return;
	}
	Label(body8, BA_SHIP_DEPTH);
	Label(body15, BA_SUB_DEPTH);
	int n8 = 0, n15 = 0;
	for (int b : body8) n8 = std::max(n8, b + 1);
	for (int b : body15) n15 = std::max(n15, b + 1);
	hostile8.assign(n8, 0);
	hostile15.assign(n15, 0);
	waterBuilt = true;
}

void CBattleAnalysis::UpdateWaterSurvey(int body)
{
    BuildWater();
    // Pay history allocation/indexing only for a caller requesting a survey;
    // ordinary AIR/TECH water analysis retains its previous memory/work cost.
    if (surveySeen.empty()) {
        surveyCells.resize(hostile8.size());
        surveySeen.assign(body8.size(), -1);
        surveyFrame.assign(hostile8.size(), -100000);
        for (size_t i=0; i<body8.size(); ++i)
            if (body8[i]>=0) surveyCells[body8[i]].push_back(static_cast<int>(i));
    }
    const int frame = circuit->GetLastFrame();
    if (body < 0 || body >= static_cast<int>(surveyCells.size()) || frame-surveyFrame[body] < 5*FRAMES_PER_SEC) return;
    surveyFrame[body] = frame;
    const auto* sensors = circuit->GetMapManager();
    // O(W_body), independent of unit/scout count. Read the already updated
    // ally sensor maps, not engine wrappers, once per five seconds per basin.
    // A 64-elmo grid proves sampled coverage, not omniscience between samples.
    for (int c : surveyCells[body]) {
        const AIFloat3 surface((c%gw+.5f)*cellSize, 0.f, (c/gw+.5f)*cellSize);
        const AIFloat3 submerged(surface.x, -64.f, surface.z);
        surveySeen[c] = survey::Observe(surveySeen[c], frame,
            sensors->IsInLOS(surface), sensors->IsInRadar(submerged));
    }
}

float CBattleAnalysis::GetWaterSurveyCoverage(int body, int maxAgeFrames)
{
    UpdateWaterSurvey(body);
    if (body < 0 || body >= static_cast<int>(surveyCells.size()) || surveyCells[body].empty()) return 0.f;
    int fresh = 0;
    for (int c : surveyCells[body]) fresh += survey::Fresh(surveySeen[c], circuit->GetLastFrame(), maxAgeFrames);
    return static_cast<float>(fresh)/static_cast<float>(surveyCells[body].size());
}

AIFloat3 CBattleAnalysis::GetWaterScoutGoal(int body, int maxAgeFrames, const AIFloat3& from, int seed)
{
    UpdateWaterSurvey(body);
    AIFloat3 best(-1.f, 0.f, -1.f);
    if (body < 0 || body >= static_cast<int>(surveyCells.size())) return best;
    float score = std::numeric_limits<float>::max();
    for (int c : surveyCells[body]) {
        if (survey::Fresh(surveySeen[c], circuit->GetLastFrame(), maxAgeFrames)) continue;
        const AIFloat3 p((c%gw+.5f)*cellSize, 0.f, (c/gw+.5f)*cellSize);
        const float dx=p.x-from.x, dz=p.z-from.z;
        // Stable scout-specific tie/sector bias without consuming random draws.
        const unsigned hash=static_cast<unsigned>(c/16)*2654435761u ^ static_cast<unsigned>(seed)*2246822519u;
        const float rank=dx*dx+dz*dz+static_cast<float>(hash%16u)*65536.f;
        if (rank < score) { score=rank; best=p; }
    }
    return best;
}

int CBattleAnalysis::GetWaterEnemyCount(int body)
{
    BuildWater();
    if (body < 0 || body >= static_cast<int>(hostile8.size())) return -1;
    int count=0;
    // O(E), called by SEA's five-second decision only. Include unfinished
    // factories/builders and unresolved static sightings omitted by combat
    // snapshots. Never query hidden engine positions or definitions.
    for (const auto& item : circuit->GetEnemyManager()->GetEnemyUnits()) {
        const auto* enemy=item.second;
        if (enemy->GetData().losStatus & (SEnemyData::LosMask::NEUTRAL|SEnemyData::LosMask::DYING|SEnemyData::LosMask::DEAD)) continue;
        const auto* def=enemy->GetCircuitDef();
        if (def != nullptr && def->GetDef()->IsAbleToFly()) continue;
        const auto& p=enemy->GetPos();
        if (WaterBody(p,false)!=body) continue;
        // A profile's IGNORE preference is not proof that a remembered enemy
        // structure vanished. HIDDEN marks invalidated positional memory.
        if (enemy->IsInRadarOrLOS() || (def != nullptr && !def->IsMobile()
            && !(enemy->GetData().losStatus & SEnemyData::LosMask::HIDDEN))) ++count;
    }
    return count;
}

int CBattleAnalysis::WaterBody(const AIFloat3& pos, bool subDepth) const
{
	if (!waterBuilt) {
		return -1;
	}
	return subDepth ? body15[Cell(pos)] : body8[Cell(pos)];
}

bool CBattleAnalysis::IsHostileWater(int body, bool subDepth) const
{
	const std::vector<char>& h = subDepth ? hostile15 : hostile8;
	return (body >= 0) && (body < (int)h.size()) && h[body];
}

void CBattleAnalysis::MarkHostileWater(const AIFloat3& pos, float radius)
{
	BuildWater();
	const int r = std::max(0, int(radius / cellSize));
	const int x0 = std::max(0, std::min(gw - 1, int(pos.x) / cellSize));
	const int z0 = std::max(0, std::min(gh - 1, int(pos.z) / cellSize));
	for (int z = std::max(0, z0 - r); z <= std::min(gh - 1, z0 + r); ++z) {
		for (int x = std::max(0, x0 - r); x <= std::min(gw - 1, x0 + r); ++x) {
			const int c = z * gw + x;
			if (body8[c] >= 0) hostile8[body8[c]] = 1;
			if (body15[c] >= 0) hostile15[body15[c]] = 1;
		}
	}
}

// The owner's rule (D-125, W8): the engine allows a torpedo launcher 12 deep,
// a submarine needs 15. A site passes only where subs can actually come.
bool CBattleAnalysis::TorpedoSiteOK(const CCircuitDef* cdef, const AIFloat3& pos, float range, bool onLand) const
{
	if (!waterBuilt || (cdef == nullptr)) {
		return false;
	}
	if (!onLand) {
		const float hx = cdef->GetDef()->GetXSize() * SQUARE_SIZE * 0.5f;
		const float hz = cdef->GetDef()->GetZSize() * SQUARE_SIZE * 0.5f;
		for (float z = -hz; z <= hz; z += SQUARE_SIZE) {
			for (float x = -hx; x <= hx; x += SQUARE_SIZE) {
				if (Height(AIFloat3(pos.x + x, 0.f, pos.z + z)) > -BA_SUB_DEPTH) {
					return false;   // 1: every footprint square 15 deep
				}
			}
		}
		const int b = body15[Cell(pos)];
		if (!IsHostileWater(b, true)) {
			return false;   // 2: a body subs can come from
		}
	} else if (Height(pos) < 0.f) {
		return false;
	}
	// 4: half the range circle in a hostile 15 body
	const int r = std::max(1, int(range / cellSize));
	const int x0 = int(pos.x) / cellSize, z0 = int(pos.z) / cellSize;
	int inside = 0, hostile = 0;
	float nearest = std::numeric_limits<float>::max();
	for (int z = z0 - r; z <= z0 + r; ++z) {
		for (int x = x0 - r; x <= x0 + r; ++x) {
			if ((x - x0) * (x - x0) + (z - z0) * (z - z0) > r * r) {
				continue;
			}
			++inside;
			if ((x < 0) || (z < 0) || (x >= gw) || (z >= gh)) {
				continue;
			}
			const int c = z * gw + x;
			if (IsHostileWater(body15[c], true)) {
				++hostile;
				nearest = std::min(nearest, pos.SqDistance2D(CellPos(c)));
			}
		}
	}
	if (hostile * 2 < inside) {
		return false;
	}
	if (onLand) {
		return nearest <= SQUARE(300.f);   // depth charges: deep water close to the shore
	}
	// 3: a straight line 60% of the range out stays 15 deep (no sandbar)
	for (int k = 0; k < 16; ++k) {
		const float a = k * float(M_PI) / 8.f;
		const float cx = std::cos(a), cz = std::sin(a);
		bool clear = true;
		for (float d = 16.f; d <= range * 0.6f; d += 16.f) {
			if (Height(AIFloat3(pos.x + cx * d, 0.f, pos.z + cz * d)) > -BA_SUB_DEPTH) {
				clear = false;
				break;
			}
		}
		if (clear) {
			return true;
		}
	}
	return false;
}

int CBattleAnalysis::AnalyseBeaches(const AIFloat3& centre, float radius)
{
	BuildWater();
	beaches.clear();
	const int N = gw * gh;
	std::vector<char> shore(N, 0);
	std::vector<int> cells;
	for (int c = 0; c < N; ++c) {
		if (height[c] < 0.f || centre.SqDistance2D(CellPos(c)) > radius * radius) {
			continue;
		}
		const int cx = c % gw, cz = c / gw;
		for (int k = 0; k < 4; ++k) {
			const int nx = cx + NB8[k][0], nz = cz + NB8[k][1];
			if ((nx >= 0) && (nz >= 0) && (nx < gw) && (nz < gh) && (height[nz * gw + nx] < 0.f)) {
				shore[c] = 1;
				cells.push_back(c);
				break;
			}
		}
	}
	// landing routes for hovers and amphibious units: where they cross the shore
	std::vector<float> crossHeat(N, 0.f);
	if (!sources.empty()) {
		Grid penalty(N, 1.f), dist;
		std::vector<int> prev;
		Dijkstra(Cell(centre), penalty, true, dist, prev);
		for (const AIFloat3& s : sources) {
			const int sc = Cell(s);
			if (dist[sc] == std::numeric_limits<float>::max()) {
				continue;
			}
			bool wet = false;
			for (int c = sc; c >= 0; c = prev[c]) {
				if (height[c] < 0.f) {
					wet = true;
				} else if (wet && shore[c]) {
					crossHeat[c] += 1.f;
					wet = false;
				}
			}
		}
	}
	const float seg2 = 256.f * 256.f;
	std::vector<char> used(N, 0);
	for (int seed : cells) {
		if (used[seed]) {
			continue;
		}
		const AIFloat3 sp = CellPos(seed);
		float sx = 0.f, sz = 0.f, wx = 0.f, wz = 0.f, heat = 0.f;
		int n = 0, nw = 0;
		for (int c : cells) {
			if (used[c] || (sp.SqDistance2D(CellPos(c)) > seg2)) {
				continue;
			}
			used[c] = 1;
			const AIFloat3 p = CellPos(c);
			sx += p.x;
			sz += p.z;
			heat += crossHeat[c];
			++n;
			const int cx = c % gw, cz = c / gw;
			for (int k = 0; k < 8; ++k) {
				const int nx = cx + NB8[k][0], nz = cz + NB8[k][1];
				if ((nx >= 0) && (nz >= 0) && (nx < gw) && (nz < gh) && (height[nz * gw + nx] < 0.f)) {
					const AIFloat3 q = CellPos(nz * gw + nx);
					wx += q.x;
					wz += q.z;
					++nw;
				}
			}
		}
		if ((n == 0) || (nw == 0)) {
			continue;
		}
		SBeach b;
		b.pos = AIFloat3(sx / n, 0.f, sz / n);
		b.pos.y = Height(b.pos);
		AIFloat3 dir(wx / nw - b.pos.x, 0.f, wz / nw - b.pos.z);
		const float len = std::sqrt(dir.x * dir.x + dir.z * dir.z);
		b.seaward = (len > 0.f) ? AIFloat3(dir.x / len, 0.f, dir.z / len) : AIFloat3(1.f, 0.f, 0.f);
		b.heat = heat;
		b.cls = 0;
		auto at = [&b, this](float d) { return Height(AIFloat3(b.pos.x + b.seaward.x * d, 0.f, b.pos.z + b.seaward.z * d)); };
		const float grade = (at(-128.f) - at(64.f)) / 192.f;
		if (grade > BA_CLIFF_GRADE) {
			b.cls |= CLIFF;
		}
		const float d250 = -at(250.f), d500 = -at(500.f);
		if (!(b.cls & CLIFF) && (d250 > 0.f) && (d250 < BA_WADE_DEPTH) && (d500 < BA_WADE_DEPTH)) {
			b.cls |= WADING;
		}
		bool ship = false, deep = false;
		const int r = int(BA_NEAR_WATER / cellSize);
		const int x0 = int(b.pos.x) / cellSize, z0 = int(b.pos.z) / cellSize;
		for (int z = std::max(0, z0 - r); z <= std::min(gh - 1, z0 + r); ++z) {
			for (int x = std::max(0, x0 - r); x <= std::min(gw - 1, x0 + r); ++x) {
				const int c = z * gw + x;
				ship |= IsHostileWater(body8[c], false);
				deep |= IsHostileWater(body15[c], true);
			}
		}
		if (ship) b.cls |= SHIP_WATER;
		if (deep) b.cls |= DEEP_WATER;
		if ((ship || deep) && (grade <= BA_HOVER_GRADE)) b.cls |= HOVER_BEACH;
		beaches.push_back(b);
	}
	circuit->LOG("BATTLE: %i beach segments within %i of (%i, %i)", (int)beaches.size(), int(radius), int(centre.x), int(centre.z));
	return (int)beaches.size();
}

AIFloat3 CBattleAnalysis::GetBeachPos(int i) const { return ((i >= 0) && (i < (int)beaches.size())) ? beaches[i].pos : AIFloat3(-1.f, 0.f, 0.f); }
AIFloat3 CBattleAnalysis::GetBeachSeaward(int i) const { return ((i >= 0) && (i < (int)beaches.size())) ? beaches[i].seaward : AIFloat3(1.f, 0.f, 0.f); }
int CBattleAnalysis::GetBeachClass(int i) const { return ((i >= 0) && (i < (int)beaches.size())) ? beaches[i].cls : 0; }
float CBattleAnalysis::GetBeachHeat(int i) const { return ((i >= 0) && (i < (int)beaches.size())) ? beaches[i].heat : 0.f; }

float CBattleAnalysis::GetBeachDepth(int i, float out) const
{
	if ((i < 0) || (i >= (int)beaches.size())) {
		return 0.f;
	}
	const SBeach& b = beaches[i];
	return -Height(AIFloat3(b.pos.x + b.seaward.x * out, 0.f, b.pos.z + b.seaward.z * out));
}

} // namespace circuit
