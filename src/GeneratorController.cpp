#include "GeneratorController.h"

#include "BrushEngine.h"      // for Bbox3
#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "GeneratorState.h"
#include "Input.h"
#include "OverlayDraw.h"
#include "ShapeController.h"
#include "ShapeEngine.h"      // ShapeParams (for commit kernel)
#include "ViewContext.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <simd/simd.h>
#include <vector>

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

constexpr generators::Bounds3i kEmptyBounds{0, 0, 0, -1, -1, -1};

inline bool IsEmpty(generators::Bounds3i b) {
    return b.x1 < b.x0 || b.y1 < b.y0 || b.z1 < b.z0;
}

// Track the bbox of every dispatch made so far in this gesture, so
// OnMouseUp can blit exactly that region of tex_a back to CPU for the
// diff against shadow. gen_gizmo.last_bounds already records the
// previous dispatch (Tick reads it for dirty detection); we expand a
// union into gen_gizmo.{union_bounds_*} as the user drags.
void ExtendUnion(InteractionState& state, generators::Bounds3i b) {
    if (IsEmpty(b)) return;
    auto& g = state.gen_gizmo;
    if (g.union_bounds_x0 == INT32_MAX) {
        g.union_bounds_x0 = b.x0; g.union_bounds_y0 = b.y0;
        g.union_bounds_z0 = b.z0;
        g.union_bounds_x1 = b.x1; g.union_bounds_y1 = b.y1;
        g.union_bounds_z1 = b.z1;
        return;
    }
    g.union_bounds_x0 = std::min(g.union_bounds_x0, b.x0);
    g.union_bounds_y0 = std::min(g.union_bounds_y0, b.y0);
    g.union_bounds_z0 = std::min(g.union_bounds_z0, b.z0);
    g.union_bounds_x1 = std::max(g.union_bounds_x1, b.x1);
    g.union_bounds_y1 = std::max(g.union_bounds_y1, b.y1);
    g.union_bounds_z1 = std::max(g.union_bounds_z1, b.z1);
}

// Dispatch the generator kernel into tex_t. The kernel covers the
// union of `bounds` and the gen_gizmo's previously-dispatched bounds,
// so cells the old preview wrote that the new one doesn't cover get
// zeroed in the same dispatch. Sync gen_gizmo cache fields so
// DrawOverlay sees the new bounds and Tick's change detector doesn't
// redundantly re-fire next frame.
void Regenerate(EditorContext& ctx, InteractionState& state,
                generators::Bounds3i bounds,
                const GenerateFn& generate) {
    ctx.preview_active = true;

    generators::Params p = ctx.generator.params;
    p.palette_idx = ctx.tool.palette_idx;

    const generators::Bounds3i prev =
        state.gen_gizmo.last_bounds_dispatched_valid
            ? state.gen_gizmo.last_bounds_dispatched
            : kEmptyBounds;
    generate(ctx.generator.active_kind, bounds, prev, p);
    state.gen_gizmo.last_bounds_dispatched = bounds;
    state.gen_gizmo.last_bounds_dispatched_valid = true;
    ExtendUnion(state, bounds);

    state.gen_gizmo.bounds = bounds;
    state.gen_gizmo.last_kind = ctx.generator.active_kind;
    state.gen_gizmo.last_bounds = bounds;
    state.gen_gizmo.last_params = p;
}

void ResetUnion(InteractionState& state) {
    auto& g = state.gen_gizmo;
    g.union_bounds_x0 = INT32_MAX; g.union_bounds_y0 = INT32_MAX;
    g.union_bounds_z0 = INT32_MAX;
    g.union_bounds_x1 = INT32_MIN; g.union_bounds_y1 = INT32_MIN;
    g.union_bounds_z1 = INT32_MIN;
    g.last_bounds_dispatched_valid = false;
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
    ResetUnion(state);
    ctx.history.BeginOp();
    Regenerate(ctx, state, b, generate);
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
    Regenerate(ctx, state, b, generate);
}

void EndDragOut(InteractionState& state) {
    state.anchor.has_anchor = false;
}

void OnGizmoClick(EditorContext& ctx, InteractionState& state,
                  const ViewContext& vc, const MouseEvent& e,
                  const CommitFn& commit, const ReadBackFn& readback) {
    const int face = vc.PickGenHandle(e.local.x, e.local.y,
                                      state.gen_gizmo.bounds);
    if (face >= 0) {
        state.gen_gizmo.active_drag_face = face;
        state.gen_gizmo.handle_start_local = e.local;
        state.gen_gizmo.handle_start_bounds = state.gen_gizmo.bounds;
        state.drag_mode = DragMode::GenHandle;
    } else {
        Commit(ctx, state, commit, readback);
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
        Cancel(ctx, state, generate);
        return;
    }

    // Dirty check: bounds (memcmp-safe — Bounds3i is a POD), kind,
    // palette, and the per-kind params we care about. Param changes
    // flow in from the panel UI.
    const auto& gs = ctx.generator;
    const auto& last = state.gen_gizmo.last_params;
    const uint8_t cur_palette = ctx.tool.palette_idx;
    const bool dirty =
        gs.active_kind != state.gen_gizmo.last_kind ||
        std::memcmp(&state.gen_gizmo.bounds, &state.gen_gizmo.last_bounds,
                    sizeof(state.gen_gizmo.bounds)) != 0 ||
        cur_palette != last.palette_idx ||
        gs.params.axis != last.axis ||
        gs.params.apex_at_max != last.apex_at_max ||
        gs.params.noise_scale != last.noise_scale ||
        gs.params.noise_threshold != last.noise_threshold ||
        gs.params.noise_octaves != last.noise_octaves ||
        gs.params.noise_seed != last.noise_seed ||
        gs.params.torus_tube != last.torus_tube ||
        gs.params.perlin_palette_lo != last.perlin_palette_lo ||
        gs.params.perlin_palette_hi != last.perlin_palette_hi;
    if (!dirty) return;

    Regenerate(ctx, state, state.gen_gizmo.bounds, generate);
}

