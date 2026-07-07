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
#include <vector>

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

using Snap = InteractionState::ObjectGizmo::Snap;

// Append one leaf-transform record (old → current) to the OPEN op.
// No-op if nothing changed.
void AppendTransformRecord(EditorContext& ctx, int32_t trn_id,
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
    ctx.history.RecordSceneChange(sc);
}

// One op covering every snapshot's net change. CommitOp drops the op
// when no record survived the no-change filter.
void RecordSnapOps(EditorContext& ctx, const std::vector<Snap>& snaps) {
    ctx.history.BeginOp();
    for (const Snap& s : snaps) {
        AppendTransformRecord(ctx, s.trn_id, s.start_leaf_t,
                              s.start_leaf_r);
    }
    ctx.history.CommitOp();
}

// Union of the selection's dims-box AABBs. False when no member has
// a valid box.
bool SelectionUnionBounds(const EditorContext& ctx, Bounds3* out) {
    const Scene& scene = ctx.document.scene;
    bool any = false;
    for (int32_t m : ctx.selected_objects) {
        Bounds3 b;
        if (!ObjectDimsWorldBounds(scene, m, &b)) continue;
        if (!any) {
            *out = b;
            any = true;
        } else {
            out->min_x = std::min(out->min_x, b.min_x);
            out->min_y = std::min(out->min_y, b.min_y);
            out->min_z = std::min(out->min_z, b.min_z);
            out->max_x = std::max(out->max_x, b.max_x);
            out->max_y = std::max(out->max_y, b.max_y);
            out->max_z = std::max(out->max_z, b.max_z);
        }
    }
    return any;
}

// Transform snapshots for every movable member, deduped by leaf id —
// instanced leaves alias one nTRN and must be transformed once.
std::vector<Snap> BuildSnaps(const EditorContext& ctx) {
    const Scene& scene = ctx.document.scene;
    std::vector<Snap> snaps;
    for (int32_t m : ctx.selected_objects) {
        if (m < 0 || static_cast<size_t>(m) >= scene.objects.size()) {
            continue;
        }
        const SceneObject& o = scene.objects[static_cast<size_t>(m)];
        if (o.trn_id < 0) continue;
        const bool seen =
            std::any_of(snaps.begin(), snaps.end(), [&](const Snap& s) {
                return s.trn_id == o.trn_id;
            });
        if (seen) continue;
        const SceneNode& node = scene.nodes.at(o.trn_id);
        snaps.push_back({o.trn_id, m, o.world_r, o.world_t, node.t,
                         node.rot});
    }
    return snaps;
}

// floor((lo + hi + 1) / 2): the integer center of an inclusive span,
// sign-safe, matching the HalfDims floor convention.
int32_t SpanCenter(int32_t lo, int32_t hi) {
    const int32_t s = lo + hi + 1;
    return s >= 0 ? s / 2 : -((-s + 1) / 2);
}

// Translation that pushes an AABB back inside ±kWorldHalf (zero when
// already inside).
int32_t NudgeIntoWorld(int32_t lo, int32_t hi) {
    if (lo < -kWorldHalf) return -kWorldHalf - lo;
    if (hi > kWorldHalf - 1) return (kWorldHalf - 1) - hi;
    return 0;
}

