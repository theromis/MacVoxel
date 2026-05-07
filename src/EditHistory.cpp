#include "EditHistory.h"

#include "VoxelGrid.h"

namespace macvoxel {

namespace {
// Same packing scheme as Raycast.h's PackCellKey: 21 bits per axis is
// plenty for any voxel grid we'll see.
inline int64_t PackKey(int32_t x, int32_t y, int32_t z) {
    constexpr uint64_t kMask = (1ull << 21) - 1ull;
    return static_cast<int64_t>(
        (static_cast<uint64_t>(x) & kMask) |
        ((static_cast<uint64_t>(y) & kMask) << 21) |
        ((static_cast<uint64_t>(z) & kMask) << 42));
}
}  // namespace

void EditHistory::BeginOp() {
    // Starting a new op invalidates redo (a typical undo-stack convention:
    // any new edit branch loses the redo timeline).
    redo_.clear();
    current_.changes.clear();
    current_index_.clear();
    in_op_ = true;
}

void EditHistory::Record(int32_t x, int32_t y, int32_t z,
                         uint8_t old_val, uint8_t new_val) {
    if (!in_op_ || old_val == new_val) return;
    // Collapse same-cell rewrites within the op so an undo restores the
    // pre-op value. Drag-paint commonly revisits a cell as the brush
    // sweeps over it. The hash map keeps the lookup O(1) — a linear
    // scan here used to make wide brush strokes O(N²).
    const int64_t key = PackKey(x, y, z);
    auto it = current_index_.find(key);
    if (it != current_index_.end()) {
        current_.changes[it->second].new_val = new_val;
        return;
    }
    current_index_.emplace(key, current_.changes.size());
    current_.changes.push_back(EditOp::Change{x, y, z, old_val, new_val});
}

void EditHistory::CommitOp() {
    if (!in_op_) return;
    in_op_ = false;
    current_index_.clear();
    if (current_.changes.empty()) return;
    undo_.push_back(std::move(current_));
    current_.changes.clear();
    while (undo_.size() > kMaxOps) undo_.pop_front();
}

void EditHistory::AbandonOp() {
    in_op_ = false;
    current_.changes.clear();
    current_index_.clear();
}

bool EditHistory::Undo(VoxelGrid& grid) {
    if (undo_.empty()) return false;
    EditOp op = std::move(undo_.back());
    undo_.pop_back();
    for (const auto& c : op.changes) {
        grid.Set(c.x, c.y, c.z, c.old_val);
    }
    redo_.push_back(std::move(op));
    while (redo_.size() > kMaxOps) redo_.pop_front();
    return true;
}

bool EditHistory::Redo(VoxelGrid& grid) {
    if (redo_.empty()) return false;
    EditOp op = std::move(redo_.back());
    redo_.pop_back();
    for (const auto& c : op.changes) {
        grid.Set(c.x, c.y, c.z, c.new_val);
    }
    undo_.push_back(std::move(op));
    while (undo_.size() > kMaxOps) undo_.pop_front();
    return true;
}

void EditHistory::Clear() {
    undo_.clear();
    redo_.clear();
    current_.changes.clear();
    current_index_.clear();
    in_op_ = false;
}

EditHistory& CurrentHistory() {
    static EditHistory s;
    return s;
}

}  // namespace macvoxel
