#include "circuit/spring/CallbackBuffer.h"
#include <chrono>
#include <iostream>
#include <stdexcept>

static void Check(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
int main() {
    circuit::CallbackBuffer buffer;
    const int maximum=32768;
    const int* retained=nullptr;
    for(int iteration=0;iteration<1000;++iteration) {
        const int count=iteration%101;
        auto result=buffer.Read(maximum,[&](int* output,int capacity) {
            Check(capacity==maximum,"callback still receives full capacity");
            if(retained) Check(output==retained,"storage address retained");
            if(iteration>0) Check(output[maximum-1]==771,"unused tail must not be reinitialized");
            output[maximum-1]=771;
            for(int i=0;i<count;++i) output[i]=iteration-i;
            return count;
        });
        retained=result.data(); Check(int(result.size())==count,"populated prefix only");
        for(int i=0;i<count;++i) Check(result[i]==iteration-i,"exact producer order");
    }
    Check(buffer.Read(maximum,[](int*,int){return -1;}).empty(),"failed callback is empty");
    Check(buffer.Read(3,[](int* values,int){values[0]=1;values[1]=2;values[2]=3;return 7;}).size()==3,"bounded oversized result");
    auto measure=[&](bool optimized) {
        circuit::CallbackBuffer scratch; std::vector<int> legacy; long long checksum=0;
        const auto start=std::chrono::steady_clock::now();
        for(int query=0;query<100000;++query) {
            const int count=query%101;
            auto producer=[&](int* output,int) {for(int i=0;i<count;++i) output[i]=query-i;return count;};
            if(optimized) {auto result=scratch.Read(maximum,producer);legacy.assign(result.begin(),result.end());}
            else {legacy.resize(maximum);producer(legacy.data(),maximum);legacy.resize(count);}
            for(int value:legacy) checksum+=value;
        }
        return std::pair{checksum,std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count()};
    };
    const auto old=measure(false), current=measure(true);
    Check(old.first==current.first,"old/new callback result parity");
    std::cout<<"callback buffer: 1000 lifecycle cases + 100000 queries PASS; old_ms="<<old.second<<" new_ms="<<current.second<<"\n";
}
