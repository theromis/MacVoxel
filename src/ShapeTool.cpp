#include "ShapeTool.h"

#include "BrushEngine.h"
#include "CellKey.h"
#include "Document.h"
#include "EditEngine.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "Input.h"
#include "InteractionState.h"
#include "ShapeEngine.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_set>
#include <vector>

namespace macvoxel {
namespace {

int ShapeKindForTool(ToolKind tool) {
    switch (tool) {
        case ToolKind::Line:   return 0;
        case ToolKind::Circle: return 1;
        case ToolKind::Square: return 2;
        case ToolKind::Box:    return 3;
        default: return -1;
    }
}

// Per-shape `(fill, even, line_straight)` flags pulled from ToolSettings;
// the kernel uses these to choose between filled/shell + center-on-cell-
// vs-corner.
void GetShapeFlags(const ToolSettings& t, ToolKind tool,
                   int* fill, int* even, int* line_straight) {
    *fill = 1;
    *even = 0;
    *line_straight = 1;
    switch (tool) {
        case ToolKind::Line:
            *line_straight = (t.line_mode == LineMode::Straight) ? 1 : 0;
            break;
        case ToolKind::Circle:
            *fill = t.circle_fill ? 1 : 0;
            *even = t.circle_even ? 1 : 0;
            break;
        case ToolKind::Square:
            *fill = t.square_fill ? 1 : 0;
            *even = t.square_even ? 1 : 0;
            break;
        case ToolKind::Box:
            *fill = t.box_fill ? 1 : 0;
            break;
        default: break;
    }
}

// Conservative AABB for the shape's footprint in world cell coords,
// inflated by the brush size so the kernel's expanded shape always
// fits inside. Clamped to the edit volume.
void ComputeShapeBbox(const ToolSettings& t, ToolKind tool,
                      shapes::Vec3i anchor, shapes::Vec3i endpoint,
                      int face_axis, const EditVolume& vol,
                      int32_t* x0, int32_t* y0, int32_t* z0,
                      int32_t* x1, int32_t* y1, int32_t* z1) {
    const int half = std::max(1, t.brush_size + 1);

    int32_t a_x = anchor.x, a_y = anchor.y, a_z = anchor.z;
    int32_t b_x = endpoint.x, b_y = endpoint.y, b_z = endpoint.z;
    int32_t lo_x = std::min(a_x, b_x);
    int32_t lo_y = std::min(a_y, b_y);
    int32_t lo_z = std::min(a_z, b_z);
    int32_t hi_x = std::max(a_x, b_x);
    int32_t hi_y = std::max(a_y, b_y);
    int32_t hi_z = std::max(a_z, b_z);

    if (tool == ToolKind::Circle || tool == ToolKind::Square) {
        const int32_t dx = b_x - a_x;
        const int32_t dy = b_y - a_y;
        const int32_t dz = b_z - a_z;
        int32_t in_plane_du = 0, in_plane_dv = 0;
        if (face_axis == 0) { in_plane_du = dy; in_plane_dv = dz; }
        else if (face_axis == 1) { in_plane_du = dx; in_plane_dv = dz; }
        else { in_plane_du = dx; in_plane_dv = dy; }
        const int32_t r =
            static_cast<int32_t>(std::ceil(std::sqrt(
                static_cast<double>(in_plane_du) * in_plane_du +
                static_cast<double>(in_plane_dv) * in_plane_dv)));
        lo_x = a_x - r;
        lo_y = a_y - r;
        lo_z = a_z - r;
        hi_x = a_x + r;
        hi_y = a_y + r;
        hi_z = a_z + r;
    }

    *x0 = std::max(lo_x - half, vol.x0);
    *y0 = std::max(lo_y - half, vol.y0);
    *z0 = std::max(lo_z - half, vol.z0);
    *x1 = std::min(hi_x + half, vol.x1);
    *y1 = std::min(hi_y + half, vol.y1);
    *z1 = std::min(hi_z + half, vol.z1);
}

shapes::Vec3i ResolveEndpoint(const InteractionState& state,
                              const ViewContext& vc, const MouseEvent& e) {
    shapes::Vec3i endpoint = state.anchor.cell;
    int end_face = state.anchor.face_axis;
    if (!vc.ComputeLineEndpoint(e.local.x, e.local.y, state.anchor.mode,
                                &endpoint, &end_face)) {
        return state.anchor.cell;
    }
    return endpoint;
}

// Line "project" mode: walk the screen-space segment from the anchor
// pixel to the cursor pixel, raycasting at each oversampled step. The
// picked cells are uploaded to a GPU buffer and the kernel expands
// them by the brush footprint into tex_t. Returns the (xyz, xyz, …)
// packed cell list.
std::vector<int32_t> EnumerateLineProjectCells(const InteractionState& state,
                                                const ViewContext& vc,
                                                const MouseEvent& e) {
    std::vector<int32_t> out;
    const auto& a = state.anchor;
    const simd::float2 s1 = a.screen_local;
    const simd::float2 s2 = e.local;
    const float dx = s2.x - s1.x;
    const float dy = s2.y - s1.y;
    const int steps = std::max(1, static_cast<int>(
        2.0f * std::max(std::fabs(dx), std::fabs(dy))));
    out.reserve(static_cast<size_t>(steps + 1) * 3);
    std::unordered_set<int64_t> seen;
    seen.reserve(static_cast<size_t>(steps) + 1);
    auto push = [&](int32_t x, int32_t y, int32_t z) {
        const int64_t k = PackCellKey(x, y, z);
        if (!seen.insert(k).second) return;
        out.push_back(x); out.push_back(y); out.push_back(z);
    };
    for (int i = 0; i <= steps; ++i) {
        const float u = static_cast<float>(i) / static_cast<float>(steps);
        const float px = s1.x + dx * u;
        const float py = s1.y + dy * u;
        shapes::Vec3i cell;
        int face_axis = a.face_axis;
        if (!vc.ComputeTargetCell(px, py, a.mode, &cell, &face_axis)) continue;
        push(cell.x, cell.y, cell.z);
    }
    const int64_t anchor_k = PackCellKey(a.cell.x, a.cell.y, a.cell.z);
    if (seen.find(anchor_k) == seen.end()) {
        std::vector<int32_t> with_anchor;
        with_anchor.reserve(out.size() + 3);
        with_anchor.push_back(a.cell.x);
        with_anchor.push_back(a.cell.y);
        with_anchor.push_back(a.cell.z);
        with_anchor.insert(with_anchor.end(), out.begin(), out.end());
        return with_anchor;
    }
    return out;
}

bool BboxFromCells(const std::vector<int32_t>& cells_xyz, int brush_size,
                   const EditVolume& vol,
                   int32_t* x0, int32_t* y0, int32_t* z0,
                   int32_t* x1, int32_t* y1, int32_t* z1) {
    if (cells_xyz.empty()) return false;
    int32_t lo_x = cells_xyz[0], lo_y = cells_xyz[1], lo_z = cells_xyz[2];
    int32_t hi_x = lo_x, hi_y = lo_y, hi_z = lo_z;
    for (size_t i = 3; i < cells_xyz.size(); i += 3) {
        lo_x = std::min(lo_x, cells_xyz[i + 0]);
        lo_y = std::min(lo_y, cells_xyz[i + 1]);
        lo_z = std::min(lo_z, cells_xyz[i + 2]);
        hi_x = std::max(hi_x, cells_xyz[i + 0]);
        hi_y = std::max(hi_y, cells_xyz[i + 1]);
        hi_z = std::max(hi_z, cells_xyz[i + 2]);
    }
    const int half = std::max(1, brush_size + 1);
    *x0 = std::max(lo_x - half, vol.x0);
    *y0 = std::max(lo_y - half, vol.y0);
    *z0 = std::max(lo_z - half, vol.z0);
    *x1 = std::min(hi_x + half, vol.x1);
    *y1 = std::min(hi_y + half, vol.y1);
    *z1 = std::min(hi_z + half, vol.z1);
    return true;
}

}  // namespace

bool BeginShapeAnchor(EditorContext& ctx, InteractionState& state,
                      const ViewContext& vc, const MouseEvent& e,
                      ToolMode mode) {
    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeLineEndpoint(e.local.x, e.local.y, mode,
                                &target, &face_axis)) {
        return false;
    }
    state.anchor.has_anchor = true;
    state.anchor.cell = target;
    state.anchor.face_axis = face_axis;
    state.anchor.mode = mode;
    state.anchor.screen_local = e.local;
    state.anchor.tool = ctx.tool.tool;
    return true;
}

