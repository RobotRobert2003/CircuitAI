#include "circuit/util/DefinitionCounts.h"
#include <map>
#include <random>
#include <stdexcept>
#include <iostream>
int main() {
    circuit::DefinitionCounts<int> index;
    std::map<int,int> oracle;
    std::mt19937 rng(243);
    for(int i=0;i<12000;++i) {
        int key=rng()%300, def=rng()%37;
        if(i%71==0) { index.Clear();oracle.clear(); }
        else if(i%3==0) { index.Erase(key);oracle.erase(key);index.Erase(key); }
        else { index.Set(key,def);oracle[key]=def;index.Set(key,def); }
        for(int d=-1;d<40;++d) {
            int count=0;for(auto [id,v]:oracle) if(v==d) ++count;
            if(index.Count(d)!=count) throw std::runtime_error("definition lifecycle mismatch");
        }
    }
    std::cout<<"definition counters: duplicate/create/frame/repeat/remove/reuse/rebuild oracle PASS\n";
}
