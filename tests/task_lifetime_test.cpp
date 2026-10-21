#include "util/LifetimeRegistry.h"
#include "script/RefCounter.h"

#include <cassert>
#include <new>

struct Task : circuit::IRefCounter<Task> {
    static inline circuit::LifetimeRegistry<Task> live;
    static inline int destroyed = 0;
    Task() { live.Insert(this); }
    ~Task() override { live.Erase(this); ++destroyed; }
    static std::uint64_t Lookup(const Task* task) { return live.Find(task); }
};

int main()
{
    Task* pointer = nullptr;
    std::uint64_t generation = 0;
    const auto replace = [&](Task* task) {
        return circuit::ReplaceLiveReference(pointer, generation, task, Task::Lookup);
    };
    const auto get = [&]() { return circuit::LiveReference(pointer, generation, Task::Lookup); };
    assert(get() == nullptr);
    Task* invalid = reinterpret_cast<Task*>(std::uintptr_t{0x1234});
    assert(!replace(invalid)); // no access through an arbitrary address
    assert(get() == nullptr);

    auto* original = new Task;
    assert(replace(original));
    original->Release(); // unit now holds the final reference
    assert(replace(pointer)); // retain before release on self-assignment
    assert(pointer->GetRefCount() == 1);
    {
        auto callback = circuit::RetainReference(get());
        assert(replace(nullptr)); // callback reassigns/drops the unit's task
        assert(Task::destroyed == 0);
        assert(callback->GetRefCount() == 1);
    }
    assert(Task::destroyed == 1); // callback's final instruction is safe

    // Simulate an external deletion that bypassed intrusive ownership. The
    // stale unit field must neither be dispatched nor released during repair.
    original = new Task;
    assert(replace(original));
    original->Release();
    delete original;
    assert(get() == nullptr);
    assert(replace(nullptr));
    assert(Task::destroyed == 2);

    // Reuse the EXACT address: a membership-only live set is insufficient.
    alignas(Task) unsigned char storage[sizeof(Task)];
    original = new (storage) Task;
    assert(replace(original));
    original->Release();
    const auto previousGeneration = generation;
    original->~Task();
    auto* replacement = new (storage) Task;
    assert(Task::Lookup(replacement) != previousGeneration);
    assert(get() == nullptr);
    assert(replace(nullptr)); // must not Release the replacement
    assert(replacement->GetRefCount() == 1);
    replacement->~Task();
    assert(Task::destroyed == 4);

    // A rejected new pointer leaves a valid reclaim assignment untouched.
    auto* reclaim = new Task;
    assert(replace(reclaim));
    reclaim->Release();
    assert(!replace(invalid));
    assert(get() == reclaim && reclaim->GetRefCount() == 1);
    assert(replace(nullptr));
    assert(Task::destroyed == 5);
}
