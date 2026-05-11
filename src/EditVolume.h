#pragma once

#include <cstdint>

namespace macvoxel {

// Canonical bounded edit region the user paints into. Lives on Document.
// Fixed 256³ for now to match MagicaVoxel's max object size and keep .vox
// round-tripping inside the format's limits. Anchored so x and y straddle
// the camera target while z sits flat on the floor:
//
//   x ∈ [-128, 127]
//   y ∈ [-128, 127]
//   z ∈ [0, 255]      (the floor grid lives at z=0)
//
// Edits that would create a non-empty cell outside the volume are
// silently dropped at the cell level (BrushOps, PreviewOps commit,
// FloatingBuffer commit, paste). Deletes are unrestricted so any cells
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
};

}  // namespace macvoxel
