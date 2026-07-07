#include "ObjectModeController.h"

#include "EditorContext.h"
#include "Input.h"
#include "InteractionState.h"
#include "ObjectPick.h"
#include "OverlayDraw.h"
#include "SelectionOverlay.h"
#include "ViewContext.h"
#include "VoxScene.h"

#include <algorithm>
#include <cmath>

namespace macvoxel::object_mode_controller {
namespace {

// 90° rotation generators about each world axis (CCW in the right-
// handed grid frame) and per-axis mirrors, as signed permutations.
RotMat AxisRotation(int axis, bool ccw) {
    const int8_t s = ccw ? 1 : -1;
    RotMat q;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) q.m[i][j] = 0;
    switch (axis) {
        case 0:
            q.m[0][0] = 1;
            q.m[1][2] = static_cast<int8_t>(-s);
            q.m[2][1] = s;
            break;
        case 1:
            q.m[1][1] = 1;
            q.m[0][2] = s;
            q.m[2][0] = static_cast<int8_t>(-s);
            break;
        default:
            q.m[2][2] = 1;
            q.m[0][1] = static_cast<int8_t>(-s);
            q.m[1][0] = s;
            break;
    }
    return q;
}

RotMat AxisMirror(int axis) {
    RotMat q;
    q.m[axis][axis] = -1;
    return q;
}

bool SelectedObject(const EditorContext& ctx, int* out_index) {
    const int i = ctx.selected_object;
    if (i < 0 ||
        static_cast<size_t>(i) >= ctx.document.scene.objects.size()) {
        return false;
    }
    *out_index = i;
    return true;
}

void ApplyRotation(EditorContext& ctx, const RotMat& q) {
    int i;
    if (!SelectedObject(ctx, &i)) return;
    Scene& scene = ctx.document.scene;
    const SceneObject& o = scene.objects[static_cast<size_t>(i)];
    SetObjectWorldTransform(scene, i, q * o.world_r, o.world_t);
    ctx.document.BumpScene();
}

}  // namespace

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    simd::float3 ro, rd;
    if (!vc.RayAt(e.local.x, e.local.y, &ro, &rd)) return false;
    const Scene& scene = ctx.document.scene;
    const int hit = PickObject(scene, ro, rd, 1.0e6f);
    ctx.selected_object = hit;
    if (hit < 0) return false;

    // Grab plane through the entry point of the object's world AABB,
    // perpendicular to the entry face (MoveSelect's trick).
    Bounds3 b;
    if (!ObjectWorldBounds(scene, hit, &b)) return false;
    const simd::float3 bmin{static_cast<float>(b.min_x),
                            static_cast<float>(b.min_y),
                            static_cast<float>(b.min_z)};
    const simd::float3 bmax{static_cast<float>(b.max_x + 1),
                            static_cast<float>(b.max_y + 1),
                            static_cast<float>(b.max_z + 1)};
    const simd::float3 inv = 1.0f / rd;
    const simd::float3 t1 = (bmin - ro) * inv;
    const simd::float3 t2 = (bmax - ro) * inv;
    const simd::float3 lo = simd_min(t1, t2);
    int axis;
    if (lo.x >= lo.y && lo.x >= lo.z) {
        axis = 0;
    } else if (lo.y >= lo.z) {
        axis = 1;
    } else {
        axis = 2;
    }
    const float axis_dir = (axis == 0) ? rd.x : (axis == 1) ? rd.y : rd.z;
    const int sign = axis_dir > 0.0f ? -1 : +1;
    const float plane_coord =
        (axis == 0) ? (sign > 0 ? bmax.x : bmin.x)
        : (axis == 1) ? (sign > 0 ? bmax.y : bmin.y)
                      : (sign > 0 ? bmax.z : bmin.z);
    simd::float3 anchor;
    if (!vc.GridPlaneIntersect(e.local.x, e.local.y, axis, plane_coord,
                               &anchor)) {
        return false;
    }
    const SceneObject& o = scene.objects[static_cast<size_t>(hit)];
    state.object_move.axis = axis;
    state.object_move.anchor_grid = anchor;
    state.object_move.start_world_t = o.world_t;
    state.drag_mode = DragMode::ObjectMove;
    return true;
}

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    int i;
    if (!SelectedObject(ctx, &i)) return;
    const auto& m = state.object_move;
    const float plane_coord = (m.axis == 0)   ? m.anchor_grid.x
                              : (m.axis == 1) ? m.anchor_grid.y
                                              : m.anchor_grid.z;
    simd::float3 hit;
    if (!vc.GridPlaneIntersect(e.local.x, e.local.y, m.axis, plane_coord,
                               &hit)) {
        return;
    }
    auto snap = [](float f) {
        return static_cast<int32_t>(std::lround(f));
    };
    Vec3i32 target = m.start_world_t;
    if (m.axis != 0) target.x += snap(hit.x - m.anchor_grid.x);
    if (m.axis != 1) target.y += snap(hit.y - m.anchor_grid.y);
    if (m.axis != 2) target.z += snap(hit.z - m.anchor_grid.z);

    Scene& scene = ctx.document.scene;
    const SceneObject& o = scene.objects[static_cast<size_t>(i)];
    if (target == o.world_t) return;  // dispatch-on-change

    // Clamp so the object's AABB stays inside the world.
    Bounds3 b;
    if (ObjectWorldBounds(scene, i, &b)) {
        const Vec3i32 d = target - o.world_t;
        auto clamp_axis = [](int32_t delta, int32_t lo, int32_t hi) {
            const int32_t max_up = (kWorldHalf - 1) - hi;
            const int32_t max_dn = -kWorldHalf - lo;
            return std::clamp(delta, max_dn, max_up);
        };
        target = o.world_t + Vec3i32{clamp_axis(d.x, b.min_x, b.max_x),
                                     clamp_axis(d.y, b.min_y, b.max_y),
                                     clamp_axis(d.z, b.min_z, b.max_z)};
        if (target == o.world_t) return;
    }
    SetObjectWorldTransform(scene, i, o.world_r, target);
    ctx.document.BumpScene();
}

void RotateSelected(EditorContext& ctx, int axis, bool ccw) {
    ApplyRotation(ctx, AxisRotation(axis, ccw));
}

void FlipSelected(EditorContext& ctx, int axis) {
    ApplyRotation(ctx, AxisMirror(axis));
}

void DrawOverlay(const EditorContext& ctx, const ViewContext& vc,
                 OverlayDraw& od) {
    const Scene& scene = ctx.document.scene;
    const int active = ctx.document.active_object;
    if (active != ctx.selected_object) {
        Bounds3 b;
        if (ObjectWorldBounds(scene, active, &b)) {
            selection_overlay::DrawWorldAabb(
                b, Rgba8(140, 150, 175, 160), 1.0f, vc, od);
        }
    }
    int i;
    if (SelectedObject(ctx, &i)) {
        Bounds3 b;
        if (ObjectWorldBounds(scene, i, &b)) {
            selection_overlay::DrawWorldAabb(
                b, Rgba8(255, 220, 80, 255), 1.5f, vc, od);
        }
    }
}

}  // namespace macvoxel::object_mode_controller