void Commit(EditorContext& ctx, InteractionState& state,
            const CommitFn& commit, const ReadBackFn& readback) {
    if (!state.gen_gizmo.active) return;
    const auto& g = state.gen_gizmo;
    Document& doc = ctx.document;
    const EditVolume& vol = doc.volume;
    if (g.union_bounds_x0 != INT32_MAX) {
        Bbox3 bb{};
        bb.x0 = std::max(g.union_bounds_x0, vol.x0);
        bb.y0 = std::max(g.union_bounds_y0, vol.y0);
        bb.z0 = std::max(g.union_bounds_z0, vol.z0);
        bb.x1 = std::min(g.union_bounds_x1, vol.x1);
        bb.y1 = std::min(g.union_bounds_y1, vol.y1);
        bb.z1 = std::min(g.union_bounds_z1, vol.z1);
        if (bb.x0 <= bb.x1 && bb.y0 <= bb.y1 && bb.z0 <= bb.z1) {
            ShapeParams cp{};
            cp.mode = static_cast<uint32_t>(state.anchor.mode);
            cp.palette_idx = ctx.tool.palette_idx;
            cp.dispatch_lo_x = bb.x0 - vol.x0;
            cp.dispatch_lo_y = bb.y0 - vol.y0;
            cp.dispatch_lo_z = bb.z0 - vol.z0;
            cp.dispatch_size_x = bb.x1 - bb.x0 + 1;
            cp.dispatch_size_y = bb.y1 - bb.y0 + 1;
            cp.dispatch_size_z = bb.z1 - bb.z0 + 1;
            cp.vol_min_x = vol.x0; cp.vol_min_y = vol.y0; cp.vol_min_z = vol.z0;
            cp.vol_max_x = vol.x1; cp.vol_max_y = vol.y1; cp.vol_max_z = vol.z1;
            cp.tex_origin_x = vol.x0; cp.tex_origin_y = vol.y0;
            cp.tex_origin_z = vol.z0;
            commit(cp);

            std::vector<uint8_t> post;
            readback(bb, &post);
            const size_t bw = static_cast<size_t>(bb.x1 - bb.x0 + 1);
            const size_t bh = static_cast<size_t>(bb.y1 - bb.y0 + 1);
            const size_t bd = static_cast<size_t>(bb.z1 - bb.z0 + 1);
            if (post.size() >= bw * bh * bd) {
                std::vector<CellChange> diff;
                diff.reserve(bw * bh);
                for (size_t lz = 0; lz < bd; ++lz) {
                    for (size_t ly = 0; ly < bh; ++ly) {
                        const size_t row_base = lz * bw * bh + ly * bw;
                        for (size_t lx = 0; lx < bw; ++lx) {
                            const int32_t x = bb.x0 + static_cast<int32_t>(lx);
                            const int32_t y = bb.y0 + static_cast<int32_t>(ly);
                            const int32_t z = bb.z0 + static_cast<int32_t>(lz);
                            const uint8_t pre = doc.volume_shadow.Get(x, y, z);
                            const uint8_t cur = post[row_base + lx];
                            if (pre == cur) continue;
                            CellChange c{};
                            c.x = x; c.y = y; c.z = z;
                            c.old_val = pre; c.new_val = cur;
                            diff.push_back(c);
                        }
                    }
                }
                if (!diff.empty()) {
                    doc.ApplyChanges(diff.data(), diff.size());
                    ctx.history.RecordBatch(diff.data(), diff.size());
                    (void)doc.volume_shadow.TakeDirtyChunks();
                    doc.BumpGeometry();
                }
            }
        }
    }

    ctx.history.CommitOp();
    ctx.preview_active = false;
    state.gen_gizmo.active = false;
    state.gen_gizmo.active_drag_face = -1;
    ResetUnion(state);
}

void Cancel(EditorContext& ctx, InteractionState& state,
            const GenerateFn& generate) {
    if (!state.gen_gizmo.active) return;
    // Dispatch with empty bounds + last dispatched bounds → kernel
    // zeros every cell in the previous bbox (no shape cells fill).
    if (state.gen_gizmo.last_bounds_dispatched_valid) {
        generators::Params p = ctx.generator.params;
        p.palette_idx = ctx.tool.palette_idx;
        generate(ctx.generator.active_kind, kEmptyBounds,
                 state.gen_gizmo.last_bounds_dispatched, p);
    }
    ctx.history.AbandonOp();
    ctx.preview_active = false;
    state.gen_gizmo.active = false;
    state.gen_gizmo.active_drag_face = -1;
    ResetUnion(state);
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
