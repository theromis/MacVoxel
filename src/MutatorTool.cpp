#include "MutatorTool.h"

#include "BrushEngine.h"   // Bbox3
#include "Document.h"
#include "EditEngine.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "Input.h"
#include "InteractionState.h"
#include "Camera.h"
#include "EditVolume.h"
#include "MutatorEngine.h"   // MutatorDispatchParams (pure C++ part)
#include "MutatorState.h"
#include "OverlayDraw.h"
#include "ShapeEngine.h"   // CommitGenericParams
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <cstdint>
#include <vector>

namespace macvoxel {
namespace {

constexpr shapes::Vec3i kInvalidCell{INT32_MIN, INT32_MIN, INT32_MIN};

inline bool SameCell(const shapes::Vec3i& a, const shapes::Vec3i& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

// Build the AOE bbox around the cursor cell, sized by the brush
// footprint. Matches BrushParams' lo/hi math so the visual AOE size
// is consistent with the brush footprint indicator.
void AoeBoundsFor(const EditorContext& ctx, const shapes::Vec3i& center,
                   int32_t* lo_x, int32_t* lo_y, int32_t* lo_z,
                   int32_t* hi_x, int32_t* hi_y, int32_t* hi_z) {
    const int size = std::max(1, ctx.tool.brush_size);
    const int lo = -((size - 1) / 2);
    const int hi = size / 2;
    *lo_x = center.x + lo;
    *lo_y = center.y + lo;
    *lo_z = center.z + lo;
    *hi_x = center.x + hi;
    *hi_y = center.y + hi;
    *hi_z = center.z + hi;
}

}  // namespace

uint32_t MutatorTool::s_stroke_counter_ = 1;

void MutatorTool::ResetStrokeState() {
    last_drag_edit_cell_ = kInvalidCell;
    last_face_axis_ = 2;
    stroke_bbox_x0_ = stroke_bbox_y0_ = stroke_bbox_z0_ = INT32_MAX;
    stroke_bbox_x1_ = stroke_bbox_y1_ = stroke_bbox_z1_ = INT32_MIN;
}

uint64_t MutatorTool::DispatchParamsHash(const EditorContext& ctx,
                                          const InteractionState& /*state*/,
                                          const ViewContext& vc,
                                          const MouseEvent& e) const {
    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeTargetCell(e.local.x, e.local.y, ToolMode::Add, &target,
                              &face_axis)) {
        // No pick — hash a sentinel that varies across kinds/params so
        // a recovered pick on the same cursor cell still re-fires.
        target = shapes::Vec3i{INT32_MIN, INT32_MIN, INT32_MIN};
    }
    const auto& ms = ctx.mutator;
    auto mix = [](uint64_t h, uint64_t v) {
        return h ^ (v + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
    };
    auto mix_f = [&](uint64_t h, float f) {
        union { float fv; uint32_t uv; } u{}; u.fv = f;
        return mix(h, u.uv);
    };
    uint64_t h = 0xcbf29ce484222325ULL;
    h = mix(h, static_cast<uint64_t>(stroke_id_));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(target.x)));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(target.y)));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(target.z)));
    h = mix(h, static_cast<uint64_t>(face_axis));
    h = mix(h, static_cast<uint64_t>(ms.active_kind));
    h = mix(h, static_cast<uint64_t>(ms.params.foliage.seed_color));
    h = mix_f(h, ms.params.foliage.density);
    h = mix(h, static_cast<uint64_t>(ctx.tool.brush_size));
    h = mix(h, static_cast<uint64_t>(ctx.tool.brush_shape));
    h = mix(h, static_cast<uint64_t>(ctx.tool.brush_3d ? 1u : 0u));
    return h | 1ULL;  // never 0 — 0 disables ShouldDispatch.
}

