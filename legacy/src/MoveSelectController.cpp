#include "MoveSelectController.h"

#include "EditorContext.h"
#include "Input.h"
#include "Selection.h"
#include "SelectionLift.h"
#include "Shapes.h"
#include "ViewContext.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <cmath>

namespace macvoxel::move_select_controller {

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return false;
    const Bounds3& b = sel.bounds();
    if (b.empty()) return false;

    // Lift cells live in tex_lift only — doc.grid has a hole at
    // those positions, so the doc-only Raycast in PickFace can't see
    // them. Do an AABB intersect against the lift bbox instead.
    simd::float3 ray_origin, ray_dir;
    if (!vc.RayAt(e.local.x, e.local.y, &ray_origin, &ray_dir)) return false;

    const simd::float3 bmin{static_cast<float>(b.min_x),
                            static_cast<float>(b.min_y),
                            static_cast<float>(b.min_z)};
    const simd::float3 bmax{static_cast<float>(b.max_x + 1),
                            static_cast<float>(b.max_y + 1),
                            static_cast<float>(b.max_z + 1)};
    const simd::float3 inv_dir = 1.0f / ray_dir;
    const simd::float3 t1 = (bmin - ray_origin) * inv_dir;
    const simd::float3 t2 = (bmax - ray_origin) * inv_dir;
    const simd::float3 t_lo = simd_min(t1, t2);
    const simd::float3 t_hi = simd_max(t1, t2);
    const float t_enter = std::max({t_lo.x, t_lo.y, t_lo.z});
    const float t_exit = std::min({t_hi.x, t_hi.y, t_hi.z});
    if (t_exit < 0.0f || t_enter > t_exit) return false;

    // Entry face: whichever axis has the largest t_lo. Outward normal
    // sign is opposite the ray's travel direction along that axis.
    int axis;
    int sign;
    if (t_lo.x >= t_lo.y && t_lo.x >= t_lo.z) {
        axis = 0;
        sign = (ray_dir.x > 0.0f) ? -1 : +1;
    } else if (t_lo.y >= t_lo.z) {
        axis = 1;
        sign = (ray_dir.y > 0.0f) ? -1 : +1;
    } else {
        axis = 2;
        sign = (ray_dir.z > 0.0f) ? -1 : +1;
    }

    const float plane_coord = (axis == 0)
        ? (sign > 0 ? bmax.x : bmin.x)
        : (axis == 1)
        ? (sign > 0 ? bmax.y : bmin.y)
        : (sign > 0 ? bmax.z : bmin.z);
    simd::float3 anchor;
    if (!vc.GridPlaneIntersect(e.local.x, e.local.y, axis, plane_coord, &anchor)) {
        return false;
    }

    state.move_select.axis = axis;
    state.move_select.anchor_grid = anchor;
    state.move_select.start_bounds_min =
        shapes::Vec3i{b.min_x, b.min_y, b.min_z};
    state.drag_mode = DragMode::MoveSelect;
    return true;
}

void OnMouseDragged(EditorContext& ctx,
                    const InteractionState::MoveSelect& m,
                    const ViewContext& vc, const MouseEvent& e) {
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return;

    const float plane_coord = (m.axis == 0) ? m.anchor_grid.x
                            : (m.axis == 1) ? m.anchor_grid.y
                                            : m.anchor_grid.z;
    simd::float3 hit;
    if (!vc.GridPlaneIntersect(e.local.x, e.local.y, m.axis, plane_coord, &hit)) {
        return;
    }

    auto round_to_int = [](float f) -> int32_t {
        return static_cast<int32_t>(std::lround(f));
    };
    int32_t target_x = m.start_bounds_min.x;
    int32_t target_y = m.start_bounds_min.y;
    int32_t target_z = m.start_bounds_min.z;
    if (m.axis != 0) target_x += round_to_int(hit.x - m.anchor_grid.x);
    if (m.axis != 1) target_y += round_to_int(hit.y - m.anchor_grid.y);
    if (m.axis != 2) target_z += round_to_int(hit.z - m.anchor_grid.z);

    const Bounds3& b = sel.bounds();
    const int32_t dx = target_x - b.min_x;
    const int32_t dy = target_y - b.min_y;
    const int32_t dz = target_z - b.min_z;
    if (dx == 0 && dy == 0 && dz == 0) return;
    lift::TranslateLift(ctx, dx, dy, dz);
}

}  // namespace macvoxel::move_select_controller
