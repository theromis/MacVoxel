#include "ShapeController.h"

#include "BrushOps.h"
#include "CellKey.h"
#include "EditorContext.h"
#include "Input.h"
#include "PreviewOps.h"
#include "PreviewOverlay.h"
#include "Shapes.h"
#include "ViewContext.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_set>
#include <vector>

namespace macvoxel::shape_controller {
namespace {

// Per-cell hit produced by the four enumerate* functions. face_axis
// is the orientation hint passed through to the brush footprint
// (controls 2D slab orientation for non-3D brushes).
struct LineHit { int32_t x, y, z; int face_axis; };

void EnumerateLine(EditorContext& /*ctx*/, const InteractionState& state,
                   const ViewContext& vc, const MouseEvent& e,
                   bool straight, std::vector<LineHit>& out) {
    out.clear();
    const auto& a = state.anchor;
    if (!a.has_anchor) return;

    if (straight) {
        shapes::Vec3i endpoint;
        int end_face = a.face_axis;
        if (!vc.ComputeLineEndpoint(e.local.x, e.local.y, a.mode,
                                    &endpoint, &end_face)) {
            // Endpoint picker only fails when no usable cell exists at
            // all (camera looking up, ground-plane fallback behind the
            // camera). Show just the anchor.
            out.push_back({a.cell.x, a.cell.y, a.cell.z, a.face_axis});
            return;
        }
        std::vector<shapes::Vec3i> cells;
        shapes::EnumerateLine(a.cell, endpoint, cells);
        out.reserve(cells.size());
        for (const auto& c : cells) {
            out.push_back({c.x, c.y, c.z, a.face_axis});
        }
        return;
    }

    // Project mode: walk the screen-space segment from the anchor
    // pixel to the cursor pixel, raycasting at each step. Each hit
    // is the cell a single Brush click at that pixel would produce.
    const simd::float2 s1 = a.screen_local;
    const simd::float2 s2 = e.local;
    const float dx = s2.x - s1.x;
    const float dy = s2.y - s1.y;
    // Oversample 2× so oblique screen-space lines don't skip voxels
    // whose projection sits between integer pixels.
    const int steps = std::max(1, static_cast<int>(
        2.0f * std::max(std::fabs(dx), std::fabs(dy))));
    std::unordered_set<int64_t> seen;
    seen.reserve(static_cast<size_t>(steps) + 1);
    for (int i = 0; i <= steps; ++i) {
        const float u = static_cast<float>(i) / static_cast<float>(steps);
        const float px = s1.x + dx * u;
        const float py = s1.y + dy * u;
        shapes::Vec3i cell;
        int face_axis = a.face_axis;
        if (!vc.ComputeTargetCell(px, py, a.mode, &cell, &face_axis)) {
            continue;
        }
        const int64_t k = PackCellKey(cell.x, cell.y, cell.z);
        if (!seen.insert(k).second) continue;
        out.push_back({cell.x, cell.y, cell.z, face_axis});
    }
    // The anchor cell may not be among the per-step hits if the anchor
    // started on the ground-plane fallback while the first stepped
    // pixels hit different cells; ensure click 1's cell is always
    // included so the line endpoint always reads as placed.
    const int64_t anchor_k = PackCellKey(a.cell.x, a.cell.y, a.cell.z);
    if (seen.find(anchor_k) == seen.end()) {
        out.insert(out.begin(),
                   {a.cell.x, a.cell.y, a.cell.z, a.face_axis});
    }
}

void EnumerateCircle(const InteractionState& state, const ViewContext& vc,
                     const MouseEvent& e, bool fill, bool even,
                     std::vector<LineHit>& out) {
    out.clear();
    const auto& a = state.anchor;
    if (!a.has_anchor) return;
    shapes::Vec3i endpoint;
    int end_face = a.face_axis;
    if (!vc.ComputeLineEndpoint(e.local.x, e.local.y, a.mode,
                                &endpoint, &end_face)) {
        out.push_back({a.cell.x, a.cell.y, a.cell.z, a.face_axis});
        return;
    }
    std::vector<shapes::Vec3i> cells;
    shapes::EnumerateCirclePlanar(a.cell, endpoint, a.face_axis,
                                  fill, even, cells);
    out.reserve(cells.size());
    for (const auto& c : cells) {
        out.push_back({c.x, c.y, c.z, a.face_axis});
    }
}

void EnumerateSquare(const InteractionState& state, const ViewContext& vc,
                     const MouseEvent& e, bool fill, bool even,
                     std::vector<LineHit>& out) {
    out.clear();
    const auto& a = state.anchor;
    if (!a.has_anchor) return;
    shapes::Vec3i endpoint;
    int end_face = a.face_axis;
    if (!vc.ComputeLineEndpoint(e.local.x, e.local.y, a.mode,
                                &endpoint, &end_face)) {
        out.push_back({a.cell.x, a.cell.y, a.cell.z, a.face_axis});
        return;
    }
    std::vector<shapes::Vec3i> cells;
    shapes::EnumerateSquarePlanar(a.cell, endpoint, a.face_axis,
                                  fill, even, cells);
    out.reserve(cells.size());
    for (const auto& c : cells) {
        out.push_back({c.x, c.y, c.z, a.face_axis});
    }
}

void EnumerateBoxShape(const InteractionState& state, const ViewContext& vc,
                       const MouseEvent& e, bool fill,
                       std::vector<LineHit>& out) {
    out.clear();
    const auto& a = state.anchor;
    if (!a.has_anchor) return;
    shapes::Vec3i endpoint;
    int end_face = a.face_axis;
    if (!vc.ComputeLineEndpoint(e.local.x, e.local.y, a.mode,
                                &endpoint, &end_face)) {
        out.push_back({a.cell.x, a.cell.y, a.cell.z, a.face_axis});
        return;
    }
    std::vector<shapes::Vec3i> cells;
    shapes::EnumerateBox(a.cell, endpoint, fill, cells);
    out.reserve(cells.size());
    for (const auto& c : cells) {
        out.push_back({c.x, c.y, c.z, a.face_axis});
    }
}

// Refresh the live preview: clear the overlay, enumerate the shape's
// hits at the current cursor, stamp each through the brush footprint.
void Refresh(EditorContext& ctx, InteractionState& state,
             const ViewContext& vc, const MouseEvent& e) {
    if (!state.anchor.has_anchor) return;

    PreviewOverlay& overlay = ctx.preview;
    overlay.Clear();
    overlay.active = true;

    const ToolSettings& t = ctx.tool;
    std::vector<LineHit> hits;
    switch (state.anchor.tool) {
        case ToolKind::Line:
            EnumerateLine(ctx, state, vc, e,
                          t.line_mode == LineMode::Straight, hits);
            break;
        case ToolKind::Circle:
            EnumerateCircle(state, vc, e, t.circle_fill, t.circle_even, hits);
            break;
        case ToolKind::Square:
            EnumerateSquare(state, vc, e, t.square_fill, t.square_even, hits);
            break;
        case ToolKind::Box:
            EnumerateBoxShape(state, vc, e, t.box_fill, hits);
            break;
        default: return;
    }
    for (const LineHit& h : hits) {
        StampBrushFootprint(ctx, h.x, h.y, h.z, h.face_axis,
                            state.anchor.mode, /*preview=*/true, nullptr);
    }
    ++overlay.version;
}

}  // namespace

bool BeginAnchor(EditorContext& ctx, InteractionState& state,
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

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    const ToolMode mode = e.mods.command ? ToolMode::Remove : ctx.tool.mode;
    if (!BeginAnchor(ctx, state, vc, e, mode)) return false;
    state.drag_mode = DragMode::Shape;
    Refresh(ctx, state, vc, e);
    return true;
}

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    Refresh(ctx, state, vc, e);
}

void OnMouseUp(EditorContext& ctx, InteractionState& state) {
    if (!state.anchor.has_anchor) return;
    CommitPreviewOverlayThroughHistory(ctx);
    state.anchor.has_anchor = false;
}

}  // namespace macvoxel::shape_controller
