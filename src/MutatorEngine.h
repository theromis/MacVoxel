#pragma once

#include "Mutators.h"

#include <cstdint>

namespace macvoxel {

// CPU-side mutator dispatch parameters. World cell coords; the engine
// translates to texture-local + builds the MSL uniforms. Pure C++ so
// MutatorTool (a .cpp) can name the type without dragging in Metal.h.
struct MutatorDispatchParams {
    mutators::Kind kind;
    // Cursor AOE bbox in world cells, inclusive. The kernel dispatches
    // over this AABB and tests each thread against the actual brush
    // footprint (sphere / cube / 2D slab) inline.
    int32_t aoe_x0, aoe_y0, aoe_z0;
    int32_t aoe_x1, aoe_y1, aoe_z1;
    // Cursor cell — the AOE's footprint center.
    int32_t center_x, center_y, center_z;
    int32_t brush_size;
    int32_t brush_shape;   // 0 sq, 1 circle
    int32_t brush_3d;      // 0 = 2D slab on `face_axis`'s slice
    int32_t face_axis;     // 0..2
    uint32_t stroke_id;    // per-mouseDown RNG salt
    // Foliage knobs (read by Foliage kernel; future kinds add fields).
    uint32_t seed_color;
    float    density;
};

}  // namespace macvoxel

#ifdef __OBJC__

#import <Metal/Metal.h>

@class VolumeTexture;

// One PSO per Mutator kind. Same async pattern as GeneratorEngine /
// ShapeEngine: a dedicated command queue, fire-and-forget dispatches
// during a stroke, `waitForPendingWork` at end-of-stroke before the
// commit-readback round-trip.
@interface MutatorEngine : NSObject

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                            commandQueue:(nonnull id<MTLCommandQueue>)queue;

- (void)dispatchInto:(nonnull VolumeTexture*)texture
              params:(const macvoxel::MutatorDispatchParams&)params;

- (void)waitForPendingWork;

@end

#endif  // __OBJC__
