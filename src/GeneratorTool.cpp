#include "GeneratorTool.h"

#include "BrushEngine.h"      // Bbox3
#include "Document.h"
#include "EditEngine.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "GeneratorState.h"
#include "Input.h"
#include "InteractionState.h"
#include "OverlayDraw.h"
#include "ShapeEngine.h"      // ShapeParams (commit kernel)
#include "ShapeTool.h"        // BeginShapeAnchor (shared with Shape)
#include "ViewContext.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace macvoxel {
namespace {

constexpr generators::Bounds3i kEmptyBounds{0, 0, 0, -1, -1, -1};

inline bool IsEmpty(generators::Bounds3i b) {
    return b.x1 < b.x0 || b.y1 < b.y0 || b.z1 < b.z0;
}

// Face index 0..5 → (axis, sign). Same convention every other gizmo
// uses; see XformHandleController and ViewContext for siblings.
inline void FaceAxisSign(int face, int* axis, int* sign) {
    *axis = face / 2;
    *sign = (face & 1) ? +1 : -1;
}

// World-space face center + outward normal for a Bounds3i.
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

}  // namespace

void GeneratorTool::ResetUnion() {
    union_x0_ = INT32_MAX; union_y0_ = INT32_MAX; union_z0_ = INT32_MAX;
    union_x1_ = INT32_MIN; union_y1_ = INT32_MIN; union_z1_ = INT32_MIN;
    last_bounds_dispatched_valid_ = false;
}

void GeneratorTool::ExtendUnion(generators::Bounds3i b) {
    if (IsEmpty(b)) return;
    if (union_x0_ == INT32_MAX) {
        union_x0_ = b.x0; union_y0_ = b.y0; union_z0_ = b.z0;
        union_x1_ = b.x1; union_y1_ = b.y1; union_z1_ = b.z1;
        return;
    }
    union_x0_ = std::min(union_x0_, b.x0);
    union_y0_ = std::min(union_y0_, b.y0);
    union_z0_ = std::min(union_z0_, b.z0);
    union_x1_ = std::max(union_x1_, b.x1);
    union_y1_ = std::max(union_y1_, b.y1);
    union_z1_ = std::max(union_z1_, b.z1);
}

// Dispatch the generator kernel into tex_t over the union of `bounds`
// and the previously-dispatched bounds. Updates the gesture's running
// union bbox + the dirty-check cache.
void GeneratorTool::Regenerate(EditorContext& ctx, InteractionState& /*state*/,
                               generators::Bounds3i bounds,
                               EditEngine& engine) {
    ctx.preview_active = true;

    generators::Params p = ctx.generator.params;
    p.palette_idx = ctx.tool.palette_idx;

    const generators::Bounds3i prev =
        last_bounds_dispatched_valid_ ? last_bounds_dispatched_ : kEmptyBounds;
    engine.Generate(ctx.generator.active_kind, bounds, prev, p);
    last_bounds_dispatched_ = bounds;
    last_bounds_dispatched_valid_ = true;
    ExtendUnion(bounds);

    bounds_ = bounds;
    last_kind_ = ctx.generator.active_kind;
    last_bounds_ = bounds;
    last_params_ = p;
}

bool GeneratorTool::OnMouseDown(EditorContext& ctx, InteractionState& state,
                                const ViewContext& vc, const MouseEvent& e,
                                EditEngine& engine) {
    // Two branches: gizmo already alive → handle-pick / commit-outside,
    // or no gizmo → BeginDragOut.
    if (active_) {
        const int face = vc.PickGenHandle(e.local.x, e.local.y, bounds_);
        if (face >= 0) {
            active_drag_face_ = face;
            handle_start_local_ = e.local;
            handle_start_bounds_ = bounds_;
            mouse_drag_ = Drag::HandleScale;
            state.drag_mode = DragMode::GenHandle;
        } else {
            Commit(ctx, state, engine);
            state.drag_mode = DragMode::None;
        }
        return true;
    }

    const ToolMode mode = e.mods.command ? ToolMode::Remove : ctx.tool.mode;
    if (!BeginShapeAnchor(ctx, state, vc, e, mode)) {
        return false;
    }
    state.drag_mode = DragMode::Shape;
    mouse_drag_ = Drag::DragOut;
    const generators::Bounds3i b{
        state.anchor.cell.x, state.anchor.cell.y, state.anchor.cell.z,
        state.anchor.cell.x, state.anchor.cell.y, state.anchor.cell.z,
    };
    active_ = true;
    state.gen_gizmo.active = true;  // mirrored for SelectionOverlay
    ResetUnion();
    ctx.history.BeginOp();
    Regenerate(ctx, state, b, engine);
    return true;
}

