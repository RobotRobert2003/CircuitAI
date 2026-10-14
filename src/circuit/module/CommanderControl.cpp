#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/FactoryManager.h"
#include "module/MilitaryManager.h"
#include "task/builder/CommanderTask.h"
#include "task/RetreatTask.h"
#include "task/fighter/RangedWorld.h"
#include "unit/CircuitUnit.h"
#include "unit/ally/AllyUnit.h"
#include "unit/CircuitWDef.h"
#include "unit/enemy/EnemyUnit.h"
#include "unit/enemy/EnemyManager.h"
#include "setup/SetupManager.h"
#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"
#include "spring/SpringUnit.h"
#include "terrain/TerrainManager.h"
#include "util/Performance.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Damage.h"
#include "Log.h"
#include "WeaponMount.h"
#include "Sim/Units/CommandAI/Command.h"
#include <array>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <sstream>

namespace circuit {
using springai::AIFloat3;
using commander::Point;
static Point P(const AIFloat3& p) { return {p.x,p.z}; }
static AIFloat3 F(Point p,float y=0) { return {p.x,y,p.z}; }
static const bool commanderTrace=std::getenv("CIRCUIT_COMMANDER_TRACE")!=nullptr;

bool CCommanderControl::ActualDecoy(CCircuitDef* definition) const {
    const auto found=actualDecoys.find(definition->GetId());
    if(found!=actualDecoys.end()) return found->second;
    const std::unique_ptr<springai::UnitDef> impersonated(definition->GetDef()->GetDecoyDef());
    const bool actual=impersonated!=nullptr;
    actualDecoys.emplace(definition->GetId(),actual); return actual;
}
bool CCommanderControl::Handles(CCircuitUnit* unit) const {
    return options.enabled && unit && !unit->IsDead() && !unit->IsDestroying()
        && unit->HasDGun() && unit->GetCircuitDef()->IsRoleComm()
        && (options.decoys || !ActualDecoy(unit->GetCircuitDef()));
}
void CCommanderControl::Join(CCircuitUnit* unit) {
    if(!unit->GetCircuitDef()->IsRoleComm()) return;
    State state; state.generation=++sequence;
    commanders.emplace(unit->GetId(),std::move(state));
    if(commanderTrace) ai->LOG("[CommanderTrace] join=%i role=%i dgun=%i decoy=%i",unit->GetId(),unit->GetCircuitDef()->IsRoleComm(),unit->HasDGun(),ActualDecoy(unit->GetCircuitDef()));
}
void CCommanderControl::Leave(int id) {
    ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),id);
    if(commanders.erase(id)>0) ++operation;
}
bool CCommanderControl::RetreatCloakFunded(CCircuitUnit* unit) const {
    if(!Handles(unit) || !unit->GetCircuitDef()->IsAbleToCloak()) return false;
    const auto& cap=ai->GetMilitaryManager()->GetRangedWorld()->CapabilitiesFor(unit->GetCircuitDef());
    return ai->GetEconomyManager()->GetEnergyCur()>=cap.cloakMoving*options.escapeSeconds+options.margin;
}
void CCommanderControl::Damaged(CCircuitUnit* unit) {
    auto it=commanders.find(unit->GetId());
    if(!Handles(unit) || it==commanders.end()) return;
    auto& s=it->second; const int frame=ai->GetLastFrame();
    // Coalesce simultaneous weapon hits, never delay beyond the current frame.
    if(s.lastDamage==frame) return;
    performance::Scope measured(ai,performance::COMMANDER_DAMAGE);
    s.lastDamage=frame; s.next=frame+3;
    const float previousReserve=reserve; reserve=std::max(0.f,reserve-std::max(s.budget,s.fundingBudget));
    Tick(unit,s,frame); reserve=std::max(previousReserve,reserve+std::max(s.budget,s.fundingBudget));
}
void CCommanderControl::MoveFailed(int id) {
    auto it=commanders.find(id); if(it==commanders.end()) return;
    it->second.route.clear(); ++it->second.failed; it->second.next=0;
}
void CCommanderControl::WeaponFired(int id,int weapon) {
    auto it=commanders.find(id); auto* unit=ai->GetTeamUnit(id);
    if(it==commanders.end() || !Handles(unit) || !unit->GetCircuitDef()->GetDGunDef()
        || unit->GetCircuitDef()->GetDGunDef()->GetDef()->GetWeaponDefId()!=weapon) return;
    auto& s=it->second; s.fired=ai->GetLastFrame(); s.pending=-1; s.next=0;
    // Shot event confirms dispatch, not a kill. Every repeat uses fresh HP.
    if(dynamic_cast<CCommanderTask*>(unit->GetTask()))
        Transition(unit,s,Mode::ESCAPE,s.fired);
    ai->LOG("[Commander] unit=%i shot_confirmed frame=%i target=%i",id,s.fired,s.target);
}
float CCommanderControl::GetDeficit() const {
    return options.enabled?std::max(0.f,reserve-ai->GetEconomyManager()->GetEnergyCur()):0.f;
}
bool CCommanderControl::SetOption(const std::string& name,float value) {
    if(!std::isfinite(value)) return false;
    if(name=="enabled") {
        options.enabled=value>0;
        for(const auto& [id,u]:ai->GetTeamUnits()) if(!commanders.count(id)) Join(u);
        return true;
    }
    if(name=="advance") {
        if(options.advance!=(value>0)) for(auto& [id,s]:commanders) s.invalidated=true;
        options.advance=value>0; return true;
    }
    if(name=="decoys") { options.decoys=value>0; return true; }
    if(name=="front_duty") {
        if(options.frontDuty!=(value>0)) for(auto& [id,s]:commanders) s.invalidated=true;
        options.frontDuty=value>0; return true;
    }
    if(name=="front_ready") { options.frontReady=value>0; return true; }
    if(name=="work") { options.work=value>0; return true; }
    if(name.rfind("t3.",0)==0) return SetProfileOption(name,value);
    if(name.rfind("reset.t3.",0)==0) return SetProfileOption(name.substr(6),value,true);
    if(name=="fallback") {
        // Disabling releases through the ordinary SUPPORT/Resume path.
        if(options.fallback && value<=0) for(auto& [id,s]:commanders) s.fallbackUntil=-1;
        options.fallback=value>0; return true;
    }
    struct Option { const char* name; float* field; float low,high; };
    const Option fields[]={
        {"scan",&options.scan,400,2000},{"leash",&options.leash,100,10000},
        {"step",&options.step,16,160},{"support",&options.support,0,10000},
        {"min_value",&options.minValue,0,20000},{"kill_reward",&options.killReward,0,1000},
        {"hp_reserve",&options.hpReserve,.1f,.85f},{"retreat",&options.retreat,.1f,.9f},
        {"recover",&options.recover,.3f,1},{"aggression",&options.aggression,0,1},
        {"shots",&options.shots,1,4},{"margin",&options.margin,0,5000},
        {"escape_seconds",&options.escapeSeconds,1,10},{"align_seconds",&options.alignSeconds,0,2},
        {"max_approach",&options.maxApproach,0,400},{"max_seconds",&options.maxSeconds,2,30},
        {"cloak_seconds",&options.cloakSeconds,0,5},{"donor_reserve",&options.donorReserve,0,50000},
        {"friendly_margin",&options.friendlyMargin,0,100},{"normal_range",&options.normalRange,.5f,1},
        {"front_workers",&options.frontWorkers,1,20},
        {"front_distance",&options.frontDistance,200,10000},{"front_standoff",&options.frontStandoff,200,1500},
        {"front_radius",&options.frontRadius,100,1000},{"front_threat",&options.frontThreat,0,50},
        {"t3_intercept",&options.t3Intercept,0,1},{"t3_health",&options.t3Health,.1f,.5f},
        {"t3_distance",&options.t3Distance,250,2000},{"detection_margin",&options.detectionMargin,8,200},
        {"fallback_metal",&options.fallbackMetal,0,20000},{"fallback_range_scale",&options.fallbackRangeScale,.5f,6},
        {"fallback_group_radius",&options.fallbackGroupRadius,50,2000},{"fallback_offset",&options.fallbackOffset,0,600},
        {"fallback_search",&options.fallbackSearch,300,10000},{"fallback_hold_seconds",&options.fallbackHoldSeconds,0,30},
        {"fallback_porc_range",&options.fallbackPorcRange,200,5000},{"sensor_memory",&options.sensorMemory,0,120},
        {"t3_leash",&options.t3Leash,200,4000},{"t3_hold_seconds",&options.t3HoldSeconds,0,30},
        {"t3_dodge_seconds",&options.t3DodgeSeconds,0,5},{"t3_hunt_leash",&options.t3HuntLeash,200,6000},
        {"t3_screen",&options.t3Screen,0,20000},
        {"t3_hunt",&options.t3Hunt,0,1},{"t3_artillery_approach",&options.t3ArtilleryApproach,0,400},
        {"t3_trade",&options.t3Trade,0,1},{"t3_retry_seconds",&options.t3RetrySeconds,.3f,10},
        {"t3_cloaked_volley_risk",&options.t3CloakedVolleyRisk,0,1},
        {"t3_bait_def",&options.t3BaitDef,-1,100000},{"t3_bait_count",&options.t3BaitCount,0,8},
        {"t3_bait_margin",&options.t3BaitMargin,0,1000},{"t3_bait_distance",&options.t3BaitDistance,16,400},
        {"t3_bait_spacing",&options.t3BaitSpacing,32,300},{"t3_bait_timeout",&options.t3BaitTimeout,1,20},
        // D-299 work ladder
        {"work_radius",&options.workRadius,0,3000},{"work_clearance",&options.workClearance,0,2000},
        {"repair_health",&options.repairHealth,.5f,1},{"reclaim_storage",&options.reclaimStorage,.1f,1},
        {"reclaim_metal",&options.reclaimMetal,0,10000},{"line_income",&options.lineIncome,0,1000},
        {"line_min",&options.lineMin,0,20},{"line_max",&options.lineMax,0,20},
        {"line_radius",&options.lineRadius,100,2000},{"line_spacing",&options.lineSpacing,32,400},
        {"line_hold_seconds",&options.lineHoldSeconds,0,600},{"line_retry_seconds",&options.lineRetrySeconds,1,60},
        {"timed_interval",&options.timedInterval,5,600},{"timed_until",&options.timedUntil,0,7200},
        {"radar_coverage",&options.radarCoverage,.1f,1},{"base_radius",&options.baseRadius,200,5000}};
    for(const auto& field:fields) if(name==field.name) {
        *field.field=std::clamp(value,field.low,field.high); return true;
    }
    return false;
}

