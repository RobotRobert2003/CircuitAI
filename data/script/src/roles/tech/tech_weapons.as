// TECH's weapon clusters (D-126): doc/roles/tech-weapon-clusters.md.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../manager/builder.as"
#include "../../systems/construction/layout.as"
#include "../../systems/combat/spam.as"
#include "tech_forward.as"
#include "tech_factories.as"

/******************************************************************************

TECH WEAPON CLUSTERS (D-126)

A weapon cluster is an anchor, a set of slots (a weapon, a wall, a sensor or
a construction turret each) laid out when the cluster is found, and a
priority. The owner's rules:
  - no weapon cluster before +200 metal income (WeaponStartMetalIncome), and
    each kind waits for its own income gate;
  - clusters are found at strategic defence points and re-ranked as the game
    goes (every WeaponReplanSeconds): chokes on the enemy's approach routes,
    the assets enemy aircraft come for, high ground over a kill zone, the
    long-range band 20% to 40% of a cannon's range back from an active combat
    zone, the beaches enemy ships and amphibious units can land on;
  - every cluster has at least 4 construction turrets;
  - whatever fires over walls is walled in; direct fire gets wall rows in front;
    walls and turrets never stand on a friendly lane;
  - the super cannon: +500 metal to start (+1000 ideally), every air
    constructor on it the moment it is framed, and its escort: advanced
    energy storage for a full shot, dense forward flak, long-range AA,
    deflectors, anti-nuke.
Every setting is in Global::RoleSettings::Tech and data/config/weapons.json.
Analysis (routes, chokes, heat, composition, water, beaches) is native:
aiBattle, src/circuit/terrain/BattleAnalysis.cpp.

******************************************************************************/
namespace TechWeapons {

    // cluster kinds
    const int RANGE_WATER = 2;
    const int KILL = 0;
    const int AIR = 1;
    const int ARTY = 2;
    const int LRPC = 3;
    const int SUPER = 4;
    const int COAST = 5;
    const array<string> KIND_NAMES = {"kill zone", "air defence", "artillery", "long range", "super cannon", "coast"};

    // enemy composition classes (CBattleAnalysis::Kind)
    const int E_LAND = 0, E_AIR = 1, E_SHIP = 2, E_SUB = 3, E_HOVER = 4, E_AMPH = 5, E_ARTY = 6,
              E_STATIC = 7, E_HEAVY = 8, E_NUKE = 9, E_LRPC = 10;
    // beach classes (CBattleAnalysis::Beach)
    const int B_CLIFF = 1, B_WADING = 2, B_SHIP = 4, B_DEEP = 8, B_HOVER = 16;

    float Mx(float a, float b) { return a > b ? a : b; }
    float Mn(float a, float b) { return a < b ? a : b; }
    int Mx(int a, int b) { return a > b ? a : b; }
    int Mn(int a, int b) { return a < b ? a : b; }

    bool loaded = false;
    void LoadSettings()
    {
        if (loaded) return;
        loaded = true;
        // one line per JSON key: data/config/weapons.json, the defaults in global.as
        Global::RoleSettings::Tech::WeaponWallFrontRadius = aiSetupMgr.ConfigFloat("weapons/front/wall_front_radius", Global::RoleSettings::Tech::WeaponWallFrontRadius);
        Global::RoleSettings::Tech::WeaponGroundFrontRadius = aiSetupMgr.ConfigFloat("weapons/front/ground_front_radius", Global::RoleSettings::Tech::WeaponGroundFrontRadius);
        Global::RoleSettings::Tech::WeaponArmadaEmpCount = aiSetupMgr.ConfigInt("weapons/front/armada_emp_count", Global::RoleSettings::Tech::WeaponArmadaEmpCount);
        Global::RoleSettings::Tech::WeaponCortexTacticalCount = aiSetupMgr.ConfigInt("weapons/front/cortex_tactical_count", Global::RoleSettings::Tech::WeaponCortexTacticalCount);
        Global::RoleSettings::Tech::WeaponLegionPerditionCount = aiSetupMgr.ConfigInt("weapons/front/legion_perdition_count", Global::RoleSettings::Tech::WeaponLegionPerditionCount);
        Global::RoleSettings::Tech::WeaponSpecialSpacing = aiSetupMgr.ConfigFloat("weapons/front/special_spacing", Global::RoleSettings::Tech::WeaponSpecialSpacing);
        Global::RoleSettings::Tech::WeaponGeoClusterRadius = aiSetupMgr.ConfigFloat("weapons/front/geo_cluster_radius", Global::RoleSettings::Tech::WeaponGeoClusterRadius);
        Global::RoleSettings::Tech::WeaponClustersEnabled = aiSetupMgr.ConfigBool("weapons/enabled", Global::RoleSettings::Tech::WeaponClustersEnabled);
        Global::RoleSettings::Tech::WeaponStartMetalIncome = aiSetupMgr.ConfigFloat("weapons/start_metal_income", Global::RoleSettings::Tech::WeaponStartMetalIncome);
        Global::RoleSettings::Tech::WeaponBudgetShare = aiSetupMgr.ConfigFloat("weapons/budget/share", Global::RoleSettings::Tech::WeaponBudgetShare);
        Global::RoleSettings::Tech::WeaponBudgetShareAttacked = aiSetupMgr.ConfigFloat("weapons/budget/share_attacked", Global::RoleSettings::Tech::WeaponBudgetShareAttacked);
        Global::RoleSettings::Tech::WeaponBudgetWindowSeconds = aiSetupMgr.ConfigFloat("weapons/budget/window_seconds", Global::RoleSettings::Tech::WeaponBudgetWindowSeconds);
        Global::RoleSettings::Tech::WeaponAttackedHeat = aiSetupMgr.ConfigFloat("weapons/budget/attacked_heat", Global::RoleSettings::Tech::WeaponAttackedHeat);
        Global::RoleSettings::Tech::WeaponBaseRadius = aiSetupMgr.ConfigFloat("weapons/budget/base_radius", Global::RoleSettings::Tech::WeaponBaseRadius);
        Global::RoleSettings::Tech::WeaponMaxConcurrent = aiSetupMgr.ConfigInt("weapons/budget/max_concurrent", Global::RoleSettings::Tech::WeaponMaxConcurrent);
        Global::RoleSettings::Tech::WeaponKillMinIncome = aiSetupMgr.ConfigFloat("weapons/gates/kill_zone", Global::RoleSettings::Tech::WeaponKillMinIncome);
        Global::RoleSettings::Tech::WeaponAirMinIncome = aiSetupMgr.ConfigFloat("weapons/gates/air_defence", Global::RoleSettings::Tech::WeaponAirMinIncome);
        Global::RoleSettings::Tech::WeaponCoastMinIncome = aiSetupMgr.ConfigFloat("weapons/gates/coast", Global::RoleSettings::Tech::WeaponCoastMinIncome);
        Global::RoleSettings::Tech::WeaponArtyMinIncome = aiSetupMgr.ConfigFloat("weapons/gates/artillery", Global::RoleSettings::Tech::WeaponArtyMinIncome);
        Global::RoleSettings::Tech::WeaponLrpcMinIncome = aiSetupMgr.ConfigFloat("weapons/gates/long_range", Global::RoleSettings::Tech::WeaponLrpcMinIncome);
        Global::RoleSettings::Tech::WeaponMaxKill = aiSetupMgr.ConfigInt("weapons/max/kill_zone", Global::RoleSettings::Tech::WeaponMaxKill);
        Global::RoleSettings::Tech::WeaponMaxAir = aiSetupMgr.ConfigInt("weapons/max/air_defence", Global::RoleSettings::Tech::WeaponMaxAir);
        Global::RoleSettings::Tech::WeaponMaxCoast = aiSetupMgr.ConfigInt("weapons/max/coast", Global::RoleSettings::Tech::WeaponMaxCoast);
        Global::RoleSettings::Tech::WeaponMaxArty = aiSetupMgr.ConfigInt("weapons/max/artillery", Global::RoleSettings::Tech::WeaponMaxArty);
        Global::RoleSettings::Tech::WeaponMaxLrpc = aiSetupMgr.ConfigInt("weapons/max/long_range", Global::RoleSettings::Tech::WeaponMaxLrpc);
        Global::RoleSettings::Tech::WeaponMaxSuper = aiSetupMgr.ConfigInt("weapons/max/super", Global::RoleSettings::Tech::WeaponMaxSuper);
        Global::RoleSettings::Tech::WeaponNanoPerCluster = aiSetupMgr.ConfigInt("weapons/cluster/nanos", Global::RoleSettings::Tech::WeaponNanoPerCluster);
        Global::RoleSettings::Tech::WeaponWorkRadius = aiSetupMgr.ConfigFloat("weapons/cluster/work_radius", Global::RoleSettings::Tech::WeaponWorkRadius);
        Global::RoleSettings::Tech::WeaponCriticalSpacing = aiSetupMgr.ConfigFloat("weapons/cluster/critical_spacing", Global::RoleSettings::Tech::WeaponCriticalSpacing);
        Global::RoleSettings::Tech::WeaponAirSpacing = aiSetupMgr.ConfigFloat("weapons/cluster/air_spacing", Global::RoleSettings::Tech::WeaponAirSpacing);
        Global::RoleSettings::Tech::SuperMinMetalIncome = aiSetupMgr.ConfigFloat("weapons/super/min_metal_income", Global::RoleSettings::Tech::SuperMinMetalIncome);
        Global::RoleSettings::Tech::SuperIdealMetalIncome = aiSetupMgr.ConfigFloat("weapons/super/ideal_metal_income", Global::RoleSettings::Tech::SuperIdealMetalIncome);
        Global::RoleSettings::Tech::SuperMinNeed = aiSetupMgr.ConfigFloat("weapons/super/min_need", Global::RoleSettings::Tech::SuperMinNeed);
        Global::RoleSettings::Tech::SuperEnergySpareFactor = aiSetupMgr.ConfigFloat("weapons/super/energy_spare_factor", Global::RoleSettings::Tech::SuperEnergySpareFactor);
        Global::RoleSettings::Tech::SuperStorageMin = aiSetupMgr.ConfigInt("weapons/super/storage_min", Global::RoleSettings::Tech::SuperStorageMin);
        Global::RoleSettings::Tech::SuperStorageMargin = aiSetupMgr.ConfigFloat("weapons/super/storage_margin", Global::RoleSettings::Tech::SuperStorageMargin);
        Global::RoleSettings::Tech::SuperFlakCount = aiSetupMgr.ConfigInt("weapons/super/flak", Global::RoleSettings::Tech::SuperFlakCount);
        Global::RoleSettings::Tech::SuperLongRangeAACount = aiSetupMgr.ConfigInt("weapons/super/long_range_aa", Global::RoleSettings::Tech::SuperLongRangeAACount);
        Global::RoleSettings::Tech::SuperDeflectorCount = aiSetupMgr.ConfigInt("weapons/super/deflectors", Global::RoleSettings::Tech::SuperDeflectorCount);
        Global::RoleSettings::Tech::SuperAntiNukeCount = aiSetupMgr.ConfigInt("weapons/super/anti_nukes", Global::RoleSettings::Tech::SuperAntiNukeCount);
        Global::RoleSettings::Tech::SuperNanoCount = aiSetupMgr.ConfigInt("weapons/super/nanos", Global::RoleSettings::Tech::SuperNanoCount);
        Global::RoleSettings::Tech::SuperRadarCount = aiSetupMgr.ConfigInt("weapons/super/radars", Global::RoleSettings::Tech::SuperRadarCount);
        Global::RoleSettings::Tech::SuperBandMin = aiSetupMgr.ConfigFloat("weapons/super/band_min", Global::RoleSettings::Tech::SuperBandMin);
        Global::RoleSettings::Tech::SuperBandMax = aiSetupMgr.ConfigFloat("weapons/super/band_max", Global::RoleSettings::Tech::SuperBandMax);
        Global::RoleSettings::Tech::SuperEscortRadius = aiSetupMgr.ConfigFloat("weapons/super/escort_radius", Global::RoleSettings::Tech::SuperEscortRadius);
        Global::RoleSettings::Tech::SuperEscortSeconds = aiSetupMgr.ConfigInt("weapons/super/escort_seconds", Global::RoleSettings::Tech::SuperEscortSeconds);
        Global::RoleSettings::Tech::WeaponLrpcBandMin = aiSetupMgr.ConfigFloat("weapons/long_range/band_min", Global::RoleSettings::Tech::WeaponLrpcBandMin);
        Global::RoleSettings::Tech::WeaponLrpcBandMax = aiSetupMgr.ConfigFloat("weapons/long_range/band_max", Global::RoleSettings::Tech::WeaponLrpcBandMax);
        Global::RoleSettings::Tech::WeaponReplanSeconds = aiSetupMgr.ConfigFloat("weapons/analysis/replan_seconds", Global::RoleSettings::Tech::WeaponReplanSeconds);
        Global::RoleSettings::Tech::WeaponAnalyseSeconds = aiSetupMgr.ConfigFloat("weapons/analysis/analyse_seconds", Global::RoleSettings::Tech::WeaponAnalyseSeconds);
        Global::RoleSettings::Tech::WeaponRouteAlternatives = aiSetupMgr.ConfigInt("weapons/analysis/route_alternatives", Global::RoleSettings::Tech::WeaponRouteAlternatives);
        Global::RoleSettings::Tech::WeaponChokeHalfWidth = aiSetupMgr.ConfigFloat("weapons/analysis/choke_half_width", Global::RoleSettings::Tech::WeaponChokeHalfWidth);
        Global::RoleSettings::Tech::WeaponChokeMerge = aiSetupMgr.ConfigFloat("weapons/analysis/choke_merge", Global::RoleSettings::Tech::WeaponChokeMerge);
        Global::RoleSettings::Tech::WeaponKillShareMin = aiSetupMgr.ConfigFloat("weapons/analysis/kill_share_min", Global::RoleSettings::Tech::WeaponKillShareMin);
        Global::RoleSettings::Tech::WeaponKillShareMax = aiSetupMgr.ConfigFloat("weapons/analysis/kill_share_max", Global::RoleSettings::Tech::WeaponKillShareMax);
        Global::RoleSettings::Tech::WeaponCombatMinHeat = aiSetupMgr.ConfigFloat("weapons/analysis/combat_min_heat", Global::RoleSettings::Tech::WeaponCombatMinHeat);
        Global::RoleSettings::Tech::WeaponCombatHalfLife = aiSetupMgr.ConfigFloat("weapons/analysis/combat_half_life", Global::RoleSettings::Tech::WeaponCombatHalfLife);
        Global::RoleSettings::Tech::WeaponAirHalfLife = aiSetupMgr.ConfigFloat("weapons/analysis/air_half_life", Global::RoleSettings::Tech::WeaponAirHalfLife);
        Global::RoleSettings::Tech::WeaponCoastRadius = aiSetupMgr.ConfigFloat("weapons/analysis/coast_radius", Global::RoleSettings::Tech::WeaponCoastRadius);
        Global::RoleSettings::Tech::WeaponEnemyCoastRadius = aiSetupMgr.ConfigFloat("weapons/analysis/enemy_coast_radius", Global::RoleSettings::Tech::WeaponEnemyCoastRadius);
        aiBattle.SetHeatHalfLife(Global::RoleSettings::Tech::WeaponCombatHalfLife, Global::RoleSettings::Tech::WeaponAirHalfLife);
        {   // the engine's range formula, checked on this map: flat ground should give the def's range
            const AIFloat3 b = Global::Map::StartPos;
            array<string> probe = {"lrpc", "art2", "llt", "super"};
            string s = "";
            for (uint i = 0; i < probe.length(); ++i) {
                CCircuitDef@ d = Def(probe[i]);
                if (d is null) continue;
                s += (s == "" ? "" : ", ") + d.GetName() + " " + int(aiBattle.MainRange(d)) + " -> " + int(aiBattle.EffectiveRange(d, b, AIFloat3(b.x + 100.0f, 0.0f, b.z)));
            }
            GenericHelpers::LogUtil("[TECH][Weapons] effective range beside the start: " + s + " (D-126)", 1);
        }
        GenericHelpers::LogUtil("[TECH][Weapons] settings: start +" + int(Global::RoleSettings::Tech::WeaponStartMetalIncome)
            + ", budget " + int(Global::RoleSettings::Tech::WeaponBudgetShare * 100) + "% (" + int(Global::RoleSettings::Tech::WeaponBudgetShareAttacked * 100)
            + "% attacked), super +" + int(Global::RoleSettings::Tech::SuperMinMetalIncome) + "/+" + int(Global::RoleSettings::Tech::SuperIdealMetalIncome)
            + ", " + Global::RoleSettings::Tech::WeaponNanoPerCluster + " turrets a cluster (D-126)", 1);
    }

