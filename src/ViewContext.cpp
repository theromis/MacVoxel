#include "ViewContext.h"

#include "Document.h"
#include "EditorContext.h"
#include "FloatingBuffer.h"
#include "Raycast.h"
#include "Selection.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace macvoxel {

namespace {

// Intersect the ray with the 6 axis-aligned walls of the edit volume;
// return the closest forward hit and snap it to the cell on the inside
// of the hit face. Used as the empty-space fallback for picking and
// for Add-mode tools — a click into empty space anchors at whichever
// wall the ray hits first instead of always landing on z=0.
bool IntersectVolumeWall(const EditVolume& vol,
                         simd::float3 ray_origin,
                         simd::float3 ray_dir,
                         shapes::Vec3i* out_cell,
                         int* out_face_axis) {
    const float walls[3][2] = {
        {static_cast<float>(vol.x0), static_cast<float>(vol.x1 + 1)},
        {static_cast<float>(vol.y0), static_cast<float>(vol.y1 + 1)},
        {static_cast<float>(vol.z0), static_cast<float>(vol.z1 + 1)},
    };
    const float ro[3] = {ray_origin.x, ray_origin.y, ray_origin.z};
    const float rd[3] = {ray_dir.x, ray_dir.y, ray_dir.z};
    // Skip the 3 camera-facing walls — the user can't see them, and
    // hiding the matching wireframe edges (raycast shader) only makes
    // sense if clicks anchor consistently to the back walls instead.
    const int near_side[3] = {
        (ro[0] < (walls[0][0] + walls[0][1]) * 0.5f) ? 0 : 1,
        (ro[1] < (walls[1][0] + walls[1][1]) * 0.5f) ? 0 : 1,
        (ro[2] < (walls[2][0] + walls[2][1]) * 0.5f) ? 0 : 1,
    };
    float best_t = std::numeric_limits<float>::infinity();
    int best_axis = -1, best_sign = 0;
    float best_h[3] = {0.0f, 0.0f, 0.0f};
    for (int axis = 0; axis < 3; ++axis) {
        if (std::abs(rd[axis]) < 1e-6f) continue;
        for (int side = 0; side < 2; ++side) {
            if (side == near_side[axis]) continue;
            const float plane = walls[axis][side];
            const float t = (plane - ro[axis]) / rd[axis];
            if (t < 0.0f || t > 4096.0f) continue;
            if (t >= best_t) continue;
            const float h[3] = {ro[0] + t * rd[0],
                                ro[1] + t * rd[1],
                                ro[2] + t * rd[2]};
            bool inside = true;
            for (int o = 0; o < 3 && inside; ++o) {
                if (o == axis) continue;
                if (h[o] < walls[o][0] || h[o] > walls[o][1]) inside = false;
            }
            if (!inside) continue;
            best_t = t;
            best_axis = axis;
            best_sign = (side == 0) ? -1 : +1;
            best_h[0] = h[0]; best_h[1] = h[1]; best_h[2] = h[2];
        }
    }
    if (best_axis < 0) return false;
    out_cell->x = std::clamp(static_cast<int>(std::floor(best_h[0])),
                             vol.x0, vol.x1);
    out_cell->y = std::clamp(static_cast<int>(std::floor(best_h[1])),
                             vol.y0, vol.y1);
    out_cell->z = std::clamp(static_cast<int>(std::floor(best_h[2])),
                             vol.z0, vol.z1);
    if (best_axis == 0) out_cell->x = (best_sign < 0) ? vol.x0 : vol.x1;
    if (best_axis == 1) out_cell->y = (best_sign < 0) ? vol.y0 : vol.y1;
    if (best_axis == 2) out_cell->z = (best_sign < 0) ? vol.z0 : vol.z1;
    if (out_face_axis) *out_face_axis = best_axis;
    return true;
}

// (axis, sign) for face index 0..5. axis = face/2 (0=X, 1=Y, 2=Z);
// sign = (face&1) ? +1 : -1. Same convention as VoxelView's gizmo
// drawing — duplicated here so ViewContext is self-contained until
// the gizmo controllers move out and consolidate this helper.
inline void FaceAxisSign(int face, int* axis, int* sign) {
    *axis = face / 2;
    *sign = (face & 1) ? +1 : -1;
}

// Floating-buffer transform gizmo face center + outward normal in
// world (renderer) coords. Voxels span [c, c+1] so the +face surface
// sits at coord+1, the -face at coord. R = (gx, gz, -gy) matches the
// renderer's grid → world rotation.
void XformFaceWorldGeom(const Bounds3& b, int face,
                        simd::float3* out_center, simd::float3* out_normal) {
    int axis, sign;
    FaceAxisSign(face, &axis, &sign);
    auto mid = [](int32_t lo, int32_t hi) {
        return (static_cast<float>(lo) + static_cast<float>(hi) + 1.0f) * 0.5f;
    };
    const int32_t face_coord = (sign < 0)
        ? (axis == 0 ? b.min_x : axis == 1 ? b.min_y : b.min_z)
        : ((axis == 0 ? b.max_x : axis == 1 ? b.max_y : b.max_z) + 1);
    float gx, gy, gz;
    if (axis == 0) {
        gx = static_cast<float>(face_coord);
        gy = mid(b.min_y, b.max_y);
        gz = mid(b.min_z, b.max_z);
    } else if (axis == 1) {
        gx = mid(b.min_x, b.max_x);
        gy = static_cast<float>(face_coord);
        gz = mid(b.min_z, b.max_z);
    } else {
        gx = mid(b.min_x, b.max_x);
        gy = mid(b.min_y, b.max_y);
        gz = static_cast<float>(face_coord);
    }
    *out_center = simd::float3{gx, gz, -gy};
    simd::float3 n_grid{0.0f, 0.0f, 0.0f};
    if (axis == 0) n_grid.x = static_cast<float>(sign);
    else if (axis == 1) n_grid.y = static_cast<float>(sign);
    else                n_grid.z = static_cast<float>(sign);
    *out_normal = simd::float3{n_grid.x, n_grid.z, -n_grid.y};
}

// Generator gizmo face center + outward normal. Same as the xform
// gizmo but on the int32-indexed Bounds3i.
void GizmoFaceWorldGeom(const generators::Bounds3i& b, int face,
                        simd::float3* out_center, simd::float3* out_normal) {
    int axis, sign;
    FaceAxisSign(face, &axis, &sign);
    auto mid = [](int32_t a, int32_t b1) {
        return (static_cast<float>(a) + static_cast<float>(b1) + 1.0f) * 0.5f;
    };
    const int32_t face_coord = (sign < 0)
        ? (axis == 0 ? b.x0 : axis == 1 ? b.y0 : b.z0)
        : ((axis == 0 ? b.x1 : axis == 1 ? b.y1 : b.z1) + 1);
    float gx, gy, gz;
    if (axis == 0) {
        gx = static_cast<float>(face_coord);
        gy = mid(b.y0, b.y1);
        gz = mid(b.z0, b.z1);
    } else if (axis == 1) {
        gx = mid(b.x0, b.x1);
        gy = static_cast<float>(face_coord);
        gz = mid(b.z0, b.z1);
    } else {
        gx = mid(b.x0, b.x1);
        gy = mid(b.y0, b.y1);
        gz = static_cast<float>(face_coord);
    }
    *out_center = simd::float3{gx, gz, -gy};
    simd::float3 n_grid{0, 0, 0};
    if (axis == 0) n_grid.x = static_cast<float>(sign);
    else if (axis == 1) n_grid.y = static_cast<float>(sign);
    else                n_grid.z = static_cast<float>(sign);
    *out_normal = simd::float3{n_grid.x, n_grid.z, -n_grid.y};
}

}  // namespace

