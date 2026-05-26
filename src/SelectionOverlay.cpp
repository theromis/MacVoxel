#include "SelectionOverlay.h"

#include <cstdint>

#include <simd/simd.h>

#include "Camera.h"
#include "EditorContext.h"
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
    if (!sel.active() || sel.bounds().empty()) return;

    const float w = vc.viewport_w;
    const float h = vc.viewport_h;
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();

    // Bbox outline only. Selection contents live in tex_lift (lift
    // mode) and get their tint from the rasterizer's lift composite;
    // box-mode preview during the marquee drag draws the wire here.
    const Bounds3 b = sel.bounds();
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
    // Brush and Mutator render a ghost-alpha preview of the exact cells
    // they'll write; a separate cursor wire would just duplicate that.
    // Two-click tools have no per-cursor preview yet, so they still get
    // the wire as a target indicator.
    const bool is_two_click = (t.tool == ToolKind::Line ||
                               t.tool == ToolKind::Circle ||
                               t.tool == ToolKind::Square ||
                               t.tool == ToolKind::Box ||
                               t.tool == ToolKind::Generator);
    if (!is_two_click) return;

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
    if (!vc.ComputeLineEndpoint(lp.x, lp.y, t.mode, &cell, nullptr)) return;
    DrawCellWire(cell.x, cell.y, cell.z,
                 color_for_mode(t.mode), 1.5f, vc, od);
}

}  // namespace macvoxel::selection_overlay