    // ---------------------------------------------------------------- units by side

    // a role name -> the side's unit ("" when the side has none)
    //                              role        armada          cortex          legion
    const array<string> ROLES = {"llt",      "beamer",     "hlt",      "popup",    "t2pop",        "heavy",      "art1",       "art2",
                                 "lrpc",     "super",      "aal",      "aah",      "flak",         "lraa",       "antinuke",   "shield",
                                 "estor",    "teeth",      "fort",     "radar",    "radar2",       "nano",       "torp1",      "torp2",
                                 "dcharge",  "fhlt",       "fheavy",   "sonar",    "fteeth",       "targ"};
    const array<string> ARM   = {"armllt",   "armbeamer",  "armhlt",   "armclaw",  "armpb",        "armanni",    "",   "armamb",
                                 "armbrtha", "armvulc",    "armrl",    "armcir",   "armflak",      "armmercury", "armamd",     "armgate",
                                 "armuwadves","armdrag",   "armfort",  "armrad",   "armarad",      "armnanotc",  "armtl",      "armatl",
                                 "armdl",    "armfhlt",    "armkraken","armsonar", "armfdrag",     "armtarg"};
    const array<string> COR   = {"corllt",   "corhllt",    "corhlt",   "cormaw",   "corvipe",      "cordoom",    "",     "cortoast",
                                 "corint",   "corbuzz",    "corrl",    "corerad",  "corflak",      "corscreamer","corfmd",     "corgate",
                                 "coruwadves","cordrag",   "corfort",  "corrad",   "corarad",      "cornanotc",  "cortl",      "coratl",
                                 "cordl",    "corfhlt",    "corfdoom", "corsonar", "corfdrag",     "cortarg"};
    const array<string> LEG   = {"leglht",   "leglht",     "legmg",    "legdtr",   "legapopupdef", "legbastion", "", "legacluster",
                                 "leglrpc",  "legstarfall","legrl",    "leglupara","legflak",      "leglraa",    "legabm",     "legdeflector",
                                 "legadvestore","legdrag", "legforti", "legrad",   "legarad",      "legnanotc",  "legtl",      "leganavaltorpturret",
                                 "legctl",   "legfmg",     "legfmg",   "legfrad",  "legfdrag",     "legtarg"};
    string UnitName(const string &in role)
    {
        if (role == "special") return Global::AISettings::Side == "armada" ? "armemp"
            : Global::AISettings::Side == "cortex" ? "cortron" : "legperdition";
        if (role == "geoartillery") return Global::AISettings::Side == "cortex" ? "corbhmth" : "";
        const int i = ROLES.find(role);
        if (i < 0) return "";
        const string s = Global::AISettings::Side;
        if (s == "armada") return ARM[i];
        if (s == "cortex") return COR[i];
        return LEG[i];
    }
    CCircuitDef@ Def(const string &in role)
    {
        const string n = UnitName(role);
        return (n == "") ? null : ai.GetCircuitDef(n);
    }

    bool DirectFire(const string &in role)
    {
        return role == "llt" || role == "beamer" || role == "hlt" || role == "popup" || role == "heavy" || role == "aal" || role == "aah";
    }
    bool IsWall(const string &in role) { return role == "teeth" || role == "fort" || role == "fteeth"; }
    bool IsTorp(const string &in role) { return role == "torp1" || role == "torp2" || role == "dcharge"; }

    Task::BuildType TypeOf(const string &in role)
    {
        if (role == "nano") return Task::BuildType::NANO;
        if (role == "estor") return Task::BuildType::STORE;
        if (role == "radar" || role == "radar2") return Task::BuildType::RADAR;
        if (role == "sonar") return Task::BuildType::SONAR;
        if (role == "geoartillery") return Task::BuildType::GEO;
        if (role == "special" || role == "lrpc" || role == "super" || role == "antinuke") return Task::BuildType::BIG_GUN;
        return Task::BuildType::DEFENCE;
    }

    // ---------------------------------------------------------------- clusters

    class Slot {
        string role;
        AIFloat3 pos;
        bool dead = false;
        int orderedFrame = -100000;
        int standFrame = -1;
        Slot(const string &in r, const AIFloat3& in p) { role = r; pos = p; }
    }

