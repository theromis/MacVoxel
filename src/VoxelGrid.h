#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <unordered_map>
#include <unordered_set>

namespace macvoxel {

// World-space AABB of filled cells. `empty()` if no voxels.
struct Bounds3 {
    int32_t min_x = 0, min_y = 0, min_z = 0;
    int32_t max_x = -1, max_y = -1, max_z = -1;

    bool empty() const { return max_x < min_x; }
    int32_t size_x() const { return empty() ? 0 : max_x - min_x + 1; }
    int32_t size_y() const { return empty() ? 0 : max_y - min_y + 1; }
    int32_t size_z() const { return empty() ? 0 : max_z - min_z + 1; }
};

// Sparse 3D grid of uint8 palette indices, stored as 16x16x16 dense chunks
// keyed by chunk coord in a hash map. Cells default to 0 ("empty"). World
// coordinates are signed so models with negative translations (common in
// MagicaVoxel scene graphs) work directly.
//
// Why chunks: dense storage everywhere is fine for small models but blows
// up for large multi-model scenes (a 2000^3 union AABB would be 8 GB of
// uint8 cells). Chunks pay only for non-empty 16^3 regions, support O(1)
// point queries (needed by future picking and path-tracing DDA), and stay
// cache-friendly when iterated.
class VoxelGrid {
public:
    static constexpr uint32_t kChunkBits = 4;
    static constexpr uint32_t kChunkSize = 1u << kChunkBits;  // 16
    static constexpr uint32_t kChunkMask = kChunkSize - 1u;
    static constexpr size_t kChunkVolume =
        static_cast<size_t>(kChunkSize) * kChunkSize * kChunkSize;

    struct ChunkCoord {
        int32_t x = 0, y = 0, z = 0;
        friend bool operator==(const ChunkCoord& a, const ChunkCoord& b) {
            return a.x == b.x && a.y == b.y && a.z == b.z;
        }
    };

    struct ChunkCoordHash {
        size_t operator()(const ChunkCoord& c) const noexcept {
            uint64_t h = static_cast<uint32_t>(c.x);
            h *= 0xff51afd7ed558ccdULL;
            h ^= static_cast<uint32_t>(c.y) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
            h *= 0xff51afd7ed558ccdULL;
            h ^= static_cast<uint32_t>(c.z) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
            return static_cast<size_t>(h);
        }
    };

    struct Chunk {
        ChunkCoord coord{};
        uint8_t cells[kChunkVolume]{};
        uint32_t filled_count = 0;
        // Bumped on every modification to this chunk's cells, AND on edits
        // to neighbor chunks at our shared boundary (those edits can
        // change which of our boundary faces are visible). Renderers cache
        // their last-built version per chunk and remesh on mismatch.
        uint32_t version = 0;
    };

    using ChunkMap =
        std::unordered_map<ChunkCoord, std::unique_ptr<Chunk>, ChunkCoordHash>;
    using ChunkSet = std::unordered_set<ChunkCoord, ChunkCoordHash>;

    VoxelGrid() = default;
    VoxelGrid(VoxelGrid&&) = default;
    VoxelGrid& operator=(VoxelGrid&&) = default;
    VoxelGrid(const VoxelGrid&) = delete;
    VoxelGrid& operator=(const VoxelGrid&) = delete;

    uint8_t Get(int32_t x, int32_t y, int32_t z) const;
    void Set(int32_t x, int32_t y, int32_t z, uint8_t value);

    void Clear();

    // Deep copy. The default copy ctor is deleted because the chunk
    // map holds unique_ptrs, but a manual clone is cheap and useful
    // for snapshots (the floating-buffer scale gizmo captures one at
    // drag start so each frame's resample sees the lossless original).
    VoxelGrid Clone() const;

    size_t FilledCount() const { return total_filled_; }
    bool empty() const { return total_filled_ == 0; }

    // Loose bounds: monotonically expanded by Set(non-zero); not retightened
    // by Set(0). Reset by Clear(). Phase 3 only adds voxels at load time, so
    // "loose" is exactly tight in practice.
    Bounds3 Bounds() const { return bounds_; }

    const ChunkMap& chunks() const { return chunks_; }

    // Set populates this with each modified chunk and any boundary
    // neighbor whose visible faces could be affected. Consumers (today
    // just VoxelRenderer) drain it via TakeDirtyChunks() — they receive
    // the set by move, leaving the grid empty so the next batch of edits
    // accumulates from scratch.
    ChunkSet TakeDirtyChunks() {
        ChunkSet out = std::move(dirty_chunks_);
        dirty_chunks_.clear();
        return out;
    }

    // Helpers — exposed for renderers and the save path so they don't have
    // to reproduce the chunk math.
    static ChunkCoord ToChunkCoord(int32_t x, int32_t y, int32_t z) {
        // Arithmetic right-shift on signed types is implementation-defined
        // before C++20 and floor-divide from C++20 onward; we require C++20.
        return ChunkCoord{x >> kChunkBits, y >> kChunkBits, z >> kChunkBits};
    }
    static size_t LocalIndex(int32_t x, int32_t y, int32_t z) {
        const uint32_t lx = static_cast<uint32_t>(x) & kChunkMask;
        const uint32_t ly = static_cast<uint32_t>(y) & kChunkMask;
        const uint32_t lz = static_cast<uint32_t>(z) & kChunkMask;
        return lx + ly * kChunkSize + lz * kChunkSize * kChunkSize;
    }

private:
    ChunkMap chunks_;
    ChunkSet dirty_chunks_;
    size_t total_filled_ = 0;
    Bounds3 bounds_{};
};

}  // namespace macvoxel
