// Pure polyline geometry. Distances are world elmos, not waypoint indices.
namespace DeliveryFrontMath {
    float Length(const array<AIFloat3>& in points) {
        float result=0.0f;
        for (uint i=1;i<points.length();++i) result+=points[i-1].distance2D(points[i]);
        return result;
    }
    AIFloat3 At(const array<AIFloat3>& in points,float distance) {
        if (points.length()==0) return AIFloat3(-1,0,-1);
        for (uint i=1;i<points.length();++i) {
            const float length=points[i-1].distance2D(points[i]);
            if (length<0.01f) continue;
            if (distance<=length) {
                const float t=AiMax(0.0f,distance)/length;
                return AIFloat3(points[i-1].x+(points[i].x-points[i-1].x)*t,0,
                    points[i-1].z+(points[i].z-points[i-1].z)*t);
            }
            distance-=length;
        }
        return points[points.length()-1];
    }
}
