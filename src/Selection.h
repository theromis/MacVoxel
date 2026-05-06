#pragma once

#include "VoxelGrid.h"

#include <array>
#include <cstdint>
#include <vector>

namespace macvoxel {

// One axis-aligned voxel-space selection. Empty (active = false) means
// nothing is selected; selection-aware operations fall back to global
// behavior in that case.
//
// `voxels` is an optional sparse list of cell coordinates produced by
// non-rectangular sources (e.g. Palette → "Select voxels by color").
// When non-empty, palette-driven paint actions iterate it directly;
// the AABB-based copy/cut/delete in AppDelegate still work on `box`
// and ignore the list — they predate sparse selection and we'll
// reconcile them in a later selection-upgrades phase.
struct Selection {
    Bounds3 box{};
    bool active = false;
    std::vector<std::array<int32_t, 3>> voxels;

    void Clear() {
        box = Bounds3{};
        active = false;
        voxels.clear();
    }
};

Selection& CurrentSelection();

}  // namespace macvoxel
