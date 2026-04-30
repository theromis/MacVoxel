#include "VoxelGrid.h"

namespace macvoxel {

VoxelGrid::VoxelGrid(Dims d) : dims_(d), cells_(d.volume(), uint8_t{0}) {}

uint8_t VoxelGrid::Get(uint32_t x, uint32_t y, uint32_t z) const {
    if (x >= dims_.x || y >= dims_.y || z >= dims_.z) {
        return 0;
    }
    const size_t i =
        static_cast<size_t>(x) +
        static_cast<size_t>(y) * dims_.x +
        static_cast<size_t>(z) * dims_.x * dims_.y;
    return cells_[i];
}

void VoxelGrid::Set(uint32_t x, uint32_t y, uint32_t z, uint8_t value) {
    if (x >= dims_.x || y >= dims_.y || z >= dims_.z) {
        return;
    }
    const size_t i =
        static_cast<size_t>(x) +
        static_cast<size_t>(y) * dims_.x +
        static_cast<size_t>(z) * dims_.x * dims_.y;
    cells_[i] = value;
}

void VoxelGrid::Clear() {
    std::fill(cells_.begin(), cells_.end(), uint8_t{0});
}

void VoxelGrid::Resize(Dims d) {
    dims_ = d;
    cells_.assign(d.volume(), uint8_t{0});
}

size_t VoxelGrid::FilledCount() const {
    size_t n = 0;
    for (uint8_t v : cells_) {
        if (v != 0) {
            ++n;
        }
    }
    return n;
}

}  // namespace macvoxel
