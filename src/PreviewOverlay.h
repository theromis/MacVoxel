#pragma once

#include "VoxelGrid.h"

#include <cstdint>

namespace macvoxel {

// A non-destructive sparse overlay the shape / face / generator tools
// stage their in-progress edits into instead of mutating the document.
// The renderer composites it on top of the doc:
//
//   additions[x,y,z] != 0   → render this palette index
//   removals[x,y,z] != 0    → render empty (hide whatever the doc has)
//   otherwise                → render the doc cell
//
// Why two channels: the overlay has to express "this cell should appear
// empty" for Remove / Paint / Add-inset previews. The earlier model wrote
// the new state into Document::grid and rolled it back each frame, which
// dirtied document chunks on every cursor move; the overlay sidesteps
// that entirely — its own version counter governs renderer rebuilds and
// the doc's chunk pool is left alone until commit.
//
// PreviewOverlay and FloatingBuffer never co-exist: FloatingBuffer is the
// selection-aware overlay (lift / paste / move-drag / rotate / flip) and
// auto-commits on tool change, mouseDown outside the buffer, render-mode
// toggle, etc. — exactly the gestures that would otherwise begin a tool
// preview. They share the renderer's overlay slot.
struct PreviewOverlay {
    VoxelGrid additions;
    VoxelGrid removals;
    bool active = false;
    // Bumped after any structural change to additions / removals. Renderer
    // caches its last-built version per overlay channel and rebuilds on
    // mismatch. Callers bump after a stamping batch, not per cell.
    uint64_t version = 0;

    void Clear() {
        additions.Clear();
        removals.Clear();
        active = false;
        ++version;
    }

    bool empty() const {
        return !active || (additions.empty() && removals.empty());
    }

    // Update the overlay so the user sees `new_val` at (x,y,z), given
    // `doc_val` is what the document has there. Maps the change onto
    // the additions / removals channels:
    //   new == doc            → ClearAt (no override)
    //   new != 0              → additions.Set(new), removals.Set(0)
    //   new == 0 && doc != 0  → additions.Set(0), removals.Set(1)
    void Stamp(int32_t x, int32_t y, int32_t z, uint8_t new_val,
               uint8_t doc_val) {
        if (new_val == doc_val) {
            ClearAt(x, y, z);
            return;
        }
        if (new_val != 0) {
            additions.Set(x, y, z, new_val);
            removals.Set(x, y, z, 0);
        } else {
            additions.Set(x, y, z, 0);
            removals.Set(x, y, z, 1);
        }
    }

    // Drop any preview override at (x,y,z) so the doc shows through.
    void ClearAt(int32_t x, int32_t y, int32_t z) {
        additions.Set(x, y, z, 0);
        removals.Set(x, y, z, 0);
    }
};

PreviewOverlay& CurrentPreview();

}  // namespace macvoxel
