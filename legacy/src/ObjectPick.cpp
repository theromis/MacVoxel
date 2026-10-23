#include "ObjectPick.h"

#include "Raycast.h"
#include "VoxScene.h"

#include <algorithm>
#include <vector>

namespace macvoxel {

int PickObject(const Scene& scene, simd::float3 ray_origin,
               simd::float3 ray_dir, float t_max) {
    struct Candidate {
        int index;
        float t_enter;
    };
    std::vector<Candidate> candidates;
    for (size_t i = 0; i < scene.objects.size(); ++i) {
        const SceneObject& o = scene.objects[i];
        if (o.hidden) continue;
        Bounds3 b;
        if (!ObjectWorldBounds(scene, static_cast<int>(i), &b)) continue;
        const simd::float3 bmin{static_cast<float>(b.min_x),
                                static_cast<float>(b.min_y),
                                static_cast<float>(b.min_z)};
        const simd::float3 bmax{static_cast<float>(b.max_x + 1),
                                static_cast<float>(b.max_y + 1),
                                static_cast<float>(b.max_z + 1)};
        const simd::float3 inv = 1.0f / ray_dir;
        const simd::float3 t1 = (bmin - ray_origin) * inv;
        const simd::float3 t2 = (bmax - ray_origin) * inv;
        const simd::float3 lo = simd_min(t1, t2);
        const simd::float3 hi = simd_max(t1, t2);
        const float t_enter = std::max({lo.x, lo.y, lo.z});
        const float t_exit = std::min({hi.x, hi.y, hi.z});
        if (t_exit < 0.0f || t_enter > t_exit || t_enter > t_max) continue;
        candidates.push_back(
            {static_cast<int>(i), std::max(t_enter, 0.0f)});
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const Candidate& a, const Candidate& b) {
                  return a.t_enter < b.t_enter;
              });

    // Nearest-AABB order isn't a guaranteed nearest-voxel order for
    // overlapping boxes, but confirming candidates in t_enter order and
    // taking the closest *confirmed* hit is.
    int best = -1;
    float best_t = t_max;
    for (const Candidate& c : candidates) {
        if (c.t_enter > best_t) break;  // sorted: nothing closer remains
        const SceneObject& o =
            scene.objects[static_cast<size_t>(c.index)];
        const SceneModel& model =
            scene.models[static_cast<size_t>(o.model_id)];
        // Grid-space → model-local: l = Rᵀ(w − T) + h. The float ray
        // uses the same map with the int matrix applied per component.
        const RotMat rinv = o.world_r.Transposed();
        const simd::float3 rel{
            ray_origin.x - static_cast<float>(o.world_t.x),
            ray_origin.y - static_cast<float>(o.world_t.y),
            ray_origin.z - static_cast<float>(o.world_t.z)};
        auto apply = [&rinv](simd::float3 v) {
            return simd::float3{
                rinv.m[0][0] * v.x + rinv.m[0][1] * v.y + rinv.m[0][2] * v.z,
                rinv.m[1][0] * v.x + rinv.m[1][1] * v.y + rinv.m[1][2] * v.z,
                rinv.m[2][0] * v.x + rinv.m[2][1] * v.y + rinv.m[2][2] * v.z,
            };
        };
        const simd::float3 h{static_cast<float>(model.dims[0] / 2),
                             static_cast<float>(model.dims[1] / 2),
                             static_cast<float>(model.dims[2] / 2)};
        // Center-referenced map: the integer bake is w = R(l−h)+T over
        // cell *indices*; for continuous points the half-open cell
        // interval flips along negated axes, so map relative to cell
        // centers (−0.5 in, +0.5 out) to keep floor(q) on the right cell.
        const simd::float3 ro_l = apply(rel - 0.5f) + h + 0.5f;
        const simd::float3 rd_l = apply(ray_dir);
        RayHit hit;
        if (Raycast(model.grid, ro_l, rd_l, best_t, &hit) && hit.t < best_t) {
            best = c.index;
            best_t = hit.t;
        }
    }
    return best;
}

}  // namespace macvoxel
