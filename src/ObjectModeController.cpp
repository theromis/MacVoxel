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

// Record a leaf-transform edit going from (old_t, old_r) to the node's
// current values as one history op. No-op if nothing changed.
void RecordTransformOp(EditorContext& ctx, int32_t trn_id,
                       const Vec3i32& old_t, uint8_t old_r) {
    auto it = ctx.document.scene.nodes.find(trn_id);
    if (it == ctx.document.scene.nodes.end()) return;
    const SceneNode& node = it->second;
    if (node.t == old_t && node.rot == old_r) return;
    EditOp::SceneChange sc;
    sc.kind = EditOp::SceneChange::Kind::Transform;
    sc.trn_id = trn_id;
    sc.old_t = old_t;
    sc.old_r = old_r;
    sc.new_t = node.t;
    sc.new_r = node.rot;
    ctx.history.BeginOp();
    ctx.history.RecordSceneChange(sc);
    ctx.history.CommitOp();
}

void ApplyRotation(EditorContext& ctx, const RotMat& q) {
    int i;
    if (!SelectedObject(ctx, &i)) return;
    Scene& scene = ctx.document.scene;
    const SceneObject& o = scene.objects[static_cast<size_t>(i)];
    if (o.trn_id < 0) return;
    const SceneNode& node = scene.nodes.at(o.trn_id);
    const Vec3i32 old_t = node.t;
    const uint8_t old_r = node.rot;
    const int32_t trn_id = o.trn_id;
    SetObjectWorldTransform(scene, i, q * o.world_r, o.world_t);
    ctx.document.BumpScene();
    RecordTransformOp(ctx, trn_id, old_t, old_r);
}

}  // namespace

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    const Scene& scene = ctx.document.scene;

    // The translate arrows get first claim on the click — their tips
    // often float over empty space, where a fall-through pick would
    // deselect instead of grabbing the handle.
    int sel;
    if (SelectedObject(ctx, &sel)) {
        const SceneObject& so = scene.objects[static_cast<size_t>(sel)];
        Bounds3 gb;
        if (so.trn_id >= 0 && ObjectDimsWorldBounds(scene, sel, &gb)) {
            const int axis =
                vc.PickObjectAxisHandle(gb, e.local.x, e.local.y);
            if (axis >= 0) {
                const SceneNode& node = scene.nodes.at(so.trn_id);
                auto& g = state.object_gizmo;
                g.axis = axis;
                g.start_local = e.local;
                g.start_bounds = gb;
                g.snaps.clear();
                g.snaps.push_back({so.trn_id, sel, so.world_r, so.world_t,
                                   node.t, node.rot});
                state.drag_mode = DragMode::ObjectGizmo;
                return true;
            }
        }
    }

    simd::float3 ro, rd;
    if (!vc.RayAt(e.local.x, e.local.y, &ro, &rd)) return false;
    const int hit = PickObject(scene, ro, rd, 1.0e6f);
    ctx.selected_object = hit;
    if (hit < 0) return false;

    // Grab plane through the entry point of the object's world AABB,
    // perpendicular to the entry face (MoveSelect's trick).
    Bounds3 b;
    if (!ObjectDimsWorldBounds(scene, hit, &b)) return false;
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
    if (o.trn_id < 0) return false;  // bare shape: selectable, not movable
    const SceneNode& node = scene.nodes.at(o.trn_id);
    state.object_move.axis = axis;
    state.object_move.anchor_grid = anchor;
    state.object_move.start_world_t = o.world_t;
    state.object_move.trn_id = o.trn_id;
    state.object_move.start_leaf_t = node.t;
    state.object_move.start_leaf_r = node.rot;
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
    if (ObjectDimsWorldBounds(scene, i, &b)) {
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

void OnMouseUp(EditorContext& ctx, InteractionState& state) {
    const auto& m = state.object_move;
    if (m.trn_id < 0) return;
    RecordTransformOp(ctx, m.trn_id, m.start_leaf_t, m.start_leaf_r);
}

void OnGizmoDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    auto& g = state.object_gizmo;
    if (g.axis < 0 || g.snaps.empty()) return;
    Scene& scene = ctx.document.scene;
    const auto& s = g.snaps.front();
    if (s.object_index < 0 ||
        static_cast<size_t>(s.object_index) >= scene.objects.size()) {
        return;
    }

    auto mid = [](int32_t lo, int32_t hi) {
        return (static_cast<float>(lo) + static_cast<float>(hi) + 1.0f) * 0.5f;
    };
    const simd::float3 anchor{mid(g.start_bounds.min_x, g.start_bounds.max_x),
                              mid(g.start_bounds.min_y, g.start_bounds.max_y),
                              mid(g.start_bounds.min_z, g.start_bounds.max_z)};
    int delta = vc.AxisDragVoxels(g.axis, anchor, e.local.x, e.local.y,
                                  g.start_local.x, g.start_local.y);

    // Clamp so the AABB stays inside the world on the drag axis.
    const int32_t lo = (g.axis == 0)   ? g.start_bounds.min_x
                       : (g.axis == 1) ? g.start_bounds.min_y
                                       : g.start_bounds.min_z;
    const int32_t hi = (g.axis == 0)   ? g.start_bounds.max_x
                       : (g.axis == 1) ? g.start_bounds.max_y
                                       : g.start_bounds.max_z;
    delta = std::clamp(delta, -kWorldHalf - lo, (kWorldHalf - 1) - hi);

    Vec3i32 target = s.start_world_t;
    if (g.axis == 0) target.x += delta;
    else if (g.axis == 1) target.y += delta;
    else target.z += delta;

    const SceneObject& o = scene.objects[static_cast<size_t>(s.object_index)];
    if (target == o.world_t) return;  // dispatch-on-change
    SetObjectWorldTransform(scene, s.object_index, s.world_r, target);
    ctx.document.BumpScene();
}

