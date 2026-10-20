#include "task/fighter/RangedWorld.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"
#include "module/MilitaryManager.h"
#include "setup/SetupManager.h"
#include "terrain/TerrainManager.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitWDef.h"
#include "unit/enemy/EnemyUnit.h"
#include "unit/enemy/EnemyManager.h"
#include "spring/SpringMap.h"
#include "spring/SpringUnit.h"
#include "spring/SpringCallback.h"
#include "util/Performance.h"
#include "Damage.h"
#include "WeaponMount.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace circuit {
using springai::AIFloat3;
static ranged::Point P(const AIFloat3& p) { return {p.x,p.z}; }
static const bool verifyRangedQueries=std::getenv("CIRCUIT_VERIFY_RANGED_QUERIES")!=nullptr;
CRangedWorld::CRangedWorld(CCircuitAI* circuit): circuit(circuit), friendlyOrder(MAX_UNITS)
{
    const float width=float(circuit->GetMap()->GetWidth()*SQUARE_SIZE);
    const float height=float(circuit->GetMap()->GetHeight()*SQUARE_SIZE);
    enemies.Configure(width,height); staticHazards.Configure(width,height);
    allies.Configure(width,height); formations.Configure(width,height);
    clusterValues.Configure(int(width/128.f)+1,int(height/128.f)+1);
}
CRangedWorld::Weapon::Weapon() = default;
CRangedWorld::Weapon::~Weapon() = default;
CRangedWorld::Weapon::Weapon(Weapon&&) noexcept = default;
CRangedWorld::Weapon& CRangedWorld::Weapon::operator=(Weapon&&) noexcept = default;
CRangedWorld::~CRangedWorld() = default;

const CRangedWorld::Metadata& CRangedWorld::MetadataFor(CCircuitDef* def)
{
    auto [it, fresh] = metadata.try_emplace(def->GetId());
    if (fresh) {
        auto* ud = def->GetDef();
        it->second = {float(ud->GetRadarRadius()), float(ud->GetJammerRadius()), def->GetLosRadius(), ud->GetArmorType()};
        const auto& params = ud->GetCustomParams();
        const auto level = params.find("techlevel");
        if (level != params.end()) it->second.tech = float(std::atof(level->second.c_str()));
        const std::unique_ptr<springai::WeaponDef> explosion(ud->GetDeathExplosion());
        if(explosion) {
            const std::unique_ptr<springai::Damage> damage(explosion->GetDamage());
            const auto types=damage ? damage->GetTypes() : std::vector<float>{};
            if(std::any_of(types.begin(),types.end(),[](float value){return value>0.f;}))
                it->second.explosionRadius=explosion->GetAreaOfEffect();
        }
    }
    return it->second;
}

const CRangedWorld::Capabilities& CRangedWorld::CapabilitiesFor(CCircuitDef* def)
{
    auto [it,fresh]=capabilities.try_emplace(def->GetId());
    auto& c=it->second;
    if (!fresh) return c;
    auto* ud=def->GetDef();
    c.speed=def->GetSpeed(); c.turnRate=ud->GetTurnRate();
    c.acceleration=ud->GetMaxAcceleration(); c.radius=def->GetRadius();
    c.cloak=def->IsAbleToCloak();
    c.cloakCost=ud->GetCloakCost(); c.cloakMoving=ud->GetCloakCostMoving();
    const std::unique_ptr<springai::WeaponDef> death(ud->GetDeathExplosion());
    if (death) c.blastRadius=death->GetAreaOfEffect(); // wrapper already returns radius
    for (auto* raw: ud->GetWeaponMounts()) {
        Weapon w; w.mount.reset(raw);
        const std::unique_ptr<springai::WeaponDef> wd(raw->GetWeaponDef());
        if (!wd || wd->IsShield() || wd->IsManualFire()) continue;
        const auto& params=wd->GetCustomParams();
        w.fake=params.find("fake_weapon")!=params.end();
        w.def=circuit->GetWeaponDef(wd->GetWeaponDefId());
        const std::unique_ptr<springai::Damage> damage(wd->GetDamage());
        if (damage) w.damage=damage->GetTypes();
        const bool carrier=def->GetRangedPolicy().mode==RangedPolicy::Mode::CARRIER;
        if (!carrier && (w.fake || w.damage.empty() || w.damage[0]<=0.f || wd->IsParalyzer())) continue;
        w.index=raw->GetWeaponMountId(); w.category=raw->GetOnlyTargetCategory();
        w.range=wd->GetRange(); w.arc=raw->GetMaxAngleDif();
        w.forward=w.arc>-.99f;
        w.reload=std::max(.1f,wd->GetReload());
        w.burst=std::max(wd->GetBeamTime(),wd->GetSalvoDelay()*std::max(0,wd->GetSalvoSize()-1));
        w.alphaScale=float(std::max(1,wd->GetSalvoSize())*std::max(1,wd->GetProjectilesPerShot()));
        w.splash=wd->GetAreaOfEffect(); w.heightMod=wd->GetHeightMod(); w.cylinder=wd->GetCylinderTargetting();
        const std::string weaponType=wd->GetType();
        w.ballistic=weaponType=="Cannon";
        w.instant=weaponType=="BeamLaser" || weaponType=="LightningCannon" || weaponType=="Melee";
        w.continuous=wd->IsNoExplode();
        // Immutable per-definition metadata: two callbacks once per beam,
        // retained for this AI lifetime; no live weapon calls in risk scoring.
        if(weaponType=="BeamLaser") {
            w.beamMinIntensity=wd->GetMinIntensity();
            w.beamTargetBorder=std::max(0.f,wd->GetTargetBorder());
        }
        w.guided=wd->IsTracks();
        w.high=w.def && w.def->IsHighTrajectory();
        w.speed=wd->GetProjectileSpeed();
        w.gravity=wd->GetMyGravity()>0.f ? wd->GetMyGravity() : -circuit->GetMap()->GetGravity();
        c.weapons.push_back(std::move(w));
    }
    return c;
}