void ShapeTool::ResetBboxes() {
    last_bbox_x0_ = last_bbox_y0_ = last_bbox_z0_ = INT32_MAX;
    last_bbox_x1_ = last_bbox_y1_ = last_bbox_z1_ = INT32_MIN;
    union_bbox_x0_ = union_bbox_y0_ = union_bbox_z0_ = INT32_MAX;
    union_bbox_x1_ = union_bbox_y1_ = union_bbox_z1_ = INT32_MIN;
}

void ShapeTool::DispatchPreview(EditorContext& ctx, InteractionState& state,
                                 const ViewContext& vc, const MouseEvent& e,
                                 int kind, EditEngine& engine) {
    const auto& a = state.anchor;
    const ToolSettings& t = ctx.tool;
    const EditVolume& vol = ctx.document.volume;

    // Line project mode: CPU-enumerate the picked cells, dispatch via
    // the project-preview kernel with the cell list.
    if (kind == 0 && t.line_mode == LineMode::Project) {
        std::vector<int32_t> cells = EnumerateLineProjectCells(state, vc, e);
        const size_t cell_count = cells.size() / 3;

        int32_t x0, y0, z0, x1, y1, z1;
        if (!BboxFromCells(cells, t.brush_size, vol,
                           &x0, &y0, &z0, &x1, &y1, &z1)) {
            x0 = vol.x0; y0 = vol.y0; z0 = vol.z0;
            x1 = vol.x0; y1 = vol.y0; z1 = vol.z0;
        }
        if (last_bbox_x0_ != INT32_MAX) {
            x0 = std::min(x0, last_bbox_x0_);
            y0 = std::min(y0, last_bbox_y0_);
            z0 = std::min(z0, last_bbox_z0_);
            x1 = std::max(x1, last_bbox_x1_);
            y1 = std::max(y1, last_bbox_y1_);
            z1 = std::max(z1, last_bbox_z1_);
        }
        x0 = std::max(x0, vol.x0); y0 = std::max(y0, vol.y0); z0 = std::max(z0, vol.z0);
        x1 = std::min(x1, vol.x1); y1 = std::min(y1, vol.y1); z1 = std::min(z1, vol.z1);

        ShapeParams p{};
        p.anchor_x = a.cell.x; p.anchor_y = a.cell.y; p.anchor_z = a.cell.z;
        p.endpoint_x = a.cell.x; p.endpoint_y = a.cell.y; p.endpoint_z = a.cell.z;
        p.face_axis = a.face_axis;
        p.brush_size = std::max(1, t.brush_size);
        p.brush_shape = (t.brush_shape == BrushShape::Circle) ? 1 : 0;
        p.brush_3d = t.brush_3d ? 1 : 0;
        p.mode = static_cast<uint32_t>(a.mode);
        p.palette_idx = t.palette_idx;
        p.shape_kind = 0;
        p.shape_fill = 1;
        p.shape_even = 0;
        p.line_straight = 0;
        p.dispatch_lo_x = x0 - vol.x0;
        p.dispatch_lo_y = y0 - vol.y0;
        p.dispatch_lo_z = z0 - vol.z0;
        p.dispatch_size_x = x1 - x0 + 1;
        p.dispatch_size_y = y1 - y0 + 1;
        p.dispatch_size_z = z1 - z0 + 1;
        p.vol_min_x = vol.x0; p.vol_min_y = vol.y0; p.vol_min_z = vol.z0;
        p.vol_max_x = vol.x1; p.vol_max_y = vol.y1; p.vol_max_z = vol.z1;
        p.tex_origin_x = vol.x0; p.tex_origin_y = vol.y0; p.tex_origin_z = vol.z0;

        last_bbox_x0_ = x0; last_bbox_y0_ = y0; last_bbox_z0_ = z0;
        last_bbox_x1_ = x1; last_bbox_y1_ = y1; last_bbox_z1_ = z1;
        union_bbox_x0_ = std::min(union_bbox_x0_, x0);
        union_bbox_y0_ = std::min(union_bbox_y0_, y0);
        union_bbox_z0_ = std::min(union_bbox_z0_, z0);
        union_bbox_x1_ = std::max(union_bbox_x1_, x1);
        union_bbox_y1_ = std::max(union_bbox_y1_, y1);
        union_bbox_z1_ = std::max(union_bbox_z1_, z1);

        engine.ShapeLineProjectPreview(p, cells.empty() ? nullptr : cells.data(),
                                       cell_count);
        return;
    }

    // Analytic path (straight line / circle / square / box).
    const shapes::Vec3i endpoint = ResolveEndpoint(state, vc, e);

    int fill = 1, even = 0, line_straight = 1;
    GetShapeFlags(t, a.tool, &fill, &even, &line_straight);

    int32_t x0, y0, z0, x1, y1, z1;
    ComputeShapeBbox(t, a.tool, a.cell, endpoint, a.face_axis, vol,
                     &x0, &y0, &z0, &x1, &y1, &z1);
    if (last_bbox_x0_ != INT32_MAX) {
        x0 = std::min(x0, last_bbox_x0_);
        y0 = std::min(y0, last_bbox_y0_);
        z0 = std::min(z0, last_bbox_z0_);
        x1 = std::max(x1, last_bbox_x1_);
        y1 = std::max(y1, last_bbox_y1_);
        z1 = std::max(z1, last_bbox_z1_);
    }
    x0 = std::max(x0, vol.x0); y0 = std::max(y0, vol.y0); z0 = std::max(z0, vol.z0);
    x1 = std::min(x1, vol.x1); y1 = std::min(y1, vol.y1); z1 = std::min(z1, vol.z1);

    ShapeParams p{};
    p.anchor_x = a.cell.x; p.anchor_y = a.cell.y; p.anchor_z = a.cell.z;
    p.endpoint_x = endpoint.x; p.endpoint_y = endpoint.y; p.endpoint_z = endpoint.z;
    p.face_axis = a.face_axis;
    p.brush_size = std::max(1, t.brush_size);
    p.brush_shape = (t.brush_shape == BrushShape::Circle) ? 1 : 0;
    p.brush_3d = t.brush_3d ? 1 : 0;
    p.mode = static_cast<uint32_t>(a.mode);
    p.palette_idx = t.palette_idx;
    p.shape_kind = kind;
    p.shape_fill = fill;
    p.shape_even = even;
    p.line_straight = line_straight;
    p.dispatch_lo_x = x0 - vol.x0;
    p.dispatch_lo_y = y0 - vol.y0;
    p.dispatch_lo_z = z0 - vol.z0;
    p.dispatch_size_x = x1 - x0 + 1;
    p.dispatch_size_y = y1 - y0 + 1;
    p.dispatch_size_z = z1 - z0 + 1;
    p.vol_min_x = vol.x0; p.vol_min_y = vol.y0; p.vol_min_z = vol.z0;
    p.vol_max_x = vol.x1; p.vol_max_y = vol.y1; p.vol_max_z = vol.z1;
    p.tex_origin_x = vol.x0; p.tex_origin_y = vol.y0; p.tex_origin_z = vol.z0;

    last_bbox_x0_ = x0; last_bbox_y0_ = y0; last_bbox_z0_ = z0;
    last_bbox_x1_ = x1; last_bbox_y1_ = y1; last_bbox_z1_ = z1;
    union_bbox_x0_ = std::min(union_bbox_x0_, x0);
    union_bbox_y0_ = std::min(union_bbox_y0_, y0);
    union_bbox_z0_ = std::min(union_bbox_z0_, z0);
    union_bbox_x1_ = std::max(union_bbox_x1_, x1);
    union_bbox_y1_ = std::max(union_bbox_y1_, y1);
    union_bbox_z1_ = std::max(union_bbox_z1_, z1);

    engine.ShapePreview(p);
}