bool ViewContext::RayAt(float local_x, float local_y,
                        simd::float3* out_origin,
                        simd::float3* out_dir) const {
    if (viewport_w <= 0.0f || viewport_h <= 0.0f) return false;

    const float ndc_x = (local_x / viewport_w) * 2.0f - 1.0f;
    const float ndc_y = (local_y / viewport_h) * 2.0f - 1.0f;

    const float aspect = viewport_w / viewport_h;
    const simd::float4x4 vmat = camera.ViewMatrix();
    const simd::float4x4 pmat = camera.ProjectionMatrix(aspect);
    const simd::float4x4 inv_vp = simd_inverse(pmat * vmat);

    auto unproject = [&](float z) -> simd::float3 {
        simd::float4 clip{ndc_x, ndc_y, z, 1.0f};
        simd::float4 wh = simd_mul(inv_vp, clip);
        return simd::float3{wh.x / wh.w, wh.y / wh.w, wh.z / wh.w};
    };
    const simd::float3 near_world = unproject(0.0f);
    const simd::float3 far_world  = unproject(1.0f);
    const simd::float3 dir_world  = simd::normalize(far_world - near_world);
    const simd::float3 origin_world = camera.Position();

    // World → grid: invert the renderer's R = (gx, gz, -gy).
    *out_origin = simd::float3{origin_world.x, -origin_world.z, origin_world.y};
    *out_dir    = simd::float3{dir_world.x,    -dir_world.z,    dir_world.y};
    return true;
}

