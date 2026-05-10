#include "FaceController.h"

#include "Document.h"
#include "EditorContext.h"
#include "Input.h"
#include "PreviewOps.h"
#include "PreviewOverlay.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "VoxelGrid.h"

#include <cmath>
#include <cstdint>
#include <vector>

namespace macvoxel::face_controller {
namespace {

void FloodFaceFromCell(const Document& doc, shapes::Vec3i seed,
                       int axis, int sign, uint8_t color,
                       bool eight_connected,
                       std::vector<shapes::Vec3i>& out) {
    out.clear();
    shapes::FloodCoplanarFace(doc.grid, seed, axis, sign, color,
                              eight_connected, out);
}

// Bulk full-rebuild path. Walks the seed plane k=1..d (extrude) or
// k=0..|d|-1 (inset / Remove / Paint) and stamps every cell. Used
// only when transitionFaceTo decides an incremental diff isn't safe
// (sign flip or face_with change mid-drag).
void ApplyFaceExtrusion(EditorContext& ctx, InteractionState& state, int d) {
    if (d == 0 || state.face.seed_cells.empty()) return;
    Document& doc = ctx.document;

    int da[3] = {0, 0, 0};
    da[state.anchor.face_axis] = state.face.sign;
    PreviewOverlay& overlay = ctx.preview;
    auto write = [&](int x, int y, int z, uint8_t new_val) {
        overlay.Stamp(x, y, z, new_val, doc.grid.Get(x, y, z));
    };

    const ToolSettings& tool = ctx.tool;
    const ToolMode mode = state.anchor.mode;
    const int n = std::abs(d);

    if (mode == ToolMode::Add && d > 0) {
        // Extrude outward: fill empty cells at offsets 1..d. Existing
        // geometry isn't overwritten (avoids surprising data loss).
        const bool with_geometry =
            (tool.face_with == FaceWithColor::Geometry);
        for (int k = 1; k <= d; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x + k * da[0];
                const int y = v.y + k * da[1];
                const int z = v.z + k * da[2];
                if (doc.grid.Get(x, y, z) != 0) continue;
                const uint8_t color = with_geometry
                    ? doc.grid.Get(v.x, v.y, v.z)  // source cell color
                    : tool.palette_idx;
                write(x, y, z, color);
            }
        }
    } else if (mode == ToolMode::Add && d < 0) {
        // Inset (Add with negative drag): erase the seed plane and
        // walk |d| steps inward.
        for (int k = 0; k < n; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                write(x, y, z, 0);
            }
        }
    } else if (mode == ToolMode::Remove) {
        // Always inset, magnitude only — drag direction is ignored.
        for (int k = 0; k < n; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                write(x, y, z, 0);
            }
        }
    } else if (mode == ToolMode::Paint) {
        // Repaint existing voxels at the seed plane and |d|-1 layers
        // in. Skips empty cells (Paint mode never fills).
        for (int k = 0; k < n; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                if (doc.grid.Get(x, y, z) != 0) {
                    write(x, y, z, tool.palette_idx);
                }
            }
        }
    }
    ++overlay.version;
}

// Apply or rollback a single Face-tool layer at `offset` along the
// face normal. These are the incremental hot-path helpers used during
// the live preview — they only touch one layer's worth of cells
// (seed_cells many) instead of the full O(seed × |d|) the bulk path
// would do. Both write to PreviewOverlay; the doc grid is not
// modified until commit.
void ApplyFaceLayerAtOffset(EditorContext& ctx, InteractionState& state,
                            int offset) {
    Document& doc = ctx.document;
    int da[3] = {0, 0, 0};
    da[state.anchor.face_axis] = state.face.sign;
    const ToolSettings& tool = ctx.tool;
    const ToolMode mode = state.anchor.mode;
    PreviewOverlay& overlay = ctx.preview;

    for (const auto& v : state.face.seed_cells) {
        const int x = v.x + offset * da[0];
        const int y = v.y + offset * da[1];
        const int z = v.z + offset * da[2];
        const uint8_t old_val = doc.grid.Get(x, y, z);
        if (mode == ToolMode::Add && offset > 0) {
            if (old_val != 0) continue;
            const uint8_t color =
                (tool.face_with == FaceWithColor::Geometry)
                    ? doc.grid.Get(v.x, v.y, v.z)
                    : tool.palette_idx;
            overlay.Stamp(x, y, z, color, old_val);
        } else if (mode == ToolMode::Add && offset <= 0) {
            overlay.Stamp(x, y, z, 0, old_val);
        } else if (mode == ToolMode::Remove) {
            overlay.Stamp(x, y, z, 0, old_val);
        } else if (mode == ToolMode::Paint) {
            if (old_val != 0) {
                overlay.Stamp(x, y, z, tool.palette_idx, old_val);
            }
        }
    }
    ++overlay.version;
}

