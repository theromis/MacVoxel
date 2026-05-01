#include "EditHistory.h"

#include "VoxelGrid.h"

namespace macvoxel {

void EditHistory::BeginOp() {
    // Starting a new op invalidates redo (a typical undo-stack convention:
    // any new edit branch loses the redo timeline).
    redo_.clear();
    current_.changes.clear();
    in_op_ = true;
}

void EditHistory::Record(int32_t x, int32_t y, int32_t z,
                         uint8_t old_val, uint8_t new_val) {
    if (!in_op_ || old_val == new_val) return;
    // If this same cell was already modified earlier in the op, collapse
    // them into a single Change with the original old_val. Drag-paint
    // commonly hits the same cell repeatedly as the brush moves over it.
    for (auto& c : current_.changes) {
        if (c.x == x && c.y == y && c.z == z) {
            c.new_val = new_val;
            return;
        }
    }
    current_.changes.push_back(EditOp::Change{x, y, z, old_val, new_val});
}

void EditHistory::CommitOp() {
    if (!in_op_) return;
    in_op_ = false;
    if (current_.changes.empty()) return;
    undo_.push_back(std::move(current_));
    current_.changes.clear();
    while (undo_.size() > kMaxOps) undo_.pop_front();
}

void EditHistory::AbandonOp() {
    in_op_ = false;
    current_.changes.clear();
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
    in_op_ = false;
}

EditHistory& CurrentHistory() {
    static EditHistory s;
    return s;
}

}  // namespace macvoxel
