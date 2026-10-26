#pragma once
// Engine-free adapter for testing the production queue's container semantics.
#include <mutex>
#include <condition_variable>
namespace spring {
using mutex = std::mutex;
using condition_variable_any = std::condition_variable_any;
}