void RollbackFaceLayerAtOffset(EditorContext& ctx, InteractionState& state,
                               int offset) {
    int da[3] = {0, 0, 0};
    da[state.anchor.face_axis] = state.face.sign;
    PreviewOverlay& overlay = ctx.preview;
    for (const auto& v : state.face.seed_cells) {
        const int x = v.x + offset * da[0];
        const int y = v.y + offset * da[1];
        const int z = v.z + offset * da[2];
        overlay.ClearAt(x, y, z);
    }
    ++overlay.version;
}

// Move the Face preview from `state.face.applied_d` to `new_d` by
// adding / removing only the layers that differ. Falls back to a full
// rebuild when the preview's "direction" flips (Add positive ↔
// negative drag) or `face_with` changes — both rare during a drag,
// so the fallback's O(seed × |d|) cost is acceptable.
//
// For Remove/Paint, `new_d` is expected pre-normalized to a
// non-negative magnitude (always inward), so a sign flip is impossible.
void TransitionFaceTo(EditorContext& ctx, InteractionState& state, int new_d) {
    const ToolSettings& tool = ctx.tool;
    const ToolMode mode = state.anchor.mode;

    bool full_rebuild = false;
    if (mode == ToolMode::Add) {
        if (tool.face_with != state.face.applied_with) full_rebuild = true;
        if (state.face.applied_d != 0 && new_d != 0 &&
            ((state.face.applied_d > 0) != (new_d > 0))) {
            full_rebuild = true;
        }
    }
    if (full_rebuild) {
        // Drop the per-layer state so ApplyFaceExtrusion sees an empty
        // canvas. Active is held — Face's overlay was activated once
        // at mouseDown and stays live until commit/cancel.
        PreviewOverlay& overlay = ctx.preview;
        overlay.additions.Clear();
        overlay.removals.Clear();
        ++overlay.version;
        state.face.applied_d = 0;
        ApplyFaceExtrusion(ctx, state, new_d);
        state.face.applied_d = new_d;
        state.face.applied_with = tool.face_with;
        return;
    }

    const int abs_old = std::abs(state.face.applied_d);
    const int abs_new = std::abs(new_d);
    int dir_sign;  // +1 = outward (Add d>0), -1 = inward (Add d<0, Remove, Paint)
    if (mode == ToolMode::Add) {
        if (state.face.applied_d == 0 && new_d == 0) return;
        dir_sign = (state.face.applied_d != 0 ? state.face.applied_d : new_d) > 0
                       ? +1 : -1;
    } else {
        dir_sign = -1;
    }
    // Map a 0-based layer index to the offset along the face normal:
    //   outward  (idx 0,1,2,...)  → offsets +1, +2, +3, ...
    //   inward   (idx 0,1,2,...)  → offsets  0, -1, -2, ...
    auto offset_for_idx = [dir_sign](int idx) {
        return dir_sign > 0 ? idx + 1 : -idx;
    };

    if (abs_new > abs_old) {
        for (int idx = abs_old; idx < abs_new; ++idx) {
            ApplyFaceLayerAtOffset(ctx, state, offset_for_idx(idx));
        }
    } else if (abs_new < abs_old) {
        for (int idx = abs_old - 1; idx >= abs_new; --idx) {
            RollbackFaceLayerAtOffset(ctx, state, offset_for_idx(idx));
        }
    }
    state.face.applied_d = new_d;
    state.face.applied_with = tool.face_with;
}