void GeneratorTool::OnMouseDragged(EditorContext& ctx, InteractionState& state,
                                    const ViewContext& vc, const MouseEvent& e,
                                    EditEngine& engine) {
    if (mouse_drag_ == Drag::DragOut) {
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
        Regenerate(ctx, state, b, engine);
        return;
    }
    if (mouse_drag_ == Drag::HandleScale) {
        const int face = active_drag_face_;
        const int delta = vc.GenHandleDragVoxels(
            face, e.local.x, e.local.y,
            handle_start_local_.x, handle_start_local_.y,
            handle_start_bounds_);
        int axis, sign;
        FaceAxisSign(face, &axis, &sign);
        generators::Bounds3i b = handle_start_bounds_;
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
        bounds_ = b;
        // Tick's dirty check picks up the bounds change next frame and
        // re-runs the engine — no inline dispatch here.
    }
}

void GeneratorTool::OnMouseUp(EditorContext& /*ctx*/, InteractionState& state,
                               const ViewContext& /*vc*/, const MouseEvent& /*e*/,
                               EditEngine& /*engine*/) {
    if (mouse_drag_ == Drag::DragOut) {
        // Drop the anchor — gizmo stays alive until Commit / Cancel.
        state.anchor.has_anchor = false;
    } else if (mouse_drag_ == Drag::HandleScale) {
        active_drag_face_ = -1;
    }
    mouse_drag_ = Drag::None;
}

void GeneratorTool::Tick(EditorContext& ctx, InteractionState& state,
                         ToolKind active_tool, bool escape_pressed,
                         EditEngine& engine) {
    if (!active_) return;

    if (active_tool != ToolKind::Generator || escape_pressed) {
        Cancel(ctx, state, engine);
        return;
    }

    // Dirty check: bounds (memcmp-safe — Bounds3i is a POD), kind,
    // palette, and the per-kind params we care about. Param changes
    // flow in from the panel UI.
    const auto& gs = ctx.generator;
    const uint8_t cur_palette = ctx.tool.palette_idx;
    const bool dirty =
        gs.active_kind != last_kind_ ||
        std::memcmp(&bounds_, &last_bounds_, sizeof(bounds_)) != 0 ||
        cur_palette != last_params_.palette_idx ||
        gs.params.axis != last_params_.axis ||
        gs.params.apex_at_max != last_params_.apex_at_max ||
        gs.params.noise_scale != last_params_.noise_scale ||
        gs.params.noise_threshold != last_params_.noise_threshold ||
        gs.params.noise_octaves != last_params_.noise_octaves ||
        gs.params.noise_seed != last_params_.noise_seed ||
        gs.params.torus_tube != last_params_.torus_tube ||
        gs.params.perlin_palette_lo != last_params_.perlin_palette_lo ||
        gs.params.perlin_palette_hi != last_params_.perlin_palette_hi;
    if (!dirty) return;

    Regenerate(ctx, state, bounds_, engine);
}

