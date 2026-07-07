#pragma once

#include "VoxelGrid.h"

#include <cstdint>

namespace macvoxel {

// Half-extent of the world coordinate space: 2048³, covering
// MagicaVoxel's 2000³ workspace while staying 16-chunk-aligned (the
// CenteredOn clamp must never break the lattice snap). Object
// transforms and the movable edit volume are clamped inside
// [-kWorldHalf, kWorldHalf).
inline constexpr int32_t kWorldHalf = 1024;

// Canonical bounded edit region the user paints into. Lives on Document.
// Always 256³ to match MagicaVoxel's max object size and keep .vox
// round-tripping inside the format's limits, but movable: the box
// re-centers on the active object when objects live elsewhere in the
// world. Default anchor has x and y straddling the camera target while
// z sits flat on the floor:
//
//   x ∈ [-128, 127]
//   y ∈ [-128, 127]
//   z ∈ [0, 255]      (the floor grid lives at z=0)
//
// Edits that would create a non-empty cell outside the volume are
// silently dropped at the cell level (brush / shape / face / generator
// kernels, FloatingBuffer commit, paste). Deletes are unrestricted so any cells
// that exist outside the volume — e.g. opened from a .vox with an
// unusual scene-graph translation — can still be cleaned up by the user.
struct EditVolume {
    int32_t x0 = -128, x1 = 127;
    int32_t y0 = -128, y1 = 127;
    int32_t z0 = 0,    z1 = 255;

    constexpr bool Contains(int32_t x, int32_t y, int32_t z) const noexcept {
        return x >= x0 && x <= x1 &&
               y >= y0 && y <= y1 &&
               z >= z0 && z <= z1;
    }

    constexpr int32_t size_x() const noexcept { return x1 - x0 + 1; }
    constexpr int32_t size_y() const noexcept { return y1 - y0 + 1; }
    constexpr int32_t size_z() const noexcept { return z1 - z0 + 1; }

    // Same-size translation to a new origin.
    void MoveTo(int32_t nx0, int32_t ny0, int32_t nz0) noexcept {
        x1 = nx0 + size_x() - 1;
        y1 = ny0 + size_y() - 1;
        z1 = nz0 + size_z() - 1;
        x0 = nx0;
        y0 = ny0;
        z0 = nz0;
    }

    // Default-size volume centered on a world AABB. The origin snaps
    // down to the 16-cell chunk lattice — this keeps the volume's
    // chunks and the world buffer's chunks on ONE lattice, which is
    // what lets the rasterizer keep a single chunk-skip loop — and is
    // clamped so the box stays inside the world.
    static EditVolume CenteredOn(const Bounds3& b) noexcept {
        EditVolume v{};
        if (b.empty()) return v;
        auto center = [](int32_t lo, int32_t hi, int32_t size) {
            int32_t o = lo + (hi - lo + 1 - size) / 2;
            o &= ~15;                                      // 16-lattice snap
            o = o < -kWorldHalf ? -kWorldHalf : o;
            o = o + size > kWorldHalf ? kWorldHalf - size : o;
            return o;
        };
        v.MoveTo(center(b.min_x, b.max_x, v.size_x()),
                 center(b.min_y, b.max_y, v.size_y()),
                 center(b.min_z, b.max_z, v.size_z()));
        return v;
    }
};

}  // namespace macvoxel