bool ViewContext::PickCell(float local_x, float local_y,
                           shapes::Vec3i* out_cell) const {
    if (ctx == nullptr) return false;
    const Document& doc = ctx->document;

    simd::float3 ray_origin_grid, ray_dir_grid;
    if (!RayAt(local_x, local_y, &ray_origin_grid, &ray_dir_grid)) return false;

    // Match the GPU dual-volume DDA: raycast both the document grid
    // and (if active) the floating buffer, take whichever the ray hits
    // first. Without this, Cmd-drag on a buffer that's been moved off
    // its lifted-from doc cells fails because the picker can't see
    // them — they exist only in the buffer.
    RayHit hit_doc, hit_buf;
    bool got_doc = Raycast(doc.grid, ray_origin_grid, ray_dir_grid,
                           4096.0f, &hit_doc);
    bool got_buf = false;
    const FloatingBuffer& fb = ctx->floating_buffer;
    if (fb.active && !fb.grid.empty()) {
        const simd::float3 origin_buf{
            ray_origin_grid.x - static_cast<float>(fb.offset_x),
            ray_origin_grid.y - static_cast<float>(fb.offset_y),
            ray_origin_grid.z - static_cast<float>(fb.offset_z),
        };
        got_buf = Raycast(fb.grid, origin_buf, ray_dir_grid,
                          4096.0f, &hit_buf);
    }
    if (got_doc || got_buf) {
        const bool from_buf = got_buf && (!got_doc || hit_buf.t < hit_doc.t);
        const RayHit& hit = from_buf ? hit_buf : hit_doc;
        out_cell->x = hit.x + (from_buf ? fb.offset_x : 0);
        out_cell->y = hit.y + (from_buf ? fb.offset_y : 0);
        out_cell->z = hit.z + (from_buf ? fb.offset_z : 0);
        return true;
    }
    // Empty-space fallback: snap to whichever wall of the edit volume
    // the ray hits first instead of always landing on z=0.
    return IntersectVolumeWall(doc.volume, ray_origin_grid, ray_dir_grid,
                               out_cell, nullptr);
}

