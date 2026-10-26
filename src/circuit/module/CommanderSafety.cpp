#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "task/builder/CommanderTask.h"
#include "task/RetreatTask.h"
#include "terrain/BattleAnalysis.h"
#include "terrain/TerrainManager.h"
#include "setup/SetupManager.h"
#include "spring/SpringMap.h"
#include "spring/SpringUnit.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitWDef.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"

namespace circuit {
using springai::AIFloat3;
using commander::Point;
static Point P(const AIFloat3& p) { return {p.x,p.z}; }

bool CCommanderControl::HealthRetreat(CCircuitUnit* unit) const {
    if(!Handles(unit) || options.healthRetreatFraction<=0) return false;
    const auto it=commanders.find(unit->GetId());
    return unit->GetHealthPercent()<options.healthRetreatFraction
        || (it!=commanders.end() && it->second.healthRetreat);
}

bool CCommanderControl::HealthControl(CCircuitUnit* unit,State& s,int frame) {
    if(options.healthRetreatFraction<=0
        || unit->GetHealthPercent()>=std::max(options.recover,options.healthRetreatFraction)) {
        s.healthRetreat=false;s.healthGoal={-1,0,-1};s.healthShotUntil=-1;return false;
    }
    if(!HealthRetreat(unit)) return false;
    const auto pos=unit->GetPos(frame);
    auto* def=unit->GetCircuitDef();
    const float window=options.healthShotSeconds;
    const bool recentDamage=s.lastDamage>=0 && frame-s.lastDamage<FRAMES_PER_SEC;
    // An actual cloak and a clear in-range T3 shot are required. Never hand a
    // low-health exception to the general jammer controller (which can chase
    // heavy T2s). One finite aiming window per retreat; no lease renewal loop.
    if(!s.healthRetreat && window>0 && !recentDamage && unit->GetUnit()->IsCloaked()
        && RetreatCloakFunded(unit) && CloakSafe(unit,P(pos),P(pos),window)
        && Exposure(P(pos),P(pos),window,pos.y,true,0.f)<unit->GetUnit()->GetHealth()*.1f
        && (s.healthShotUntil<0 || frame<s.healthShotUntil)) {
        const float range=unit->GetDGunRange()-12.f;
        const float speed=std::max(1.f,def->GetDGunDef()->GetDef()->GetProjectileSpeed()*30.f);
        const float width=std::min(24.f,std::max(4.f,def->GetDGunDef()->GetAoe()*.25f));
        for(const auto& c:contacts) {
            if(!c.t3 || c.friendly || c.blocker || !c.targetable || (c.reserved && c.id!=s.target)) continue;
            const auto lead=c.pos+c.velocity*(commander::Length(c.pos-P(pos))/speed);
            auto line=commander::ScoreLine(contacts,P(pos),lead-P(pos),range,speed,width,
                options.killReward,options.friendlyMargin,c.id);
            if(!line.requiredHit || line.blocked || unit->GetDGunReloadFrame()>frame+int(window*FRAMES_PER_SEC)) continue;
            auto* task=dynamic_cast<CCommanderTask*>(unit->GetTask());
            if(!task) {
                task=ai->GetBuilderManager()->EnqueueCommander(nullptr);
                ai->GetBuilderManager()->AssignTask(unit,task);
                if(unit->GetTask()!=task) {ai->GetBuilderManager()->AbortTask(task);break;}
            }
            if(s.healthShotUntil<0) {
                s.healthShotUntil=frame+int(window*FRAMES_PER_SEC);
                TRY_UNIT(ai,unit,unit->CmdStop();)
                s.route.clear();s.deployed=false;
                ai->LOG("[CommanderSafety] unit=%i action=cloaked_t3_wait target=%i",unit->GetId(),c.id);
            }
            Conceal(unit,s,true);
            s.budget=def->GetDGunDef()->GetCostE();
            // Keep the current shot lease until it fires; every next tick still
            // checks cloak, damage and the finite deadline above.
            if(s.pending>=0 && unit->GetDGunReloadFrame()<=frame) return true;
            if(unit->IsDGunReady(frame,ai->GetEconomyManager()->GetEnergyCur()-std::max(0.f,reserve))) {
                line.target=c.id;
                if(!Fire(unit,s,line,frame)) break; // shared blast/friendly-fire admission
            }
            return true;
        }
    }
    if(!s.healthRetreat) ai->LOG("[CommanderSafety] unit=%i action=health_retreat hp=%.3f frame=%i",
        unit->GetId(),unit->GetHealthPercent(),frame);
    s.healthRetreat=true;s.budget=0;s.fundingBudget=0;s.pending=-1;s.leaseUntil=0;
    s.deployed=false;s.workTask=nullptr;s.route.clear();
    ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
    EndT3(unit,s,frame,"low_health");
    auto* battle=ai->GetBattle();
    const bool threatened=recentDamage || Exposure(P(pos),P(pos),options.escapeSeconds,pos.y)>0;
    // At most eight endpoint/path assessments per second while escaping.
    // Prefer visible rearward lane space; never query hidden enemy positions.
    // Keep a safe reached station rather than continuously walking to base.
    if(frame>=s.healthPlan+FRAMES_PER_SEC && (s.healthGoal.x<0
        || (threatened && pos.SqDistance2D(s.healthGoal)<SQUARE(64.f))
        || !battle->InLos(s.healthGoal)
        || Exposure(P(s.healthGoal),P(s.healthGoal),options.escapeSeconds,s.healthGoal.y)>0)) {
        s.healthPlan=frame;
        const bool lane=battle->GetFrontLaneLength()>0;
        const float own=lane?battle->GetFrontLaneProgress(pos):0;
        const auto rear=lane?battle->GetFrontLanePoint(std::max(0.f,own-options.cloakRetreatDistance))
            :ai->GetSetupManager()->GetBasePos();
        Point away=commander::Normal(P(rear)-P(pos));
        if(commander::Length(away)<.1f) away={0,-1};
        float best=1e30f;
        for(int i=0;i<8;++i) {
            const float angle=i*.785398163f;
            const Point direction{away.x*std::cos(angle)-away.z*std::sin(angle),
                away.x*std::sin(angle)+away.z*std::cos(angle)};
            const float step=std::min(options.cloakRetreatDistance,std::max(128.f,def->GetLosRadius()*.65f));
            const Point end=P(pos)+direction*step;
            AIFloat3 at(end.x,0,end.z);
            if(!OnMap(at)) continue;
            at.y=ai->GetMap()->GetElevationAt(at.x,at.z);
            if(!ai->GetTerrainManager()->CanReachAt(unit,at,64.f)) continue;
            const float risk=Exposure(P(pos),P(at),options.escapeSeconds,pos.y)
                +4.f*Exposure(P(at),P(at),options.escapeSeconds,at.y);
            int fog=0;
            for(int sample=0;sample<8;++sample) {
                const float a=sample*.785398163f;
                AIFloat3 probe(at.x+std::cos(a)*step,at.y,at.z+std::sin(a)*step);
                if(OnMap(probe) && !battle->InLos(probe)) ++fog;
            }
            // Visibility dominates equal-exposure choices; progress and lane
            // distance break ties so withdrawing does not become lane hopping.
            const float score=risk*10000.f+(battle->InLos(at)?0.f:100000.f)+fog*1000.f
                +(lane?std::max(0.f,battle->GetFrontLaneProgress(at)-own)*100.f
                    +battle->GetFrontLaneDistance(at):0.f)+commander::Length(P(at)-P(rear));
            if(score<best) {best=score;s.healthGoal=at;}
        }
        if(s.healthGoal.x>=0) ai->LOG("[CommanderSafety] unit=%i retreat_goal=%.0f,%.0f visible=%i",
            unit->GetId(),s.healthGoal.x,s.healthGoal.z,int(battle->InLos(s.healthGoal)));
    }
    if(unit->GetTask()->GetType()!=IUnitTask::Type::RETREAT)
        ai->GetBuilderManager()->AssignTask(unit,ai->GetBuilderManager()->EnqueueRetreat());
    return true;
}
}
