#include "circuit/spring/RouteCommand.h"
#include "circuit/terrain/RangedGeometry.h"
#include <stdexcept>
#include <iostream>
#include <chrono>
using circuit::routecommand::Command;
void Check(bool value) { if(!value) throw std::runtime_error("route command assertion"); }
int main(int argc, char**) {
    std::vector<Command> sent{{10,0,100,1,2,3},{10,32,100,4,5,6},{10,32,100,7,8,9}},live=sent;
    auto match=[&](int frame) { return circuit::routecommand::LiveSuffix(sent,live.size(),frame,
        [&](int i,Command& c){ c=live[i];return true; }); };
    Check(match(99));live.erase(live.begin());Check(match(100));Check(!match(101));
    live[0].options=0;Check(!match(99));live[0]=sent[1];
    live[0].timeout=101;Check(!match(99));live[0]=sent[1];
    live[0].id=0;Check(!match(99));live[0]=sent[1];
    live[0].x+=1;Check(!match(99));live.clear();Check(!match(99));
    struct Pos { float x,y,z; };
    using circuit::routecommand::RemainingIntent;
    std::vector<Command> remaining{{10,0,200,4,5,6},{10,32,200,7,8,9}};
    Check(RemainingIntent(sent,remaining,0,0,0,32));
    remaining.insert(remaining.begin(),{10,0,200,0,0,0});
    remaining[1].options=32;
    Check(RemainingIntent(sent,remaining,0,0,0,32));
    Check(!RemainingIntent(sent,remaining,0,1,0,32)); // joining move still necessary
    remaining.back().x+=.01f;Check(!RemainingIntent(sent,remaining,0,0,0,32));
    remaining.back().x=7;remaining.back().options=0;
    Check(!RemainingIntent(sent,remaining,0,0,0,32));
    std::vector<Pos> line{{0,0,0},{64,0,0},{128,0,0},{192,0,0},{256,0,0},{320,0,0}};
    circuit::ranged::CompactStraightRoute(line);Check(line.size()==2 && line[0].x==0 && line[1].x==320);
    // Projected flank path has a shore-induced bend absent from the centerline.
    std::vector<Pos> flank{{0,0,64},{64,0,64},{128,0,0},{192,0,64},{256,0,64}};
    circuit::ranged::CompactStraightRoute(flank);Check(flank.size()==5);
    std::vector<Pos> reversal{{0,0,0},{64,0,0},{0,0,0}};
    circuit::ranged::CompactStraightRoute(reversal);Check(reversal.size()==3);
    std::vector<Pos> segmented;
    for(int i=0;i<100;++i) segmented.push_back({float(i*64),0,0});
    int validations=0;
    circuit::ranged::CompactValidatedStraightRoute(segmented,[&](const Pos& a,const Pos& b){
        ++validations; Check(b.x-a.x==64); return a.x!=49*64;
    });
    Check(validations==99 && segmented.size()==4);
    Check(segmented[0].x==0 && segmented[1].x==49*64 && segmented[2].x==50*64 && segmented[3].x==99*64);
    std::vector<Pos> bend{{0,0,0},{64,0,0},{128,0,0},{128,0,64},{128,0,128}};
    circuit::ranged::CompactValidatedStraightRoute(bend,[](const Pos&,const Pos&){return true;});
    Check(bend.size()==3 && bend[1].x==128 && bend[1].z==0);
    auto unchanged=flank;
    circuit::ranged::CompactValidatedStraightRoute(unchanged,[](const Pos&,const Pos&){return false;});
    Check(unchanged.size()==flank.size());
    circuit::ranged::CompactValidatedStraightRoute(reversal,[](const Pos&,const Pos&){return true;});
    Check(reversal.size()==3);
    int irreducibleChecks=0;
    // Diagonal projection rounding used to defeat exact collinearity. The
    // corridor keeps its fixed axis (no accumulating shortcuts through bends).
    std::vector<Pos> rounded;
    for(int index=0;index<100;++index) rounded.push_back({6000.f-index*17.1f,0,1200.f+index*26.7f});
    const Pos finalRounded=rounded.back();
    int corridorChecks=0;
    circuit::ranged::CompactValidatedCorridorRoute(rounded,[&](const Pos&,const Pos&){++corridorChecks;return true;},1.0/32.0);
    Check(rounded.size()==2 && corridorChecks==99 && rounded.back().x==finalRounded.x && rounded.back().z==finalRounded.z);
    auto corridorBend=flank;
    circuit::ranged::CompactValidatedCorridorRoute(corridorBend,[](const Pos&,const Pos&){return true;},1.0/32.0);
    Check(corridorBend.size()==flank.size());
    auto corridorReverse=reversal;
    circuit::ranged::CompactValidatedCorridorRoute(corridorReverse,[](const Pos&,const Pos&){return true;},1.0/32.0);
    Check(corridorReverse.size()==3);
    std::vector<Pos> fenced;
    for(int index=0;index<100;++index) fenced.push_back({float(index*64),0,0});
    circuit::ranged::CompactValidatedCorridorRoute(fenced,[](const Pos& a,const Pos&){return a.x!=49*64;},1.0/32.0);
    Check(fenced.size()==4 && fenced[1].x==49*64 && fenced[2].x==50*64);
    std::cout<<"rounded diagonal: 100 -> 2 commands, 99 original-leg validations PASS\n";
    auto zigzag=flank;
    circuit::ranged::CompactValidatedStraightRoute(zigzag,[&](const Pos&,const Pos&){++irreducibleChecks;return true;});
    Check(irreducibleChecks==0 && zigzag.size()==flank.size());
    // Clear routes must match the previous exact reducer, including repeated
    // points and changes in direction. Deterministic generated regression.
    unsigned seed=271;
    for(int trial=0;trial<500;++trial) {
        std::vector<Pos> oldPath{{0,0,0}};
        for(int i=0;i<100;++i) {
            seed=seed*1664525u+1013904223u;
            auto next=oldPath.back();
            next.x+=float(int((seed>>16)%3)-1)*64;
            next.z+=float(int((seed>>20)%3)-1)*64;
            oldPath.push_back(next);
        }
        auto newPath=oldPath;
        circuit::ranged::CompactStraightRoute(oldPath);
        circuit::ranged::CompactValidatedStraightRoute(newPath,[](const Pos&,const Pos&){return true;});
        Check(oldPath.size()==newPath.size());
        for(size_t i=0;i<oldPath.size();++i) Check(oldPath[i].x==newPath[i].x && oldPath[i].z==newPath[i].z);
    }
    std::cout<<"validated runs: 100 -> 4 commands despite one rejected leg; 99 original-leg checks PASS\n";
    std::cout<<"route commands: exact live suffix, expiry, recovery, projected bends and reversals PASS\n";
    if (argc>1) {
        // Equivalent rounded 100-point input; geometry component only. The
        // real terrain sampler/network/FPS are deliberately not simulated.
        std::vector<Pos> input;
        for(int index=0;index<100;++index) input.push_back({6000.f-index*9.1f,0,1200.f+index*6.1f});
        for(int implementation=0;implementation<2;++implementation) {
            size_t commands=0,validations=0;
            const auto start=std::chrono::steady_clock::now();
            for(int iteration=0;iteration<20000;++iteration) {
                auto path=input;
                auto clear=[&](const Pos&,const Pos&){++validations;return true;};
                if(implementation==0) circuit::ranged::CompactValidatedStraightRoute(path,clear);
                else circuit::ranged::CompactValidatedCorridorRoute(path,clear,1.0/32.0);
                commands+=path.size();
            }
            const auto elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
            std::cout<<"geometry implementation="<<implementation<<" routes=20000 milliseconds="<<elapsed<<" commands="<<commands<<" validations="<<validations<<'\n';
        }
    }
}
