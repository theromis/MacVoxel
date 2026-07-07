#include "ChunkPool.h"

#include <algorithm>
#include <cstring>

namespace macvoxel {

PackedChunks PackGridChunks(const VoxelGrid& grid, ChunkOverrides overrides) {
    using VG = VoxelGrid;
    PackedChunks out;
    const auto& chunks = grid.chunks();
    if (chunks.empty() && overrides.empty()) return out;

    int32_t min_cx = INT32_MAX, min_cy = INT32_MAX, min_cz = INT32_MAX;
    int32_t max_cx = INT32_MIN, max_cy = INT32_MIN, max_cz = INT32_MIN;
    const auto extend = [&](const VG::ChunkCoord& c) {
        min_cx = std::min(min_cx, c.x); max_cx = std::max(max_cx, c.x);
        min_cy = std::min(min_cy, c.y); max_cy = std::max(max_cy, c.y);
        min_cz = std::min(min_cz, c.z); max_cz = std::max(max_cz, c.z);
    };
    for (const auto& [coord, chunk] : chunks) extend(coord);
    for (const auto& [coord, cells] : overrides) extend(coord);

    out.min[0] = min_cx; out.min[1] = min_cy; out.min[2] = min_cz;
    out.dim[0] = max_cx - min_cx + 1;
    out.dim[1] = max_cy - min_cy + 1;
    out.dim[2] = max_cz - min_cz + 1;

    const size_t coarse_count = static_cast<size_t>(out.dim[0]) *
                                static_cast<size_t>(out.dim[1]) *
                                static_cast<size_t>(out.dim[2]);
    out.coarse.assign(coarse_count, 0);
    out.pool.reserve((chunks.size() + overrides.size()) * VG::kChunkVolume);
    uint32_t pool_idx = 1;
    const auto coarse_index = [&](const VG::ChunkCoord& coord) {
        return static_cast<size_t>(coord.x - min_cx) +
               static_cast<size_t>(coord.y - min_cy) *
                   static_cast<size_t>(out.dim[0]) +
               static_cast<size_t>(coord.z - min_cz) *
                   static_cast<size_t>(out.dim[0]) *
                   static_cast<size_t>(out.dim[1]);
    };
    // Overrides land on top of the grid payload (the lift composites
    // over the doc), so apply them after the chunk memcpy.
    const auto apply_overrides = [&](const VG::ChunkCoord& coord,
                                     size_t pool_offset) {
        auto it = overrides.find(coord);
        if (it == overrides.end()) return;
        for (const auto& [local, val] : it->second) {
            out.pool[pool_offset + local] = val;
        }
        overrides.erase(it);
    };
    for (const auto& [coord, chunk] : chunks) {
        out.coarse[coarse_index(coord)] = pool_idx++;
        const size_t old = out.pool.size();
        out.pool.resize(old + VG::kChunkVolume);
        std::memcpy(out.pool.data() + old, chunk->cells, VG::kChunkVolume);
        apply_overrides(coord, old);
    }
    // Overrides over otherwise-empty chunks: allocate a zeroed chunk each.
    for (const auto& [coord, cells] : overrides) {
        out.coarse[coarse_index(coord)] = pool_idx++;
        const size_t old = out.pool.size();
        out.pool.resize(old + VG::kChunkVolume, 0);
        for (const auto& [local, val] : cells) {
            out.pool[old + local] = val;
        }
    }
    return out;
}

}  // namespace macvoxel
