#include "../../helpers/math/delivery_front_math.as"

namespace TechDeliveryFront {
    // Called only for dispatch/retry, never per cargo per frame. At most 512
    // live LOS samples shared by the dispatch, plus twelve local landing probes.
    // No enemy scan or radar-as-vision. Lock the accepted endpoint through the
    // flight so the carrier's own sight cannot push its target farther forward.
    bool Plan(CCircuitUnit@ cargo, array<AIFloat3>& out route, AIFloat3& out destination) {
        destination=AIFloat3(-1,0,-1);
        array<AIFloat3> lane=Spam::DeliveryLane();
        const float length=DeliveryFrontMath::Length(lane);
        if (length<1.0f) return false;
        const int samples=AiMin(512,AiMax(1,int(ceil(length/64.0f))));
        const float step=length/float(samples);
        float edge=-1.0f;
        bool visible=aiBattle.InLos(lane[0]);
        for (int i=1;i<=samples;++i) {
            const bool next=aiBattle.InLos(DeliveryFrontMath::At(lane,float(i)*step));
            if (visible && !next) edge=float(i)*step;
            visible=next;
        }
        if (edge<0.0f) return false; // no observed forward fog edge yet
        // Refine the final visible -> fog transition to ~4 elmos.
        float lo=AiMax(0.0f,edge-step), hi=edge;
        for (int i=0;i<5;++i) {
            const float middle=(lo+hi)*0.5f;
            if (aiBattle.InLos(DeliveryFrontMath::At(lane,middle))) lo=middle; else hi=middle;
        }
        const AIFloat3 fog=DeliveryFrontMath::At(lane,hi);
        const float range=AiMax(1.0f,cargo.circuitDef.GetMaxRange());
        float along=AiMax(0.0f,lo-range);
        for (int attempt=0;attempt<12 && along>0.0f;++attempt,along-=64.0f) {
            const AIFloat3 desired=DeliveryFrontMath::At(lane,along);
            if (desired.distance2D(fog)<range-8.0f || !aiBattle.InLos(desired)) continue;
            const AIFloat3 drop=aiTerrainMgr.FindSafeDropSpot(cargo,desired,64.0f,
                Global::Ferry::DropSurfaceThreat,Global::RoleSettings::Tech::HeavyDeliveryAirThreat);
            if (drop.x<0.0f || !aiBattle.InLos(drop) || drop.distance2D(fog)<range-32.0f
                || aiBattle.AirThreatAlong(drop,drop,Global::RoleSettings::Tech::HeavyDeliveryAirPadding)
                    >Global::RoleSettings::Tech::HeavyDeliveryAirThreat) continue;
            float passed=0.0f;
            for (uint i=1;i<lane.length();++i) {
                passed+=lane[i-1].distance2D(lane[i]);
                if (passed>=along) break;
                route.insertLast(lane[i]);
            }
            route.insertLast(drop); destination=drop;
            GenericHelpers::LogUtil("[HeavyDelivery] front drop="+int(drop.x)+","+int(drop.z)
                +" fog="+int(fog.x)+","+int(fog.z)+" range="+int(range)
                +" standoff="+int(drop.distance2D(fog))+" waypoints="+route.length(),1);
            return true;
        }
        return false;
    }
}