bool ViewContext::GridPlaneIntersect(float local_x, float local_y,
                                     int axis, float plane_coord,
                                     simd::float3* out_grid_point) const {
    simd::float3 ro, rd;
    if (!RayAt(local_x, local_y, &ro, &rd)) return false;
    const float ro_ax = (axis == 0) ? ro.x : (axis == 1) ? ro.y : ro.z;
    const float rd_ax = (axis == 0) ? rd.x : (axis == 1) ? rd.y : rd.z;
    if (std::fabs(rd_ax) < 1e-6f) return false;
    const float t = (plane_coord - ro_ax) / rd_ax;
    if (t <= 0.0f) return false;
    *out_grid_point = ro + rd * t;
    return true;
}

bool ViewContext::ComputeTargetCell(
    float local_x, float local_y, ToolMode mode,
    shapes::Vec3i* out_cell, int* out_face_axis,
    const std::unordered_set<int64_t>& skip) const {
    if (ctx == nullptr) return false;
    const Document& doc = ctx->document;

    simd::float3 ray_origin_grid, ray_dir_grid;
    if (!RayAt(local_x, local_y, &ray_origin_grid, &ray_dir_grid)) {
        return false;
    }

    RayHit hit;
    bool hit_voxel;
    // During a drag-Add stroke, skip cells we just placed so the raycast
    // keeps hitting the original surface. Other modes (Remove, Paint)
    // and non-drag interactions raycast against the live grid.
    if (mode == ToolMode::Add && !skip.empty()) {
        hit_voxel = RaycastIgnoring(doc.grid, ray_origin_grid,
                                    ray_dir_grid, 4096.0f, skip, &hit);
    } else {
        hit_voxel = Raycast(doc.grid, ray_origin_grid,
                            ray_dir_grid, 4096.0f, &hit);
    }

    int target_x = 0;
    int target_y = 0;
    int target_z = 0;
    int face_axis = 2;  // ground-plane fallback faces +Z
    if (hit_voxel) {
        target_x = hit.x;
        target_y = hit.y;
        target_z = hit.z;
        if (hit.axis >= 0) face_axis = hit.axis;
        if (mode == ToolMode::Add) {
            if (hit.axis < 0) return false;  // ray started inside a voxel
            if (hit.axis == 0) target_x += hit.sign;
            else if (hit.axis == 1) target_y += hit.sign;
            else if (hit.axis == 2) target_z += hit.sign;
        }
    } else {
        // Empty-space click. Add falls back to the nearest camera-facing
        // wall of the edit volume; Remove/Paint still no-op here for
        // non-Line tools (a "remove empty space" brush doesn't mean
        // anything). ComputeLineEndpoint retries with Add mode so Line
        // endpoints can still anchor to a wall.
        if (mode != ToolMode::Add) return false;
        shapes::Vec3i wall_cell;
        int wall_axis = 0;
        if (!IntersectVolumeWall(ctx->document.volume,
                                 ray_origin_grid, ray_dir_grid,
                                 &wall_cell, &wall_axis)) {
            return false;
        }
        target_x = wall_cell.x;
        target_y = wall_cell.y;
        target_z = wall_cell.z;
        face_axis = wall_axis;
    }

    *out_cell = shapes::Vec3i{target_x, target_y, target_z};
    if (out_face_axis) *out_face_axis = face_axis;
    return true;
}

bool ViewContext::ComputeLineEndpoint(
    float local_x, float local_y, ToolMode mode,
    shapes::Vec3i* out_cell, int* out_face_axis) const {
    if (ComputeTargetCell(local_x, local_y, mode, out_cell, out_face_axis)) {
        return true;
    }
    if (mode == ToolMode::Add) return false;
    return ComputeTargetCell(local_x, local_y, ToolMode::Add,
                             out_cell, out_face_axis);
}

