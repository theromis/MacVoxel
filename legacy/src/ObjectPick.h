#pragma once

#include <simd/simd.h>

namespace macvoxel {

struct Scene;

// Pick the scene object under a grid-space ray: slab-test every
// non-hidden object's world AABB (signed permutations keep AABBs
// axis-aligned), then confirm candidates nearest-first with an exact
// DDA over the model grid through the inverse-transformed ray. Returns
// the object index or -1.
int PickObject(const Scene& scene, simd::float3 ray_origin,
               simd::float3 ray_dir, float t_max);

}  // namespace macvoxel