void ApplyRotation(EditorContext& ctx, const RotMat& q) {
    Scene& scene = ctx.document.scene;
    std::vector<Snap> snaps = BuildSnaps(ctx);
    if (snaps.empty()) return;

    if (snaps.size() == 1) {
        // Single object rotates in place (translation unchanged).
        const Snap& s = snaps.front();
        SetObjectWorldTransform(scene, s.object_index, q * s.world_r,
                                s.start_world_t);
    } else {
        // Rigid group rotation about the union-AABB center.
        Bounds3 ub;
        if (!SelectionUnionBounds(ctx, &ub)) return;
        const Vec3i32 p{SpanCenter(ub.min_x, ub.max_x),
                        SpanCenter(ub.min_y, ub.max_y),
                        SpanCenter(ub.min_z, ub.max_z)};
        for (const Snap& s : snaps) {
            SetObjectWorldTransform(scene, s.object_index, q * s.world_r,
                                    p + q * (s.start_world_t - p));
        }
        // Push the rotated union back inside the world, uniformly.
        Bounds3 nb;
        if (SelectionUnionBounds(ctx, &nb)) {
            const Vec3i32 d{NudgeIntoWorld(nb.min_x, nb.max_x),
                            NudgeIntoWorld(nb.min_y, nb.max_y),
                            NudgeIntoWorld(nb.min_z, nb.max_z)};
            if (!(d == Vec3i32{})) {
                for (const Snap& s : snaps) {
                    const SceneObject& o =
                        scene.objects[static_cast<size_t>(s.object_index)];
                    SetObjectWorldTransform(scene, s.object_index,
                                            o.world_r, o.world_t + d);
                }
            }
        }
    }
    ctx.document.BumpScene();
    RecordSnapOps(ctx, snaps);
}

}  // namespace

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    const Scene& scene = ctx.document.scene;

    // The translate arrows get first claim on the click — their tips
    // often float over empty space, where a fall-through pick would
    // deselect instead of grabbing the handle. The gizmo sits on the
    // union AABB and drags every movable member.
    Bounds3 gb;
    if (SelectionUnionBounds(ctx, &gb)) {
        const int axis = vc.PickObjectAxisHandle(gb, e.local.x, e.local.y);
        if (axis >= 0) {
            std::vector<Snap> snaps = BuildSnaps(ctx);
            if (!snaps.empty()) {
                auto& g = state.object_gizmo;
                g.axis = axis;
                g.start_local = e.local;
                g.start_bounds = gb;
                g.snaps = std::move(snaps);
                state.drag_mode = DragMode::ObjectGizmo;
                return true;
            }
        }
    }

    simd::float3 ro, rd;
    if (!vc.RayAt(e.local.x, e.local.y, &ro, &rd)) return false;
    const int hit = PickObject(scene, ro, rd, 1.0e6f);

    // Shift-click toggles membership; no drag either way.
    if (e.mods.shift) {
        if (hit >= 0) ctx.ToggleObjectSelected(hit);
        return false;
    }

    // Empty space starts the rubber band; the deselect (when the rect
    // stays a click) happens on mouseUp.
    if (hit < 0) {
        state.marquee.anchor_local = e.local;
        state.marquee.current_local = e.local;
        state.drag_mode = DragMode::ObjectMarquee;
        return true;
    }

    // Clicking a member keeps the set (just re-primaries); anything
    // else replaces the selection.
    if (ctx.IsObjectSelected(hit)) {
        ctx.selected_object = hit;
    } else {
        ctx.SelectObjectOnly(hit);
    }

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
    state.object_move.axis = axis;
    state.object_move.anchor_grid = anchor;
    // Body drags move the whole selection rigidly; the same snapshot
    // store serves both drag kinds.
    auto& g = state.object_gizmo;
    g.snaps = BuildSnaps(ctx);
    if (g.snaps.empty()) return false;
    Bounds3 ub;
    if (!SelectionUnionBounds(ctx, &ub)) return false;
    g.start_bounds = ub;
    state.drag_mode = DragMode::ObjectMove;
    return true;
}