bool ViewContext::PickFace(float local_x, float local_y,
                           shapes::Vec3i* out_cell, int* out_axis,
                           int* out_sign, uint8_t* out_color) const {
    if (ctx == nullptr) return false;
    const Document& doc = ctx->document;

    simd::float3 ray_origin_grid, ray_dir_grid;
    if (!RayAt(local_x, local_y, &ray_origin_grid, &ray_dir_grid)) return false;

    // Same dual-volume strategy the renderer uses: try both grids and
    // take whichever is hit first. Without this, Cmd-drag on a moved
    // floating buffer fails because the doc-only picker can't see the
    // lifted cells anymore.
    RayHit hit_doc, hit_buf;
    bool got_doc = Raycast(doc.grid, ray_origin_grid, ray_dir_grid,
                           4096.0f, &hit_doc);
    bool got_buf = false;
    const FloatingBuffer& fb = ctx->floating_buffer;
    if (fb.active && !fb.grid.empty()) {
        const simd::float3 origin_buf{
            ray_origin_grid.x - static_cast<float>(fb.offset_x),
            ray_origin_grid.y - static_cast<float>(fb.offset_y),
            ray_origin_grid.z - static_cast<float>(fb.offset_z),
        };
        got_buf = Raycast(fb.grid, origin_buf, ray_dir_grid,
                          4096.0f, &hit_buf);
    }
    if (!got_doc && !got_buf) return false;
    const bool from_buf = got_buf && (!got_doc || hit_buf.t < hit_doc.t);
    const RayHit& hit = from_buf ? hit_buf : hit_doc;
    if (hit.axis < 0) return false;  // ray started inside a voxel — no face
    out_cell->x = hit.x + (from_buf ? fb.offset_x : 0);
    out_cell->y = hit.y + (from_buf ? fb.offset_y : 0);
    out_cell->z = hit.z + (from_buf ? fb.offset_z : 0);
    *out_axis = hit.axis;
    *out_sign = hit.sign;
    if (out_color) *out_color = hit.color;
    return true;
}

bool ViewContext::XformGizmoBounds(Bounds3* out) const {
    if (ctx == nullptr) return false;
    const FloatingBuffer& fb = ctx->floating_buffer;
    if (fb.active && !fb.grid.empty()) {
        Bounds3 wb = fb.grid.Bounds();
        wb.min_x += fb.offset_x; wb.max_x += fb.offset_x;
        wb.min_y += fb.offset_y; wb.max_y += fb.offset_y;
        wb.min_z += fb.offset_z; wb.max_z += fb.offset_z;
        *out = wb;
        return true;
    }
    const Selection& sel = ctx->selection;
    if (sel.active() && !sel.empty()) {
        *out = sel.bounds();
        return true;
    }
    return false;
}

int ViewContext::PickXformHandle(float local_x, float local_y) const {
    Bounds3 wb;
    if (!XformGizmoBounds(&wb)) return -1;
    if (viewport_w <= 0.0f || viewport_h <= 0.0f) return -1;
    const float aspect = viewport_w / viewport_h;
    const simd::float4x4 vp =
        camera.ProjectionMatrix(aspect) * camera.ViewMatrix();

    const float cur_x = local_x;
    const float cur_y = viewport_h - local_y;  // ImGui Y-down

    constexpr float kTipLengthVoxels = 4.0f;
    constexpr float kHitRadiusPx = 16.0f;
    int best = -1;
    float best_d2 = kHitRadiusPx * kHitRadiusPx;
    for (int f = 0; f < 6; ++f) {
        simd::float3 cw, nw;
        XformFaceWorldGeom(wb, f, &cw, &nw);
        const simd::float3 tip = cw + nw * kTipLengthVoxels;
        const simd::float4 clip = simd_mul(
            vp, simd::float4{tip.x, tip.y, tip.z, 1.0f});
        if (clip.w <= 0.001f) continue;
        const float ndc_x = clip.x / clip.w;
        const float ndc_y = clip.y / clip.w;
        const float sx = (ndc_x * 0.5f + 0.5f) * viewport_w;
        const float sy = (1.0f - (ndc_y * 0.5f + 0.5f)) * viewport_h;
        const float dx = sx - cur_x;
        const float dy = sy - cur_y;
        const float d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = f;
        }
    }
    return best;
}

