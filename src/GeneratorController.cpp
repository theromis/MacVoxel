#include "GeneratorController.h"

#include "BrushOps.h"
#include "Document.h"
#include "EditorContext.h"
#include "GeneratorState.h"
#include "Input.h"
#include "OverlayDraw.h"
#include "PreviewOps.h"
#include "PreviewOverlay.h"
#include "ShapeController.h"
#include "ViewContext.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <simd/simd.h>

namespace macvoxel::generator_controller {
namespace {

// Face index 0..5 → (axis, sign). Same convention every other gizmo
// uses; see XformHandleController and ViewContext for siblings.
inline void FaceAxisSign(int face, int* axis, int* sign) {
    *axis = face / 2;
    *sign = (face & 1) ? +1 : -1;
}

// World-space face center + outward normal for a Bounds3i (the
// generator gizmo's AABB). Voxels span [c, c+1] so the +face surface
// sits at coord+1 and the -face at coord. R = (gx, gz, -gy) matches
// the renderer's grid → world rotation.
void FaceWorldGeom(const generators::Bounds3i& b, int face,
                   simd::float3* out_center, simd::float3* out_normal) {
    int axis, sign;
    FaceAxisSign(face, &axis, &sign);
    auto mid = [](int32_t a, int32_t b1) {
        return (static_cast<float>(a) + static_cast<float>(b1) + 1.0f) * 0.5f;
    };
    const int32_t face_coord = (sign < 0)
        ? (axis == 0 ? b.x0 : axis == 1 ? b.y0 : b.z0)
        : ((axis == 0 ? b.x1 : axis == 1 ? b.y1 : b.z1) + 1);
    float gx, gy, gz;
    if (axis == 0) {
        gx = static_cast<float>(face_coord);
        gy = mid(b.y0, b.y1);
        gz = mid(b.z0, b.z1);
    } else if (axis == 1) {
        gx = mid(b.x0, b.x1);
        gy = static_cast<float>(face_coord);
        gz = mid(b.z0, b.z1);
    } else {
        gx = mid(b.x0, b.x1);
        gy = mid(b.y0, b.y1);
        gz = static_cast<float>(face_coord);
    }
    *out_center = simd::float3{gx, gz, -gy};
    simd::float3 n_grid{0, 0, 0};
    if (axis == 0) n_grid.x = static_cast<float>(sign);
    else if (axis == 1) n_grid.y = static_cast<float>(sign);
    else                n_grid.z = static_cast<float>(sign);
    *out_normal = simd::float3{n_grid.x, n_grid.z, -n_grid.y};
}

// Single-cell stamp pipeline. Each cell from the engine is "fill this
// exact cell" — brush size / shape / 2D / 3D options must NOT apply
// (the kernel already produced the final cell list). Stages into
// PreviewOverlay; Commit / Cancel close the gesture.
void StampCellsToOverlay(EditorContext& ctx,
                         const std::vector<shapes::Vec3i>& cells,
                         ToolMode mode) {
    if (cells.empty()) return;
    Document& doc = ctx.document;
    const uint8_t palette_idx = ctx.tool.palette_idx;
    PreviewOverlay& overlay = ctx.preview;
    for (const auto& c : cells) {
        const uint8_t old_val = doc.grid.Get(c.x, c.y, c.z);
        const uint8_t new_val = ComputeNewCellValue(old_val, mode, palette_idx);
        if (new_val != 0 && old_val == 0 &&
            !doc.volume.Contains(c.x, c.y, c.z)) continue;
        overlay.Stamp(c.x, c.y, c.z, new_val, old_val);
    }
    ++overlay.version;
}

// Run the engine for `bounds` + the live params/kind, stamp the
// resulting cells through the overlay, and sync the gen_gizmo cache
// fields so DrawOverlay sees the new bounds and Tick's change
// detector doesn't redundantly re-fire next frame.
void RegenerateAndStamp(EditorContext& ctx, InteractionState& state,
                        generators::Bounds3i bounds, ToolMode mode,
                        const GenerateFn& generate) {
    PreviewOverlay& overlay = ctx.preview;
    overlay.Clear();
    overlay.active = true;

    generators::Params p = ctx.generator.params;
    p.palette_idx = ctx.tool.palette_idx;
    std::vector<shapes::Vec3i> cells;
    generate(ctx.generator.active_kind, bounds, p, cells);
    StampCellsToOverlay(ctx, cells, mode);

    state.gen_gizmo.bounds = bounds;
    state.gen_gizmo.last_kind = ctx.generator.active_kind;
    state.gen_gizmo.last_bounds = bounds;
    state.gen_gizmo.last_params = p;
}

}  // namespace

bool BeginDragOut(EditorContext& ctx, InteractionState& state,
                  const ViewContext& vc, const MouseEvent& e,
                  const GenerateFn& generate) {
    const ToolMode mode = e.mods.command ? ToolMode::Remove : ctx.tool.mode;
    if (!shape_controller::BeginAnchor(ctx, state, vc, e, mode)) {
        return false;
    }
    state.drag_mode = DragMode::Shape;
    const generators::Bounds3i b{
        state.anchor.cell.x, state.anchor.cell.y, state.anchor.cell.z,
        state.anchor.cell.x, state.anchor.cell.y, state.anchor.cell.z,
    };
    state.gen_gizmo.active = true;
    RegenerateAndStamp(ctx, state, b, state.anchor.mode, generate);
    return true;
}

void UpdateDragOut(EditorContext& ctx, InteractionState& state,
                   const ViewContext& vc, const MouseEvent& e,
                   const GenerateFn& generate) {
    if (!state.anchor.has_anchor) return;

    shapes::Vec3i endpoint = state.anchor.cell;
    int end_face = state.anchor.face_axis;
    vc.ComputeLineEndpoint(e.local.x, e.local.y, state.anchor.mode,
                           &endpoint, &end_face);
    const generators::Bounds3i b{
        std::min(state.anchor.cell.x, endpoint.x),
        std::min(state.anchor.cell.y, endpoint.y),
        std::min(state.anchor.cell.z, endpoint.z),
        std::max(state.anchor.cell.x, endpoint.x),
        std::max(state.anchor.cell.y, endpoint.y),
        std::max(state.anchor.cell.z, endpoint.z),
    };
    RegenerateAndStamp(ctx, state, b, state.anchor.mode, generate);
}

void EndDragOut(InteractionState& state) {
    state.anchor.has_anchor = false;
}

void OnGizmoClick(EditorContext& ctx, InteractionState& state,
                  const ViewContext& vc, const MouseEvent& e) {
    const int face = vc.PickGenHandle(e.local.x, e.local.y,
                                      state.gen_gizmo.bounds);
    if (face >= 0) {
        state.gen_gizmo.active_drag_face = face;
        state.gen_gizmo.handle_start_local = e.local;
        state.gen_gizmo.handle_start_bounds = state.gen_gizmo.bounds;
        state.drag_mode = DragMode::GenHandle;
    } else {
        Commit(ctx, state);
        state.drag_mode = DragMode::None;
    }
}

void UpdateHandleDrag(InteractionState& state,
                      const ViewContext& vc, const MouseEvent& e) {
    const int face = state.gen_gizmo.active_drag_face;
    const int delta = vc.GenHandleDragVoxels(
        face, e.local.x, e.local.y,
        state.gen_gizmo.handle_start_local.x,
        state.gen_gizmo.handle_start_local.y,
        state.gen_gizmo.handle_start_bounds);

    int axis, sign;
    FaceAxisSign(face, &axis, &sign);
    generators::Bounds3i b = state.gen_gizmo.handle_start_bounds;
    if (axis == 0) {
        if (sign < 0) b.x0 = std::min(b.x1, b.x0 - delta);
        else          b.x1 = std::max(b.x0, b.x1 + delta);
    } else if (axis == 1) {
        if (sign < 0) b.y0 = std::min(b.y1, b.y0 - delta);
        else          b.y1 = std::max(b.y0, b.y1 + delta);
    } else {
        if (sign < 0) b.z0 = std::min(b.z1, b.z0 - delta);
        else          b.z1 = std::max(b.z0, b.z1 + delta);
    }
    state.gen_gizmo.bounds = b;
    // The per-frame Tick's dirty check picks up the bounds change and
    // re-runs the engine — no need to do it inline here.
}

void EndHandleDrag(InteractionState& state) {
    state.gen_gizmo.active_drag_face = -1;
}

void Tick(EditorContext& ctx, InteractionState& state,
          ToolKind active_tool, bool escape_pressed,
          const GenerateFn& generate) {
    if (!state.gen_gizmo.active) return;

    if (active_tool != ToolKind::Generator || escape_pressed) {
        Cancel(ctx, state);
        return;
    }

    // Dirty check: bounds (memcmp-safe — Bounds3i is a POD), kind,
    // palette, and the per-kind params we care about (axis,
    // apex_at_max). Param changes flow in from the panel UI.
    const auto& gs = ctx.generator;
    const uint8_t cur_palette = ctx.tool.palette_idx;
    const bool dirty =
        gs.active_kind != state.gen_gizmo.last_kind ||
        std::memcmp(&state.gen_gizmo.bounds, &state.gen_gizmo.last_bounds,
                    sizeof(state.gen_gizmo.bounds)) != 0 ||
        cur_palette != state.gen_gizmo.last_params.palette_idx ||
        gs.params.axis != state.gen_gizmo.last_params.axis ||
        gs.params.apex_at_max != state.gen_gizmo.last_params.apex_at_max;
    if (!dirty) return;

    RegenerateAndStamp(ctx, state, state.gen_gizmo.bounds,
                       ctx.tool.mode, generate);
}

void Commit(EditorContext& ctx, InteractionState& state) {
    if (!state.gen_gizmo.active) return;
    CommitPreviewOverlayThroughHistory(ctx);
    state.gen_gizmo.active = false;
}

void Cancel(EditorContext& ctx, InteractionState& state) {
    if (!state.gen_gizmo.active) return;
    ctx.preview.Clear();
    state.gen_gizmo.active = false;
    state.gen_gizmo.active_drag_face = -1;
    if (state.drag_mode == DragMode::GenHandle) {
        state.drag_mode = DragMode::None;
    }
}

void DrawOverlay(const InteractionState& state, const ViewContext& vc,
                 OverlayDraw& od, bool mouse_captured_by_ui) {
    if (!state.gen_gizmo.active) return;
    const float w = vc.viewport_w;
    const float h = vc.viewport_h;
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();

    auto project = [&](simd::float3 wpos, simd::float2* screen, bool* valid) {
        const simd::float4 clip =
            simd_mul(vp, simd::float4{wpos.x, wpos.y, wpos.z, 1.0f});
        *valid = clip.w > 0.001f;
        if (!*valid) return;
        const float ndc_x = clip.x / clip.w;
        const float ndc_y = clip.y / clip.w;
        screen->x = (ndc_x * 0.5f + 0.5f) * w;
        screen->y = (1.0f - (ndc_y * 0.5f + 0.5f)) * h;
    };

    // Box outline. Voxels span [c, c+1] so outer surfaces sit at
    // min..max+1.
    const float bx0 = static_cast<float>(state.gen_gizmo.bounds.x0);
    const float by0 = static_cast<float>(state.gen_gizmo.bounds.y0);
    const float bz0 = static_cast<float>(state.gen_gizmo.bounds.z0);
    const float bx1 = static_cast<float>(state.gen_gizmo.bounds.x1 + 1);
    const float by1 = static_cast<float>(state.gen_gizmo.bounds.y1 + 1);
    const float bz1 = static_cast<float>(state.gen_gizmo.bounds.z1 + 1);
    const simd::float3 corners_grid[8] = {
        {bx0, by0, bz0}, {bx1, by0, bz0},
        {bx1, by1, bz0}, {bx0, by1, bz0},
        {bx0, by0, bz1}, {bx1, by0, bz1},
        {bx1, by1, bz1}, {bx0, by1, bz1},
    };
    simd::float2 screen[8];
    bool valid[8];
    for (int i = 0; i < 8; ++i) {
        const simd::float3 g = corners_grid[i];
        project(simd::float3{g.x, g.z, -g.y}, &screen[i], &valid[i]);
    }
    static constexpr int kEdges[12][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 0},
        {4, 5}, {5, 6}, {6, 7}, {7, 4},
        {0, 4}, {1, 5}, {2, 6}, {3, 7},
    };
    const uint32_t outline_color = Rgba8(120, 200, 255, 230);
    for (int i = 0; i < 12; ++i) {
        const int a = kEdges[i][0];
        const int b = kEdges[i][1];
        if (!valid[a] || !valid[b]) continue;
        od.AddLine(screen[a], screen[b], outline_color, 1.5f);
    }

