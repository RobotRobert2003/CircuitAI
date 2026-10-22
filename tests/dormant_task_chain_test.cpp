#include "task/DormantTaskChain.h"
#include "script/RefCounter.h"
#include <cassert>
#include <cstdio>

struct Task : circuit::IRefCounter<Task> {
    static inline int live = 0;
    Task* next = nullptr;
    bool dead = false;
    Task() { ++live; }
    ~Task() override { circuit::ReleaseDormantTaskChain(next); --live; }
    Task* GetNextTask() const { return next; }
    void SetNextTask(Task* value) { next = value; }
    void Dead() { dead = true; }
    void ClearRelease() { Release(); }
};

int main()
{
    // A script snapshot must survive cancellation/destruction of its parent.
    auto* parent = new Task;
    auto* child = new Task;
    auto* tail = new Task;
    parent->next = child;
    child->next = tail;
    child->AddRef();
    tail->AddRef();
    parent->Release();
    assert(Task::live == 2 && child->dead && tail->dead);
    assert(child->next == nullptr && tail->next == nullptr);
    assert(child->GetRefCount() == 1 && tail->GetRefCount() == 1);
    child->Release();
    tail->Release();
    assert(Task::live == 0);

    // Normal activation transfers the initial reference to the manager and
    // detaches the link. Destroying the old head must not kill the active task.
    parent = new Task;
    child = new Task;
    parent->next = child;
    Task* manager = parent->next;
    parent->next = nullptr;
    parent->Release();
    assert(Task::live == 1 && !manager->dead);
    manager->Release();
    assert(Task::live == 0);

    // Already-cancelled links and long chains have one ownership release each.
    Task* head = nullptr;
    for (int index = 0; index < 100000; ++index) {
        auto* link = new Task;
        link->next = head;
        link->dead = index % 2 == 0;
        head = link;
    }
    circuit::ReleaseDormantTaskChain(head);
    circuit::ReleaseDormantTaskChain(head);
    assert(head == nullptr && Task::live == 0);
    std::puts("dormant chain: retained handles, activation, cancellation and 100000-link release passed");
}