void MutatorTool::StampAtCursor(EditorContext& ctx, const ViewContext& vc,
                                 const MouseEvent& e, EditEngine& engine) {
    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeTargetCell(e.local.x, e.local.y, ToolMode::Add, &target,
                              &face_axis)) {
        return;
    }
    if (SameCell(target, last_drag_edit_cell_) &&
        face_axis == last_face_axis_) {
        // Cursor cell hasn't moved — ShouldDispatch already short-
        // circuits this branch, but keep the explicit guard so a
        // hash collision doesn't sneak a duplicate kernel through.
        return;
    }
    last_drag_edit_cell_ = target;
    last_face_axis_ = face_axis;

    int32_t lo_x, lo_y, lo_z, hi_x, hi_y, hi_z;
    AoeBoundsFor(ctx, target, &lo_x, &lo_y, &lo_z, &hi_x, &hi_y, &hi_z);

    MutatorDispatchParams p{};
    p.kind        = ctx.mutator.active_kind;
    p.aoe_x0 = lo_x; p.aoe_y0 = lo_y; p.aoe_z0 = lo_z;
    p.aoe_x1 = hi_x; p.aoe_y1 = hi_y; p.aoe_z1 = hi_z;
    p.center_x  = target.x;
    p.center_y  = target.y;
    p.center_z  = target.z;
    p.brush_size  = std::max(1, ctx.tool.brush_size);
    p.brush_shape = (ctx.tool.brush_shape == BrushShape::Circle) ? 1 : 0;
    p.brush_3d    = ctx.tool.brush_3d ? 1 : 0;
    p.face_axis   = face_axis;
    p.stroke_id   = stroke_id_;
    p.seed_color  = ctx.mutator.params.foliage.seed_color;
    p.density     = ctx.mutator.params.foliage.density;
    engine.DispatchMutator(p);

    stroke_bbox_x0_ = std::min(stroke_bbox_x0_, lo_x);
    stroke_bbox_y0_ = std::min(stroke_bbox_y0_, lo_y);
    stroke_bbox_z0_ = std::min(stroke_bbox_z0_, lo_z);
    stroke_bbox_x1_ = std::max(stroke_bbox_x1_, hi_x);
    stroke_bbox_y1_ = std::max(stroke_bbox_y1_, hi_y);
    stroke_bbox_z1_ = std::max(stroke_bbox_z1_, hi_z);
}

void MutatorTool::SyncStrokeFromTexture(EditorContext& ctx,
                                         EditEngine& engine) {
    if (stroke_bbox_x0_ > stroke_bbox_x1_) return;

    Document& doc = ctx.document;
    const EditVolume& vol = doc.volume;
    Bbox3 bb{};
    bb.x0 = std::max(stroke_bbox_x0_, vol.x0);
    bb.y0 = std::max(stroke_bbox_y0_, vol.y0);
    bb.z0 = std::max(stroke_bbox_z0_, vol.z0);
    bb.x1 = std::min(stroke_bbox_x1_, vol.x1);
    bb.y1 = std::min(stroke_bbox_y1_, vol.y1);
    bb.z1 = std::min(stroke_bbox_z1_, vol.z1);
    if (bb.x0 > bb.x1 || bb.y0 > bb.y1 || bb.z0 > bb.z1) return;

    // Two commit_generic passes over the union bbox:
    //  1. Add  — promote tex_t (additive preview) into tex_a.
    //  2. Erase — clear tex_a where preview_rem flagged a Remove.
    // Foliage v1 never writes preview_rem so the Erase pass is a no-op
    // there; we still fire it so future Mutator kinds (Erode etc.)
    // wire through this same path automatically.
    CommitGenericParams cp{};
    cp.dispatch_lo_x = bb.x0 - vol.x0;
    cp.dispatch_lo_y = bb.y0 - vol.y0;
    cp.dispatch_lo_z = bb.z0 - vol.z0;
    cp.dispatch_size_x = bb.x1 - bb.x0 + 1;
    cp.dispatch_size_y = bb.y1 - bb.y0 + 1;
    cp.dispatch_size_z = bb.z1 - bb.z0 + 1;
    cp.brush = 0u;
    cp.fill_palette = ctx.tool.palette_idx;
    cp.bm = 1u;  // Add
    engine.CommitGeneric(cp);
    cp.bm = 2u;  // Erase
    engine.CommitGeneric(cp);

    std::vector<uint8_t> post;
    engine.Readback(bb, &post);
    const size_t bw = static_cast<size_t>(bb.x1 - bb.x0 + 1);
    const size_t bh = static_cast<size_t>(bb.y1 - bb.y0 + 1);
    const size_t bd = static_cast<size_t>(bb.z1 - bb.z0 + 1);
    if (post.size() < bw * bh * bd) return;

    std::vector<CellChange> diff;
    diff.reserve(1024);
    doc.volume_shadow.DiffAndApplyRegion(bb.x0, bb.y0, bb.z0,
                                         bb.x1, bb.y1, bb.z1,
                                         post.data(), &diff);
    if (diff.empty()) return;

    doc.grid.ApplyChanges(diff.data(), diff.size());
    ctx.history.RecordBatch(diff.data(), diff.size());
    (void)doc.volume_shadow.TakeDirtyChunks();
    doc.BumpGeometry();
}

