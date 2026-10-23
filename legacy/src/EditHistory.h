#pragma once

#include "Material.h"
#include "Palette.h"
#include "Selection.h"
#include "VoxScene.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <unordered_map>
#include <vector>

namespace macvoxel {

struct Document;

// One edit operation = a contiguous batch of changes. A drag-paint
// stroke is one operation; a single click is also one operation;
// dragging the color picker through 30 intermediate values is one
// operation. Undo reverts the whole batch.
//
// An op can carry any combination of cell, palette-color, and material
// changes. Most ops only touch one category — painting touches cells,
// the color picker touches a palette slot — but mixed ops are valid
// (a future "set palette + paint with it" macro could write both).
struct EditOp {
    struct Change {
        int32_t x;
        int32_t y;
        int32_t z;
        uint8_t old_val;
        uint8_t new_val;
    };
    struct PaletteChange {
        uint8_t index;
        Color old_val;
        Color new_val;
    };
    struct MaterialChange {
        uint8_t index;
        Material old_val;
        Material new_val;
    };
    // Scene-graph mutation. Cheap by construction: unlinked nodes stay
    // resident in scene.nodes (the writer only emits reachable ones), so
    // Add/Remove are pure child-list link records — no voxel snapshots.
    //
    //   Transform:    leaf nTRN t/rot rewrite, addressed by trn_id
    //                 (stable across structural edits, unlike indices).
    //   Add/Remove:   (un)link `child_trn` at `child_pos` in group
    //                 `parent_group`'s child list.
    //   ActiveSwitch: active-object change. Recorded on EVERY
    //                 activation — undoing past a switch re-activates
    //                 the prior object before its cell ops replay, which
    //                 is what keeps cross-object undo correct.
    //   ModelResize:  dims-box edit, addressed by model_id. Carries the
    //                 voxels the shrink clipped as MODEL-LOCAL cells
    //                 (the model may be inactive, so its voxels aren't
    //                 in doc.grid, and cell records replay before scene
    //                 changes on undo — world-cell records can't
    //                 represent the clip either way). old_t/new_t hold
    //                 the pivot-compensating leaf translation.
    struct SceneChange {
        enum class Kind : uint8_t {
            Transform,
            AddObject,
            RemoveObject,
            ActiveSwitch,
            ModelResize,
        };
        Kind kind = Kind::Transform;
        // Transform (+ ModelResize's leaf translation):
        int32_t trn_id = -1;
        Vec3i32 old_t{}, new_t{};
        uint8_t old_r = 4, new_r = 4;
        // Add / Remove:
        int32_t parent_group = -1;
        int32_t child_pos = -1;
        int32_t child_trn = -1;
        // ActiveSwitch (object indices at op time):
        int32_t old_active = -1, new_active = -1;
        // ModelResize:
        int32_t model_id = -1;
        Vec3i32 old_dims{}, new_dims{};
        struct ClippedCell {
            Vec3i32 l;
            uint8_t v = 0;
        };
        std::vector<ClippedCell> clipped;
    };
    std::vector<Change> changes;
    std::vector<PaletteChange> palette_changes;
    std::vector<MaterialChange> material_changes;
    std::vector<SceneChange> scene_changes;
    // Optional selection snapshots, set by ops whose meaning includes
    // a selection state change (today: only the move-selection drag).
    // When present, Undo / Redo also restore the captured selection so
    // the marquee follows the voxels back. Brush / shape strokes leave
    // these empty, which means the selection survives the undo as-is.
    std::optional<Selection> pre_select;
    std::optional<Selection> post_select;
};

// Edit history. Bounded to ~100 operations so a long session doesn't
// accumulate unbounded RAM.
class EditHistory {
public:
    static constexpr size_t kMaxOps = 128;

    void BeginOp();
    // Record a change. Caller is responsible for actually applying the
    // change to the grid / palette; this just remembers old / new.
    // Coalescing same-target writes within one op is handled here.
    void Record(int32_t x, int32_t y, int32_t z, uint8_t old_val, uint8_t new_val);
    // Bulk equivalent — reserves capacity up front, but keeps per-cell
    // dedupe via current_index_ (drag-paint can revisit cells across
    // stamps, and the dedupe is what keeps undo correct when it does).
    void RecordBatch(const CellChange* changes, size_t count);
    void RecordPalette(uint8_t index, Color old_val, Color new_val);
    void RecordMaterial(uint8_t index, Material old_val, Material new_val);
    // Append a scene-graph mutation (no coalescing — scene ops are
    // few and order matters).
    void RecordSceneChange(const EditOp::SceneChange& change);
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

    // Apply the most recent op's old values to `doc` and shift it to
    // the redo stack. Mutates doc.grid / doc.palette as needed and
    // bumps the matching typed dirty counters so renderers reupload
    // only the affected categories. If the op carries a selection
    // snapshot and `sel` is non-null, the selection is rolled back too.
    bool Undo(Document& doc, Selection* sel = nullptr);
    // Re-apply the most recently undone op's new values.
    bool Redo(Document& doc, Selection* sel = nullptr);

    // Throw out everything (called when a fresh document replaces the
    // current one — old undo state isn't meaningful for the new doc).
    void Clear();

private:
    void RebuildIndex();

    std::deque<EditOp> undo_;
    std::deque<EditOp> redo_;
    EditOp current_;
    // Packed-coord → index into current_.changes for O(1) dedupe of
    // same-cell rewrites within an op. The linear scan that lived here
    // turned brush strokes into O(N²) work at large radii. Cleared on
    // BeginOp / CommitOp / AbandonOp so it never outlives an op.
    //
    // Lazy: `index_built_` is true when the map is in sync with
    // `current_.changes`. Single-batch ops (the common case for every
    // GPU-authoritative tool) skip building it entirely — RecordBatch
    // appends straight to `current_.changes` and leaves the map empty.
    // Any subsequent Record / RecordBatch call rebuilds the map first.
    std::unordered_map<int64_t, size_t> current_index_;
    bool index_built_ = true;
    // Same idea for palette / material slot dedupe. Indexed by the
    // 0..255 slot number; size 256 is fine for either array.
    std::array<int16_t, 256> palette_slot_index_{};   // -1 = absent
    std::array<int16_t, 256> material_slot_index_{};  // -1 = absent
    bool in_op_ = false;
};

}  // namespace macvoxel
