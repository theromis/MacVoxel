#pragma once

#include <simd/simd.h>

namespace macvoxel {

class Camera {
public:
    Camera() = default;

    simd::float3 target = simd::float3{0.0f, 0.0f, 0.0f};
    float distance = 5.0f;
    float yaw = 0.5236f;    // ~30°
    float pitch = 0.4363f;  // ~25°
    float fov_y = 0.7854f;  // ~45°
    float near_plane = 0.05f;
    float far_plane = 1000.0f;

    simd::float3 Position() const;
    simd::float4x4 ViewMatrix() const;
    simd::float4x4 ProjectionMatrix(float aspect) const;

    void Orbit(float dx_points, float dy_points);
    void Pan(float dx_points, float dy_points);
    void Zoom(float ticks);

    // Reset orientation, set the orbit target to `target_world`, and pick
    // a distance that fits a cube of side `extent` around that target in
    // the current FOV. Called when a new document is loaded.
    void Frame(simd::float3 target_world, float extent);
};

}  // namespace macvoxel