    // Hover face: derived per-frame from the cursor unless we're
    // already mid-drag (then the dragged face is the "hovered" one,
    // visually). When a panel has captured the mouse, suppress hover
    // so the cursor over a tooltip doesn't paint a handle hot.
    int hover_face = -1;
    if (state.drag_mode == DragMode::GenHandle) {
        hover_face = state.gen_gizmo.active_drag_face;
    } else if (state.hover.has_point && !mouse_captured_by_ui) {
        hover_face = vc.PickGenHandle(state.hover.local.x, state.hover.local.y,
                                      state.gen_gizmo.bounds);
    }

    constexpr float kTipLengthVoxels = 4.0f;
    constexpr float kArrowheadLenPx = 14.0f;
    constexpr float kArrowheadHalfWidthPx = 7.0f;
    // Standard X / Y / Z = red / green / blue, with brighter variants
    // for hover and active states. Both the +axis and -axis face share
    // their axis's colour — position on the box disambiguates direction.
    const uint32_t kAxisBase[3] = {
        Rgba8(230,  80,  80, 255),
        Rgba8( 90, 200, 100, 255),
        Rgba8( 90, 140, 240, 255),
    };
    const uint32_t kAxisHover[3] = {
        Rgba8(255, 160, 160, 255),
        Rgba8(170, 250, 180, 255),
        Rgba8(160, 200, 255, 255),
    };
    const uint32_t kAxisActive[3] = {
        Rgba8(255, 220, 220, 255),
        Rgba8(220, 255, 230, 255),
        Rgba8(220, 240, 255, 255),
    };