    class WCluster {
        int id;
        int kind;
        string key;          // the strategic point it defends: kind and cell
        AIFloat3 pos;        // anchor
        AIFloat3 dir;        // toward the threat
        float siteScore = 1.0f;
        float priority = 0.0f;
        string why;
        array<Slot@> slots;
        int created;
        int seen;            // the last replan that found its point again
        bool stale = false;  // its point is gone (the fighting moved): no new orders
        int reshapes = 0;    // Upkeep's relays
    }

    array<WCluster@> clusters;
    int nextId = 1;
    int lastReplan = -100000;
    int lastAnalyse = -100000;
    int lastTick = 0;
    float tokens = 0.0f;
    bool announcedGate = false;
    int lastBudgetLog = -100000;

    float MetalIncome() { return Economy::GetMinMetalIncomeLast10s(); }
    // Local AA remains available during the opening. Forward clusters wait
    // for the two economy aircraft to take over; ground weapons stay outside
    // the economy radius. O(1), evaluated before slot or reservation searches.
    int frontSnapshotFrame=-1;
    AIFloat3 frontSnapshot(-1,0,-1);
    bool NearFront(const AIFloat3 &in position, float radius)
    {
        // One lane selection per used frame, then O(1) per wall/slot. No unit
        // scans or new periodic job. A failed lane never falls back to home.
        if (frontSnapshotFrame != ai.frame) {
            frontSnapshotFrame=ai.frame; frontSnapshot=AIFloat3(-1,0,-1);
            const int lane=Lanes::BestLane(Lanes::BOT);
            if (lane>=0) {
                const float observed=aiBattle.GetLaneFront(lane);
                frontSnapshot=aiBattle.GetLanePoint(lane,observed>=0 ? observed : 0.5f);
            }
        }
        return frontSnapshot.x>=0 && MapHelpers::SqDist(position,frontSnapshot)<=radius*radius;
    }
    bool PlacementReleased(int kind, const AIFloat3 &in position)
    {
        if (Global::AISettings::Role != AiRole::TECH) return true;
        const bool local = position.distance2D(Base()) < Global::RoleSettings::Tech::WeaponBaseRadius;
        return kind == AIR && local || TechForward::T2Released() && (kind == AIR || !local)
            && (kind != KILL && kind != ARTY && kind != COAST
                || NearFront(position,Global::RoleSettings::Tech::WeaponGroundFrontRadius));
    }
    // owner: under the experimental build system only (TECH's; other roles may use it later)
    bool Enabled() { return Global::RoleSettings::Tech::WeaponClustersEnabled && Global::RoleSettings::Tech::ExperimentalBuild; }
    bool Active() { return Enabled() && MetalIncome() >= Global::RoleSettings::Tech::WeaponStartMetalIncome; }

    float Gate(int kind)
    {
        switch (kind) {
            case KILL: return Global::RoleSettings::Tech::WeaponKillMinIncome;
            case AIR: return Global::RoleSettings::Tech::WeaponAirMinIncome;
            case ARTY: return Global::RoleSettings::Tech::WeaponArtyMinIncome;
            case LRPC: return Global::RoleSettings::Tech::WeaponLrpcMinIncome;
            case SUPER: return Global::RoleSettings::Tech::SuperMinMetalIncome;
            case COAST: return Global::RoleSettings::Tech::WeaponCoastMinIncome;
        }
        return 1e9f;
    }
    int MaxOf(int kind)
    {
        switch (kind) {
            case KILL: return Global::RoleSettings::Tech::WeaponMaxKill;
            case AIR: return Global::RoleSettings::Tech::WeaponMaxAir;
            case ARTY: return Global::RoleSettings::Tech::WeaponMaxArty;
            case LRPC: return Global::RoleSettings::Tech::WeaponMaxLrpc;
            case SUPER: return Global::RoleSettings::Tech::WeaponMaxSuper;
            case COAST: return Global::RoleSettings::Tech::WeaponMaxCoast;
        }
        return 0;
    }
    int CountKind(int kind)
    {
        int n = 0;
        for (uint i = 0; i < clusters.length(); ++i) if (clusters[i].kind == kind) ++n;
        return n;
    }

    // ---------------------------------------------------------------- need (composition and behaviour)

    float Share(float part, float whole) { return (whole > 1.0f) ? part / whole : 0.0f; }
    float Need(int kind)
    {
        const float land = aiBattle.EnemyCost(E_LAND), air = aiBattle.EnemyCost(E_AIR), ship = aiBattle.EnemyCost(E_SHIP),
                    sub = aiBattle.EnemyCost(E_SUB), hover = aiBattle.EnemyCost(E_HOVER), amph = aiBattle.EnemyCost(E_AMPH),
                    arty = aiBattle.EnemyCost(E_ARTY), stat = aiBattle.EnemyCost(E_STATIC), heavy = aiBattle.EnemyCost(E_HEAVY),
                    lrpc = aiBattle.EnemyCost(E_LRPC);
        const float mobile = land + air + ship + sub + hover + amph;
        const float artyShare = Share(arty, mobile);
        switch (kind) {
            // artillery beats statics that cannot answer: fewer kill zones against it
            case KILL:  return (0.6f + 1.5f * Share(land + amph + hover, mobile) + Share(heavy, mobile)) * (1.0f - 0.5f * artyShare);
            case AIR:   return 0.4f + 2.0f * Share(air, mobile);
            case ARTY:  return (0.4f + Share(stat, mobile + stat) + Share(land, mobile)) * (1.0f - Share(air, mobile));
            case LRPC:  return 0.4f + Share(stat + lrpc, mobile + stat + lrpc) + Share(ship, mobile) + artyShare;
            case SUPER: return 0.5f + Share(stat + lrpc, mobile + stat + lrpc) + ((MetalIncome() >= Global::RoleSettings::Tech::SuperIdealMetalIncome) ? 1.0f : 0.0f);
            case COAST: return 0.3f + 2.0f * Share(ship + sub + hover + amph, mobile) + ((heavy > 0.0f && amph > 0.0f) ? 1.0f : 0.0f);
        }
        return 0.0f;
    }

    // ---------------------------------------------------------------- analysis

    AIFloat3 Base() { return Layout::BaseCentre(); }
    bool OnMap(const AIFloat3& in p) { return p.x > 64.0f && p.z > 64.0f && p.x < float(AiTerrainWidth()) - 64.0f && p.z < float(AiTerrainHeight()) - 64.0f; }
    AIFloat3 Along(const AIFloat3& in p, const AIFloat3& in dir, float d, float lateral)
    {
        return AIFloat3(p.x + dir.x * d - dir.z * lateral, 0.0f, p.z + dir.z * d + dir.x * lateral);
    }
    AIFloat3 Norm(const AIFloat3& in a, const AIFloat3& in b)   // a -> b, flat
    {
        float dx = b.x - a.x, dz = b.z - a.z;
        float l = sqrt(dx * dx + dz * dz);
        if (l < 1.0f) return AIFloat3(1.0f, 0.0f, 0.0f);
        return AIFloat3(dx / l, 0.0f, dz / l);
    }

    void Analyse()
    {
        array<AIFloat3> enemies = Lanes::EnemyStarts();   // D-127: the spots in the enemy's start boxes
        aiBattle.ClearSources();
        for (uint i = 0; i < enemies.length(); ++i) {
            aiBattle.AddSource(enemies[i]);
            aiBattle.MarkHostileWater(enemies[i], Global::RoleSettings::Tech::WeaponEnemyCoastRadius);
        }
        const int chokes = aiBattle.Analyse(Base(), Global::RoleSettings::Tech::WeaponRouteAlternatives,
            Global::RoleSettings::Tech::WeaponChokeHalfWidth, Global::RoleSettings::Tech::WeaponChokeMerge);
        const int beaches = aiBattle.AnalyseBeaches(Base(), Global::RoleSettings::Tech::WeaponCoastRadius);
        lastAnalyse = ai.frame;
        GenericHelpers::LogUtil("[TECH][Weapons] analysis: " + enemies.length() + " enemy starts, " + aiBattle.GetRouteCount() + " routes, "
            + chokes + " chokes, " + beaches + " beach segments (D-126)", 1);
    }

    // the active combat zone nearest the base, else the front
    // (played: a raid on the base made the base the combat zone, and the LRPC
    // site went behind it to the map edge; fighting within WeaponBaseRadius of
    // the base is base defence, not the front)
    AIFloat3 CombatZone()
    {
        const AIFloat3 base = Base();
        const AIFloat3 front = Layout::FrontTarget();
        const float r = Global::RoleSettings::Tech::WeaponBaseRadius;
        // step from the base toward the front, taking the first hot cell beyond the base radius
        AIFloat3 dir = Norm(base, front);
        for (float d = r; d < base.distance2D(front) + 4000.0f; d += 512.0f) {
            AIFloat3 p = Along(base, dir, d, 0.0f);
            if (!OnMap(p)) break;
            if (aiBattle.CombatHeat(p, 768.0f) >= Global::RoleSettings::Tech::WeaponCombatMinHeat) return p;
        }
        AIFloat3 z = aiBattle.CombatNear(front, Global::RoleSettings::Tech::WeaponCombatMinHeat);
        return (z.x < 0.0f || z.distance2D(base) < r) ? front : z;
    }

    // ---------------------------------------------------------------- discovery

    class Candidate {
        int kind;
        string key;
        AIFloat3 pos;
        AIFloat3 dir;
        float score;
        string why;
    }

    string Key(int kind, const AIFloat3& in p, float cell) { return "" + kind + ":" + int(p.x / cell) + ":" + int(p.z / cell); }

