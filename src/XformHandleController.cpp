#include "XformHandleController.h"

#include "EditorContext.h"
#include "FloatingBuffer.h"
#include "FloatingBufferOps.h"
#include "Input.h"
#include "OverlayDraw.h"
#include "ViewContext.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <cmath>
#include <simd/simd.h>

namespace macvoxel::xform_handle_controller {
namespace {

// Face index 0..5 → (axis, sign). axis = face/2 (0=X, 1=Y, 2=Z),
// sign = (face&1) ? +1 : -1. Same convention as GeneratorController
// and ViewContext's internal helper.
inline void FaceAxisSign(int face, int* axis, int* sign) {
    *axis = face / 2;
    *sign = (face & 1) ? +1 : -1;
}

// World-space face center + outward normal for a Bounds3 (the
// floating buffer's bounds + offset). R = (gx, gz, -gy) matches the
// renderer's grid → world rotation. Voxels span [c, c+1] so the
// +face surface sits at coord+1 and the -face at coord.
void FaceWorldGeom(const Bounds3& b, int face,
                   simd::float3* out_center, simd::float3* out_normal) {
    int axis, sign;
    FaceAxisSign(face, &axis, &sign);
    auto mid = [](int32_t lo, int32_t hi) {
        return (static_cast<float>(lo) + static_cast<float>(hi) + 1.0f) * 0.5f;
    };
    const int32_t face_coord = (sign < 0)
        ? (axis == 0 ? b.min_x : axis == 1 ? b.min_y : b.min_z)
        : ((axis == 0 ? b.max_x : axis == 1 ? b.max_y : b.max_z) + 1);
    float gx, gy, gz;
    if (axis == 0) {
        gx = static_cast<float>(face_coord);
        gy = mid(b.min_y, b.max_y);
        gz = mid(b.min_z, b.max_z);
    } else if (axis == 1) {
        gx = mid(b.min_x, b.max_x);
        gy = static_cast<float>(face_coord);
        gz = mid(b.min_z, b.max_z);
    } else {
        gx = mid(b.min_x, b.max_x);
        gy = mid(b.min_y, b.max_y);
        gz = static_cast<float>(face_coord);
    }
    *out_center = simd::float3{gx, gz, -gy};
    simd::float3 n_grid{0.0f, 0.0f, 0.0f};
    if (axis == 0) n_grid.x = static_cast<float>(sign);
    else if (axis == 1) n_grid.y = static_cast<float>(sign);
    else                n_grid.z = static_cast<float>(sign);
    *out_normal = simd::float3{n_grid.x, n_grid.z, -n_grid.y};
}

}  // namespace

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    const int face = vc.PickXformHandle(e.local.x, e.local.y);
    if (face < 0) return false;

    FloatingBuffer& fb = ctx.floating_buffer;
    if (!fb.active) {
        LiftSelectionToFloating(ctx);
        if (!fb.active || fb.grid.empty()) return false;
    }

    state.xform.drag_face = face;
    state.xform.drag_start_local = e.local;
    state.xform.drag_start_bounds = fb.grid.Bounds();
    state.xform.orig_grid = fb.grid.Clone();
    state.drag_mode = DragMode::XformHandle;
    return true;
}

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    const int face = state.xform.drag_face;
    const int delta = vc.XformHandleDragVoxels(
        face, e.local.x, e.local.y,
        state.xform.drag_start_local.x,
        state.xform.drag_start_local.y,
        state.xform.drag_start_bounds);

    int axis, sign;
    FaceAxisSign(face, &axis, &sign);
    Bounds3 nb = state.xform.drag_start_bounds;
    if (axis == 0) {
        if (sign < 0) nb.min_x = std::min(nb.max_x, nb.min_x - delta);
        else          nb.max_x = std::max(nb.min_x, nb.max_x + delta);
    } else if (axis == 1) {
        if (sign < 0) nb.min_y = std::min(nb.max_y, nb.min_y - delta);
        else          nb.max_y = std::max(nb.min_y, nb.max_y + delta);
    } else {
        if (sign < 0) nb.min_z = std::min(nb.max_z, nb.min_z - delta);
        else          nb.max_z = std::max(nb.min_z, nb.max_z + delta);
    }
    ResampleFloatingBuffer(ctx, state.xform.orig_grid,
                           state.xform.drag_start_bounds, nb);
    ++ctx.floating_buffer.version;
}

void OnMouseUp(InteractionState& state) {
    state.xform.drag_face = -1;
    state.xform.orig_grid.Clear();
}

void DrawOverlay(const InteractionState& state, const ViewContext& vc,
                 OverlayDraw& od, bool mouse_captured_by_ui) {
    Bounds3 wb;
    if (!vc.XformGizmoBounds(&wb)) return;
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

    int hover_face = -1;
    if (state.drag_mode == DragMode::XformHandle) {
        hover_face = state.xform.drag_face;
    } else if (state.hover.has_point && !mouse_captured_by_ui) {
        hover_face = vc.PickXformHandle(state.hover.local.x,
                                        state.hover.local.y);
    }

    constexpr float kTipLengthVoxels = 4.0f;
    constexpr float kArrowheadLenPx = 14.0f;
    constexpr float kArrowheadHalfWidthPx = 7.0f;
    // Same X/Y/Z = red/green/blue palette as the generator gizmo so
    // axis colour reads consistently across the editor.
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
        FaceWorldGeom(wb, f, &cw, &nw);
        simd::float2 base, tip;
        bool base_v, tip_v;
        project(cw, &base, &base_v);
        project(cw + nw * kTipLengthVoxels, &tip, &tip_v);
        if (!base_v || !tip_v) continue;

        const int axis = f / 2;
        const uint32_t color =
            (state.drag_mode == DragMode::XformHandle && f == state.xform.drag_face)
                ? kAxisActive[axis]
            : (f == hover_face) ? kAxisHover[axis]
                                : kAxisBase[axis];
        const float thickness =
            (f == hover_face ||
             (state.drag_mode == DragMode::XformHandle && f == state.xform.drag_face))
                ? 2.8f : 2.0f;
        od.AddLine(base, tip, color, thickness);

        const float stem_dx = tip.x - base.x;
        const float stem_dy = tip.y - base.y;
        const float stem_len = std::sqrt(stem_dx * stem_dx +
                                         stem_dy * stem_dy);
        if (stem_len > 1e-3f) {
            const float ux = stem_dx / stem_len;
            const float uy = stem_dy / stem_len;
            const float pxn = -uy;
            const float pyn =  ux;
            const simd::float2 back{
                tip.x - ux * kArrowheadLenPx,
                tip.y - uy * kArrowheadLenPx};
            const simd::float2 leg1{
                back.x + pxn * kArrowheadHalfWidthPx,
                back.y + pyn * kArrowheadHalfWidthPx};
            const simd::float2 leg2{
                back.x - pxn * kArrowheadHalfWidthPx,
                back.y - pyn * kArrowheadHalfWidthPx};
            od.AddTriangleFilled(tip, leg1, leg2, color);
        }
    }
}

}  // namespace macvoxel::xform_handle_controller
