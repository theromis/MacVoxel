#pragma once

#include <cstdint>
#include <vector>

#include "VoxelGrid.h"

namespace macvoxel {

// One vertex of the greedy mesh. Coordinates are in .vox-native Z-up grid
// space; the renderer swaps Y/Z when computing world position. normal_idx
// indexes a 6-entry constant table (see VoxelRenderer's shader).
struct MeshVertex {
    int16_t x;
    int16_t y;
    int16_t z;
    uint8_t normal_idx;
    uint8_t palette_idx;
};
static_assert(sizeof(MeshVertex) == 8, "MeshVertex layout must match shader");

// Greedy-mesh a single 16^3 chunk. For each of the six face directions:
//   1. Build a 16x16 mask of exposed faces in each layer (a face is exposed
//      iff the cell is filled and the neighbor in the face's normal
//      direction is empty — neighbor lookups go through `grid.Get` so
//      cross-chunk boundaries are handled).
//   2. Greedily merge same-color rectangles in the mask, emitting one quad
//      per rectangle.
//
// Vertices are appended to *vertices, indices reference the global vertex
// buffer (caller may chain chunks into one big mesh by calling repeatedly).
// Quads are wound CCW from outside the surface.
void GreedyMeshChunk(const VoxelGrid& grid,
                     const VoxelGrid::ChunkCoord& chunk_coord,
                     const VoxelGrid::Chunk& chunk,
                     std::vector<MeshVertex>* vertices,
                     std::vector<uint32_t>* indices);

}  // namespace macvoxel