    void Discover(array<Candidate@>@ found)
    {
        const AIFloat3 base = Base();
        // One lane selection per existing replan, not per builder or slot.
        // Negative front means no observed enemy yet: use the lane midpoint.
        // Keep the centre on our side and offset laterally; slot-level lane,
        // threat and reservation checks remain authoritative.
        const int selectedLane=Global::AISettings::Role==AiRole::TECH && TechForward::T2Released() ? Lanes::BestLane(Lanes::BOT) : -1;
        if (Global::AISettings::Role==AiRole::TECH && selectedLane>=0 && TechForward::T2Released()) {
            const float length=aiBattle.GetLaneLength(selectedLane);
            const float observedFront=aiBattle.GetLaneFront(selectedLane);
            const float frontShare=observedFront>=0.0f ? observedFront : 0.5f;
            const float share=Mx(0.0f,frontShare-Global::RoleSettings::Tech::WeaponLaneFrontReserve/Mx(1.0f,length));
            const AIFloat3 centre=aiBattle.GetLanePoint(selectedLane,share);
            const AIFloat3 toward=aiBattle.GetLanePoint(selectedLane,Mn(1.0f,frontShare));
            const AIFloat3 direction=Norm(centre,toward);
            Candidate@ candidate=Candidate();
            candidate.kind=KILL;
            candidate.pos=Along(centre,direction,0.0f,aiBattle.GetLaneWidth(selectedLane)*0.5f+Global::RoleSettings::Tech::WeaponLaneSideOffset);
            candidate.dir=direction; candidate.score=1.0f;
            candidate.key=Key(KILL,candidate.pos,512.0f);
            candidate.why="selected lane "+selectedLane+" behind observed front";
            if (OnMap(candidate.pos) && candidate.pos.distance2D(base)>=Global::RoleSettings::Tech::WeaponBaseRadius) {
                found.insertLast(candidate);
                Candidate@ artillery = Candidate();
                artillery.kind = ARTY;
                artillery.pos = Along(candidate.pos, direction, -Global::RoleSettings::Tech::WeaponLaneFrontReserve, 0.0f);
                artillery.dir = direction; artillery.score = candidate.score;
                artillery.key = Key(ARTY, artillery.pos, 512.0f);
                artillery.why = candidate.why;
                if (OnMap(artillery.pos)) found.insertLast(artillery);
            }
        }
        // kill zones: chokes on the routes, our side of the middle
        for (int i = 0; i < aiBattle.GetChokeCount(); ++i) {
            if (Global::AISettings::Role==AiRole::TECH) break; // TECH uses the chosen forward lane above
            const float sh = aiBattle.GetChokeShare(i);
            if (sh < Global::RoleSettings::Tech::WeaponKillShareMin || sh > Global::RoleSettings::Tech::WeaponKillShareMax) continue;
            const AIFloat3 p = aiBattle.GetChokePos(i);
            Candidate@ c = Candidate();
            c.kind = KILL; c.pos = p; c.dir = aiBattle.GetChokeDir(i);
            c.score = (1.0f + aiBattle.GetChokeHeat(i)) * (1.0f + 0.02f * aiBattle.CombatHeat(p, 1024.0f)) / (1.0f + aiBattle.SurfThreat(p) * 0.01f);
            c.key = Key(KILL, p, 512.0f);
            c.why = "choke " + int(aiBattle.GetChokeWidth(i)) + " wide, " + int(aiBattle.GetChokeHeat(i)) + " route(s), " + int(sh * 100) + "% out";
            found.insertLast(c);
        }
        // air defence: the assets enemy aircraft come for, weighted by the air heat near them
        array<AIFloat3> assets = {base};
        if (Layout::factoryCentre.x > 0.0f) assets.insertLast(Layout::factoryCentre);
        array<TechForward::MexCluster@> mc = TechForward::Clusters();
        for (uint i = 0; i < mc.length(); ++i) if (mc[i].n >= 2) assets.insertLast(mc[i].c);
        for (uint i = 0; i < TechFactories::clusters.length(); ++i) assets.insertLast(TechFactories::clusters[i].pos);
        for (uint i = 0; i < assets.length(); ++i) {
            const AIFloat3 a = assets[i];
            if (EcoFlak::OwnsArea(a)) continue; // economy perimeter has one flak owner
            AIFloat3 from = aiBattle.AirCentre(a, 4000.0f);
            if (from.x < 0.0f) from = Layout::FrontTarget();
            Candidate@ c = Candidate();
            c.kind = AIR; c.pos = a; c.dir = Norm(a, from);
            c.score = (i == 0 ? 2.0f : 1.0f) * (1.0f + 0.05f * aiBattle.AirHeat(a, 1500.0f));
            c.key = Key(AIR, a, 768.0f);
            c.why = (i == 0 ? "the base" : "an asset group") + ", air heat " + int(aiBattle.AirHeat(a, 1500.0f));
            found.insertLast(c);
        }
        // artillery: high ground behind each kill-zone choke, in range of it
        CCircuitDef@ art = Def("art2");
        if (art !is null) {
            for (int i = 0; i < aiBattle.GetChokeCount(); ++i) {
                if (Global::AISettings::Role == AiRole::TECH) break;
                const float sh = aiBattle.GetChokeShare(i);
                if (sh < Global::RoleSettings::Tech::WeaponKillShareMin || sh > Global::RoleSettings::Tech::WeaponKillShareMax + 0.15f) continue;
                const AIFloat3 k = aiBattle.GetChokePos(i);
                const AIFloat3 back = Norm(k, base);
                float best = -1.0f; AIFloat3 bp;
                for (int a = -3; a <= 3; ++a) {
                    for (int r = 0; r < 3; ++r) {
                        AIFloat3 p = Along(k, back, 500.0f + 250.0f * r, 220.0f * a);
                        if (!OnMap(p)) continue;
                        const float reach = aiBattle.EffectiveRange(art, p, k);
                        if (reach < p.distance2D(k) * 1.05f) continue;
                        const float s = (1.0f + Mx(0.0f, aiBattle.HeightAbove(p, 400.0f)) * 0.01f) * reach / (1.0f + aiBattle.SurfThreat(p) * 0.02f);
                        if (s > best) { best = s; bp = p; }
                    }
                }
                if (best < 0.0f) continue;
                Candidate@ c = Candidate();
                c.kind = ARTY; c.pos = bp; c.dir = Norm(bp, k); c.score = best / 1000.0f * (1.0f + aiBattle.GetChokeHeat(i));
                c.key = Key(ARTY, k, 512.0f);
                c.why = "high ground over the choke at (" + int(k.x) + ", " + int(k.z) + "), height " + int(aiBattle.HeightAbove(bp, 400.0f));
                found.insertLast(c);
            }
        }
        // long range and super cannon: the band behind the active combat zone
        BandCandidates(LRPC, Def("lrpc"), Global::RoleSettings::Tech::WeaponLrpcBandMin, Global::RoleSettings::Tech::WeaponLrpcBandMax, found);
        BandCandidates(SUPER, Def("super"), Global::RoleSettings::Tech::SuperBandMin, Global::RoleSettings::Tech::SuperBandMax, found);
        // coast: beach segments that face hostile water or carry a landing route
        for (int i = 0; i < aiBattle.GetBeachCount(); ++i) {
            const int cls = aiBattle.GetBeachClass(i);
            if ((cls & (B_SHIP | B_DEEP | B_HOVER | B_WADING)) == 0) continue;
            if ((cls & B_WADING) != 0 && (cls & (B_SHIP | B_DEEP)) == 0 && aiBattle.GetBeachHeat(i) <= 0.0f) continue;   // a quiet shallow shore: the land routes cover it
            const AIFloat3 p = aiBattle.GetBeachPos(i);
            Candidate@ c = Candidate();
            c.kind = COAST; c.pos = p; c.dir = aiBattle.GetBeachSeaward(i);
            c.score = (1.0f + aiBattle.GetBeachHeat(i)) * (((cls & B_DEEP) != 0) ? 1.5f : 1.0f) * 3000.0f / Mx(1000.0f, p.distance2D(base));
            c.key = Key(COAST, p, 512.0f);
            c.why = "beach" + (((cls & B_CLIFF) != 0) ? " cliff" : "") + (((cls & B_WADING) != 0) ? " wading" : "") + (((cls & B_SHIP) != 0) ? " ship-water" : "")
                + (((cls & B_DEEP) != 0) ? " deep-water" : "") + (((cls & B_HOVER) != 0) ? " hover" : "") + ", " + int(aiBattle.GetBeachHeat(i)) + " landing route(s)";
            found.insertLast(c);
        }
    }

    // the owner's band: 20% to 40% of the weapon's range back from the active combat zone
    void BandCandidates(int kind, CCircuitDef@ gun, float bandMin, float bandMax, array<Candidate@>@ found)
    {
        if (gun is null) return;
        const AIFloat3 zone = CombatZone();
        const AIFloat3 back = Norm(zone, Base());
        const float range = aiBattle.MainRange(gun) > 0.0f ? aiBattle.MainRange(gun) : 4000.0f;
        float best = -1.0f; AIFloat3 bp;
        for (int s = 0; s < 5; ++s) {
            const float d = range * (bandMin + (bandMax - bandMin) * s / 4.0f);
            for (int a = -4; a <= 4; ++a) {
                AIFloat3 p = Along(zone, back, d, 300.0f * a);
                if (!OnMap(p)) continue;
                if (aiBattle.SurfThreat(p) > 1.0f) continue;   // a safe area
                if (!CriticalSpaced(p)) continue;
                // reach past the fighting, height-boosted: the site's range toward the zone
                const AIFloat3 far = Along(zone, back, -range * 0.3f, 0.0f);
                // the height-boosted reach already carries the altitude (played: a
                // height factor on top logged 'reach 27404' for a 6200 reach)
                const float reach = aiBattle.EffectiveRange(gun, p, far);
                if (reach > best) { best = reach; bp = p; }
            }
        }
        if (best < 0.0f) return;
        Candidate@ c = Candidate();
        c.kind = kind; c.pos = bp; c.dir = Norm(bp, zone); c.score = best / range;
        c.key = Key(kind, zone, 1024.0f);
        c.why = int(bp.distance2D(zone)) + " back from the combat zone at (" + int(zone.x) + ", " + int(zone.z) + "), reach " + int(best) + ", height " + int(aiBattle.HeightAbove(bp, 600.0f));
        found.insertLast(c);
    }