void CCommanderControl::Observe(CCircuitUnit* unit,int frame) {
    performance::Scope measured(ai,performance::COMMANDER_OBSERVE);
    contacts.clear(); threats.clear(); seeds.clear(); attackers.clear(); submergedContact=false;
    auto& claims=ai->GetAllyTeam()->GetCommanderShots(); claims.Prune(frame);
    auto world=ai->GetMilitaryManager()->GetRangedWorld();
    auto* api=ai->GetUnitAPI(); auto* def=unit->GetCircuitDef();
    const auto pos=unit->GetPos(frame);
    const int armor=def->GetDef()->GetArmorType();
    // D-293: "can attack the commander" means a known weapon whose target
    // category includes this commander and deals damage to its armor class.
    const auto canHit=[&](const CRangedWorld::Capabilities& capabilities) {
        for(const auto& w:capabilities.weapons) {
            if((w.category & def->GetCategory())==0 || w.damage.empty()) continue;
            if(w.damage[std::min(size_t(std::max(0,armor)),w.damage.size()-1)]*w.alphaScale>0) return true;
        }
        return false;
    };
    const auto observeWeapons=[&](int id,const commander::Contact& c,const CRangedWorld::Capabilities& cap) {
        for(const auto& w:cap.weapons) {
            if((w.category & def->GetCategory())==0 || w.damage.empty()) continue;
            // Definition-owned noExplode metadata costs one load-time callback;
            // this O(1) crossing bound prevents treating Behemoth gauss as a
            // single 1200-damage hit. See commander_combat_test and corjugg arena.
            const float hits=w.continuous?commander::CollisionHits(def->GetRadius(),w.speed*30.f):1.f;
            const float damage=w.damage[std::min(size_t(std::max(0,armor)),w.damage.size()-1)]*w.alphaScale*hits;
            if(damage<=0) continue;
            const int reload=api->GetVisibleWeaponReload(id,w.index);
            threats.push_back({c.pos,c.velocity,w.range,damage,w.reload,
                std::max(0.f,float(reload-frame)/30.f),w.splash,w.speed*30.f,w.arc,w.heightMod,c.height,
                !w.instant && w.speed>0.f,w.guided,(w.ballistic || w.high) && !w.guided,
                w.range+def->GetRadius()*w.beamTargetBorder,w.beamMinIntensity,c.radius+def->GetRadius()});
        }
    };
    // All queries are local. No RangedWorld::Refresh/global army census here.
    // O(E*W+F), retained buffers; effective definition metadata is cached by
    // RangedWorld for this AI lifetime. Enemy reload is never read without LOS.
    const auto& enemies=ai->GetCallback()->GetEnemyUnitIdsIn(pos,options.scan,false);
    if(commanderTrace && frame%30<3) ai->LOG("[CommanderTrace] query unit=%i x=%.0f z=%.0f count=%i",unit->GetId(),pos.x,pos.z,int(enemies.size()));
    for(int id:enemies) {
        auto* enemy=ai->GetEnemyInfo(id);
        if(commanderTrace && frame%30<3) ai->LOG("[CommanderTrace] contact id=%i known=%i hidden=%i los=%i neutral=%i dead=%i dying=%i",id,int(enemy!=nullptr),enemy?enemy->IsHidden():0,enemy?enemy->IsInLOS():0,enemy?enemy->GetData()->IsNeutral():0,enemy?enemy->GetData()->IsDead():0,enemy?enemy->GetData()->IsDying():0);
        if(!enemy) continue;
        const auto data=enemy->GetData()->GetData();
        if(data.losStatus & (SEnemyData::HIDDEN|SEnemyData::NEUTRAL|SEnemyData::DEAD|SEnemyData::DYING)) continue;
        // IsHidden also includes profile threat suppression (IGNORE). Match
        // RangedWorld's legal-contact filter: a zero strategic threat weight
        // must not blind local commander defence to visible T1 attackers.
        if(data.IsIgnore() && (!enemy->GetCircuitDef() || !enemy->GetCircuitDef()->IsIgnore()
            || enemy->GetUnit()->GetRulesParamFloat("ignoredByAI",0.f)>0.f)) continue;
        if(!enemy->IsInLOS()) {
            // Radar uncertainty contributes danger, never a precision aim.
            threats.push_back({P(enemy->GetPos()),{},450,250,1,0,100,0,-1,0,enemy->GetPos().y,false,false});
            // Under water and out of sight: sonar shows an amphibious threat
            // that LOS-based T3 tracking cannot see yet.
            if(enemy->GetPos().y<-20.f && enemy->GetPos().SqDistance2D(pos)<SQUARE(options.t3Distance)) submergedContact=true;
            // A previously identified radar contact keeps its definition; its
            // last known position is conservative for the fallback group.
            auto* known=enemy->GetCircuitDef();
            if(known && canHit(world->CapabilitiesFor(known)))
                attackers.push_back({P(enemy->GetPos()),known->GetCostM()});
            continue;
        }
        auto* ed=enemy->GetCircuitDef(); if(!ed) continue;
        // Unit_getPos leaves the buffer untouched for an id it cannot
        // resolve (e.g. given this frame); never route on stale garbage.
        float raw[3]={NAN,NAN,NAN}; api->GetPosition(id,raw); AIFloat3 ep(raw[0],raw[1],raw[2]);
        if(!OnMap(ep)) continue;
        api->GetVelocity(id,raw);
        const auto& cap=world->CapabilitiesFor(ed);
        commander::Contact c;
        c.id=id; c.pos=P(ep); c.velocity={raw[0]*30,raw[2]*30};
        c.radius=cap.radius; c.cost=ed->GetCostM(); c.health=enemy->GetUnit()->GetHealth(); c.height=ep.y;
        c.blocker=ed->IsRoleComm() && !ActualDecoy(ed);
        c.t3=DefinitionFor(ed).t3; // one lookup here instead of two per contact per tick
        c.targetable=!ed->IsAbleToFly() && ep.y>=-c.radius*.4f
            && (ed->GetCategory() & def->GetTargetCategoryDGun())!=0;
        // Default D-gun damage is deliberately conservative for repeat-hit T3.
        // A shield makes a promised one-shot inappropriate; reobserve after fire.
        c.damage=def->GetDGunDef()->GetDamage()*(ed->GetShieldMount()?.35f:1.f);
        c.stopAfter=ed->GetShieldMount()!=nullptr;
        c.reserved=claims.Reserved(id,ai->GetTeamId(),unit->GetId())>=c.health;
        contacts.push_back(c);
        if(c.targetable && !c.blocker) seeds.push_back(int(contacts.size()-1));
        if(enemy->GetUnit()->IsBeingBuilt() || enemy->GetUnit()->IsParalyzed()
            || enemy->GetUnit()->GetRulesParamFloat("disarmed",0)>0) continue;
        if(canHit(cap)) attackers.push_back({c.pos,c.cost});
        observeWeapons(id,c,cap);
    }
    // Bounded candidate seeds, but ScoreLine still scores every local contact.
    const auto order=[this](int a,int b) {
        const auto& x=contacts[a]; const auto& y=contacts[b];
        return x.cost==y.cost?x.id<y.id:x.cost>y.cost;
    };
    std::partial_sort(seeds.begin(),seeds.begin()+std::min(size_t(12),seeds.size()),seeds.end(),order);
    if(seeds.size()>12) seeds.resize(12);
    // Friendly contacts matter only with enemies observed (line safety,
    // support, jammers, splash and screen checks) or for the once-a-second
    // advance deployment plan. Skipping the scan otherwise removes the idle
    // cost measured in the 16-commander population arena (review finding 2):
    // 4-5 engine callbacks per nearby friendly every 3 frames, discarded.
    const auto self=commanders.find(unit->GetId());
    const bool deployDue=options.advance && !options.frontDuty && self!=commanders.end() && frame>=self->second.lastLog+30;
    const bool farT3=self!=commanders.end() && !self->second.farT3.empty();
    // ...and while a T3 engagement, a declined T3 or a fallback is active: the
    // splash checks of a cloaked scout need the friendlies a lost T3 is
    // shelling (b42 walled Behemoth: no enemy in sight, friends skipped,
    // scouted through the shelled wall).
    const bool engagedT3=self!=commanders.end()
        && (self->second.t3Target>=0 || self->second.t3Declined>=0 || self->second.fallback);
    const bool needFriends=!contacts.empty() || !threats.empty() || !attackers.empty() || deployDue || farT3 || engagedT3;
    static const std::vector<int> none;
    const auto& friends=needFriends?ai->GetCallback()->GetFriendlyUnitIdsIn(pos,options.scan,false):none;
    for(int id:friends) {
        if(id==unit->GetId()) continue;
        auto* fd=ai->GetCircuitDefSafe(ai->GetCallback()->Unit_GetDefId(id));
        if(!fd) continue;
        float raw[3]={NAN,NAN,NAN}; api->GetPosition(id,raw); const float y=raw[1];
        if(!OnMap(AIFloat3(raw[0],raw[1],raw[2]))) continue;
        commander::Contact c; c.id=id; c.pos={raw[0],raw[2]}; c.height=y;
        api->GetVelocity(id,raw); c.velocity={raw[0]*30,raw[2]*30};
        c.radius=fd->GetRadius(); c.friendly=true; c.blocker=fd->IsRoleComm();
        c.targetable=false;
        c.cost=fd->IsAttacker() && !fd->IsRoleComm() && !fd->IsAbleToFly()
            && api->GetCombatHealth(id)>0 ? fd->GetCostM():0;
        // High flying aircraft do not intersect a ground-hugging projectile.
        if(y>ai->GetMap()->GetElevationAt(c.pos.x,c.pos.z)+c.radius+32 && fd->IsAbleToFly()) continue;
        contacts.push_back(c);
    }
    // D-294: T3 artillery shells the line from beyond the 3-frame scan. Once a
    // second per commander, one wider query keeps only in-LOS T3 definitions
    // (O(E') ids, map lookups only); they join the contacts so Intercept can
    // hunt them. Their positions are re-read every observation.
    auto found=commanders.find(unit->GetId());
    if(found==commanders.end() || options.t3Intercept<=0 || options.t3HuntLeash<=options.scan) return;
    auto& st=found->second;
    if(frame>=st.farT3Frame+FRAMES_PER_SEC) {
        st.farT3Frame=frame; st.farT3.clear();
        for(int id:ai->GetCallback()->GetEnemyUnitIdsIn(pos,options.t3HuntLeash,false)) {
            auto* enemy=ai->GetEnemyInfo(id);
            if(enemy && enemy->IsInLOS() && enemy->GetCircuitDef() && DefinitionFor(enemy->GetCircuitDef()).t3
                && enemy->GetPos().SqDistance2D(pos)>SQUARE(options.scan)) st.farT3.push_back(id);
        }
    }
    for(int id:st.farT3) {
        auto* enemy=ai->GetEnemyInfo(id);
        if(!enemy || !enemy->IsInLOS() || enemy->GetData()->IsDead()) continue;
        auto* ed=enemy->GetCircuitDef(); if(!ed) continue;
        float raw[3]={NAN,NAN,NAN}; api->GetPosition(id,raw); AIFloat3 ep(raw[0],raw[1],raw[2]);
        if(!OnMap(ep) || ep.SqDistance2D(pos)<=SQUARE(options.scan)) continue;
        api->GetVelocity(id,raw);
        const auto& cap=world->CapabilitiesFor(ed);
        commander::Contact c;
        c.id=id; c.pos=P(ep); c.velocity={raw[0]*30,raw[2]*30};
        c.radius=cap.radius; c.cost=ed->GetCostM(); c.health=enemy->GetUnit()->GetHealth(); c.height=ep.y;
        c.targetable=!ed->IsAbleToFly() && ep.y>=-c.radius*.4f && (ed->GetCategory() & def->GetTargetCategoryDGun())!=0;
        c.damage=def->GetDGunDef()->GetDamage()*(ed->GetShieldMount()?.35f:1.f);
        c.stopAfter=ed->GetShieldMount()!=nullptr;
        c.reserved=claims.Reserved(id,ai->GetTeamId(),unit->GetId())>=c.health;
        c.t3=true; // the far query keeps T3 definitions only
        contacts.push_back(c);
        // Same legal LOS-only weapon observation as the near scan. The distance
        // exclusion above makes crossing the boundary count each weapon once.
        if(!enemy->GetUnit()->IsBeingBuilt() && !enemy->GetUnit()->IsParalyzed()
            && enemy->GetUnit()->GetRulesParamFloat("disarmed",0)<=0) observeWeapons(id,c,cap);
    }
}

