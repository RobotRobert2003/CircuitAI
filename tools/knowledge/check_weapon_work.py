"""Execute extracted old/new TECH weapon selection with identical scripted observations.

String role IDs and the diagnostic budget message are replaced by integer IDs
and a trace event. Engine reads are fixed observations; failed orders can mutate
other slots/observations to verify cache invalidation. Selection bodies are not
reimplemented by the test.
"""
import argparse
from pathlib import Path
import re
import subprocess
from check_performance_policy import ROOT, function

COMMON = r'''
const int SECOND=30, SUPER=3, AIR=1;
class AIFloat3 { int x; float distance2D(const AIFloat3 &in p) const { return float(x>p.x?x-p.x:p.x-x); } }
// Dedicated economy flak admission is outside the cache-equivalence domain.
// Its enabled behavior is checked by the physical eco-flak arena.
namespace EcoFlak { bool OwnsArea(const AIFloat3 &in p) { return false; } }
class CCircuitDef { int id; float costM; bool air; bool CanBuild(CCircuitDef@ d) { return d.id!=4; } }
class CCircuitUnit { CCircuitDef@ circuitDef; AIFloat3 GetPos(int f) { return AIFloat3(); } }
class IUnitTask { int id; }
namespace Task { enum BuildType { GEO } }
class IBuilderTask : IUnitTask { Task::BuildType GetBuildType() { return Task::GEO; } }
// Geothermal handoff is outside this cache-equivalence oracle's role domain.
namespace Team { namespace GeoRelease {
    IUnitTask@ Work(CCircuitUnit@ unit, const AIFloat3 &in position) { return null; }
    bool Waiting(const AIFloat3 &in position) { return false; }
}}
class Slot { int role; AIFloat3 pos; bool dead; int orderedFrame; int standFrame; }
class WCluster { int kind; bool stale; AIFloat3 pos; array<Slot@> slots; }
class AI { int frame=12000; } AI ai;
class Eco { bool isMetalFull; } Eco aiEconomyMgr;
array<WCluster@> clusters;
array<CCircuitDef@> defs;
array<bool> unfinished64, unfinished96, siteOK, orderOK, mutate;
array<int> trace;
CCircuitUnit unit, marker;
float income, tokens;
int lastBudgetLog, countCalls;
namespace Global { namespace RoleSettings { namespace Tech {
    float WeaponWorkRadius=900, WeaponArtyMinIncome=200;
    int WeaponMaxConcurrent=4;
}}}
namespace UnitHelpers { bool IsAirConstructor(CCircuitDef@ d) { return d.air; } }
class Builder {
    CCircuitUnit@ FindUnfinishedNear(const AIFloat3 &in p, float radius, CCircuitDef@ d) {
        return (radius>80?unfinished96[p.x]:unfinished64[p.x])?@marker:null;
    }
} Builder aiBuilderMgr;
CCircuitDef@ Def(int role) { return role==0?null:defs[role]; }
bool Active() { return true; }
// This differential suite isolates pending-order caching after policy admission.
// TECH's defense-release gate is exercised by the conversion runtime fixture.
bool PlacementReleased(int kind, const AIFloat3 &in position) { return true; }
float MetalIncome() { return income; }
float Gate(int kind) { return kind==2?150:0; }
bool SuperStartable(WCluster@ c) { return income>=300; }
bool Site(Slot@ s, CCircuitDef@ d, AIFloat3 &out at) {
    trace.insertLast(10000+s.pos.x); at=s.pos; return siteOK[s.pos.x];
}
void RecordBudgetLog() { trace.insertLast(-2); }
IUnitTask@ Order(CCircuitUnit@ u,WCluster@ c,Slot@ s,CCircuitDef@ d,const AIFloat3 &in at) {
    trace.insertLast(20000+s.pos.x);
    if (orderOK[s.pos.x]) { IUnitTask t; t.id=s.pos.x; s.orderedFrame=ai.frame; return t; }
    if (mutate[s.pos.x]) {
        // Stand-in for synchronous enqueue/abort hooks affecting other state.
        Slot@ other=clusters[clusters.length()-1].slots[0];
        other.orderedFrame=ai.frame; other.dead=false;
        unfinished96[other.pos.x]=true; aiEconomyMgr.isMetalFull=!aiEconomyMgr.isMetalFull;
    }
    return null;
}
uint seed;
uint R() { seed=1664525*seed+1013904223; return seed^(seed>>16); }
void Prepare(uint input, bool bench=false) {
    seed=input; ai.frame=12000; clusters.resize(0); defs.resize(6); trace.resize(0); countCalls=0;
    for(uint k=0;k<defs.length();++k) { CCircuitDef d; d.id=int(k); d.costM=float(k*10); @defs[k]=d; }
    @unit.circuitDef=defs[1]; defs[1].air=(R()%2)==0;
    income=float(R()%450); tokens=float(R()%90); lastBudgetLog=int(R()%13000);
    aiEconomyMgr.isMetalFull=(R()%2)==0; Global::RoleSettings::Tech::WeaponMaxConcurrent=int(R()%5);
    int n=bench?32:int(1+R()%12), total=n*16;
    unfinished64.resize(total);unfinished96.resize(total);siteOK.resize(total);orderOK.resize(total);mutate.resize(total);
    array<int> ages={-1,0,29*SECOND,30*SECOND,59*SECOND,60*SECOND,299*SECOND,300*SECOND,300*SECOND+1,100000};
    for(int c=0;c<n;++c) {
        WCluster w; w.kind=int(R()%4);w.stale=R()%5==0;w.pos.x=int(R()%1600);
        for(int j=0;j<16;++j) {
            int id=c*16+j;Slot s;s.role=int(R()%6);s.pos.x=id;s.dead=R()%5==0;
            s.standFrame=R()%3==0?0:-1;s.orderedFrame=ai.frame-ages[R()%ages.length()];
            unfinished64[id]=R()%5==0;unfinished96[id]=R()%4==0;siteOK[id]=R()%3!=0;orderOK[id]=R()%4==0;mutate[id]=R()%3==0;
            if(bench){s.role=4;s.dead=false;s.standFrame=-1;s.orderedFrame=-100000;}
            w.slots.insertLast(s);
        }
        if(bench){w.kind=0;w.stale=false;w.pos.x=0;income=400;tokens=1000;Global::RoleSettings::Tech::WeaponMaxConcurrent=4;}
        clusters.insertLast(w);
    }
}
array<int>@ Snapshot(IUnitTask@ result) {
    array<int> a={result is null?-1:result.id,int(tokens),lastBudgetLog,aiEconomyMgr.isMetalFull?1:0};
    for(uint c=0;c<clusters.length();++c)for(uint j=0;j<clusters[c].slots.length();++j){
        Slot@ s=clusters[c].slots[j];a.insertLast(s.dead?1:0);a.insertLast(s.orderedFrame);a.insertLast(unfinished96[s.pos.x]?1:0);
    }
    a.insertLast(-3);for(uint i=0;i<trace.length();++i)a.insertLast(trace[i]);return a;
}
void Advance() {
    ai.frame+=31*SECOND;
    Slot@ s=clusters[clusters.length()-1].slots[0];
    s.dead=false; s.standFrame=-1; s.orderedFrame=-100000;
    siteOK[s.pos.x]=true; orderOK[s.pos.x]=true;
    unfinished64[s.pos.x]=false;unfinished96[s.pos.x]=false;
}
'''


