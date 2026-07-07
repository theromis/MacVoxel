#pragma once

#include "EditVolume.h"
#include "VoxelGrid.h"

#include <cstdint>
#include <vector>

namespace macvoxel {

// Dense bounded shadow of the document voxels, sized to a fixed
// EditVolume (default 256³ = 16 MiB). Phase A1: write-through cache
// alongside VoxelGrid, with VoxelGrid still the read source.
// Phase A2 attaches a Metal 3D texture; B1 makes the GPU side
// authoritative and migrates the shadow to a write-back cache.
//
// Reads outside the EditVolume return 0. Writes outside are silently
// dropped — those cells still live in VoxelGrid until the user cleans
// them up (matches EditVolume's "deletes are unrestricted" policy).
class VoxelVolume {
public:
    static constexpr int32_t kChunkSize = 16;
    static constexpr int32_t kChunkBits = 4;
    static constexpr int32_t kChunkMask = 0xF;

    explicit VoxelVolume(EditVolume volume = {});

    VoxelVolume(VoxelVolume&&) = default;
    VoxelVolume& operator=(VoxelVolume&&) = default;
    VoxelVolume(const VoxelVolume&) = delete;
    VoxelVolume& operator=(const VoxelVolume&) = delete;

    uint8_t Get(int32_t x, int32_t y, int32_t z) const noexcept;
    void Set(int32_t x, int32_t y, int32_t z, uint8_t value);
    void Clear() noexcept;

    // Bulk apply. Each entry's old_val isn't validated against the
    // current cell — callers must hand over a diff that matches the
    // current shadow state (which the brush kernel does by construction).
    void ApplyChanges(const CellChange* changes, size_t count);

    // Single-pass commit from a GPU-texture readback. `post_bytes` is
    // the x-fastest contents of the bbox region the engine just read
    // back. Walks the bbox row-by-row, comparing against the dense
    // shadow; for every cell that changed, emits a CellChange in
    // *out_diff AND writes the new value back into the shadow + marks
    // the chunk dirty + updates filled_count_ / bounds_.
    //
    // Saves the second per-cell loop that would otherwise happen in
    // VoxelVolume::ApplyChanges: the diff and the shadow update touch
    // the same cells, so doing them in one pass cuts memory traffic
    // and per-cell function-call overhead in half.
    void DiffAndApplyRegion(int32_t bx0, int32_t by0, int32_t bz0,
                            int32_t bx1, int32_t by1, int32_t bz1,
                            const uint8_t* post_bytes,
                            std::vector<CellChange>* out_diff);

    // Whole-buffer reseed used by load + open + new. The per-cell `Set`
    // storm would also work but skips the dense-zero scan when the
    // source is sparse.
    void RebuildFromGrid(const VoxelGrid& src);

    // Re-anchor to a (moved) EditVolume and reseed from `src`. Leaves
    // every chunk dirty so the next texture sync re-uploads in full.
    void Rebase(const EditVolume& volume, const VoxelGrid& src) {
        *this = VoxelVolume(volume);
        RebuildFromGrid(src);
    }

    // Loose bounds, mirroring VoxelGrid: monotonically expanded on
    // non-zero Set, never retightened on Set(0). Reset by Clear().
    Bounds3 Bounds() const noexcept { return bounds_; }
    bool empty() const noexcept { return filled_count_ == 0; }
    size_t FilledCount() const noexcept { return filled_count_; }
    const EditVolume& edit_volume() const noexcept { return volume_; }

    int32_t size_x() const noexcept { return volume_.size_x(); }
    int32_t size_y() const noexcept { return volume_.size_y(); }
    int32_t size_z() const noexcept { return volume_.size_z(); }
    int32_t chunks_x() const noexcept { return chunks_x_; }
    int32_t chunks_y() const noexcept { return chunks_y_; }
    int32_t chunks_z() const noexcept { return chunks_z_; }

    // Dense linear pointer (x-fastest, z-slowest) used by A2's texture
    // upload. Length is size_x * size_y * size_z bytes.
    const uint8_t* data() const noexcept { return cells_.data(); }
    size_t data_size() const noexcept { return cells_.size(); }

    // 16³-chunk dirty bitset, indexed by
    // (cz * chunks_x * chunks_y + cy * chunks_x + cx).
    // Chunk (0,0,0) covers cells [x0..x0+15] × [y0..y0+15] × [z0..z0+15].
    using DirtyBits = std::vector<uint64_t>;
    DirtyBits TakeDirtyChunks();

private:
    EditVolume volume_;
    int32_t chunks_x_ = 0, chunks_y_ = 0, chunks_z_ = 0;
    std::vector<uint8_t> cells_;
    DirtyBits dirty_;
    Bounds3 bounds_{};
    size_t filled_count_ = 0;

    size_t LinearIndex(int32_t x, int32_t y, int32_t z) const noexcept;
    void MarkChunkDirty(int32_t x, int32_t y, int32_t z) noexcept;
    void MarkAllChunksDirty() noexcept;
};

}  // namespace macvoxel
