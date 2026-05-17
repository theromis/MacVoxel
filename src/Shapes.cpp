#include "Shapes.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <unordered_set>
#include <utility>

#include "CellKey.h"
#include "VoxelGrid.h"

namespace macvoxel::shapes {

void Bresenham3D(int x0, int y0, int z0, int x1, int y1, int z1,
                 std::vector<Vec3i>& out) {
    out.clear();
    const int dx = std::abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    const int dy = std::abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    const int dz = std::abs(z1 - z0), sz = z0 < z1 ? 1 : -1;
    const int dm = std::max({dx, dy, dz});
    int x = x0, y = y0, z = z0;
    int ex = dm / 2, ey = dm / 2, ez = dm / 2;
    out.reserve(static_cast<size_t>(dm) + 1);
    out.push_back({x, y, z});
    for (int i = 0; i < dm; ++i) {
        ex -= dx; if (ex < 0) { ex += dm; x += sx; }
        ey -= dy; if (ey < 0) { ey += dm; y += sy; }
        ez -= dz; if (ez < 0) { ez += dm; z += sz; }
        out.push_back({x, y, z});
    }
}

void ProjectInPlane(int face_axis, int x, int y, int z, int* u, int* v) {
    switch (face_axis) {
        case 0:  *u = y; *v = z; break;
        case 1:  *u = x; *v = z; break;
        default: *u = x; *v = y; break;
    }
}

void OffsetInPlane(int face_axis, int i, int j, int* dx, int* dy, int* dz) {
    *dx = *dy = *dz = 0;
    switch (face_axis) {
        case 0:  *dy = i; *dz = j; break;
        case 1:  *dx = i; *dz = j; break;
        default: *dx = i; *dy = j; break;
    }
}

void EnumerateLine(Vec3i a, Vec3i b, std::vector<Vec3i>& out) {
    Bresenham3D(a.x, a.y, a.z, b.x, b.y, b.z, out);
}

void EnumerateCirclePlanar(Vec3i anchor, Vec3i endpoint, int face_axis,
                           bool fill, bool even,
                           std::vector<Vec3i>& out) {
    out.clear();
    int au, av, eu, ev;
    ProjectInPlane(face_axis, anchor.x, anchor.y, anchor.z, &au, &av);
    ProjectInPlane(face_axis, endpoint.x, endpoint.y, endpoint.z, &eu, &ev);
    const int du = eu - au;
    const int dv = ev - av;

    // Center offset: 0.0 places the disc center on the anchor cell (odd
    // diameter); 0.5 places it on the corner shared by the four cells
    // around the anchor (even diameter).
    const float c = even ? 0.5f : 0.0f;
    const float fdu = static_cast<float>(du) - c;
    const float fdv = static_cast<float>(dv) - c;
    const float radius2 = fdu * fdu + fdv * fdv;
    const float radius = std::sqrt(radius2);
    const int bound = static_cast<int>(std::ceil(radius)) + 1;

    auto in_disc = [c, radius2](int i, int j) {
        const float fi = static_cast<float>(i) - c;
        const float fj = static_cast<float>(j) - c;
        return (fi * fi + fj * fj) <= radius2;
    };

    out.reserve(static_cast<size_t>((2 * bound + 1) * (2 * bound + 1)));
    for (int j = -bound; j <= bound; ++j) {
        for (int i = -bound; i <= bound; ++i) {
            if (!in_disc(i, j)) continue;
            if (!fill) {
                // Outline = boundary of disc: cell is in the disc but at
                // least one 4-neighbor isn't.
                if (in_disc(i + 1, j) && in_disc(i - 1, j) &&
                    in_disc(i, j + 1) && in_disc(i, j - 1)) {
                    continue;
                }
            }
            int dx, dy, dz;
            OffsetInPlane(face_axis, i, j, &dx, &dy, &dz);
            out.push_back({anchor.x + dx, anchor.y + dy, anchor.z + dz});
        }
    }
}

void EnumerateSquarePlanar(Vec3i anchor, Vec3i endpoint, int face_axis,
                           bool fill, bool even,
                           std::vector<Vec3i>& out) {
    out.clear();
    int au, av, eu, ev;
    ProjectInPlane(face_axis, anchor.x, anchor.y, anchor.z, &au, &av);
    ProjectInPlane(face_axis, endpoint.x, endpoint.y, endpoint.z, &eu, &ev);
    const int du = eu - au;
    const int dv = ev - av;

    const float c = even ? 0.5f : 0.0f;
    const float fdu = std::fabs(static_cast<float>(du) - c);
    const float fdv = std::fabs(static_cast<float>(dv) - c);
    const float half = std::max(fdu, fdv);
    const int bound = static_cast<int>(std::ceil(half)) + 1;

    auto in_square = [c, half](int i, int j) {
        const float fi = std::fabs(static_cast<float>(i) - c);
        const float fj = std::fabs(static_cast<float>(j) - c);
        return std::max(fi, fj) <= half;
    };

    out.reserve(static_cast<size_t>((2 * bound + 1) * (2 * bound + 1)));
    for (int j = -bound; j <= bound; ++j) {
        for (int i = -bound; i <= bound; ++i) {
            if (!in_square(i, j)) continue;
            if (!fill) {
                if (in_square(i + 1, j) && in_square(i - 1, j) &&
                    in_square(i, j + 1) && in_square(i, j - 1)) {
                    continue;
                }
            }
            int dx, dy, dz;
            OffsetInPlane(face_axis, i, j, &dx, &dy, &dz);
            out.push_back({anchor.x + dx, anchor.y + dy, anchor.z + dz});
        }
    }
}

void EnumerateBox(Vec3i corner_a, Vec3i corner_b, bool fill,
                  std::vector<Vec3i>& out) {
    out.clear();
    const int32_t x0 = std::min(corner_a.x, corner_b.x);
    const int32_t x1 = std::max(corner_a.x, corner_b.x);
    const int32_t y0 = std::min(corner_a.y, corner_b.y);
    const int32_t y1 = std::max(corner_a.y, corner_b.y);
    const int32_t z0 = std::min(corner_a.z, corner_b.z);
    const int32_t z1 = std::max(corner_a.z, corner_b.z);
    const size_t nx = static_cast<size_t>(x1 - x0 + 1);
    const size_t ny = static_cast<size_t>(y1 - y0 + 1);
    const size_t nz = static_cast<size_t>(z1 - z0 + 1);

    if (fill) {
        out.reserve(nx * ny * nz);
        for (int32_t z = z0; z <= z1; ++z) {
            for (int32_t y = y0; y <= y1; ++y) {
                for (int32_t x = x0; x <= x1; ++x) {
                    out.push_back({x, y, z});
                }
            }
        }
        return;
    }

    // Hollow shell: the six faces of the AABB. A single-axis-thin box
    // (any of nx/ny/nz == 1) collapses to its filled form rather than
    // returning empty, so a 1-thick frame still draws something.
    if (nx == 1 || ny == 1 || nz == 1) {
        out.reserve(nx * ny * nz);
        for (int32_t z = z0; z <= z1; ++z) {
            for (int32_t y = y0; y <= y1; ++y) {
                for (int32_t x = x0; x <= x1; ++x) {
                    out.push_back({x, y, z});
                }
            }
        }
        return;
    }

    const size_t shell_count = nx * ny * nz - (nx - 2) * (ny - 2) * (nz - 2);
    out.reserve(shell_count);
    for (int32_t z = z0; z <= z1; ++z) {
        const bool z_face = (z == z0 || z == z1);
        for (int32_t y = y0; y <= y1; ++y) {
            const bool y_face = (y == y0 || y == y1);
            for (int32_t x = x0; x <= x1; ++x) {
                const bool x_face = (x == x0 || x == x1);
                if (x_face || y_face || z_face) {
                    out.push_back({x, y, z});
                }
            }
        }
    }
}

void FloodCoplanarFace(const VoxelGrid& grid, Vec3i seed, int axis, int sign,
                       uint8_t match_color, bool eight_conn,
                       std::vector<Vec3i>& out) {
    out.clear();
    const int u_axis = (axis == 0) ? 1 : 0;
    const int v_axis = (axis == 2) ? 1 : 2;
    const int seed_xyz[3] = {seed.x, seed.y, seed.z};
    auto cell_at = [&](int u, int v) -> Vec3i {
        int xyz[3] = {0, 0, 0};
        xyz[axis] = seed_xyz[axis];
        xyz[u_axis] = u;
        xyz[v_axis] = v;
        return Vec3i{xyz[0], xyz[1], xyz[2]};
    };
    int normal[3] = {0, 0, 0};
    normal[axis] = sign;

    auto qualifies = [&](const Vec3i& c) -> bool {
        const uint8_t v = grid.Get(c.x, c.y, c.z);
        if (v == 0) return false;
        if (match_color != 0 && v != match_color) return false;
        return grid.Get(c.x + normal[0], c.y + normal[1],
                        c.z + normal[2]) == 0;
    };

    if (!qualifies(seed)) return;

    std::unordered_set<int64_t> visited;
    std::vector<std::pair<int, int>> stack;
    const int seed_u = seed_xyz[u_axis];
    const int seed_v = seed_xyz[v_axis];
    stack.push_back({seed_u, seed_v});
    visited.insert(PackCellKey(seed_u, seed_v, 0));
    while (!stack.empty()) {
        const std::pair<int, int> top = stack.back();
        stack.pop_back();
        const int u = top.first;
        const int v = top.second;
        const Vec3i c = cell_at(u, v);
        if (!qualifies(c)) continue;
        out.push_back(c);
        const std::pair<int, int> cardinals[4] = {
            {u + 1, v}, {u - 1, v}, {u, v + 1}, {u, v - 1}
        };
        for (const auto& n : cardinals) {
            const int64_t key = PackCellKey(n.first, n.second, 0);
            if (visited.insert(key).second) stack.push_back(n);
        }
        if (eight_conn) {
            const std::pair<int, int> diagonals[4] = {
                {u + 1, v + 1}, {u + 1, v - 1},
                {u - 1, v + 1}, {u - 1, v - 1}
            };
            for (const auto& n : diagonals) {
                const int64_t key = PackCellKey(n.first, n.second, 0);
                if (visited.insert(key).second) stack.push_back(n);
            }
        }
    }
}

void FloodCoplanarEmpty(const VoxelGrid& grid, Vec3i seed, int axis,
                        int u_min, int u_max, int v_min, int v_max,
                        bool eight_conn, std::vector<Vec3i>& out) {
    out.clear();
    const int u_axis = (axis == 0) ? 1 : 0;
    const int v_axis = (axis == 2) ? 1 : 2;
    const int seed_xyz[3] = {seed.x, seed.y, seed.z};
    auto cell_at = [&](int u, int v) -> Vec3i {
        int xyz[3] = {0, 0, 0};
        xyz[axis] = seed_xyz[axis];
        xyz[u_axis] = u;
        xyz[v_axis] = v;
        return Vec3i{xyz[0], xyz[1], xyz[2]};
    };
    auto in_rect = [&](int u, int v) {
        return u >= u_min && u <= u_max && v >= v_min && v <= v_max;
    };
    auto is_empty = [&](const Vec3i& c) -> bool {
        return grid.Get(c.x, c.y, c.z) == 0;
    };

    const int seed_u = seed_xyz[u_axis];
    const int seed_v = seed_xyz[v_axis];
    if (!in_rect(seed_u, seed_v)) return;
    if (!is_empty(seed)) return;

    std::unordered_set<int64_t> visited;
    std::vector<std::pair<int, int>> stack;
    stack.push_back({seed_u, seed_v});
    visited.insert(PackCellKey(seed_u, seed_v, 0));
    while (!stack.empty()) {
        const std::pair<int, int> top = stack.back();
        stack.pop_back();
        const int u = top.first;
        const int v = top.second;
        if (!in_rect(u, v)) continue;
        const Vec3i c = cell_at(u, v);
        if (!is_empty(c)) continue;
        out.push_back(c);
        const std::pair<int, int> cardinals[4] = {
            {u + 1, v}, {u - 1, v}, {u, v + 1}, {u, v - 1}
        };
        for (const auto& n : cardinals) {
            const int64_t key = PackCellKey(n.first, n.second, 0);
            if (visited.insert(key).second) stack.push_back(n);
        }
        if (eight_conn) {
            const std::pair<int, int> diagonals[4] = {
                {u + 1, v + 1}, {u + 1, v - 1},
                {u - 1, v + 1}, {u - 1, v - 1}
            };
            for (const auto& n : diagonals) {
                const int64_t key = PackCellKey(n.first, n.second, 0);
                if (visited.insert(key).second) stack.push_back(n);
            }
        }
    }
}

}  // namespace macvoxel::shapes
