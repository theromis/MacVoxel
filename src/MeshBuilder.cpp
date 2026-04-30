#include "MeshBuilder.h"

#include <array>
#include <cstring>

namespace macvoxel {
namespace {

constexpr int N = static_cast<int>(VoxelGrid::kChunkSize);  // 16

// Six face directions. For each, axis_a is the face normal's axis; axis_r
// and axis_t are the two tangent axes chosen so that (+axis_r) cross
// (+axis_t) equals sign*(+axis_a) — i.e., R x T = N for both signs. Quad
// vertices in CCW order BL -> BR -> TR -> TL are then automatically
// correct for outside-viewing winding regardless of which face we're on.
//
// normal_idx is the renderer's index into its constant normal table:
//   0:+X 1:-X 2:+Y 3:-Y 4:+Z 5:-Z
struct DirInfo {
    int axis_a;
    int axis_r;
    int axis_t;
    int sign;
    uint8_t normal_idx;
};

constexpr std::array<DirInfo, 6> kDirs = {{
    {0, 1, 2, +1, 0},   // +X: R=+Y, T=+Z
    {0, 2, 1, -1, 1},   // -X: R=+Z, T=+Y
    {1, 2, 0, +1, 2},   // +Y: R=+Z, T=+X
    {1, 0, 2, -1, 3},   // -Y: R=+X, T=+Z
    {2, 0, 1, +1, 4},   // +Z: R=+X, T=+Y
    {2, 1, 0, -1, 5},   // -Z: R=+Y, T=+X
}};

inline uint8_t GetCellInChunk(const VoxelGrid::Chunk& chunk, int x, int y, int z) {
    const size_t li = static_cast<size_t>(x) +
                      static_cast<size_t>(y) * VoxelGrid::kChunkSize +
                      static_cast<size_t>(z) * VoxelGrid::kChunkSize *
                          VoxelGrid::kChunkSize;
    return chunk.cells[li];
}

// Read the cell at chunk-local (a, r, t) under direction d. Lookups that
// leave the chunk go through grid.Get for cross-chunk visibility checks.
inline uint8_t ReadCell(const VoxelGrid& grid,
                        const VoxelGrid::Chunk& chunk,
                        const VoxelGrid::ChunkCoord& cc,
                        const DirInfo& d, int a, int r, int t) {
    const bool inside = (0 <= a && a < N && 0 <= r && r < N && 0 <= t && t < N);
    if (inside) {
        int local[3]{};
        local[d.axis_a] = a;
        local[d.axis_r] = r;
        local[d.axis_t] = t;
        return GetCellInChunk(chunk, local[0], local[1], local[2]);
    }
    int origin[3] = {cc.x * N, cc.y * N, cc.z * N};
    int world[3] = {origin[0], origin[1], origin[2]};
    world[d.axis_a] += a;
    world[d.axis_r] += r;
    world[d.axis_t] += t;
    return grid.Get(world[0], world[1], world[2]);
}

void EmitQuad(std::vector<MeshVertex>* vertices,
              std::vector<uint32_t>* indices,
              const DirInfo& d,
              int origin[3], int plane_a,
              int r_min, int t_min, int width, int height,
              uint8_t color) {
    auto make = [&](int r, int t) -> std::array<int, 3> {
        std::array<int, 3> w{};
        w[0] = origin[0];
        w[1] = origin[1];
        w[2] = origin[2];
        w[d.axis_r] += r;
        w[d.axis_t] += t;
        w[d.axis_a] = plane_a;  // overrides origin component on axis_a
        return w;
    };

    const std::array<int, 3> bl = make(r_min, t_min);
    const std::array<int, 3> br = make(r_min + width, t_min);
    const std::array<int, 3> tr = make(r_min + width, t_min + height);
    const std::array<int, 3> tl = make(r_min, t_min + height);

    const uint32_t base = static_cast<uint32_t>(vertices->size());
    auto push = [&](const std::array<int, 3>& p) {
        MeshVertex v;
        v.x = static_cast<int16_t>(p[0]);
        v.y = static_cast<int16_t>(p[1]);
        v.z = static_cast<int16_t>(p[2]);
        v.normal_idx = d.normal_idx;
        v.palette_idx = color;
        vertices->push_back(v);
    };
    push(bl);
    push(br);
    push(tr);
    push(tl);

    indices->push_back(base + 0);
    indices->push_back(base + 1);
    indices->push_back(base + 2);
    indices->push_back(base + 0);
    indices->push_back(base + 2);
    indices->push_back(base + 3);
}

void MeshDirection(const VoxelGrid& grid,
                   const VoxelGrid::ChunkCoord& cc,
                   const VoxelGrid::Chunk& chunk,
                   const DirInfo& d,
                   std::vector<MeshVertex>* vertices,
                   std::vector<uint32_t>* indices) {
    int origin[3] = {cc.x * N, cc.y * N, cc.z * N};

    for (int a = 0; a < N; ++a) {
        // mask[t][r] = palette index of an exposed face, or 0 if none.
        uint8_t mask[N][N];
        std::memset(mask, 0, sizeof(mask));

        bool any = false;
        for (int t = 0; t < N; ++t) {
            for (int r = 0; r < N; ++r) {
                const uint8_t cell = ReadCell(grid, chunk, cc, d, a, r, t);
                if (cell == 0) continue;
                const uint8_t neighbor =
                    ReadCell(grid, chunk, cc, d, a + d.sign, r, t);
                if (neighbor != 0) continue;
                mask[t][r] = cell;
                any = true;
            }
        }
        if (!any) continue;

        // Greedy 2D rectangle merge: scan in row-major (t outer, r inner).
        for (int t0 = 0; t0 < N; ++t0) {
            for (int r0 = 0; r0 < N; ++r0) {
                const uint8_t color = mask[t0][r0];
                if (color == 0) continue;

                int width = 1;
                while (r0 + width < N && mask[t0][r0 + width] == color) ++width;

                int height = 1;
                while (t0 + height < N) {
                    bool match = true;
                    for (int rr = 0; rr < width; ++rr) {
                        if (mask[t0 + height][r0 + rr] != color) {
                            match = false;
                            break;
                        }
                    }
                    if (!match) break;
                    ++height;
                }

                const int plane_a = origin[d.axis_a] + a + (d.sign > 0 ? 1 : 0);
                EmitQuad(vertices, indices, d, origin, plane_a,
                         r0, t0, width, height, color);

                for (int dt = 0; dt < height; ++dt) {
                    for (int dr = 0; dr < width; ++dr) {
                        mask[t0 + dt][r0 + dr] = 0;
                    }
                }
            }
        }
    }
}

}  // namespace

void GreedyMeshChunk(const VoxelGrid& grid,
                     const VoxelGrid::ChunkCoord& cc,
                     const VoxelGrid::Chunk& chunk,
                     std::vector<MeshVertex>* vertices,
                     std::vector<uint32_t>* indices) {
    for (const DirInfo& d : kDirs) {
        MeshDirection(grid, cc, chunk, d, vertices, indices);
    }
}

}  // namespace macvoxel
