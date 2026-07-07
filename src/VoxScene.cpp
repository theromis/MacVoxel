#include "VoxScene.h"

namespace macvoxel {

RotMat RotMat::FromByte(uint8_t rot) {
    const int c0 = rot & 0x3;
    const int c1 = (rot >> 2) & 0x3;
    const int c2 = 3 - c0 - c1;
    if (c0 == c1 || c2 < 0 || c2 > 2) return RotMat{};
    const int s0 = (rot & (1 << 4)) ? -1 : 1;
    const int s1 = (rot & (1 << 5)) ? -1 : 1;
    const int s2 = (rot & (1 << 6)) ? -1 : 1;
    RotMat out;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) out.m[i][j] = 0;
    out.m[0][c0] = static_cast<int8_t>(s0);
    out.m[1][c1] = static_cast<int8_t>(s1);
    out.m[2][c2] = static_cast<int8_t>(s2);
    return out;
}

RotMat RotMat::Transposed() const {
    RotMat out;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) out.m[i][j] = m[j][i];
    return out;
}

bool RotMat::IsIdentity() const {
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) {
            if (m[i][j] != (i == j ? 1 : 0)) return false;
        }
    return true;
}

RotMat operator*(const RotMat& a, const RotMat& b) {
    RotMat out;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            int v = 0;
            for (int k = 0; k < 3; ++k) v += a.m[i][k] * b.m[k][j];
            out.m[i][j] = static_cast<int8_t>(v);
        }
    }
    return out;
}

Vec3i32 RotMat::operator*(const Vec3i32& v) const {
    return Vec3i32{
        m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
        m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z,
    };
}

}  // namespace macvoxel