bool MutatorTool::OnMouseDown(EditorContext& ctx, InteractionState& state,
                               const ViewContext& vc, const MouseEvent& e,
                               EditEngine& engine) {
    // Adopt the hover stroke_id (if a ghost is currently up) so the
    // first stamp produces the same cells the user was already seeing.
    // Otherwise allocate a fresh one.
    stroke_id_ = (hover_stroke_id_ != 0) ? hover_stroke_id_ : ++s_stroke_counter_;
    // Drop the ghost so the drag's bbox tracking starts clean. The
    // first stamp below will re-dispatch over the same cell at full
    // alpha — visually seamless since stroke_id is preserved.
    ClearHoverPreviewBbox(engine);
    hover_stroke_id_ = 0;
    hover_last_hash_ = 0;
    ResetStrokeState();
    ResetDispatchHash();
    is_dragging_ = true;
    state.drag_mode = DragMode::Paint;
    ctx.preview_active = true;
    ctx.preview_alpha = 1.0f;
    ctx.history.BeginOp();
    // Always dispatch the first stamp, even if ShouldDispatch hashes
    // happen to match (defensive — the hash already includes
    // stroke_id_, but the first event has no prior hash to compare).
    if (ShouldDispatch(DispatchParamsHash(ctx, state, vc, e))) {
        StampAtCursor(ctx, vc, e, engine);
    }
    return true;
}

void MutatorTool::OnMouseDragged(EditorContext& ctx, InteractionState& state,
                                  const ViewContext& vc, const MouseEvent& e,
                                  EditEngine& engine) {
    if (!is_dragging_) return;
    if (!ShouldDispatch(DispatchParamsHash(ctx, state, vc, e))) return;
    StampAtCursor(ctx, vc, e, engine);
}

void MutatorTool::OnMouseUp(EditorContext& ctx, InteractionState& /*state*/,
                             const ViewContext& /*vc*/,
                             const MouseEvent& /*e*/,
                             EditEngine& engine) {
    if (!is_dragging_) return;
    SyncStrokeFromTexture(ctx, engine);
    ctx.preview_active = false;
    ctx.preview_alpha = 1.0f;
    ctx.history.CommitOp();
    is_dragging_ = false;
    ResetStrokeState();
}

