#include <metal_stdlib>
using namespace metal;

// Vertex layout matches macvoxel::OverlayDraw::Vertex:
//   { float x, y; uint32_t rgba; }  — 12 bytes, 4-byte aligned.
// packed_float2 is the 4-aligned variant; using float2 here would
// promote the struct to 16 bytes and break the layout contract.
struct OverlayVertex {
    packed_float2 pos;
    uint32_t rgba;
};

struct OverlayVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex OverlayVertexOut overlay_vertex(uint vid [[vertex_id]],
                                       device const OverlayVertex* verts
                                           [[buffer(0)]],
                                       constant float2& viewport_size
                                           [[buffer(1)]]) {
    OverlayVertex v = verts[vid];
    OverlayVertexOut out;
    // Pixel-space, top-left origin → NDC.
    out.position = float4(
        v.pos.x / viewport_size.x * 2.0f - 1.0f,
        1.0f - v.pos.y / viewport_size.y * 2.0f,
        0.0f, 1.0f);
    float r = float((v.rgba >>  0u) & 0xffu) / 255.0f;
    float g = float((v.rgba >>  8u) & 0xffu) / 255.0f;
    float b = float((v.rgba >> 16u) & 0xffu) / 255.0f;
    float a = float((v.rgba >> 24u) & 0xffu) / 255.0f;
    // Pre-multiply alpha so the pipeline's One / OneMinusSrcAlpha
    // blend reproduces straight-alpha semantics correctly.
    out.color = float4(r * a, g * a, b * a, a);
    return out;
}

fragment float4 overlay_fragment(OverlayVertexOut in [[stage_in]]) {
    return in.color;
}
