#include "SelectionOps.h"

#include "CellKey.h"
#include "Document.h"
#include "EditorContext.h"
#include "Selection.h"
#include "SelectionLift.h"
#include "VoxelGrid.h"

#include <array>
#include <cstdint>
#include <unordered_set>
#include <vector>

namespace macvoxel {

namespace {

// 6-connected flood fill from seed; returns the list of cells that
// share `target_pal` with the seed.
std::vector<std::array<int32_t, 3>> FloodCells(const VoxelGrid& grid,
                                                int32_t sx, int32_t sy,
                                                int32_t sz,
                                                uint8_t target_pal) {
    std::unordered_set<int64_t> visited;
    std::vector<std::array<int32_t, 3>> picked;
    std::vector<std::array<int32_t, 3>> queue;
    queue.reserve(256);
    visited.reserve(256);
    queue.push_back({sx, sy, sz});
    visited.insert(PackCellKey(sx, sy, sz));
    static constexpr int kStep[6][3] = {
        { 1, 0, 0}, {-1, 0, 0},
        { 0, 1, 0}, { 0,-1, 0},
        { 0, 0, 1}, { 0, 0,-1},
    };
    while (!queue.empty()) {
        const auto c = queue.back();
        queue.pop_back();
        picked.push_back(c);
        for (int i = 0; i < 6; ++i) {
            const int32_t nx = c[0] + kStep[i][0];
            const int32_t ny = c[1] + kStep[i][1];
            const int32_t nz = c[2] + kStep[i][2];
            const int64_t key = PackCellKey(nx, ny, nz);
            if (!visited.insert(key).second) continue;
            if (grid.Get(nx, ny, nz) != target_pal) continue;
            queue.push_back({nx, ny, nz});
        }
    }
    return picked;
}

}  // namespace

std::vector<std::array<int32_t, 3>> EnumerateCellsWhere(
    EditorContext& ctx,
    const std::function<bool(int32_t, int32_t, int32_t, uint8_t)>& pred) {
    std::vector<std::array<int32_t, 3>> picked;
    constexpr uint32_t kCS = VoxelGrid::kChunkSize;
    for (const auto& [coord, chunk] : ctx.document.grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        const int32_t base_x = coord.x * static_cast<int32_t>(kCS);
        const int32_t base_y = coord.y * static_cast<int32_t>(kCS);
        const int32_t base_z = coord.z * static_cast<int32_t>(kCS);
        for (uint32_t lz = 0; lz < kCS; ++lz) {
            for (uint32_t ly = 0; ly < kCS; ++ly) {
                for (uint32_t lx = 0; lx < kCS; ++lx) {
                    const size_t idx = lx + ly * kCS + lz * kCS * kCS;
                    const uint8_t pal = chunk->cells[idx];
                    if (pal == 0) continue;
                    const int32_t cx = base_x + static_cast<int32_t>(lx);
                    const int32_t cy = base_y + static_cast<int32_t>(ly);
                    const int32_t cz = base_z + static_cast<int32_t>(lz);
                    if (!pred(cx, cy, cz, pal)) continue;
                    picked.push_back({cx, cy, cz});
                }
            }
        }
    }
    return picked;
}

void FloodSelectFromSeed(EditorContext& ctx, int32_t x, int32_t y, int32_t z) {
    const uint8_t target = ctx.document.grid.Get(x, y, z);
    if (target == 0) {
        ctx.selection.Clear();
        return;
    }
    auto cells = FloodCells(ctx.document.grid, x, y, z, target);
    if (cells.empty()) {
        ctx.selection.Clear();
        return;
    }
    lift::LiftSelectionCells(ctx, cells);
}

void RotateSelection(EditorContext& ctx, Axis axis, bool cw) {
    lift::RotateLift(ctx, axis, cw);
}

void FlipSelection(EditorContext& ctx, Axis axis) {
    lift::FlipLift(ctx, axis);
}

}  // namespace macvoxel
