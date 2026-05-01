#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
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
    // Finalize the current op. No-op if no changes were recorded.
    void CommitOp();
    // Discard the in-progress op (used when we abandon a stroke partway).
    void AbandonOp();

    bool CanUndo() const { return !undo_.empty(); }
    bool CanRedo() const { return !redo_.empty(); }

    // Apply the most recent op's old values to `grid` and shift it to the
    // redo stack. Caller bumps doc->version after to trigger a redraw.
    bool Undo(VoxelGrid& grid);
    // Re-apply the most recently undone op's new values.
    bool Redo(VoxelGrid& grid);

    // Throw out everything (called when a fresh document replaces the
    // current one — old undo state isn't meaningful for the new doc).
    void Clear();

private:
    std::deque<EditOp> undo_;
    std::deque<EditOp> redo_;
    EditOp current_;
    bool in_op_ = false;
};

EditHistory& CurrentHistory();

}  // namespace macvoxel
