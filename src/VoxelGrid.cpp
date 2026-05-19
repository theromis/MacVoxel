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

    // Flat Chunk* lookup keyed by linearized chunk coord. Skips the
    // scatter-into-sorted_indices pass and iterates changes[] in
    // input order — sequential reads are cache-friendly. The
    // hashmap probe `chunks_.find(cc)` happens once per unique chunk
    // (~K entries for big-flood commits) instead of once per cell.
    //
    // Pass 1: scan changes, compute chunk-coord bbox.
    // Pass 2: iterate changes in input order; for each change,
    //         resolve (or lazily create) the chunk pointer in by_idx;
    //         apply the cell write + bookkeeping inline. Per-cell
    //         flags update touched[bi*6..bi*6+6] + modified[bi].
    // Pass 3: walk bucket array, do per-chunk post-work (version
    //         bump, dirty_chunks insertion, neighbor bumps, empty
    //         chunk cleanup). bucket_count is small (~thousands).
    int32_t ccx_min = INT32_MAX, ccy_min = INT32_MAX, ccz_min = INT32_MAX;
    int32_t ccx_max = INT32_MIN, ccy_max = INT32_MIN, ccz_max = INT32_MIN;
    for (size_t i = 0; i < count; ++i) {
        const auto& c = changes[i];
        if (c.old_val == c.new_val) continue;
        const int32_t ccx = c.x >> kChunkBits;
        const int32_t ccy = c.y >> kChunkBits;
        const int32_t ccz = c.z >> kChunkBits;
        if (ccx < ccx_min) ccx_min = ccx;
        if (ccy < ccy_min) ccy_min = ccy;
        if (ccz < ccz_min) ccz_min = ccz;
        if (ccx > ccx_max) ccx_max = ccx;
        if (ccy > ccy_max) ccy_max = ccy;
        if (ccz > ccz_max) ccz_max = ccz;
    }
    if (ccx_min == INT32_MAX) return;

    const size_t span_x = static_cast<size_t>(ccx_max - ccx_min + 1);
    const size_t span_y = static_cast<size_t>(ccy_max - ccy_min + 1);
    const size_t span_xy = span_x * span_y;
    const size_t bucket_count =
        span_xy * static_cast<size_t>(ccz_max - ccz_min + 1);

    // by_idx: 0 = unseen; (Chunk*)1 = seen-but-uncreated (erase-into-
    // empty chunk, nothing to do); other = live chunk pointer. The
    // sentinel saves us from re-probing `chunks_` when subsequent
    // erase cells land in the same empty chunk.
    constexpr uintptr_t kNoCreate = 1;
    std::vector<uintptr_t> by_idx(bucket_count, 0);
    std::vector<uint8_t> modified(bucket_count, 0);
    std::vector<uint8_t> touched(bucket_count * 6, 0);

    for (size_t i = 0; i < count; ++i) {
        const auto& c = changes[i];
        if (c.old_val == c.new_val) continue;
        const int32_t ccx = c.x >> kChunkBits;
        const int32_t ccy = c.y >> kChunkBits;
        const int32_t ccz = c.z >> kChunkBits;
        const size_t bi = static_cast<size_t>(ccx - ccx_min) +
                          static_cast<size_t>(ccy - ccy_min) * span_x +
                          static_cast<size_t>(ccz - ccz_min) * span_xy;

        Chunk* chunk = nullptr;
        const uintptr_t slot = by_idx[bi];
        if (slot == kNoCreate) {
            // Cached "no chunk here, all writes so far were erases" —
            // a non-zero write below promotes to a real chunk.
            if (c.new_val == 0) continue;
            ChunkCoord cc{ccx, ccy, ccz};
            auto fresh = std::make_unique<Chunk>();
            fresh->coord = cc;
            auto [it, ok] = chunks_.emplace(cc, std::move(fresh));
            chunk = it->second.get();
            by_idx[bi] = reinterpret_cast<uintptr_t>(chunk);
        } else if (slot == 0) {
            ChunkCoord cc{ccx, ccy, ccz};
            auto it = chunks_.find(cc);
            if (it == chunks_.end()) {
                if (c.new_val == 0) {
                    by_idx[bi] = kNoCreate;
                    continue;
                }
                auto fresh = std::make_unique<Chunk>();
                fresh->coord = cc;
                auto [nit, ok] = chunks_.emplace(cc, std::move(fresh));
                chunk = nit->second.get();
            } else {
                chunk = it->second.get();
            }
            by_idx[bi] = reinterpret_cast<uintptr_t>(chunk);
        } else {
            chunk = reinterpret_cast<Chunk*>(slot);
        }

        const size_t li = LocalIndex(c.x, c.y, c.z);
        const uint8_t prev = chunk->cells[li];
        if (prev == c.new_val) continue;
        chunk->cells[li] = c.new_val;
        modified[bi] = 1;

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
        uint8_t* t = touched.data() + bi * 6;
        if (lx == 0)              t[0] = 1;
        if (lx == kChunkSize - 1) t[1] = 1;
        if (ly == 0)              t[2] = 1;
        if (ly == kChunkSize - 1) t[3] = 1;
        if (lz == 0)              t[4] = 1;
        if (lz == kChunkSize - 1) t[5] = 1;
    }

    // Per-chunk post-work: version bumps, dirty marks, neighbor bumps,
    // empty-chunk cleanup. Walks at most bucket_count entries — small.
    for (size_t bi = 0; bi < bucket_count; ++bi) {
        if (!modified[bi]) continue;
        const uintptr_t slot = by_idx[bi];
        if (slot == 0 || slot == kNoCreate) continue;
        Chunk* chunk = reinterpret_cast<Chunk*>(slot);
        const ChunkCoord cc = chunk->coord;

        ++chunk->version;
        dirty_chunks_.insert(cc);

        const uint8_t* t = touched.data() + bi * 6;
        auto bump_neighbor = [&](int32_t dx, int32_t dy, int32_t dz) {
            ChunkCoord nc{cc.x + dx, cc.y + dy, cc.z + dz};
            auto nit = chunks_.find(nc);
            if (nit != chunks_.end()) {
                ++nit->second->version;
                dirty_chunks_.insert(nc);
            }
        };
        if (t[0]) bump_neighbor(-1, 0, 0);
        if (t[1]) bump_neighbor(+1, 0, 0);
        if (t[2]) bump_neighbor(0, -1, 0);
        if (t[3]) bump_neighbor(0, +1, 0);
        if (t[4]) bump_neighbor(0, 0, -1);
        if (t[5]) bump_neighbor(0, 0, +1);

        if (chunk->filled_count == 0) {
            chunks_.erase(cc);
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
