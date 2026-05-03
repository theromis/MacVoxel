#include "Raycast.h"

#include "VoxelGrid.h"

#include <cmath>
#include <limits>

namespace macvoxel {
namespace {

bool RaycastImpl(const VoxelGrid& grid,
                 simd::float3 origin,
                 simd::float3 direction,
                 float t_max,
                 const std::unordered_set<int64_t>* ignore,
                 RayHit* out_hit) {
    constexpr float kInf = std::numeric_limits<float>::infinity();

    // Starting cell: floor of origin in each axis.
    int32_t x = static_cast<int32_t>(std::floor(origin.x));
    int32_t y = static_cast<int32_t>(std::floor(origin.y));
    int32_t z = static_cast<int32_t>(std::floor(origin.z));

    auto sign_of = [](float d) {
        return d > 0.0f ? 1 : (d < 0.0f ? -1 : 0);
    };
    const int sx = sign_of(direction.x);
    const int sy = sign_of(direction.y);
    const int sz = sign_of(direction.z);

    // Distance along the ray to the next cell boundary along each axis.
    auto tmax_init = [](int s, int cell, float origin_c, float dir_c) {
        if (s == 0) return kInf;
        const float boundary = static_cast<float>(s > 0 ? cell + 1 : cell);
        return (boundary - origin_c) / dir_c;
    };
    float tMaxX = tmax_init(sx, x, origin.x, direction.x);
    float tMaxY = tmax_init(sy, y, origin.y, direction.y);
    float tMaxZ = tmax_init(sz, z, origin.z, direction.z);

    // Distance along the ray per cell traversed along each axis.
    const float tDeltaX = (sx != 0) ? 1.0f / std::abs(direction.x) : kInf;
    const float tDeltaY = (sy != 0) ? 1.0f / std::abs(direction.y) : kInf;
    const float tDeltaZ = (sz != 0) ? 1.0f / std::abs(direction.z) : kInf;

    auto is_ignored = [&](int32_t cx, int32_t cy, int32_t cz) {
        return ignore != nullptr && ignore->contains(PackCellKey(cx, cy, cz));
    };

    // Starting cell: if it's already filled, the ray began inside a voxel.
    // Return that hit with no face — callers can decide what to do.
    if (uint8_t v = grid.Get(x, y, z); v != 0 && !is_ignored(x, y, z)) {
        out_hit->x = x;
        out_hit->y = y;
        out_hit->z = z;
        out_hit->color = v;
        out_hit->axis = -1;
        out_hit->sign = 0;
        out_hit->t = 0.0f;
        return true;
    }

    float t = 0.0f;
    while (t < t_max) {
        int last_axis;
        if (tMaxX <= tMaxY && tMaxX <= tMaxZ) {
            x += sx;
            t = tMaxX;
            tMaxX += tDeltaX;
            last_axis = 0;
        } else if (tMaxY <= tMaxZ) {
            y += sy;
            t = tMaxY;
            tMaxY += tDeltaY;
            last_axis = 1;
        } else {
            z += sz;
            t = tMaxZ;
            tMaxZ += tDeltaZ;
            last_axis = 2;
        }
        if (t > t_max) return false;

        const uint8_t v = grid.Get(x, y, z);
        if (v != 0 && !is_ignored(x, y, z)) {
            out_hit->x = x;
            out_hit->y = y;
            out_hit->z = z;
            out_hit->color = v;
            out_hit->axis = last_axis;
            // Normal points back out the face we just entered — opposite of
            // the step we took.
            const int step = (last_axis == 0) ? sx
                            : (last_axis == 1) ? sy : sz;
            out_hit->sign = -step;
            out_hit->t = t;
            return true;
        }
    }
    return false;
}

}  // namespace

bool Raycast(const VoxelGrid& grid,
             simd::float3 origin,
             simd::float3 direction,
             float t_max,
             RayHit* out_hit) {
    return RaycastImpl(grid, origin, direction, t_max, nullptr, out_hit);
}

bool RaycastIgnoring(const VoxelGrid& grid,
                     simd::float3 origin,
                     simd::float3 direction,
                     float t_max,
                     const std::unordered_set<int64_t>& ignore,
                     RayHit* out_hit) {
    return RaycastImpl(grid, origin, direction, t_max, &ignore, out_hit);
}

}  // namespace macvoxel
