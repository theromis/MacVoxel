#pragma once

#include "Selection.h"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <unordered_map>
#include <vector>

namespace macvoxel {

class VoxelGrid;

// One edit operation = a contiguous batch of cell changes. A drag-paint
// stroke is one operation; a single click is also one operation. Undo
// reverts the whole batch.
struct EditOp {
    struct Change {
        int32_t x;
        int32_t y;
        int32_t z;
        uint8_t old_val;
        uint8_t new_val;
    };
    std::vector<Change> changes;
    // Optional selection snapshots, set by ops whose meaning includes
    // a selection state change (today: only the move-selection drag).
    // When present, Undo / Redo also restore the captured selection so
    // the marquee follows the voxels back. Brush / shape strokes leave
    // these empty, which means the selection survives the undo as-is.
    std::optional<Selection> pre_select;
    std::optional<Selection> post_select;
};

// Singleton history; edits and the Edit > Undo/Redo menu both reach for
// CurrentHistory(). Bounded to ~100 operations so a long session doesn't
// accumulate unbounded RAM.
class EditHistory {
public:
    static constexpr size_t kMaxOps = 128;

    void BeginOp();
    // Record a change. Caller is responsible for actually applying the
    // change to the grid; this just remembers (x, y, z, old, new).
    // Coalescing same-cell writes within one op is handled here.
    void Record(int32_t x, int32_t y, int32_t z, uint8_t old_val, uint8_t new_val);
    // Attach pre/post selection snapshots to the in-progress op. Called
    // by selection-aware ops (move, eventually rotate / paste / cut)
    // so Undo / Redo can restore the marquee alongside the voxels.
    void RecordSelectionPre(const Selection& sel);
    void RecordSelectionPost(const Selection& sel);
    // Finalize the current op. No-op if no changes were recorded.
    void CommitOp();
    // Discard the in-progress op (used when we abandon a stroke partway).
    void AbandonOp();

    bool CanUndo() const { return !undo_.empty(); }
    bool CanRedo() const { return !redo_.empty(); }

    // Apply the most recent op's old values to `grid` and shift it to
    // the redo stack. If the op carries a selection snapshot and `sel`
    // is non-null, the selection is rolled back too. Caller bumps
    // doc->version after to trigger a redraw.
    bool Undo(VoxelGrid& grid, Selection* sel = nullptr);
    // Re-apply the most recently undone op's new values.
    bool Redo(VoxelGrid& grid, Selection* sel = nullptr);

    // Throw out everything (called when a fresh document replaces the
    // current one — old undo state isn't meaningful for the new doc).
    void Clear();

private:
    std::deque<EditOp> undo_;
    std::deque<EditOp> redo_;
    EditOp current_;
    // Packed-coord → index into current_.changes for O(1) dedupe of
    // same-cell rewrites within an op. The linear scan that lived here
    // turned brush strokes into O(N²) work at large radii. Cleared on
    // BeginOp / CommitOp / AbandonOp so it never outlives an op.
    std::unordered_map<int64_t, size_t> current_index_;
    bool in_op_ = false;
};

EditHistory& CurrentHistory();

}  // namespace macvoxel
