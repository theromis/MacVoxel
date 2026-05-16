#pragma once

#include "InteractionState.h"
#include "ToolState.h"

#include <functional>
#include <vector>

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
struct ShapeParams;
struct Bbox3;
}

// Two-click shape tools: Line, Circle, Square, Box. Click 1 anchors;
// drag through click 2 dispatches the shape kernel into `tex_t` each
// mouseDragged event; mouseUp commits via a copy kernel + diff
// readback. The doc grid stays frozen until commit (same model as
// the GPU-authoritative brush).
namespace macvoxel::shape_controller {

// Async kernel dispatch — writes the shape's preview into tex_t
// (with palette / 0 per the mode rule). Built by MetalScene around
// the doc VolumeTexture + a ShapeEngine.
using PreviewFn = std::function<void(const ShapeParams& params)>;

// Line tool's "project" mode dispatch — same shape preview write,
// but the picked cells (one per oversampled screen-space step) come
// from a CPU-side raycast walk that the kernel can't replicate
// (needs the live camera + doc grid). `cells_xyz` is packed
// [x,y,z, x,y,z, ...].
using PreviewLineProjectFn = std::function<void(
    const ShapeParams& params,
    const int32_t* cells_xyz, size_t cell_count)>;

// Same dispatch shape, but for the commit kernel — promotes preview
// cells into tex_a + clears preview cells. Built by MetalScene.
using CommitFn = std::function<void(const ShapeParams& params)>;

// End-of-stroke barrier + bbox texture readback. Identical contract
// to the brush controller's ReadBackFn: waits for the kernel queue,
// then blits the (texture-local) bbox of `tex_a` into `out_bytes` in
// x-fastest dense layout.
using ReadBackFn =
    std::function<void(const Bbox3& world_bbox, std::vector<uint8_t>* out_bytes)>;

// Pick the anchor cell, capture face axis / mode / screen pixel /
// tool kind into TwoClickAnchor. Returns false if the click missed
// every cell *and* the empty-space ground-plane fallback wasn't
// usable (e.g., camera looking straight up). Exposed because the
// Generator tool also needs anchor seeding before its gizmo activates.
bool BeginAnchor(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e,
                 ToolMode mode);

// Click 1: anchor + activate live preview + first kernel dispatch.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e,
                 const PreviewFn& preview,
                 const PreviewLineProjectFn& preview_project);

// Mouse moved while held — re-dispatches the shape kernel with the
// new endpoint. Cells the previous frame wrote and the current frame
// doesn't cover get zeroed out by the kernel (single dispatch over
// the union of old & new bboxes).
void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e,
                    const PreviewFn& preview,
                    const PreviewLineProjectFn& preview_project);

// Commit the preview through history + clear preview / anchor.
void OnMouseUp(EditorContext& ctx, InteractionState& state,
               const CommitFn& commit, const ReadBackFn& readback);

}  // namespace macvoxel::shape_controller
