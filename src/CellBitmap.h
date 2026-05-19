#pragma once

#include "EditVolume.h"

#include <cstdint>
#include <cstring>
#include <vector>

namespace macvoxel {

// Dense byte-per-cell flag bitmap sized to an EditVolume. Replaces the
// std::unordered_set<int64_t> the brush stroke used as a skip set:
// Set/Test become an array index + dereference (~5 ns) instead of a
// hashmap probe (~200 ns). At 600k cells per big-brush stroke the
// hashmap cost was 100+ ms; the bitmap is single-digit ms total.
//
// 16 MiB ceiling at the default 256³ EditVolume is fine — one
// allocation per BrushTool instance, memset on stroke reset (~0.5 ms
// at unified-memory bandwidth).
//
// Cells outside the EditVolume are silently dropped on Set and report
// false on Test, matching VoxelVolume's clipping policy.
class CellBitmap {
public:
    CellBitmap() = default;

    // (Re)bind to an EditVolume. Allocates / re-allocates the backing
    // buffer if the dimensions changed; otherwise zeroes in place.
    void ResetTo(const EditVolume& vol) {
        vol_ = vol;
        sx_ = static_cast<size_t>(vol.size_x());
        sy_ = static_cast<size_t>(vol.size_y());
        sxy_ = sx_ * sy_;
        const size_t needed = sxy_ * static_cast<size_t>(vol.size_z());
        if (bits_.size() != needed) {
            bits_.assign(needed, 0);
        } else {
            std::memset(bits_.data(), 0, bits_.size());
        }
        any_set_ = false;
    }

    void Set(int32_t x, int32_t y, int32_t z) {
        if (!vol_.Contains(x, y, z)) return;
        bits_[Index(x, y, z)] = 1;
        any_set_ = true;
    }

    bool Test(int32_t x, int32_t y, int32_t z) const {
        if (!vol_.Contains(x, y, z)) return false;
        return bits_[Index(x, y, z)] != 0;
    }

    bool Empty() const { return !any_set_; }

private:
    size_t Index(int32_t x, int32_t y, int32_t z) const {
        return static_cast<size_t>(x - vol_.x0) +
               static_cast<size_t>(y - vol_.y0) * sx_ +
               static_cast<size_t>(z - vol_.z0) * sxy_;
    }

    EditVolume vol_{0, -1, 0, -1, 0, -1};
    size_t sx_ = 0;
    size_t sy_ = 0;
    size_t sxy_ = 0;
    std::vector<uint8_t> bits_;
    bool any_set_ = false;
};

}  // namespace macvoxel
