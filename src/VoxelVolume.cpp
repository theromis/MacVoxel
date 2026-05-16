#include "VoxelVolume.h"

#include <algorithm>

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

VoxelVolume::DirtyBits VoxelVolume::TakeDirtyChunks() {
    DirtyBits out;
    out.swap(dirty_);
    dirty_.assign(out.size(), 0);
    return out;
}

}  // namespace macvoxel
