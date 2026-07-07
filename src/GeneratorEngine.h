#pragma once

#import <Metal/Metal.h>

#include "Generators.h"

@class VolumeTexture;

// GPU-backed generator runner. Owns one Metal compute pipeline state
// per generator kind. Each kernel evaluates its primitive's
// inside-test for every cell in a dispatch bbox and writes the
// resulting palette / 0 into a target VolumeTexture's preview tex
// (tex_t). The rasterizer composites tex_t on top of the doc tex
// during the drag-out; on confirm, the preview is promoted into the
// doc via the shared shape-commit kernel and a per-cell history diff
// is captured from the texture readback.
//
// Async: each `dispatchInto:` commits its command buffer and returns
// without waiting; `waitForPendingWork` is the barrier the controller
// uses at confirm time before reading the texture back.
@interface GeneratorEngine : NSObject

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                            commandQueue:(nonnull id<MTLCommandQueue>)queue;

// Dispatch the kernel into `texture`'s preview tex. The kernel runs
// over the UNION of `bounds` and `last_bounds` in texture-local
// coords — cells the previous dispatch wrote that the new one
// doesn't cover get zeroed out by the kernel. Passing an empty
// last_bounds (x1<x0) dispatches only over the current bounds.
// `clip` (world cells, inclusive) bounds the dispatch region on top
// of the texture extent — the gizmo may overhang the writable edit
// region, whose cells must never be touched.
- (void)dispatchInto:(nonnull VolumeTexture*)texture
                kind:(macvoxel::generators::Kind)kind
              bounds:(macvoxel::generators::Bounds3i)bounds
          lastBounds:(macvoxel::generators::Bounds3i)last_bounds
                clip:(macvoxel::generators::Bounds3i)clip
              params:(const macvoxel::generators::Params&)params;

- (void)waitForPendingWork;

@end