void OnGizmoUp(EditorContext& ctx, InteractionState& state) {
    auto& g = state.object_gizmo;
    for (const auto& s : g.snaps) {
        RecordTransformOp(ctx, s.trn_id, s.start_leaf_t, s.start_leaf_r);
    }
    g.snaps.clear();
    g.axis = -1;
}

void RotateSelected(EditorContext& ctx, int axis, bool ccw) {
    ApplyRotation(ctx, AxisRotation(axis, ccw));
}

void FlipSelected(EditorContext& ctx, int axis) {
    ApplyRotation(ctx, AxisMirror(axis));
}

void DrawOverlay(const EditorContext& ctx, const InteractionState& state,
                 const ViewContext& vc, OverlayDraw& od) {
    const Scene& scene = ctx.document.scene;
    const int active = ctx.document.active_object;
    if (active != ctx.selected_object) {
        Bounds3 b;
        if (ObjectDimsWorldBounds(scene, active, &b)) {
            selection_overlay::DrawWorldAabb(
                b, Rgba8(140, 150, 175, 160), 1.0f, vc, od);
        }
    }
    int i;
    if (!SelectedObject(ctx, &i)) return;
    Bounds3 b;
    if (!ObjectDimsWorldBounds(scene, i, &b)) return;
    selection_overlay::DrawWorldAabb(b, Rgba8(255, 220, 80, 255), 1.5f, vc,
                                     od);

    // Translate arrows — movable objects only (bare shapes have no
    // leaf nTRN to edit).
    if (scene.objects[static_cast<size_t>(i)].trn_id < 0) return;
    const float w = vc.viewport_w;
    const float h = vc.viewport_h;
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();
    auto project = [&](simd::float3 wpos, simd::float2* screen) -> bool {
        const simd::float4 clip =
            simd_mul(vp, simd::float4{wpos.x, wpos.y, wpos.z, 1.0f});
        if (clip.w <= 0.001f) return false;
        screen->x = (clip.x / clip.w * 0.5f + 0.5f) * w;
        screen->y = (1.0f - (clip.y / clip.w * 0.5f + 0.5f)) * h;
        return true;
    };

    const bool dragging = state.drag_mode == DragMode::ObjectGizmo;
    int hot_axis = -1;
    if (dragging) {
        hot_axis = state.object_gizmo.axis;
    } else if (state.hover.has_point &&
               state.drag_mode == DragMode::None) {
        hot_axis = vc.PickObjectAxisHandle(b, state.hover.local.x,
                                           state.hover.local.y);
    }

    // Same X/Y/Z = red/green/blue palette as the generator gizmo so
    // axis colour reads consistently across the editor.
    constexpr uint32_t kAxisBase[3] = {Rgba8(230, 80, 80, 255),
                                       Rgba8(90, 200, 100, 255),
                                       Rgba8(90, 140, 240, 255)};
    constexpr uint32_t kAxisHover[3] = {Rgba8(255, 160, 160, 255),
                                        Rgba8(170, 250, 180, 255),
                                        Rgba8(160, 200, 255, 255)};
    constexpr uint32_t kAxisActive[3] = {Rgba8(255, 220, 220, 255),
                                         Rgba8(220, 255, 230, 255),
                                         Rgba8(220, 240, 255, 255)};
    constexpr float kArrowheadLenPx = 14.0f;
    constexpr float kArrowheadHalfWidthPx = 7.0f;

    for (int axis = 0; axis < 3; ++axis) {
        simd::float3 base_w, tip_w;
        ObjectAxisArrowGeom(b, axis, &base_w, &tip_w);
        simd::float2 p0, p1;
        if (!project(base_w, &p0) || !project(tip_w, &p1)) continue;

        const bool hot = axis == hot_axis;
        const uint32_t color = (dragging && hot) ? kAxisActive[axis]
                               : hot             ? kAxisHover[axis]
                                                 : kAxisBase[axis];
        const float thickness = hot ? 2.8f : 2.0f;
        od.AddLine(p0, p1, color, thickness);

        const simd::float2 d{p1.x - p0.x, p1.y - p0.y};
        const float stem_len = std::sqrt(d.x * d.x + d.y * d.y);
        if (stem_len <= 1e-3f) continue;
        const simd::float2 u{d.x / stem_len, d.y / stem_len};
        const simd::float2 perp{-u.y, u.x};
        const simd::float2 back{p1.x - u.x * kArrowheadLenPx,
                                p1.y - u.y * kArrowheadLenPx};
        od.AddTriangleFilled(
            p1,
            {back.x + perp.x * kArrowheadHalfWidthPx,
             back.y + perp.y * kArrowheadHalfWidthPx},
            {back.x - perp.x * kArrowheadHalfWidthPx,
             back.y - perp.y * kArrowheadHalfWidthPx},
            color);
    }
}

}  // namespace macvoxel::object_mode_controller
