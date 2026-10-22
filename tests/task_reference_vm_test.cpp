#include "script/RefCounter.h"
#include "util/LifetimeRegistry.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

namespace {
struct Task : circuit::IRefCounter<Task> {
    static inline int live = 0;
    static inline circuit::LifetimeRegistry<Task> registry;
    Task() { ++live; registry.Insert(this); }
    ~Task() override { registry.Erase(this); --live; }
    static std::uint64_t Lookup(const Task* task) { return registry.Find(task); }
};
struct BuilderTask final : Task {};
Task* unitTask = nullptr;
std::uint64_t taskGeneration = 0;
struct Unit {} unit;
Unit* unitPointer = &unit;
void AddRef(asIScriptGeneric* call) { static_cast<Task*>(call->GetObject())->AddRef(); }
void Release(asIScriptGeneric* call) { static_cast<Task*>(call->GetObject())->Release(); }
void CastBuilder(asIScriptGeneric* call) {
    auto* result = dynamic_cast<BuilderTask*>(static_cast<Task*>(call->GetObject()));
    if (result) result->AddRef();
    call->SetReturnAddress(result);
}
void GetTask(asIScriptGeneric* call) {
    if (unitTask) unitTask->AddRef();
    call->SetReturnAddress(unitTask);
}
void GetLiveTask(asIScriptGeneric* call) {
    // Same borrowed auto-handle contract as CCircuitUnit.get_task.
    call->SetReturnAddress(circuit::LiveReference(unitTask, taskGeneration, Task::Lookup));
}
void Invalidate(asIScriptGeneric*) {
    delete unitTask; // simulate a legacy direct delete bypassing ownership
}
void Replace(asIScriptGeneric* call) {
    Task* managerTask = call->GetArgByte(0) ? static_cast<Task*>(new BuilderTask) : new Task;
    assert(circuit::ReplaceLiveReference(unitTask, taskGeneration, managerTask, Task::Lookup));
    managerTask->Release(); // Manager ownership ends before script casts/retains it.
}
void Clear(asIScriptGeneric*) { assert(circuit::ReplaceLiveReference(unitTask, taskGeneration, static_cast<Task*>(nullptr), Task::Lookup)); }
void Check(asIScriptGeneric* call) { assert(call->GetArgByte(0)); }
void Message(const asSMessageInfo* message, void*) { std::fprintf(stderr, "%s:%d %s\n", message->section, message->row, message->message); }
}

int main() {
    auto* engine = asCreateScriptEngine();
    assert(engine);
    engine->SetMessageCallback(asFUNCTION(Message), nullptr, asCALL_CDECL);
    for (const char* name : {"Task", "BuilderTask"}) {
        assert(engine->RegisterObjectType(name, 0, asOBJ_REF) >= 0);
        assert(engine->RegisterObjectBehaviour(name, asBEHAVE_ADDREF, "void f()", asFUNCTION(AddRef), asCALL_GENERIC) >= 0);
        assert(engine->RegisterObjectBehaviour(name, asBEHAVE_RELEASE, "void f()", asFUNCTION(Release), asCALL_GENERIC) >= 0);
    }
    assert(engine->RegisterObjectMethod("Task", "BuilderTask@ opCast()", asFUNCTION(CastBuilder), asCALL_GENERIC) >= 0);
    assert(engine->RegisterGlobalFunction("Task@ GetTask()", asFUNCTION(GetTask), asCALL_GENERIC) >= 0);
    assert(engine->RegisterGlobalFunction("void Replace(bool)", asFUNCTION(Replace), asCALL_GENERIC) >= 0);
    assert(engine->RegisterGlobalFunction("void Clear()", asFUNCTION(Clear), asCALL_GENERIC) >= 0);
    assert(engine->RegisterGlobalFunction("void Check(bool)", asFUNCTION(Check), asCALL_GENERIC) >= 0);
    assert(engine->RegisterObjectType("Unit", 0, asOBJ_REF | asOBJ_NOCOUNT) >= 0);
    assert(engine->RegisterGlobalProperty("Unit@ unit", &unitPointer) >= 0);
    assert(engine->RegisterObjectMethod("Unit", "Task@+ get_task() const property", asFUNCTION(GetLiveTask), asCALL_GENERIC) >= 0);
    assert(engine->RegisterGlobalFunction("void Invalidate()", asFUNCTION(Invalidate), asCALL_GENERIC) >= 0);
    auto* module = engine->GetModule("lifetime", asGM_ALWAYS_CREATE);
    const char* script = R"(
        void Test() {
            Check(unit.task is null);
            Replace(true);
            Task@ pinned = unit.task;
            Clear();
            Check(cast<BuilderTask>(pinned) !is null);
            @pinned = null;
            Replace(false);
            Invalidate();
            Check(unit.task is null); // getter must not AddRef the invalid field
            Clear(); // must not Release its stale pointer either
            Task@ empty;
            Check(cast<BuilderTask>(empty) is null);
            Replace(false);
            Task@ ordinary = GetTask();
            Check(cast<BuilderTask>(ordinary) is null);
            Replace(true);
            Task@ retained = GetTask();
            BuilderTask@ builder = cast<BuilderTask>(retained);
            Check(builder !is null);
            Clear(); // Unit dies/transfers while script handles survive.
            Check(cast<BuilderTask>(retained) !is null);
            Replace(false); // A different task must not invalidate retained handles.
            Check(cast<BuilderTask>(GetTask()) is null);
            Clear();
            @retained = null;
            Check(builder !is null);
            @builder = null;
            @ordinary = null;
        }
    )";
    assert(module->AddScriptSection("ownership", script) >= 0);
    assert(module->Build() >= 0);
    auto* context = engine->CreateContext();
    assert(context->Prepare(module->GetFunctionByDecl("void Test()")) >= 0);
    assert(context->Execute() == asEXECUTION_FINISHED);
    context->Release();
    engine->ShutDownAndRelease();
    assert(unitTask == nullptr && Task::live == 0);
    std::puts("task reference VM: null/wrong casts, retained handles, replacement and release passed");
}