// Mutator contour outline: line drawn where the AOE volume contacts a
// "barrier" — either a doc voxel surface (the boundary between an
// occupied cell and an empty cell) or an edit-volume wall. Coplanar
// adjacent cell-faces are deduped automatically by the "XOR walk":
// for each axis-aligned cell edge inside the 2D footprint of a plane,
// emit the edge iff exactly one of the two adjacent cell-faces is a
// barrier-inside-AOE — interior shared edges cancel, only the outer
// perimeter survives. The ghost cells from the Foliage kernel show
// what *will* be written; this outline shows what *could* be reached.
void MutatorTool::DrawOverlay(const InteractionState& state,
                               const ViewContext& vc, OverlayDraw& od,
                               bool mouse_captured_by_ui) const {
    if (is_dragging_) return;
    if (mouse_captured_by_ui) return;
    if (!state.hover.has_point) return;
    if (vc.ctx == nullptr) return;
    if (vc.ctx->tool.tool != ToolKind::Mutator) return;

    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeTargetCell(state.hover.local.x, state.hover.local.y,
                              ToolMode::Add, &target, &face_axis)) return;

    const float w = vc.viewport_w;
    const float h = vc.viewport_h;
    if (w <= 0.0f || h <= 0.0f) return;

    const ToolSettings& tool = vc.ctx->tool;
    const int size = std::max(1, tool.brush_size);
    const int lo = -((size - 1) / 2);
    const int hi = size / 2;
    int32_t bx0 = target.x + lo, by0 = target.y + lo, bz0 = target.z + lo;
    int32_t bx1 = target.x + hi, by1 = target.y + hi, bz1 = target.z + hi;
    if (!tool.brush_3d) {
        if (face_axis == 0)      { bx0 = target.x; bx1 = target.x; }
        else if (face_axis == 1) { by0 = target.y; by1 = target.y; }
        else                     { bz0 = target.z; bz1 = target.z; }
    }
    const EditVolume& vol = vc.ctx->document.volume;
    // Clip AOE to the edit volume — faces outside the volume can't be
    // touched by the kernel, so they're not part of the contour. After
    // clamping, plane sweeps naturally include the volume walls when
    // the AOE pokes into them.
    bx0 = std::max(bx0, vol.x0); bx1 = std::min(bx1, vol.x1);
    by0 = std::max(by0, vol.y0); by1 = std::min(by1, vol.y1);
    bz0 = std::max(bz0, vol.z0); bz1 = std::min(bz1, vol.z1);
    if (bx0 > bx1 || by0 > by1 || bz0 > bz1) return;

    const float aspect = w / h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();
    auto project = [&](float gx, float gy, float gz,
                       simd::float2* screen, bool* valid) {
        // Same grid → world swap the renderer uses: world = (x, z, -y).
        const simd::float4 clip = simd_mul(vp, simd::float4{gx, gz, -gy, 1.0f});
        *valid = clip.w > 0.001f;
        if (!*valid) return;
        screen->x = (clip.x / clip.w * 0.5f + 0.5f) * w;
        screen->y = (1.0f - (clip.y / clip.w * 0.5f + 0.5f)) * h;
    };

    const VoxelVolume& shadow = vc.ctx->document.volume_shadow;
    const uint32_t color = Rgba8(150, 230, 150, 200);

    // Per-axis plane sweep. `axis` is the face-normal direction (0=X,
    // 1=Y, 2=Z); the plane is at world cell-boundary `p`. The 2D
    // footprint uses the other two axes (u, v).
    for (int axis = 0; axis < 3; ++axis) {
        int32_t p_lo, p_hi;        // plane range (cell boundaries)
        int32_t u_lo, u_hi;        // 2D footprint, u-axis cell range
        int32_t v_lo, v_hi;        // 2D footprint, v-axis cell range
        int32_t wall_min, wall_max;
        if (axis == 0) {
            p_lo = bx0; p_hi = bx1 + 1;
            u_lo = by0; u_hi = by1; v_lo = bz0; v_hi = bz1;
            wall_min = vol.x0; wall_max = vol.x1 + 1;
        } else if (axis == 1) {
            p_lo = by0; p_hi = by1 + 1;
            u_lo = bx0; u_hi = bx1; v_lo = bz0; v_hi = bz1;
            wall_min = vol.y0; wall_max = vol.y1 + 1;
        } else {
            p_lo = bz0; p_hi = bz1 + 1;
            u_lo = bx0; u_hi = bx1; v_lo = by0; v_hi = by1;
            wall_min = vol.z0; wall_max = vol.z1 + 1;
        }
        const int U = u_hi - u_lo + 1;
        const int V = v_hi - v_lo + 1;
        if (U <= 0 || V <= 0) continue;
        std::vector<uint8_t> grid(static_cast<size_t>(U) * V, 0);

        for (int32_t p = p_lo; p <= p_hi; ++p) {
            // (1) Mark each face on this plane that's a barrier.
            std::fill(grid.begin(), grid.end(), 0);
            const bool is_wall = (p == wall_min) || (p == wall_max);
            for (int v = 0; v < V; ++v) {
                for (int u = 0; u < U; ++u) {
                    const int32_t uw = u_lo + u;
                    const int32_t vw = v_lo + v;
                    bool barrier;
                    if (is_wall) {
                        barrier = true;
                    } else {
                        // Faces between (p-1, ...) and (p, ...) on this axis.
                        // Reads outside the volume return 0, so the shadow's
                        // out-of-range semantics handle wall-adjacent cells
                        // even though we already special-cased walls above.
                        uint8_t a, b;
                        if (axis == 0) {
                            a = shadow.Get(p - 1, uw, vw);
                            b = shadow.Get(p,     uw, vw);
                        } else if (axis == 1) {
                            a = shadow.Get(uw, p - 1, vw);
                            b = shadow.Get(uw, p,     vw);
                        } else {
                            a = shadow.Get(uw, vw, p - 1);
                            b = shadow.Get(uw, vw, p);
                        }
                        barrier = ((a != 0) != (b != 0));
                    }
                    grid[static_cast<size_t>(v) * U + u] = barrier ? 1 : 0;
                }
            }

            // (2) Emit boundary edges via XOR walk. `world_edge` converts
            // a plane-local edge endpoint (in cell coords on the plane)
            // back into world (x, y, z) for projection.
            auto world_edge = [&](int32_t pe_u, int32_t pe_v,
                                  float* gx, float* gy, float* gz) {
                if (axis == 0) {
                    *gx = static_cast<float>(p);
                    *gy = static_cast<float>(pe_u);
                    *gz = static_cast<float>(pe_v);
                } else if (axis == 1) {
                    *gx = static_cast<float>(pe_u);
                    *gy = static_cast<float>(p);
                    *gz = static_cast<float>(pe_v);
                } else {
                    *gx = static_cast<float>(pe_u);
                    *gy = static_cast<float>(pe_v);
                    *gz = static_cast<float>(p);
                }
            };
            auto draw_segment = [&](int32_t u0, int32_t v0,
                                    int32_t u1, int32_t v1) {
                float gx0, gy0, gz0, gx1, gy1, gz1;
                world_edge(u_lo + u0, v_lo + v0, &gx0, &gy0, &gz0);
                world_edge(u_lo + u1, v_lo + v1, &gx1, &gy1, &gz1);
                simd::float2 s0, s1;
                bool v0_ok, v1_ok;
                project(gx0, gy0, gz0, &s0, &v0_ok);
                project(gx1, gy1, gz1, &s1, &v1_ok);
                if (v0_ok && v1_ok) od.AddLine(s0, s1, color, 1.5f);
            };

            // Vertical edges (constant u-coord, varying v-cell). For each
            // u_pos in [0..U], the edge runs along the v-axis through
            // cell-row v. Emit if the two adjacent cells (u_pos-1, v)
            // and (u_pos, v) differ in barrier status; out-of-grid
            // counts as not-barrier.
            for (int u_pos = 0; u_pos <= U; ++u_pos) {
                for (int v = 0; v < V; ++v) {
                    const bool left  = (u_pos > 0) &&
                        grid[static_cast<size_t>(v) * U + (u_pos - 1)];
                    const bool right = (u_pos < U) &&
                        grid[static_cast<size_t>(v) * U + u_pos];
                    if (left != right) {
                        draw_segment(u_pos, v, u_pos, v + 1);
                    }
                }
            }
            // Horizontal edges (constant v-coord, varying u-cell).
            for (int v_pos = 0; v_pos <= V; ++v_pos) {
                for (int u = 0; u < U; ++u) {
                    const bool bot = (v_pos > 0) &&
                        grid[static_cast<size_t>(v_pos - 1) * U + u];
                    const bool top = (v_pos < V) &&
                        grid[static_cast<size_t>(v_pos) * U + u];
                    if (bot != top) {
                        draw_segment(u, v_pos, u + 1, v_pos);
                    }
                }
            }
        }
    }
}

