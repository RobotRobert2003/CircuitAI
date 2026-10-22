"""D-199: compile actual old/new policy bodies in the pinned AngelScript VM.

The engine-free fixture replaces option discovery with an identical input array
and definition names with integer dictionary keys. Ranking and CanPlace control
flow are extracted, not rewritten. The old source is an immutable fixture.
"""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def function(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def generate():
    fixtures = ROOT / 'tests/fixtures/performance'
    old = (fixtures / 'energy_options_before.as').read_text(encoding='utf-8')
    new = (ROOT / 'data/script/src/systems/construction/eco_planner.as').read_text(encoding='utf-8')
    text = '''
class Option { int id; float cost, metalPerE, output; }
class State { float bank; }
array<Option@> input;
bool Affordable(const Option@ o, const State@ s) { return o.cost <= s.bank; }
'''
    for label, source, sig in [('Old', old, 'array<Option@> EnergyOptions('),
                               ('New', new, 'array<Option@>@ EnergyOptions(')]:
        body = function(source, sig)
        # Discovery is unchanged; isolate the sort and its real return type.
        begin = body.index('// affordable first')
        head = body[:body.index('{')].replace('EnergyOptions', label)
        text += head + '{ array<Option@> opts = input;\n' + body[begin:] + '\n'
    old = (fixtures / 'layout_can_place_before.as').read_text(encoding='utf-8')
    new = (ROOT / 'data/script/src/systems/construction/layout.as').read_text(encoding='utf-8')
    text += '''
class CCircuitDef { int key; int GetName() const { return key; } }
class dictionary {
    array<int64> times(8, -100000); array<bool> values(8, true);
    void get(int key, int64 &out v) { v=times[key]; }
    void get(int key, bool &out v) { v=values[key]; }
    void set(int key, int64 v) { times[key]=v; }
    void set(int key, bool v) { values[key]=v; }
}
dictionary canPlaceAt, canPlaceWas;
class AI { int frame=0; } AI ai;
const int SECOND=30;
namespace Global { namespace RoleSettings { namespace Tech {
float LayoutCanPlaceMemoSeconds=2.0f;
} } }
bool hasBox=true; int zoneCount=0, hit=-1, probes=0;
int nanoGroup=1, facing=0;
bool HasBox() { return hasBox; }
int ZoneCount() { return zoneCount; }
int ZoneAt(int i) { return i; }
float MinNanoDist(const CCircuitDef@ d) { return 0.0f; }
class Terrain {
bool CanPackNearGroup(int z, const CCircuitDef@ d, int g, int f, float r, float m) {
    ++probes; return z==hit;
} } Terrain aiTerrainMgr;
'''
    for label, source in [('OldCanPlace', old), ('NewCanPlace', new)]:
        body = function(source, 'bool CanPlace(')
        text += body.replace('CanPlace(', label + '(', 1).replace('const string key', 'const int key') + '\n'
    return text


TESTS = '''
uint seed=199;
uint Random() { seed=seed*1664525+1013904223; return seed; }
void test_ranking_and_ownership() {
    State s;
    for(int trial=0;trial<20000;++trial) {
        input.resize(Random()%9);
        s.bank=float(Random()%7);
        for(uint i=0;i<input.length();++i) {
            Option o; o.id=int(i); o.cost=float(Random()%9);
            o.metalPerE=float(Random()%5); o.output=float(Random()%5);
            @input[i]=o;
        }
        array<Option@> before=Old(s);
        array<Option@>@ after=New(s);
        Check(before.length()==after.length());
        for(uint i=0;i<before.length();++i) {
            Check(before[i] is after[i]);
            Check(input[i].id==int(i)); // callers' input was not mutated
        }
        // PickEnergy removes disallowed reactors from its owned return array.
        for(int i=int(before.length())-1;i>=0;--i) {
            if(before[i].id%2!=0) { before.removeAt(uint(i)); after.removeAt(uint(i)); }
        }
        Check(before.length()==after.length());
        for(uint i=0;i<before.length();++i) Check(before[i] is after[i]);
        for(uint i=0;i<input.length();++i) Check(input[i].id==int(i));
    }
}
void test_preflight_memo_and_geometry_changes() {
    CCircuitDef d;
    for(int trial=0;trial<20000;++trial) {
        d.key=int(Random()%8); ai.frame+=int(Random()%90);
        if(trial%997==0) ai.frame=0; // load/rewind clock
        zoneCount=int(Random()%12); hit=int(Random()%14)-2;
        hasBox=(Random()%3)!=0;
        Check(OldCanPlace(d)==NewCanPlace(d));
        Check(OldCanPlace(null)==NewCanPlace(null));
        int previous=probes;
        Check(NewCanPlace(d)); Check(probes==previous);
    }
    Check(probes>1000); // exercise discarded old native searches
}
'''

BENCH = '''
void Prepare() {
    input.resize(5);
    for(uint i=0;i<5;++i) {
        Option o; o.id=int(i); o.cost=float(i*100);
        o.metalPerE=float(5-i); o.output=float(i*20); @input[i]=o;
    }
}
void bench_0_old() {
    Prepare(); State s; s.bank=250;
    for(int i=0;i<100000;++i) { array<Option@> opts=Old(s); Check(opts[0].id==2); }
}
void bench_1_new() {
    Prepare(); State s; s.bank=250;
    for(int i=0;i<100000;++i) { const array<Option@>@ opts=New(s); Check(opts[0].id==2); }
}
void bench_2_new() { bench_1_new(); }
void bench_3_old() { bench_0_old(); }
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--benchmark', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    policy, tests = args.output / 'policy.as', args.output / 'tests.as'
    policy.write_text(generate(), encoding='utf-8')
    tests.write_text(BENCH if args.benchmark else TESTS, encoding='utf-8')
    command = [str(args.runner), str(policy), str(tests)]
    if args.benchmark:
        command.append('--benchmark')
    return subprocess.run(command, check=False).returncode


if __name__ == '__main__':
    raise SystemExit(main())
