#ifndef CIRCUIT_LOCAL_RUSH_H
#define CIRCUIT_LOCAL_RUSH_H
#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

namespace circuit::rush {
inline float Score(float own, float enemy, float ratio, float aggression) {
    return own / std::max(1.f, enemy) - ratio + aggression;
}
inline bool Exhausted(unsigned remaining, unsigned initial, float fraction) {
    return initial == 0 || float(remaining) < float(initial) * fraction;
}
// Per-AI callback-thread ownership. Starting/ending a campaign is O(M);
// membership/loss updates are expected O(1). No per-frame army census.
// Original front members alone count toward the immutable denominator.
// Leave removes identity before engine IDs can be reused. See local_rush_test.
class Registry {
public:
    struct Member { int id; bool front; };
    struct Campaign {
        unsigned initial=0, remaining=0;
        float fraction=.25f;
        int cooldown=600;
        std::vector<Member> members;
    };
    int Find(int id) const { auto i=membership.find(id); return i==membership.end()?-1:i->second.key; }
    bool Active(int id) const {
        auto c=campaigns.find(Find(id));
        return c!=campaigns.end() && !Exhausted(c->second.remaining,c->second.initial,c->second.fraction);
    }
    int Cooldown(int id) const { auto i=cooldowns.find(id); return i==cooldowns.end()?0:i->second; }
    int Start(const std::vector<Member>& members, float fraction, int cooldown) {
        const int key=next++;
        auto& c=campaigns[key]; c.fraction=fraction; c.cooldown=cooldown;
        for(const auto& m:members) {
            if(Find(m.id)>=0) continue;
            membership[m.id]={key,c.members.size()}; c.members.push_back(m);
            if(m.front) ++c.initial;
        }
        c.remaining=c.initial;
        return key;
    }
    const Campaign* Get(int key) const { auto c=campaigns.find(key); return c==campaigns.end()?nullptr:&c->second; }
    void Reinforce(int key, const std::vector<Member>& recruits) {
        auto c=campaigns.find(key); if(c==campaigns.end()) return;
        for(const auto& m:recruits) if(Find(m.id)<0) {
            membership[m.id]={key,c->second.members.size()};
            c->second.members.push_back({m.id,false}); // never reset original front strength
        }
    }
    bool Valid() const {
        size_t total=0;
        for(const auto& [key,c]:campaigns) {
            unsigned front=0;
            for(size_t i=0;i<c.members.size();++i) {
                const auto& m=c.members[i]; auto owner=membership.find(m.id);
                if(owner==membership.end() || owner->second.key!=key || owner->second.index!=i) return false;
                front+=m.front;
            }
            if(front!=c.remaining || front>c.initial || c.initial==0) return false;
            total+=c.members.size();
        }
        return total==membership.size();
    }
    void Finish(int key, int now) {
        auto i=campaigns.find(key); if(i==campaigns.end()) return;
        for(const auto& m:i->second.members) if(Find(m.id)==key) {
            membership.erase(m.id); cooldowns[m.id]=now+i->second.cooldown;
        }
        campaigns.erase(i);
    }
    void Leave(int id) {
        const int key=Find(id); auto c=campaigns.find(key);
        if(c!=campaigns.end()) {
            auto& list=c->second.members;
            const size_t index=membership.at(id).index;
            if(list[index].front) --c->second.remaining;
            list[index]=list.back(); membership.at(list[index].id).index=index; list.pop_back();
            if(list.empty()) campaigns.erase(c);
        }
        membership.erase(id); cooldowns.erase(id);
    }
private:
    int next=0;
    struct Entry { int key; size_t index; };
    std::unordered_map<int,Entry> membership;
    std::unordered_map<int,int> cooldowns;
    std::unordered_map<int,Campaign> campaigns;
};
}
#endif
