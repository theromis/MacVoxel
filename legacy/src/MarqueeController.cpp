#include "MarqueeController.h"

#include "EditorContext.h"
#include "Input.h"
#include "OverlayDraw.h"
#include "Selection.h"
#include "SelectionLift.h"
#include "SelectionOps.h"
#include "ViewContext.h"

#include <algorithm>
#include <simd/simd.h>

namespace macvoxel::marquee_controller {

void OnMouseDown(InteractionState& state, const MouseEvent& e) {
    state.drag_mode = DragMode::Marquee;
    state.marquee.anchor_local = e.local;
    state.marquee.current_local = e.local;
}

void OnMouseDragged(InteractionState::MarqueeDrag& m, const MouseEvent& e) {
    m.current_local = e.local;
}

void OnMouseUp(EditorContext& ctx,
               InteractionState::MarqueeDrag& m,
               const ViewContext& vc,
               const MouseEvent& e) {
    m.current_local = e.local;

    if (vc.viewport_w <= 0.0f || vc.viewport_h <= 0.0f) return;

    const float rx_min = std::min(m.anchor_local.x, m.current_local.x);
    const float rx_max = std::max(m.anchor_local.x, m.current_local.x);
    const float ry_min = std::min(m.anchor_local.y, m.current_local.y);
    const float ry_max = std::max(m.anchor_local.y, m.current_local.y);

    // A click without meaningful drag is a click into empty space —
    // treat as a clear-selection gesture so the user has a way back to
    // no-selection without a tool switch.
    if ((rx_max - rx_min) < 2.0f && (ry_max - ry_min) < 2.0f) {
        ctx.selection.Clear();
        return;
    }

    const float aspect = vc.viewport_w / vc.viewport_h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();
    const float vw = vc.viewport_w;
    const float vh = vc.viewport_h;

    auto cells = EnumerateCellsWhere(ctx, [&](int32_t cx, int32_t cy, int32_t cz,
                                                uint8_t /*pal*/) {
        // Grid → world: R = (gx, gz, -gy) — same convention the
        // renderers and the wireframe overlay use.
        const float gx = static_cast<float>(cx) + 0.5f;
        const float gy = static_cast<float>(cy) + 0.5f;
        const float gz = static_cast<float>(cz) + 0.5f;
        const simd::float4 clip = simd_mul(
            vp, simd::float4{gx, gz, -gy, 1.0f});
        if (clip.w <= 1e-3f) return false;
        const float ndc_x = clip.x / clip.w;
        const float ndc_y = clip.y / clip.w;
        // View-local y is bottom-up — same convention the rect's
        // corners use, so a direct comparison is correct.
        const float sx = (ndc_x * 0.5f + 0.5f) * vw;
        const float sy = (ndc_y * 0.5f + 0.5f) * vh;
        return (sx >= rx_min && sx <= rx_max &&
                sy >= ry_min && sy <= ry_max);
    });
    if (cells.empty()) {
        ctx.selection.Clear();
        return;
    }
    lift::LiftSelectionCells(ctx, cells);
}

void DrawOverlay(const InteractionState& state, const ViewContext& vc,
                 OverlayDraw& od) {
    if (state.drag_mode != DragMode::Marquee) return;
    const float h = vc.viewport_h;
    if (h <= 0.0f) return;
    const simd::float2 a = state.marquee.anchor_local;
    const simd::float2 b = state.marquee.current_local;
    // Local y is bottom-up; the overlay renderer is top-down — flip
    // once on the way out so the marquee follows the cursor exactly.
    const simd::float2 tl{std::min(a.x, b.x), h - std::max(a.y, b.y)};
    const simd::float2 br{std::max(a.x, b.x), h - std::min(a.y, b.y)};
    od.AddRectFilled(tl, br, Rgba8(255, 220, 80, 28));
    od.AddRect(tl, br, Rgba8(255, 220, 80, 220), 1.0f);
}

}  // namespace macvoxel::marquee_controller