def generate():
    result = COMMON
    for name, path in (("Old", ROOT/'tests/fixtures/performance/weapon_work_before.as'),
                       ("New", ROOT/'data/script/src/roles/tech/tech_weapons.as')):
        source = path.read_text(encoding='utf-8')
        body = function(source, 'int OutstandingOrders()') + '\n' + function(source, 'IUnitTask@ Work(')
        body = re.sub(r'if \(AiPerfEnabled\) AiPerf\w+\([^;]*\);', '', body)
        body = re.sub(r'GenericHelpers::LogUtil\([^;]*;', 'RecordBudgetLog();', body)
        # The legacy fixture has no geothermal/special roles. Preserve its
        # measured cache domain rather than inventing a handoff simulation.
        body = re.sub(r'\s*if \(s.role == "special"[^\n]*\n', '\n', body)
        body = body.replace('"art2"', '2').replace('"super"', '3').replace('"geoartillery"', '6')
        body = body.replace('OutstandingOrders()', name+'OutstandingOrders()').replace('IUnitTask@ Work(', 'IUnitTask@ '+name+'Work(')
        start = body.index('{')+1
        body = body[:start]+' ++countCalls; '+body[start:]
        result += '\n'+body
    return result


TESTS = r'''
void CompareWeaponWork(uint first, uint last) {
    for(uint n=first;n<=last;++n) {
        Prepare(n); int oldCount=OldOutstandingOrders();
        IUnitTask@ oldTask=OldWork(unit); array<int>@ before=Snapshot(oldTask);
        @oldTask=OldWork(unit); array<int>@ again=Snapshot(oldTask);
        Advance(); @oldTask=OldWork(unit); array<int>@ advanced=Snapshot(oldTask);
        Prepare(n); Check(NewOutstandingOrders()==oldCount);
        IUnitTask@ newTask=NewWork(unit); array<int>@ after=Snapshot(newTask);
        Check(before.length()==after.length());for(uint k=0;k<before.length();++k)Check(before[k]==after[k]);
        @newTask=NewWork(unit); @after=Snapshot(newTask);
        Check(again.length()==after.length());for(uint k=0;k<again.length();++k)Check(again[k]==after[k]);
        Advance(); @newTask=NewWork(unit); @after=Snapshot(newTask);
        Check(advanced.length()==after.length());for(uint k=0;k<advanced.length();++k)Check(advanced[k]==after[k]);
    }
}
void test_repeated_read_work() {
    Prepare(1,true); Check(OldWork(unit) is null); Check(countCalls==32);
    Prepare(1,true); Check(NewWork(unit) is null); Check(countCalls==1);
}
'''
# Keep all 20,000 seeds, with GC opportunities between engine callbacks.
# A single giant VM call otherwise retains millions of deferred class objects
# and hits AngelScript's debug reference-count ceiling before checking policy.
TESTS += '\n'.join(
    f'void test_weapon_work_equivalence_{index}() {{ CompareWeaponWork({index*1000+1}, {(index+1)*1000}); }}'
    for index in range(20))
BENCH = r'''
void bench_0_old() { Prepare(1,true);for(int i=0;i<1000;++i)Check(OldWork(unit) is null);Check(countCalls==32000); }
void bench_1_new() { Prepare(1,true);for(int i=0;i<1000;++i)Check(NewWork(unit) is null);Check(countCalls==1000); }
void bench_2_new() { bench_1_new(); }
void bench_3_old() { bench_0_old(); }
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--benchmark',action='store_true')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    policy,tests=args.output/'policy.as',args.output/'tests.as'
    policy.write_text(generate(),encoding='utf-8');tests.write_text(BENCH if args.benchmark else TESTS,encoding='utf-8')
    return subprocess.run([str(args.runner),str(policy),str(tests)]+(['--benchmark'] if args.benchmark else [])).returncode


if __name__=='__main__':
    raise SystemExit(main())
