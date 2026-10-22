#include "script/RefCounter.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

namespace {
struct Task : circuit::IRefCounter<Task> {
    static inline int live = 0;
    Task() { ++live; }
    ~Task() override { --live; }
};
struct BuilderTask final : Task {};
Task* unitTask = nullptr;
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
void Replace(asIScriptGeneric* call) {
    Task* managerTask = call->GetArgByte(0) ? static_cast<Task*>(new BuilderTask) : new Task;
    circuit::AssignOwnedReference(unitTask, managerTask);
    managerTask->Release(); // Manager ownership ends before script casts/retains it.
}
void Clear(asIScriptGeneric*) { circuit::AssignOwnedReference(unitTask, static_cast<Task*>(nullptr)); }
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
    auto* module = engine->GetModule("lifetime", asGM_ALWAYS_CREATE);
    const char* script = R"(
        void Test() {
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