bool ShapeTool::OnMouseDown(EditorContext& ctx, InteractionState& state,
                            const ViewContext& vc, const MouseEvent& e,
                            EditEngine& engine) {
    const ToolMode mode = e.mods.command ? ToolMode::Remove : ctx.tool.mode;
    if (!BeginShapeAnchor(ctx, state, vc, e, mode)) return false;
    const int kind = ShapeKindForTool(state.anchor.tool);
    if (kind < 0) {
        state.anchor.has_anchor = false;
        return false;
    }
    state.drag_mode = DragMode::Shape;
    ctx.preview_active = true;
    dragging_ = true;
    ResetBboxes();
    ResetDispatchHash();
    ctx.history.BeginOp();
    // First frame always dispatches — the hash starts cleared.
    ShouldDispatch(DispatchParamsHash(ctx, state, vc, e));
    DispatchPreview(ctx, state, vc, e, kind, engine);
    return true;
}

void ShapeTool::OnMouseDragged(EditorContext& ctx, InteractionState& state,
                                const ViewContext& vc, const MouseEvent& e,
                                EditEngine& engine) {
    if (!state.anchor.has_anchor) return;
    const int kind = ShapeKindForTool(state.anchor.tool);
    if (kind < 0) return;
    // Skip the kernel dispatch when nothing the kernel cares about has
    // changed since the previous mouseDragged event (CLAUDE.md:339-347
    // perf rule). Endpoint cell is the dominant signal — most events
    // produce duplicate hashes during a slow drag.
    if (!ShouldDispatch(DispatchParamsHash(ctx, state, vc, e))) return;
    DispatchPreview(ctx, state, vc, e, kind, engine);
}

