#include "EditHistory.h"

#include "CellKey.h"
#include "Document.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <cstddef>
#include <type_traits>

namespace macvoxel {

// Layout-compat invariants the RecordBatch fast path's range insert
// depends on. The two structs are conceptually the same payload —
// one comes from the diff buffer, the other lives in the undo stack —
// so keeping their bytes interchangeable saves per-cell copy-construct
// on 10M+ cell commits. Both types are trivially copyable so libc++'s
// vector::insert(end(), first, last) lowers to a memcpy.
static_assert(sizeof(EditOp::Change) == sizeof(CellChange),
              "EditOp::Change / CellChange size mismatch breaks history fast path");
static_assert(offsetof(EditOp::Change, x) == offsetof(CellChange, x),
              "x offset mismatch");
static_assert(offsetof(EditOp::Change, y) == offsetof(CellChange, y),
              "y offset mismatch");
static_assert(offsetof(EditOp::Change, z) == offsetof(CellChange, z),
              "z offset mismatch");
static_assert(offsetof(EditOp::Change, old_val) == offsetof(CellChange, old_val),
              "old_val offset mismatch");
static_assert(offsetof(EditOp::Change, new_val) == offsetof(CellChange, new_val),
              "new_val offset mismatch");
static_assert(std::is_trivially_copyable_v<EditOp::Change>,
              "EditOp::Change must be trivially copyable for memcpy path");
static_assert(std::is_trivially_copyable_v<CellChange>,
              "CellChange must be trivially copyable for memcpy path");

namespace {

// Apply one SceneChange in the undo (reverse) or redo (forward)
// direction, keeping the flat object cache, the active-object bake,
// and the edit volume coherent.
void ApplySceneChange(Document& doc, const EditOp::SceneChange& sc,
                      bool undo, Selection* sel) {
    Scene& scene = doc.scene;
    using Kind = EditOp::SceneChange::Kind;
    switch (sc.kind) {
        case Kind::Transform: {
            auto it = scene.nodes.find(sc.trn_id);
            if (it == scene.nodes.end()) return;
            it->second.t = undo ? sc.old_t : sc.new_t;
            it->second.rot = undo ? sc.old_r : sc.new_r;
            scene.RebuildObjects();
            // The active object's bake is frozen at its old transform.
            const int active = doc.active_object;
            if (active >= 0 &&
                static_cast<size_t>(active) < scene.objects.size() &&
                scene.objects[static_cast<size_t>(active)].trn_id ==
                    sc.trn_id) {
                doc.RebakeActiveObject();
            }
            return;
        }
        case Kind::AddObject:
        case Kind::RemoveObject: {
            const bool link = (sc.kind == Kind::AddObject) != undo;
            auto git = scene.nodes.find(sc.parent_group);
            if (git == scene.nodes.end() ||
                git->second.kind != SceneNode::Kind::Group) {
                return;
            }
            // Structural edits shift object indices; re-locate the
            // active object by its (stable) leaf id afterwards.
            const int active = doc.active_object;
            const int32_t active_trn =
                (active >= 0 &&
                 static_cast<size_t>(active) < scene.objects.size())
                    ? scene.objects[static_cast<size_t>(active)].trn_id
                    : -1;
            auto& kids = git->second.children;
            if (link) {
                const size_t pos = std::min(
                    static_cast<size_t>(std::max(sc.child_pos, 0)),
                    kids.size());
                kids.insert(kids.begin() + static_cast<ptrdiff_t>(pos),
                            sc.child_trn);
            } else {
                for (size_t p = 0; p < kids.size(); ++p) {
                    if (kids[p] == sc.child_trn) {
                        kids.erase(kids.begin() +
                                   static_cast<ptrdiff_t>(p));
                        break;
                    }
                }
            }
            scene.RebuildObjects();
            if (active_trn >= 0) {
                const int relocated = FindObjectByTrn(scene, active_trn);
                if (relocated >= 0) doc.active_object = relocated;
            }
            return;
        }
        case Kind::ActiveSwitch: {
            const int32_t target = undo ? sc.old_active : sc.new_active;
            if (target < 0 ||
                static_cast<size_t>(target) >= scene.objects.size()) {
                return;
            }
            // Fold any (possibly just-undone) grid edits into the
            // outgoing model before rebasing onto the incoming one —
            // the world buffer renders inactive objects from models.
            doc.SyncActiveModel();
            doc.active_object = target;
            doc.RebakeActiveObject();
            if (sel != nullptr) sel->Clear();
            return;
        }
    }
}

}  // namespace

void EditHistory::BeginOp() {
    // Starting a new op invalidates redo (a typical undo-stack convention:
    // any new edit branch loses the redo timeline).
    redo_.clear();
    current_.changes.clear();
    current_.palette_changes.clear();
    current_.material_changes.clear();
    current_.scene_changes.clear();
    current_.pre_select.reset();
    current_.post_select.reset();
    current_index_.clear();
    index_built_ = true;  // map empty == changes empty, in sync.
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
    in_op_ = true;
}

void EditHistory::RebuildIndex() {
    current_index_.clear();
    current_index_.reserve(current_.changes.size());
    for (size_t i = 0; i < current_.changes.size(); ++i) {
        const auto& c = current_.changes[i];
        current_index_.emplace(PackCellKey(c.x, c.y, c.z), i);
    }
    index_built_ = true;
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
    if (!index_built_) RebuildIndex();
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

void EditHistory::RecordBatch(const CellChange* changes, size_t count) {
    if (!in_op_ || count == 0) return;

    // Fast path: single-batch op (every GPU-authoritative tool's commit
    // hits this). The diff produced from DiffAndApplyRegion is already
    // deduped (one entry per cell) AND skips no-op entries (the
    // pre==cur check), so the map adds nothing and the per-entry filter
    // is unnecessary. Range-insert from a reinterpret_cast pointer
    // lowers to a single memcpy for trivially-copyable types (skipping
    // the zero-init that resize() would do before the copy). Leave the
    // index map empty + mark lazy; a later Record/RecordBatch rebuilds.
    if (current_.changes.empty()) {
        current_.changes.reserve(count);
        const EditOp::Change* src =
            reinterpret_cast<const EditOp::Change*>(changes);
        current_.changes.insert(current_.changes.end(), src, src + count);
        index_built_ = false;
        return;
    }

    if (!index_built_) RebuildIndex();
    current_.changes.reserve(current_.changes.size() + count);
    current_index_.reserve(current_index_.size() + count);
    for (size_t i = 0; i < count; ++i) {
        const auto& c = changes[i];
        if (c.old_val == c.new_val) continue;
        const int64_t key = PackCellKey(c.x, c.y, c.z);
        auto [it, inserted] =
            current_index_.try_emplace(key, current_.changes.size());
        if (inserted) {
            current_.changes.push_back(
                EditOp::Change{c.x, c.y, c.z, c.old_val, c.new_val});
        } else {
            current_.changes[it->second].new_val = c.new_val;
        }
    }
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

void EditHistory::RecordSceneChange(const EditOp::SceneChange& change) {
    if (!in_op_) return;
    current_.scene_changes.push_back(change);
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
    index_built_ = true;
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
    if (current_.changes.empty() && current_.palette_changes.empty() &&
        current_.material_changes.empty() &&
        current_.scene_changes.empty()) {
        return;
    }
    undo_.push_back(std::move(current_));
    current_.changes.clear();
    current_.palette_changes.clear();
    current_.material_changes.clear();
    current_.scene_changes.clear();
    while (undo_.size() > kMaxOps) undo_.pop_front();
}

void EditHistory::AbandonOp() {
    in_op_ = false;
    current_.changes.clear();
    current_.palette_changes.clear();
    current_.material_changes.clear();
    current_.scene_changes.clear();
    current_index_.clear();
    index_built_ = true;
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
}

bool EditHistory::Undo(Document& doc, Selection* sel) {
    if (undo_.empty()) return false;
    EditOp op = std::move(undo_.back());
    undo_.pop_back();
    for (const auto& c : op.changes) {
        doc.SetCell(c.x, c.y, c.z, c.old_val);
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
    // Scene changes revert after cells, newest first (an op reads as
    // "scene mutations, then cells" going forward).
    for (auto it = op.scene_changes.rbegin(); it != op.scene_changes.rend();
         ++it) {
        ApplySceneChange(doc, *it, /*undo=*/true, sel);
    }
    if (!op.scene_changes.empty()) doc.BumpScene();
    redo_.push_back(std::move(op));
    while (redo_.size() > kMaxOps) redo_.pop_front();
    return true;
}

bool EditHistory::Redo(Document& doc, Selection* sel) {
    if (redo_.empty()) return false;
    EditOp op = std::move(redo_.back());
    redo_.pop_back();
    for (const auto& sc : op.scene_changes) {
        ApplySceneChange(doc, sc, /*undo=*/false, sel);
    }
    if (!op.scene_changes.empty()) doc.BumpScene();
    for (const auto& c : op.changes) {
        doc.SetCell(c.x, c.y, c.z, c.new_val);
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
    current_.scene_changes.clear();
    current_index_.clear();
    index_built_ = true;
    palette_slot_index_.fill(-1);
    material_slot_index_.fill(-1);
    in_op_ = false;
}

}  // namespace macvoxel
