#include "SelectionOverlay.h"

#include <array>
#include <cstdint>
#include <unordered_set>
#include <vector>

#include <simd/simd.h>

#include "Camera.h"
#include "CellKey.h"
#include "EditorContext.h"
#include "FloatingBuffer.h"
#include "InteractionState.h"
#include "OverlayDraw.h"
#include "Selection.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "VoxelGrid.h"

namespace macvoxel::selection_overlay {
namespace {

// 12 edges of a unit cube as pairs of corner indices.
constexpr int kEdges[12][2] = {
    {0, 1}, {1, 2}, {2, 3}, {3, 0},
    {4, 5}, {5, 6}, {6, 7}, {7, 4},
    {0, 4}, {1, 5}, {2, 6}, {3, 7},
};

// Per-face edge order (4 edges per face) used by the silhouette
// wireframe. Order: +X, -X, +Y, -Y, +Z, -Z.
constexpr int kFaceEdges[6][4][2] = {
    {{1, 2}, {2, 6}, {6, 5}, {5, 1}},
    {{0, 3}, {3, 7}, {7, 4}, {4, 0}},
    {{3, 2}, {2, 6}, {6, 7}, {7, 3}},
    {{0, 1}, {1, 5}, {5, 4}, {4, 0}},
    {{4, 5}, {5, 6}, {6, 7}, {7, 4}},
    {{0, 1}, {1, 2}, {2, 3}, {3, 0}},
};

constexpr int kNeighbor[6][3] = {
    {+1, 0, 0}, {-1, 0, 0},
    {0, +1, 0}, {0, -1, 0},
    {0, 0, +1}, {0, 0, -1},
};

// Face outward normal in world space (after R = (gx, gz, -gy)):
// grid +X→world +X, grid +Y→world -Z, grid +Z→world +Y.
constexpr simd::float3 kFaceNormalWorld[6] = {
    { 1.0f,  0.0f,  0.0f},
    {-1.0f,  0.0f,  0.0f},
    { 0.0f,  0.0f, -1.0f},
    { 0.0f,  0.0f,  1.0f},
    { 0.0f,  1.0f,  0.0f},
    { 0.0f, -1.0f,  0.0f},
};

void ProjectCorners(simd::float3 gmin, simd::float3 gmax,
                    const simd::float4x4& vp, float w, float h,
                    simd::float2 screen[8], bool valid[8]) {
    const simd::float3 corners_grid[8] = {
        {gmin.x, gmin.y, gmin.z}, {gmax.x, gmin.y, gmin.z},
        {gmax.x, gmax.y, gmin.z}, {gmin.x, gmax.y, gmin.z},
        {gmin.x, gmin.y, gmax.z}, {gmax.x, gmin.y, gmax.z},
        {gmax.x, gmax.y, gmax.z}, {gmin.x, gmax.y, gmax.z},
    };
    for (int i = 0; i < 8; ++i) {
        const simd::float3 g = corners_grid[i];
        // R = (gx, gz, -gy): same rotation the renderer applies.
        const simd::float3 wpos{g.x, g.z, -g.y};
        const simd::float4 clip =
            simd_mul(vp, simd::float4{wpos.x, wpos.y, wpos.z, 1.0f});
        valid[i] = clip.w > 0.001f;
        if (valid[i]) {
            const float ndc_x = clip.x / clip.w;
            const float ndc_y = clip.y / clip.w;
            screen[i].x = (ndc_x * 0.5f + 0.5f) * w;
            screen[i].y = (1.0f - (ndc_y * 0.5f + 0.5f)) * h;
        }
    }
}

void StrokeEdges(const simd::float2 screen[8], const bool valid[8],
                 const int (*edges)[2], int n,
                 uint32_t color, float thickness, OverlayDraw& od) {
    for (int i = 0; i < n; ++i) {
        const int a = edges[i][0];
        const int b = edges[i][1];
        if (!valid[a] || !valid[b]) continue;
        od.AddLine(screen[a], screen[b], color, thickness);
    }
}

}  // namespace

void DrawCellWire(int cx, int cy, int cz, uint32_t color, float thickness,
                  const ViewContext& vc, OverlayDraw& od) {
    const float w = vc.viewport_w;
    const float h = vc.viewport_h;
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();

    const simd::float3 gmin{static_cast<float>(cx),
                            static_cast<float>(cy),
                            static_cast<float>(cz)};
    const simd::float3 gmax{gmin.x + 1.0f, gmin.y + 1.0f, gmin.z + 1.0f};
    simd::float2 screen[8];
    bool valid[8];
    ProjectCorners(gmin, gmax, vp, w, h, screen, valid);
    StrokeEdges(screen, valid, kEdges, 12, color, thickness, od);
}

void DrawSelection(const ViewContext& vc, OverlayDraw& od) {
    if (vc.ctx == nullptr) return;
    const EditorContext& ctx = *vc.ctx;
    const Selection& sel = ctx.selection;
    const FloatingBuffer& fb = ctx.floating_buffer;
    const bool show_doc_sel = sel.active() && !sel.bounds().empty();
    const bool show_floating = fb.active && !fb.grid.empty();
    if (!show_doc_sel && !show_floating) return;

    const float w = vc.viewport_w;
    const float h = vc.viewport_h;
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();

    // Outer AABB. Voxels span [c, c+1] so the outer faces are at
    // min..max+1. When the floating buffer is active, take its bounds
    // + offset; the doc-side selection bounds are stale during a drag
    // (we don't shift them per frame for performance reasons — the
    // whole point of FloatingBuffer is O(1) drag work).
    {
        Bounds3 b{};
        if (show_floating) {
            const Bounds3 gb = fb.grid.Bounds();
            b.min_x = gb.min_x + fb.offset_x;
            b.min_y = gb.min_y + fb.offset_y;
            b.min_z = gb.min_z + fb.offset_z;
            b.max_x = gb.max_x + fb.offset_x;
            b.max_y = gb.max_y + fb.offset_y;
            b.max_z = gb.max_z + fb.offset_z;
        } else {
            b = sel.bounds();
        }
        const simd::float3 box_min{static_cast<float>(b.min_x),
                                   static_cast<float>(b.min_y),
                                   static_cast<float>(b.min_z)};
        const simd::float3 box_max{static_cast<float>(b.max_x + 1),
                                   static_cast<float>(b.max_y + 1),
                                   static_cast<float>(b.max_z + 1)};
        simd::float2 screen[8];
        bool valid[8];
        ProjectCorners(box_min, box_max, vp, w, h, screen, valid);
        StrokeEdges(screen, valid, kEdges, 12,
                    Rgba8(255, 220, 80, 255), 1.5f, od);
    }

    // Per-voxel highlights for sparse selections. Two passes of
    // hidden-line removal keep the overlay legible for thousands of
    // voxels:
    //  1. Skip faces whose neighbor cell is also selected — internal
    //     boundaries collapse, leaving only the silhouette.
    //  2. Of those, skip back-facing faces so we don't double-stroke
    //     through the silhouette.
    //
    // Floating-buffer cell counts blow up faster than doc-side
    // marquee selections (a 256³ lift would do millions of cells'
    // worth of OverlayDraw work otherwise); cap there only.
    constexpr size_t kFloatingWireMax = 200000;

    const simd::float3 cam = vc.camera.Position();
    const uint32_t voxel_color = Rgba8(255, 220, 80, 200);

    std::vector<std::array<int32_t, 3>> cells;
    std::unordered_set<int64_t> selected_set;
    if (show_floating) {
        const size_t nfilled = static_cast<size_t>(fb.grid.FilledCount());
        if (nfilled == 0 || nfilled > kFloatingWireMax) return;
        cells.reserve(nfilled);
        selected_set.reserve(nfilled * 2);
        constexpr uint32_t kCS = VoxelGrid::kChunkSize;
        for (const auto& [coord, chunk] : fb.grid.chunks()) {
            if (chunk->filled_count == 0) continue;
            const int32_t base_x = coord.x * static_cast<int32_t>(kCS);
            const int32_t base_y = coord.y * static_cast<int32_t>(kCS);
            const int32_t base_z = coord.z * static_cast<int32_t>(kCS);
            for (uint32_t lz = 0; lz < kCS; ++lz)
            for (uint32_t ly = 0; ly < kCS; ++ly)
            for (uint32_t lx = 0; lx < kCS; ++lx) {
                const size_t idx = lx + ly * kCS + lz * kCS * kCS;
                if (chunk->cells[idx] == 0) continue;
                const int32_t cx = base_x + static_cast<int32_t>(lx)
                                   + fb.offset_x;
                const int32_t cy = base_y + static_cast<int32_t>(ly)
                                   + fb.offset_y;
                const int32_t cz = base_z + static_cast<int32_t>(lz)
                                   + fb.offset_z;
                cells.push_back({cx, cy, cz});
                selected_set.insert(PackCellKey(cx, cy, cz));
            }
        }
    } else {
        if (sel.empty()) return;
        cells.reserve(sel.size());
        selected_set.reserve(sel.size() * 2);
        for (const auto& v : sel.voxels()) {
            cells.push_back(v);
            selected_set.insert(PackCellKey(v[0], v[1], v[2]));
        }
    }

    for (const auto& v : cells) {
        const simd::float3 cmin{static_cast<float>(v[0]),
                                static_cast<float>(v[1]),
                                static_cast<float>(v[2])};
        const simd::float3 cmax{cmin.x + 1.0f, cmin.y + 1.0f, cmin.z + 1.0f};
        simd::float2 screen[8];
        bool valid[8];
        ProjectCorners(cmin, cmax, vp, w, h, screen, valid);
        const simd::float3 center_world{
            cmin.x + 0.5f, cmin.z + 0.5f, -(cmin.y + 0.5f)};
        for (int f = 0; f < 6; ++f) {
            if (selected_set.count(PackCellKey(
                    v[0] + kNeighbor[f][0],
                    v[1] + kNeighbor[f][1],
                    v[2] + kNeighbor[f][2]))) {
                continue;  // interior face
            }
            const simd::float3 to_cam = cam - center_world;
            if (simd_dot(to_cam, kFaceNormalWorld[f]) <= 0.0f) {
                continue;  // back-facing
            }
            StrokeEdges(screen, valid, kFaceEdges[f], 4,
                        voxel_color, 1.0f, od);
        }
    }
}

void DrawHover(const InteractionState& state, const ViewContext& vc,
               bool mouse_captured_by_ui, OverlayDraw& od) {
    if (!state.hover.has_point) return;
    if (state.drag_mode != DragMode::None) return;
    if (mouse_captured_by_ui) return;
    // Generator gizmo is the cursor indicator while it's live; the
    // would-place-cell wireframe would compete with it and read as a
    // stray duplicate.
    if (state.gen_gizmo_active) return;
    if (vc.ctx == nullptr) return;

    const ToolSettings& t = vc.ctx->tool;
    const bool is_brush = t.tool == ToolKind::Brush;
    const bool is_two_click = (t.tool == ToolKind::Line ||
                               t.tool == ToolKind::Circle ||
                               t.tool == ToolKind::Square ||
                               t.tool == ToolKind::Box ||
                               t.tool == ToolKind::Generator);
    if (!is_brush && !is_two_click) return;

    auto color_for_mode = [](ToolMode m) -> uint32_t {
        switch (m) {
            case ToolMode::Add:    return Rgba8(120, 230, 140, 220);
            case ToolMode::Remove: return Rgba8(240, 110, 110, 220);
            case ToolMode::Paint:  return Rgba8(120, 180, 240, 220);
        }
        return Rgba8(255, 255, 255, 220);
    };

    shapes::Vec3i cell;
    const simd::float2 lp = state.hover.local;
    const bool ok = is_two_click
        ? vc.ComputeLineEndpoint(lp.x, lp.y, t.mode, &cell, nullptr)
        : vc.ComputeTargetCell(lp.x, lp.y, t.mode, &cell, nullptr);
    if (!ok) return;
    DrawCellWire(cell.x, cell.y, cell.z,
                 color_for_mode(t.mode), 1.5f, vc, od);
}

}  // namespace macvoxel::selection_overlay
