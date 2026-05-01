#pragma once

#include <cstdint>

namespace macvoxel {

enum class MaterialType : uint8_t {
    Diffuse = 0,
    Metal = 1,
    Emissive = 2,
    Glass = 3,
};

// Per-palette-entry material attributes. Stored alongside Color in the
// Palette. The ray-cast renderer ignores these in Phase 7 — it shades
// purely from the diffuse color. Phase 8's path tracer reads them for
// reflections, transmission, emissive contribution, and microfacet
// roughness.
struct Material {
    MaterialType type = MaterialType::Diffuse;
    float roughness = 1.0f;     // 0 = mirror-smooth, 1 = matte
    float metallic = 0.0f;      // 0 = dielectric, 1 = pure metal
    float emission = 0.0f;      // 0 = non-emitter; >0 multiplier on diffuse color
    float transparency = 0.0f;  // 0 = opaque, 1 = fully transmissive
    float ior = 1.5f;           // index of refraction (~1.5 is glass)
};

}  // namespace macvoxel
