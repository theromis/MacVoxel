#pragma once

#include <cstdint>
#include <vector>

namespace macvoxel {

// Voxel-space clipboard. Holds a copy of a rectangular region of palette
// indices, addressed X-fastest then Y then Z (same convention as a chunk).
struct Clipboard {
    uint32_t size_x = 0;
    uint32_t size_y = 0;
    uint32_t size_z = 0;
    std::vector<uint8_t> cells;

    bool empty() const { return cells.empty(); }
    void Clear() {
        size_x = size_y = size_z = 0;
        cells.clear();
    }
    size_t LinearIndex(uint32_t x, uint32_t y, uint32_t z) const {
        return (static_cast<size_t>(z) * size_y + y) * size_x + x;
    }
};

Clipboard& CurrentClipboard();

}  // namespace macvoxel
