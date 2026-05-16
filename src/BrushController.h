#pragma once

#include "InteractionState.h"

#include <functional>

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
struct BrushParams;
struct Bbox3;
}

// Brush: bare-click stroke painter. The dispatcher (MetalScene) routes
// here for any tool that doesn't claim mouseDown via its own branch
// — the catch-all default. Cmd flips the stroke to Remove.
//
// B2: kernel dispatch is async. During the stroke `doc.grid` and
// `doc.volume_shadow` stay frozen at pre-stroke state, the texture is
// the live state, and `drag_skip_cells` is populated CPU-side from the
// brush footprint (using doc.grid.Get as the still-pre-stroke
// occupancy oracle). At OnMouseUp the stroke's bbox is read back from
// the texture, diffed against the shadow, and batch-applied to grid /
// shadow / history.
namespace macvoxel::brush_controller {

// Per-stamp kernel dispatch — async, no diff readback. The closure is
// built by MetalScene around `BrushEngine` + the doc's `VolumeTexture`.
using StampFn = std::function<void(const BrushParams& params)>;

// End-of-stroke barrier + bbox readback. Waits for the engine's
// command queue to drain, then blits the bbox region of the doc
// texture into `out_bytes` in x-fastest dense layout.
using ReadBackFn =
    std::function<void(const Bbox3& bbox, std::vector<uint8_t>* out_bytes)>;

void OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e,
                 const StampFn& stamp);

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e,
                    const StampFn& stamp);

void OnMouseUp(EditorContext& ctx, InteractionState& state,
               const ReadBackFn& readback);

}  // namespace macvoxel::brush_controller
