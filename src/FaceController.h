#pragma once

#include "InteractionState.h"

#include <cstdint>
#include <functional>
#include <vector>

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
struct CellPalette;
}

// Face tool: click selects a coplanar same-color flood region whose
// face on the clicked side is exposed; drag extrudes (positive,
// outward) or insets (negative, inward) by an integer number of voxel
// layers along the face normal.
//
// Phase B3c: flood-fill stays CPU (needs doc.grid for same-color
// matching), but the per-frame extrusion writes go through the
// shape engine's tex_t. Each mouseDragged event enumerates the
// current layer of cells with their target palettes (Add+ = source
// or palette color; Add- / Remove = 0; Paint = palette where doc
// has a non-empty cell) and dispatches the stamp_cells kernel. The
// rasterizer composites tex_t over the doc; commit promotes via
// commit_cells + a bbox readback for the per-cell history diff.
//
// Mode dispatch (mode is frozen at click in TwoClickAnchor::mode):
//   Add    — signed d. Positive extrudes; negative insets (erases).
//            Extrude color comes from `face_with` (read live so the
//            user can flip Geometry/Palette mid-drag and see it).
//   Remove — |d| layers, always inset (drag direction ignored).
//   Paint  — |d| inward layers, repaint existing voxels with the
//            palette color. Empty cells skipped (Paint never fills).
namespace macvoxel::face_controller {

// Async dispatch closures, built by MetalScene around ShapeEngine +
// the doc VolumeTexture. Same pattern as the brush / shape / generator
// tools.
using StampCellsFn = std::function<void(
    const CellPalette* cells, std::size_t count)>;
using CommitCellsFn = std::function<void(
    const CellPalette* cells, std::size_t count)>;
using ClearBboxFn = std::function<void(
    int32_t x0, int32_t y0, int32_t z0,
    int32_t x1, int32_t y1, int32_t z1)>;
using ReadBackFn = std::function<void(
    int32_t x0, int32_t y0, int32_t z0,
    int32_t x1, int32_t y1, int32_t z1,
    std::vector<uint8_t>* out_bytes)>;

// Pick the clicked face, run a flood fill on the seed plane, set up
// FaceTool state, activate the live preview, do the first refresh
// (the bare-click 1-layer placement). Returns false if no face was
// under the cursor.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e,
                 const StampCellsFn& stamp,
                 const ClearBboxFn& clear_bbox);

// Refresh the preview at the cursor's current cell. Dispatches the
// stamp kernel only when d or face_with actually changed
// (Generator-style dirty check) to keep idle event cost near zero.
void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e,
                    const StampCellsFn& stamp,
                    const ClearBboxFn& clear_bbox);

// Re-converge to the release cursor, dispatch commit_cells, read
// back the affected bbox + diff against shadow, apply via
// Document::ApplyChanges + EditHistory::RecordBatch. Clear face state.
void OnMouseUp(EditorContext& ctx, InteractionState& state,
               const ViewContext& vc, const MouseEvent& e,
               const StampCellsFn& stamp,
               const CommitCellsFn& commit,
               const ClearBboxFn& clear_bbox,
               const ReadBackFn& readback);

}  // namespace macvoxel::face_controller
