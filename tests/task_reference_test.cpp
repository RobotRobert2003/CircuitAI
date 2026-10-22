#include "script/RefCounter.h"
#include <cassert>

struct Task : circuit::IRefCounter<Task> {
    static inline int destroyed = 0;
    virtual int Kind() const { return 1; }
    ~Task() override { ++destroyed; }
};
struct BuilderTask : Task { int Kind() const override { return 2; } };

int main()
{
    Task* unitTask = nullptr;
    Task* managerTask = new BuilderTask;
    circuit::AssignOwnedReference(unitTask, managerTask);
    assert(managerTask->GetRefCount() == 2);
    managerTask->Release(); // manager dequeues while a unit/script still reads it
    assert(Task::destroyed == 0);
    circuit::AssignOwnedReference(unitTask, unitTask);
    assert(unitTask->GetRefCount() == 1);
    assert(dynamic_cast<BuilderTask*>(unitTask) != nullptr);
    Task* scriptTask = nullptr;
    circuit::AssignOwnedReference(scriptTask, unitTask);
    circuit::AssignOwnedReference(unitTask, static_cast<Task*>(nullptr));
    assert(scriptTask->Kind() == 2 && Task::destroyed == 0);
    circuit::AssignOwnedReference(scriptTask, static_cast<Task*>(nullptr));
    assert(Task::destroyed == 1);
    circuit::AssignOwnedReference(unitTask, static_cast<Task*>(nullptr));
    Task* replacement = new Task;
    circuit::AssignOwnedReference(unitTask, replacement);
    replacement->Release();
    assert(dynamic_cast<BuilderTask*>(unitTask) == nullptr);
    circuit::AssignOwnedReference(unitTask, static_cast<Task*>(nullptr));
    assert(Task::destroyed == 2);
}
