#pragma once

#include "Generators.h"
#include "Shapes.h"
#include "ToolState.h"
#include "VoxelGrid.h"

#include <CoreGraphics/CGGeometry.h>
#include <simd/simd.h>

#include <cstdint>
#include <unordered_set>
#include <vector>

namespace macvoxel {

// Top-level gesture machine state for VoxelView. Each value identifies
// the kind of drag currently in flight; None means "no drag — input
// goes to camera idle / hover / clicks". Tools that need persistent
// state across multiple events (Shape/Face/Generator/Marquee/etc.)
// store it in the per-gesture sub-structs below; this enum just routes
// each NSView event into the matching code path.
enum class DragMode {
    None,
    Orbit,
    Pan,
    Paint,
    Marquee,
    BoxSelect,
    MoveSelect,
    XformHandle,
    Shape,
    GenHandle,
};

// Owned, named home for everything that used to live as a private ivar
// on VoxelView. Grouped per gesture so each block matches the eventual
// per-tool controller boundary (P12.x's "extract gestures from
// VoxelView" task) — splitting these now means the controller pass
// becomes a straight std::move per group instead of cell-by-cell ivar
// triage.
//
// VoxelView still owns the platform-and-render ivars (command queue,
// renderers, camera, tracking area, ImGui lifetime); this struct
// covers only the modeling-side gesture state.
struct InteractionState {
    // Active drag, across every gesture. Set on mouseDown by the
    // tool-routing dispatch; cleared on mouseUp by the matching
    // commit/abort path.
    DragMode drag_mode = DragMode::None;

    // Brush stream — drag-paint along the cursor path. Captures the
    // mode at stroke start so changing the panel mid-stroke doesn't
    // partway-flip the operation; tracks the last edited cell so the
    // raycaster can ignore the stroke's own placements (otherwise the
    // brush marches outward along the face normal).
    struct BrushStream {
        ToolMode paint_mode = ToolMode::Add;
        shapes::Vec3i last_drag_edit_cell{0, 0, 0};
        CGPoint last_drag_location{};
        std::unordered_set<int64_t> drag_skip_cells;
    } brush;

    // Cursor hover — last known mouse position in NSWindow coords,
    // and whether the cursor is currently inside the view. Drives
    // the hover overlay.
    struct Hover {
        CGPoint window_point{};
        bool has_point = false;
    } hover;

    // Marquee tool: the rectangle's two corners in view-local
    // coords. We deliberately don't pick a voxel at mouseDown — the
    // marquee selects what's *under* the rect on commit, so an anchor
    // in empty space is fine. Both points get re-projected on mouseUp
    // through the live camera matrix; no per-pixel work happens during
    // drag.
    struct MarqueeDrag {
        simd::float2 anchor_local{0.0f, 0.0f};
        simd::float2 current_local{0.0f, 0.0f};
    } marquee;

    // Box-select tool: anchor cell at mouseDown; the selection's
    // AABB grows live to [min(anchor, current), max] during drag.
    struct BoxSelectDrag {
        shapes::Vec3i anchor{0, 0, 0};
    } box_select;

    // Cmd-drag on a selected voxel = move the selection in the
    // click face's tangent plane. The actual lift / commit is
    // delegated to the FloatingBuffer; we just track the drag plane
    // and the offset value at click time so each frame can compute
    // a new absolute offset from the cumulative cursor delta.
    struct MoveSelect {
        int axis = 0;
        simd::float3 anchor_grid{0.0f, 0.0f, 0.0f};
        shapes::Vec3i start_offset{0, 0, 0};
    } move_select;

    // Floating-buffer transform gizmo. While a buffer is alive we
    // draw 6 face-arrow handles around its world AABB; clicking a
    // handle enters DragMode::XformHandle, which scales fb.grid
    // along that face's axis. The orig-grid snapshot is captured at
    // drag start so every frame's resample sees the lossless
    // original (shrink-then-grow round-trips cleanly within one
    // drag).
    struct XformHandle {
        int drag_face = -1;          // 0..5 while dragging, -1 otherwise
        simd::float2 drag_start_local{0.0f, 0.0f};
        Bounds3 drag_start_bounds{};
        VoxelGrid orig_grid{};
    } xform;

    // Two-click tools (Line, Circle, Square, Box, Generator-as-AABB):
    // between click 1 and click 2. Anchor cell + face axis are
    // computed at click 1 (via the line-endpoint picker); the
    // screen-space anchor is used as one endpoint of the screen-space
    // segment in Line's Project mode. The mode and tool are frozen
    // at click 1 so switching either mid-stroke doesn't surprise the
    // user; the per-frame sweep cancels the anchor when they change.
    struct TwoClickAnchor {
        bool has_anchor = false;
        shapes::Vec3i cell{0, 0, 0};
        int face_axis = 0;
        ToolMode mode = ToolMode::Add;
        simd::float2 screen_local{0.0f, 0.0f};
        ToolKind tool = ToolKind::Brush;
    } anchor;

    // Face tool: result of the click-time flood fill (all coplanar
    // same-color cells whose face on (face_axis, sign) is exposed)
    // and the source color used for extrusions. `observed_drag` is
    // set the first time the cursor produces a non-zero voxel
    // distance from the anchor; while it's still false, a d=0 commit
    // is treated as d=1 so a click without drag applies a single
    // 1-voxel layer. `applied_d` and `applied_with` snapshot the
    // d/face_with values currently materialised into the
    // PreviewOverlay so each frame only does O(seed_cells × Δd) work
    // as the user drags through layer boundaries.
    struct FaceTool {
        int sign = 0;
        uint8_t seed_color = 0;
        bool observed_drag = false;
        int applied_d = 0;
        FaceWithColor applied_with = FaceWithColor::Geometry;
        std::vector<shapes::Vec3i> seed_cells;
    } face;

    // Generator gizmo. After the user releases the mouse from a
    // Generator-tool drag-out, the box stays visible (along with the
    // PreviewOverlay cells) until they confirm. Clicking outside the
    // box commits the preview through EditHistory; Esc drops the
    // overlay without a commit. The bounds + active-kind cache lets
    // the per-frame loop detect param/kind changes from the panel
    // and re-run the engine. While a face-handle is being dragged
    // (`active_drag_face` 0..5; -1 otherwise), `handle_start_bounds`
    // locks in the bounds at drag-start so each frame's drag distance
    // projects against the same NDC reference direction — without
    // this, the projected normal moves as bounds change and the
    // drag-to-voxels mapping drifts.
    struct GenGizmo {
        bool active = false;
        generators::Bounds3i bounds{};
        generators::Kind last_kind = generators::Kind::Ellipsoid;
        generators::Bounds3i last_bounds{};
        generators::Params last_params{};
        int active_drag_face = -1;
        simd::float2 handle_start_local{0.0f, 0.0f};
        generators::Bounds3i handle_start_bounds{};
    } gen_gizmo;
};

}  // namespace macvoxel
