#include "Camera.h"

#include <algorithm>
#include <cmath>

namespace macvoxel {
namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr float kOrbitDegPerPx = 0.4f;
constexpr float kPanScale = 0.0025f;     // multiplied by distance for distance-uniform feel
constexpr float kZoomBase = 0.9f;        // distance *= kZoomBase ^ ticks
constexpr float kPitchLimit = 1.5533f;   // ~89° in radians, avoids gimbal lock
constexpr float kDistanceMin = 0.1f;
constexpr float kDistanceMax = 1000.0f;

inline float deg_to_rad(float deg) { return deg * (kPi / 180.0f); }

}  // namespace

simd::float3 Camera::Position() const {
    const float cp = std::cos(pitch);
    const float sp = std::sin(pitch);
    const float cy = std::cos(yaw);
    const float sy = std::sin(yaw);
    return target + distance * simd::float3{cp * sy, sp, cp * cy};
}

simd::float4x4 Camera::ViewMatrix() const {
    const simd::float3 eye = Position();
    const simd::float3 up_world{0.0f, 1.0f, 0.0f};
    const simd::float3 f = simd::normalize(target - eye);
    const simd::float3 r = simd::normalize(simd::cross(f, up_world));
    const simd::float3 u = simd::cross(r, f);

    simd::float4x4 m;
    m.columns[0] = simd::float4{r.x, u.x, -f.x, 0.0f};
    m.columns[1] = simd::float4{r.y, u.y, -f.y, 0.0f};
    m.columns[2] = simd::float4{r.z, u.z, -f.z, 0.0f};
    m.columns[3] = simd::float4{
        -simd::dot(r, eye),
        -simd::dot(u, eye),
        simd::dot(f, eye),
        1.0f,
    };
    return m;
}

simd::float4x4 Camera::ProjectionMatrix(float aspect) const {
    // Right-handed perspective with NDC z in [0, 1] (Metal convention).
    const float f = 1.0f / std::tan(fov_y * 0.5f);
    const float a = f / aspect;
    const float A = far_plane / (near_plane - far_plane);
    const float B = near_plane * A;

    simd::float4x4 m;
    m.columns[0] = simd::float4{a, 0.0f, 0.0f, 0.0f};
    m.columns[1] = simd::float4{0.0f, f, 0.0f, 0.0f};
    m.columns[2] = simd::float4{0.0f, 0.0f, A, -1.0f};
    m.columns[3] = simd::float4{0.0f, 0.0f, B, 0.0f};
    return m;
}

void Camera::Orbit(float dx_points, float dy_points) {
    // Drag-the-world: cursor drags the scene, so the camera moves opposite
    // to the cursor delta. yaw/pitch decrease as the user drags right/up.
    yaw -= deg_to_rad(dx_points * kOrbitDegPerPx);
    pitch -= deg_to_rad(dy_points * kOrbitDegPerPx);
    pitch = std::clamp(pitch, -kPitchLimit, kPitchLimit);
}

void Camera::Pan(float dx_points, float dy_points) {
    const simd::float3 eye = Position();
    const simd::float3 up_world{0.0f, 1.0f, 0.0f};
    const simd::float3 f = simd::normalize(target - eye);
    const simd::float3 r = simd::normalize(simd::cross(f, up_world));
    const simd::float3 u = simd::cross(r, f);

    const float scale = kPanScale * distance;
    // Drag-the-world: scene follows the cursor, so target moves opposite to
    // the cursor delta in screen space.
    target -= r * (dx_points * scale);
    target -= u * (dy_points * scale);
}

void Camera::Zoom(float ticks) {
    distance *= std::pow(kZoomBase, ticks);
    distance = std::clamp(distance, kDistanceMin, kDistanceMax);
}

}  // namespace macvoxel