void MutatorTool::Cancel(EditorContext& ctx, InteractionState& /*state*/,
                          EditEngine& engine) {
    if (!is_dragging_) return;
    SyncStrokeFromTexture(ctx, engine);
    ctx.preview_active = false;
    ctx.preview_alpha = 1.0f;
    ctx.history.CommitOp();
    is_dragging_ = false;
    ResetStrokeState();
}

void MutatorTool::ClearHoverPreviewBbox(EditEngine& engine) {
    if (hover_bbox_x0_ > hover_bbox_x1_) return;
    Bbox3 bb{};
    bb.x0 = hover_bbox_x0_; bb.y0 = hover_bbox_y0_; bb.z0 = hover_bbox_z0_;
    bb.x1 = hover_bbox_x1_; bb.y1 = hover_bbox_y1_; bb.z1 = hover_bbox_z1_;
    engine.ClearPreviewBbox(bb);
    hover_bbox_x0_ = hover_bbox_y0_ = hover_bbox_z0_ = INT32_MAX;
    hover_bbox_x1_ = hover_bbox_y1_ = hover_bbox_z1_ = INT32_MIN;
}

// Per-frame hover preview. Re-dispatches the Foliage kernel into tex_t
// whenever the cursor cell or params change; the rasterizer composites
// the result at preview_alpha = 0.55 (ghost). On mouseDown the drag
// inherits the same stroke_id so the click is a no-op for that first
// cell — only the alpha snaps from 0.55 to 1.0.
void MutatorTool::Tick(EditorContext& ctx, InteractionState& state,
                        const ViewContext& vc, ToolKind active_tool,
                        bool escape_pressed, EditEngine& engine) {
    if (is_dragging_) return;
    const bool tool_active = (active_tool == ToolKind::Mutator);
    const bool eligible = tool_active && state.hover.has_point && !escape_pressed;
    if (!eligible) {
        if (hover_bbox_x0_ <= hover_bbox_x1_) {
            ClearHoverPreviewBbox(engine);
            ctx.preview_active = false;
            ctx.preview_alpha = 1.0f;
        }
        hover_last_hash_ = 0;
        hover_stroke_id_ = 0;
        return;
    }

    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeTargetCell(state.hover.local.x, state.hover.local.y,
                              ToolMode::Add, &target, &face_axis)) {
        if (hover_bbox_x0_ <= hover_bbox_x1_) {
            ClearHoverPreviewBbox(engine);
            ctx.preview_active = false;
            ctx.preview_alpha = 1.0f;
        }
        hover_last_hash_ = 0;
        return;
    }

    if (hover_stroke_id_ == 0) {
        hover_stroke_id_ = ++s_stroke_counter_;
        hover_last_hash_ = 0;
    }

    const auto& ms = ctx.mutator;
    auto mix = [](uint64_t h, uint64_t v) {
        return h ^ (v + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
    };
    auto mix_f = [&](uint64_t h, float f) {
        union { float fv; uint32_t uv; } u{}; u.fv = f;
        return mix(h, u.uv);
    };
    uint64_t h = 0xcbf29ce484222325ULL;
    h = mix(h, static_cast<uint32_t>(target.x));
    h = mix(h, static_cast<uint32_t>(target.y));
    h = mix(h, static_cast<uint32_t>(target.z));
    h = mix(h, static_cast<uint32_t>(face_axis));
    h = mix(h, static_cast<uint64_t>(ms.active_kind));
    h = mix(h, ms.params.foliage.seed_color);
    h = mix_f(h, ms.params.foliage.density);
    h = mix(h, static_cast<uint32_t>(ctx.tool.brush_size));
    h = mix(h, static_cast<uint32_t>(ctx.tool.brush_shape));
    h = mix(h, ctx.tool.brush_3d ? 1u : 0u);
    h = mix(h, hover_stroke_id_);
    // Mutators read the live-composited neighborhood, so undo/redo
    // under a stationary cursor must re-dispatch the ghost.
    h = mix(h, ctx.document.geometry_version);
    h |= 1ULL;
    if (h == hover_last_hash_) {
        ctx.preview_active = true;
        ctx.preview_alpha = 0.55f;
        return;
    }
    hover_last_hash_ = h;

    ClearHoverPreviewBbox(engine);

    const int size = std::max(1, ctx.tool.brush_size);
    const int lo = -((size - 1) / 2);
    const int hi = size / 2;
    MutatorDispatchParams p{};
    p.kind        = ms.active_kind;
    p.aoe_x0 = target.x + lo; p.aoe_y0 = target.y + lo; p.aoe_z0 = target.z + lo;
    p.aoe_x1 = target.x + hi; p.aoe_y1 = target.y + hi; p.aoe_z1 = target.z + hi;
    p.center_x = target.x; p.center_y = target.y; p.center_z = target.z;
    p.brush_size  = size;
    p.brush_shape = (ctx.tool.brush_shape == BrushShape::Circle) ? 1 : 0;
    p.brush_3d    = ctx.tool.brush_3d ? 1 : 0;
    p.face_axis   = face_axis;
    p.stroke_id   = hover_stroke_id_;
    p.seed_color  = ms.params.foliage.seed_color;
    p.density     = ms.params.foliage.density;
    engine.DispatchMutator(p);

    hover_bbox_x0_ = p.aoe_x0;
    hover_bbox_y0_ = p.aoe_y0;
    hover_bbox_z0_ = p.aoe_z0;
    hover_bbox_x1_ = p.aoe_x1;
    hover_bbox_y1_ = p.aoe_y1;
    hover_bbox_z1_ = p.aoe_z1;
    ctx.preview_active = true;
    ctx.preview_alpha = 0.55f;
}

}  // namespace macvoxel
