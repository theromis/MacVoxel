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
        chunks_.emplace(cc, std::move(chunk));
        it = chunks_.find(cc);
    }
    Chunk* chunk = it->second.get();
    const uint8_t prev = chunk->cells[li];
    if (prev == value) return;
    chunk->cells[li] = value;
    ++chunk->version;
    dirty_chunks_.insert(cc);

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
            chunk = nullptr;  // freed; do not touch below
        }
        // bounds_ left as a loose over-estimate; safe for renderer framing.
    }

    // If the modified cell sat on a chunk boundary, the adjacent chunk's
    // visible faces may have changed too — bump its version so the renderer
    // remeshes it. Skip if the neighbor doesn't exist (no mesh to update).
    const uint32_t lx = static_cast<uint32_t>(x) & kChunkMask;
    const uint32_t ly = static_cast<uint32_t>(y) & kChunkMask;
    const uint32_t lz = static_cast<uint32_t>(z) & kChunkMask;
    auto bump_neighbor = [&](int32_t dx, int32_t dy, int32_t dz) {
        ChunkCoord nc{cc.x + dx, cc.y + dy, cc.z + dz};
        auto nit = chunks_.find(nc);
        if (nit != chunks_.end()) {
            ++nit->second->version;
            dirty_chunks_.insert(nc);
        }
    };
    if (lx == 0)              bump_neighbor(-1, 0, 0);
    if (lx == kChunkSize - 1) bump_neighbor(+1, 0, 0);
    if (ly == 0)              bump_neighbor(0, -1, 0);
    if (ly == kChunkSize - 1) bump_neighbor(0, +1, 0);
    if (lz == 0)              bump_neighbor(0, 0, -1);
    if (lz == kChunkSize - 1) bump_neighbor(0, 0, +1);
}

void VoxelGrid::Clear() {
    chunks_.clear();
    dirty_chunks_.clear();
    total_filled_ = 0;
    bounds_ = Bounds3{};
}

}  // namespace macvoxel