void CRangedWorld::Refresh()
{
    const int now=circuit->GetLastFrame();
    if (frame==now) return;
    performance::Scope measured(circuit,performance::RANGED_SNAPSHOT);
    frame=now; contacts.clear(); friends.clear(); objectives.clear();
    clusterValues.Clear();
    enemies.Clear(); staticHazards.Clear(); formations.Clear();
    alliesDirty = true;
    largestRange=largestStaticRange=0.f; nonnegativeHazardCosts=finiteStaticHazards=true;
    largestCohortHazard=0.f;
    largestSpacing=0.f; largestFriendRadius=0.f; largestScreenRange=0.f;
    // Profile threat suppression must not erase an actual weapon's coverage.
    // Respect true fog, neutral/dying contacts and BAR's explicit ignoredByAI.
    {
    performance::Scope enemyPhase(circuit,performance::RANGED_ENEMIES);
    for (const auto& [id,e]:circuit->GetEnemyManager()->GetEnemyUnits()) {
        if (!e || !e->IsInRadarOrLOS()) continue;
        const auto& data=e->GetData();
        if (data.losStatus & (SEnemyData::DEAD|SEnemyData::DYING|SEnemyData::NEUTRAL|SEnemyData::HIDDEN)) continue;
        if (e->IsIgnore() && (!e->GetCircuitDef() || !e->GetCircuitDef()->IsIgnore()
            || e->GetUnit()->GetRulesParamFloat("ignoredByAI",0.f)>0.f)) continue;
        Contact c; c.id=id; c.def=e->GetCircuitDef(); c.pos=e->GetPos();
        if(!c.def) {
            // Unidentified radar contacts can support low-priority blind fire,
            // but never invented precision identities, HP or threat estimates.
            c.pos.y=circuit->GetTerrainManager()->GetAreaData()->GetElevationAt(c.pos.x,c.pos.z);
            c.mobile=true;
            // D-294: the engine reports a radar dot's velocity (UpdateInRadarData);
            // a shooter uses it to tell a slow or stationary dot (blind shot
            // allowed) from one too fast for its shell. Zero until sampled.
            c.velocity=e->GetVel()*30.f;
            enemies.Add(P(c.pos),int(contacts.size())); objectives.push_back(int(contacts.size()));
            contacts.push_back(c); continue;
        }
        c.velocity=e->GetVel()*30.f; c.health=std::max(1.f,e->GetHealth());
        c.radius=e->GetRadius(); c.cost=e->GetCost(); c.los=e->IsInLOS();
        c.mobile=c.def->IsMobile();
        c.armed=c.def->HasSurfToLand() && !e->IsBeingBuilt() && !e->IsDisarmed() && !e->IsParalyzed();
        if(e->IsIgnore()) {
            // The legacy enemy cache intentionally stops health/velocity
            // updates for profile-ignored contacts. Refresh only observable
            // fields here, without changing the global cache or other roles.
            c.velocity=e->GetUnit()->GetVel()*30.f;
            if(c.los) {
                c.health=std::max(1.f,e->GetUnit()->GetHealth());
                c.armed=c.def->HasSurfToLand() && !e->GetUnit()->IsBeingBuilt()
                    && !e->GetUnit()->IsParalyzed() && e->GetUnit()->GetRulesParamFloat("disarmed",0.f)<=0.f;
            }
        }
        c.groundRange=c.armed ? c.def->GetMaxRange(CCircuitDef::RangeType::LAND) : 0.f;
        // Definition facts are immutable for this AI/game load. Resolve once
        // per type, not once per candidate mount in every shooter's hot loop.
        const auto& meta=MetadataFor(c.def);
        c.armor=meta.armor; c.explosionRadius=meta.explosionRadius; c.tech=meta.tech;
        c.hazardRadius=std::max(c.armed ? c.groundRange+c.radius : 0.f,c.explosionRadius);
        largestRange=std::max(largestRange,c.hazardRadius);
        // Reclaimers can be unarmed and exceed 600 elmos (including the
        // advanced Legion construction turret). Keep this separate from the
        // legacy weapon bound so existing ranged-query semantics stay exact.
        largestCohortHazard=std::max(largestCohortHazard,std::max(c.hazardRadius,
            c.def->IsAbleToReclaim()?c.def->GetBuildDistance()+c.radius:0.f));
        if(!(c.hazardRadius<=0.f)) {
            nonnegativeHazardCosts=nonnegativeHazardCosts && std::isfinite(c.cost) && c.cost>=0.f;
            if(!c.mobile) {
                staticHazards.Add(P(c.pos),int(contacts.size()));
                largestStaticRange=std::max(largestStaticRange,c.hazardRadius);
                finiteStaticHazards=finiteStaticHazards && std::isfinite(c.hazardRadius);
            }
        }
        enemies.Add(P(c.pos),int(contacts.size()));
        if (!c.def->IsAbleToFly()) objectives.push_back(int(contacts.size()));
        contacts.push_back(c);
        clusterValues.Get(int(c.pos.x/128.f),int(c.pos.z/128.f))+=c.cost;
        auto& h=history[id];
        if (c.los) {
            if (now-h.frame>=300) {
                // A repaired target remains legal, but repeated negligible net
                // progress makes another useful shot preferable. Unknown repair
                // income and hidden repairers are never inspected.
                h.stalled=(h.frame>0 && h.engaged>=h.frame && h.health-c.health< std::max(20.f,h.health*.03f)) ? std::min(4,h.stalled+1) : 0;
                h.health=c.health; h.frame=now;
            }
            h.seen=now;
        }
    }
    // A small shared strategic shortlist bounds distant selection per shooter.
    // Local contacts are never truncated; nearby emergencies retain response.
    const auto order = [this](int a,int b) {
        const auto& x=contacts[a]; const auto& y=contacts[b];
        const float vx=x.cost*(x.mobile?1.f:2.f), vy=y.cost*(y.mobile?1.f:2.f);
        return vx==vy ? x.id<y.id : vx>vy;
    };
    // Fixed shortlist: O(E log 16), rather than sorting every enemy per frame.
    std::partial_sort(objectives.begin(),objectives.begin()+std::min(size_t(16),objectives.size()),objectives.end(),order);
    if (objectives.size()>16) objectives.resize(16);
    }
    // UpdateFriendlyUnits rebuilds CAllyUnit + engine wrappers + map nodes for
    // every ally. Calling it every ranged frame dominated measured snapshot
    // cost. Read the same legal IDs/defs/positions into owned reusable storage.
    // Order fresh IDs with reusable bits to retain old std::map traversal/ties.
    // Every definition/position is still read at this observation instant: a
    // unit ID can be reused between asks, even within one simulation frame.
    // No borrowed
    // wrapper survives and no global ally cache is invalidated by this reader.
    {
    performance::Scope friendlyPhase(circuit,performance::RANGED_FRIENDS);
    auto* api=circuit->GetUnitAPI();
    const int friendCount=api->GetFriendlyUnitIds(friendlyIds);
    friendlyOrder.Sort(friendlyIds,friendCount);
    auto* authority=circuit->GetAllyTeam()->GetAuthority();
    const size_t definitionCount=authority->GetDefCount()+1;
    if(friendlyDefinitions.size()!=definitionCount) {
        friendlyDefinitions.resize(definitionCount);
        friendlyDefinitionFrames.assign(definitionCount,-1);
    }
    for (int i=0;i<friendCount;++i) {
        const int id=friendlyIds[i];
        const int definitionId=circuit->GetCallback()->Unit_GetDefId(id);
        if(definitionId<=0 || size_t(definitionId)>=definitionCount) continue;
        auto& prototype=friendlyDefinitions[definitionId];
        if(friendlyDefinitionFrames[definitionId]!=now) {
            friendlyDefinitionFrames[definitionId]=now;
            auto* definition=authority->GetCircuitDef(definitionId);
            prototype.def=definition->IsAbleToFly() ? nullptr : definition;
            if(prototype.def) {
                const auto& metadata=MetadataFor(definition);
                prototype.radius=definition->GetRadius();
                prototype.screen=definition->IsAttacker() && (!definition->IsAttrRanged() || definition->GetRangedPolicy().coordinated);
                prototype.radar=metadata.radar; prototype.jammer=metadata.jammer; prototype.los=metadata.los;
                // D-295: O(D) per frame with the existing prototype; never per unit.
                prototype.range=prototype.screen ? definition->GetMaxRange(CCircuitDef::RangeType::LAND) : 0.f;
                prototype.assist=definition->IsAttrRanged() && definition->GetRangedPolicy().assistRadius>0.f;
            }
        }
        if(!prototype.def) continue;
        float raw[3]; api->GetPosition(id,raw);
        AIFloat3 position(raw[0],raw[1],raw[2]); terrain::CTerrainData::CorrectPosition(position);
        // Coordinated frontline bots retain their old screening role for
        // precision artillery. Opting Thugs into ranged movement must not
        // make allied Starlights/Sharpshooters stop recognizing their screen.
        // O(N) live identity/position reads, O(D) definition interpretation for
        // D represented types. No stale static-position assumptions or shared
        // cross-AI authority. INV-148 compares every resulting field in tests.
        Friend f=prototype; f.id=id; f.pos=position;
        largestFriendRadius=std::max(largestFriendRadius,f.radius);
        if(f.screen && !f.assist) largestScreenRange=std::max(largestScreenRange,f.range);
        friends.push_back(f);
    }
    static const bool verify=std::getenv("CIRCUIT_VERIFY_RANGED_SNAPSHOT")!=nullptr;
    if(verify) {
        // Slow, opt-in differential oracle. Never enable in timing runs.
        circuit->UpdateFriendlyUnits();
        size_t index=0;
        bool equal=true;
        for(const auto& [id,u]:circuit->GetFriendlyUnits()) {
            auto* d=u->GetCircuitDef(); if(!d || d->IsAbleToFly()) continue;
            const auto p=u->GetPos(now);
            if(index>=friends.size() || friends[index].id!=id || friends[index].pos!=p
                || friends[index].radius!=d->GetRadius()
                || friends[index].screen!=(d->IsAttacker() && (!d->IsAttrRanged() || d->GetRangedPolicy().coordinated))
                || friends[index].radar!=MetadataFor(d).radar
                || friends[index].jammer!=MetadataFor(d).jammer
                || friends[index].los!=MetadataFor(d).los) equal=false;
            ++index;
        }
        if(!equal || index!=friends.size()) circuit->LOG("[INVARIANT] INV-148 ranged friendly snapshot differs from legacy view");
    }
    }
    performance::Scope statePhase(circuit,performance::RANGED_STATE);
    for (auto it=slots.begin();it!=slots.end();) {
        auto* u=circuit->GetTeamUnit(it->first);
        if (!u || u->IsDead() || !u->GetCircuitDef()->IsAttrRanged()) {
            // Match task-release cleanup even if a lifecycle callback arrived
            // after this snapshot. Otherwise stale members inflate rush value
            // and keep empty cohorts alive. Advance before Leave erases here.
            const int stale=(it++)->first;
            Leave(stale);
            continue;
        }
        formations.Add(P(it->second.pos),it->first);
        largestSpacing=std::max(largestSpacing,it->second.spacing); ++it;
    }
    for (auto it=shots.begin();it!=shots.end();) {
        if (it->second.until<=now || !circuit->GetEnemyManager()->GetEnemyUnit(it->second.target) || !slots.count(it->first)) {
            auto sum=reserved.find(it->second.target);
            if (sum!=reserved.end()) {
                sum->second-=it->second.damage;
                if (sum->second<.01f) reserved.erase(sum);
            }
            it=shots.erase(it);
        } else ++it;
    }
    for (auto it=history.begin();it!=history.end();) {
        if (now-it->second.seen>1800) it=history.erase(it); else ++it;
    }
    for (auto it=escorts.begin();it!=escorts.end();) {
        if (!circuit->GetTeamUnit(it->first) || !slots.count(it->second.anchor)) it=escorts.erase(it); else ++it;
    }
}

