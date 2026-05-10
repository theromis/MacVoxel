#pragma once

#include "Camera.h"
#include "Generators.h"
#include "Shapes.h"
#include "ToolState.h"

#include <simd/simd.h>

#include <cstdint>
#include <unordered_set>

namespace macvoxel {

struct EditorContext;
struct Bounds3;

// Stateless view-projection + scene context built fresh per event/frame
// from VoxelView. Owns nothing — Camera by value (cheap), EditorContext
// by raw pointer (AppDelegate keeps it alive for the app's lifetime).
//
// All cursor pixel coordinates are *view-local* — origin at the view's
// bottom-left, units in pixels (width up to viewport_w, height up to
// viewport_h). VoxelView converts NSWindow → local once at the NSEvent
// boundary so this header stays AppKit-free, which is what lets the
// per-tool gesture controllers (the next refactor step) be pure C++.
struct ViewContext {
    Camera camera;
    float viewport_w;
    float viewport_h;
    EditorContext* ctx;

    // ---------- Ray construction ----------

    // Build a grid-space ray from a local-coordinate cursor pixel.
    // Returns false if the viewport is degenerate.
    bool RayAt(float local_x, float local_y,
               simd::float3* out_origin, simd::float3* out_dir) const;

    // ---------- Grid picking ----------

    // Pick the cell the cursor lands on. Considers both the document
    // grid and the active floating buffer; takes whichever is hit
    // first. Falls back to the implicit ground plane (grid z=0) when
    // the ray misses everything.
    bool PickCell(float local_x, float local_y,
                  shapes::Vec3i* out_cell) const;

    // Intersect the camera ray with an axis-aligned plane in grid
    // space. axis: 0=X, 1=Y, 2=Z. plane_coord is the constant grid
    // coord on that axis. Returns the grid-space hit point, or false
    // if the ray is parallel to the plane / hits behind the camera.
    bool GridPlaneIntersect(float local_x, float local_y,
                            int axis, float plane_coord,
                            simd::float3* out_grid_point) const;

    // Mode-aware pick. Add returns the *neighbor* cell (placement
    // target); Remove/Paint return the *hit* cell. During a Paint
    // drag, the per-stroke skip set keeps the raycast on the
    // original surface even after voxels have been placed in front.
    bool ComputeTargetCell(
        float local_x, float local_y, ToolMode mode,
        shapes::Vec3i* out_cell, int* out_face_axis,
        const std::unordered_set<int64_t>& skip = {}) const;

    // For tools that accept empty-space anchors (Line/Circle/Square/
    // Box): try mode-faithful pick, then fall back to Add semantics
    // so Remove/Paint can still anchor in air.
    bool ComputeLineEndpoint(
        float local_x, float local_y, ToolMode mode,
        shapes::Vec3i* out_cell, int* out_face_axis) const;

    // Pick the clicked face: cell + (axis, sign) + color. Like
    // PickCell but exposes the hit's axis/sign — used by the Face
    // tool for extrude direction and by MoveSelect for the drag
    // plane.
    bool PickFace(float local_x, float local_y,
                  shapes::Vec3i* out_cell, int* out_axis, int* out_sign,
                  uint8_t* out_color) const;

    // ---------- Selection / floating-buffer transform gizmo ----------

    // The gizmo's world-space (already-offset) AABB: floating buffer
    // if active, else the on-grid selection bounds. Returns false if
    // neither exists.
    bool XformGizmoBounds(Bounds3* out_world_bounds) const;

    // Pick the transform-gizmo face arrow under the cursor. Returns
    // 0..5 (face index, see InteractionState.h) or -1.
    int PickXformHandle(float local_x, float local_y) const;

    // Project a cursor delta from the drag-start position onto the
    // dragged face's outward normal in NDC. Result is a signed voxel
    // count along that normal. start_bounds is the floating buffer's
    // pre-offset bounds at drag-start; this method adds the live
    // floating-buffer offset internally so the projection always
    // sees the gizmo's *world* face.
    int XformHandleDragVoxels(int face,
                              float local_x, float local_y,
                              float start_local_x, float start_local_y,
                              const Bounds3& start_bounds) const;

    // ---------- Generator gizmo ----------

    // Pick the generator-gizmo face arrow under the cursor against
    // the supplied bounds.
    int PickGenHandle(float local_x, float local_y,
                      const generators::Bounds3i& bounds) const;

    // Same projection trick as XformHandleDragVoxels; bounds are
    // the gizmo's drag-start bounds.
    int GenHandleDragVoxels(int face,
                            float local_x, float local_y,
                            float start_local_x, float start_local_y,
                            const generators::Bounds3i& start_bounds) const;

    // ---------- Face tool ----------

    // Cursor → signed voxel distance along the clicked face's normal.
    // Anchor cell + face_axis + face_sign + anchor screen pixel are
    // controller-owned drag-start state.
    int FaceDragVoxels(float local_x, float local_y,
                       const shapes::Vec3i& anchor_cell,
                       int face_axis, int face_sign,
                       float anchor_local_x, float anchor_local_y) const;
};

}  // namespace macvoxel
