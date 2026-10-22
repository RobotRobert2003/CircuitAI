// Exercise the shipped CUnitAPI adapter against Recoil's actual C ABI. The
// fake callback implements its bounded-copy return contract (not array size).
#include "spring/SpringUnit.h"
#include "SSkirmishAICallback.h"
#include "Sim/Units/CommandAI/Command.h"
#include <algorithm>
#include <cassert>
#include <climits>
#include <iostream>
#include <limits>
#include <vector>

struct Entry { int id; std::vector<float> params; short options=0; int timeout=INT_MAX; };
static std::vector<Entry> queue;
static int reads=0;
static void CheckIds(int ai,int unit) { assert(ai==7 && unit==12); ++reads; }
static int CALLING_CONV Count(int ai,int unit) { CheckIds(ai,unit);return int(queue.size()); }
static int CALLING_CONV Id(int ai,int unit,int i) { CheckIds(ai,unit);return queue.at(i).id; }
static short CALLING_CONV Options(int ai,int unit,int i) { CheckIds(ai,unit);return queue.at(i).options; }
static int CALLING_CONV Timeout(int ai,int unit,int i) { CheckIds(ai,unit);return queue.at(i).timeout; }
static int CALLING_CONV Params(int ai,int unit,int i,float* dst,int size) {
	CheckIds(ai,unit);
	const auto& p=queue.at(i).params;
	const int n=dst ? std::min(size,int(p.size())) : int(p.size());
	if (dst) std::copy_n(p.begin(),n,dst);
	return n;
}
int main() {
	SSkirmishAICallback cb{};
	cb.Unit_getCurrentCommands=Count;
	cb.Unit_CurrentCommand_getId=Id;
	cb.Unit_CurrentCommand_getOptions=Options;
	cb.Unit_CurrentCommand_getTimeOut=Timeout;
	cb.Unit_CurrentCommand_getParams=Params;
	circuit::CUnitAPI api(&cb,7);
	queue.clear(); reads=0;
	assert(!api.HasQueuedCommand(12,CMD_WAIT) && reads==1);
	queue={{CMD_MOVE,{10,0,20}},{CMD_WAIT,{}}};
	assert(api.HasQueuedCommand(12,CMD_WAIT)); // later WAIT must be removed too
	queue={{CMD_WAIT,{}},{CMD_MOVE,{10,0,20}}};
	assert(api.HasQueuedCommand(12,CMD_WAIT));
	queue={{-123,{}},{-456,{}}}; // factory build queue, no WAIT
	assert(!api.HasQueuedCommand(12,CMD_WAIT));
	queue.push_back({CMD_WAIT,{}}); // same-frame queue mutation, no memo
	assert(api.HasQueuedCommand(12,CMD_WAIT));
	int checks=0;
	auto test=[&](std::vector<Entry> q,bool expected,int target=42,int frame=100) {
		queue=std::move(q);
		assert(api.HasGuardIntent(12,target,frame)==expected);++checks;
	};
	const Entry guard{CMD_GUARD,{42}};
	const Entry repair{CMD_REPAIR,{55}};
	test({},false);
	test({guard},true);
	test({{CMD_GUARD,{42},SHIFT_KEY}},true);
	for (short option : {short(CONTROL_KEY),short(ALT_KEY),short(META_KEY),short(INTERNAL_ORDER),short(RIGHT_MOUSE_KEY)})
		test({{CMD_GUARD,{42},option}},false);
	test({repair,guard},true); // engine assist does not necessarily set INTERNAL
	test({{CMD_REPAIR,{55},INTERNAL_ORDER},guard},true);
	test({{CMD_REPAIR,{10,0,20,300}},guard},false);
	test({{CMD_REPAIR,{55},CONTROL_KEY},guard},false);
	test({{CMD_MOVE,{10,0,20},RIGHT_MOUSE_KEY,500},guard},true);
	test({{CMD_MOVE,{10,0,20},INTERNAL_ORDER},repair,guard},true);
	test({{CMD_MOVE,{10,0,20}},guard},false);
	test({{CMD_MOVE,{10,0,20},RIGHT_MOUSE_KEY},guard},false);
	test({{CMD_MOVE,{10,0},INTERNAL_ORDER},guard},false);
	test({{CMD_MOVE,{10,0,20,30},INTERNAL_ORDER},guard},false);
	test({{CMD_WAIT,{}},guard},false);
	test({{CMD_ATTACK,{99}},guard},false);
	test({{CMD_GUARD,{43}},guard},false);
	test({guard},false,43);
	test({{CMD_GUARD,{},0}},false);
	test({{CMD_GUARD,{42,0,0,0,99}}},false); // oversized copied params
	test({{CMD_GUARD,{std::numeric_limits<float>::quiet_NaN()}}},false);
	test({{CMD_MOVE,{0,0,std::numeric_limits<float>::infinity()},INTERNAL_ORDER},guard},false);
	test({{CMD_GUARD,{42},0,99}},false);
	test({{CMD_GUARD,{42},0,100}},true);
	test({{CMD_MOVE,{10,0,20},RIGHT_MOUSE_KEY,99},guard},false);
	test({{CMD_STOP,{}},guard},false);
	queue={guard};reads=0;
	for (int i=0;i<100000;++i) assert(api.HasGuardIntent(12,42,100));
	assert(reads==500000); // five allocation-free callbacks, no full wrapper list
	std::cout << "guard_callback_test: " << checks << " checks + 100000 live reads PASS\n";
}