void CRangedWorld::Join(CCircuitUnit* unit)
{
    const auto* d=unit->GetCircuitDef();
    SetSlot(unit->GetId(),unit->GetPos(circuit->GetLastFrame()),d->GetRangedPolicy().spacing,d->GetCostM());
    if(d->GetRangedPolicy().coordinated) JoinCohort(unit);
}
void CRangedWorld::InvalidateCohortPlans(CohortPlan& group)
{
    group.frame=group.formationFrame=-1;
    // Membership can change between callbacks in one frame. Invalidate both
    // ends so the paired plan is reusable for every shooter without repeating
    // partner discovery/validation until the next observation or mutation.
    auto partner=cohorts.find(group.formationPartner);
    if(partner!=cohorts.end()) partner->second.frame=partner->second.formationFrame=-1;
}

void CRangedWorld::EnsureAllies() const
{
    if (!alliesDirty) return;
    // Capture still occurs at Refresh's original observation instant, including
    // fresh IDs, definitions and positions. Only derived indexing is lazy:
    // enemy-only safety/withdrawal queries need no friendly buckets. Building
    // once on first use preserves z/x/ascending-ID query order exactly. O(F+C)
    // on demand, O(1) thereafter; no stale cross-frame/shared-AI observations.
    performance::Scope measured(circuit,performance::RANGED_FRIENDS);
    allies.Clear();
    for (size_t index=0; index<friends.size(); ++index) allies.Add(P(friends[index].pos),int(index));
    alliesDirty = false;
}
void CRangedWorld::Leave(int id) {
    rushes.Leave(id);
    if(verifyRangedQueries && !rushes.Valid())
        circuit->LOG("[INVARIANT] INV-196 local rush membership or original-front casualty accounting is inconsistent");
    slots.erase(id); ReleaseShot(id);
    auto member=membership.find(id);
    if(member!=membership.end()) {
        auto group=cohorts.find(member->second);
        if(group!=cohorts.end()) {
            std::erase(group->second.members,id);
            InvalidateCohortPlans(group->second);
            if(group->second.members.empty()) {
                auto partner=cohorts.find(group->second.formationPartner);
                if(partner!=cohorts.end() && partner->second.formationPartner==group->first) {
                    partner->second.formationPartner=-1;
                    partner->second.formationRear=false;
                }
                cohorts.erase(group);
            }
        }
        membership.erase(member);
    }
}
void CRangedWorld::SetSlot(int id,const AIFloat3& pos,float spacing,float value)
{
    auto old=slots.find(id);
    if(old!=slots.end()) formations.Remove(P(old->second.pos),id);
    slots[id]={pos,spacing,value};
    // Cache immutable type facts at the mutation boundary, not in every local
    // neighbor test. A reused unit ID receives fresh facts on Join/SetSlot.
    if(const auto* unit=circuit->GetTeamUnit(id)) {
        auto* def=unit->GetCircuitDef();
        slots[id].radius=def->GetRadius();
        slots[id].coordinated=def->GetRangedPolicy().coordinated;
        largestFriendRadius=std::max(largestFriendRadius,slots[id].radius);
    }
    largestSpacing=std::max(largestSpacing,spacing);
    formations.Add(P(pos),id);
}
bool CRangedWorld::FreeSlot(int id,const AIFloat3& pos,float spacing) const
{
    const auto own=slots.find(id);
    const float radius=own==slots.end()?0.f:own->second.radius;
    return !formations.Any(P(pos),std::max({spacing,largestSpacing,radius+largestFriendRadius}),[&](int other) {
        const auto it=slots.find(other); if(other==id || it==slots.end()) return false;
        // D-228: Thug screen reservations must not exclude the entire narrow
        // firing band of a Starlight behind them. Other artillery pairs retain
        // their old spacing; FriendlyLine still forbids shooting through hulls.
        const float separation=own==slots.end()?std::max(spacing,it->second.spacing)
            :cohort::PairSpacing(spacing,it->second.spacing,own->second.coordinated,
                                 it->second.coordinated,radius+it->second.radius);
        return pos.SqDistance2D(it->second.pos)<separation*separation;
    });
}
void CRangedWorld::Nearby(const AIFloat3& pos,float radius,std::vector<int>& result) const
{
    result.clear(); enemies.Query(P(pos),radius,[&](int i) {
        if(contacts[i].pos.SqDistance2D(pos)<=radius*radius) result.push_back(i);
    });
}
bool CRangedWorld::Safe(const AIFloat3& from,const AIFloat3& to,float margin,bool escaping,float press) const
{
    const AIFloat3 center=(from+to)*.5f;
    // Only static hazards can reject this predicate. Preserve the old bounds
    // for unusual negative margins; for ordinary nonnegative margins the
    // static maximum remains a conservative bound for the same exact test.
    const float query=(margin>=0.f && finiteStaticHazards?largestStaticRange:largestRange)+margin+std::sqrt(from.SqDistance2D(to))*.5f;
    const bool safe=!staticHazards.Any(P(center),query,[&](int i) {
        const auto& c=contacts[i];
        const float hazard=HazardFor(c,press);
        if(!(hazard>0.f)) return false;
        const float radius=hazard+margin;
        if(escaping) return !ranged::SafeSegment(P(from),P(to),P(c.pos),radius);
        return !(ranged::SegmentDistanceSq(P(c.pos),P(from),P(to))>=radius*radius);
    });
    if(verifyRangedQueries) {
        // Same live observation, old full-contact bounds/predicate. No commands
        // or RNG calls. Run separately from timing: this deliberately repeats
        // the old expensive query and checks static-bound reduction in-engine.
        bool legacy=true;
        enemies.Query(P(center),largestRange+margin+std::sqrt(from.SqDistance2D(to))*.5f,[&](int i) {
            const auto& c=contacts[i]; if(!legacy || HazardFor(c,press)<=0.f || c.mobile) return;
            const float radius=HazardFor(c,press)+margin;
            legacy=escaping ? ranged::SafeSegment(P(from),P(to),P(c.pos),radius)
                : ranged::SegmentDistanceSq(P(c.pos),P(from),P(to))>=radius*radius;
        });
        if(legacy!=safe) circuit->LOG("[INVARIANT] INV-161 ranged safety query differs from legacy predicate");
    }
    return safe;
}
float CRangedWorld::Danger(const AIFloat3& pos,float margin,float press) const
{
    float danger=0.f;
    enemies.Query(P(pos),largestRange+margin,[&](int i) {
        const auto& c=contacts[i]; const float hazard=HazardFor(c,press); if(hazard<=0.f) return;
        if(pos.SqDistance2D(c.pos)<std::pow(hazard+margin,2.f)) danger+=c.cost;
    });
    return danger;
}
int CRangedWorld::DangerSign(const AIFloat3& pos,float margin,float press) const
{
    // Callers ask ==0 or >0, not a magnitude. Nonnegative finite contributions
    // permit existence short-circuiting without changing either comparison.
    // Keep ordered accumulation for exceptional/negative values; -1 also
    // represents NaN, for which both original comparisons are false.
    int result;
    if(!nonnegativeHazardCosts) {
        const float value=Danger(pos,margin,press);
        result=value>0.f?1:value==0.f?0:-1;
    } else result=enemies.Any(P(pos),largestRange+margin,[&](int i) {
        const auto& c=contacts[i]; const float hazard=HazardFor(c,press);
        return hazard>0.f && c.cost>0.f
            && pos.SqDistance2D(c.pos)<std::pow(hazard+margin,2.f);
    }) ? 1 : 0;
    if(verifyRangedQueries) {
        const float value=Danger(pos,margin,press);
        const int expected=value>0.f?1:value==0.f?0:-1;
        if(result!=expected) circuit->LOG("[INVARIANT] INV-161 ranged danger sign differs from ordered sum");
    }
    return result;
}
bool CRangedWorld::FriendlySplash(int id,const AIFloat3& target,float radius) const
{
    if(radius<=16.f) return false;
    EnsureAllies();
    return allies.Any(P(target),radius+largestFriendRadius,[&](int i) {
        const auto& f=friends[i];
        return f.id!=id && target.SqDistance2D(f.pos)<std::pow(radius+f.radius,2.f);
    });
}
bool CRangedWorld::HasScreen(int id,const AIFloat3& from,const AIFloat3& target) const
{
    EnsureAllies();
    const float distance=from.SqDistance2D(target);
    return allies.Any(P(from),700.f,[&](int i) {
        const auto& f=friends[i];
        return f.id!=id && f.screen && f.pos.SqDistance2D(target)<distance && f.pos.SqDistance2D(from)<490000.f;
    });
}
bool CRangedWorld::Engaged(int contact,float margin,int* ally) const
{
    if(ally) *ally=-1;
    if(contact<0 || size_t(contact)>=contacts.size()) return false;
    const auto& c=contacts[contact];
    // Only identified, currently visible ground contacts can be an allied
    // engagement; a radar dot or aircraft never pulls a precision gun forward.
    if(!c.def || !c.los || c.def->IsAbleToFly() || c.pos.y< -20.f) return false;
    if(engagedFrame!=frame || engagedMargin!=margin) {
        engagedMemo.assign(contacts.size(),-1); // reuses capacity
        engagedFrame=frame; engagedMargin=margin;
    }
    int& memo=engagedMemo[contact];
    if(memo<0) {
        // One bounded local query per contact per frame: O(allies near c).
        // Other assisters are excluded so assisting guns never bootstrap
        // each other forward. Allied teams' units are included because the
        // snapshot is GetFriendlyUnitIds (engine: same allyteam, not neutral).
        EnsureAllies();
        int found=-1;
        allies.Any(P(c.pos),largestScreenRange+margin+c.radius,[&](int k) {
            const auto& f=friends[k];
            if(!f.screen || f.assist || f.range<=0.f) return false;
            const float reach=f.range+margin+c.radius;
            if(f.pos.SqDistance2D(c.pos)>reach*reach) return false;
            found=k; return true;
        });
        memo=found+1;
    }
    if(memo>0 && ally) *ally=friends[memo-1].id;
    return memo>0;
}
bool CRangedWorld::FriendlyLine(const Weapon& w,int id,const AIFloat3& from,const AIFloat3& target) const
{
    // Ballistic/high-arc trajectories may legitimately clear a screen. For
    // direct and guided projectiles, reserve a conservative firing corridor;
    // engine avoidance alone did not prevent Medusa rockets hitting a radar.
    // Query local cells along this segment, not all allies for every target.
    if(w.fake || w.ballistic) return false;
    const AIFloat3 delta=target-from;
    const float length=delta.SqLength2D();
    if(length<1.f) return false;
    EnsureAllies();
    // Guided rockets curve in height and may descend after losing a target.
    // A straight-line height exemption let Medusa hit a radar on a hillside
    // after its target died. Require a clear 2-D corridor for guided weapons,
    // including their splash padding. Direct beams retain the height test.
    // The Medusa fixture requires zero allied damage as well as target kills.
    const float padding=w.guided ? std::max(8.f,w.splash) : 8.f;
    return allies.Any(P((from+target)*.5f),std::sqrt(length)*.5f+largestFriendRadius+padding,[&](int i) {
        const auto& f=friends[i];
        if(f.id==id) return false;
        const float t=((f.pos.x-from.x)*delta.x+(f.pos.z-from.z)*delta.z)/length;
        if(t<=0.f || t>=1.f) return false;
        const auto p=from+delta*t;
        const float radius=f.radius+padding;
        return f.pos.SqDistance2D(p)<radius*radius
            && (w.guided || std::fabs(f.pos.y-(p.y+24.f))<radius+24.f);
    });
}
float CRangedWorld::Range(const Weapon& w,const AIFloat3& from,const AIFloat3& to) const
{
    const float h=(to.y-from.y)*w.heightMod;
    if(w.cylinder>0.f) return std::fabs(h)<w.cylinder*w.range ? w.range : 0.f;
    // Conservative uphill correction; do not assume bonus downhill reach.
    // The engine remains authoritative for actual firing reach and aim.
    return w.ballistic ? std::max(0.f,w.range-std::max(0.f,h)) : std::sqrt(std::max(0.f,w.range*w.range-h*h));
}
bool CRangedWorld::Trajectory(const Weapon& w,const AIFloat3& from,const AIFloat3& to) const
{
    if(w.fake || w.high) return true; // starburst/carrier requires actual firing fixture
    const float distance=std::sqrt(from.SqDistance2D(to));
    const int steps=std::max(1,int(distance/32.f));
    float tangent=0.f;
    if(w.ballistic && w.speed>0.f && w.gravity>0.f) {
        const float v2=w.speed*w.speed;
        const float disc=v2*v2-w.gravity*(w.gravity*distance*distance+2.f*(to.y-from.y)*v2);
        if(disc<0.f) return false;
        tangent=(v2-std::sqrt(disc))/std::max(1.f,w.gravity*distance);
    }
    const auto* area=circuit->GetTerrainManager()->GetAreaData();
    for(int i=1;i<steps;++i) {
        const float t=float(i)/steps, x=distance*t;
        const float y=w.ballistic && w.speed>0.f ? from.y+24.f+x*tangent-w.gravity*x*x*(1.f+tangent*tangent)/(2.f*w.speed*w.speed)
            : from.y+24.f+(to.y-from.y)*t;
        if(area->GetElevationAt(from.x+(to.x-from.x)*t,from.z+(to.z-from.z)*t)>y) return false;
    }
    return true;
}
void CRangedWorld::ReleaseShot(int owner)
{
    auto it=shots.find(owner); if(it==shots.end()) return;
    auto sum=reserved.find(it->second.target);
    if(sum!=reserved.end()) {
        sum->second-=it->second.damage;
        if(sum->second<.01f) reserved.erase(sum);
    }
    shots.erase(it);
}
void CRangedWorld::ReserveShot(int owner,int target,float damage,int until)
{
    ReleaseShot(owner); shots[owner]={target,until,damage}; reserved[target]+=damage;
    history[target].engaged=circuit->GetLastFrame();
}
float CRangedWorld::Reserved(int target,int owner) const
{
    const auto r=reserved.find(target); const auto s=shots.find(owner);
    return std::max(0.f,(r==reserved.end()?0.f:r->second)-(s!=shots.end() && s->second.target==target?s->second.damage:0.f));
}
float CRangedWorld::Progress(int target,float penalty) const
{
    const auto it=history.find(target); return it==history.end()?1.f:std::max(.05f,std::pow(penalty,float(it->second.stalled)));
}
float CRangedWorld::ClusterValue(const AIFloat3& target,float radius) const
{
    // A coarse density score, not predicted damage. Aggregate once per shared
    // snapshot so a dense battle does not become an enemy-pair scan for every
    // splash shooter. Cost depends on weapon footprint, not total army size.
    if(radius<32.f) return 0.f;
    float value=0.f;
    const int cells=int(std::ceil(std::min(512.f,radius)/128.f));
    const int x=int(target.x/128.f),z=int(target.z/128.f);
    for(int dz=-cells;dz<=cells;++dz) for(int dx=-cells;dx<=cells;++dx) {
        if(dx*dx+dz*dz>cells*cells) continue;
        const auto* cell=clusterValues.Find(x+dx,z+dz);
        if(cell) value+=*cell;
    }
    return value;
}
bool CRangedWorld::Escort(CCircuitUnit* sensor,AIFloat3& position)
{
    performance::Scope measured(circuit,performance::RANGED_ESCORT);
    Refresh();
    auto* d=sensor->GetCircuitDef(); const auto& meta=MetadataFor(d);
    const float radar=meta.radar, jammer=meta.jammer;
    static const bool trace=std::getenv("CIRCUIT_RANGED_TRACE")!=nullptr;
    const bool report=trace && frame%150==3;
    if(report) circuit->LOG("RANGED: escort sensor=%d radar=%.0f jammer=%.0f land=%d anchors=%u",sensor->GetId(),radar,jammer,int(d->IsLander()),unsigned(slots.size()));
    if((radar<=0.f && jammer<=0.f) || d->IsAbleToFly() || !d->IsLander()) return false;
    EnsureAllies();
    const bool isJammer=jammer>0.f;
    const auto pos=sensor->GetPos(frame);
    float best=-1.f; int anchor=-1;
    for(const auto& [id,slot]:slots) {
        if(!circuit->GetTerrainManager()->CanMoveToPos(sensor->GetArea(),slot.pos)) continue;
        AIFloat3 coveragePoint=slot.pos;
        if(!isJammer) {
            float nearest=2000.f*2000.f;
            enemies.Query(P(slot.pos),2000.f,[&](int i) {
                const float distance=slot.pos.SqDistance2D(contacts[i].pos);
                if(distance<nearest) { nearest=distance; coveragePoint=contacts[i].pos; }
            });
        }
        bool covered=false;
        allies.Query(P(coveragePoint),std::max(radar,jammer),[&](int i) {
            const auto& f=friends[i]; if(f.id==sensor->GetId()) return;
            // Radar over the firing line does not replace vision of targets.
            // A radar escort's scarce useful resource here is its allied LOS.
            const float reach=isJammer?f.jammer:f.los;
            if(reach>0.f && f.pos.SqDistance2D(coveragePoint)<reach*reach*.81f) covered=true;
        });
        for(const auto& [other,lease]:escorts) {
            if(other==sensor->GetId() || lease.jammer!=isJammer) continue;
            const auto a=slots.find(lease.anchor);
            if(a!=slots.end() && a->second.pos.SqDistance2D(slot.pos)<262144.f) covered=true;
        }
        if(covered) continue;
        auto* gun=circuit->GetTeamUnit(id);
        if(!gun) continue;
        AIFloat3 direction=isJammer ? circuit->GetSetupManager()->GetBasePos()-slot.pos : coveragePoint-slot.pos;
        if(direction.SqLength2D()<1.f) direction=circuit->GetSetupManager()->GetBasePos()-slot.pos;
        direction.Normalize2D();
        const float offset=gun->GetCircuitDef()->GetRangedPolicy().sensorOffset;
        AIFloat3 candidate=slot.pos+direction*offset;
        bool safe=false;
        // A short-range anchor may put the nominal forward sensor offset
        // inside static coverage. Try the firing line itself, then another
        // anchor; never reserve an unreachable/unsafe escort slot.
        for(int attempt=0;attempt<2;++attempt) {
            CTerrainManager::CorrectPosition(candidate);
            candidate.y=circuit->GetTerrainManager()->GetAreaData()->GetElevationAt(candidate.x,candidate.z);
            safe=circuit->GetTerrainManager()->CanMoveToPos(sensor->GetArea(),candidate)
                && Safe(pos,candidate,32.f,true) && DangerSign(candidate,32.f)==0;
            if(safe) break;
            candidate=slot.pos;
        }
        if(!safe) continue;
        const auto previous=escorts.find(sensor->GetId());
        const float value=slot.value/(256.f+std::sqrt(pos.SqDistance2D(slot.pos))) *
            (previous!=escorts.end() && previous->second.anchor==id?1.5f:1.f);
        if(value>best) { best=value; anchor=id; position=candidate; }
    }
    if(anchor<0) { if(report) circuit->LOG("RANGED: escort covered sensor=%d",sensor->GetId()); escorts.erase(sensor->GetId()); return false; }
    escorts[sensor->GetId()]={anchor,isJammer};
    if(report) circuit->LOG("RANGED: escort choice sensor=%d anchor=%d pos=%.0f,%.0f",sensor->GetId(),anchor,position.x,position.z);
    return true;
}
}
