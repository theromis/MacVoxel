#pragma once

#include <cstdint>

namespace macvoxel {

struct Vec3i32 {
    int32_t x = 0, y = 0, z = 0;

    friend Vec3i32 operator+(const Vec3i32& a, const Vec3i32& b) {
        return Vec3i32{a.x + b.x, a.y + b.y, a.z + b.z};
    }
    friend Vec3i32 operator-(const Vec3i32& a, const Vec3i32& b) {
        return Vec3i32{a.x - b.x, a.y - b.y, a.z - b.z};
    }
    friend bool operator==(const Vec3i32& a, const Vec3i32& b) {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
};

// Signed-permutation rotation matrix — one of the axis-aligned orientations
// a .vox scene-graph transform can express. FromByte implements the `_r`
// rotation-byte codec: bits 0-1 select row 0's non-zero column, bits 2-3
// row 1's (row 2 is implied), bits 4/5/6 carry the per-row signs. The
// identity encodes as 4; malformed bytes decode to identity.
struct RotMat {
    int8_t m[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};

    static RotMat FromByte(uint8_t rot);

    // For signed permutations the transpose is the inverse.
    RotMat Transposed() const;

    bool IsIdentity() const;

    friend RotMat operator*(const RotMat& a, const RotMat& b);
    Vec3i32 operator*(const Vec3i32& v) const;
};

}  // namespace macvoxel
