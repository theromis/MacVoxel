#pragma once

#include "Palette.h"
#include "VoxelGrid.h"

#include <string>

namespace macvoxel {

// The single open document. Phase 2 is single-document; we'll grow into
// multi-document if/when there's a real reason.
struct Document {
    VoxelGrid grid;
    Palette palette;
    std::string path;  // empty => Untitled, never saved
};

}  // namespace macvoxel
