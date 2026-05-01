#pragma once

#include "VoxelGrid.h"

namespace macvoxel {

// One axis-aligned voxel-space selection. Empty (active = false) means
// nothing is selected; selection-aware operations fall back to global
// behavior in that case.
struct Selection {
    Bounds3 box{};
    bool active = false;

    void Clear() {
        box = Bounds3{};
        active = false;
    }
};

Selection& CurrentSelection();

}  // namespace macvoxel
