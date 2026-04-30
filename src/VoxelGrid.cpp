#include "VoxelGrid.h"

#include <algorithm>

namespace macvoxel {

uint8_t VoxelGrid::Get(int32_t x, int32_t y, int32_t z) const {
    const ChunkCoord cc = ToChunkCoord(x, y, z);
    auto it = chunks_.find(cc);
    if (it == chunks_.end()) return 0;
    return it->second->cells[LocalIndex(x, y, z)];
}

void VoxelGrid::Set(int32_t x, int32_t y, int32_t z, uint8_t value) {
    const ChunkCoord cc = ToChunkCoord(x, y, z);
    const size_t li = LocalIndex(x, y, z);

    auto it = chunks_.find(cc);
    if (it == chunks_.end()) {
        if (value == 0) return;  // erase on empty chunk: no-op
        auto chunk = std::make_unique<Chunk>();
        chunk->coord = cc;
        Chunk* raw = chunk.get();
        chunks_.emplace(cc, std::move(chunk));
        it = chunks_.find(cc);
        (void)raw;
    }
    Chunk* chunk = it->second.get();
    const uint8_t prev = chunk->cells[li];
    if (prev == value) return;
    chunk->cells[li] = value;

    if (prev == 0 && value != 0) {
        ++chunk->filled_count;
        ++total_filled_;
        if (bounds_.empty()) {
            bounds_.min_x = bounds_.max_x = x;
            bounds_.min_y = bounds_.max_y = y;
            bounds_.min_z = bounds_.max_z = z;
        } else {
            bounds_.min_x = std::min(bounds_.min_x, x);
            bounds_.min_y = std::min(bounds_.min_y, y);
            bounds_.min_z = std::min(bounds_.min_z, z);
            bounds_.max_x = std::max(bounds_.max_x, x);
            bounds_.max_y = std::max(bounds_.max_y, y);
            bounds_.max_z = std::max(bounds_.max_z, z);
        }
    } else if (prev != 0 && value == 0) {
        --chunk->filled_count;
        --total_filled_;
        if (chunk->filled_count == 0) {
            chunks_.erase(it);
        }
        // bounds_ left as a loose over-estimate; safe for renderer framing.
    }
}

void VoxelGrid::Clear() {
    chunks_.clear();
    total_filled_ = 0;
    bounds_ = Bounds3{};
}

}  // namespace macvoxel
