#include "VoxelGrid.h"

#include <algorithm>
#include <cstring>

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

void VoxelGrid::ApplyChanges(const CellChange* changes, size_t count) {
    if (count == 0) return;

    // Bucket cell indices by destination chunk. Brush footprints cluster
    // across a handful of chunks (~30 for a 60-radius sphere), so the
    // map stays small while each bucket holds hundreds of cells.
    std::unordered_map<ChunkCoord, std::vector<uint32_t>, ChunkCoordHash>
        by_chunk;
    by_chunk.reserve(count / 256 + 4);
    for (size_t i = 0; i < count; ++i) {
        const auto& c = changes[i];
        if (c.old_val == c.new_val) continue;
        by_chunk[ToChunkCoord(c.x, c.y, c.z)].push_back(
            static_cast<uint32_t>(i));
    }

    for (auto& [cc, indices] : by_chunk) {
        auto it = chunks_.find(cc);
        if (it == chunks_.end()) {
            // No chunk yet. Materialize one only if any change actually
            // writes a non-empty value — pure erase-into-empty is a
            // no-op per Set's existing policy.
            bool any_create = false;
            for (uint32_t i : indices) {
                if (changes[i].new_val != 0) { any_create = true; break; }
            }
            if (!any_create) continue;
            auto chunk = std::make_unique<Chunk>();
            chunk->coord = cc;
            chunks_.emplace(cc, std::move(chunk));
            it = chunks_.find(cc);
        }
        Chunk* chunk = it->second.get();
        bool touched[6] = {false, false, false, false, false, false};
        bool any_modified = false;

        for (uint32_t i : indices) {
            const auto& c = changes[i];
            const size_t li = LocalIndex(c.x, c.y, c.z);
            const uint8_t prev = chunk->cells[li];
            if (prev == c.new_val) continue;
            chunk->cells[li] = c.new_val;
            any_modified = true;

            if (prev == 0 && c.new_val != 0) {
                ++chunk->filled_count;
                ++total_filled_;
                if (bounds_.empty()) {
                    bounds_.min_x = bounds_.max_x = c.x;
                    bounds_.min_y = bounds_.max_y = c.y;
                    bounds_.min_z = bounds_.max_z = c.z;
                } else {
                    bounds_.min_x = std::min(bounds_.min_x, c.x);
                    bounds_.min_y = std::min(bounds_.min_y, c.y);
                    bounds_.min_z = std::min(bounds_.min_z, c.z);
                    bounds_.max_x = std::max(bounds_.max_x, c.x);
                    bounds_.max_y = std::max(bounds_.max_y, c.y);
                    bounds_.max_z = std::max(bounds_.max_z, c.z);
                }
            } else if (prev != 0 && c.new_val == 0) {
                --chunk->filled_count;
                --total_filled_;
            }

            const uint32_t lx = static_cast<uint32_t>(c.x) & kChunkMask;
            const uint32_t ly = static_cast<uint32_t>(c.y) & kChunkMask;
            const uint32_t lz = static_cast<uint32_t>(c.z) & kChunkMask;
            if (lx == 0)              touched[0] = true;
            if (lx == kChunkSize - 1) touched[1] = true;
            if (ly == 0)              touched[2] = true;
            if (ly == kChunkSize - 1) touched[3] = true;
            if (lz == 0)              touched[4] = true;
            if (lz == kChunkSize - 1) touched[5] = true;
        }

        if (!any_modified) continue;

        ++chunk->version;
        dirty_chunks_.insert(cc);

        auto bump_neighbor = [&](int32_t dx, int32_t dy, int32_t dz) {
            ChunkCoord nc{cc.x + dx, cc.y + dy, cc.z + dz};
            auto nit = chunks_.find(nc);
            if (nit != chunks_.end()) {
                ++nit->second->version;
                dirty_chunks_.insert(nc);
            }
        };
        if (touched[0]) bump_neighbor(-1, 0, 0);
        if (touched[1]) bump_neighbor(+1, 0, 0);
        if (touched[2]) bump_neighbor(0, -1, 0);
        if (touched[3]) bump_neighbor(0, +1, 0);
        if (touched[4]) bump_neighbor(0, 0, -1);
        if (touched[5]) bump_neighbor(0, 0, +1);

        if (chunk->filled_count == 0) {
            chunks_.erase(it);
        }
    }
}

void VoxelGrid::Clear() {
    chunks_.clear();
    dirty_chunks_.clear();
    total_filled_ = 0;
    bounds_ = Bounds3{};
}

VoxelGrid VoxelGrid::Clone() const {
    VoxelGrid out;
    out.bounds_ = bounds_;
    out.total_filled_ = total_filled_;
    out.chunks_.reserve(chunks_.size());
    for (const auto& [coord, chunk] : chunks_) {
        auto copy = std::make_unique<Chunk>();
        copy->coord = chunk->coord;
        std::memcpy(copy->cells, chunk->cells, sizeof(copy->cells));
        copy->filled_count = chunk->filled_count;
        copy->version = chunk->version;
        out.chunks_.emplace(coord, std::move(copy));
    }
    // Don't copy the dirty queue — clones are read-only snapshots and
    // the renderer never asks them to flush dirty chunks.
    return out;
}

}  // namespace macvoxel