    // no two critical structures within a nuke's AoE (W7)
    bool CriticalSpaced(const AIFloat3& in p)
    {
        const float s2 = Global::RoleSettings::Tech::WeaponCriticalSpacing * Global::RoleSettings::Tech::WeaponCriticalSpacing;
        for (uint i = 0; i < clusters.length(); ++i) {
            const int k = clusters[i].kind;
            if ((k == LRPC || k == SUPER) && clusters[i].pos.distance2D(p) * clusters[i].pos.distance2D(p) < s2) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------- the shape of each cluster

    void AddRing(WCluster@ c, const string &in role, const AIFloat3& in centre, float radius, float gap)
    {
        const int n = Mx(4, int(6.2832f * radius / gap));
        for (int k = 0; k < n; ++k) {
            const float a = 6.2832f * k / n;
            AIFloat3 p(centre.x + cos(a) * radius, 0.0f, centre.z + sin(a) * radius);
            if (OnMap(p) && !aiBattle.IsFriendlyLane(p) && WallHelpers::Allowed(Def(role),p)) c.slots.insertLast(Slot(role, p));
        }
    }
    // a staggered double row, 2 to 3 wall segments in front of a direct-fire turret
    void AddFrontRows(WCluster@ c, const AIFloat3& in at, const AIFloat3& in dir)
    {
        for (int row = 0; row < 2; ++row) {
            for (int k = -1; k <= 1; ++k) {
                AIFloat3 p = Along(at, dir, 72.0f + 32.0f * row, 32.0f * k + 16.0f * row);
                if (OnMap(p) && !aiBattle.IsFriendlyLane(p)) c.slots.insertLast(Slot("teeth", p));
            }
        }
    }
    void AddNanos(WCluster@ c, int n)
    {
        // two pairs on the cluster's safe side, within build range (400) of its pieces
        const AIFloat3 back(-c.dir.x, 0.0f, -c.dir.z);
        for (int k = 0; k < n; ++k) {
            const float lat = ((k % 2 == 0) ? -1.0f : 1.0f) * (90.0f + 70.0f * (k / 2));
            AIFloat3 p = Along(c.pos, back, 180.0f + 40.0f * (k / 4), lat);
            if (OnMap(p)) c.slots.insertLast(Slot("nano", p));
        }
    }
    void Shape(WCluster@ c)
    {
        const AIFloat3 p = c.pos, d = c.dir, back(-d.x, 0.0f, -d.z);
        const bool t2 = MetalIncome() >= Global::RoleSettings::Tech::WeaponArtyMinIncome;
        if (Global::AISettings::Role == AiRole::TECH && (c.kind == KILL || c.kind == ARTY)) AddFactionSupport(c);
        const bool heavy = aiBattle.EnemyCost(E_HEAVY) > 0.0f;
        const bool t2air = aiBattle.EnemyCost(E_AIR) > 3000.0f;
        if (c.kind == KILL) {
            // turrets on an arc behind the choke, facing it; fields of fire overlap on its centre
            array<string> ring = {"llt", "llt", "beamer", "llt", "llt", "hlt", "popup", "hlt"};
            if (t2) { ring.insertLast("t2pop"); ring.insertLast("t2pop"); }
            if (heavy) ring.insertLast("heavy");
            for (uint k = 0; k < ring.length(); ++k) {
                const float lat = ((k % 2 == 0) ? -1.0f : 1.0f) * (70.0f + 70.0f * (k / 2));
                AIFloat3 at = Along(p, back, 260.0f + 40.0f * (k % 3), lat);
                if (!OnMap(at) || aiBattle.IsFriendlyLane(at)) continue;
                c.slots.insertLast(Slot(ring[k], at));
                if (ring[k] == "heavy") AddRing(c,"fort",at,112.0f,32.0f);
                else if (DirectFire(ring[k])) AddFrontRows(c, at, d);
            }
            AIFloat3 ar = Along(p, back, 700.0f, 0.0f);
            if (OnMap(ar) && !aiBattle.IsFriendlyLane(ar)) { c.slots.insertLast(Slot("art2", ar)); AddRing(c, "teeth", ar, 72.0f, 32.0f); }
            c.slots.insertLast(Slot("aah", Along(p, back, 420.0f, 160.0f)));
            c.slots.insertLast(Slot("radar", Along(p, back, 480.0f, -180.0f)));
            AddNanos(c, Global::RoleSettings::Tech::WeaponNanoPerCluster);
        } else if (c.kind == AIR) {
            // AA between the asset and the air approach, spaced so one pass kills one piece
            const float sp = Global::RoleSettings::Tech::WeaponAirSpacing;
            const int flak = t2 ? 3 : 0;
            for (int k = 0; k < flak; ++k) {
                AIFloat3 at = Along(p, d, 420.0f, sp * (k - 1));
                c.slots.insertLast(Slot("flak", at));
                AddRing(c, "teeth", at, 56.0f, 32.0f);
            }
            if (!t2) { c.slots.insertLast(Slot("aal", Along(p, d, 360.0f, -sp))); c.slots.insertLast(Slot("aal", Along(p, d, 360.0f, sp))); }
            c.slots.insertLast(Slot("aah", Along(p, d, 250.0f, 0.0f)));
            if (t2air || t2) { AIFloat3 at = Along(p, d, 150.0f, sp * 1.7f); c.slots.insertLast(Slot("lraa", at)); AddRing(c, "teeth", at, 64.0f, 32.0f); }
            AddNanos(c, Global::RoleSettings::Tech::WeaponNanoPerCluster);
        } else if (c.kind == ARTY) {
            for (int k = 0; k < 2; ++k) {
                AIFloat3 at = Along(p, d, 0.0f, 160.0f * (k == 0 ? -1.0f : 1.0f));
                c.slots.insertLast(Slot("art2", at));
            }
            c.slots.insertLast(Slot("aah", Along(p, back, 150.0f, 0.0f)));
            c.slots.insertLast(Slot("radar", Along(p, back, 200.0f, 200.0f)));
            AddRing(c, "teeth", p, 300.0f, 32.0f);
            AddNanos(c, Global::RoleSettings::Tech::WeaponNanoPerCluster);
        } else if (c.kind == LRPC) {
            c.slots.insertLast(Slot("lrpc", p));
            c.slots.insertLast(Slot("flak", Along(p, d, 260.0f, -130.0f)));
            c.slots.insertLast(Slot("flak", Along(p, d, 260.0f, 130.0f)));
            c.slots.insertLast(Slot("radar", Along(p, back, 200.0f, 220.0f)));
            AddRing(c, "teeth", p, 360.0f, 32.0f);
            AddNanos(c, Global::RoleSettings::Tech::WeaponNanoPerCluster);
        } else if (c.kind == SUPER) {
            ShapeSuper(c);
        } else if (c.kind == COAST) {
            ShapeCoast(c);
        }
    }

    void AddFactionSupport(WCluster@ cluster)
    {
        // Bounded by public geothermal sites, on cluster creation only. Exact
        // footprint admission honors allied buildings and layout reservations.
        // Occupied vents require an explicit owner handoff through GeoRelease.
        if (Global::AISettings::Side == "cortex") {
            CCircuitDef@ geothermal=Def("geoartillery");
            if (geothermal !is null) for (int index=0;index<ai.GetGeoSpotCount();++index) {
                const AIFloat3 point=ai.GetGeoSpot(index);
                if (point.distance2D(cluster.pos)>Global::RoleSettings::Tech::WeaponGeoClusterRadius
                    || !NearFront(point,Global::RoleSettings::Tech::WeaponGroundFrontRadius)
                    || aiBattle.SurfThreat(point)>1.0f) continue;
                cluster.slots.insertLast(Slot("geoartillery",point));
                AddRing(cluster,"fort",point,112.0f,32.0f);
            }
        }
        const int count=Global::AISettings::Side == "armada" ? Global::RoleSettings::Tech::WeaponArmadaEmpCount
            : Global::AISettings::Side == "cortex" ? Global::RoleSettings::Tech::WeaponCortexTacticalCount
            : Global::RoleSettings::Tech::WeaponLegionPerditionCount;
        for (int index=0;index<count;++index) {
            const AIFloat3 point=Along(cluster.pos,cluster.dir,-240.0f,
                (float(index)-float(count-1)*0.5f)*Global::RoleSettings::Tech::WeaponSpecialSpacing);
            cluster.slots.insertLast(Slot("special",point));
            AddRing(cluster,"fort",point,112.0f,32.0f);
        }
    }
    bool PendingGeothermal(WCluster@ cluster)
    {
        for (uint index=0;index<cluster.slots.length();++index) {
            Slot@ slot=cluster.slots[index];
            if (slot.role == "geoartillery" && !slot.dead && slot.standFrame<0) return true;
        }
        return false;
    }

    // the owner's escort (W9): storage for a full shot, dense forward flak,
    // long-range AA, deflectors, anti-nuke, turrets, radars, a wall ring
    int SuperStorages()
    {
        CCircuitDef@ gun = Def("super");
        CCircuitDef@ st = Def("estor");
        const float shot = (gun is null) ? 0.0f : aiBattle.ShotEnergy(gun) * Global::RoleSettings::Tech::SuperStorageMargin;
        const float have = aiEconomyMgr.energy.storage;
        const float per = 40000.0f;   // armuwadves, coruwadves, legadvestore
        int n = int(ceil(Mx(0.0f, shot - have) / per));
        return Mx(Global::RoleSettings::Tech::SuperStorageMin, n);
    }
    void ShapeSuper(WCluster@ c)
    {
        const AIFloat3 p = c.pos, d = c.dir, back(-d.x, 0.0f, -d.z);
        c.slots.insertLast(Slot("super", p));
        const int an = (aiBattle.EnemyCount(E_NUKE) > 0) ? Mx(2, Global::RoleSettings::Tech::SuperAntiNukeCount) : Global::RoleSettings::Tech::SuperAntiNukeCount;
        for (int k = 0; k < an; ++k) c.slots.insertLast(Slot("antinuke", Along(p, back, 420.0f, (k == 0 ? -1.0f : 1.0f) * 360.0f)));
        c.slots.insertLast(Slot("shield", Along(p, d, 150.0f, -140.0f)));
        const int fl = Global::RoleSettings::Tech::SuperFlakCount;
        for (int k = 0; k < fl; ++k) {   // dense forward arc, 300 to 700 toward the air approach
            const float lat = (k - (fl - 1) * 0.5f) * 170.0f;
            c.slots.insertLast(Slot("flak", Along(p, d, 380.0f + 120.0f * (k % 2), lat)));
        }
        for (int k = 1; k < Global::RoleSettings::Tech::SuperDeflectorCount; ++k)
            c.slots.insertLast(Slot("shield", Along(p, d, 150.0f, 140.0f * k)));
        for (int k = 0; k < Global::RoleSettings::Tech::SuperLongRangeAACount; ++k)
            c.slots.insertLast(Slot("lraa", Along(p, d, 60.0f, (k % 2 == 0 ? -1.0f : 1.0f) * (460.0f + 60.0f * (k / 2)))));
        const int st = SuperStorages();
        for (int k = 0; k < st; ++k) c.slots.insertLast(Slot("estor", Along(p, back, 260.0f + 110.0f * (k / 4), ((k % 4) - 1.5f) * 120.0f)));
        for (int k = 0; k < Global::RoleSettings::Tech::SuperRadarCount; ++k)
            c.slots.insertLast(Slot("radar", Along(p, back, 560.0f, (k % 2 == 0 ? -1.0f : 1.0f) * 300.0f)));
        const AIFloat3 keep = c.pos;
        AddNanos(c, Global::RoleSettings::Tech::SuperNanoCount);
        AddRing(c, "teeth", keep, Global::RoleSettings::Tech::SuperEscortRadius * 0.8f, 32.0f);
    }

    // the coast (W8): layers from the sea to the beach's emergence band
    void ShapeCoast(WCluster@ c)
    {
        int idx = -1;
        for (int i = 0; i < aiBattle.GetBeachCount(); ++i) if (aiBattle.GetBeachPos(i).distance2D(c.pos) < 32.0f) { idx = i; break; }
        const int cls = (idx >= 0) ? aiBattle.GetBeachClass(idx) : 0;
        const AIFloat3 p = c.pos, sea = c.dir, land(-sea.x, 0.0f, -sea.z);
        const bool t2 = MetalIncome() >= Global::RoleSettings::Tech::WeaponArtyMinIncome;
        const bool heavy = aiBattle.EnemyCost(E_HEAVY) > 0.0f;
        // the beach: direct fire behind the shore over the emergence band, walls at the land exit
        c.slots.insertLast(Slot("hlt", Along(p, land, 90.0f, -120.0f)));
        c.slots.insertLast(Slot("hlt", Along(p, land, 90.0f, 120.0f)));
        c.slots.insertLast(Slot("llt", Along(p, land, 70.0f, 0.0f)));
        if (t2) c.slots.insertLast(Slot("t2pop", Along(p, land, 140.0f, 0.0f)));
        if (heavy) c.slots.insertLast(Slot("heavy", Along(p, land, 200.0f, 200.0f)));
        for (int k = -2; k <= 2; ++k) c.slots.insertLast(Slot("teeth", Along(p, land, 30.0f, 48.0f * k)));
        if ((cls & (B_SHIP | B_DEEP)) != 0) {
            // ship water: surface guns afloat, artillery on the high ground behind
            for (float dist = 80.0f; dist <= 400.0f; dist += 40.0f) {
                AIFloat3 w = Along(p, sea, dist, 0.0f);
                if (aiBattle.Depth(w) >= 6.0f) { c.slots.insertLast(Slot("fhlt", w)); break; }
            }
            c.slots.insertLast(Slot("art2", Along(p, land, 450.0f, 0.0f)));
            for (int k = -1; k <= 1; k += 2) {
                AIFloat3 w = Along(p, sea, 120.0f, 160.0f * k);
                if (aiBattle.Depth(w) >= 2.0f && aiBattle.Depth(w) < 20.0f) c.slots.insertLast(Slot("fteeth", w));
            }
        }
        if ((cls & B_DEEP) != 0) {
            // deep water: torpedoes (the owner's rule: only where subs can come), depth charges, two sonars
            int torps = 0;
            for (float dist = 100.0f; dist <= 900.0f && torps < 2; dist += 32.0f) {
                for (int k = -1; k <= 1 && torps < 2; k += 2) {
                    AIFloat3 w = Along(p, sea, dist, 120.0f * k);
                    CCircuitDef@ td = Def(t2 ? "torp2" : "torp1");
                    if (td !is null && aiBattle.TorpedoSiteOK(td, w, td.GetMaxRange(RANGE_WATER) > 0.0f ? td.GetMaxRange(RANGE_WATER) : 500.0f, false)) {
                        c.slots.insertLast(Slot(t2 ? "torp2" : "torp1", w));
                        ++torps;
                    }
                }
            }
            c.slots.insertLast(Slot("dcharge", Along(p, land, 40.0f, -80.0f)));
            c.slots.insertLast(Slot("dcharge", Along(p, land, 40.0f, 80.0f)));
            int sonars = 0;
            for (float dist = 60.0f; dist <= 600.0f && sonars < 2; dist += 60.0f) {
                AIFloat3 w = Along(p, sea, dist, (sonars == 0 ? -1.0f : 1.0f) * 200.0f);
                if (aiBattle.Depth(w) >= 12.0f) { c.slots.insertLast(Slot("sonar", w)); ++sonars; }
            }
        }
        c.slots.insertLast(Slot("aah", Along(p, land, 260.0f, 0.0f)));
        c.slots.insertLast(Slot("radar", Along(p, land, 320.0f, 200.0f)));
        // nanos behind the beach, toward the land
        c.dir = sea;
        AddNanos(c, Global::RoleSettings::Tech::WeaponNanoPerCluster);
    }

    // ---------------------------------------------------------------- replan: found again, re-ranked

    void Replan()
    {
        lastReplan = ai.frame;
        array<Candidate@> cand;
        Discover(cand);
        // a cluster with anything framed or standing keeps its point (played: the combat
        // zone moved, the framed Ragnarok's cluster went stale, its air builders left)
        for (uint i = 0; i < clusters.length(); ++i) clusters[i].stale = !Started(clusters[i]);
        int added = 0;
        for (uint i = 0; i < cand.length(); ++i) {
            Candidate@ k = cand[i];
            if (!PlacementReleased(k.kind, k.pos)) continue;
            WCluster@ have = null;
            for (uint j = 0; j < clusters.length(); ++j) if (clusters[j].key == k.key) { @have = clusters[j]; break; }
            const float pr = Need(k.kind) * k.score;
            if (have !is null) {
                have.stale = false;
                have.priority = pr;
                have.siteScore = k.score;
                have.seen = ai.frame;
                continue;
            }
            if (CountKind(k.kind) >= MaxOf(k.kind)) {
                // a better point than the weakest of its kind replaces it, when that one has nothing built yet
                WCluster@ weakest = null;
                for (uint j = 0; j < clusters.length(); ++j)
                    if (clusters[j].kind == k.kind && (weakest is null || clusters[j].priority < weakest.priority)) @weakest = clusters[j];
                if (weakest is null || weakest.priority * 1.5f > pr || Started(weakest)) continue;
                GenericHelpers::LogUtil("[TECH][Weapons] " + KIND_NAMES[k.kind] + " cluster #" + weakest.id + " dropped for a better point (D-126)", 1);
                clusters.removeAt(clusters.findByRef(weakest));
            }
            if ((k.kind == LRPC || k.kind == SUPER) && !CriticalSpaced(k.pos)) continue;
            WCluster@ c = WCluster();
            c.id = nextId++; c.kind = k.kind; c.key = k.key; c.pos = k.pos; c.dir = k.dir;
            c.siteScore = k.score; c.priority = pr; c.why = k.why; c.created = ai.frame; c.seen = ai.frame;
            Shape(c);
            SortSlots(c);
            clusters.insertLast(c);
            ++added;
            GenericHelpers::LogUtil("[TECH][Weapons] new " + KIND_NAMES[c.kind] + " cluster #" + c.id + " at (" + int(c.pos.x) + ", " + int(c.pos.z)
                + "): " + c.why + ", " + c.slots.length() + " slots, priority " + int(pr * 100) / 100.0f + " (D-126)", 1);
        }
        Upkeep();
        // the order of work: highest priority first
        for (uint i = 1; i < clusters.length(); ++i) {
            for (uint j = i; j > 0 && clusters[j].priority > clusters[j - 1].priority; --j) {
                WCluster@ tmp = clusters[j]; @clusters[j] = clusters[j - 1]; @clusters[j - 1] = tmp;
            }
        }
        string rank = "";
        for (uint i = 0; i < clusters.length() && i < 8; ++i)
            rank += (i > 0 ? ", " : "") + "#" + clusters[i].id + " " + KIND_NAMES[clusters[i].kind] + " " + int(clusters[i].priority * 100) / 100.0f
                + (clusters[i].stale ? " (stale)" : "") + " " + Built(clusters[i]) + "/" + clusters[i].slots.length() + (Dead(clusters[i]) > 0 ? (" (" + Dead(clusters[i]) + " no site)") : "");
        GenericHelpers::LogUtil("[TECH][Weapons] replan: " + cand.length() + " points, " + added + " new, ranked: " + rank + " (D-126)", 1);
    }

    // the order of work in a cluster: its first weapon, its construction turrets
    // (they build the rest), the other weapons and sensors, then protective walls.
    // Other roles retain the previous wall-first sequence.
    void SortSlots(WCluster@ c)
    {
        array<Slot@> a, b, d, w;
        for (uint i = 0; i < c.slots.length(); ++i) {
            Slot@ s = c.slots[i];
            if (IsWall(s.role)) w.insertLast(s);
            else if (s.role == "nano") b.insertLast(s);
            else if (a.length() == 0) a.insertLast(s);
            else d.insertLast(s);
        }
        c.slots.resize(0);
        if (Global::AISettings::Role != AiRole::TECH) for (uint i = 0; i < w.length(); ++i) c.slots.insertLast(w[i]);
        for (uint i = 0; i < a.length(); ++i) c.slots.insertLast(a[i]);
        for (uint i = 0; i < b.length(); ++i) c.slots.insertLast(b[i]);
        for (uint i = 0; i < d.length(); ++i) c.slots.insertLast(d[i]);
        if (Global::AISettings::Role == AiRole::TECH) for (uint i = 0; i < w.length(); ++i) c.slots.insertLast(w[i]);
    }

    // a started cluster short of construction turrets gets new slots on another
    // side; a cluster with nothing built and every slot dead moves its anchor
    // outward and is laid again (at most 3 times)
    void Upkeep()
    {
        for (uint i = 0; i < clusters.length(); ++i) {
            WCluster@ c = clusters[i];
            int open = 0, nanosAlive = 0;
            for (uint j = 0; j < c.slots.length(); ++j) {
                if (!c.slots[j].dead && c.slots[j].standFrame < 0) ++open;
                if (c.slots[j].role == "nano" && (!c.slots[j].dead || c.slots[j].standFrame >= 0)) ++nanosAlive;
            }
            const int want = (c.kind == SUPER) ? Global::RoleSettings::Tech::SuperNanoCount : Global::RoleSettings::Tech::WeaponNanoPerCluster;
            if (Started(c) && nanosAlive < want && c.reshapes < 3) {
                ++c.reshapes;
                const AIFloat3 keep = c.dir;
                c.dir = AIFloat3(-keep.z, 0.0f, keep.x);   // a quarter turn: the next side
                if ((c.reshapes % 2) == 0) c.dir = AIFloat3(keep.z, 0.0f, -keep.x);
                if (Global::AISettings::Role == AiRole::TECH && c.reshapes == 3)
                    c.dir = AIFloat3(-keep.x, 0.0f, -keep.z);
                AddNanos(c, want - nanosAlive);
                c.dir = keep;
                // Replacement support must keep the original priority, not sit
                // behind every remaining weapon. Linear reorder only on these
                // bounded repair mutations, never on the per-builder hot path.
                if (Global::AISettings::Role == AiRole::TECH) SortSlots(c);
                GenericHelpers::LogUtil("[TECH][Weapons] " + KIND_NAMES[c.kind] + " #" + c.id + ": " + (want - nanosAlive) + " construction turret slot(s) laid again on another side (D-126)", 1);
            } else if (open == 0 && Built(c) == 0 && c.reshapes < 3) {
                ++c.reshapes;
                c.pos = Along(c.pos, c.dir, -250.0f, 0.0f);
                c.slots.resize(0);
                Shape(c);
                SortSlots(c);
                GenericHelpers::LogUtil("[TECH][Weapons] " + KIND_NAMES[c.kind] + " #" + c.id + ": no site for any slot; moved to (" + int(c.pos.x) + ", " + int(c.pos.z) + ") and laid again (D-126)", 1);
            }
        }
    }

    // anything of it standing or going up
    bool Started(WCluster@ c)
    {
        for (uint i = 0; i < c.slots.length(); ++i) {
            Slot@ s = c.slots[i];
            if (s.standFrame >= 0) return true;
            CCircuitDef@ d = Def(s.role);
            if (d !is null && ai.frame - s.orderedFrame < 300 * SECOND && aiBuilderMgr.FindUnfinishedNear(s.pos, 96.0f, d) !is null) return true;
        }
        return false;
    }

    int Dead(WCluster@ c)
    {
        int n = 0;
        for (uint i = 0; i < c.slots.length(); ++i) if (c.slots[i].dead) ++n;
        return n;
    }

    int Built(WCluster@ c)
    {
        int n = 0;
        for (uint i = 0; i < c.slots.length(); ++i) if (c.slots[i].standFrame >= 0) ++n;
        return n;
    }

    // ---------------------------------------------------------------- tick (once a second, from Tech_AiUpdate)

    void Tick()
    {
        LoadSettings();
        const float dt = float(ai.frame - lastTick) / SECOND;
        lastTick = ai.frame;
        if (!Enabled()) return;
        const float mi = MetalIncome();
        if (mi < Global::RoleSettings::Tech::WeaponStartMetalIncome) {
            if (!announcedGate && ai.frame > 60 * SECOND) {
                announcedGate = true;
                GenericHelpers::LogUtil("[TECH][Weapons] waiting for +" + int(Global::RoleSettings::Tech::WeaponStartMetalIncome) + " metal before any weapon cluster (D-126)", 1);
            }
            return;
        }
        // the budget: a share of income, more while the base is fought over
        const bool attacked = aiBattle.CombatHeat(Base(), Global::RoleSettings::Tech::WeaponBaseRadius) >= Global::RoleSettings::Tech::WeaponAttackedHeat;
        const float share = attacked ? Global::RoleSettings::Tech::WeaponBudgetShareAttacked : Global::RoleSettings::Tech::WeaponBudgetShare;
        tokens = Mn(tokens + share * mi * Mx(0.0f, dt), share * mi * Global::RoleSettings::Tech::WeaponBudgetWindowSeconds);
        if (lastAnalyse < 0 || ai.frame - lastAnalyse > int(Global::RoleSettings::Tech::WeaponAnalyseSeconds * SECOND)) Analyse();
        if (ai.frame - lastReplan > int(Global::RoleSettings::Tech::WeaponReplanSeconds * SECOND)) Replan();
        // slots standing
        for (uint i = 0; i < clusters.length(); ++i) {
            WCluster@ c = clusters[i];
            for (uint j = 0; j < c.slots.length(); ++j) {
                Slot@ s = c.slots[j];
                if (s.dead) continue;
                CCircuitDef@ d = Def(s.role);
                if (d is null) { s.dead = true; continue; }
                const bool stands = aiBuilderMgr.FindOwnNear(s.pos, 64.0f, d) !is null;
                if (stands && s.standFrame < 0) s.standFrame = ai.frame;
                if (!stands && s.standFrame >= 0) s.standFrame = -1;   // lost: to be rebuilt
            }
        }
        SuperTick();
        Checks();
    }

    // ---------------------------------------------------------------- work for a builder (rule weapons.cluster)

    int OutstandingOrders()
    {
        int n = 0;
        for (uint i = 0; i < clusters.length(); ++i) {
            if (clusters[i].kind == SUPER) continue;
            for (uint j = 0; j < clusters[i].slots.length(); ++j) {
                Slot@ s = clusters[i].slots[j];
                if (s.standFrame >= 0 || s.dead) continue;
                // out: ordered in the last 30 s, or a frame going up (a failed order
                // no longer holds a place for a minute)
                if (ai.frame - s.orderedFrame < 30 * SECOND) { ++n; continue; }
                if (ai.frame - s.orderedFrame >= 300 * SECOND) continue;
                CCircuitDef@ d = Def(s.role);
                if (d !is null && aiBuilderMgr.FindUnfinishedNear(s.pos, 96.0f, d) !is null) ++n;
            }
        }
        return n;
    }

    IUnitTask@ Work(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null || !Active()) return null;
        const bool air = UnitHelpers::IsAirConstructor(u.circuitDef);
        const AIFloat3 from = u.GetPos(ai.frame);
        const float mi = MetalIncome();
        // One synchronous Work invocation, never a frame-to-frame cache.
        // Pure cluster filters cannot change the pending count. Any slot
        // mutation or attempted order invalidates it before the next cluster.
        // This avoids C repeated scans of all S slots on a read-only pass
        // (O(C*S) -> O(C+S)); mutations can legitimately require another scan.
        // Do not hoist this across Work calls: same-frame enqueues are visible.
        // tools/knowledge/check_weapon_work.py is the differential oracle.
        int pending = -1;
        for (uint i = 0; i < clusters.length(); ++i) {
            WCluster@ c = clusters[i];
            if (c.stale || mi < Gate(c.kind)) continue;
            if (c.kind == AIR && EcoFlak::OwnsArea(c.pos)) continue;
            if (!PlacementReleased(c.kind, c.pos)) continue;
            if (c.kind == SUPER && !SuperStartable(c)) continue;
            if (!air && from.distance2D(c.pos) > Global::RoleSettings::Tech::WeaponWorkRadius) continue;
            const bool escort = (c.kind == SUPER);
            // a full metal bank: the economy has nothing to spend it on, so no budget and twice the orders
            const bool flooded = aiEconomyMgr.isMetalFull;
            if (!escort) {
                if (pending < 0) {
                    if (AiPerfEnabled) AiPerfBeginLabel("weapons-outstanding");
                    pending = OutstandingOrders();
                    if (AiPerfEnabled) AiPerfEndLabel();
                }
                if (pending >= Global::RoleSettings::Tech::WeaponMaxConcurrent * (flooded ? 2 : 1)) return null;
            }
            for (uint j = 0; j < c.slots.length(); ++j) {
                Slot@ s = c.slots[j];
                if (s.dead || s.standFrame >= 0 || ai.frame - s.orderedFrame < 60 * SECOND) continue;
                if (s.role == "special" && Global::AISettings::Side == "cortex" && PendingGeothermal(c)) continue;
                if (s.role == "art2" && mi < Global::RoleSettings::Tech::WeaponArtyMinIncome) continue;
                if (s.role == "super" && air) continue;   // the cannon itself: SuperTask frames it with all air build power
                CCircuitDef@ d = Def(s.role);
                if (d is null) { s.dead = true; pending = -1; continue; }
                if (!u.circuitDef.CanBuild(d)) continue;
                if (aiBuilderMgr.FindUnfinishedNear(s.pos, 64.0f, d) !is null) continue;   // going up: someone is on it
                if (!escort && !flooded && tokens < d.costM) {
                    if (ai.frame - lastBudgetLog > 30 * SECOND) {
                        lastBudgetLog = ai.frame;
                        GenericHelpers::LogUtil("[TECH][Weapons] budget: " + int(tokens) + " metal saved, " + d.GetName() + " costs " + int(d.costM) + " (D-126)", 2);
                    }
                    return null;
                }
                if (s.role == "geoartillery") {
                    IUnitTask@ geothermal=Team::GeoRelease::Work(u,s.pos);
                    if (geothermal !is null) {
                        s.orderedFrame=ai.frame;
                        IBuilderTask@ build=cast<IBuilderTask>(geothermal);
                        if (!escort && build !is null && Task::BuildType(build.GetBuildType())==Task::BuildType::GEO) tokens-=d.costM;
                        pending=-1;
                        return geothermal;
                    }
                    if (!Team::GeoRelease::Waiting(s.pos)) { s.dead=true; pending=-1; }
                    continue;
                }
                AIFloat3 at;
                if (AiPerfEnabled) AiPerfBeginLabel("weapons-site");
                const bool site = Site(s, d, at);
                if (AiPerfEnabled) AiPerfEndLabel();
                if (!site) { s.dead = true; pending = -1; continue; }
                pending = -1; // enqueue/abort hooks may mutate other slots
                if (AiPerfEnabled) AiPerfBeginLabel("weapons-order");
                IUnitTask@ t = Order(u, c, s, d, at);
                if (AiPerfEnabled) AiPerfEndLabel();
                if (t is null) continue;
                if (!escort) tokens -= d.costM;
                return t;
            }
        }
        return null;
    }

    // the site rules: walls and turrets never on a friendly lane; torpedoes only
    // where submarines can come (W8, INV-054); the engine's footprint test last
    bool Site(Slot@ s, CCircuitDef@ d, AIFloat3& out at)
    {
        at = s.pos;
        if (IsTorp(s.role)) {
            const float r = d.GetMaxRange(RANGE_WATER) > 0.0f ? d.GetMaxRange(RANGE_WATER) : 500.0f;
            if (!aiBattle.TorpedoSiteOK(d, at, r, s.role == "dcharge")) return false;
        }
        // construction turrets only need build range of the cluster: search further
        // (played: a long-range cluster stood with 0 of its 4, their slots dead)
        const int rings = IsWall(s.role) || s.role == "geoartillery" ? 1 : (s.role == "nano") ? 5 : 3;
        for (int ring = 0; ring < rings; ++ring) {
            for (int k = 0; k < (ring == 0 ? 1 : 8); ++k) {
                const float a = 0.7854f * k;
                AIFloat3 p(s.pos.x + cos(a) * 48.0f * ring, 0.0f, s.pos.z + sin(a) * 48.0f * ring);
                if (!OnMap(p) || aiBattle.IsFriendlyLane(p) || !WallHelpers::Allowed(d, p)) continue;
                if (IsTorp(s.role) && ring > 0) {
                    const float r = d.GetMaxRange(RANGE_WATER) > 0.0f ? d.GetMaxRange(RANGE_WATER) : 500.0f;
                    if (!aiBattle.TorpedoSiteOK(d, p, r, s.role == "dcharge")) continue;
                }
                if (!aiTerrainMgr.CanReserveBuilding(d, p, 0)) continue;
                at = p;
                return true;
            }
        }
        return false;
    }

    IUnitTask@ Order(CCircuitUnit@ u, WCluster@ c, Slot@ s, CCircuitDef@ d, const AIFloat3& in at)
    {
        if (TypeOf(s.role) == Task::BuildType::NANO && Layout::TurretsCapped()) return null;
        if (!TechForward::Buildable(u, d) || !WallHelpers::Allowed(d, at)) return null;
        const int slot = aiTerrainMgr.ReserveBuilding(d, at, 0);
        if (slot < 0) return null;
        if (aiBattle.IsFriendlyLane(aiTerrainMgr.GetReservationPos(slot)) || !WallHelpers::Allowed(d, aiTerrainMgr.GetReservationPos(slot))) {
            aiTerrainMgr.ReleaseReservation(slot); return null;
        }
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(TypeOf(s.role), (c.kind == SUPER) ? Task::Priority::HIGH : Task::Priority::NORMAL,
            d, aiTerrainMgr.GetReservationPos(slot), 0.0f, true, 120 * SECOND));
        if (t is null) { aiTerrainMgr.ReleaseReservation(slot); return null; }
        if (!AiPinReservation(t, slot)) { aiBuilderMgr.AbortTask(t); return null; }
        s.orderedFrame = ai.frame;
        if (MetalIncome() < Global::RoleSettings::Tech::WeaponStartMetalIncome)
            Invariants::Violation("INV-061", "" + c.id, "weapon cluster #" + c.id + " ordered " + d.GetName() + " at +" + int(MetalIncome()) + " metal, under +" + int(Global::RoleSettings::Tech::WeaponStartMetalIncome));
        GenericHelpers::LogUtil("[TECH][Weapons] " + KIND_NAMES[c.kind] + " #" + c.id + ": " + u.circuitDef.GetName() + " " + u.id + " orders " + d.GetName()
            + " (" + s.role + ") at (" + int(at.x) + ", " + int(at.z) + ") (D-126)", 1);
        return t;
    }

