#pragma once

#include "Palette.h"
#include "VoxelGrid.h"

#include <cstdint>
#include <string>

namespace macvoxel {

// The single open document. Phase 2 is single-document; we'll grow into
// multi-document if/when there's a real reason.
//
// `version` is bumped any time the grid or palette is replaced. Renderers
// and other observers cache their state against this counter and rebuild
// when it changes.
struct Document {
    VoxelGrid grid;
    Palette palette;
    std::string path;  // empty => Untitled, never saved
    uint64_t version = 0;
};

}  // namespace macvoxel