int ViewContext::XformHandleDragVoxels(int face,
                                       float local_x, float local_y,
                                       float start_local_x, float start_local_y,
                                       const Bounds3& start_bounds) const {
    if (ctx == nullptr) return 0;
    if (viewport_w <= 0.0f || viewport_h <= 0.0f) return 0;
    const float aspect = viewport_w / viewport_h;
    const simd::float4x4 vp =
        camera.ProjectionMatrix(aspect) * camera.ViewMatrix();

    // World-space face geometry of the *original* (drag-start) bounds
    // — anchoring against a moving face would make 1 voxel of cursor
    // travel ≠ 1 voxel of growth, so the drag mapping would drift.
    Bounds3 wb = start_bounds;
    const FloatingBuffer& fb = ctx->floating_buffer;
    wb.min_x += fb.offset_x; wb.max_x += fb.offset_x;
    wb.min_y += fb.offset_y; wb.max_y += fb.offset_y;
    wb.min_z += fb.offset_z; wb.max_z += fb.offset_z;

    simd::float3 cw, nw;
    XformFaceWorldGeom(wb, face, &cw, &nw);
    auto to_ndc = [&](simd::float3 wp, simd::float2* ndc) -> bool {
        const simd::float4 clip = simd_mul(
            vp, simd::float4{wp.x, wp.y, wp.z, 1.0f});
        if (clip.w <= 1e-6f) return false;
        ndc->x = clip.x / clip.w;
        ndc->y = clip.y / clip.w;
        return true;
    };
    simd::float2 ndc0{}, ndc1{};
    if (!to_ndc(cw, &ndc0)) return 0;
    if (!to_ndc(cw + nw, &ndc1)) return 0;
    const simd::float2 dir{ndc1.x - ndc0.x, ndc1.y - ndc0.y};
    const float dir_len2 = dir.x * dir.x + dir.y * dir.y;
    if (dir_len2 < 1e-8f) return 0;

    const simd::float2 drag{
        ((local_x - start_local_x) / viewport_w) * 2.0f,
        ((local_y - start_local_y) / viewport_h) * 2.0f};
    const float t = (drag.x * dir.x + drag.y * dir.y) / dir_len2;
    return static_cast<int>(std::round(t));
}

int ViewContext::PickGenHandle(float local_x, float local_y,
                               const generators::Bounds3i& bounds) const {
    if (viewport_w <= 0.0f || viewport_h <= 0.0f) return -1;
    const float aspect = viewport_w / viewport_h;
    const simd::float4x4 vp =
        camera.ProjectionMatrix(aspect) * camera.ViewMatrix();

    const float cur_x = local_x;
    const float cur_y = viewport_h - local_y;  // ImGui Y-down

    constexpr float kTipLengthVoxels = 4.0f;
    constexpr float kHitRadiusPx = 16.0f;
    int best = -1;
    float best_d2 = kHitRadiusPx * kHitRadiusPx;
    for (int f = 0; f < 6; ++f) {
        simd::float3 cw, nw;
        GizmoFaceWorldGeom(bounds, f, &cw, &nw);
        const simd::float3 tip = cw + nw * kTipLengthVoxels;
        const simd::float4 clip = simd_mul(
            vp, simd::float4{tip.x, tip.y, tip.z, 1.0f});
        if (clip.w <= 0.001f) continue;
        const float ndc_x = clip.x / clip.w;
        const float ndc_y = clip.y / clip.w;
        const float sx = (ndc_x * 0.5f + 0.5f) * viewport_w;
        const float sy = (1.0f - (ndc_y * 0.5f + 0.5f)) * viewport_h;
        const float dx = sx - cur_x;
        const float dy = sy - cur_y;
        const float d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = f;
        }
    }
    return best;
}