    // ---------------------------------------------------------------- the super cannon (W9)

    WCluster@ SuperCluster()
    {
        for (uint i = 0; i < clusters.length(); ++i) if (clusters[i].kind == SUPER) return clusters[i];
        return null;
    }
    bool SuperStartable(WCluster@ c)
    {
        const float mi = MetalIncome();
        if (mi < Global::RoleSettings::Tech::SuperMinMetalIncome) return false;
        if (mi < Global::RoleSettings::Tech::SuperIdealMetalIncome && c.priority < Global::RoleSettings::Tech::SuperMinNeed) return false;
        CCircuitDef@ gun = Def("super");
        if (gun is null) return false;
        // energy for its fire: the sustained draw (shot / reload) within income
        const float reload = Mx(0.1f, aiBattle.ShotReload(gun));
        const float draw = aiBattle.ShotEnergy(gun) / reload;
        return aiEconomyMgr.energy.income >= draw * Global::RoleSettings::Tech::SuperEnergySpareFactor;
    }
    CCircuitUnit@ SuperFrame()
    {
        WCluster@ c = SuperCluster();
        CCircuitDef@ gun = Def("super");
        if (c is null || gun is null) return null;
        return aiBuilderMgr.FindUnfinishedNear(c.pos, 256.0f, gun);
    }
    int superFramedAt = -1;
    int lastSuperOrder = -100000;
    int lastRecall = -100000;
    void SuperTick()
    {
        WCluster@ c = SuperCluster();
        if (c is null) return;
        CCircuitUnit@ fr = SuperFrame();
        if (fr !is null && superFramedAt < 0) {
            superFramedAt = ai.frame;
            GenericHelpers::LogUtil("[TECH][Weapons] super cannon framed at (" + int(c.pos.x) + ", " + int(c.pos.z) + ") at +" + int(MetalIncome())
                + " metal: every air constructor to it (D-126)", 1);
            if (MetalIncome() < Global::RoleSettings::Tech::SuperMinMetalIncome)
                Invariants::Violation("INV-059", "" + c.id, "super cannon framed at +" + int(MetalIncome()) + " metal, under +" + int(Global::RoleSettings::Tech::SuperMinMetalIncome));
        }
        if (fr is null) {
            superFramedAt = -1;
            return;
        }
        // the owner: all air build power, immediately: every air constructor not on it drops its job
        if (ai.frame - lastRecall < 5 * SECOND) return;
        lastRecall = ai.frame;
        array<string>@ keys = TechBuild::airConsSeen.getKeys();
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            CCircuitUnit@ a = ai.GetTeamUnit(parseInt(keys[i]));
            if (a is null || a.task is null) continue;
            if (Global::AISettings::Role == AiRole::TECH && TechBuild::IsDedicatedAirCon(a)) continue;
            if (OnSuper(a)) continue;
            if (Team::Ferry::IsGift(a.id)) continue;   // a delivery in flight finishes first
            aiBuilderMgr.AbortTask(a.task);
        }
    }
    bool OnSuper(CCircuitUnit@ a)
    {
        IBuilderTask@ bt = cast<IBuilderTask>(a.task);
        if (bt is null) return false;
        const int bt_ = int(bt.GetBuildType());
        CCircuitDef@ gun = Def("super");
        if (bt_ == int(Task::BuildType::BIG_GUN) && bt.buildDef is gun) return true;
        if (bt_ == int(Task::BuildType::REPAIR)) {
            CCircuitUnit@ fr = SuperFrame();
            return fr !is null && bt.target is fr;
        }
        return false;
    }
    // rule weapons.super: an air constructor builds the cannon (frames it, or assists the frame)
    IUnitTask@ SuperTask(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null || !UnitHelpers::IsAirConstructor(u.circuitDef)) return null;
        WCluster@ c = SuperCluster();
        if (c is null || c.stale) return null;
        CCircuitUnit@ fr = SuperFrame();
        if (fr !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, fr, 120 * SECOND));
        if (!PlacementReleased(c.kind, c.pos)) return null;
        if (!SuperStartable(c) || !Active()) return null;
        CCircuitDef@ gun = Def("super");
        if (gun is null || !u.circuitDef.CanBuild(gun)) return null;
        if (aiBuilderMgr.FindOwnNear(c.pos, 256.0f, gun) !is null) return null;   // standing
        if (ai.frame - lastSuperOrder < 30 * SECOND) return null;
        Slot@ s = c.slots[0];
        AIFloat3 at;
        if (!Site(s, gun, at)) {
            GenericHelpers::LogUtil("[TECH][Weapons] super cannon: no footprint at (" + int(s.pos.x) + ", " + int(s.pos.z) + "); the next replan moves it (D-126)", 1);
            c.stale = true;
            return null;
        }
        IUnitTask@ t = Order(u, c, s, gun, at);
        if (t !is null) lastSuperOrder = ai.frame;
        return t;
    }

    // ---------------------------------------------------------------- invariants (D-126)

    int lastCheck = 0;
    void Checks()
    {
        if (ai.frame - lastCheck < 30 * SECOND) return;
        lastCheck = ai.frame;
        for (uint i = 0; i < clusters.length(); ++i) {
            WCluster@ c = clusters[i];
            // INV-054: no torpedo or depth-charge launcher of ours where submarines cannot come
            for (uint j = 0; j < c.slots.length(); ++j) {
                Slot@ s = c.slots[j];
                if (!IsTorp(s.role) || s.standFrame < 0) continue;
                CCircuitDef@ d = Def(s.role);
                const float r = d.GetMaxRange(RANGE_WATER) > 0.0f ? d.GetMaxRange(RANGE_WATER) : 500.0f;
                if (!aiBattle.TorpedoSiteOK(d, s.pos, r, s.role == "dcharge"))
                    Invariants::Violation("INV-054", "" + c.id + ":" + j, d.GetName() + " at (" + int(s.pos.x) + ", " + int(s.pos.z) + ") stands where submarines cannot come");
            }
            // INV-060: a cluster with weapons standing keeps its construction turrets (W5)
            int weapons = 0, nanos = 0;
            for (uint j = 0; j < c.slots.length(); ++j) {
                Slot@ s = c.slots[j];
                if (s.standFrame < 0) continue;
                if (s.role == "nano") ++nanos; else if (!IsWall(s.role)) ++weapons;
            }
            const int want = (c.kind == SUPER) ? Global::RoleSettings::Tech::SuperNanoCount : Global::RoleSettings::Tech::WeaponNanoPerCluster;
            if (weapons >= 3 && nanos < Mn(4, want) && ai.frame - c.created > 600 * SECOND)
                Invariants::Violation("INV-060", "" + c.id, KIND_NAMES[c.kind] + " cluster #" + c.id + " has " + weapons + " weapons standing and " + nanos + " construction turrets (under 4) after 10 minutes");
        }
        // INV-057 and INV-058: the super cannon
        WCluster@ sc = SuperCluster();
        CCircuitUnit@ fr = SuperFrame();
        if (fr !is null && superFramedAt >= 0 && ai.frame - superFramedAt > 20 * SECOND) {
            array<string>@ keys = TechBuild::airConsSeen.getKeys();
            for (uint i = 0; keys !is null && i < keys.length(); ++i) {
                CCircuitUnit@ a = ai.GetTeamUnit(parseInt(keys[i]));
                if (a is null || Team::Ferry::IsGift(a.id) || OnSuper(a)) continue;
                if (Global::AISettings::Role == AiRole::TECH && TechBuild::IsDedicatedAirCon(a)) continue;
                Invariants::Violation("INV-057", keys[i], "air constructor " + keys[i] + " is not on the framed super cannon");
            }
        }
        CCircuitDef@ gun = Def("super");
        if (sc !is null && gun !is null && superFramedAt >= 0 && ai.frame - superFramedAt > Global::RoleSettings::Tech::SuperEscortSeconds * SECOND) {
            string missing = "";
            array<string> roles = {"antinuke", "shield", "flak", "lraa", "estor", "nano"};
            for (uint k = 0; k < roles.length(); ++k) {
                int want = 0, have = 0;
                for (uint j = 0; j < sc.slots.length(); ++j) {
                    if (sc.slots[j].role != roles[k] || sc.slots[j].dead) continue;
                    ++want;
                    CCircuitDef@ d = Def(roles[k]);
                    if (sc.slots[j].standFrame >= 0 || (d !is null && aiBuilderMgr.FindUnfinishedNear(sc.slots[j].pos, 64.0f, d) !is null)) ++have;
                }
                if (have < want) missing += (missing == "" ? "" : ", ") + roles[k] + " " + have + "/" + want;
            }
            if (missing != "") Invariants::Violation("INV-058", "" + sc.id, "super cannon escort short after " + Global::RoleSettings::Tech::SuperEscortSeconds + " s: " + missing);
        }
    }

    void OnRoleLeave()
    {
        clusters.resize(0);
        lastReplan = -100000;
        lastAnalyse = -100000;
        tokens = 0.0f;
        superFramedAt = -1;
    }
}