float CCommanderControl::Exposure(Point from,Point to,float seconds,float height,bool moving,float newVolleyRisk) const {
    float total=0;
    for(const auto& t:threats) {
        const float distance=std::min(commander::Length(t.pos-from),commander::Length(t.pos-to));
        const float heightRange=std::max(0.f,t.height-height)*std::max(0.f,t.heightMod);
        if(distance>t.range+heightRange+t.splash+32) continue;
        // Reload is evidence of a window, not evidence that its last projectile
        // missed us. Include one in-flight salvo while inside its flight time.
        const float flight=t.projectile?distance/std::max(1.f,t.speed):0;
        // A moving commander dodges most unguided shells: ballistic arcs, and
        // straight-flying missiles with over 0.6 s of flight (corcat, b19).
        const bool dodgeable=!t.guided && (t.ballistic || (t.projectile && flight>.6f));
        const float hit=moving && dodgeable?.35f:1.f;
        // Recoil BeamLaser damage falls with beam length. Subtract both unit
        // radii as a conservative muzzle/surface bound, not a guessed rear arc.
        const float intensity=commander::BeamIntensity(distance-t.beamClearance,t.beamRange,t.beamMinIntensity);
        total+=hit*intensity*t.damage*commander::ImpactVolleys(seconds,t.reload,t.delay,flight,newVolleyRisk);
    }
    for(const auto& p:projectiles) {
        if(ai->GetLastFrame()-p.frame>6) continue;
        const Point relative=p.pos-to;
        const float v2=commander::Dot(p.velocity,p.velocity);
        const float time=v2>0?std::clamp(-commander::Dot(relative,p.velocity)/v2,0.f,seconds):0;
        if(commander::Length(relative+p.velocity*time)<p.radius+32) total+=1500;
    }
    return total;
}
bool CCommanderControl::Route(CCircuitUnit* unit,const AIFloat3& from,const AIFloat3& to) const {
    auto* terrain=ai->GetTerrainManager();
    if(!OnMap(from) || !OnMap(to) || !terrain->CanReachAt(unit,to,8)) return false;
    // Small local moves, sampled across the movement footprint at 24 elmos.
    // End-point reachability alone does not prove a lateral ramp is traversable.
    const int n=std::max(1,int(std::ceil((to-from).Length2D()/24.f)));
    for(int i=1;i<=n;++i) {
        AIFloat3 p=from+(to-from)*(float(i)/n);
        if(!terrain->CanMoveToPos(unit->GetArea(),p)) return false;
    }
    return true;
}
void CCommanderControl::Move(CCircuitUnit* unit,State& s,const AIFloat3& goal,int frame) {
    // Exact destination, ownership and live queue suffix must all agree. A
    // swallowed order or move failure is reissued; a moving target is new intent.
    if(!s.route.empty() && s.goal==goal && ai->GetUnitAPI()->HasRouteIntent(unit->GetId(),s.route,frame)) return;
    CheckPerimeter(unit,s,goal,frame,"move");
    s.goal=goal; s.route={{CMD_MOVE,0,frame+90,goal.x,goal.y,goal.z}};
    TRY_UNIT(ai,unit,unit->CmdMoveTo(goal,0,frame+90);)
}
void CCommanderControl::Conceal(CCircuitUnit* unit,State& s,bool value) {
    const int fire=value?CCircuitDef::FireType::HOLD:CCircuitDef::FireType::OPEN;
    if(unit->GetRequestedFireState()!=fire) unit->TrySetFireState(fire);
    if(value!=s.cloak) {
        TRY_UNIT(ai,unit,unit->CmdCloak(value);)
        s.cloak=value;
    }
}
void CCommanderControl::Transition(CCircuitUnit* unit,State& s,Mode mode,int frame) {
    if(s.mode==mode) return;
    s.mode=mode; s.route.clear();
    if(mode==Mode::SUPPORT) { s.budget=0; s.target=-1; s.leaseUntil=0; }
    ai->LOG("[Commander] unit=%i generation=%i state=%i frame=%i",unit->GetId(),s.generation,int(mode),frame);
}
void CCommanderControl::Update() {
    performance::Scope measured(ai,performance::COMMANDER_DECISION);
    const int frame=ai->GetLastFrame(); reserve=0;
    for(auto& [id,s]:commanders) {
        auto* unit=ai->GetTeamUnit(id); if(!unit || unit->IsDead()) continue;
        if(!Handles(unit)) {
            ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),id);
            if(auto* task=dynamic_cast<CCommanderTask*>(unit->GetTask())) task->Resume(unit);
            s.budget=0; s.fundingBudget=0; s.pending=-1; s.mode=Mode::SUPPORT; continue;
        }
        // Fixed three-frame active/idle observation cadence independent of the
        // total action population. Immediate own-shot/move-failure invalidation.
        if(frame>=s.fundingUntil || !ai->GetEnemyInfo(s.fundingTarget)) s.fundingBudget=0;
        if(frame>=s.next) { s.next=frame+3; Tick(unit,s,frame); }
        reserve+=std::max(s.budget,s.fundingBudget);
    }
}
void CCommanderControl::Tick(CCircuitUnit* unit,State& s,int frame) {
    auto* current=unit->GetTask();
    auto* task=dynamic_cast<CCommanderTask*>(current);
    const bool trace=commanderTrace && frame%30<3;
    if(trace) ai->LOG("[CommanderTrace] unit=%i task=%i morph=%i stun=%i disarm=%i build=%i external=%i reclaim=%i transported=%.0f retry=%i",unit->GetId(),current?int(current->GetType()):-1,unit->IsMorphing(),unit->GetUnit()->IsParalyzed(),unit->IsDisarmed(frame),unit->GetUnit()->IsBeingBuilt(),current?current->IsExternalControlled():0,current?current->IsEnemyReclaim():0,unit->GetUnit()->GetRulesParamFloat("circuit_comm_transported",0),s.retry);
    if(s.invalidated) {
        ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
        s.invalidated=false; s.budget=0; s.fundingBudget=0; s.deployed=false;
        EndT3(unit,s,frame,"invalidated");
        if(task) { ai->GetBuilderManager()->AbortTask(task); Transition(unit,s,Mode::SUPPORT,frame); return; }
    }
    if(!current || current->GetType()==IUnitTask::Type::PLAYER || current->IsEnemyReclaim()
        || current->IsExternalControlled() || unit->IsMorphing() || unit->GetUnit()->IsBeingBuilt()
        || unit->GetUnit()->IsParalyzed() || unit->IsDisarmed(frame)
        || unit->GetUnit()->GetRulesParamFloat("circuit_comm_transported",0)>0) {
        s.budget=0; s.fundingBudget=0; s.pending=-1; s.leaseUntil=0;
        EndT3(unit,s,frame,"ownership");
        ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
        if(task) task->Resume(unit);
        return;
    }
    if(!task && s.mode!=Mode::SUPPORT) {
        ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
        Transition(unit,s,Mode::SUPPORT,frame); s.pending=-1;
        s.retry=frame+30; // external retreat/role takeover wins
    }
    if(!task && frame<s.retry) return;
    const AIFloat3 pos=unit->GetPos(frame);
    if(pos.y>ai->GetMap()->GetElevationAt(pos.x,pos.z)+unit->GetCircuitDef()->GetRadius()*2.f) {
        // The C AI interface has no transporter query. Suspended ground units
        // are not legal firing origins; the optional adapter adds exact status.
        s.budget=0; if(task) task->Resume(unit); return;
    }
    auto* def=unit->GetCircuitDef();
    const auto& cap=ai->GetMilitaryManager()->GetRangedWorld()->CapabilitiesFor(def);
    const float speed=std::max(1.f,cap.speed);
    const float hp=unit->GetUnit()->GetHealth(),maxHp=unit->GetUnit()->GetMaxHealth();
    const float bank=ai->GetEconomyManager()->GetEnergyCur();
    const float shot=def->GetDGunDef()->GetCostE();
    const float range=unit->GetDGunRange()-12;
    Observe(unit,frame);
    if(trace) ai->LOG("[CommanderTrace] observation unit=%i contacts=%i seeds=%i threats=%i y=%.0f",unit->GetId(),int(contacts.size()),int(seeds.size()),int(threats.size()),pos.y);
    // D-294: a T3 in range is engaged from the line (concealed per-T3 plan)
    // ahead of the D-293 withdrawal, which then covers everything else.
    if(Intercept(unit,s,frame)) return;
    if(current->GetType()==IUnitTask::Type::RETREAT && Handles(unit)) {
        const bool hide=RetreatCloakFunded(unit) && CloakSafe(unit,P(pos),P(pos),options.escapeSeconds);
        unit->TrySetFireState(hide?CCircuitDef::FireType::HOLD:CCircuitDef::FireType::RETURN);
    }
    // Under fire from an attacker it cannot see (a submerged amphibious T3,
    // fire from beyond sight) and no known T3 owns the situation: cloak and
    // step back toward base for a few seconds (b43: a submerged Juggernaut
    // lasered an uncloaked shore commander from 3,700 to 2,641 HP). Scoped to
    // unknown attackers: a known T3 is already owned by the engagement or the
    // fallback (b44: at base, repeated withdrawals pre-empted re-engaging).
    // Shore only: on land an unseen shooter is a known kind of threat (long
    // range beyond sight) that the T3 plan and fallback handle; withdrawing
    // there broke Behemoth engagements (b50: walled and no-defence failed).
    const bool knownT3=s.t3Target>=0 || s.t3Declined>=0 || s.fallback;
    if(!knownT3 && frame-s.lastDamage<FRAMES_PER_SEC && seeds.empty() && threats.empty() && attackers.empty()) {
        const AIFloat3 here=unit->GetPos(frame);
        bool nearWater=false;
        // 16 samples on two rings (300, 700): a shore line usually stands a few
        // hundred elmos back from the waterline.
        for(int i=0;i<16 && !nearWater;++i) {
            const float a=float(i%8)*.7853982f,r=i<8?300.f:700.f;
            nearWater=ai->GetMap()->GetElevationAt(here.x+std::cos(a)*r,here.z+std::sin(a)*r)<0.f;
        }
        if(nearWater) s.unseenUntil=frame+3*FRAMES_PER_SEC;
    }
    if(knownT3) s.unseenUntil=0;
    if(frame<s.unseenUntil && seeds.empty() && threats.empty() && current->GetType()!=IUnitTask::Type::RETREAT) {
        auto* def=unit->GetCircuitDef();
        const auto& capU=ai->GetMilitaryManager()->GetRangedWorld()->CapabilitiesFor(def);
        auto* t=dynamic_cast<CCommanderTask*>(current);
        if(capU.cloak && ai->GetEconomyManager()->GetEnergyCur()>=def->GetDGunDef()->GetCostE()+capU.cloakMoving*options.escapeSeconds) {
            if(!t) {
                t=ai->GetBuilderManager()->EnqueueCommander(current);
                ai->GetBuilderManager()->AssignTask(unit,t);
                if(unit->GetTask()!=t) { ai->GetBuilderManager()->AbortTask(t); t=nullptr; }
                else { s.started=frame; s.cloak=unit->GetUnit()->IsCloaked(); ++operation; TRY_UNIT(ai,unit,unit->CmdStop();) }
            }
            if(t) {
                Conceal(unit,s,true); Transition(unit,s,Mode::ESCAPE,frame);
                const AIFloat3 here=unit->GetPos(frame);
                AIFloat3 back=F(P(here)+commander::Normal(P(ai->GetSetupManager()->GetBasePos())-P(here))*options.step*2.f);
                back.y=ai->GetMap()->GetElevationAt(back.x,back.z);
                if(back.y>=0 && Route(unit,here,back)) Move(unit,s,back,frame);
                if(frame>=s.lastLog+60) { s.lastLog=frame; ai->LOG("[Commander] unit=%i unseen_fire withdraw frame=%i",unit->GetId(),frame); }
                return;
            }
        }
    }
    // A submerged sonar contact approaching the shore: cloak and wait in
    // place (stationary cloak, 100 E/s) until it surfaces, when the T3 plan
    // takes over (b43: a submerged legeheatraymech beamed an uncloaked shore
    // commander for 2,000 HP before it was ever in sight).
    if(submergedContact && !s.fallback && current->GetType()!=IUnitTask::Type::RETREAT) {
        auto* def=unit->GetCircuitDef();
        const auto& capW=ai->GetMilitaryManager()->GetRangedWorld()->CapabilitiesFor(def);
        auto* t=dynamic_cast<CCommanderTask*>(current);
        if(capW.cloak && ai->GetEconomyManager()->GetEnergyCur()>=def->GetDGunDef()->GetCostE()+capW.cloakCost*options.escapeSeconds) {
            if(!t) {
                t=ai->GetBuilderManager()->EnqueueCommander(current);
                ai->GetBuilderManager()->AssignTask(unit,t);
                if(unit->GetTask()!=t) { ai->GetBuilderManager()->AbortTask(t); t=nullptr; }
                else { s.started=frame; s.cloak=unit->GetUnit()->IsCloaked(); ++operation; TRY_UNIT(ai,unit,unit->CmdStop();) }
            }
            if(t) {
                Conceal(unit,s,true); Transition(unit,s,Mode::ASSESS,frame);
                if(frame>=s.lastLog+90) { s.lastLog=frame; ai->LOG("[Commander] unit=%i submerged_contact conceal frame=%i",unit->GetId(),frame); }
                return;
            }
        }
    }
    if(Fallback(unit,s,current,frame)) return;
    if(seeds.empty() && threats.empty()) {
        s.budget=0;
        if(Deploy(unit,s,frame)) return;
        if(task) { Conceal(unit,s,false); Transition(unit,s,Mode::SUPPORT,frame); task->Resume(unit); }
        return;
    }
    float support=0,nearest=options.scan;
    Point supported=P(pos),toward;
    bool enemyNearby=false;
    for(const auto& c:contacts) {
        const float distance=commander::Length(c.pos-P(pos));
        if(c.friendly) {
            if(distance<450) support+=c.cost;
        } else {
            enemyNearby=true;
            if(distance<nearest) { nearest=distance; toward=commander::Normal(c.pos-P(pos)); }
        }
    }
    // A local screen supplies both a supported forward point and an exit.
    float bestSupport=-1;
    for(const auto& c:contacts) if(c.friendly && c.cost>0) {
        const float score=commander::Dot(c.pos-P(pos),toward)-commander::Length(c.pos-P(pos))*.2f;
        if(score>bestSupport) { bestSupport=score; supported=c.pos-toward*100.f; }
    }
    AIFloat3 home=ai->GetSetupManager()->GetBasePos();
    AIFloat3 safe=F(support>=options.support?supported:P(pos)-toward*options.step);
    if(!enemyNearby) safe=home;
    safe.y=ai->GetMap()->GetElevationAt(safe.x,safe.z);
    if(!Route(unit,pos,safe)) safe=home;
    const float exposed=Exposure(P(pos),P(safe),1.f,pos.y);
    const bool emergency=nearest<range*.85f && exposed>hp*.12f;
    if(!task && current->GetType()==IUnitTask::Type::RETREAT && !emergency) { s.budget=0; return; }
    const bool endangered=hp/maxHp<options.retreat || !commander::Survivable(hp,maxHp,exposed,options.hpReserve);
    const bool front=options.advance && ai->GetFactoryManager()->GetFactoryCount()>0
        && ai->GetBuilderManager()->GetWorkerCount()>options.frontWorkers;

    if(task && s.pending>=0) {
        if(unit->GetDGunReloadFrame()>frame) {
            s.fired=frame; s.pending=-1; Transition(unit,s,Mode::ESCAPE,frame);
        } else if(frame-s.pending>30) {
            ai->LOG("[Commander] unit=%i shot_timeout frame=%i",unit->GetId(),frame);
            s.pending=-1; s.leaseUntil=0; s.retry=frame+15;
            ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
            Transition(unit,s,Mode::ESCAPE,frame);
        } else if(!endangered || emergency || (options.frontDuty && unit->GetUnit()->IsCloaked()
            && CloakSafe(unit,P(pos),P(pos),.1f))) return;
        else {
            s.pending=-1; s.leaseUntil=0;
            ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
            Transition(unit,s,Mode::ESCAPE,frame);
        }
    }
    if(!enemyNearby && task) {
        Conceal(unit,s,false); Transition(unit,s,Mode::SUPPORT,frame); task->Resume(unit); return;
    }

    const bool wantCloak=cap.cloak && options.cloakSeconds>0 && nearest>55 && support>=options.support;
    const float cloakBudget=commander::Reserve(shot,options.shots,cap.cloakCost,cap.cloakMoving,
        options.alignSeconds,options.cloakSeconds+options.escapeSeconds,options.margin);
    const bool fundedCloak=wantCloak && bank>=cloakBudget;
    s.budget=enemyNearby? (wantCloak?cloakBudget:shot*options.shots+options.margin):0;
    // Never count a transfer acknowledgement as funds: actual bank only.
    const float spendable=bank-std::max(0.f,reserve);
    const bool ready=unit->IsDGunReady(frame,spendable) && frame>=s.retry;
    commander::Line best;
    AIFloat3 bestPos=pos;
    const float projectileSpeed=std::max(1.f,def->GetDGunDef()->GetDef()->GetProjectileSpeed()*30.f);
    const float width=std::min(24.f,std::max(4.f,def->GetDGunDef()->GetAoe()*.25f));
    const float aggression=ai->GetMilitaryManager()->GetAggression();
    const float minValue=commander::MinimumValue(options.minValue,aggression,options.aggression);
    const float maxLoss=std::clamp(options.hpReserve-aggression*.04f,.2f,.85f);
    // Five positions x <=12 directions, each O(E+F). No pairwise unit search.
    const Point lateral={-toward.z,toward.x};
    const std::array<Point,5> offsets={Point{},lateral*options.step,lateral*(-options.step),
        toward*std::min(options.step,options.maxApproach),toward*(-options.step)};
    for(size_t i=0;i<offsets.size();++i) {
        if(i>0 && (endangered || support<options.support || nearest>range+options.maxApproach)) continue;
        AIFloat3 candidate=F(P(pos)+offsets[i]);
        candidate.y=ai->GetMap()->GetElevationAt(candidate.x,candidate.z);
        // No submerged manual fire; shore movement may still use normal torpedo.
        if(candidate.y<0 || (i>0 && !Route(unit,pos,candidate))) continue;
        if(i>0 && candidate.SqDistance2D(home)>options.leash*options.leash && !emergency) continue;
        const float travel=i==0?0.f:commander::TravelSeconds(commander::Length(offsets[i]),speed,
            cap.acceleration,cap.turnRate,i==3?0.f:1.5707963f);
        const float escape=commander::Length(P(candidate)-P(safe))/speed;
        const float risk=Exposure(P(pos),P(candidate),travel+options.alignSeconds+1.f,pos.y)
            +Exposure(P(candidate),P(safe),std::min(options.escapeSeconds,escape),candidate.y);
        if(i>0 && !commander::Survivable(hp,maxHp,risk,maxLoss)) continue;
        for(int index:seeds) {
            const auto& seed=contacts[index];
            Point dir=seed.pos+seed.velocity*(commander::Length(seed.pos-P(candidate))/projectileSpeed)-P(candidate);
            auto line=commander::ScoreLine(contacts,P(candidate),dir,range,projectileSpeed,width,
                options.killReward,options.friendlyMargin);
            // Reject impossible height intersections without treating ridges as
            // universal DGun blockers. Ground aim and subsequent fresh checks
            // handle the game's ground-hugging projectile behavior.
            if(std::abs(seed.height-std::max(0.f,candidate.y))>range*.5f) continue;
            line.value-=travel*60.f+risk*.05f;
            if(line.value>best.value) { best=line; bestPos=candidate; }
        }
        if(emergency && best.target>=0) break;
    }

    const bool opportunity=best.target>=0 && (best.value>=minValue || emergency);
    if(trace) ai->LOG("[CommanderTrace] unit=%i contacts=%i seeds=%i range=%.1f target=%i value=%.1f min=%.1f ready=%i danger=%i support=%.1f home=%.1f,%.1f",unit->GetId(),int(contacts.size()),int(seeds.size()),range,best.target,best.value,minValue,ready,endangered,support,home.x,home.z);
    // A visible unit outside useful firing range is not a reason to lock a
    // healthy front commander in combat. Deployment and role construction
    // keep their owner until a real attack/withdrawal opportunity appears.
    if(options.frontDuty && !opportunity && !endangered && s.pending<0) {
        if(Deploy(unit,s,frame)) return;
        if(task) { Conceal(unit,s,false); Transition(unit,s,Mode::SUPPORT,frame); task->Resume(unit); }
        return;
    }
    if(!task) {
        const bool defend=endangered && enemyNearby;
        const bool attack=opportunity && (nearest<=range+32 || (support>=options.support && front));
        // A distant observer must not reserve the only emergency shot away
        // from another owned commander that can actually engage now.
        if(!defend && !attack) { s.budget=0; Deploy(unit,s,frame); return; }
        // Enemy reclaim and explicit no-disrupt construction are protected.
        if(def->IsAttrNoDisrupt() && !defend) return;
        task=ai->GetBuilderManager()->EnqueueCommander(current);
        ai->GetBuilderManager()->AssignTask(unit,task);
        if(unit->GetTask()!=task) { ai->GetBuilderManager()->AbortTask(task); return; }
        s.started=frame; s.exit=safe; s.failed=0; s.cloak=unit->GetUnit()->IsCloaked(); ++operation;
        Transition(unit,s,Mode::ASSESS,frame);
        unit->TrySetMoveState(CCircuitDef::MoveType::HOLD_POS);
        // Clear construction/movement commands before taking a precision shot.
        TRY_UNIT(ai,unit,unit->CmdStop();)
    }
    // One command owner is an executable invariant, not a Blocker assumption.
    if(unit->GetDGunAct()!=nullptr || task->GetAssignees().size()!=1 || task->GetAssignees().count(unit)!=1) {
        ai->LOG("[INVARIANT] INV-214 commander combat has competing owner unit=%i",unit->GetId());
        task->Resume(unit); return;
    }
    if(opportunity && ready && bestPos.SqDistance2D(pos)<16.f*16.f
        && (!endangered || emergency)) {
        if(Fire(unit,s,best,frame)) return;
    }
    const bool expired=frame-s.started>int(options.maxSeconds*30) || s.failed>=2;
    if(!opportunity && !endangered && s.fired>=s.started && frame-s.fired>=27) {
        // Once the firing window closes, ordinary work/weapons should handle
        // a cheap survivor. Do not oscillate ASSESS/ESCAPE every observation
        // or spend a full lease cloaked beside a safe, low-value target. Before
        // the first shot, retain the bounded alignment lease: a moving column
        // can briefly lose value while the commander reaches its firing point.
        Conceal(unit,s,false); Transition(unit,s,Mode::SUPPORT,frame);
        s.retry=frame+15; task->Resume(unit); return;
    }
    if(endangered || expired || s.mode==Mode::ESCAPE || !opportunity) {
        Transition(unit,s,Mode::ESCAPE,frame);
        Conceal(unit,s,fundedCloak && bank>shot+cap.cloakMoving);
        AIFloat3 exit=safe;
        // Consider both reachable side exits, including projectile volumes
        // when the optional ally-LOS adapter is present. Never infer a blind
        // rear arc from a forward-facing weapon definition alone.
        float exitRisk=Exposure(P(pos),P(exit),options.escapeSeconds,pos.y);
        for(float side:{-1.f,1.f}) {
            AIFloat3 lateralExit=F(P(pos)+lateral*(side*options.step)-toward*(options.step*.5f));
            lateralExit.y=ai->GetMap()->GetElevationAt(lateralExit.x,lateralExit.z);
            if(!Route(unit,pos,lateralExit)) continue;
            const float risk=Exposure(P(pos),P(lateralExit),options.escapeSeconds,pos.y);
            if(risk<exitRisk) { exitRisk=risk; exit=lateralExit; }
        }
        if(Exposure(P(pos),P(exit),1.f,pos.y)>exposed && Route(unit,pos,s.exit)) exit=s.exit;
        if(Route(unit,pos,exit) && exit.SqDistance2D(pos)>32*32) Move(unit,s,exit,frame);
        if(expired || nearest>range+200 || hp/maxHp<options.retreat) {
            Conceal(unit,s,false); Transition(unit,s,Mode::RECOVER,frame);
            s.retry=frame+60; s.budget=0; s.leaseUntil=0;
            bool lineRepair=false;
            if(options.frontDuty && hp/maxHp>=options.retreat
                && commander::Survivable(hp,maxHp,Exposure(P(pos),P(pos),options.escapeSeconds,pos.y),options.retreat)) {
                // Existing local contacts only; no global builder scan. A real,
                // completed allied builder must be in range of the commander.
                for(const auto& c:contacts) if(c.friendly) {
                    const auto* ally=ai->GetFriendlyUnit(c.id);
                    const auto* repair=ally?ally->GetCircuitDef():nullptr;
                    if(repair && repair->IsBuilder() && repair->GetWorkerTime()>0
                        && commander::Length(c.pos-P(pos))<=repair->GetBuildDistance()
                        && !ally->GetUnit()->IsBeingBuilt() && !ally->GetUnit()->IsParalyzed()) {
                        lineRepair=true; break;
                    }
                }
            }
            if(hp/maxHp<options.recover && !lineRepair) {
                auto* retreat=ai->GetBuilderManager()->EnqueueRetreat();
                ai->GetBuilderManager()->AssignTask(unit,retreat);
            } else task->Resume(unit);
        } else if(opportunity && frame-s.fired>=27 && !endangered) Transition(unit,s,Mode::ASSESS,frame);
        return;
    }
    if(bestPos.SqDistance2D(pos)>16*16 && support>=options.support && ready) {
        // Cloak requests do not prove concealment. Wait briefly for actual
        // cloak; never expand our risk budget on the strength of a request.
        Conceal(unit,s,fundedCloak);
        if(fundedCloak && !unit->GetUnit()->IsCloaked() && frame-s.started<30) return;
        if(frame-s.started>int((options.alignSeconds+options.maxApproach/speed)*30)) {
            Transition(unit,s,Mode::ESCAPE,frame); return;
        }
        Transition(unit,s,Mode::ALIGN,frame); Move(unit,s,bestPos,frame);
    } else {
        // Normal weapons keep firing while waiting for bank/reload. No pointless
        // movement loop that interrupts Legion's longer heat-ray contact.
        Conceal(unit,s,false); Transition(unit,s,Mode::ASSESS,frame);
    }
}

