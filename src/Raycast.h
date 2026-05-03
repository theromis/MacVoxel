#pragma once

#include <cstdint>
#include <simd/simd.h>
#include <unordered_set>

namespace macvoxel {

class VoxelGrid;

struct RayHit {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
    uint8_t color = 0;
    // Face hit: axis is 0/1/2 (X/Y/Z), sign is +1 or -1. The face normal in
    // grid space is `unit_axis(axis) * sign`. axis = -1 means the ray
    // started inside a filled cell — no face was crossed.
    int axis = -1;
    int sign = 0;
    float t = 0.0f;
};

// Pack (x, y, z) into a 64-bit key for the skip set. 21 bits per axis is
// plenty — voxel coordinates fit comfortably in int21.
inline int64_t PackCellKey(int32_t x, int32_t y, int32_t z) {
    constexpr uint64_t kMask = (1ull << 21) - 1ull;
    return static_cast<int64_t>(
        (static_cast<uint64_t>(x) & kMask) |
        ((static_cast<uint64_t>(y) & kMask) << 21) |
        ((static_cast<uint64_t>(z) & kMask) << 42));
}

// Walks the grid via 3D DDA (Amanatides & Woo, 1987) and returns the first
// filled cell the ray enters. Origin and direction are in grid space; t_max
// caps how far we'll march. Returns false if no filled cell is reached.
bool Raycast(const VoxelGrid& grid,
             simd::float3 origin,
             simd::float3 direction,
             float t_max,
             RayHit* out_hit);

// Same DDA, but cells whose packed key is in `ignore` are treated as empty.
// Lets drag-add ignore voxels placed during the current stroke so the
// raycast keeps targeting the original surface.
bool RaycastIgnoring(const VoxelGrid& grid,
                     simd::float3 origin,
                     simd::float3 direction,
                     float t_max,
                     const std::unordered_set<int64_t>& ignore,
                     RayHit* out_hit);

}  // namespace macvoxel
