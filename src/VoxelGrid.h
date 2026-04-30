#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace macvoxel {

struct Dims {
    uint32_t x = 0;
    uint32_t y = 0;
    uint32_t z = 0;

    size_t volume() const {
        return static_cast<size_t>(x) * static_cast<size_t>(y) * static_cast<size_t>(z);
    }
    bool empty() const { return x == 0 || y == 0 || z == 0; }

    friend bool operator==(const Dims& a, const Dims& b) {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
    friend bool operator!=(const Dims& a, const Dims& b) { return !(a == b); }
};

// Dense 3D array of uint8_t palette indices.
// Index 0 means "empty"; indices 1..255 reference the corresponding entry of
// a Palette. Voxels are stored X-fastest, Z-slowest:
// linear = x + y*dims.x + z*dims.x*dims.y.
class VoxelGrid {
public:
    VoxelGrid() = default;
    explicit VoxelGrid(Dims d);

    const Dims& dims() const { return dims_; }
    bool empty() const { return dims_.empty(); }

    // Bounds-checked accessors. Out-of-bounds get returns 0; out-of-bounds set
    // is a no-op. This matches how .vox loaders should behave with malformed
    // chunks — the loader validates separately and logs.
    uint8_t Get(uint32_t x, uint32_t y, uint32_t z) const;
    void Set(uint32_t x, uint32_t y, uint32_t z, uint8_t value);

    void Clear();
    void Resize(Dims d);  // resets contents to zero

    size_t FilledCount() const;

    // Raw storage for I/O. Do not assume the layout outside this class —
    // X-fastest, then Y, then Z.
    const uint8_t* data() const { return cells_.data(); }
    uint8_t* data() { return cells_.data(); }
    size_t size() const { return cells_.size(); }

private:
    Dims dims_{};
    std::vector<uint8_t> cells_;
};

}  // namespace macvoxel
