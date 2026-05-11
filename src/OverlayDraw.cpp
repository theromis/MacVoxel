#include "OverlayDraw.h"

#include <cmath>

namespace macvoxel {

void OverlayDraw::AddLine(simd::float2 p0, simd::float2 p1,
                          uint32_t color, float thickness) {
    const float dx = p1.x - p0.x;
    const float dy = p1.y - p0.y;
    const float len = std::sqrt(dx * dx + dy * dy);
    if (len < 1e-3f) return;
    const float half = thickness * 0.5f;
    const float nx = -dy / len * half;
    const float ny =  dx / len * half;

    const Vertex a{p0.x + nx, p0.y + ny, color};
    const Vertex b{p0.x - nx, p0.y - ny, color};
    const Vertex c{p1.x - nx, p1.y - ny, color};
    const Vertex d{p1.x + nx, p1.y + ny, color};

    vertices_.push_back(a);
    vertices_.push_back(b);
    vertices_.push_back(c);

    vertices_.push_back(a);
    vertices_.push_back(c);
    vertices_.push_back(d);
}

void OverlayDraw::AddRect(simd::float2 mn, simd::float2 mx,
                          uint32_t color, float thickness) {
    AddLine({mn.x, mn.y}, {mx.x, mn.y}, color, thickness);
    AddLine({mx.x, mn.y}, {mx.x, mx.y}, color, thickness);
    AddLine({mx.x, mx.y}, {mn.x, mx.y}, color, thickness);
    AddLine({mn.x, mx.y}, {mn.x, mn.y}, color, thickness);
}

void OverlayDraw::AddRectFilled(simd::float2 mn, simd::float2 mx, uint32_t color) {
    const Vertex tl{mn.x, mn.y, color};
    const Vertex tr{mx.x, mn.y, color};
    const Vertex br{mx.x, mx.y, color};
    const Vertex bl{mn.x, mx.y, color};
    vertices_.push_back(tl);
    vertices_.push_back(tr);
    vertices_.push_back(br);
    vertices_.push_back(tl);
    vertices_.push_back(br);
    vertices_.push_back(bl);
}

void OverlayDraw::AddTriangleFilled(simd::float2 p0, simd::float2 p1, simd::float2 p2,
                                    uint32_t color) {
    vertices_.push_back({p0.x, p0.y, color});
    vertices_.push_back({p1.x, p1.y, color});
    vertices_.push_back({p2.x, p2.y, color});
}

}  // namespace macvoxel