int ViewContext::GenHandleDragVoxels(int face,
                                     float local_x, float local_y,
                                     float start_local_x, float start_local_y,
                                     const generators::Bounds3i& start_bounds) const {
    if (viewport_w <= 0.0f || viewport_h <= 0.0f) return 0;
    const float aspect = viewport_w / viewport_h;
    const simd::float4x4 vp =
        camera.ProjectionMatrix(aspect) * camera.ViewMatrix();

    simd::float3 cw, nw;
    GizmoFaceWorldGeom(start_bounds, face, &cw, &nw);

    auto to_ndc = [&](simd::float3 wp, simd::float2* ndc) -> bool {
        const simd::float4 clip = simd_mul(
            vp, simd::float4{wp.x, wp.y, wp.z, 1.0f});
        if (clip.w <= 1e-6f) return false;
        ndc->x = clip.x / clip.w;
        ndc->y = clip.y / clip.w;
        return true;
    };
    simd::float2 ndc0{}, ndc1{};
    if (!to_ndc(cw, &ndc0)) return 0;
    if (!to_ndc(cw + nw, &ndc1)) return 0;
    const simd::float2 dir{ndc1.x - ndc0.x, ndc1.y - ndc0.y};
    const float dir_len2 = dir.x * dir.x + dir.y * dir.y;
    if (dir_len2 < 1e-8f) return 0;

    const simd::float2 drag{
        ((local_x - start_local_x) / viewport_w) * 2.0f,
        ((local_y - start_local_y) / viewport_h) * 2.0f};
    const float t = (drag.x * dir.x + drag.y * dir.y) / dir_len2;
    return static_cast<int>(std::round(t));
}

int ViewContext::FaceDragVoxels(float local_x, float local_y,
                                const shapes::Vec3i& anchor_cell,
                                int face_axis, int face_sign,
                                float anchor_local_x, float anchor_local_y) const {
    if (viewport_w <= 0.0f || viewport_h <= 0.0f) return 0;
    const float aspect = viewport_w / viewport_h;
    const simd::float4x4 vp =
        camera.ProjectionMatrix(aspect) * camera.ViewMatrix();

    const simd::float3 p0_grid{
        static_cast<float>(anchor_cell.x) + 0.5f,
        static_cast<float>(anchor_cell.y) + 0.5f,
        static_cast<float>(anchor_cell.z) + 0.5f};
    const simd::float3 p0_world{p0_grid.x, p0_grid.z, -p0_grid.y};
    simd::float3 n_grid{0, 0, 0};
    if (face_axis == 0)      n_grid.x = static_cast<float>(face_sign);
    else if (face_axis == 1) n_grid.y = static_cast<float>(face_sign);
    else                     n_grid.z = static_cast<float>(face_sign);
    const simd::float3 n_world{n_grid.x, n_grid.z, -n_grid.y};

    auto to_ndc = [&](simd::float3 wp, simd::float2* ndc) -> bool {
        const simd::float4 clip =
            simd_mul(vp, simd::float4{wp.x, wp.y, wp.z, 1.0f});
        if (clip.w <= 1e-6f) return false;
        ndc->x = clip.x / clip.w;
        ndc->y = clip.y / clip.w;
        return true;
    };
    simd::float2 ndc0{}, ndc1{};
    if (!to_ndc(p0_world, &ndc0)) return 0;
    if (!to_ndc(p0_world + n_world, &ndc1)) return 0;
    const simd::float2 dir{ndc1.x - ndc0.x, ndc1.y - ndc0.y};
    const float dir_len2 = dir.x * dir.x + dir.y * dir.y;
    if (dir_len2 < 1e-8f) return 0;

    const simd::float2 drag{
        ((local_x - anchor_local_x) / viewport_w) * 2.0f,
        ((local_y - anchor_local_y) / viewport_h) * 2.0f};
    const float t = (drag.x * dir.x + drag.y * dir.y) / dir_len2;
    return static_cast<int>(std::round(t));
}

}  // namespace macvoxel
