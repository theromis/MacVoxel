#pragma once

#include "VoxelGrid.h"

#include <cstdint>
#include <unordered_map>
#include <utility>
#include <vector>

namespace macvoxel {

// CPU-side coarse+pool packing of a sparse grid: `coarse` is a dense
// chunk-index volume over the tight chunk bounds (0 = empty chunk,
// otherwise 1-based slot), `pool` holds 4096-byte chunk payloads with
// slot i at offset (i-1)*4096. Both the path tracer and the rasterizer's
// world-composite buffer consume this layout.
struct PackedChunks {
    std::vector<uint32_t> coarse;
    std::vector<uint8_t> pool;
    int32_t min[3] = {0, 0, 0};  // chunk coords
    int32_t dim[3] = {0, 0, 0};
    bool empty() const { return pool.empty(); }
};

// World-cell overrides splatted on top of the grid's chunks (the path
// tracer's floating-lift composite): chunk coord → (local index, value)
// pairs. Overridden chunks that don't exist in the grid are allocated.
using ChunkOverrides =
    std::unordered_map<VoxelGrid::ChunkCoord,
                       std::vector<std::pair<uint32_t, uint8_t>>,
                       VoxelGrid::ChunkCoordHash>;

PackedChunks PackGridChunks(const VoxelGrid& grid,
                            ChunkOverrides overrides = {});

}  // namespace macvoxel
