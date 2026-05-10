#pragma once

#include "Selection.h"
#include "VoxelGrid.h"

#include <array>
#include <cstdint>
#include <utility>
#include <vector>

namespace macvoxel {

// A separate sparse-chunk grid that lives "on top of" the document
// grid during selection-aware editing — paste/move-drag/rotate/flip
// stage their cells here instead of mutating the document until the
// user explicitly commits (deselects, switches tools, enters render
// mode, saves, ...).
//
// Why: the prior model rewrote document cells on every drag frame,
// which dirtied chunks and forced the renderer to re-mesh — fine at
// brush-size scale, catastrophic at 256³. The floating buffer is
// built once on lift, shifted by an integer offset uniform per frame,
// and folded into the renderer as a second volume the shader
// traverses alongside the doc grid. Per-drag-frame work is now O(1).
//
// Cells are stored in *grid space* (the same coordinate system as
// the document), so a paste-in-place paints back where it was copied
// from; `offset` is the running drag delta the renderer adds at
// sample time. Commit re-stamps each cell at (key + offset) into the
// document and clears the buffer.
struct FloatingBuffer {
    VoxelGrid grid;
    int32_t offset_x = 0;
    int32_t offset_y = 0;
    int32_t offset_z = 0;
    bool active = false;
    // True when the buffer was populated by lifting cells off the
    // document. Lift defers its grid mutations to commit time so the
    // entire move (lift + drag + commit) is a single EditHistory op
    // — Cmd-Z reverses the whole gesture atomically. `source_originals`
    // captures the cells we cleared from the doc and what palette was
    // there, so commit can build the pre-lift→post-commit delta and
    // undo-while-floating can put them back without touching history.
    // Paste-style buffers leave it false (no source cells; discarding
    // the buffer is the entire undo).
    bool originated_from_lift = false;
    std::vector<std::pair<std::array<int32_t, 3>, uint8_t>> source_originals;
    // Pre-lift selection so undo-while-floating restores the marquee
    // exactly as it was before the user grabbed the selection.
    Selection pre_lift_sel;
    // Bumped by callers after any structural change to `grid` (lift,
    // commit, rotate, flip). Renderer caches its uploaded chunks
    // against this; pure offset changes are O(1) and don't bump it.
    uint64_t version = 0;

    void Clear() {
        grid.Clear();
        offset_x = offset_y = offset_z = 0;
        active = false;
        originated_from_lift = false;
        source_originals.clear();
        pre_lift_sel = Selection{};
        ++version;
    }

    bool empty() const { return !active || grid.empty(); }
};

}  // namespace macvoxel