bool CCommanderControl::Deploy(CCircuitUnit* unit,State& s,int frame) {
    performance::Scope measured(ai,performance::COMMANDER_DEPLOY);
    auto* task=dynamic_cast<CCommanderTask*>(unit->GetTask());
    if(FallbackActive(s,frame)) return false; // the porc line bounds exploration
    if(options.frontDuty) {
        // Let the existing idle scheduler offer construction after arrival.
        // Only deployment yields; local combat observation never pauses.
        if(frame<s.frontYield) return false;
        if(!options.frontReady || unit->GetHealthPercent()<options.recover
            || unit->GetTask()->GetType()==IUnitTask::Type::RETREAT) return false;
        // D-299: hold the last fallback line until its turret quota stands
        // (bounded by line_hold_seconds); the ladder offers that work.
        if(frame<s.lineUntil && !s.lineDone) return false;
        const auto pos=unit->GetPos(frame),goal=FrontPosition(unit,s,frame);
        if(goal.x<0 || Exposure(P(pos),P(pos),1.f,pos.y)>unit->GetUnit()->GetHealth()*.12f) return false;
        auto* build=dynamic_cast<IBuilderTask*>(unit->GetTask());
        // Finish a live frame/chain; planned base economy no longer prevents
        // deployment forever. Front work has its own bounded area and owner.
        // A ladder task (repair, reclaim, radar on the way) is local by
        // construction; finish it before walking on (D-299).
        if(build && (build->GetNextTask() || build->GetTarget() || build==s.workTask
            || build->GetPosition().SqDistance2D(goal)<=options.frontRadius*options.frontRadius)) return true;
        if(!task) {
            task=ai->GetBuilderManager()->EnqueueCommander(nullptr);
            ai->GetBuilderManager()->AssignTask(unit,task);
            if(unit->GetTask()!=task) { ai->GetBuilderManager()->AbortTask(task); return false; }
            s.started=frame; s.cloak=unit->GetUnit()->IsCloaked(); ++operation;
            ai->LOG("[CommanderFront] unit=%i deploy x=%.0f z=%.0f",unit->GetId(),goal.x,goal.z);
        }
        s.deployed=true; Conceal(unit,s,false); Transition(unit,s,Mode::SUPPORT,frame);
        if(pos.SqDistance2D(goal)<=options.frontRadius*options.frontRadius*.25f) {
            s.frontYield=frame+60;
            if(s.frontArrived<0) s.frontArrived=frame; // D-299 timed defence clock
            task->Resume(unit); // next builder callback selects front work
        } else {
            const Point delta=P(goal)-P(pos);
            AIFloat3 next=F(P(pos)+commander::Normal(delta)*std::min(240.f,commander::Length(delta)));
            next.y=ai->GetMap()->GetElevationAt(next.x,next.z);
            if(!s.route.empty() && s.goal.SqDistance2D(pos)>48*48
                && ai->GetUnitAPI()->HasRouteIntent(unit->GetId(),s.route,frame)) return true;
            if(Route(unit,pos,next)) Move(unit,s,next,frame);
        }
        return true;
    }
    if(!options.advance || unit->GetHealthPercent()<options.recover
        || ai->GetFactoryManager()->GetFactoryCount()==0
        || ai->GetBuilderManager()->GetWorkerCount()<=options.frontWorkers
        || unit->GetTask()->GetType()==IUnitTask::Type::RETREAT) return false;
    // Strategic planning uses the existing published enemy-group snapshot once
    // a second. Local threat observation remains at three frames while deployed.
    if(frame<s.lastLog+30) return s.deployed && task;
    s.lastLog=frame;
    const auto pos=unit->GetPos(frame);
    const auto enemy=ai->GetEnemyManager()->GetNearestGroupPos(pos,options.minValue);
    if(enemy.x<0) return false;
    const Point forward=commander::Normal(P(enemy)-P(pos));
    float support=0,best=64;
    Point anchor=P(pos);
    for(const auto& c:contacts) if(c.friendly && c.cost>0) {
        const float ahead=commander::Dot(c.pos-P(pos),forward);
        if(ahead>0 && commander::Length(c.pos-P(pos))<options.scan) support+=c.cost;
        if(ahead>best && ahead<600) { best=ahead; anchor=c.pos-forward*120.f; }
    }
    if(support<options.support) return false;
    const auto home=ai->GetSetupManager()->GetBasePos();
    AIFloat3 goal=F(anchor); goal.y=ai->GetMap()->GetElevationAt(goal.x,goal.z);
    if(goal.SqDistance2D(home)>options.leash*options.leash || !Route(unit,pos,goal)) return false;
    if(!task) {
        auto* old=unit->GetTask();
        // Productive frames retain priority until completed; wait/guard/patrol
        // work can yield to supported front deployment after the opening gates.
        auto* build=dynamic_cast<IBuilderTask*>(old);
        if(build && build->GetBuildDef()!=nullptr) return false;
        task=ai->GetBuilderManager()->EnqueueCommander(old);
        ai->GetBuilderManager()->AssignTask(unit,task);
        if(unit->GetTask()!=task) { ai->GetBuilderManager()->AbortTask(task); return false; }
        s.started=frame; s.failed=0; s.cloak=unit->GetUnit()->IsCloaked(); ++operation;
    }
    s.deployed=true; s.exit=pos;
    Conceal(unit,s,false); Transition(unit,s,Mode::SUPPORT,frame);
    if(goal.SqDistance2D(pos)>96*96) Move(unit,s,goal,frame);
    else if(s.route.empty() || !ai->GetUnitAPI()->HasRouteIntent(unit->GetId(),s.route,frame)) {
        // Native patrol performs opportunistic repair/reclaim in this supported
        // area. Combat preempts that one owner as soon as a local threat appears.
        CheckPerimeter(unit,s,goal,frame,"patrol");
        s.goal=goal; s.route={{CMD_PATROL,0,frame+300,goal.x,goal.y,goal.z}};
        TRY_UNIT(ai,unit,unit->CmdPatrolTo(goal,0,frame+300);)
    }
    return true;
}

