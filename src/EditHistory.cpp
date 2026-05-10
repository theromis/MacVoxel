#include "EditHistory.h"

#include "CellKey.h"
#include "Document.h"
#include "VoxelGrid.h"

namespace macvoxel {

void EditHistory::BeginOp() {
    // Starting a new op invalidates redo (a typical undo-stack convention:
    // any new edit branch loses the redo timeline).
    redo_.clear();
    current_.changes.clear();
    current_.palette_changes.clear();
    current_.material_changes.clear();
    current_.pre_select.reset();
    current_.post_select.reset();
    current_index_.clear();
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
    in_op_ = true;
}

void EditHistory::RecordSelectionPre(const Selection& sel) {
    if (!in_op_) return;
    current_.pre_select = sel;
}

void EditHistory::RecordSelectionPost(const Selection& sel) {
    if (!in_op_) return;
    current_.post_select = sel;
}

void EditHistory::Record(int32_t x, int32_t y, int32_t z,
                         uint8_t old_val, uint8_t new_val) {
    if (!in_op_ || old_val == new_val) return;
    // Collapse same-cell rewrites within the op so an undo restores the
    // pre-op value. Drag-paint commonly revisits a cell as the brush
    // sweeps over it. The hash map keeps the lookup O(1) — a linear
    // scan here used to make wide brush strokes O(N²).
    const int64_t key = PackCellKey(x, y, z);
    auto it = current_index_.find(key);
    if (it != current_index_.end()) {
        current_.changes[it->second].new_val = new_val;
        return;
    }
    current_index_.emplace(key, current_.changes.size());
    current_.changes.push_back(EditOp::Change{x, y, z, old_val, new_val});
}

void EditHistory::RecordPalette(uint8_t index, Color old_val, Color new_val) {
    if (!in_op_ || old_val == new_val) return;
    // Same dedupe pattern as cells. A color-picker drag sends a fresh
    // RecordPalette every frame the user moves the cursor — coalescing
    // collapses the entire drag into one op whose old_val is the
    // pre-drag color.
    const int16_t existing = palette_slot_index_[index];
    if (existing >= 0) {
        current_.palette_changes[existing].new_val = new_val;
        return;
    }
    palette_slot_index_[index] =
        static_cast<int16_t>(current_.palette_changes.size());
    current_.palette_changes.push_back({index, old_val, new_val});
}

void EditHistory::RecordMaterial(uint8_t index, Material old_val,
                                 Material new_val) {
    if (!in_op_ || old_val == new_val) return;
    const int16_t existing = material_slot_index_[index];
    if (existing >= 0) {
        current_.material_changes[existing].new_val = new_val;
        return;
    }
    material_slot_index_[index] =
        static_cast<int16_t>(current_.material_changes.size());
    current_.material_changes.push_back({index, old_val, new_val});
}

void EditHistory::CommitOp() {
    if (!in_op_) return;
    in_op_ = false;
    current_index_.clear();
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
    if (current_.changes.empty() && current_.palette_changes.empty() &&
        current_.material_changes.empty()) {
        return;
    }
    undo_.push_back(std::move(current_));
    current_.changes.clear();
    current_.palette_changes.clear();
    current_.material_changes.clear();
    while (undo_.size() > kMaxOps) undo_.pop_front();
}

void EditHistory::AbandonOp() {
    in_op_ = false;
    current_.changes.clear();
    current_.palette_changes.clear();
    current_.material_changes.clear();
    current_index_.clear();
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
}

bool EditHistory::Undo(Document& doc, Selection* sel) {
    if (undo_.empty()) return false;
    EditOp op = std::move(undo_.back());
    undo_.pop_back();
    for (const auto& c : op.changes) {
        doc.grid.Set(c.x, c.y, c.z, c.old_val);
    }
    for (const auto& p : op.palette_changes) {
        doc.palette.Set(p.index, p.old_val);
    }
    for (const auto& m : op.material_changes) {
        doc.palette.SetMaterial(m.index, m.old_val);
    }
    if (sel != nullptr && op.pre_select.has_value()) {
        *sel = *op.pre_select;
    }
    if (!op.changes.empty()) doc.BumpGeometry();
    if (!op.palette_changes.empty()) doc.BumpPalette();
    if (!op.material_changes.empty()) doc.BumpMaterials();
    redo_.push_back(std::move(op));
    while (redo_.size() > kMaxOps) redo_.pop_front();
    return true;
}

bool EditHistory::Redo(Document& doc, Selection* sel) {
    if (redo_.empty()) return false;
    EditOp op = std::move(redo_.back());
    redo_.pop_back();
    for (const auto& c : op.changes) {
        doc.grid.Set(c.x, c.y, c.z, c.new_val);
    }
    for (const auto& p : op.palette_changes) {
        doc.palette.Set(p.index, p.new_val);
    }
    for (const auto& m : op.material_changes) {
        doc.palette.SetMaterial(m.index, m.new_val);
    }
    if (sel != nullptr && op.post_select.has_value()) {
        *sel = *op.post_select;
    }
    if (!op.changes.empty()) doc.BumpGeometry();
    if (!op.palette_changes.empty()) doc.BumpPalette();
    if (!op.material_changes.empty()) doc.BumpMaterials();
    undo_.push_back(std::move(op));
    while (undo_.size() > kMaxOps) undo_.pop_front();
    return true;
}

void EditHistory::Clear() {
    undo_.clear();
    redo_.clear();
    current_.changes.clear();
    current_.palette_changes.clear();
    current_.material_changes.clear();
    current_index_.clear();
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
    in_op_ = false;
}

EditHistory& CurrentHistory() {
    static EditHistory s;
    return s;
}

}  // namespace macvoxel
