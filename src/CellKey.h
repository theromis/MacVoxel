#pragma once

#include <cstdint>

namespace macvoxel {

// Pack (x, y, z) cell coordinates into a 64-bit key. 21 bits per axis,
// two's-complement signed range ±2^20 (≈ ±1M voxels) — coordinates outside
// that range will silently wrap. Layout matches the original Raycast skip
// set: x in bits [0..20], y in [21..41], z in [42..62].
inline int64_t PackCellKey(int32_t x, int32_t y, int32_t z) {
    constexpr uint64_t kFieldMask = (1ull << 21) - 1ull;
    return static_cast<int64_t>(
        (static_cast<uint64_t>(x) & kFieldMask) |
        ((static_cast<uint64_t>(y) & kFieldMask) << 21) |
        ((static_cast<uint64_t>(z) & kFieldMask) << 42));
}

// Inverse of PackCellKey. The packed encoding stores 21-bit fields with
// implicit two's-complement sign extension; reverse it with the standard
// `(u ^ signBit) - signBit` trick.
inline void UnpackCellKey(int64_t key, int32_t* x, int32_t* y, int32_t* z) {
    constexpr uint64_t kFieldMask = (1ull << 21) - 1ull;
    constexpr uint32_t kSignBit = 1u << 20;
    auto extend = [](uint64_t v) -> int32_t {
        const uint32_t u = static_cast<uint32_t>(v & kFieldMask);
        return static_cast<int32_t>((u ^ kSignBit) - kSignBit);
    };
    const uint64_t k = static_cast<uint64_t>(key);
    *x = extend(k);
    *y = extend(k >> 21);
    *z = extend(k >> 42);
}

}  // namespace macvoxel