bool CCommanderControl::ReceiveProjectiles(const char* message) {
    // Optional synced BAR adapter. No hidden identities, only ally-LOS
    // projectile volumes. Reject stale/future/unbounded packets atomically.
    if(!message || std::strncmp(message,"comm_projectiles|",17)!=0) return false;
    if(std::strlen(message)>16384) return true;
    std::istringstream input(message+17); int frame,count; char sep;
    if(!(input>>frame>>sep>>count) || sep!='|' || frame<=projectileFrame || frame>ai->GetLastFrame()
        || frame<ai->GetLastFrame()-3 || count<0 || count>128) return true;
    std::vector<Projectile> parsed; parsed.reserve(count);
    for(int i=0;i<count;++i) {
        Projectile p; p.frame=frame;
        if(!(input>>sep) || sep!='|' || !(input>>p.pos.x>>p.pos.z>>p.velocity.x>>p.velocity.z>>p.radius)
            || !std::isfinite(p.pos.x) || !std::isfinite(p.pos.z) || !std::isfinite(p.velocity.x)
            || !std::isfinite(p.velocity.z) || !(p.radius>=0 && p.radius<=1000)) return true;
        parsed.push_back(p);
    }
    input>>std::ws; if(!input.eof()) return true;
    projectiles=std::move(parsed); projectileFrame=frame; return true;
}
}