// Cursor → integer voxel distance along the face normal. Mutates
// observed_drag once the user actually moves; applies the
// click-as-1-layer override while observed_drag is still false; and
// normalizes Remove/Paint to magnitude only.
int ComputeFaceVoxels(InteractionState& state, const ViewContext& vc,
                      const MouseEvent& e) {
    int d = vc.FaceDragVoxels(
        e.local.x, e.local.y, state.anchor.cell,
        state.anchor.face_axis, state.face.sign,
        state.anchor.screen_local.x, state.anchor.screen_local.y);
    if (d != 0) state.face.observed_drag = true;
    if (d == 0 && !state.face.observed_drag) d = 1;
    if (state.anchor.mode == ToolMode::Remove ||
        state.anchor.mode == ToolMode::Paint) {
        d = std::abs(d);
    }
    return d;
}

}  // namespace

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    shapes::Vec3i seed;
    int axis = 2, sign = 1;
    uint8_t color = 0;
    if (!vc.PickFace(e.local.x, e.local.y, &seed, &axis, &sign, &color)) {
        return false;
    }
    state.anchor.has_anchor = true;
    state.anchor.cell = seed;
    state.anchor.face_axis = axis;
    state.anchor.mode = ctx.tool.mode;
    state.anchor.screen_local = e.local;
    state.anchor.tool = ToolKind::Face;
    state.face.sign = sign;
    state.face.seed_color = color;
    state.face.observed_drag = false;
    state.face.applied_d = 0;
    state.face.applied_with = ctx.tool.face_with;

    // FaceExtrudeKind::Geometry passes color=0 to the flood — that's
    // the "any non-empty cell" sentinel inside FloodCoplanarFace.
    const ToolSettings& t = ctx.tool;
    const uint8_t flood_color =
        (t.face_extrude == FaceExtrudeKind::Color) ? color : 0;
    FloodFaceFromCell(ctx.document, seed, axis, sign, flood_color,
                      t.face_eight_connected, state.face.seed_cells);
    state.drag_mode = DragMode::Shape;

    // Face uses an incremental preview: the overlay is activated once
    // at mouseDown and only modified — never wholesale cleared — until
    // commit/cancel. applied_d=0 already pairs with an empty overlay.
    ctx.preview.Clear();
    ctx.preview.active = true;

    // Render the click-as-1-layer preview immediately. As soon as the
    // user actually drags, OnMouseDragged switches to the live drag
    // distance.
    const int d = ComputeFaceVoxels(state, vc, e);
    if (d != state.face.applied_d ||
        ctx.tool.face_with != state.face.applied_with) {
        TransitionFaceTo(ctx, state, d);
    }
    return true;
}

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    const int d = ComputeFaceVoxels(state, vc, e);
    if (d == state.face.applied_d &&
        ctx.tool.face_with == state.face.applied_with) {
        return;
    }
    TransitionFaceTo(ctx, state, d);
}

void OnMouseUp(EditorContext& ctx, InteractionState& state,
               const ViewContext& vc, const MouseEvent& e) {
    if (!state.anchor.has_anchor) {
        state.face.seed_cells.clear();
        return;
    }
    // Re-run the incremental preview to the cursor's release location
    // so the overlay reflects the exact final state before commit.
    // The last mouseDragged event isn't guaranteed to fire at the
    // same point mouseUp arrives at — better to converge here than
    // to ship one layer off.
    const int d = ComputeFaceVoxels(state, vc, e);
    if (d != state.face.applied_d ||
        ctx.tool.face_with != state.face.applied_with) {
        TransitionFaceTo(ctx, state, d);
    }
    CommitPreviewOverlayThroughHistory(ctx);
    state.anchor.has_anchor = false;
    state.face.seed_cells.clear();
}

}  // namespace macvoxel::face_controller