// Apply one rigid translation to every snapshot (absolute targets, so
// repeated frames can't accumulate error). Assumes `delta` is already
// clamped to keep the union AABB in the world.
static void ApplySnapTranslation(EditorContext& ctx,
                                 const std::vector<Snap>& snaps,
                                 const Vec3i32& delta) {
    Scene& scene = ctx.document.scene;
    const Snap& first = snaps.front();
    if (first.object_index < 0 ||
        static_cast<size_t>(first.object_index) >= scene.objects.size()) {
        return;
    }
    const Vec3i32 lead = first.start_world_t + delta;
    if (lead == scene.objects[static_cast<size_t>(first.object_index)]
                    .world_t) {
        return;  // dispatch-on-change
    }
    for (const Snap& s : snaps) {
        SetObjectWorldTransform(scene, s.object_index, s.world_r,
                                s.start_world_t + delta);
    }
    ctx.document.BumpScene();
}

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    const auto& m = state.object_move;
    const auto& g = state.object_gizmo;
    if (g.snaps.empty()) return;
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
    Vec3i32 delta{};
    if (m.axis != 0) delta.x = snap(hit.x - m.anchor_grid.x);
    if (m.axis != 1) delta.y = snap(hit.y - m.anchor_grid.y);
    if (m.axis != 2) delta.z = snap(hit.z - m.anchor_grid.z);

    // Clamp so the union AABB stays inside the world.
    auto clamp_axis = [](int32_t d, int32_t lo, int32_t hi) {
        return std::clamp(d, -kWorldHalf - lo, (kWorldHalf - 1) - hi);
    };
    const Bounds3& ub = g.start_bounds;
    delta.x = clamp_axis(delta.x, ub.min_x, ub.max_x);
    delta.y = clamp_axis(delta.y, ub.min_y, ub.max_y);
    delta.z = clamp_axis(delta.z, ub.min_z, ub.max_z);

    ApplySnapTranslation(ctx, g.snaps, delta);
}

void OnMouseUp(EditorContext& ctx, InteractionState& state) {
    auto& g = state.object_gizmo;
    RecordSnapOps(ctx, g.snaps);
    g.snaps.clear();
}

void OnGizmoDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    auto& g = state.object_gizmo;
    if (g.axis < 0 || g.snaps.empty()) return;

    auto mid = [](int32_t lo, int32_t hi) {
        return (static_cast<float>(lo) + static_cast<float>(hi) + 1.0f) * 0.5f;
    };
    const simd::float3 anchor{mid(g.start_bounds.min_x, g.start_bounds.max_x),
                              mid(g.start_bounds.min_y, g.start_bounds.max_y),
                              mid(g.start_bounds.min_z, g.start_bounds.max_z)};
    int d = vc.AxisDragVoxels(g.axis, anchor, e.local.x, e.local.y,
                              g.start_local.x, g.start_local.y);

    // Clamp so the union AABB stays inside the world on the drag axis.
    const int32_t lo = (g.axis == 0)   ? g.start_bounds.min_x
                       : (g.axis == 1) ? g.start_bounds.min_y
                                       : g.start_bounds.min_z;
    const int32_t hi = (g.axis == 0)   ? g.start_bounds.max_x
                       : (g.axis == 1) ? g.start_bounds.max_y
                                       : g.start_bounds.max_z;
    d = std::clamp(d, -kWorldHalf - lo, (kWorldHalf - 1) - hi);

    Vec3i32 delta{};
    if (g.axis == 0) delta.x = d;
    else if (g.axis == 1) delta.y = d;
    else delta.z = d;

    ApplySnapTranslation(ctx, g.snaps, delta);
}

void OnGizmoUp(EditorContext& ctx, InteractionState& state) {
    auto& g = state.object_gizmo;
    RecordSnapOps(ctx, g.snaps);
    g.snaps.clear();
    g.axis = -1;
}

void OnMarqueeDragged(InteractionState& state, const MouseEvent& e) {
    state.marquee.current_local = e.local;
}

