#include "VoxelVolume.h"

#include <algorithm>
#include <cstring>

namespace macvoxel {

namespace {
int32_t CeilDiv(int32_t n, int32_t d) { return (n + d - 1) / d; }
}  // namespace

VoxelVolume::VoxelVolume(EditVolume volume) : volume_(volume) {
    chunks_x_ = CeilDiv(volume.size_x(), kChunkSize);
    chunks_y_ = CeilDiv(volume.size_y(), kChunkSize);
    chunks_z_ = CeilDiv(volume.size_z(), kChunkSize);
    const size_t total_cells =
        static_cast<size_t>(volume.size_x()) *
        static_cast<size_t>(volume.size_y()) *
        static_cast<size_t>(volume.size_z());
    cells_.assign(total_cells, 0);
    const size_t total_chunks =
        static_cast<size_t>(chunks_x_) *
        static_cast<size_t>(chunks_y_) *
        static_cast<size_t>(chunks_z_);
    dirty_.assign((total_chunks + 63) / 64, 0);
    // GPU-side mirror lives in private storage with undefined initial
    // contents; mark every chunk dirty so the first sync uploads
    // (zeroed) cells across the whole texture.
    MarkAllChunksDirty();
}

size_t VoxelVolume::LinearIndex(int32_t x, int32_t y,
                                int32_t z) const noexcept {
    const int32_t lx = x - volume_.x0;
    const int32_t ly = y - volume_.y0;
    const int32_t lz = z - volume_.z0;
    const size_t sx = static_cast<size_t>(volume_.size_x());
    const size_t sy = static_cast<size_t>(volume_.size_y());
    return static_cast<size_t>(lx) +
           static_cast<size_t>(ly) * sx +
           static_cast<size_t>(lz) * sx * sy;
}

uint8_t VoxelVolume::Get(int32_t x, int32_t y, int32_t z) const noexcept {
    if (!volume_.Contains(x, y, z)) return 0;
    return cells_[LinearIndex(x, y, z)];
}

void VoxelVolume::MarkChunkDirty(int32_t x, int32_t y, int32_t z) noexcept {
    const int32_t cx = (x - volume_.x0) >> kChunkBits;
    const int32_t cy = (y - volume_.y0) >> kChunkBits;
    const int32_t cz = (z - volume_.z0) >> kChunkBits;
    const size_t idx =
        static_cast<size_t>(cx) +
        static_cast<size_t>(cy) * static_cast<size_t>(chunks_x_) +
        static_cast<size_t>(cz) * static_cast<size_t>(chunks_x_) *
                                  static_cast<size_t>(chunks_y_);
    dirty_[idx >> 6] |= (uint64_t{1} << (idx & 63));
}

void VoxelVolume::Set(int32_t x, int32_t y, int32_t z, uint8_t value) {
    if (!volume_.Contains(x, y, z)) return;
    const size_t li = LinearIndex(x, y, z);
    const uint8_t prev = cells_[li];
    if (prev == value) return;
    cells_[li] = value;
    MarkChunkDirty(x, y, z);
    if (prev == 0 && value != 0) {
        ++filled_count_;
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
        --filled_count_;
        // Loose bounds match VoxelGrid: not retightened on erase.
    }
}

void VoxelVolume::MarkAllChunksDirty() noexcept {
    if (dirty_.empty()) return;
    const size_t total_chunks =
        static_cast<size_t>(chunks_x_) *
        static_cast<size_t>(chunks_y_) *
        static_cast<size_t>(chunks_z_);
    std::fill(dirty_.begin(), dirty_.end(), ~uint64_t{0});
    // Mask off the unused high bits in the last word so consumers can
    // iterate the bitset without overshooting `total_chunks`.
    const size_t tail = total_chunks & 63;
    if (tail != 0) {
        dirty_.back() = (uint64_t{1} << tail) - 1;
    }
}

void VoxelVolume::ApplyChanges(const CellChange* changes, size_t count) {
    // Tight inline of Set + MarkChunkDirty: hoists volume bounds and
    // strides out of the per-cell loop, computes LinearIndex once per
    // cell, and folds the chunk-coord recompute MarkChunkDirty would
    // otherwise redo. For 500k-cell strokes this matters: Set does
    // three function calls per change (Contains, LinearIndex,
    // MarkChunkDirty's own chunk-index math), all redundant when the
    // caller has already validated cells live inside the volume.
    const int32_t x0 = volume_.x0;
    const int32_t y0 = volume_.y0;
    const int32_t z0 = volume_.z0;
    const int32_t x1 = volume_.x1;
    const int32_t y1 = volume_.y1;
    const int32_t z1 = volume_.z1;
    const size_t sx = static_cast<size_t>(volume_.size_x());
    const size_t sy = static_cast<size_t>(volume_.size_y());
    const size_t sxy = sx * sy;
    const size_t cxc = static_cast<size_t>(chunks_x_);
    const size_t cxcyc = cxc * static_cast<size_t>(chunks_y_);
    uint8_t* cells = cells_.data();

    for (size_t i = 0; i < count; ++i) {
        const auto& c = changes[i];
        if (c.old_val == c.new_val) continue;
        if (c.x < x0 || c.x > x1 || c.y < y0 || c.y > y1 ||
            c.z < z0 || c.z > z1) continue;
        const int32_t lx = c.x - x0;
        const int32_t ly = c.y - y0;
        const int32_t lz = c.z - z0;
        const size_t li = static_cast<size_t>(lx) +
                          static_cast<size_t>(ly) * sx +
                          static_cast<size_t>(lz) * sxy;
        const uint8_t prev = cells[li];
        if (prev == c.new_val) continue;
        cells[li] = c.new_val;

        const size_t cidx =
            static_cast<size_t>(lx >> kChunkBits) +
            static_cast<size_t>(ly >> kChunkBits) * cxc +
            static_cast<size_t>(lz >> kChunkBits) * cxcyc;
        dirty_[cidx >> 6] |= (uint64_t{1} << (cidx & 63));

        if (prev == 0 && c.new_val != 0) {
            ++filled_count_;
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
            --filled_count_;
            // Loose bounds match VoxelGrid: not retightened on erase.
        }
    }
}

void VoxelVolume::Clear() noexcept {
    std::fill(cells_.begin(), cells_.end(), 0);
    bounds_ = Bounds3{};
    filled_count_ = 0;
    // A2's incremental upload reads dirty bits to know what to push;
    // a Clear must invalidate every chunk so the cleared region propagates.
    MarkAllChunksDirty();
}

void VoxelVolume::RebuildFromGrid(const VoxelGrid& src) {
    Clear();
    for (const auto& [coord, chunk] : src.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (uint32_t i = 0; i < VoxelGrid::kChunkVolume; ++i) {
            const uint8_t v = chunk->cells[i];
            if (v == 0) continue;
            const uint32_t lx = i & VoxelGrid::kChunkMask;
            const uint32_t ly =
                (i >> VoxelGrid::kChunkBits) & VoxelGrid::kChunkMask;
            const uint32_t lz = i >> (2 * VoxelGrid::kChunkBits);
            const int32_t x =
                (coord.x << VoxelGrid::kChunkBits) + static_cast<int32_t>(lx);
            const int32_t y =
                (coord.y << VoxelGrid::kChunkBits) + static_cast<int32_t>(ly);
            const int32_t z =
                (coord.z << VoxelGrid::kChunkBits) + static_cast<int32_t>(lz);
            Set(x, y, z, v);
        }
    }
}

void VoxelVolume::DiffAndApplyRegion(int32_t bx0, int32_t by0, int32_t bz0,
                                      int32_t bx1, int32_t by1, int32_t bz1,
                                      const uint8_t* post_bytes,
                                      std::vector<CellChange>* out_diff) {
    if (post_bytes == nullptr || out_diff == nullptr) return;
    if (bx0 > bx1 || by0 > by1 || bz0 > bz1) return;
    // Clip to the volume so the row pointer math stays in-bounds.
    bx0 = std::max(bx0, volume_.x0);
    by0 = std::max(by0, volume_.y0);
    bz0 = std::max(bz0, volume_.z0);
    bx1 = std::min(bx1, volume_.x1);
    by1 = std::min(by1, volume_.y1);
    bz1 = std::min(bz1, volume_.z1);
    if (bx0 > bx1 || by0 > by1 || bz0 > bz1) return;

    const size_t bw = static_cast<size_t>(bx1 - bx0 + 1);
    const size_t bh = static_cast<size_t>(by1 - by0 + 1);
    const size_t bd = static_cast<size_t>(bz1 - bz0 + 1);
    // Worst-case diff size = every cell in the bbox differs. On macOS
    // a large allocation is a lazy mmap — pages aren't faulted in
    // until actually written, so this is cheap even for near-whole-
    // volume bboxes. Eliminates per-cell capacity checks and
    // amortized-doubling reallocs from push_back inside the inner loop.
    out_diff->reserve(out_diff->size() + bw * bh * bd);
    const size_t sx = static_cast<size_t>(volume_.size_x());
    const size_t sxy = sx * static_cast<size_t>(volume_.size_y());
    const size_t lx0 = static_cast<size_t>(bx0 - volume_.x0);
    const size_t ly0 = static_cast<size_t>(by0 - volume_.y0);
    const size_t lz0 = static_cast<size_t>(bz0 - volume_.z0);
    const size_t cxc = static_cast<size_t>(chunks_x_);
    const size_t cxcyc = cxc * static_cast<size_t>(chunks_y_);
    uint8_t* shadow = cells_.data();

    for (size_t lz = 0; lz < bd; ++lz) {
        for (size_t ly = 0; ly < bh; ++ly) {
            uint8_t* shadow_row =
                shadow + (lz0 + lz) * sxy + (ly0 + ly) * sx + lx0;
            const uint8_t* post_row = post_bytes + lz * bw * bh + ly * bw;
            if (std::memcmp(shadow_row, post_row, bw) == 0) continue;
            const int32_t y = by0 + static_cast<int32_t>(ly);
            const int32_t z = bz0 + static_cast<int32_t>(lz);
            const int32_t ly_local = y - volume_.y0;
            const int32_t lz_local = z - volume_.z0;
            const size_t cy_chunk = static_cast<size_t>(ly_local >> kChunkBits);
            const size_t cz_chunk = static_cast<size_t>(lz_local >> kChunkBits);
            for (size_t lx = 0; lx < bw; ++lx) {
                const uint8_t prev = shadow_row[lx];
                const uint8_t cur = post_row[lx];
                if (prev == cur) continue;
                const int32_t x = bx0 + static_cast<int32_t>(lx);
                shadow_row[lx] = cur;

                CellChange c{};
                c.x = x; c.y = y; c.z = z;
                c.old_val = prev; c.new_val = cur;
                out_diff->push_back(c);

                const size_t cx_chunk =
                    static_cast<size_t>((x - volume_.x0) >> kChunkBits);
                const size_t cidx = cx_chunk + cy_chunk * cxc + cz_chunk * cxcyc;
                dirty_[cidx >> 6] |= (uint64_t{1} << (cidx & 63));

                if (prev == 0 && cur != 0) {
                    ++filled_count_;
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
                } else if (prev != 0 && cur == 0) {
                    --filled_count_;
                }
            }
        }
    }
}

VoxelVolume::DirtyBits VoxelVolume::TakeDirtyChunks() {
    DirtyBits out;
    out.swap(dirty_);
    dirty_.assign(out.size(), 0);
    return out;
}

}  // namespace macvoxel
