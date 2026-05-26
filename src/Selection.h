#pragma once

#include "VoxelGrid.h"

#include <array>
#include <cstdint>
#include <optional>
#include <unordered_set>
#include <vector>

namespace macvoxel {

// Selection state — Magica-style: at finalize time the marquee /
// box-select / flood lifts its cells *off* the doc texture into a
// separate `tex_lift` buffer (see VolumeTexture::liftTexture). From
// that moment until commit, the doc has a hole at the lift's source
// positions and the lift's tight bbox is the user-visible selection.
//
// `lift_active` is the canonical "is there a selection" flag. The
// `bounds_` field is the lift's tight bbox in world cell coords;
// `pre_lift_originals_` records the (cell, palette) pairs that were
// cleared from the doc when the lift was created — used to restore
// the doc on Cancel and to build the net diff on Commit.
//
// The legacy cell list (`voxels_`) is still populated by the
// box-mode preview and a handful of consumers that haven't been
// migrated yet; it will be removed once the migration completes.
class Selection {
public:
    Selection() = default;
    Selection(const Selection& other);
    Selection(Selection&& other) noexcept;
    Selection& operator=(const Selection& other);
    Selection& operator=(Selection&& other) noexcept;

    bool active() const { return active_; }
    bool empty() const { return voxels_.empty() && !lift_active_; }
    size_t size() const { return voxels_.size(); }
    const Bounds3& bounds() const { return bounds_; }
    const std::vector<std::array<int32_t, 3>>& voxels() const {
        return voxels_;
    }
    // Monotonic counter, bumped on every mutation. Renderers cache the
    // last value they saw against this and re-sync the GPU mirror only
    // on change.
    uint64_t version() const { return version_; }

    bool Contains(int32_t x, int32_t y, int32_t z) const;

    void SetVoxels(std::vector<std::array<int32_t, 3>> voxels);
    void SetBox(const Bounds3& box);
    void AddVoxel(int32_t x, int32_t y, int32_t z);
    void Clear();

    // Lift-state API. A "lift" means: cells listed in
    // `pre_lift_originals_` have been removed from the doc and
    // transplanted into `tex_lift` at their (possibly later mutated)
    // positions. `bounds_` tracks the lift's tight bbox.
    bool lift_active() const { return lift_active_; }
    const std::vector<CellChange>& pre_lift_originals() const {
        return pre_lift_originals_;
    }
    std::vector<CellChange>& pre_lift_originals_mutable() {
        return pre_lift_originals_;
    }

    // Mark the selection as a lift: stores the originals (cells cleared
    // from the doc + their pre-lift palettes), sets bounds_ to the
    // lift's tight bbox, and clears voxels_ (the lift contents are on
    // the GPU; readers consume them via tex_lift). active_ becomes true.
    void SetLift(const Bounds3& lift_bounds,
                 std::vector<CellChange> pre_lift_originals);

    // Update the lift's bounds after a translate / rotate / flip
    // mutation. Leaves `pre_lift_originals_` untouched (those still
    // describe what was originally cleared from the doc, regardless of
    // where the lift currently sits).
    void UpdateLiftBounds(const Bounds3& lift_bounds);

    // Wipe the lift state without restoring the doc — caller is
    // responsible for the doc side (Commit writes lift cells into the
    // doc; Cancel walks `pre_lift_originals_` to restore). After this
    // returns, active_ is false unless voxels_ still has content.
    void ClearLift();

private:
    Bounds3 bounds_{};
    std::vector<std::array<int32_t, 3>> voxels_;
    bool active_ = false;
    bool lift_active_ = false;
    std::vector<CellChange> pre_lift_originals_;
    uint64_t version_ = 0;
    mutable std::optional<std::unordered_set<int64_t>> membership_;

    void RecomputeBounds();
};

}  // namespace macvoxel