void GeneratorTool::Commit(EditorContext& ctx, InteractionState& state,
                           EditEngine& engine) {
    if (!active_) return;
    Document& doc = ctx.document;
    const EditVolume& vol = doc.volume;
    if (union_x0_ != INT32_MAX) {
        Bbox3 bb{};
        bb.x0 = std::max(union_x0_, vol.x0);
        bb.y0 = std::max(union_y0_, vol.y0);
        bb.z0 = std::max(union_z0_, vol.z0);
        bb.x1 = std::min(union_x1_, vol.x1);
        bb.y1 = std::min(union_y1_, vol.y1);
        bb.z1 = std::min(union_z1_, vol.z1);
        if (bb.x0 <= bb.x1 && bb.y0 <= bb.y1 && bb.z0 <= bb.z1) {
            CommitGenericParams cp{};
            cp.dispatch_lo_x = bb.x0 - vol.x0;
            cp.dispatch_lo_y = bb.y0 - vol.y0;
            cp.dispatch_lo_z = bb.z0 - vol.z0;
            cp.dispatch_size_x = bb.x1 - bb.x0 + 1;
            cp.dispatch_size_y = bb.y1 - bb.y0 + 1;
            cp.dispatch_size_z = bb.z1 - bb.z0 + 1;
            cp.bm = static_cast<uint32_t>(state.anchor.mode) + 1u;
            cp.brush = 0u;  // source = tex_t (preview)
            cp.fill_palette = ctx.tool.palette_idx;
            engine.CommitGeneric(cp);

            std::vector<uint8_t> post;
            engine.Readback(bb, &post);
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
    active_ = false;
    state.gen_gizmo.active = false;  // mirrored for SelectionOverlay
    active_drag_face_ = -1;
    mouse_drag_ = Drag::None;
    ResetUnion();
}

void GeneratorTool::Cancel(EditorContext& ctx, InteractionState& state,
                           EditEngine& engine) {
    if (!active_) return;
    // Dispatch with empty bounds + last dispatched bounds → kernel zeros
    // every cell in the previous bbox (no shape cells fill).
    if (last_bounds_dispatched_valid_) {
        generators::Params p = ctx.generator.params;
        p.palette_idx = ctx.tool.palette_idx;
        engine.Generate(ctx.generator.active_kind, kEmptyBounds,
                        last_bounds_dispatched_, p);
    }
    ctx.history.AbandonOp();
    ctx.preview_active = false;
    active_ = false;
    state.gen_gizmo.active = false;  // mirrored for SelectionOverlay
    active_drag_face_ = -1;
    mouse_drag_ = Drag::None;
    ResetUnion();
    if (state.drag_mode == DragMode::GenHandle) {
        state.drag_mode = DragMode::None;
    }
}

void GeneratorTool::DrawOverlay(const InteractionState& state,
                                 const ViewContext& vc,
                                 OverlayDraw& od,
                                 bool mouse_captured_by_ui) const {
    if (!active_) return;
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

    const float bx0 = static_cast<float>(bounds_.x0);
    const float by0 = static_cast<float>(bounds_.y0);
    const float bz0 = static_cast<float>(bounds_.z0);
    const float bx1 = static_cast<float>(bounds_.x1 + 1);
    const float by1 = static_cast<float>(bounds_.y1 + 1);
    const float bz1 = static_cast<float>(bounds_.z1 + 1);
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

    int hover_face = -1;
    if (state.drag_mode == DragMode::GenHandle) {
        hover_face = active_drag_face_;
    } else if (state.hover.has_point && !mouse_captured_by_ui) {
        hover_face = vc.PickGenHandle(state.hover.local.x, state.hover.local.y,
                                      bounds_);
    }

    constexpr float kTipLengthVoxels = 4.0f;
    constexpr float kArrowheadLenPx = 14.0f;
    constexpr float kArrowheadHalfWidthPx = 7.0f;
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
        FaceWorldGeom(bounds_, f, &cw, &nw);
        simd::float2 base, tip;
        bool base_v, tip_v;
        project(cw, &base, &base_v);
        project(cw + nw * kTipLengthVoxels, &tip, &tip_v);
        if (!base_v || !tip_v) continue;

        const int axis = f / 2;
        const uint32_t color =
            (f == active_drag_face_) ? kAxisActive[axis] :
            (f == hover_face)        ? kAxisHover[axis]  :
                                       kAxisBase[axis];
        const float thickness =
            (f == hover_face || f == active_drag_face_) ? 2.8f : 2.0f;
        od.AddLine(base, tip, color, thickness);

        const float stem_dx = tip.x - base.x;
        const float stem_dy = tip.y - base.y;
        const float stem_len = std::sqrt(stem_dx * stem_dx + stem_dy * stem_dy);
        if (stem_len > 1e-3f) {
            const float ux = stem_dx / stem_len;
            const float uy = stem_dy / stem_len;
            const float px = -uy;
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

}  // namespace macvoxel
