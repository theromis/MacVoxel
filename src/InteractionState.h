#pragma once

#include "Generators.h"
#include "Shapes.h"
#include "ToolState.h"
#include "VoxelGrid.h"

#include <CoreGraphics/CGGeometry.h>
#include <simd/simd.h>

#include <cstdint>
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

    // Last mouse window-coords position, used by every dragging gesture
    // (Orbit, Pan, Paint, …) to compute per-frame deltas. The drag's
    // first event seeds this on mouseDown / rightMouseDown / etc.;
    // mouseDragged reads then overwrites it. Lives at the top level
    // because it's not tool-specific.
    CGPoint last_drag_location{};

    // Brush gesture state moved into `BrushTool`; the stub remains so
    // Phase 4's dissolution commit has something to delete in one go.
    struct BrushStream {} brush;

    // Cursor hover — last known mouse position in view-local coords,
    // and whether the cursor is currently inside the view. Drives
    // the hover overlay.
    struct Hover {
        simd::float2 local{0.0f, 0.0f};
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
        // Shape-kernel preview bookkeeping. `last_bbox_*` is the
        // dispatch bbox of the previous frame's preview — the new
        // frame's dispatch unions with it so cells the old shape
        // covered but the new one doesn't get cleared. `union_*`
        // accumulates across the whole stroke so OnMouseUp can
        // diff against shadow over exactly the touched region.
        // INT32_MAX / MIN = empty.
        int32_t last_bbox_x0 = INT32_MAX, last_bbox_y0 = INT32_MAX,
                last_bbox_z0 = INT32_MAX;
        int32_t last_bbox_x1 = INT32_MIN, last_bbox_y1 = INT32_MIN,
                last_bbox_z1 = INT32_MIN;
        int32_t union_bbox_x0 = INT32_MAX, union_bbox_y0 = INT32_MAX,
                union_bbox_z0 = INT32_MAX;
        int32_t union_bbox_x1 = INT32_MIN, union_bbox_y1 = INT32_MIN,
                union_bbox_z1 = INT32_MIN;
    } anchor;

    // Face tool: result of the click-time flood fill (all coplanar
    // same-color cells whose face on (face_axis, sign) is exposed)
    // and the source color used for extrusions. `observed_drag` is
    // set the first time the cursor produces a non-zero voxel
    // distance from the anchor; while it's still false, a d=0 commit
    // is treated as d=1 so a click without drag applies a single
    // 1-voxel layer. `applied_d` and `applied_with` snapshot the
    // d/face_with values currently materialised into the preview
    // texture so each frame only does O(seed_cells × Δd) work as the
    // user drags through layer boundaries.
    struct FaceTool {
        int sign = 0;
        uint8_t seed_color = 0;
        bool observed_drag = false;
        int applied_d = 0;
        FaceWithColor applied_with = FaceWithColor::Geometry;
        // True when the seed plane came from a volume-wall pick
        // rather than a voxel-face pick. Forces `face_with =
        // Palette` regardless of the user's selection (there's no
        // geometry color to source from — the seed cells are shifted
        // outside the volume), and skips the "no preview if source
        // cell is 0" no-op that Geometry mode would otherwise emit.
        bool from_wall = false;
        std::vector<shapes::Vec3i> seed_cells;
        // Per-frame bbox bookkeeping for the tex_t preview. last_bbox
        // is what we wrote last frame (cleared on next Refresh);
        // union_bbox accumulates across the stroke for the commit
        // readback. INT32_MAX/MIN = empty.
        int32_t last_bbox_x0 = INT32_MAX, last_bbox_y0 = INT32_MAX,
                last_bbox_z0 = INT32_MAX;
        int32_t last_bbox_x1 = INT32_MIN, last_bbox_y1 = INT32_MIN,
                last_bbox_z1 = INT32_MIN;
        int32_t union_bbox_x0 = INT32_MAX, union_bbox_y0 = INT32_MAX,
                union_bbox_z0 = INT32_MAX;
        int32_t union_bbox_x1 = INT32_MIN, union_bbox_y1 = INT32_MIN,
                union_bbox_z1 = INT32_MIN;
    } face;

    // Generator gizmo. After the user releases the mouse from a
    // Generator-tool drag-out, the box stays visible (along with the
    // preview-texture cells) until they confirm. Clicking outside the
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
        // Bbox of the PREVIOUSLY-DISPATCHED bounds (used to union with
        // the new dispatch so shrinking-bounds cells naturally clear).
        // Distinct from `last_bounds` only briefly across the Tick
        // dirty check — `last_bounds` is updated at end of Regenerate
        // for next frame's dirty compare, while
        // `last_bounds_dispatched` is read at the start of the next
        // Regenerate. `_valid=false` on first dispatch in a session.
        generators::Bounds3i last_bounds_dispatched{};
        bool last_bounds_dispatched_valid = false;
        // Union of every dispatch's bbox across the gesture. OnMouseUp
        // reads this to know how much of tex_a to blit back for diff.
        // INT32_MAX/MIN = empty.
        int32_t union_bounds_x0 = INT32_MAX, union_bounds_y0 = INT32_MAX,
                union_bounds_z0 = INT32_MAX;
        int32_t union_bounds_x1 = INT32_MIN, union_bounds_y1 = INT32_MIN,
                union_bounds_z1 = INT32_MIN;
    } gen_gizmo;
};

}  // namespace macvoxel
