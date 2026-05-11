#pragma once

#include <cstdint>

namespace macvoxel::generators {

// Inclusive AABB in voxel-cell coordinates. (x0..x1) × (y0..y1) × (z0..z1)
// is the working volume for a generator. Generators are expected to write
// only cells within these bounds.
struct Bounds3i {
    int32_t x0;
    int32_t y0;
    int32_t z0;
    int32_t x1;
    int32_t y1;
    int32_t z1;
};

// What primitive a generator produces. Each kind is implemented as its
// own MSL compute kernel; the engine selects a pipeline state by kind.
// New kinds are added by writing a kernel and registering it in the
// engine's kernel table.
enum class Kind : uint32_t {
    Ellipsoid = 0,
    Cylinder,
    Cone,
    Pyramid,
    Perlin,
    // Maze, Fractal — added in follow-ups
    Count_,
};

// Per-generator parameters. A single struct shared across kinds; each
// kernel reads only the fields relevant to it. Adding parameters is
// cheap as long as old kernels keep ignoring fields they don't know
// about. For built-ins this is sufficient; the eventual user-shader
// path will need a richer parameter system, but that's a separate
// project.
struct Params {
    // palette_idx is the color a generator stamps at every cell it
    // produces. Generators that want per-cell color (Perlin, Maze)
    // will get additional fields here.
    uint8_t palette_idx = 1;
    // Cylinder / Cone / Pyramid: axis along which the primitive is
    // oriented (0 = X, 1 = Y, 2 = Z). Cylinder treats this as its
    // symmetry axis; Cone / Pyramid taper along it. Y is the default
    // since vertical primitives are the most common case.
    uint32_t axis = 1;
    // Cone / Pyramid: which end of the bounding box holds the apex.
    // 0 = -axis face (apex at bounds min on that axis); 1 = +axis
    // face (apex at bounds max). Ignored by Cylinder.
    uint32_t apex_at_max = 1;
    // Perlin: voxels per noise "feature" — larger = chunkier blobs.
    float    noise_scale = 8.0f;
    // Perlin: cells fill when normalized fBm output ≥ threshold.
    // 0 fills everything, 1 fills nothing; 0.5 is the natural midline.
    float    noise_threshold = 0.5f;
    // Perlin: number of fBm octaves (1..6 in the UI). Each octave
    // doubles frequency and halves amplitude.
    uint32_t noise_octaves = 4;
    // Perlin: seed for the lattice hash; pinned per-document so a
    // given (bounds, params, seed) tuple is reproducible.
    uint32_t noise_seed = 1;
};

}  // namespace macvoxel::generators
