#pragma once

#include <chrono>
#include <cstdlib>

// Header-only timing helper for ad-hoc perf instrumentation. Gated on
// the env var `MACVOXEL_PERF`: set non-zero to enable, leave unset for
// production runs. The check is evaluated once via a function-local
// static so the cost in a hot path is one predictable branch.
namespace macvoxel::perf {

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

inline TimePoint Now() { return Clock::now(); }

inline double Micros(Clock::duration d) {
    return std::chrono::duration<double, std::micro>(d).count();
}

inline bool Enabled() {
    static const bool e = [] {
        const char* v = std::getenv("MACVOXEL_PERF");
        return v != nullptr && v[0] != 0 && v[0] != '0';
    }();
    return e;
}

}  // namespace macvoxel::perf
