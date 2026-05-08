#pragma once

#import <Metal/Metal.h>

#include <vector>

#include "Generators.h"
#include "Shapes.h"  // shapes::Vec3i — output cell list

// GPU-backed generator runner. Owns a Metal compute pipeline state per
// generator kind, an output buffer (grown on demand to hold the
// max-possible voxel count for the requested bounds), and an atomic
// counter buffer.
//
// Each generator is implemented as a Metal compute kernel that scans the
// requested AABB at one thread per cell, evaluates the primitive's
// inside-test, and atomically appends the cell coordinate to the output
// buffer. After the dispatch finishes the engine reads the counter and
// copies that many cells into the caller's std::vector.
//
// Synchronous: each call commits a command buffer and waits for it. Fine
// for the live-preview drag rates we'll initially see; if it becomes a
// bottleneck the right move is double-buffered async dispatch with the
// last-frame's result kept on screen.
@interface GeneratorEngine : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)queue;

// Run the generator for `kind` over `bounds` with `params`. Cells the
// kernel marks as "filled" are appended to `out` in undefined order
// (atomic-append output, no ordering guarantee).
- (void)generateInto:(std::vector<macvoxel::shapes::Vec3i>&)out
                kind:(macvoxel::generators::Kind)kind
              bounds:(macvoxel::generators::Bounds3i)bounds
              params:(const macvoxel::generators::Params&)params;

@end
