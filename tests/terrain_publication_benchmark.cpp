// Component cost of D-286's new shared ten-second publication comparison.
// Supreme: 1536 * 1536 fine height samples. This is not an FPS benchmark.
#include "circuit/terrain/TerrainPublication.h"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <new>

static std::size_t allocations = 0;
void* operator new(std::size_t size) {
    ++allocations;
    if (void* memory = std::malloc(size ? size : 1)) return memory;
    throw std::bad_alloc();
}
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }

int main() {
    std::vector<float> before(1536 * 1536, 10.f), after = before;
    std::vector<double> samples;
    samples.reserve(128);
    const auto initial = allocations;
    std::uint64_t revision = 1;
    for (int iteration = 0; iteration < 128; ++iteration) {
        // Observable index prevents hoisting equality out of the timed loop.
        volatile std::size_t index = (iteration * 7919u) % after.size();
        after[index] = before[index];
        const auto start = std::chrono::steady_clock::now();
        revision = circuit::lane::HeightRevision(revision, before, after);
        samples.push_back(std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start).count());
    }
    const auto added = allocations - initial;
    std::sort(samples.begin(), samples.end());
    std::cout << "height publication: samples=128 cells=" << before.size()
        << " median_ms=" << samples[64] << " p95_ms=" << samples[121]
        << " max_ms=" << samples.back() << " allocations=" << added << '\n';
    return revision == 1 && added == 0 ? 0 : 1;
}
