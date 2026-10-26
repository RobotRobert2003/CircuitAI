#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "terrain/BattleAnalysis.h"
#include "terrain/TerrainManager.h"
#include "terrain/CommanderFortification.h"
#include "unit/CircuitUnit.h"
#include "unit/ally/AllyUnit.h"
#include "spring/SpringUnit.h"
#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"
#include "map/ThreatMap.h"
#include "task/builder/BuilderTask.h"
#include "task/common/WaitTask.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"

namespace circuit {
using springai::AIFloat3;
using BT=IBuilderTask::BuildType;
static commander::Point P(const AIFloat3& p) {return {p.x,p.z};}
static AIFloat3 F(commander::Point p) {return {p.x,0,p.z};}
static commander::Point Heading(const CBattleAnalysis* battle,const AIFloat3& p) {
    const float d=battle->GetFrontLaneProgress(p);
    return commander::Normal(P(battle->GetFrontLanePoint(d+64))-P(battle->GetFrontLanePoint(std::max(0.f,d-64))));
}

bool CCommanderControl::IsFrontDefence(const CCircuitDef* def) const {
    return def && (def->GetId()==int(options.frontLineDef) || def->GetId()==groupDef
        || std::find(frontDefenceDefs.begin(),frontDefenceDefs.end(),def->GetId())!=frontDefenceDefs.end());
}

std::vector<commander::DefenceExclusion> CCommanderControl::DefenceExclusions(CCircuitUnit* unit,
    CCircuitDef* def,const AIFloat3& center,float searchRadius,const IUnitTask* ignore) const {
    std::vector<commander::DefenceExclusion> result;
    if(!options.frontDuty || options.frontDefenceSpacing<=0 || !IsFrontDefence(def)
        || (unit->GetId()!=groupUnit && !Handles(unit))) return result;
    float maxRange=def->GetMaxRange();
    for(int id:frontDefenceDefs) {
        auto* other=ai->GetCircuitDefSafe(id);
        if(other) maxRange=std::max(maxRange,other->GetMaxRange());
    }
    for(int id:{int(options.frontLineDef),groupDef}) {
        auto* other=ai->GetCircuitDefSafe(id);
        if(other) maxRange=std::max(maxRange,other->GetMaxRange());
    }
    const float radius=searchRadius+maxRange*options.frontDefenceSpacing;
    auto add=[&](CCircuitDef* other,const AIFloat3& at) {
        if(IsFrontDefence(other) && OnMap(at) && at.SqDistance2D(center)<=radius*radius)
            result.push_back({P(at),std::max(def->GetMaxRange(),other->GetMaxRange())*options.frontDefenceSpacing});
    };
    // Fresh per-offer snapshot: O(F*D + Q*D) for local friendlies F, queued
    // defenses Q and the small script roster D. Terrain candidates use only
    // copied discs, never callbacks. No cache survives enqueue/loss/transfer.
    // Both frames and completed allied defenses occupy space; own queued sites
    // reserve it before a frame exists. The executing task excludes itself.
    for(int id:ai->GetCallback()->GetFriendlyUnitIdsIn(center,radius,false)) {
        auto* ally=ai->GetFriendlyUnit(id);
        if(ally) add(ally->GetCircuitDef(),ally->GetPos(ai->GetLastFrame()));
    }
    for(auto* task:ai->GetBuilderManager()->GetTasks(BT::DEFENCE)) {
        if(task==ignore || task->IsDead()) continue;
        const auto& at=task->GetBuildPos();
        add(task->GetBuildDef(),geom::is_valid(at)?at:task->GetPosition());
    }
    return result;
}

void CCommanderControl::MexFinished(CCircuitUnit* worker,CCircuitUnit* mex) {
    if(!options.frontDuty || options.frontMexDefence<=0 || !Handles(worker)) return;
    auto it=commanders.find(worker->GetId());
    if(it==commanders.end()) return;
    auto& pending=it->second.unfortifiedMexes;
    if(std::find(pending.begin(),pending.end(),mex->GetId())==pending.end()) pending.push_back(mex->GetId());
    ai->LOG("[CommanderFront] unit=%i completed_mex=%i",worker->GetId(),mex->GetId());
}

IUnitTask* CCommanderControl::FortifySite(CCircuitUnit* unit,CCircuitDef* def,const AIFloat3& site,int frame,const AIFloat3* coveragePoint) {
    auto* builder=ai->GetBuilderManager();
    const float coverageRadius=std::max(0.f,def->GetMaxRange()*.8f-16.f);
    auto* groupCommander=unit->GetId()==groupUnit?GroupCommander():nullptr;
    const auto groupCenter=groupCommander?groupCommander->GetPos(frame):site;
    const float groupSight=groupCommander?groupCommander->GetCircuitDef()->GetLosRadius():0.f;
    CTerrainManager::TerrainPredicate admit=[&](const AIFloat3& p) {
        if(!GroupSiteAllowed(unit,p)) return false;
        // Reject before enqueueing/spending the incremental allowance. The
        // final build guard also enforces this, but an invalid offer otherwise
        // repeatedly abandons defenses after replacement (support-replace).
        if(unit->GetId()==groupUnit && (!groupCommander
            || p.SqDistance2D(groupCenter)>SQUARE(std::max(0.f,groupSight-16.f)))) return false;
        if(coveragePoint && (p.SqDistance2D(*coveragePoint)>coverageRadius*coverageRadius
            || ai->GetBattle()->CorridorAtPoint(int(options.frontCorridorClass),p)!=int(options.frontCorridor))) return false;
        // A buildable site can lie across a cliff from the commander. Reject it
        // inside the search so the next reachable alternative is considered,
        // rather than retrying the same unreachable nearest result forever.
        return ai->GetThreatMap()->GetThreatAt(unit,p)<=options.frontThreat
            && ai->GetTerrainManager()->CanReachAtSafe2(unit,p,unit->GetCircuitDef()->GetBuildDistance());
    };
    for(auto* task:builder->GetTasks(BT::DEFENCE)) {
        if(task->IsDead() || task->GetBuildDef()!=def || task->GetPosition().SqDistance2D(site)>64.f*64.f || !admit(task->GetPosition())) continue;
        if(unit->GetId()==groupUnit) {
            bool covered=false;auto* power=GroupPower(unit,task->GetPosition(),covered);
            if(!covered) return power;
        }
        return task->CanAssignTo(unit)?task:nullptr;
    }
    // An orphaned nanoframe is unfinished work, not a reason to wait forever.
    // Reuse the repair registry (one owner per target) and the same safe-site
    // admission. Finished turrets are accounted for by coverage; let placement
    // search around them rather than vetoing every nearby alternative.
    const auto nearbyIds=ai->GetCallback()->GetFriendlyUnitIdsIn(site,64.f,false);
    for(int id:nearbyIds) {
        if(ai->GetCallback()->Unit_GetDefId(id)!=def->GetId()) continue;
        auto* ally=ai->GetFriendlyUnit(id);
        if(!ally || !ally->GetUnit()->IsBeingBuilt() || !admit(ally->GetPos(frame))
            || builder->IsReclaimUnit(ally)) continue;
        if(unit->GetId()==groupUnit) {
            bool covered=false;auto* power=GroupPower(unit,ally->GetPos(frame),covered);
            if(!covered) return power;
        }
        auto* repair=builder->EnqueueRepairFor(ally,60*FRAMES_PER_SEC,unit);
        if(repair && repair->CanAssignTo(unit)) return repair;
    }
    // A mandatory job cannot depend on saving a bank that factory production
    // continuously spends. Balanced policy queues one high-priority LLT and
    // lets normal construction resource allocation fund it incrementally.
    if(!OnMap(site) || ai->GetEconomyManager()->GetMetalCur()<def->GetCostM()*options.frontFortifyBank) return nullptr;
    // Mex defenses keep a small enemy-facing shake. A line may bend around a
    // slope/rock: search within weapon reach, but admit only real sites whose
    // coverage fills the gap and remains in this territory. This replaces
    // repeated failed exact-slot builds on unbuildable ground (Proving Grounds).
    const float search=coveragePoint?def->GetMaxRange()*.75f:48.f;
    const auto exclusions=DefenceExclusions(unit,def,site,search);
    CTerrainManager::TerrainPredicate spaced=[&](const AIFloat3& p) {
        return commander::DefenceSpaced(P(p),exclusions) && admit(p);
    };
    const auto at=ai->GetTerrainManager()->FindBuildSite(def,site,search,0,spaced);
    const bool found=OnMap(at);
    const bool safe=found && ai->GetThreatMap()->GetThreatAt(unit,at)<=options.frontThreat;
    const bool reachable=safe && ai->GetTerrainManager()->CanReachAtSafe2(unit,at,unit->GetCircuitDef()->GetBuildDistance());
    if(!reachable) {
        const auto state=commanders.find(unit->GetId());
        if(coveragePoint && state!=commanders.end() && frame>=state->second.lastLog+30*FRAMES_PER_SEC)
            ai->LOG("[CommanderFront] unit=%i fortify_rejected found=%i safe=%i reachable=%i site=%.0f,%.0f selected=%.0f,%.0f",unit->GetId(),int(found),int(safe),int(reachable),site.x,site.z,at.x,at.z);
        return nullptr;
    }
    if(unit->GetId()==groupUnit) {
        bool covered=false;
        auto* power=GroupPower(unit,at,covered);
        if(!covered) return power;
    }
    const auto priority=static_cast<IBuilderTask::Priority>(int(options.frontFortifyPriority));
    auto* task=builder->Enqueue(TaskB::Common(BT::DEFENCE,priority,def,at,16.f,true,60*FRAMES_PER_SEC));
    if(task && unit->GetId()==groupUnit) ai->LOG("[CommanderGroup] unit=%i defence=%s powered=1",unit->GetId(),def->GetDef()->GetName());
    if(task) ai->LOG("[CommanderFront] unit=%i fortify_site x=%.0f z=%.0f line=%i frame=%i",unit->GetId(),at.x,at.z,int(coveragePoint!=nullptr),frame);
    return task;
}

IUnitTask* CCommanderControl::MexDefenceWork(CCircuitUnit* unit,State& s,CCircuitDef* def,int frame) {
    if(options.frontMexDefence<=0 || !def || !unit->GetCircuitDef()->CanBuild(def)
        || ai->GetBattle()->GetFrontLaneLength()<=0) return nullptr;
    auto* battle=ai->GetBattle();
    // Only actual completed mexes involving this commander are retained. A
    // cancelled offer creates no debt. Drop dead/transferred IDs before use.
    const bool incremental=options.frontFortifyAdvance>0;
    const float own=battle->GetFrontLaneProgress(unit->GetPos(frame));
    const float next=std::min(s.fortifyNextProgress,
        std::min(options.frontDistance,battle->GetFrontLaneLength()-options.frontStandoff)-64.f);
    for(size_t i=0;i<s.unfortifiedMexes.size();) {
        auto* mex=ai->GetTeamUnit(s.unfortifiedMexes[i]);
        if(!mex || !mex->GetCircuitDef()->IsMex()) {s.unfortifiedMexes.erase(s.unfortifiedMexes.begin()+i);continue;}
        const auto pos=mex->GetPos(frame);
        // Retain distant obligations without walking backwards to service them.
        // Only local debts need fresh engine coverage queries (commander-owned
        // IDs, not a scan of the team's mex population).
        if(incremental && (battle->GetFrontLaneProgress(pos)<own-options.frontWorkBehind
            || pos.SqDistance2D(unit->GetPos(frame))>options.frontRadius*options.frontRadius)) {++i;continue;}
        const auto forward=Heading(battle,pos);
        float range=def->GetMaxRange()*.8f;
        auto* jobDef=def;
        bool aaPending=false;
        bool covered=false;
        workIds=ai->GetCallback()->GetFriendlyUnitIdsIn(pos,range,false);
        for(int id:workIds) {
            auto* ally=ai->GetFriendlyUnit(id);
            if(ally && ally->GetCircuitDef()==def && !ally->GetUnit()->IsBeingBuilt()
                && commander::EnemySideCover(P(pos),P(ally->GetPos(frame)),forward,range)) {covered=true;break;}
        }
        if(covered && options.frontMexAA>=0) {
            auto* aa=ai->GetCircuitDefSafe(unit->GetId()==groupUnit?groupAA:int(options.frontMexAA));
            if(!aa || !unit->GetCircuitDef()->CanBuild(aa)) {++i;continue;}
            covered=false;
            for(int id:ai->GetCallback()->GetFriendlyUnitIdsIn(pos,options.frontMexOffset+64.f,false)) {
                auto* ally=ai->GetFriendlyUnit(id);
                if(ally && ally->GetCircuitDef()==aa && !ally->GetUnit()->IsBeingBuilt()) {covered=true;break;}
            }
            if(!covered) {jobDef=aa;range=aa->GetMaxRange()*.8f;aaPending=true;}
        }
        if(covered) {
            ai->LOG("[CommanderFront] unit=%i mex_defended=%i",unit->GetId(),mex->GetId());
            s.unfortifiedMexes.erase(s.unfortifiedMexes.begin()+i);continue;
        }
        const commander::Point side{-forward.z,forward.x};
        // Three bounded placement alternatives keep every site on the enemy
        // side and within LLT range. Retry later, never silently clear a debt.
        if(frame>=s.mexFortifyRetry && (!incremental || aaPending || own>=next)) {
            s.mexFortifyRetry=frame+3*FRAMES_PER_SEC;
            for(float lateral:{0.f,64.f,-64.f}) {
                auto at=F(P(pos)+forward*std::min(options.frontMexOffset,range*.6f)+side*lateral);
                if(!OnMap(at)) continue;
                at.y=ai->GetMap()->GetElevationAt(at.x,at.z);
                if(auto* task=FortifySite(unit,jobDef,at,frame)) {
                    ai->LOG("[CommanderFront] unit=%i mex_defence=%i aa=%i x=%.0f z=%.0f",unit->GetId(),mex->GetId(),int(aaPending),at.x,at.z);
                    return task;
                }
            }
            if(incremental) {
                // Rotate a blocked local debt so it cannot starve another mex.
                const int id=s.unfortifiedMexes[i];
                s.unfortifiedMexes.erase(s.unfortifiedMexes.begin()+i);
                s.unfortifiedMexes.push_back(id);
                return nullptr;
            }
        }
        // An unavailable site must not monopolise the role ladder. Keep the
        // debt and offer lane movement; subsequent asks can try other debts.
        if(incremental) {++i;continue;}
        // Explicit blocking mode retains the original bounded wait.
        auto* wait=static_cast<IWaitTask*>(ai->GetBuilderManager()->Enqueue(TaskB::Wait(3*FRAMES_PER_SEC)));
        wait->SetStationary(true);return wait;
    }
    return nullptr;
}

IUnitTask* CCommanderControl::TerritoryLineWork(CCircuitUnit* unit,State& s,CCircuitDef* def,int frame) {
    if(options.frontLineEnabled<=0 || !def || !unit->GetCircuitDef()->CanBuild(def)) return nullptr;
    auto* battle=ai->GetBattle();
    const int corridor=int(options.frontCorridor),cls=int(options.frontCorridorClass);
    const float length=battle->GetFrontLaneLength();
    if(length<=0 || corridor<0 || cls<0) {s.territoryPending=false;return nullptr;}
    const auto pos=unit->GetPos(frame);
    const float own=battle->GetFrontLaneProgress(pos);
    if(s.territoryCorridor!=corridor || s.territoryClass!=cls) {
        s.territoryPlans.clear();s.territoryProgress=-1;s.fortifyNextProgress=0;
        s.territoryCorridor=corridor;s.territoryClass=cls;
    }
    const bool incremental=options.frontFortifyAdvance>0;
    // Plans are retained by corridor generation. Their count is bounded by
    // lane length / line depth; only the selected local plan queries units.
    // Forward progress creates new plans even when old flanks remain unfinished.
    if(s.territoryProgress<0 || ((incremental || !s.territoryPending)
        && own>=s.territoryProgress+options.frontLineDepth)) {
        bool unseen=options.frontLineFog<=0;
        // Up to 16 cached legal LOS lookups ahead, no hidden enemy information.
        for(int i=1;i<=16 && !unseen;++i) {
            const float d=own+options.frontLineFog*i/16.f;
            if(d<=length && !battle->InLos(battle->GetFrontLanePoint(d))) unseen=true;
        }
        if(unseen) {
            const auto center=battle->GetFrontLanePoint(own);
            const auto sites=commander::TerritoryLine(P(center),Heading(battle,center),
                std::max(96.f,def->GetMaxRange()*options.frontLineSpacing),[&](commander::Point p) {
                    return OnMap(F(p)) && battle->CorridorAtPoint(cls,F(p))==corridor;
                },int(std::ceil(std::hypot(AIFloat3::maxxpos,AIFloat3::maxzpos)/64.f)));
            State::TerritoryPlan plan;
            plan.progress=own;
            for(auto p:sites) {auto at=F(p);at.y=ai->GetMap()->GetElevationAt(at.x,at.z);plan.sites.push_back(at);}
            s.territoryProgress=own;
            if(!plan.sites.empty()) s.territoryPlans.push_back(std::move(plan));
            ai->LOG("[CommanderFront] unit=%i territory_line corridor=%i progress=%.0f sites=%u retained=%u",unit->GetId(),corridor,own,unsigned(sites.size()),unsigned(s.territoryPlans.size()));
        }
    }
    State::TerritoryPlan* selected=nullptr;
    float closest=std::numeric_limits<float>::max();
    s.territoryPending=false;
    for(auto& plan:s.territoryPlans) {
        if(!plan.pending) continue;
        s.territoryPending=true;
        if(incremental && plan.progress<own-options.frontWorkBehind) continue;
        const float distance=std::abs(plan.progress-own);
        if(distance<closest) {closest=distance;selected=&plan;}
    }
    const float next=std::min(s.fortifyNextProgress,
        std::min(options.frontDistance,length-options.frontStandoff)-64.f);
    if(!selected || (incremental && unit->GetId()!=groupUnit && own<next)) return nullptr;
    auto& plan=*selected;
    const auto center=battle->GetFrontLanePoint(plan.progress);
    const auto forward=Heading(battle,center);
    const commander::Point side{-forward.z,forward.x};
    float left=0,right=0;
    for(const auto& at:plan.sites) {
        const float across=commander::Dot(P(at)-P(center),side);
        left=std::min(left,across);right=std::max(right,across);
    }
    // One bounded spatial query per offer, then O(L log L) interval union for
    // L nearby finished LLTs. Avoid one engine query per planned slot, and
    // recognize continuous coverage from the commander's mex defenses too.
    const float cover=def->GetMaxRange()*.8f;
    workIds=ai->GetCallback()->GetFriendlyUnitIdsIn(center,std::max(-left,right)+cover,false);
    std::vector<commander::CoverageSpan> spans;
    spans.reserve(16);
    for(int id:workIds) {
        auto* ally=ai->GetFriendlyUnit(id);
        if(!ally || ally->GetCircuitDef()!=def || ally->GetUnit()->IsBeingBuilt()) continue;
        commander::CoverageSpan span;
        if(commander::TurretCoverage(P(ally->GetPos(frame)),P(center),side,cover,span)) spans.push_back(span);
    }
    // A one-point narrow territory still requires coverage of that point.
    const float gap=commander::FirstCoverageGap(spans,left,right+1.f);
    if(gap>=right+1.f) {
        if(s.territoryPending) ai->LOG("[CommanderFront] unit=%i territory_complete corridor=%i sites=%u",unit->GetId(),corridor,unsigned(plan.sites.size()));
        plan.pending=false;
        s.territoryPending=std::any_of(s.territoryPlans.begin(),s.territoryPlans.end(),[](const auto& p){return p.pending;});
        return nullptr;
    }
    s.territoryPending=true;
    if(frame>=s.fortifyRetry) {
        s.fortifyRetry=frame+3*FRAMES_PER_SEC;
        const float local=commander::NearestCoverageGap(spans,left,right+1.f,
            commander::Dot(P(pos)-P(center),side));
        const float across=incremental?local:commander::GapBuildOffset(spans,gap,right,
            std::min(cover*.9f,def->GetMaxRange()*options.frontLineSpacing*.5f));
        auto at=F(P(center)+side*across);
        const auto required=F(P(center)+side*(incremental?local:gap));
        if(incremental && at.SqDistance2D(pos)>options.frontRadius*options.frontRadius) return nullptr;
        if(OnMap(at)) {
            at.y=ai->GetMap()->GetElevationAt(at.x,at.z);
            if(auto* task=FortifySite(unit,def,at,frame,&required)) return task;
        }
        if(frame>=s.lastLog+30*FRAMES_PER_SEC) {
            s.lastLog=frame;
            ai->LOG("[CommanderFront] unit=%i line_blocked corridor=%i gap=%.0f across=%.0f bounds=%.0f,%.0f center=%.0f,%.0f coverage=%u",
                unit->GetId(),corridor,gap,across,left,right,center.x,center.z,unsigned(spans.size()));
        }
    }
    if(incremental) return nullptr;
    auto* wait=static_cast<IWaitTask*>(ai->GetBuilderManager()->Enqueue(TaskB::Wait(3*FRAMES_PER_SEC)));
    wait->SetStationary(true);return wait;
}
}
