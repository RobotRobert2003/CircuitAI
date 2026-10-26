#pragma once
#include "terrain/CommanderCombat.h"
#include "terrain/CommanderFortification.h"
#include "terrain/CommanderJammerCoverage.h"
#include "spring/RouteCommand.h"
#include "AIFloat3.h"
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace circuit {
class CCircuitAI; class CCircuitUnit; class CCircuitDef; class IUnitTask;
class CCommanderControl final {
public:
    explicit CCommanderControl(CCircuitAI* ai):ai(ai) { ReadProfiles(); }
    void Join(CCircuitUnit* unit);
    void Leave(int id);
    void Update();
    void WeaponFired(int id,int weapon);
    void MoveFailed(int id);
    void Damaged(CCircuitUnit* unit);
    bool Handles(CCircuitUnit* unit) const;
    bool Jammed(CCircuitUnit* unit);
    bool RetreatCloakFunded(CCircuitUnit* unit) const;
    bool FogCloak(CCircuitUnit* unit) const;
    bool EnergyRetreat(CCircuitUnit* unit) const;
    bool HealthRetreat(CCircuitUnit* unit) const;
    bool GroupSiteAllowed(CCircuitUnit* unit,const springai::AIFloat3& site) const;
    commander::JammerCoverage GroupJammerCoverage(CCircuitUnit* unit,CCircuitDef* def,
        const springai::AIFloat3& center,float searchRadius,const IUnitTask* ignore=nullptr);
    float GroupJammerMargin() const { return options.groupJammerEdge; }
    bool RetreatStation(CCircuitUnit* unit,springai::AIFloat3& goal) const;
    bool SetOption(const std::string& name,float value);
    float GetReserve() const { return reserve; }
    float GetDeficit() const;
    int GetOperation() const { return operation; }
    // Read-only cached decision state. No callbacks, census or replanning;
    // O(log commanders), called only by the strategic snapshot publisher.
    std::string DescribeFront(int id) const;

    bool ReceiveProjectiles(const char* message);
    IUnitTask* FrontWork(CCircuitUnit* unit,int kind,CCircuitDef* buildDef,float radius);
    bool CanStartRadar(CCircuitUnit* unit);
    void MexFinished(CCircuitUnit* commander, CCircuitUnit* mex);
    bool GroupMayBuild(CCircuitUnit* unit,CCircuitDef* def,const springai::AIFloat3& site) const;
    bool CanResumeFrontTask(CCircuitUnit* unit, IUnitTask* task) const;
    std::vector<commander::DefenceExclusion> DefenceExclusions(CCircuitUnit* unit,CCircuitDef* def,
        const springai::AIFloat3& center,float searchRadius,const IUnitTask* ignore=nullptr) const;
private:
    std::vector<int> frontDefenceDefs;
    bool IsFrontDefence(const CCircuitDef* def) const;
    // Script owns the one-member roster and faction definitions. IDs are
    // reacquired on every ask and cleared on ownership loss, never wrappers.
    int groupUnit=-1, groupDef=-1, groupNano=-1, groupRadar=-1, groupJammer=-1,groupAA=-1;
    int groupNext=0;
    bool groupArrived=false;
    CCircuitUnit* GroupCommander() const;
    bool GroupActive(CCircuitUnit* commander);
    IUnitTask* GroupWork(CCircuitUnit* unit);
    IUnitTask* GroupAssist(CCircuitUnit* commander);
    bool GroupTaskFunded(IUnitTask* task) const;
    IUnitTask* GroupBuild(CCircuitUnit* unit, CCircuitDef* def, const springai::AIFloat3& site, bool bootstrap=false);
    IUnitTask* GroupPower(CCircuitUnit* unit, const springai::AIFloat3& site, bool& covered);
    bool GroupPowered(const springai::AIFloat3& site) const;
    void UpdateCommanderGroup();
    // Values are logged as integers; append new modes only.
    enum class Mode { SUPPORT,ASSESS,APPROACH,ALIGN,PENDING,ESCAPE,RECOVER,FALLBACK };
    struct State {
        Mode mode=Mode::SUPPORT;
        int generation=0,seen=-10000,started=0,pending=-1,fired=-1,failed=0;
        int retry=0,target=-1,leaseUntil=0,next=0,lastLog=0,lastDamage=-1,frontFrame=-10000,frontYield=0;
        int frontMexFrame=-10000,frontProgressFrame=0;
        int frontSolarNext=0; // failed local placement retry, no recurring timer
        // Throttles (owner 2026-10-19): a failed detour or a declined T3 waits
        // 1 s, +1 s per failure in a row, at most 3 s; success resets.
        int detourNext=0,detourFails=0,t3DeclineFails=0;
        int t3PositionUntil=0,t3PositionTarget=-1;
        bool immediatePending=false;
        bool energyRetreat=false;
        bool fogCloak=false;
        int fogCloakNext=0;
        bool healthRetreat=false;
        int healthPlan=-10000,healthShotUntil=-1;
        springai::AIFloat3 healthGoal{-1,0,-1};
        int energyPlan=-10000;
        springai::AIFloat3 energyGoal{-1,0,-1};
        float detourDist=0.f; // distance to the front at the last detour MOVE
        // Same-goal MOVE resend backoff and fallback goal hold (owner 2026-10-19).
        int moveSent=-10000,moveResends=0,fallbackGoalSince=-10000;
        springai::AIFloat3 moveGoal{-1,0,-1};
        springai::AIFloat3 frontProgressPos;
        // D-293 fallback: held until fallbackUntil, porc line replanned once/second.
        int fallbackUntil=-1,fallbackPlanned=-10000,fallbackPorc=-1,fallbackMoveUntil=-1;
        int heldPorc=-1,heldPorcUntil=-1; // KI-609: last chosen porc, kept 5 s past its last choice
        float budget=0,fallbackMetal=0,fallbackReach=0;
        commander::FallbackBoundary fallbackBoundary;
        bool cloak=false,deployed=false,invalidated=false,fallback=false;
        springai::AIFloat3 exit,goal,front{-1,0,-1},fallbackGoal,fallbackThreat;
        // D-294 T3 engagement: target, resolved plan, shot accounting, juke.
        int t3Target=-1,t3Approach=0,t3Commit=0,t3Shots=0,t3LastShot=-1,t3JukeUntil=-1,t3JukeSide=1;
        int t3Progress=0,t3Ended=-1,t3Started=-1,t3Seen=-1,t3Declined=-1,t3DeclinedSeen=-1,t3Reconsider=0;
        bool t3Cornered=false,t3Artillery=false,afusEngagement=false;
        float fundingBudget=0;
        int fundingUntil=-1,fundingTarget=-1;
        int t3Screens=0,t3ScreenUntil=0; // D-294 bait turrets ordered this engagement
        int t3ScreenDef=-1,t3ScreenUnit=-1,t3ScreenCheck=0;
        float t3ScreenProgress=0;
        springai::AIFloat3 t3ScreenPos;
        int unseenUntil=0; // D-294: withdrawing cloaked from fire it cannot see
        float t3Closest=0,t3Juke=0,t3Standoff=0,t3MinHealth=0,t3Radius=0,t3Splash=0,t3Cost=0,t3Advance=0,t3Reach=0;
        springai::AIFloat3 t3Anchor,t3LastPos,t3Heading; // heading: last direction of travel
        std::vector<int> farT3; int farT3Frame=-10000; // D-294 artillery beyond scan
        // D-299 work ladder. lineUntil keeps the last fallback line's turret
        // quota open after the fallback ends; workTask is the last ladder task
        // (address compared only, never dereferenced) that Deploy must not
        // interrupt. timedNext: definition id -> next due frame.
        int lineUntil=-1,lineRetry=0,lineYield=-10000,frontArrived=-1,radarFrame=-10000,lineOutside=-1;
        bool lineDone=false,radarCovered=false,workHeld=false; // workHeld: offered under a fallback
        springai::AIFloat3 lineAnchor{-1,0,-1},lineThreat,radarPos{-1,0,-1};
        const IUnitTask* workTask=nullptr;
        int workKind=-1;
        commander::FallbackBoundary workBoundary; // perimeter when workTask was offered
        std::map<int,int> timedNext;
        std::vector<routecommand::Command> route;
        // D-356 lane push census of the last FrontPosition: corridor combat
        // screens within scan, the furthest one's lane progress, the anchor
        // bound actually applied (INV-234 re-derives it in Deploy), and the
        // "then home" latch (never released: the meta's "then home").
        int pushScreens=0; float pushScreenProgress=-1,pushBound=-1;
        // The lane progress the recorded front was built at. INV-234 compares
        // this, not a re-projection of the point: on a folded polyline the
        // exact lane point can project onto a later segment (b06 Glacial,
        // +194 elmos), which is geometry, not a goal beyond the bound.
        float pushGoalProgress=-1;
        bool pushHome=false;
        // D-357 corridor mex sweep: distinct spots offered, the last one, and
        // whether the next lane offer is the turret that follows them.
        int laneMexCount=0; bool laneMexTurret=false;
        springai::AIFloat3 laneMexLast{-1,0,-1};
        // Completion-owned IDs, never borrowed unit pointers. Released with the
        // commander; destroyed/transferred mexes are removed on a work offer.
        std::vector<int> unfortifiedMexes;
        struct TerritoryPlan {
            std::vector<springai::AIFloat3> sites;
            float progress=0;
            bool pending=true;
        };
        std::vector<TerritoryPlan> territoryPlans;
        float territoryProgress=-1;
        float fortifyNextProgress=0;
        int territoryCorridor=-1, territoryClass=-1, fortifyRetry=0, mexFortifyRetry=0;
        bool territoryPending=false;

    };
    struct Threat {
        commander::Point pos,velocity;
        float range=0,damage=0,reload=1,delay=0,splash=0,speed=0,arc=-1,heightMod=0,height=0;
        bool projectile=false,guided=false,ballistic=false;
        float beamRange=0,beamMinIntensity=1,beamClearance=0;
    };
    struct Projectile { commander::Point pos,velocity; float radius=0; int frame=0; };
    struct Options {
        bool enabled=false,advance=false,decoys=false,frontDuty=false,frontReady=false;
        bool work=true; // D-299 ladder and fallback hand-over (script Global::Commander::Work)
        bool frontRecovery=false;
        float frontRepairCombat=0;
        float frontSolarIncome=0, frontSolarStorage=.2f, frontSolarRadius=300, frontSolarDef=-1;
        float frontMexSeconds=0,frontStallSeconds=10,frontDetourSeconds=0; // 0: no detour backoff
        float moveResendSeconds=0;   // 0: a swallowed/failed MOVE is resent every tick
        float t3ImmediateShot=0,t3PositionSeconds=0; // opt-in balanced combat policy
        float fallbackGoalHoldSeconds=0; // 0: the fallback goal may change every replan
        float scan=1000,leash=700,step=96,support=600,minValue=180,killReward=45;
        float hpReserve=.35f,retreat=.45f,recover=.8f,aggression=.25f;
        float shots=2,margin=150,escapeSeconds=4.3f,alignSeconds=.6f;
        float maxApproach=180,maxSeconds=12,cloakSeconds=1.5f,donorReserve=1200;
        float friendlyMargin=12,normalRange=.85f,frontWorkers=2;
        float frontDistance=1600,frontStandoff=650,frontRadius=500,frontThreat=3;
        float jamSafe=0, jamHeavyCost=900;
        float healthRetreatFraction=0,healthShotSeconds=2,groupJammerEdge=100,groupJammerIncome=25;
        float cloakEnergyRetreat=0,cloakRetreatDistance=600,frontMexAA=-1;
        float fogCloakDistance=0,fogCloakIncome=500;
        float frontMexLos=0,radarSpacing=500;
        float groupMexPriority=3,groupRadarPriority=2,groupLinePriority=1;
        float frontPersistent=0, frontMexDefence=0, frontLineEnabled=0;
        float frontLineFog=1000, frontLineSpacing=1.5f;
        float frontDefenceSpacing=.5f;
        float frontLineDepth=800, frontMexOffset=160, frontWorkBehind=400;
        float frontFortifyBank=.5f, frontFortifyPriority=1;
        float frontFortifyAdvance=0; // 0: complete the line before advancing
        float frontCorridor=-1, frontCorridorClass=-1, frontLineDef=-1;
        float frontPushAhead=0; // 0: old screen-led anchor; positive: continuous lane advance
        // D-356: the push is screen-led (corridor combat units required before
        // the anchor leaves the commander's own progress; 0 = unscreened), ends
        // after front_push_until_seconds or once observed enemy riot metal
        // reaches front_push_home_riot ("then home"; 0 = never), and FRONT
        // offers beyond lane half-width + front_lane_margin are declined
        // (0 = the commander's build distance).
        float frontPushScreen=0,frontPushUntilSeconds=0,frontPushHomeRiot=0,frontLaneMargin=0;
        // D-357: corridor mex sweep. Spots within half-width + front_mex_reach
        // (0 = build distance) of the lane, from front_mex_behind behind the
        // commander to front_mex_ahead ahead of it; enemy extractors on those
        // spots are captured when front_mex_capture_enemy; one line turret per
        // front_mex_turret_every corridor mexes (0 = none).
        float frontMexReach=0,frontMexBehind=400,frontMexAhead=600,frontMexCaptureEnemy=0,frontMexTurretEvery=0;
        float frontMexEnemyHome=0; // spots this close to an enemy start are the enemy's home ground: never swept (0 = off)
        float t3Intercept=1,t3Health=.2f,t3Distance=1000,detectionMargin=32;
        float afusDefenceRadius=0; // opt-in script policy; zero preserves ordinary combat
        // D-293: fall back to the backline porc line before a capable group.
        bool fallback=true;
        float fallbackMetal=400,fallbackRangeScale=2,fallbackGroupRadius=400;
        float fallbackOffset=120,fallbackSearch=2000,fallbackHoldSeconds=3,fallbackPorcRange=1500;
        float sensorMemory=10; // seconds a lost mobile sensor still counts (D-293)
        // D-294: T3 engagement leash around the engagement anchor, seconds a
        // HOLD target may stop closing before the commander flanks, and the
        // post-kill dodge of in-flight shells.
        float t3Leash=900,t3HoldSeconds=4,t3DodgeSeconds=1.2f;
        float t3HuntLeash=1800; // artillery sits beyond the line; hunting it goes further
        float t3Screen=300; // friendly combat metal in the T3's reach before a 3+ shot kill
        float t3Hunt=0,t3ArtilleryApproach=180,t3Trade=0,t3RetrySeconds=2,t3DeclineGate=0; // gate: any new plan waits out a decline
        float t3CloakedVolleyRisk=1; // script tunes uncertain new targeting; in-flight damage stays full
        float t3BaitDef=-1,t3BaitCount=0,t3BaitMargin=150,t3BaitDistance=120,t3BaitSpacing=80,t3BaitTimeout=5;
        // D-299 FRONT work ladder. work_radius 0 = the commander's own LOS.
        float workRadius=0,workClearance=400,repairHealth=.98f,reclaimStorage=.95f,reclaimMetal=1;
        float lineIncome=20,lineMin=1,lineMax=6,lineRadius=400,lineSpacing=80,lineHoldSeconds=60,lineRetrySeconds=5;
        float timedInterval=30,timedUntil=300,radarCoverage=.8f,baseRadius=1500;
    } options;
public:
    // D-294 per-T3 strategy. Negative fields resolve automatically from the
    // target's stats; JSON commander.combat.t3_profiles and the script option
    // "t3.<unit>.<field>" override them per unit definition.
    enum T3Approach { T3_AUTO=0,T3_HOLD=1,T3_FLANK=2,T3_HUNT=3,T3_REAR=4 };
    struct T3Profile { float approach=-1,commit=-1,juke=-1,standoff=-1,health=-1,advance=-1; };
private:
    std::map<std::string,T3Profile> t3Profiles;
    std::map<std::string,T3Profile> configuredT3Profiles;
    void ReadProfiles();
    bool SetProfileOption(const std::string& name,float value,bool reset=false);
    CCircuitAI* ai;
    std::map<int,State> commanders;
    // IsDecoy() is the legacy *impersonated-definition* hint. Cache the actual
    // UnitDef decoy relationship separately; definitions live for this AI/game.
    mutable std::map<int,bool> actualDecoys;
    bool ActualDecoy(CCircuitDef* definition) const;
    void UpdateFogCloak(CCircuitUnit* unit,State& state,int frame);
    std::vector<commander::Contact> contacts;
    std::set<int> afusDefs; // script-selected immutable definition IDs, per AI
    int protectedAfus=-1; // fresh local observation, never retained across Tick
    std::vector<Threat> threats;
    std::vector<int> seeds;
    std::vector<Projectile> projectiles;
    // Enemies whose known weapons can hit this commander; rebuilt by Observe.
    std::vector<commander::Attacker> attackers;
    bool submergedContact=false; // D-294: a sonar-only contact under water within t3_distance
    struct PorcCandidate { springai::AIFloat3 pos; float edge=0,distance=0; int id=-1; };
    std::vector<PorcCandidate> porcs;
    struct Definition {
        float radar=0,jammer=0,seismic=0,decloak=0,blastRadius=0,blastEdge=0;
        bool t3=false,stealth=false;
        float tech=1; // BAR customparams.techlevel (1, 1.5, 2, 3); D-299 repair order
        std::vector<float> blastDamage; // immutable death-weapon data for mobile attackers
    };
    std::map<int,Definition> definitions;
    const Definition& DefinitionFor(CCircuitDef* def);
    float T3Leash(const State& s) const {
        return s.t3Artillery && options.t3Hunt<=0 ? options.t3ArtilleryApproach
            : s.t3Approach==T3_HUNT ? options.t3HuntLeash : options.t3Leash;
    }
    struct Sensor { commander::Point pos; float radar=0,seismic=0; };
    std::vector<Sensor> sensors;
    int sensorFrame=-10000;
    int projectileFrame=-1,sequence=0,operation=0;
    float reserve=0;
    float maxJammerRadius=-1;
    std::vector<int> jammerIds;
    std::vector<float> jammerRadii;
    void InitJammerRadii();
    bool HealthControl(CCircuitUnit* unit,State& s,int frame);
    struct JamZone { commander::Point center; float radius; };
    std::vector<JamZone> jamZones;
    bool JamControl(CCircuitUnit* unit,State& state,int frame);
    void Tick(CCircuitUnit* unit,State& state,int frame);
    void Observe(CCircuitUnit* unit,int frame);
    // moving: unguided ballistic shells mostly miss a moving commander (D-294).
    float Exposure(commander::Point from,commander::Point to,float seconds,float height,bool moving=false,float newVolleyRisk=1.f) const;
    bool Route(CCircuitUnit* unit,const springai::AIFloat3& from,const springai::AIFloat3& to) const;
    void Move(CCircuitUnit* unit,State& state,const springai::AIFloat3& goal,int frame,bool transit=false);
    void Conceal(CCircuitUnit* unit,State& state,bool value);
    void Transition(CCircuitUnit* unit,State& state,Mode mode,int frame);
    bool Deploy(CCircuitUnit* unit,State& state,int frame);
    springai::AIFloat3 FrontPosition(CCircuitUnit* unit,State& state,int frame);
    bool CloakSafe(CCircuitUnit* unit,commander::Point from,commander::Point to,float seconds);
    bool Intercept(CCircuitUnit* unit,State& state,int frame);
    void EndT3(CCircuitUnit* unit,State& state,int frame,const char* reason);
    void Decline(CCircuitUnit* unit,State& state,const commander::Contact& target,int frame,const char* reason);
    bool Fire(CCircuitUnit* unit,State& state,const commander::Line& line,int frame,bool acceptT3Risk=false,bool acceptJamRisk=false);
    bool FallbackActive(const State& state,int frame) const { return state.fallback && frame<state.fallbackUntil; }
    // Engine reachability indexes sectors by position without bounds checks
    // (KI register, GetClosestSector). Reject garbage/off-map points first.
    static bool OnMap(const springai::AIFloat3& p) {
        return std::isfinite(p.x) && std::isfinite(p.z) && p.x>=0 && p.z>=0
            && p.x<springai::AIFloat3::maxxpos && p.z<springai::AIFloat3::maxzpos;
    }
    void PlanFallback(CCircuitUnit* unit,State& state,int frame);
    bool Fallback(CCircuitUnit* unit,State& state,IUnitTask* current,int frame);
    void CheckPerimeter(CCircuitUnit* unit,const State& state,const springai::AIFloat3& goal,int frame,const char* source) const;
    // D-299 work ladder (CommanderWork.cpp). Kinds 5..16; see FrontWork. The
    // script names them in commander.json front_ladder (CommanderFront::Work).
    enum WorkKind { WORK_LINE=5,WORK_REPAIR_DEFENCE=6,WORK_REPAIR_UNITS=7,WORK_RECLAIM=8,
        WORK_TIMED=9,WORK_RADAR=10,WORK_FACTORY=11,WORK_BASE=12,WORK_MEX=13,WORK_ADVANCE=14,WORK_HOLD=15,
        WORK_MEX_LANE=16, WORK_TERRITORY_LINE=17, WORK_MEX_DEFENCE=18, WORK_REPAIR_COMBAT=21, WORK_SOLAR=22 };
    IUnitTask* LadderWork(CCircuitUnit* unit,State& state,int kind,CCircuitDef* buildDef,float radius,int frame);
    // D-357: the corridor mex sweep (WORK_MEX_LANE) and its dry probe (INV-235).
    IUnitTask* LaneMexWork(CCircuitUnit* unit,State& state,CCircuitDef* turretDef,int frame);
    bool LaneMexAvailable(CCircuitUnit* unit,State& state,int frame);
    bool LaneMexSiteAllowed(CCircuitUnit* unit,const springai::AIFloat3& site) const;
    float LaneMexAheadLimit(CCircuitUnit* unit,State& state,int frame,float own);
    // D-356: the "then home" latch of the lane push.
    bool PushHome(CCircuitUnit* unit,State& state,int frame);
    IUnitTask* MexDefenceWork(CCircuitUnit* unit,State& state,CCircuitDef* def,int frame);
    IUnitTask* TerritoryLineWork(CCircuitUnit* unit,State& state,CCircuitDef* def,int frame);
    IUnitTask* FortifySite(CCircuitUnit* unit,CCircuitDef* def,const springai::AIFloat3& site,int frame,
        const springai::AIFloat3* coveragePoint=nullptr);

    IUnitTask* RepairWork(CCircuitUnit* unit,const State& state,bool defence,float radius,int frame,bool stationary=false);
    IUnitTask* ReclaimWork(CCircuitUnit* unit,const State& state,float radius,int frame);
    IUnitTask* LineWork(CCircuitUnit* unit,State& state,CCircuitDef* buildDef,int frame);
    IUnitTask* RadarWork(CCircuitUnit* unit,State& state,CCircuitDef* buildDef,int frame);
    bool RadarCovered(CCircuitUnit* unit,State& state,int frame);
    IUnitTask* AssistWork(CCircuitUnit* unit,const State& state,const springai::AIFloat3& center,float radius,bool factories,int frame);
    float WorkRadius(CCircuitUnit* unit) const;
    // A ladder target is legal while a fallback holds only inside its perimeter.
    bool InsideLine(const State& state,const springai::AIFloat3& p,int frame,float slack) const {
        return !FallbackActive(state,frame) || state.fallbackBoundary.Contains({p.x,p.z},slack);
    }
    bool LineWorking(CCircuitUnit* unit,const State& state,IUnitTask* current,int frame) const;
    // The hand-over exists only where the script ladder will offer work.
    bool LadderActive() const { return options.work && options.frontDuty && options.frontReady; }
    std::vector<int> workIds; // copy of a shared callback buffer; reused
};
}
