#include <angelscript.h>
#include "scriptarray.h"
#include "scriptstdstring.h"
#include "scriptdictionary.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

namespace {
int failures = 0;
void Check(asIScriptGeneric* call) {
    const bool condition = call->GetArgByte(0) != 0;
    if (!condition) { ++failures; asGetActiveContext()->SetException("assertion failed"); }
}
void Message(const asSMessageInfo* msg, void*) {
    std::cerr << msg->section << ':' << msg->row << ' ' << msg->message << '\n';
}
std::string Read(const char* path) {
    std::ifstream file(path);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
}
int main(int argc, char** argv) {
    if (argc != 3 && argc != 4) return 2;
    const bool benchmark = argc == 4 && std::string(argv[3]) == "--benchmark";
    asIScriptEngine* engine = asCreateScriptEngine();
    engine->SetMessageCallback(asFUNCTION(Message), nullptr, asCALL_CDECL);
    RegisterScriptArray(engine, true);
    // Some differential fixtures deliberately supply a tiny dictionary stub.
    // Opt into the real add-on only for tests of its runtime semantics.
    if (argc == 4 && (std::string(argv[3]) == "--dictionary" || std::string(argv[3]) == "--strings")) {
        RegisterStdString(engine);
        RegisterStdStringUtils(engine);
        RegisterScriptDictionary(engine);
    }
    engine->RegisterGlobalFunction("void Check(bool)", asFUNCTION(Check), asCALL_GENERIC);
    asIScriptModule* mod = engine->GetModule("tests", asGM_ALWAYS_CREATE);
    const auto policy = Read(argv[1]);
    const auto tests = Read(argv[2]);
    mod->AddScriptSection("production_math.as", policy.c_str(), policy.size());
    mod->AddScriptSection("production_math_tests.as", tests.c_str(), tests.size());
    if (mod->Build() < 0) { engine->ShutDownAndRelease(); return 1; }
    int executed = 0;
    for (asUINT i = 0; i < mod->GetFunctionCount(); ++i) {
        asIScriptFunction* fn = mod->GetFunctionByIndex(i);
        if (std::string(fn->GetName()).rfind(benchmark ? "bench_" : "test_", 0) != 0) continue;
        unsigned beforeCurrent = 0, beforeDestroyed = 0;
        if (benchmark) {
            engine->GarbageCollect(asGC_FULL_CYCLE);
            engine->GetGCStatistics(&beforeCurrent, &beforeDestroyed);
        }
        asIScriptContext* ctx = engine->CreateContext();
        ctx->Prepare(fn);
        const auto start = std::chrono::steady_clock::now();
        if (ctx->Execute() != asEXECUTION_FINISHED) {
            std::cerr << fn->GetName() << ": " << ctx->GetExceptionString() << '\n';
            if (failures == 0) ++failures;
        }
        ctx->Release(); ++executed;
        // Long differential fixtures allocate script-class graphs. Reclaim
        // unreachable graphs between test cases, as the game does between
        // callbacks; do not include this cleanup in measured benchmark cases.
        if (!benchmark) engine->GarbageCollect(asGC_FULL_CYCLE);
        if (benchmark) {
            const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
            unsigned current = 0, destroyed = 0;
            engine->GetGCStatistics(&current, &destroyed);
            const long long created = static_cast<long long>(current) - beforeCurrent + (destroyed - beforeDestroyed);
            std::cout << fn->GetName() << ",ms=" << ms << ",gc_registered=" << created << ",gc_current=" << current << '\n';
        }
    }
    engine->ShutDownAndRelease();
    std::cout << executed << " production policy tests; " << failures << " failures\n";
    return failures == 0 && executed > 0 ? 0 : 1;
}
