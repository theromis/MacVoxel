#pragma once

#include <cstdint>
#include <simd/simd.h>

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

// Walks the grid via 3D DDA (Amanatides & Woo, 1987) and returns the first
// filled cell the ray enters. Origin and direction are in grid space; t_max
// caps how far we'll march. Returns false if no filled cell is reached.
bool Raycast(const VoxelGrid& grid,
             simd::float3 origin,
             simd::float3 direction,
             float t_max,
             RayHit* out_hit);

}  // namespace macvoxel