    for (int f = 0; f < 6; ++f) {
        simd::float3 cw, nw;
        FaceWorldGeom(state.gen_gizmo.bounds, f, &cw, &nw);
        simd::float2 base, tip;
        bool base_v, tip_v;
        project(cw, &base, &base_v);
        project(cw + nw * kTipLengthVoxels, &tip, &tip_v);
        if (!base_v || !tip_v) continue;

        const int axis = f / 2;
        const uint32_t color =
            (f == state.gen_gizmo.active_drag_face) ? kAxisActive[axis] :
            (f == hover_face)                       ? kAxisHover[axis]  :
                                                      kAxisBase[axis];
        const float thickness =
            (f == hover_face || f == state.gen_gizmo.active_drag_face)
                ? 2.8f : 2.0f;
        od.AddLine(base, tip, color, thickness);

        // Solid filled-triangle arrowhead. Triangle base at `back`
        // (pulled back along the stem from the tip); leg1 / leg2 are
        // perpendicular offsets in screen space, so the arrowhead reads
        // at consistent pixel size regardless of camera distance.
        const float stem_dx = tip.x - base.x;
        const float stem_dy = tip.y - base.y;
        const float stem_len = std::sqrt(stem_dx * stem_dx +
                                         stem_dy * stem_dy);
        if (stem_len > 1e-3f) {
            const float ux = stem_dx / stem_len;
            const float uy = stem_dy / stem_len;
            const float px = -uy;   // perpendicular in screen space
            const float py =  ux;
            const simd::float2 back{
                tip.x - ux * kArrowheadLenPx,
                tip.y - uy * kArrowheadLenPx};
            const simd::float2 leg1{
                back.x + px * kArrowheadHalfWidthPx,
                back.y + py * kArrowheadHalfWidthPx};
            const simd::float2 leg2{
                back.x - px * kArrowheadHalfWidthPx,
                back.y - py * kArrowheadHalfWidthPx};
            od.AddTriangleFilled(tip, leg1, leg2, color);
        }
    }
}

}  // namespace macvoxel::generator_controller