uint64_t ShapeTool::DispatchParamsHash(const EditorContext& ctx,
                                       const InteractionState& state,
                                       const ViewContext& vc,
                                       const MouseEvent& e) const {
    const auto& a = ctx.tool;
    auto mix = [](uint64_t h, uint64_t v) {
        return h ^ (v + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
    };

    shapes::Vec3i endpoint{0, 0, 0};
    int face_axis = 0;
    if (state.anchor.has_anchor) {
        endpoint = state.anchor.cell;
        int axis = state.anchor.face_axis;
        vc.ComputeLineEndpoint(e.local.x, e.local.y, state.anchor.mode,
                               &endpoint, &axis);
        face_axis = axis;
    }
    uint64_t h = 0xcbf29ce484222325ULL;  // FNV offset
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(endpoint.x)));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(endpoint.y)));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(endpoint.z)));
    h = mix(h, static_cast<uint64_t>(face_axis));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(a.tool)));
    h = mix(h, static_cast<uint64_t>(a.brush_size));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(a.brush_shape)));
    h = mix(h, static_cast<uint64_t>(a.brush_3d ? 1 : 0));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(a.mode)));
    h = mix(h, static_cast<uint64_t>(a.circle_fill | (a.circle_even << 1) |
                                      (a.square_fill << 2) | (a.square_even << 3) |
                                      (a.box_fill << 4)));
    h = mix(h, static_cast<uint64_t>(static_cast<uint32_t>(a.line_mode)));
    // For project-mode line the kernel reads CPU-enumerated cells
    // derived from the screen-space segment; sub-cell cursor movement
    // changes the cell set so include raw pixels.
    if (a.tool == ToolKind::Line && a.line_mode == LineMode::Project) {
        union { float f; uint32_t u; } pe{};
        pe.f = e.local.x; h = mix(h, pe.u);
        pe.f = e.local.y; h = mix(h, pe.u);
    }
    return h | 1ULL;  // never 0 (Tool::ShouldDispatch treats 0 as "always dispatch")
}

