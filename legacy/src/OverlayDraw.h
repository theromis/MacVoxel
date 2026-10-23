#pragma once

#include <cstdint>
#include <vector>

#include <simd/simd.h>

namespace macvoxel {

// Tiny immediate-mode 2D drawing API that replaces ImGui::ImDrawList for
// the editor's overlay primitives — selection / hover / marquee /
// transform-handle / generator-gizmo. Coordinates are pixels in
// view-local space, top-left origin (matching the 2D convention the
// existing controllers use after they project from world to screen).
//
// Filled by the controllers each frame; drained by SceneOverlayRenderer
// into a Metal vertex buffer. All primitives reduce to triangles
// internally so the GPU pipeline is a single triangle-list draw.
class OverlayDraw {
public:
    struct Vertex {
        float x, y;
        uint32_t rgba;  // 0xAABBGGRR — same byte order as IM_COL32
    };

    void Clear() { vertices_.clear(); }

    // Lines drawn at `thickness` pixels by expansion to a 4-vertex quad.
    void AddLine(simd::float2 p0, simd::float2 p1,
                 uint32_t color, float thickness);

    // Outlined rectangle, axis-aligned. (min, max) corners.
    void AddRect(simd::float2 min, simd::float2 max,
                 uint32_t color, float thickness = 1.0f);

    // Filled rectangle.
    void AddRectFilled(simd::float2 min, simd::float2 max, uint32_t color);

    // Filled triangle.
    void AddTriangleFilled(simd::float2 p0, simd::float2 p1, simd::float2 p2,
                           uint32_t color);

    const std::vector<Vertex>& vertices() const { return vertices_; }
    bool empty() const { return vertices_.empty(); }

private:
    std::vector<Vertex> vertices_;
};

// Pack RGBA bytes (0..255) into the 0xAABBGGRR layout the renderer
// expects. Replaces ImGui's IM_COL32 macro so controllers don't need
// to include ImGui headers.
inline constexpr uint32_t Rgba8(int r, int g, int b, int a) {
    return (static_cast<uint32_t>(a) << 24) |
           (static_cast<uint32_t>(b) << 16) |
           (static_cast<uint32_t>(g) << 8)  |
            static_cast<uint32_t>(r);
}

}  // namespace macvoxel
