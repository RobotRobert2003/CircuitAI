#include "util/MultiQueue.h"
#include <cassert>
#include <vector>

int main()
{
    circuit::CMultiQueue<int> queue;
    queue.RemoveAllIf([](int&) { assert(false); return false; });
    queue.PushBack(1);
    queue.RemoveAllIf([](int&) { return true; });
    assert(queue.IsEmpty());
    for (int value : {1, 2, 3, 4, 5}) queue.PushBack(value);
    std::vector<int> visited;
    queue.RemoveAllIf([&](int& value) {
        visited.push_back(value);
        return value % 2 != 0;
    });
    assert((visited == std::vector<int>{1, 5, 4, 2, 3}));
    assert(queue.Size() == 2);
    assert(queue.Pop() == 4);
    assert(queue.Pop() == 2);
    assert(queue.IsEmpty());
}