void ShapeTool::OnMouseUp(EditorContext& ctx, InteractionState& state,
                           const ViewContext& /*vc*/, const MouseEvent& /*e*/,
                           EditEngine& engine) {
    dragging_ = false;
    if (!state.anchor.has_anchor) {
        ctx.history.AbandonOp();
        return;
    }

    if (union_bbox_x0_ == INT32_MAX) {
        ctx.preview_active = false;
        state.anchor.has_anchor = false;
        ctx.history.AbandonOp();
        return;
    }

    Document& doc = ctx.document;
    const EditVolume& vol = doc.volume;
    Bbox3 bb{};
    bb.x0 = std::max(union_bbox_x0_, vol.x0);
    bb.y0 = std::max(union_bbox_y0_, vol.y0);
    bb.z0 = std::max(union_bbox_z0_, vol.z0);
    bb.x1 = std::min(union_bbox_x1_, vol.x1);
    bb.y1 = std::min(union_bbox_y1_, vol.y1);
    bb.z1 = std::min(union_bbox_z1_, vol.z1);
    if (bb.x0 > bb.x1 || bb.y0 > bb.y1 || bb.z0 > bb.z1) {
        ctx.preview_active = false;
        state.anchor.has_anchor = false;
        ctx.history.AbandonOp();
        return;
    }

    const auto& a = state.anchor;
    CommitGenericParams cp{};
    cp.dispatch_lo_x = bb.x0 - vol.x0;
    cp.dispatch_lo_y = bb.y0 - vol.y0;
    cp.dispatch_lo_z = bb.z0 - vol.z0;
    cp.dispatch_size_x = bb.x1 - bb.x0 + 1;
    cp.dispatch_size_y = bb.y1 - bb.y0 + 1;
    cp.dispatch_size_z = bb.z1 - bb.z0 + 1;
    // Add (0) -> bm 1, Remove (1) -> 2, Paint (2) -> 3 (matches the
    // existing shape_commit semantics; bm=4 Intersect is unused so far).
    cp.bm = static_cast<uint32_t>(a.mode) + 1u;
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
        doc.volume_shadow.DiffAndApplyRegion(bb.x0, bb.y0, bb.z0,
                                             bb.x1, bb.y1, bb.z1,
                                             post.data(), &diff);
        if (!diff.empty()) {
            doc.grid.ApplyChanges(diff.data(), diff.size());
            ctx.history.RecordBatch(diff.data(), diff.size());
            engine.RefreshDocOracle(doc.volume_shadow);
            doc.BumpGeometry();
        }
    }

    ctx.preview_active = false;
    state.anchor.has_anchor = false;
    ResetBboxes();
    ctx.history.CommitOp();
}

void ShapeTool::Cancel(EditorContext& ctx, InteractionState& state,
                       EditEngine& engine) {
    if (!dragging_ && !state.anchor.has_anchor) return;
    // Clear any preview cells the kernel wrote, then abandon the op so
    // nothing lands in history.
    if (union_bbox_x0_ != INT32_MAX) {
        Bbox3 bb{};
        bb.x0 = union_bbox_x0_; bb.y0 = union_bbox_y0_; bb.z0 = union_bbox_z0_;
        bb.x1 = union_bbox_x1_; bb.y1 = union_bbox_y1_; bb.z1 = union_bbox_z1_;
        engine.ClearPreviewBbox(bb);
    }
    ctx.history.AbandonOp();
    ctx.preview_active = false;
    state.anchor.has_anchor = false;
    dragging_ = false;
    ResetBboxes();
}

}  // namespace macvoxel