void OnMarqueeUp(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    auto& m = state.marquee;
    m.current_local = e.local;
    if (vc.viewport_w <= 0.0f || vc.viewport_h <= 0.0f) return;

    const float rx_min = std::min(m.anchor_local.x, m.current_local.x);
    const float rx_max = std::max(m.anchor_local.x, m.current_local.x);
    const float ry_min = std::min(m.anchor_local.y, m.current_local.y);
    const float ry_max = std::max(m.anchor_local.y, m.current_local.y);

    // Sub-click rect keeps the old empty-click semantics.
    if ((rx_max - rx_min) < 2.0f && (ry_max - ry_min) < 2.0f) {
        if (!e.mods.shift) ctx.ClearObjectSelection();
        return;
    }

    const float aspect = vc.viewport_w / vc.viewport_h;
    const simd::float4x4 vp =
        vc.camera.ProjectionMatrix(aspect) * vc.camera.ViewMatrix();
    const float vw = vc.viewport_w;
    const float vh = vc.viewport_h;

    if (!e.mods.shift) ctx.ClearObjectSelection();
    const Scene& scene = ctx.document.scene;
    for (size_t i = 0; i < scene.objects.size(); ++i) {
        if (scene.objects[i].hidden) continue;
        Bounds3 b;
        if (!ObjectDimsWorldBounds(scene, static_cast<int>(i), &b)) continue;
        // Screen-space bbox over the AABB's projected corners; select
        // on rect INTERSECTION (Magica-style). Both spaces are view-
        // local bottom-up, so a direct compare is correct.
        float sx_min = 1e9f, sx_max = -1e9f;
        float sy_min = 1e9f, sy_max = -1e9f;
        bool any = false;
        for (int c = 0; c < 8; ++c) {
            const float gx = static_cast<float>((c & 1) ? b.max_x + 1
                                                        : b.min_x);
            const float gy = static_cast<float>((c & 2) ? b.max_y + 1
                                                        : b.min_y);
            const float gz = static_cast<float>((c & 4) ? b.max_z + 1
                                                        : b.min_z);
            const simd::float4 clip =
                simd_mul(vp, simd::float4{gx, gz, -gy, 1.0f});
            if (clip.w <= 1e-3f) continue;
            const float sx = (clip.x / clip.w * 0.5f + 0.5f) * vw;
            const float sy = (clip.y / clip.w * 0.5f + 0.5f) * vh;
            sx_min = std::min(sx_min, sx);
            sx_max = std::max(sx_max, sx);
            sy_min = std::min(sy_min, sy);
            sy_max = std::max(sy_max, sy);
            any = true;
        }
        if (!any) continue;
        const bool overlaps = sx_min <= rx_max && sx_max >= rx_min &&
                              sy_min <= ry_max && sy_max >= ry_min;
        if (overlaps && !ctx.IsObjectSelected(static_cast<int32_t>(i))) {
            ctx.ToggleObjectSelected(static_cast<int32_t>(i));
        }
    }
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
    if (!ctx.IsObjectSelected(active)) {
        Bounds3 b;
        if (ObjectDimsWorldBounds(scene, active, &b)) {
            selection_overlay::DrawWorldAabb(
                b, Rgba8(140, 150, 175, 160), 1.0f, vc, od);
        }
    }

    // Rubber band, over nothing but under the outlines.
    if (state.drag_mode == DragMode::ObjectMarquee &&
        vc.viewport_h > 0.0f) {
        const simd::float2 a = state.marquee.anchor_local;
        const simd::float2 c = state.marquee.current_local;
        const float h = vc.viewport_h;
        // Local y is bottom-up; the overlay renderer is top-down.
        const simd::float2 tl{std::min(a.x, c.x), h - std::max(a.y, c.y)};
        const simd::float2 br{std::max(a.x, c.x), h - std::min(a.y, c.y)};
        od.AddRectFilled(tl, br, Rgba8(255, 220, 80, 28));
        od.AddRect(tl, br, Rgba8(255, 220, 80, 220), 1.0f);
    }

    // Every member gets an outline; the primary draws thicker.
    for (int32_t m : ctx.selected_objects) {
        if (m == ctx.selected_object) continue;
        Bounds3 mb;
        if (ObjectDimsWorldBounds(scene, m, &mb)) {
            selection_overlay::DrawWorldAabb(
                mb, Rgba8(255, 220, 80, 190), 1.0f, vc, od);
        }
    }
    int i;
    if (!SelectedObject(ctx, &i)) return;
    Bounds3 pb;
    if (!ObjectDimsWorldBounds(scene, i, &pb)) return;
    selection_overlay::DrawWorldAabb(pb, Rgba8(255, 220, 80, 255), 1.5f, vc,
                                     od);

    // Translate arrows on the union AABB — shown when at least one
    // member is movable (bare shapes have no leaf nTRN to edit).
    Bounds3 b;
    if (!SelectionUnionBounds(ctx, &b)) return;
    if (BuildSnaps(ctx).empty()) return;
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
