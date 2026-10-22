// D-161: terrain-fitted formations. One task owns travel and each member's slot.
namespace AmphibiousFormation {
    AIFloat3 Sea(const AIFloat3& in p) {
        AIFloat3 best(-1,0,-1); float distance=385.0f;
        for (int x=-384;x<=384;x+=64) for (int z=-384;z<=384;z+=64) {
            const AIFloat3 q=p+AIFloat3(float(x),0,float(z));
            const float d=p.distance2D(q);
            if (d<distance && q.x>=0 && q.z>=0 && q.x<AiTerrainWidth() && q.z<AiTerrainHeight()
                && aiBattle.Height(q)<-8) { distance=d;best=q; }
        }
        return best;
    }
    bool Dry(const AIFloat3& in p) {
        if (p.x<32 || p.z<32 || p.x>=AiTerrainWidth()-32 || p.z>=AiTerrainHeight()-32) return false;
        for (int x=-1;x<=1;++x) for (int z=-1;z<=1;++z)
            if (aiBattle.Height(p+AIFloat3(float(x*24),0,float(z*24)))<0) return false;
        return aiBattle.IsPassable(p,Lanes::BOT);
    }
    void Form(AmphibiousOps::Wave@ w) {
        if (w.kind!=0 || w.task is null || w.task.IsDead() || w.members.length()==0) return;
        w.formationAt=ai.frame;
        // Crossing commands finish before deploying the dry firing line.
        if (aiBattle.Height(AmphibiousOps::Leader(w))<0) return;
        const AIFloat3 centre=w.destination, sea=Sea(centre);
        const bool shore=sea.x>=0;
        AIFloat3 direction=shore ? sea-centre : w.goal-centre;
        float length=direction.distance2D(AIFloat3(0,0,0));
        if (length<1) { direction=AIFloat3(0,0,1);length=1; }
        direction=direction*(1.0f/length);
        const AIFloat3 tangent(-direction.z,0,direction.x);
        const float spacing=shore ? AmphibiousOps::shoreSpacing : AmphibiousOps::attackSpacing;
        const int region=StrategicSites::LandAt(centre);
        // Existing slots remain stable when a late landing member joins.
        for (uint member=0;member<w.members.length();++member) {
            const Id id=w.members[member];
            if (w.slotIds.find(id)>=0) continue;
            CCircuitUnit@ unit=ai.GetTeamUnit(id);
            if (unit is null || unit.task !is w.task) continue;
            const AIFloat3 from=unit.GetPos(ai.frame);
            if (aiBattle.Height(from)<0 || StrategicSites::LandAt(from)!=region) continue;
            const int lane=AmphibiousMath::FormationLane(int(member));
            const AIFloat3 desired=centre+tangent*(float(lane)*spacing);
            array<AIFloat3> candidates; array<float> scores;
            for (int x=-192;x<=192;x+=64) for (int z=-192;z<=192;z+=64) {
                const AIFloat3 p=desired+AIFloat3(float(x),0,float(z));
                if (!Dry(p) || StrategicSites::LandAt(p)!=region) continue;
                bool assetBlocked=false;
                for (int asset=0;asset<aiBattle.GetAllyAssetCount();++asset)
                    if (p.distance2D(aiBattle.GetAllyAssetPos(asset))<160.0f) {assetBlocked=true;break;}
                if (assetBlocked) continue;
                bool separate=true;
                for (uint s=0;s<w.slots.length();++s)
                    if (p.distance2D(w.slots[s])<spacing*0.75f) { separate=false;break; }
                for (uint wave=0;wave<AmphibiousOps::waves.length() && separate;++wave) {
                    AmphibiousOps::Wave@ other=AmphibiousOps::waves[wave];
                    if (other is w || other.phase==AmphibiousOps::ADVANCE) continue;
                    for (uint s=0;s<other.slots.length();++s)
                        if (p.distance2D(other.slots[s])<spacing*0.75f) {separate=false;break;}
                }
                if (!separate) continue;
                const AIFloat3 water=shore ? Sea(p) : AIFloat3(-1,0,-1);
                if (shore && water.x<0) continue;
                candidates.insertLast(p);
                const float coastDistance=shore ? p.distance2D(water)-192.0f : 0.0f;
                scores.insertLast(p.distance2D(desired)+(coastDistance<0 ? -coastDistance : coastDistance)*0.5f);
            }
            for (int attempt=0;attempt<12;++attempt) {
                int best=-1; float score=1.0e30f;
                for (uint c=0;c<candidates.length();++c) if (scores[c]<score) {best=int(c);score=scores[c];}
                if (best<0) break;
                scores[best]=1.0e30f;
                array<AIFloat3>@ route=AmphibiousOps::Travel(w,from,candidates[best],true);
                if (route is null || route.length()==0) continue;
                bool dry=true;
                for (uint p=0;p<route.length();++p) if (route[p].y<0) {dry=false;break;}
                if (!dry) { Invariants::Violation("INV-098","amph formation","dry connector entered water");continue; }
                if (!w.task.SetUnitRoute(unit,route,128.0f)) break;
                w.slotIds.insertLast(id);w.slots.insertLast(candidates[best]);
                AmphibiousOps::Say(w,"slot id="+id+" x="+int(candidates[best].x)+" z="+int(candidates[best].z));
                break;
            }
        }
        float span=0;
        for (uint a=0;a<w.slots.length();++a) for (uint b=a+1;b<w.slots.length();++b) {
            const float distance=w.slots[a].distance2D(w.slots[b]);
            if (distance<32) Invariants::Violation("INV-098","amph formation","duplicate firing position");
            span=AiMax(span,distance);
        }
        AmphibiousOps::Say(w,(shore?"shore perimeter":"land line")+" slots="+w.slots.length()+" span="+int(span));
    }
    void Maintain(AmphibiousOps::Wave@ w) {
        if (w.kind!=0) return;
        for (int i=int(w.slotIds.length())-1;i>=0;--i) {
            if (w.members.find(w.slotIds[i])<0) {w.slotIds.removeAt(i);w.slots.removeAt(i);}
            else if (aiBattle.Height(w.slots[i])<0) Invariants::Violation("INV-098","amph formation","firing position submerged");
        }
        if (w.slotIds.length()<w.members.length() && ai.frame-w.formationAt>=20*SECOND) Form(w);
    }
}
