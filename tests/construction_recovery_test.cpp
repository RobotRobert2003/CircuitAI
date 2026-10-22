#include "task/builder/ConstructionRecovery.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>
int main() {
    using namespace circuit::construction;
    Progress progress;
    assert(progress.MissingCommand());
    // Resource-starved build/repair queues stay valid for arbitrary durations.
    progress.commands=true; assert(!progress.MissingCommand());
    progress.commands=false; progress.moving=true; assert(!progress.MissingCommand());
    progress.moving=false; progress.pathReady=false; assert(!progress.MissingCommand());
    progress.pathReady=true; progress.waiting=true; assert(!progress.MissingCommand());
    progress.waiting=false; progress.owned=false; assert(!progress.MissingCommand());
    // Late-created frames and productive co-builders survive a failed owner.
    for (bool valid : {false,true}) for (bool reachable : {false,true}) {
        assert(!RetireUnstarted(true,false,valid,reachable));
        assert(!RetireUnstarted(false,true,valid,reachable));
    }
    assert(!RetireUnstarted(false,false,true,true)); // reassign same valid site
    assert(RetireUnstarted(false,false,false,true)); // blocked unstarted footprint
    assert(RetireUnstarted(false,false,true,false)); // no capable reachable worker
    // Expensive projects need not fit in storage to create their first frame.
    assert(CanStart(100,1000,3000,15000,10000,100,1));
    assert(!CanStart(0,1000,3000,15000,10000,100,1));
    assert(!CanStart(100,0,3000,15000,10000,100,1));
    assert(!CanStart(100,1000,3000,15000,0,100,1));
    assert(CanStart(3000,15000,3000,15000,10000,100,1000));
    Observation state;
    assert(!state.StalledCommand(0,100,200,true,1800));
    assert(!state.StalledCommand(1500,100,200,true,1800));
    assert(state.StalledCommand(1800,104,198,true,1800)); // blocked shuffle, not travel
    // Movement away from the goal is still progress (cliff detour), and a
    // pending path/wait or newly created frame starts a fresh observation.
    assert(!state.StalledCommand(1801,125,200,true,1800));
    assert(!state.StalledCommand(3000,125,200,true,1800));
    assert(!state.StalledCommand(3500,125,200,false,1800));
    assert(!state.StalledCommand(8000,125,200,true,1800));
    assert(state.Observe(0,true,300,900)==Recovery::NONE);
    assert(state.Observe(150,true,300,900)==Recovery::NONE);
    assert(state.Observe(300,true,300,900)==Recovery::RETRY);
    assert(state.Observe(450,true,300,900)==Recovery::NONE);
    assert(state.Observe(900,true,300,900)==Recovery::RELEASE);
    // Queue restored / path pending / movement / intentional wait resets the
    // failure episode. A later loss gets its own observation and retry.
    assert(state.Observe(901,false,300,900)==Recovery::NONE);
    assert(state.Observe(2000,true,300,900)==Recovery::NONE);
    assert(state.Observe(2200,false,300,900)==Recovery::NONE);
    assert(state.Observe(3000,true,300,900)==Recovery::NONE);
    assert(state.Observe(3300,true,300,900)==Recovery::RETRY);
    for(int frame=3450;frame<9000;frame+=150) assert(state.Observe(frame,false,300,900)==Recovery::NONE);
    std::puts("construction recovery: bounded retry/release and productive controls PASS");
}
