#ifndef CIRCUIT_SPRING_CALLBACK_BUFFER_H
#define CIRCUIT_SPRING_CALLBACK_BUFFER_H

#include <algorithm>
#include <span>
#include <vector>

namespace circuit {
// Owner-thread callback scratch. Allocate/initialize the maximum once; expose
// only the populated prefix. Shrinking the engine write buffer after each
// query forces O(maximum) value initialization on the next query. Read costs
// the producer's work; consuming/copying the returned span costs O(results).
// The view expires at the next Read or destruction. No cached observations,
// callbacks, pointers into engine memory, or cross-thread borrowing survive.
// tests/callback_buffer_test.cpp compares ordered results and retained storage.
class CallbackBuffer {
public:
    template<class Producer> std::span<const int> Read(int maximum, Producer&& producer) {
        if (int(storage.size())!=maximum) storage.resize(std::max(0,maximum));
        const int count=std::clamp(producer(storage.data(),int(storage.size())),0,int(storage.size()));
        return {storage.data(),size_t(count)};
    }
private:
    std::vector<int> storage;
};
}
#endif
